#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP="$(mktemp -d)"
RUNTIME_DIR_CREATED=0
USER_RUNTIME_DIR="/tmp/runtime-$(id -u)"

if [ ! -d "$USER_RUNTIME_DIR" ]; then
	RUNTIME_DIR_CREATED=1
fi

cleanup() {
	rm -rf "$TEST_TMP"
	if [ "$RUNTIME_DIR_CREATED" -eq 1 ] && [ -d "$USER_RUNTIME_DIR" ]; then
		rm -rf "$USER_RUNTIME_DIR"
	fi
}
trap cleanup EXIT

fail() {
	printf 'FAIL: %s\n' "$1" >&2
	exit 1
}

assert_eq() {
	local expected="$1"
	local actual="$2"
	local msg="$3"
	if [ "$expected" != "$actual" ]; then
		fail "$msg (expected '$expected', got '$actual')"
	fi
}

# 1. Dockerfile ldd "not found" rejection (positive, negative, boundary)
test_ldd_not_found_guard() {
	local ldd_case
	# shellcheck disable=SC2016
	ldd_case="$(grep -F 'case "$ldd_out" in *"not found"*)' "$REPO_ROOT/Dockerfile" | sed 's/ && \\$//; s/^[[:space:]]*//')"
	[ -n "$ldd_case" ] || fail "Dockerfile missing ldd 'not found' guard"

	# Positive: all shared libraries resolved
	local valid_ldd
	valid_ldd=$'\tlinux-vdso.so.1 (0x00007fff12345000)\n\tlibatomic.so.1 => /lib/x86_64-linux-gnu/libatomic.so.1 (0x00007f0000001000)\n\tlibc.so.6 => /lib/x86_64-linux-gnu/libc.so.6 (0x00007f0000002000)'
	local rc=0
	ldd_out="$valid_ldd" bash -c "$ldd_case" 2>"$TEST_TMP/ldd_valid.err" || rc=$?
	assert_eq "0" "$rc" "valid ldd output should pass"
	[ ! -s "$TEST_TMP/ldd_valid.err" ] || fail "valid ldd output should not write to stderr"

	# Negative: missing shared library
	local missing_ldd
	missing_ldd=$'\tlinux-vdso.so.1 (0x00007fff12345000)\n\tlibatomic.so.1 => not found\n\tlibc.so.6 => /lib/x86_64-linux-gnu/libc.so.6 (0x00007f0000002000)'
	rc=0
	ldd_out="$missing_ldd" bash -c "$ldd_case" 2>"$TEST_TMP/ldd_missing.err" || rc=$?
	assert_eq "1" "$rc" "missing library in ldd output must fail with exit 1"
	grep -q 'not found' "$TEST_TMP/ldd_missing.err" || fail "missing library error must be printed to stderr"

	# Boundary: exact 'not found' substring
	rc=0
	ldd_out="not found" bash -c "$ldd_case" 2>/dev/null || rc=$?
	assert_eq "1" "$rc" "boundary 'not found' ldd output must fail with exit 1"
}

