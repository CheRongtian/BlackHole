#!/bin/bash
clang++ blackhole.cpp -o blackhole \
    -std=c++17 \
    -I/opt/homebrew/include \
    -L/opt/homebrew/lib \
    -lglfw \
    -lGLEW \
    -framework OpenGL

./blackhole