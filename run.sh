#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BREW_PREFIX="$(brew --prefix)"

clang++ \
  -std=c++17 \
  -O3 \
  -fobjc-arc \
  "$SCRIPT_DIR/BlackHole.mm" \
  "$SCRIPT_DIR/MetalRayTracer.mm" \
  "$SCRIPT_DIR/Engine.cpp" \
  "$SCRIPT_DIR/Scene.cpp" \
  -o "$SCRIPT_DIR/BlackHole" \
  -I"$SCRIPT_DIR" \
  -I"$BREW_PREFIX/include" \
  -L"$BREW_PREFIX/lib" \
  -lglfw \
  -lGLEW \
  -framework OpenGL \
  -framework Cocoa \
  -framework IOKit \
  -framework CoreVideo \
  -framework Metal \
  -framework Foundation

"$SCRIPT_DIR/BlackHole"