# 2. Tiled wrapper runtime dir fallback, concurrency, and exit propagation
test_tiled_wrapper() {
	local wrapper_gen="$TEST_TMP/gen_tiled.sh"
	local wrapper="$TEST_TMP/tiled"
	local mock_bin="$TEST_TMP/bin"
	mkdir -p "$mock_bin"

	{
		printf 'tiled_bin=/opt/tiled/squashfs-root/usr/bin/tiled\n'
		awk '/^[[:space:]]*printf '\''%s\\n'\'' \\$/{flag=1} flag{print; if (/> \/usr\/local\/bin\/tiled/) exit}' "$REPO_ROOT/Dockerfile" \
			| sed "s|> /usr/local/bin/tiled.*|> \"$wrapper\"|"
	} > "$wrapper_gen"
	sh "$wrapper_gen"
	chmod +x "$wrapper"

	grep -q 'xvfb-run -a ' "$wrapper" || fail "tiled wrapper must invoke xvfb-run -a"
	if grep -q 'exec xvfb-run' "$wrapper"; then
		fail "tiled wrapper must not exec xvfb-run as PID 1 (deadlocks Xvfb SIGUSR1 wait)"
	fi
	# shellcheck disable=SC2016
	grep -Fq 'XDG_RUNTIME_DIR="/tmp/runtime-$(id -u)"' "$wrapper" || fail "tiled wrapper must fall back to per-UID runtime dir"

	cat <<'EOF' > "$mock_bin/xvfb-run"
#!/usr/bin/env bash
set -euo pipefail
if [ "$1" != "-a" ]; then
	printf 'missing -a flag: %s\n' "$1" >&2
	exit 99
fi
if [ -z "${XDG_RUNTIME_DIR:-}" ] || [ ! -w "$XDG_RUNTIME_DIR" ]; then
	printf 'XDG_RUNTIME_DIR not writable: %s\n' "${XDG_RUNTIME_DIR:-}" >&2
	exit 98
fi
if [ -n "${MOCK_LOG:-}" ]; then
	printf '%s|%s\n' "$XDG_RUNTIME_DIR" "$*" >> "$MOCK_LOG"
fi
exit "${MOCK_EXIT_CODE:-0}"
EOF
	chmod +x "$mock_bin/xvfb-run"

	# Positive: writable XDG_RUNTIME_DIR is preserved and args forwarded
	local writable_rt="$TEST_TMP/rt-writable"
	install -d -m 0700 "$writable_rt"
	local log_pos="$TEST_TMP/pos.log"
	local rc=0
	PATH="$mock_bin:$PATH" XDG_RUNTIME_DIR="$writable_rt" MOCK_LOG="$log_pos" \
		"$wrapper" --export-map json "my map.tmx" "out.json" || rc=$?
	assert_eq "0" "$rc" "writable XDG_RUNTIME_DIR should succeed"
	grep -q "^$writable_rt|-a /opt/tiled/squashfs-root/usr/bin/tiled --export-map json my map.tmx out.json\$" "$log_pos" \
		|| fail "tiled wrapper did not forward args or preserve writable XDG_RUNTIME_DIR"

	# Negative: empty/non-existent XDG_RUNTIME_DIR falls back to 0700 per-UID dir
	local log_neg="$TEST_TMP/neg.log"
	rc=0
	PATH="$mock_bin:$PATH" XDG_RUNTIME_DIR="$TEST_TMP/nonexistent-runtime-root" MOCK_LOG="$log_neg" \
		"$wrapper" --version || rc=$?
	assert_eq "0" "$rc" "unwritable XDG_RUNTIME_DIR fallback should succeed"
	[ -d "$USER_RUNTIME_DIR" ] || fail "fallback runtime dir $USER_RUNTIME_DIR was not created"
	local mode
	mode="$(stat -c '%a' "$USER_RUNTIME_DIR")"
	assert_eq "700" "$mode" "fallback runtime dir must have 0700 permissions"
	grep -q "^$USER_RUNTIME_DIR|-a " "$log_neg" || fail "fallback XDG_RUNTIME_DIR was not exported to xvfb-run"

	# Non-root read-only directory test when running as non-root UID
	if [ "$(id -u)" -ne 0 ]; then
		local ro_rt="$TEST_TMP/rt-readonly"
		install -d -m 0500 "$ro_rt"
		local log_ro="$TEST_TMP/ro.log"
		rc=0
		PATH="$mock_bin:$PATH" XDG_RUNTIME_DIR="$ro_rt" MOCK_LOG="$log_ro" \
			"$wrapper" --help || rc=$?
		assert_eq "0" "$rc" "read-only XDG_RUNTIME_DIR fallback should succeed for non-root UID"
		grep -q "^$USER_RUNTIME_DIR|-a " "$log_ro" || fail "read-only XDG_RUNTIME_DIR did not trigger per-UID fallback"
	fi

	# Negative: non-zero exit propagation
	rc=0
	PATH="$mock_bin:$PATH" XDG_RUNTIME_DIR="$writable_rt" MOCK_EXIT_CODE=42 \
		"$wrapper" --export-map json bad.tmx out.json || rc=$?
	assert_eq "42" "$rc" "tiled wrapper must propagate non-zero exit codes"

	# Concurrency: 8 parallel invocations (7 success, 1 failure)
	local log_conc="$TEST_TMP/conc.log"
	local -a pids=()
	local i
	for i in 1 2 3 4 5 6 7 8; do
		local exit_code=0
		if [ "$i" -eq 5 ]; then
			exit_code=7
		fi
		PATH="$mock_bin:$PATH" XDG_RUNTIME_DIR="$writable_rt" MOCK_EXIT_CODE="$exit_code" MOCK_LOG="$log_conc" \
			"$wrapper" --export-map json "job-$i.tmx" "job-$i.json" &
		pids+=("$!")
	done

	local ok_count=0
	local fail_count=0
	for pid in "${pids[@]}"; do
		rc=0
		wait "$pid" || rc=$?
		if [ "$rc" -eq 0 ]; then
			ok_count=$((ok_count + 1))
		elif [ "$rc" -eq 7 ]; then
			fail_count=$((fail_count + 1))
		else
			fail "unexpected concurrent exit code: $rc"
		fi
	done
	assert_eq "7" "$ok_count" "expected 7 successful concurrent tiled invocations"
	assert_eq "1" "$fail_count" "expected 1 failing concurrent tiled invocation"
	assert_eq "8" "$(wc -l < "$log_conc" | tr -d '[:space:]')" "expected 8 logged concurrent invocations"
}

