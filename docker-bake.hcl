variable "ASEPRITE_BUILDER_UPSTREAM" { default = "docker-image://python:3.12.12-trixie" }
variable "ASEPRITE_BUILD_TYPE" { default = "Release" }
variable "ASEPRITE_GIT_REF" { default = "v1.3.15.5" }
variable "IMAGES_PREFIX" { default = "" }
variable "IMAGES_TAG" { default = formatdate("YYYY-MM-DD", timestamp()) }
variable "TILED_VERSION" { default = "1.11.2" }
variable "TILE_EXTRUDER_VERSION" { default = "2.1.1" }
variable "TOOLKIT_UPSTREAM" { default = "docker-image://node:lts-trixie" }
variable "YAML_VERSION" { default = "2.8.1" }

target "gdtk" {
  args = {
    tiled_version = "${TILED_VERSION}"
    tile_extruder_version = "${TILE_EXTRUDER_VERSION}"
    yaml_version = "${YAML_VERSION}"
  }
  contexts = {
    toolkit-upstream = "${TOOLKIT_UPSTREAM}"
  }
  target = "toolkit"
  tags = ["${IMAGES_PREFIX}gdtk:${IMAGES_TAG}", "${IMAGES_PREFIX}gdtk:latest"]
}

target "gdtk-non-free" {
  args = {
    tiled_version = "${TILED_VERSION}"
    tile_extruder_version = "${TILE_EXTRUDER_VERSION}"
    yaml_version = "${YAML_VERSION}"
  }
  contexts = {
    aseprite-builder = "target:aseprite-builder"
    toolkit-upstream = "${TOOLKIT_UPSTREAM}"
  }
  target = "non-free"
  tags = ["${IMAGES_PREFIX}gdtk-non-free:${IMAGES_TAG}", "${IMAGES_PREFIX}gdtk-non-free:latest"]
}

target "aseprite-builder" {
  args = {
    aseprite_build_type = "${ASEPRITE_BUILD_TYPE}"
    aseprite_git_ref = "${ASEPRITE_GIT_REF}"
  }
  context = "./docker-aseprite-headless"
  contexts = {
    builder-upstream = "${ASEPRITE_BUILDER_UPSTREAM}"
  }
  target = "builder"
}

group "default" {
  targets = ["gdtk"]
}
