#!/usr/bin/env bash

# build-container.sh - Universal Packer+Docker+HCP registry script
set -euo pipefail

# 🎨 Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
RED='\033[0;31m'
NC='\033[0m'

# === Load .env file
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  set -a
  source "${SCRIPT_DIR}/.env"
  set +a
else
  echo -e "${RED}❌ .env file missing next to build-container.sh${NC}"
  exit 1
fi

# === Parse arguments
SERVICE_NAME=""
LOG_ENABLED=false
CLEANUP_ENABLED=false
VERSION_TYPE="patch"

usage() {
  echo -e "${YELLOW}Usage: $0 --name <service> [--log] [--cleanup] [--minor|--major]${NC}"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) SERVICE_NAME="$2"; shift 2 ;;
    --log) LOG_ENABLED=true; shift ;;
    --cleanup) CLEANUP_ENABLED=true; shift ;;
    --minor) VERSION_TYPE="minor"; shift ;;
    --major) VERSION_TYPE="major"; shift ;;
    *) usage ;;
  esac
done

if [[ -z "$SERVICE_NAME" ]]; then usage; fi

# === Build context
BUILD_CONTEXT="${SCRIPT_DIR}/${SERVICE_NAME}"
if [[ ! -d "$BUILD_CONTEXT" ]]; then
  echo -e "${RED}❌ Build context folder '$BUILD_CONTEXT' does not exist.${NC}"
  exit 1
fi

DOCKERFILE="${BUILD_CONTEXT}/Dockerfile"
if [[ ! -f "$DOCKERFILE" ]]; then
  echo -e "${RED}❌ Dockerfile not found in ${DOCKERFILE}${NC}"
  exit 1
fi

# === Detect base image from Dockerfile
BASE_IMAGE=$(grep -m1 -E '^[Ff][Rr][Oo][Mm] ' "$DOCKERFILE" | awk '{print $2}')
if [[ -z "$BASE_IMAGE" ]]; then BASE_IMAGE="ubuntu:20.04"; fi
echo -e "${GREEN}📦 Detected Base Image: $BASE_IMAGE${NC}"

# === Detect project type + version bump
VERSION="v0.1.0"
PACKAGE_JSON="${BUILD_CONTEXT}/package.json"

if [[ -f "$PACKAGE_JSON" ]]; then
  raw_version=$(jq -r '.version // empty' "$PACKAGE_JSON")
  if [[ -z "$raw_version" ]]; then
    echo -e "${YELLOW}⚠️  No version in package.json, defaulting to $VERSION${NC}"
  else
    IFS='.' read -r major minor patch <<< "$raw_version"
    case $VERSION_TYPE in
      patch) patch=$((patch + 1));;
      minor) minor=$((minor + 1)); patch=0;;
      major) major=$((major + 1)); minor=0; patch=0;;
    esac
    VERSION="${major}.${minor}.${patch}"
    jq --arg v "$VERSION" '.version = $v' "$PACKAGE_JSON" > "${BUILD_CONTEXT}/tmp.$$.json" && mv "${BUILD_CONTEXT}/tmp.$$.json" "$PACKAGE_JSON"
    echo -e "${GREEN}📦 New version set in package.json: $VERSION${NC}"
  fi
else
  echo -e "${YELLOW}⚠️  Generic project detected, defaulting version to $VERSION${NC}"
fi

# === Write Packer template
cd "$BUILD_CONTEXT"
cat > packer.pkr.hcl <<EOF
packer {
  required_plugins {
    docker = {
      source  = "github.com/hashicorp/docker"
      version = ">= 1.0.8"
    }
  }
}

variable "image_tag" {
  type    = string
  default = "${VERSION}"
}

source "docker" "app" {
  image  = "${BASE_IMAGE}"
  commit = true
}

build {
  name    = "${SERVICE_NAME}-build"
  sources = ["source.docker.app"]

  provisioner "file" {
    source      = "."
    destination = "/build"
  }

  hcp_packer_registry {
    bucket_name  = "${SERVICE_NAME}"
    description  = "Container image for ${SERVICE_NAME} (version ${VERSION})"
    bucket_labels = {
      "project" = "sportclub"
    }
    build_labels = {
      "tag" = var.image_tag
    }
    platform {
      os   = "docker"
      arch = "amd64"
    }
  }

  post-processors {
    post-processor "docker-tag" {
      repository = "${DOCKERHUB_REPO}/${SERVICE_NAME}"
      tags       = [var.image_tag, "latest"]
    }

    post-processor "docker-push" {
      login = false
    }
  }
}
EOF

# === Run Packer
echo -e "${BLUE}🏗️  Running Packer build...${NC}"
packer init . > /dev/null
packer build -var="image_tag=${VERSION}" . | tee /tmp/packer-build.log

# === Optional cleanup
if $CLEANUP_ENABLED; then
  echo -e "${BLUE}🧹 Cleaning up dangling Docker images...${NC}"
  docker image prune -f
  echo -e "${GREEN}✅ Cleanup done.${NC}"
fi

cd "$SCRIPT_DIR"
echo -e "${GREEN}✅ Done! ${SERVICE_NAME} built and pushed. Version: $VERSION${NC}"