# 3. Taskfile.yml test non-zero failure propagation and Bake check coverage
test_taskfile_contracts() {
	local cmd_block
	cmd_block="$(awk '/if docker image inspect/{flag=1} flag{print; if (/^[[:space:]]*fi$/) exit}' "$REPO_ROOT/Taskfile.yml" | sed 's/^[[:space:]]*//')"
	[ -n "$cmd_block" ] || fail "Taskfile.yml missing conditional non-free smoke test block"

	local mock_bin="$TEST_TMP/task-bin"
	mkdir -p "$mock_bin"
	cat <<'EOF' > "$mock_bin/docker"
#!/usr/bin/env bash
set -euo pipefail
if [ "$1" = "image" ] && [ "$2" = "inspect" ]; then
	exit "${MOCK_INSPECT_EXIT:-0}"
fi
if [ "$1" = "run" ]; then
	printf '%s\n' "$*" >> "${MOCK_DOCKER_LOG}"
	exit "${MOCK_RUN_EXIT:-0}"
fi
exit 97
EOF
	chmod +x "$mock_bin/docker"

	# Positive: image present and aseprite --version succeeds
	local docker_log="$TEST_TMP/docker.log"
	local rc=0
	PATH="$mock_bin:$PATH" MOCK_INSPECT_EXIT=0 MOCK_RUN_EXIT=0 MOCK_DOCKER_LOG="$docker_log" \
		bash -c "$cmd_block" || rc=$?
	assert_eq "0" "$rc" "Taskfile non-free test should pass when container exits 0"
	grep -q 'aseprite --version' "$docker_log" || fail "Taskfile non-free test did not run aseprite --version"

	# Boundary: non-free image absent -> skipped cleanly with exit 0
	: > "$docker_log"
	rc=0
	PATH="$mock_bin:$PATH" MOCK_INSPECT_EXIT=1 MOCK_RUN_EXIT=23 MOCK_DOCKER_LOG="$docker_log" \
		bash -c "$cmd_block" || rc=$?
	assert_eq "0" "$rc" "Taskfile non-free test should skip when image is absent"
	[ ! -s "$docker_log" ] || fail "docker run should not be called when non-free image is absent"

	# Negative: non-free image present and aseprite --version fails -> must propagate exit 23
	rc=0
	PATH="$mock_bin:$PATH" MOCK_INSPECT_EXIT=0 MOCK_RUN_EXIT=23 MOCK_DOCKER_LOG="$docker_log" \
		bash -c "$cmd_block" || rc=$?
	assert_eq "23" "$rc" "Taskfile non-free test must propagate non-zero exit codes"

	grep -q -- '--call=check gdtk gdtk-non-free' "$REPO_ROOT/Taskfile.yml" \
		|| fail "Taskfile.yml lint:bake must check both gdtk and gdtk-non-free"
	grep -q 'lint:shellcheck' "$REPO_ROOT/Taskfile.yml" \
		|| fail "Taskfile.yml must define lint:shellcheck"
	grep -q 'bash tests/toolkit_test.sh' "$REPO_ROOT/Taskfile.yml" \
		|| fail "Taskfile.yml test:unit must invoke tests/toolkit_test.sh"
}

