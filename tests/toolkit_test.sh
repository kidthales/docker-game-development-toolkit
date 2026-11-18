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
	if grep -qE 'gdtk(-non-free)?:latest"' "$REPO_ROOT/Taskfile.yml"; then
		fail "Taskfile.yml smoke tests must use \${IMAGES_TAG:-latest}, not hardcoded :latest"
	fi
	# shellcheck disable=SC2016
	assert_eq "7" "$(grep -c '\${IMAGES_TAG:-latest}' "$REPO_ROOT/Taskfile.yml")" \
		"Taskfile.yml test/test:gdtk/test:non-free must parameterize image tags via \${IMAGES_TAG:-latest}"
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

	for tag in "sha-5a36b5d" "sha-5a36b5d-amd64" "sha-5a36b5d-arm64" "pr-59" "dev" "latest-dev" "v1.2" "1.2" ""; do
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
	if grep -q 'setup-qemu-action' "$build"; then
		fail "build.yml must not use QEMU emulation (setup-qemu-action)"
	fi
	if [ -e "$REPO_ROOT/.github/actionlint.yaml" ]; then
		fail ".github/actionlint.yaml must not exist to allow-list self-hosted-runner labels"
	fi
	assert_eq "2" "$(grep -c "load: \${{ github.event_name == 'pull_request' }}" "$build")" \
		"build.yml must load per-arch PR candidate images for both gdtk and gdtk-non-free"
	assert_eq "2" "$(grep -c 'runner: ubuntu-latest' "$build")" \
		"build.yml must define ubuntu-latest (amd64) matrix leg for both bake jobs"
	assert_eq "2" "$(grep -c 'runner: ubuntu-24.04-arm' "$build")" \
		"build.yml must define ubuntu-24.04-arm (arm64) matrix leg for both bake jobs"
	# shellcheck disable=SC2016
	assert_eq "2" "$(grep -c '\*\.platform=\${{ matrix\.platform }}' "$build")" \
		"build.yml must pass *.platform=\${{ matrix.platform }} for both bake jobs"
	assert_eq "2" "$(grep -c 'docker buildx imagetools create' "$build")" \
		"build.yml must merge multi-arch manifests via imagetools create for both targets"
	# shellcheck disable=SC2016
	grep -Fq 'group: ${{ github.workflow }}-${{ github.event.pull_request.number || github.ref }}' "$build" \
		|| fail "build.yml concurrency group must use github.event.pull_request.number || github.ref"
	# shellcheck disable=SC2016
	grep -Fq "cancel-in-progress: \${{ github.event_name == 'pull_request' }}" "$build" \
		|| fail "build.yml concurrency cancel-in-progress must only cancel pull_request runs"
	if grep -qE '(image-ref:|gdtk(-non-free)?\.tags=).*(:latest|latest})' "$build"; then
		fail "build.yml bake tags and Trivy image-ref must not target mutable :latest"
	fi
	# shellcheck disable=SC2016
	assert_eq "4" "$(grep -c "format('pr-{0}-{1}', github.sha, matrix.arch)" "$build")" \
		"build.yml must tag and scan PR-scoped candidate images for both gdtk and gdtk-non-free"
	# shellcheck disable=SC2016
	assert_eq "2" "$(grep -c 'IMAGES_TAG: pr-${{ github.sha }}-${{ matrix.arch }}' "$build")" \
		"build.yml smoke test steps must set PR-scoped IMAGES_TAG for both gdtk and gdtk-non-free"
	if grep -qE 'if:.*github\.actor' "$build"; then
		fail "build.yml guards must not key on mutable github.actor"
	fi
	assert_eq "5" "$(grep -cF "if: \${{ github.event_name != 'pull_request' || (!github.event.pull_request.head.repo.fork && github.event.pull_request.head.repo.full_name == github.repository && github.event.pull_request.user.login != 'dependabot[bot]') }}" "$build")" \
		"build.yml must guard all 5 trusted steps/jobs against fork and Dependabot PRs without skipping push/release"
	assert_eq "1" "$(grep -cF "if: \${{ github.event_name == 'pull_request' && (github.event.pull_request.head.repo.fork || github.event.pull_request.head.repo.full_name != github.repository || github.event.pull_request.user.login == 'dependabot[bot]') }}" "$build")" \
		"build.yml must guard untrusted PR lint step with scoped pull_request condition"
	# shellcheck disable=SC2016
	grep -Fq 'docker buildx bake -f docker-bake.hcl --print gdtk gdtk-non-free' "$build" \
		|| fail "build.yml release-bom must resolve versions via docker buildx bake --print"
	local var
	for var in TILED_VERSION TILE_EXTRUDER_VERSION YAML_VERSION ASEPRITE_GIT_REF; do
		grep -Fq "${var}=" "$build" \
			|| fail "build.yml release-bom must dynamically extract ${var} via jq"
	done
	if grep -qE '\| \*\*(Tiled|tile-extruder|yaml|Aseprite)\*\* \| [0-9v]' "$build"; then
		fail "build.yml release-bom must not hardcode tool versions"
	fi
	# shellcheck disable=SC2016
	grep -Fq 'Ubuntu 26.04 LTS \`apt\` (\`arm64\`)' "$build" \
		|| fail "build.yml release-bom Tiled row must state Ubuntu 26.04 LTS apt (arm64) source"

	local hcl_tiled hcl_extruder hcl_yaml hcl_aseprite
	hcl_tiled="$(sed -n 's/^variable "TILED_VERSION" { default = "\([^"]*\)" }/\1/p' "$REPO_ROOT/docker-bake.hcl")"
	hcl_extruder="$(sed -n 's/^variable "TILE_EXTRUDER_VERSION" { default = "\([^"]*\)" }/\1/p' "$REPO_ROOT/docker-bake.hcl")"
	hcl_yaml="$(sed -n 's/^variable "YAML_VERSION" { default = "\([^"]*\)" }/\1/p' "$REPO_ROOT/docker-bake.hcl")"
	hcl_aseprite="$(sed -n 's/^variable "ASEPRITE_GIT_REF" { default = "\([^"]*\)" }/\1/p' "$REPO_ROOT/docker-bake.hcl")"
	[ -n "$hcl_tiled" ] && [ -n "$hcl_extruder" ] && [ -n "$hcl_yaml" ] && [ -n "$hcl_aseprite" ] \
		|| fail "docker-bake.hcl missing expected default tool version variables"
	grep -Fq "| **[Tiled](https://github.com/mapeditor/tiled)** | ${hcl_tiled} (\`amd64\` AppImage)" "$REPO_ROOT/README.md" \
		|| fail "README.md Tiled BOM version must match docker-bake.hcl ($hcl_tiled)"
	grep -Fq "| **[tile-extruder](https://github.com/sporadic-labs/tile-extruder)** | ${hcl_extruder} |" "$REPO_ROOT/README.md" \
		|| fail "README.md tile-extruder BOM version must match docker-bake.hcl ($hcl_extruder)"
	grep -Fq "| **[yaml](https://github.com/eemeli/yaml)** | ${hcl_yaml} |" "$REPO_ROOT/README.md" \
		|| fail "README.md yaml BOM version must match docker-bake.hcl ($hcl_yaml)"
	grep -Fq "| **[Aseprite](https://github.com/aseprite/aseprite)** | ${hcl_aseprite} |" "$REPO_ROOT/README.md" \
		|| fail "README.md Aseprite BOM version must match docker-bake.hcl ($hcl_aseprite)"

	grep -q 'find /tmp/runtime-root -mindepth 1 -delete' "$REPO_ROOT/Dockerfile" \
		|| fail "Dockerfile must clear /tmp/runtime-root contents after build smoke tests"
	if grep -q '/root/\.npm' "$REPO_ROOT/Dockerfile"; then
		fail "Dockerfile should not contain dead rm -rf /root/.npm when HOME=/tmp"
	fi
	assert_eq "4" "$(grep -c 'find /tmp -mindepth 1 -maxdepth 1 ! -name runtime-root -exec rm -rf {} +' "$REPO_ROOT/Dockerfile")" \
		"Dockerfile must prune /tmp in all 4 cleanup steps across toolkit and non-free stages"

	grep -qx '\.ci-local/' "$REPO_ROOT/.gitignore" \
		|| fail ".gitignore must ignore .ci-local/"

	local ci_local="$REPO_ROOT/scripts/ci-local.ps1"
	[ -f "$ci_local" ] || fail "scripts/ci-local.ps1 must exist"
	# shellcheck disable=SC2016
	grep -Fq '$GateResults = [ordered]@{' "$ci_local" \
		|| fail "scripts/ci-local.ps1 must statically declare \$GateResults for Schema v2 receipts"
	grep -Fq 'Write-CiGateSummary' "$ci_local" \
		|| fail "scripts/ci-local.ps1 must emit Write-CiGateSummary output"
	grep -Fq 'task lint' "$ci_local" \
		|| fail "scripts/ci-local.ps1 must wrap task lint"
	grep -Fq 'task test:unit' "$ci_local" \
		|| fail "scripts/ci-local.ps1 must run task test:unit"
	# Negative / boundary: -CI mode must fail closed on 403 Forbidden / denied rather than falling back
	# shellcheck disable=SC2016
	grep -Fq '(-not $IsCI) -and' "$ci_local" \
		|| fail "scripts/ci-local.ps1 must restrict GHCR 403 Forbidden fallback strictly to non-CI local runs"
	# Negative / boundary: degraded Gate 2 must record pass-degraded rather than undegraded pass
	grep -Fq '"pass-degraded"' "$ci_local" \
		|| fail "scripts/ci-local.ps1 must record pass-degraded when Gate 2 falls back locally"
	# Negative / boundary: -CI mode must fail closed if ignored fingerprint entries exceed MaxIgnoredFiles
	# shellcheck disable=SC2016
	grep -Fq 'if ($IsCI -and $skippedByCount -gt 0)' "$ci_local" \
		|| fail "scripts/ci-local.ps1 must fail closed in -CI mode when fingerprint entries are skipped by count"
	# Negative / boundary: Gate 0 must anchor scratch/ and docs/learnings/ to the repo root
	grep -Fq '|^(?:scratch|docs/learnings)/' "$ci_local" \
		|| fail "scripts/ci-local.ps1 Gate 0 must anchor scratch/ and docs/learnings/ to repo root"
	# Negative / boundary: Gate 0 must reject tracked .ci-local/ and agent leaks while allowing local .ci-local/ untracked
	# shellcheck disable=SC2016
	grep -Eq '^[[:space:]]*\$TrackedLeakPattern[[:space:]]*=.*\\\.ci-local/' "$ci_local" \
		|| fail "scripts/ci-local.ps1 Gate 0 \$TrackedLeakPattern must reject tracked .ci-local/ files"
	# shellcheck disable=SC2016
	if grep -Eq '^[[:space:]]*\$UntrackedLeakPattern[[:space:]]*=.*\\\.ci-local/' "$ci_local"; then
		fail "scripts/ci-local.ps1 Gate 0 \$UntrackedLeakPattern must allow untracked .ci-local/ receipts"
	fi
	# shellcheck disable=SC2016
	if grep -qE '\[switch\]\$(Quick|Skip)' "$ci_local"; then
		fail "scripts/ci-local.ps1 must reject/omit skip or quick switches"
	fi
	# shellcheck disable=SC2016
	grep -Fq -- '--user "$(id -u):$(id -g)"' "$REPO_ROOT/README.md" \
		|| fail "README.md must document --user \"\$(id -u):\$(id -g)\" host-UID volume usage"
}

# 6. Dynamic release BOM extraction against live docker buildx bake --print output
test_release_bom_extraction() {
	local bake_json="$TEST_TMP/bake-print.json"
	docker buildx bake -f "$REPO_ROOT/docker-bake.hcl" --print gdtk gdtk-non-free > "$bake_json" \
		|| fail "docker buildx bake --print gdtk gdtk-non-free failed"

	local hcl_tiled hcl_extruder hcl_yaml hcl_aseprite
	hcl_tiled="$(sed -n 's/^variable "TILED_VERSION" { default = "\([^"]*\)" }/\1/p' "$REPO_ROOT/docker-bake.hcl")"
	hcl_extruder="$(sed -n 's/^variable "TILE_EXTRUDER_VERSION" { default = "\([^"]*\)" }/\1/p' "$REPO_ROOT/docker-bake.hcl")"
	hcl_yaml="$(sed -n 's/^variable "YAML_VERSION" { default = "\([^"]*\)" }/\1/p' "$REPO_ROOT/docker-bake.hcl")"
	hcl_aseprite="$(sed -n 's/^variable "ASEPRITE_GIT_REF" { default = "\([^"]*\)" }/\1/p' "$REPO_ROOT/docker-bake.hcl")"

	grep -Fq "\"tiled_version\": \"$hcl_tiled\"" "$bake_json" \
		|| fail "bake --print JSON missing expected tiled_version '$hcl_tiled'"
	grep -Fq "\"tile_extruder_version\": \"$hcl_extruder\"" "$bake_json" \
		|| fail "bake --print JSON missing expected tile_extruder_version '$hcl_extruder'"
	grep -Fq "\"yaml_version\": \"$hcl_yaml\"" "$bake_json" \
		|| fail "bake --print JSON missing expected yaml_version '$hcl_yaml'"
	grep -Fq "\"aseprite-upstream\": \"docker-image://ghcr.io/kidthales/aseprite:${hcl_aseprite}-headless\"" "$bake_json" \
		|| fail "bake --print JSON missing expected aseprite-upstream context"

	if ! command -v jq >/dev/null 2>&1; then
		if [ -n "${GITHUB_ACTIONS:-}" ]; then
			fail "jq must be available in CI to verify release-bom filters"
		fi
		printf 'SKIP: jq not installed; skipping release-bom jq filter checks\n' >&2
		return 0
	fi

	local build="$REPO_ROOT/.github/workflows/build.yml"
	local f_tiled f_extruder f_yaml f_aseprite
	f_tiled="$(sed -n "s/.*TILED_VERSION=\$(printf '%s\\\\n' \"\$BAKE_JSON\" | jq -er '\(.*\)')/\1/p" "$build")"
	f_extruder="$(sed -n "s/.*TILE_EXTRUDER_VERSION=\$(printf '%s\\\\n' \"\$BAKE_JSON\" | jq -er '\(.*\)')/\1/p" "$build")"
	f_yaml="$(sed -n "s/.*YAML_VERSION=\$(printf '%s\\\\n' \"\$BAKE_JSON\" | jq -er '\(.*\)')/\1/p" "$build")"
	f_aseprite="$(sed -n "s/.*ASEPRITE_GIT_REF=\$(printf '%s\\\\n' \"\$BAKE_JSON\" | jq -er '\(.*\)')/\1/p" "$build")"
	[ -n "$f_tiled" ] && [ -n "$f_extruder" ] && [ -n "$f_yaml" ] && [ -n "$f_aseprite" ] \
		|| fail "failed to extract jq filter expressions from build.yml"

	assert_eq "$hcl_tiled" "$(jq -er "$f_tiled" "$bake_json")" "jq filter for TILED_VERSION failed"
	assert_eq "$hcl_extruder" "$(jq -er "$f_extruder" "$bake_json")" "jq filter for TILE_EXTRUDER_VERSION failed"
	assert_eq "$hcl_yaml" "$(jq -er "$f_yaml" "$bake_json")" "jq filter for YAML_VERSION failed"
	assert_eq "$hcl_aseprite" "$(jq -er "$f_aseprite" "$bake_json")" "jq filter for ASEPRITE_GIT_REF failed"

	# Boundary: digest-pinned aseprite-upstream context must still extract clean git ref
	local digest_json="$TEST_TMP/digest-bake.json"
	printf '{"target":{"gdtk-non-free":{"contexts":{"aseprite-upstream":"docker-image://ghcr.io/kidthales/aseprite:%s-headless@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"}}}}\n' "$hcl_aseprite" > "$digest_json"
	assert_eq "$hcl_aseprite" "$(jq -er "$f_aseprite" "$digest_json")" "jq filter must handle digest-pinned aseprite-upstream context"

	# Boundary: registry host with port and tag must extract tag, not host:port
	local port_tag_json="$TEST_TMP/port-tag-bake.json"
	printf '{"target":{"gdtk-non-free":{"contexts":{"aseprite-upstream":"docker-image://localhost:5000/aseprite:%s-headless"}}}}\n' "$hcl_aseprite" > "$port_tag_json"
	assert_eq "$hcl_aseprite" "$(jq -er "$f_aseprite" "$port_tag_json")" "jq filter must extract tag when registry includes a port"

	# Negative: registry host with port and no tag must fail closed
	local port_notag_json="$TEST_TMP/port-notag-bake.json"
	printf '{"target":{"gdtk-non-free":{"contexts":{"aseprite-upstream":"docker-image://localhost:5000/aseprite"}}}}\n' > "$port_notag_json"
	local rc=0
	jq -er "$f_aseprite" "$port_notag_json" >/dev/null 2>&1 || rc=$?
	[ "$rc" -ne 0 ] || fail "jq -er must fail when registry has port and no tag"

	# Negative: digest-only reference with no tag must fail closed
	local digest_only_json="$TEST_TMP/digest-only-bake.json"
	printf '{"target":{"gdtk-non-free":{"contexts":{"aseprite-upstream":"docker-image://ghcr.io/kidthales/aseprite@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"}}}}\n' > "$digest_only_json"
	rc=0
	jq -er "$f_aseprite" "$digest_only_json" >/dev/null 2>&1 || rc=$?
	[ "$rc" -ne 0 ] || fail "jq -er must fail when digest-only context omits tag"

	# Negative: empty arg must fail closed with jq -er
	local empty_json="$TEST_TMP/empty-bake.json"
	printf '{"target":{"gdtk":{"args":{"tiled_version":""}}}}\n' > "$empty_json"
	rc=0
	jq -er "$f_tiled" "$empty_json" >/dev/null 2>&1 || rc=$?
	[ "$rc" -ne 0 ] || fail "jq -er must fail when tiled_version is empty"
}

test_ldd_not_found_guard
test_tiled_wrapper
test_taskfile_contracts
test_clean_workflow_tags
test_repo_governance_invariants
test_release_bom_extraction

printf 'PASS: all toolkit unit and boundary tests succeeded\n'
