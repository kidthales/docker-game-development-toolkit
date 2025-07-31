# Game Development Toolkit

A Docker image that sources a collection of free & mostly-free tools useful for game design & development automation.

## Features

- [Tiled](https://github.com/mapeditor/tiled) (headless)
- [tile-extruder](https://github.com/sporadic-labs/tile-extruder)
- [Aseprite](https://github.com/aseprite/aseprite) (headless) - Some assembly required!
- [YAML](https://github.com/eemeli/yaml) (parser)

## Requirements

- [Docker](https://docs.docker.com/get-docker/) & [Docker Compose](https://docs.docker.com/compose/install/).
- [GNU Make](https://www.gnu.org/software/make/).

## Quickstart

Build the default toolkit image:

```shell
make build c="--no-cache --pull"
```

## Usage

```text
 —— 🔧 👾 Game Development Toolkit Makefile 👾 🔧 ———————————————————————————————
help                           Outputs this help screen.
build                          Build images. Pass the parameter "c=" to add options to docker buildx bake; example: make build c="toolkit with-aseprite --no-cache --pull"
toolkit                        Build toolkit image. Pass the parameter "c=" to add options to docker buildx bake; example: make toolkit c="--no-cache --pull"
with-aseprite                  Build toolkit image with aseprite included. Pass the parameter "c=" to add options to docker buildx bake; example: make with-aseprite c="--no-cache --pull"
```

## With Aseprite

Due to license constraints, you will need to provide your own Aseprite binary. Fortunately, you are free to build your
own headless copy for personal use. There is a separate [project](https://github.com/kidthales/docker-aseprite-linux)
that addresses the issue; the resulting image would compatible for use with this project.

It is recommended that you purchase a legitimate copy of Aseprite, it is a great tool!

Assuming we have a headless Aseprite image available, we can create a git ignored `docker-bake.override.hcl` at the root
of the project. In this file, override the bake variable `ASEPRITE_UPSTREAM` with an appropriate [context](https://docs.docker.com/build/bake/contexts/)
value for the image. One example would be:

```hcl
ASEPRITE_UPSTREAM="docker-image://docker.io/myvendor/aseprite:headless-main"
```

## License

[MIT](./LICENSE)
