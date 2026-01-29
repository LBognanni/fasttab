#!/bin/bash
set -e

RAYLIB_VERSION="5.5"
RAYLIB_URL="https://github.com/raysan5/raylib/releases/download/${RAYLIB_VERSION}/raylib-${RAYLIB_VERSION}_linux_amd64.tar.gz"
LIB_DIR="lib"
RAYLIB_DIR="${LIB_DIR}/raylib-${RAYLIB_VERSION}_linux_amd64"

STB_BASE_URL="https://raw.githubusercontent.com/nothings/stb/refs/heads/master"
STB_IMAGE_RESIZE_URL="${STB_BASE_URL}/stb_image_resize2.h"
STB_IMAGE_URL="${STB_BASE_URL}/stb_image.h"
INCLUDE_DIR="include"

echo "FastTab Development Setup"
echo "========================="

if [ ! -d "$INCLUDE_DIR" ]; then
    mkdir -p "$INCLUDE_DIR"
fi

# Download stb_image_resize.h
if [ ! -f "${INCLUDE_DIR}/stb_image_resize2.h" ]; then
    echo "Downloading stb_image_resize2.h..."
    curl -L "$STB_IMAGE_RESIZE_URL" -o "${INCLUDE_DIR}/stb_image_resize2.h"
fi

# Download stb_image.h
if [ ! -f "${INCLUDE_DIR}/stb_image.h" ]; then
    echo "Downloading stb_image.h..."
    curl -L "$STB_IMAGE_URL" -o "${INCLUDE_DIR}/stb_image.h"
fi

# Check if raylib is already set up
if [ -d "$RAYLIB_DIR" ]; then
    echo "raylib ${RAYLIB_VERSION} is already installed in ${RAYLIB_DIR}"
    exit 0
fi

# Create lib directory
mkdir -p "$LIB_DIR"

echo "Downloading raylib ${RAYLIB_VERSION}..."
curl -L "$RAYLIB_URL" | tar -xz -C "$LIB_DIR"

echo "raylib installed to ${RAYLIB_DIR}"

# Verify installation
if [ -f "${RAYLIB_DIR}/lib/libraylib.so" ]; then
    echo "Setup complete. You can now build with: zig build"
else
    echo "Error: raylib installation failed"
    exit 1
fi
