# Docker Game Development Toolkit

[![Build](https://github.com/kidthales/docker-game-development-toolkit/actions/workflows/build.yml/badge.svg)](https://github.com/kidthales/gdtk/actions/workflows/build.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](./LICENSE)

A Docker image with a curated collection of free tools useful for game development use cases such as build scripts or automated workflows like GitHub Actions.

## Free Tools

### [Tiled](https://github.com/mapeditor/tiled)

```shell
docker run --rm -it -v .:/workspace ghcr.io/kidthales/gdtk tiled --export-map json --resolve-types-and-properties --embed-tilesets tilemap.tmx tilemap.json
```

### [tile-extruder](https://github.com/sporadic-labs/tile-extruder)

```shell
docker run --rm -it -v .:/workspace ghcr.io/kidthales/gdtk tile-extruder --tileWidth 16 --tileHeight 16 --input tileset.png --output tileset_extruded.png
```

### [YAML](https://github.com/eemeli/yaml)

```shell
docker run --rm -it -v .:/workspace ghcr.io/kidthales/gdtk bash -c "cat config.yml | yaml --json --indent 2 --single > config.json"
```

## Non-Free Tools

An additional set of curated 'non-free' tools are also maintained; these are open-source or source-available tools that have licensing constraints governing the distribution of compiled binaries.

> [!IMPORTANT]
> **Licensing & Registry Distribution (Aseprite EULA Compliance)**:  
> - **Public Registry Images**: The `ghcr.io/kidthales/gdtk` container image contains exclusively open-source tools with permissive or copyleft distribution licenses ([Tiled](https://github.com/mapeditor/tiled), [tile-extruder](https://github.com/sporadic-labs/tile-extruder), [yaml](https://github.com/eemeli/yaml)) and is published **Publicly** on GitHub Container Registry.
> - **Private / Local Non-Free Images**: [Aseprite](https://github.com/aseprite/aseprite) is governed by the [Aseprite EULA](https://github.com/aseprite/aseprite/blob/main/EULA.txt). While compiling Aseprite from source for personal or internal commercial use is fully permitted, redistributing compiled binaries to third parties is prohibited. Consequently, `gdtk-non-free` images hosted on GitHub Container Registry (`ghcr.io/kidthales/gdtk-non-free` and `ghcr.io/kidthales/aseprite`) are configured as **Private** packages.
> - **Local Build for External Users**: External developers must build `gdtk-non-free` locally on their own machines using the instructions below. Compiling locally for personal use is 100% compliant with the Aseprite EULA.

### [Aseprite](https://github.com/aseprite/aseprite)

```shell
docker run --rm -it -v .:/workspace gdtk-non-free aseprite --batch --layer 'Layer 1' example.aseprite --save-as example.png
```

## Development

Build an image containing only the free tools:

```shell
# Creates image with tag gdtk:latest
docker buildx bake --pull --no-cache
```

Build the non-free image locally (Aseprite compiled from source):

```shell
# Ensure docker-aseprite-headless submodule is initialized
git submodule update --init --recursive
# Creates image with tag gdtk-non-free:latest
docker buildx bake --pull --no-cache gdtk-non-free
```

Build both images:

```shell
# Creates images with tags gdtk:latest and gdtk-non-free:latest
docker buildx bake --pull --no-cache gdtk gdtk-non-free
```

Please refer to the [docker-bake](./docker-bake.hcl) file for all available bake variables and their default values.

### Makefile

A simple Makefile is provided to help ease build invocations:

```text
 —— Docker Game Development Toolkit Makefile ————————————————————————————————— 
help                           Outputs this help screen.
build                          Build the toolkit images. Pass the parameter "c=" to pass additional options and arguments to docker bake; example: make build c="--no-cache --pull gdtk-non-free"
```

You may populate a git-ignored `.env` file with bake variable values, for use with the `make build` command. For example:

```dotenv
IMAGES_PREFIX="kidthales/"
ASEPRITE_GIT_REF="v1.3.15"
ASEPRITE_BUILD_TYPE="RelWithDebInfo"
```

> [!WARNING]  
> Ensure that the values assigned in the `.env` file are wrapped in double quotes. This is a requirement of the underlying `docker buildx bake` command used to perform image builds.

