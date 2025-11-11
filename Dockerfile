#syntax=docker/dockerfile:1.4

FROM toolkit-upstream AS toolkit

LABEL org.opencontainers.image.source=https://github.com/kidthales/docker-game-development-toolkit
LABEL org.opencontainers.image.description="A curated collection of free tools useful for game development use cases such as build scripts or automated workflows like GitHub Actions."
LABEL org.opencontainers.image.licenses=MIT

ENV XDG_RUNTIME_DIR /tmp/runtime-root

# Install dependencies.
RUN apt-get update && apt-get upgrade -y && apt-get install -y --no-install-recommends \
	curl \
	ca-certificates \
	xauth \
	xvfb \
	&& rm -rf /var/lib/apt/lists/*

# Install Tiled
ARG tiled_version
WORKDIR /opt/tiled
RUN curl --show-error --silent --location --output AppImage https://github.com/mapeditor/tiled/releases/download/v${tiled_version}/Tiled-${tiled_version}_Linux_Qt-5_x86_64.AppImage && \
	chmod +x /opt/tiled/AppImage && \
	./AppImage --appimage-extract && \
	rm ./AppImage && \
	echo '#!/usr/bin/env bash\nxvfb-run /opt/tiled/squashfs-root/usr/bin/tiled ${@}' > /usr/local/bin/tiled && \
	chmod +x /usr/local/bin/tiled && \
	# Smoke test \
	tiled --help

# Global NPM packages
ARG tile_extruder_version
ARG yaml_version
RUN npm install -g \
	tile-extruder@${tile_extruder_version} \
	yaml@${yaml_version} && \
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

# Install dependencies.
RUN apt-get update && apt-get upgrade -y && apt-get install -y --no-install-recommends \
	libc++1-17t64 \
	libxcursor1 \
	&& rm -rf /var/lib/apt/lists/*

# Install aseprite.
COPY --from=aseprite-builder --chmod=755 /opt/aseprite/build/bin /opt/aseprite/bin
# Ensure binary is found in $PATH.
RUN ln -s /opt/aseprite/bin/aseprite /usr/local/bin/aseprite && \
	ln -s /opt/aseprite/bin/aseprite /usr/local/bin/ase && \
	# Smoke test \
	ase --help
