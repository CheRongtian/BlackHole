#!/bin/bash
set -e
BREW_PREFIX="$(brew --prefix)"

clang++ \
  -std=c++17 \
  -O3 \
  -fobjc-arc \
  BlackHole.mm \
  -o BlackHole \
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

./BlackHole