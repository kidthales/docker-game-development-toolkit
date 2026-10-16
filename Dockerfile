#syntax=docker/dockerfile:1.4

FROM node:22-bookworm-slim AS node-upstream

FROM toolkit-upstream AS toolkit

LABEL org.opencontainers.image.source=https://github.com/kidthales/docker-game-development-toolkit
LABEL org.opencontainers.image.description="A curated collection of free tools useful for game development use cases such as build scripts or automated workflows like GitHub Actions."
LABEL org.opencontainers.image.licenses=MIT

ENV XDG_RUNTIME_DIR=/tmp/runtime-root

# Install runtime dependencies.
RUN apt-get update && apt-get install -y --no-install-recommends \
	ca-certificates \
	curl \
	libegl1 \
	libfontconfig1 \
	xauth \
	xvfb \
	&& rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# Install Node.js LTS runtime from clean slim upstream
COPY --from=node-upstream /usr/local/bin/node /usr/local/bin/node
COPY --from=node-upstream /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s /usr/local/lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm && \
	ln -s /usr/local/lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx

# Install Tiled and prune non-headless GUI assets
ARG TARGETARCH
ARG tiled_version
WORKDIR /opt/tiled
RUN if [ "$TARGETARCH" = "amd64" ] || [ -z "$TARGETARCH" ]; then \
        curl --show-error --silent --location --output AppImage https://github.com/mapeditor/tiled/releases/download/v${tiled_version}/Tiled-${tiled_version}_Linux_x86_64.AppImage && \
        chmod +x /opt/tiled/AppImage && \
        ./AppImage --appimage-extract && \
        rm ./AppImage && \
        rm -rf /opt/tiled/squashfs-root/usr/translations \
               /opt/tiled/squashfs-root/usr/share/doc \
               /opt/tiled/squashfs-root/usr/share/man && \
        printf '#!/usr/bin/env bash\nxvfb-run /opt/tiled/squashfs-root/usr/bin/tiled "$@"\n' > /usr/local/bin/tiled; \
    elif [ "$TARGETARCH" = "arm64" ]; then \
        apt-get update && apt-get install -y --no-install-recommends tiled && \
        rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* && \
        printf '#!/usr/bin/env bash\nxvfb-run /usr/bin/tiled "$@"\n' > /usr/local/bin/tiled; \
    else \
        echo "Unsupported architecture: $TARGETARCH" && exit 1; \
    fi && \
    chmod +x /usr/local/bin/tiled && \
    # Smoke test \
    tiled --help

# Global NPM packages with cache pruning
ARG tile_extruder_version
ARG yaml_version
RUN npm install -g --omit=dev --no-audit --no-fund \
	tile-extruder@${tile_extruder_version} \
	yaml@${yaml_version} && \
	npm cache clean --force && \
	rm -rf /root/.npm /tmp/* && \
	# Smoke tests \
	tile-extruder --help && \
	yaml --help

WORKDIR /workspace

# HTTP
EXPOSE 80/tcp 8080/tcp
# HTTPS
EXPOSE 443/tcp
# HTTP/3
EXPOSE 443/udp

FROM toolkit AS non-free

LABEL org.opencontainers.image.source=https://github.com/kidthales/docker-game-development-toolkit
LABEL org.opencontainers.image.description="A curated collection of free and non-free tools useful for game development use cases such as build scripts or automated workflows like GitHub Actions."
LABEL org.opencontainers.image.licenses=MIT

# Install stripped Aseprite runtime dependencies.
RUN apt-get update && apt-get install -y --no-install-recommends \
	libc++1-18 \
	libx11-6 \
	libxcursor1 \
	libxext6 \
	libxrandr2 \
	&& rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# Install aseprite.
COPY --from=aseprite-builder --chmod=755 /opt/aseprite/build/bin /opt/aseprite/bin
# Ensure binary is found in $PATH.
RUN ln -s /opt/aseprite/bin/aseprite /usr/local/bin/aseprite && \
	ln -s /opt/aseprite/bin/aseprite /usr/local/bin/ase && \
	# Smoke test \
	ase --help
