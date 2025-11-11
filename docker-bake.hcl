variable "IMAGES_PREFIX" { default = "" }
variable "IMAGES_TAG" { default = formatdate("YYYY-MM-DD", timestamp()) }
variable "TILED_VERSION" { default = "1.11.2" }
variable "TOOLKIT_UPSTREAM" { default = "docker-image://node:lts-trixie" }

target "gdtk" {
  args = {
    tiled_version = "${TILED_VERSION}"
  }
  contexts = {
    toolkit-upstream = "${TOOLKIT_UPSTREAM}"
  }
  target = "toolkit"
  tags = ["${IMAGES_PREFIX}gdtk:${IMAGES_TAG}"]
}

group "default" {
  targets = ["gdtk"]
}
