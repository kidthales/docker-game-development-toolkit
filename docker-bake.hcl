variable "ASEPRITE_GIT_REF" { default = "v1.3.18.6" }
variable "ASEPRITE_IMAGE" { default = "docker-image://ghcr.io/kidthales/aseprite:${ASEPRITE_GIT_REF}-headless" }
variable "IMAGES_PREFIX" { default = "" }
variable "IMAGES_TAG" { default = "" }
variable "PLATFORMS" { default = ["linux/amd64", "linux/arm64"] }
variable "TILED_VERSION" { default = "1.12.2" }
variable "TILE_EXTRUDER_VERSION" { default = "2.1.1" }
variable "TOOLKIT_UPSTREAM" { default = "docker-image://ubuntu:24.04" }
variable "YAML_VERSION" { default = "2.9.1" }

target "gdtk" {
  platforms = PLATFORMS
  args = {
    tiled_version = "${TILED_VERSION}"
    tile_extruder_version = "${TILE_EXTRUDER_VERSION}"
    yaml_version = "${YAML_VERSION}"
  }
  contexts = {
    toolkit-upstream = "${TOOLKIT_UPSTREAM}"
  }
  target = "toolkit"
  tags = compact([
    "${IMAGES_PREFIX}gdtk:latest",
    IMAGES_TAG != "" ? "${IMAGES_PREFIX}gdtk:${IMAGES_TAG}" : ""
  ])
}

target "gdtk-non-free" {
  platforms = PLATFORMS
  args = {
    tiled_version = "${TILED_VERSION}"
    tile_extruder_version = "${TILE_EXTRUDER_VERSION}"
    yaml_version = "${YAML_VERSION}"
  }
  contexts = {
    aseprite-upstream = "${ASEPRITE_IMAGE}"
    toolkit-upstream = "${TOOLKIT_UPSTREAM}"
  }
  target = "non-free"
  tags = compact([
    "${IMAGES_PREFIX}gdtk-non-free:latest",
    IMAGES_TAG != "" ? "${IMAGES_PREFIX}gdtk-non-free:${IMAGES_TAG}" : ""
  ])
}

group "default" {
  targets = ["gdtk"]
}
