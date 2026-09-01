# BlackHole

**English** | [简体中文](README.zh-CN.md)

A real-time black hole visualization for macOS. The ray-tracing stage runs in a Metal compute shader, while OpenGL handles the window, the three-dimensional perspective grid, and final image compositing.

## Features

- Schwarzschild black hole and event horizon
- Accretion disk traced along curved geodesics
- A sphere whose gravitationally lensed image can stretch into multiple arcs
- A real three-dimensional wireframe grid rendered independently from the ray tracer
- Eight-frame temporal anti-aliasing and material-aware FXAA

## Rendering Architecture

Metal traces the black hole, accretion disk, and sphere at `400 × 300`. It produces both an RGBA image and a material mask. OpenGL upscales the result to an `800 × 600` window, applies material-specific edge treatment, and composites it over the perspective grid.

The main visual and simulation constants live in `Scene.hpp`, including the integration step count, step length, escape radius, accretion disk radii, and grid dimensions.

## Project Structure

```text
BlackHole.mm           Application entry point and render loop
Scene.hpp/.cpp         Camera, black hole, objects, and scene constants
Engine.hpp/.cpp        GLFW window, OpenGL compositor, and 3D grid
MetalRayTracer.hpp/.mm Metal compute shader and geodesic ray tracing
CMakeLists.txt         CMake build configuration
run.sh                 Standalone clang++ build-and-run script
GPUinfoFile/           GPU information utility sources
Draft/                 Earlier experimental implementation
```

## Requirements

- A Metal-capable Mac
- Xcode or Xcode Command Line Tools
- Homebrew
- A C++17 compiler

Install the required packages:

```bash
brew install cmake glfw glew glm
```

## Quick Start

`run.sh` invokes `clang++` directly, compiles all current modules into `BlackHole` in the project root, and launches the application. This path does not invoke CMake.

```bash
chmod +x run.sh
./run.sh
```

The script resolves its own directory and the Homebrew prefix, so it can be launched from any working directory.

## Build with CMake

```bash
cmake -S . -B build
cmake --build build
./build/BlackHole
```

CMake places its output in `build/`. This workflow is useful for IDE integration and detailed build diagnostics.

## Controls

- Left mouse drag: orbit around the black hole
- `Shift` + left mouse drag: pan the camera target
- Mouse wheel: zoom in or out

Camera movement resets temporal accumulation immediately. Once the camera stops, the image converges again over eight frames.
