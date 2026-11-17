#syntax=docker/dockerfile:1

FROM node:24-bookworm-slim AS node-upstream

FROM ubuntu:26.04 AS toolkit

LABEL org.opencontainers.image.source=https://github.com/kidthales/docker-game-development-toolkit
LABEL org.opencontainers.image.description="A curated collection of free tools useful for game development use cases such as build scripts or automated workflows like GitHub Actions."
LABEL org.opencontainers.image.licenses=MIT

ENV HOME=/tmp \
	XDG_RUNTIME_DIR=/tmp/runtime-root

# Install runtime dependencies.
RUN apt-get update && apt-get upgrade -y && apt-get install -y --no-install-recommends \
	ca-certificates \
	curl \
	libatomic1 \
	libegl1 \
	libfontconfig1 \
	xauth \
	xvfb \
	&& rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* \
	&& install -d -m 0700 /tmp/runtime-root

# Install Node.js LTS runtime from clean slim upstream
COPY --from=node-upstream /usr/local/bin/node /usr/local/bin/node
COPY --from=node-upstream /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s /usr/local/lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm && \
	ln -s /usr/local/lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx && \
	ldd_out="$(ldd /usr/local/bin/node)" && \
	case "$ldd_out" in *"not found"*) printf '%s\n' "$ldd_out" >&2; exit 1 ;; esac && \
	node --version

# Install Tiled and prune non-headless GUI assets
ARG TARGETARCH
ARG tiled_version
WORKDIR /opt/tiled
RUN if [ "$TARGETARCH" = "amd64" ] || [ -z "$TARGETARCH" ]; then \
		curl --show-error --silent --location --output AppImage "https://github.com/mapeditor/tiled/releases/download/v${tiled_version}/Tiled-${tiled_version}_Linux_x86_64.AppImage" && \
		chmod +x /opt/tiled/AppImage && \
		./AppImage --appimage-extract && \
		rm ./AppImage && \
		rm -rf /opt/tiled/squashfs-root/usr/translations \
			/opt/tiled/squashfs-root/usr/share/doc \
			/opt/tiled/squashfs-root/usr/share/man && \
		tiled_bin=/opt/tiled/squashfs-root/usr/bin/tiled; \
	elif [ "$TARGETARCH" = "arm64" ]; then \
		apt-get update && apt-get install -y --no-install-recommends tiled && \
		rm -rf /var/lib/apt/lists/* /var/tmp/* && \
		tiled_bin=/usr/bin/tiled; \
	else \
		echo "Unsupported architecture: $TARGETARCH" && exit 1; \
	fi && \
	printf '%s\n' \
		"#!/usr/bin/env bash" \
		"if [ ! -w \"\${XDG_RUNTIME_DIR:-}\" ]; then" \
		"	XDG_RUNTIME_DIR=\"/tmp/runtime-\$(id -u)\"" \
		"	install -d -m 0700 \"\$XDG_RUNTIME_DIR\"" \
		"	export XDG_RUNTIME_DIR" \
		"fi" \
		"xvfb-run -a \"$tiled_bin\" \"\$@\"" \
		"rc=\$?" \
		"exit \"\$rc\"" \
		> /usr/local/bin/tiled && \
	chmod +x /usr/local/bin/tiled && \
	# Smoke test \
	tiled --help && \
	find /tmp -mindepth 1 -maxdepth 1 ! -name runtime-root -exec rm -rf {} + && \
	find /tmp/runtime-root -mindepth 1 -delete

# Global NPM packages with cache pruning
ARG tile_extruder_version
ARG yaml_version
RUN npm install -g --omit=dev --no-audit --no-fund \
	tile-extruder@${tile_extruder_version} \
	yaml@${yaml_version} && \
	npm cache clean --force && \
	find /tmp -mindepth 1 -maxdepth 1 ! -name runtime-root -exec rm -rf {} + && \
	# Smoke tests \
	tile-extruder --help && \
	yaml --help

WORKDIR /workspace

FROM toolkit AS non-free

LABEL org.opencontainers.image.source=https://github.com/kidthales/docker-game-development-toolkit
LABEL org.opencontainers.image.description="A curated collection of free and non-free tools useful for game development use cases such as build scripts or automated workflows like GitHub Actions."
LABEL org.opencontainers.image.licenses=MIT

# Install stripped Aseprite runtime dependencies.
RUN apt-get update && apt-get upgrade -y && apt-get install -y --no-install-recommends \
	libc++1 \
	libfontconfig1 \
	libx11-6 \
	libxcursor1 \
	libxext6 \
	libxrandr2 \
	&& rm -rf /var/lib/apt/lists/* /var/tmp/* \
	&& find /tmp -mindepth 1 -maxdepth 1 ! -name runtime-root -exec rm -rf {} +

# Install aseprite.
COPY --from=aseprite-upstream --chmod=755 /opt/aseprite/bin /opt/aseprite/bin
# Ensure binary is found in $PATH.
RUN ln -s /opt/aseprite/bin/aseprite /usr/local/bin/aseprite && \
	ln -s /opt/aseprite/bin/aseprite /usr/local/bin/ase && \
	# Smoke test \
	ase --help && \
	find /tmp -mindepth 1 -maxdepth 1 ! -name runtime-root -exec rm -rf {} + && \
	find /tmp/runtime-root -mindepth 1 -delete
