# Docker Game Development Toolkit

[![Build](https://github.com/kidthales/docker-game-development-toolkit/actions/workflows/build.yml/badge.svg)](https://github.com/kidthales/docker-game-development-toolkit/actions/workflows/build.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](./LICENSE)
[![Platform](https://img.shields.io/badge/platform-linux%2Famd64%20%7C%20linux%2Farm64-lightgrey.svg)](https://github.com/kidthales/docker-game-development-toolkit)
[![Base](https://img.shields.io/badge/base-Ubuntu%2024.04%20LTS-E95420.svg)](https://ubuntu.com/)
[![Taskfile](https://img.shields.io/badge/task-go--task%20v3-00ADD8.svg)](https://taskfile.dev/)
[![GHCR](https://img.shields.io/badge/ghcr.io-kidthales%2Fgdtk-blue.svg)](https://github.com/kidthales/docker-game-development-toolkit/pkgs/container/gdtk)

A multi-platform container suite providing headless, curated asset-processing toolchains for 2D game development pipelines, build automations, and GitHub Actions CI workflows.

Built on **Ubuntu 24.04 LTS (Noble Numbat)** with native multi-architecture support for **`linux/amd64`** (x86_64) and **`linux/arm64`** (Apple Silicon / ARM64).

---

## Contained Tools & Bill of Materials (BOM)

| Tool | Version | CLI Binary | Tier | Purpose | Upstream License |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **[Tiled](https://github.com/mapeditor/tiled)** | 1.12.2 | `tiled` | Free (`gdtk`) | 2D tilemap export (JSON, Lua, CSV) via headless Xvfb | GPL-2.0-or-later |
| **[tile-extruder](https://github.com/sporadic-labs/tile-extruder)** | 2.1.1 | `tile-extruder` | Free (`gdtk`) | Extrudes tile borders to prevent texture bleeding & seams | MIT |
| **[yaml](https://github.com/eemeli/yaml)** | 2.9.1 | `yaml` | Free (`gdtk`) | Fast YAML-to-JSON and JSON-to-YAML formatting & parsing | Apache-2.0 |
| **[Aseprite](https://github.com/aseprite/aseprite)** | v1.3.18.6 | `aseprite`, `ase` | Non-Free (`gdtk-non-free`) | Headless sprite slicing, tags export, and sheet packing | EULA (Proprietary) |

---

## Licensing & Registry Distribution (Aseprite EULA Compliance)

> [!IMPORTANT]
> - **Public Registry Images (`ghcr.io/kidthales/gdtk`)**: Contains exclusively open-source tools with permissive or copyleft distribution licenses ([Tiled](https://github.com/mapeditor/tiled), [tile-extruder](https://github.com/sporadic-labs/tile-extruder), [yaml](https://github.com/eemeli/yaml)) and is published **Publicly** on GitHub Container Registry.
> - **Private / Local Non-Free Images (`gdtk-non-free`)**: [Aseprite](https://github.com/aseprite/aseprite) is governed by the [Aseprite EULA](https://github.com/aseprite/aseprite/blob/main/EULA.txt). While compiling Aseprite from source for personal or internal commercial studio use is fully permitted, redistributing compiled binaries to third parties is prohibited. Consequently, `gdtk-non-free` images hosted on GitHub Container Registry (`ghcr.io/kidthales/gdtk-non-free` and `ghcr.io/kidthales/aseprite`) are configured as **Private** packages.
> - **Local Build for External Users**: External developers can build `gdtk-non-free` locally in two simple steps using the instructions below. Compiling locally for personal use is 100% compliant with the Aseprite EULA.

---

## Real-World Integration Recipes

### 1. Direct CLI Usage

Export a Tiled map to JSON with resolved custom types:
```shell
docker run --rm -v "${PWD}:/workspace" ghcr.io/kidthales/gdtk:latest \
    tiled --export-map json --resolve-types-and-properties --embed-tilesets maps/level1.tmx maps/level1.json
```

Extrude tileset margins by 1px to eliminate camera scrolling seams:
```shell
docker run --rm -v "${PWD}:/workspace" ghcr.io/kidthales/gdtk:latest \
    tile-extruder --tileWidth 16 --tileHeight 16 --input tilesets/dungeon.png --output tilesets/dungeon_extruded.png
```

Convert a YAML game manifest to formatted JSON:
```shell
docker run --rm -v "${PWD}:/workspace" ghcr.io/kidthales/gdtk:latest \
    bash -c "cat config.yml | yaml --json --indent 2 --single > config.json"
```

Batch-export sprite frames and slices using local `gdtk-non-free`:
```shell
docker run --rm -v "${PWD}:/workspace" gdtk-non-free:latest \
    aseprite --batch sprites/player.aseprite --sheet output/player.png --data output/player.json
```

---

### 2. Incremental Asset Pipeline with `go-task` (`Taskfile.yml`)

You can plug `ghcr.io/kidthales/gdtk` directly into your game repository's `Taskfile.yml` to automatically recompile maps and tilesets only when source files change:

```yaml
version: '3'

tasks:
  export:maps:
    desc: Export Tiled TMX maps to JSON using GDTK
    sources:
      - 'raw-assets/maps/*.tmx'
      - 'raw-assets/tilesets/*.tsx'
    generates:
      - 'game/assets/maps/*.json'
    cmds:
      - docker run --rm -v "{{.ROOT_DIR}}:/workspace" ghcr.io/kidthales/gdtk:latest
        tiled --export-map json --resolve-types-and-properties raw-assets/maps/level1.tmx game/assets/maps/level1.json

  extrude:tilesets:
    desc: Extrude tileset borders to prevent rendering seams
    sources:
      - 'raw-assets/tilesets/*.png'
    generates:
      - 'game/assets/tilesets/*_extruded.png'
    cmds:
      - docker run --rm -v "{{.ROOT_DIR}}:/workspace" ghcr.io/kidthales/gdtk:latest
        tile-extruder --tileWidth 16 --tileHeight 16 --input raw-assets/tilesets/terrain.png --output game/assets/tilesets/terrain_extruded.png
```

---

### 3. GitHub Actions CI/CD Pipeline

Run headless asset validation or automated map exports directly inside a containerized GitHub Actions job:

```yaml
name: Compile Game Assets

on:
  push:
    branches: [main]

jobs:
  build-assets:
    runs-on: ubuntu-latest
    container:
      image: ghcr.io/kidthales/gdtk:latest
    steps:
      - uses: actions/checkout@v7
      - name: Export Tiled Maps
        run: |
          tiled --export-map json raw-assets/maps/dungeon.tmx game/assets/maps/dungeon.json
      - name: Extrude Tilesets
        run: |
          tile-extruder --tileWidth 16 --tileHeight 16 --input raw-assets/tilesets/dungeon.png --output game/assets/tilesets/dungeon_extruded.png
```

---

## Local Development with `go-task`

This repository uses [`go-task`](https://taskfile.dev/) for cross-platform local automation across Windows, macOS, and Linux:

```shell
# Display available tasks
task

# Build free toolkit image (gdtk:latest)
task build

# Build non-free image with Aseprite (gdtk-non-free:latest)
task build -- gdtk-non-free

# Run smoke tests against local images
task test

# Run static analysis suite (BuildKit check, Hadolint, Actionlint, EditorConfig)
task lint

# Print resolved bake configuration
task print
```

### Configuration via `.env`

You can customize build variables by creating a `.env` file in the root directory:

```dotenv
IMAGES_PREFIX="kidthales/"
IMAGES_TAG="2026.10.0"
ASEPRITE_GIT_REF="v1.3.18.6"
PLATFORMS=["linux/amd64", "linux/arm64"]
```

> [!WARNING]
> Values assigned in `.env` must be wrapped in double quotes. This is a syntax requirement of the underlying `docker buildx bake -f .env` invocation.

---

## Building `gdtk-non-free` Locally (EULA Compliant)

To build the non-free image locally without downloading private images from GHCR:

1. Clone and compile the headless Aseprite base:
   ```shell
   git clone https://github.com/kidthales/docker-aseprite-headless.git
   cd docker-aseprite-headless
   task build
   ```
2. Build `gdtk-non-free` in this repository:
   ```shell
   cd ../docker-game-development-toolkit
   task build -- gdtk-non-free
   ```