# 4. clean.yml exclude-tags matching and rejection
test_clean_workflow_tags() {
	local pattern
	pattern="$(sed -n "s/.*exclude-tags:[[:space:]]*'\(.*\)'/\1/p" "$REPO_ROOT/.github/workflows/clean.yml")"
	[ -n "$pattern" ] || fail "clean.yml missing exclude-tags regex"

	local tag
	for tag in "latest" "1.0.0" "v1.2.3" "2026.11.0" "v2026.11.0-rc1"; do
		if ! printf '%s\n' "$tag" | grep -Eq "$pattern"; then
			fail "clean.yml exclude-tags should retain release/latest tag '$tag'"
		fi
	done

	for tag in "sha-5a36b5d" "pr-59" "dev" "latest-dev" "v1.2" "1.2" ""; do
		if printf '%s\n' "$tag" | grep -Eq "$pattern"; then
			fail "clean.yml exclude-tags must not protect ephemeral tag '$tag'"
		fi
	done
}

# 5. dependabot.yml LTS ignore rules, build.yml least-privilege/Trivy, Dockerfile hygiene, .gitignore
test_repo_governance_invariants() {
	local dep="$REPO_ROOT/.github/dependabot.yml"
	awk '
		/dependency-name: node/ { in_node=1; in_ubuntu=0; next }
		/dependency-name: ubuntu/ { in_ubuntu=1; in_node=0; next }
		/version-update:semver-major/ { if (in_node) node_major=1; if (in_ubuntu) ubuntu_major=1 }
		/version-update:semver-minor/ { if (in_ubuntu) ubuntu_minor=1 }
		END {
			if (!node_major || !ubuntu_major || !ubuntu_minor) exit 1
		}
	' "$dep" || fail "dependabot.yml missing expected LTS semver ignore rules"

	local build="$REPO_ROOT/.github/workflows/build.yml"
	awk '
		/^permissions:/ { in_top=1; next }
		/^concurrency:/ { in_top=0 }
		in_top && /packages: write/ { exit 1 }
	' "$build" || fail "build.yml top-level permissions must not grant packages: write"

	grep -q 'run: task test:unit' "$build" || fail "build.yml lint job must run task test:unit"
	assert_eq "2" "$(grep -c "load: \${{ github.event_name == 'pull_request' }}" "$build")" \
		"build.yml must load single-arch PR images for both gdtk and gdtk-non-free"
	assert_eq "2" "$(grep -c '\*\.platform=linux/amd64' "$build")" \
		"build.yml must pin *.platform=linux/amd64 on pull_request for both bake jobs"
	# shellcheck disable=SC2016
	grep -Fq '1.12.2 (`amd64` AppImage) / 1.12.1 (`arm64` apt)' "$build" \
		|| fail "build.yml release-bom Tiled version must match README.md"

	grep -q 'find /tmp/runtime-root -mindepth 1 -delete' "$REPO_ROOT/Dockerfile" \
		|| fail "Dockerfile must clear /tmp/runtime-root contents after build smoke tests"
	if grep -q '/root/\.npm' "$REPO_ROOT/Dockerfile"; then
		fail "Dockerfile should not contain dead rm -rf /root/.npm when HOME=/tmp"
	fi
	assert_eq "2" "$(grep -c 'find /tmp -mindepth 1 -maxdepth 1 ! -name runtime-root -exec rm -rf {} +' "$REPO_ROOT/Dockerfile" | awk '{print ($1 >= 4) ? 2 : 0}')" \
		"Dockerfile must prune /tmp across both toolkit and non-free stages"

	grep -qx '\.ci-local/' "$REPO_ROOT/.gitignore" \
		|| fail ".gitignore must ignore .ci-local/"
}

test_ldd_not_found_guard
test_tiled_wrapper
test_taskfile_contracts
test_clean_workflow_tags
test_repo_governance_invariants

printf 'PASS: all toolkit unit and boundary tests succeeded\n'
