#syntax=docker/dockerfile:1.4

FROM node:lts

LABEL org.opencontainers.image.source=https://github.com/kidthales/gdtk
LABEL org.opencontainers.image.description="Sources a collection of free & mostly-free tools useful for game design & development automation"
LABEL org.opencontainers.image.licenses=MIT

ENV XDG_RUNTIME_DIR /tmp/runtime-root

WORKDIR /tmp

# Install dependencies.
RUN apt-get update && apt-get upgrade -y && apt-get install -y --no-install-recommends \
	curl \
	ca-certificates \
	libc++1-16 \
	libfontconfig1 \
	libgl1 \
	libqt5svg5-dev \
	libsm6 \
	libssl3 \
	libxcursor1 \
	qbs \
	qtbase5-dev \
	qtbase5-private-dev \
	qtdeclarative5-dev \
	qtdeclarative5-private-dev \
	qttools5-dev-tools \
	xauth \
	xvfb \
	zlib1g-dev \
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
WORKDIR /tmp
RUN npm install -g tile-extruder yaml

WORKDIR /workspace

# HTTP
EXPOSE 80/tcp 8080/tcp
# HTTPS
EXPOSE 443/tcp
# HTTP/3
EXPOSE 443/udp
