# Docker Game Development Toolkit

[![Build](https://github.com/kidthales/gdtk/actions/workflows/build.yml/badge.svg)](https://github.com/kidthales/gdtk/actions/workflows/build.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](./LICENSE)

A Docker image with a curated collection of free tools useful for game design & development automation.

Includes:
- [Tiled](https://github.com/mapeditor/tiled) (headless)
- [tile-extruder](https://github.com/sporadic-labs/tile-extruder)
- [YAML](https://github.com/eemeli/yaml) (parser)

## Usage

```shell
docker run --rm -it -v .:/workspace ghcr.io/kidthales/gdtk tiled --export-map json --resolve-types-and-properties --embed-tilesets tilemap.tmx tilemap.json
```

```shell
docker run --rm -it -v .:/workspace ghcr.io/kidthales/gdtk tile-extruder --tileWidth 16 --tileHeight 16 --input tileset.png --output tileset_extruded.png
```

```shell
docker run --rm -it -v .:/workspace ghcr.io/kidthales/gdtk bash -c "cat config.yml | yaml --json --indent 2 --single > config.json"
```
