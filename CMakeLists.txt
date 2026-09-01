cmake_minimum_required(VERSION 3.15)

project(BlackHoleProject LANGUAGES CXX OBJCXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_OBJCXX_STANDARD 17)
set(CMAKE_OBJCXX_STANDARD_REQUIRED ON)
set(CMAKE_OBJCXX_EXTENSIONS OFF)

if(NOT APPLE)
    message(FATAL_ERROR "BlackHole requires macOS, Metal, and Cocoa")
endif()

if(EXISTS "/opt/homebrew")
    list(APPEND CMAKE_PREFIX_PATH "/opt/homebrew")
endif()

find_package(OpenGL REQUIRED)
find_package(glfw3 CONFIG REQUIRED)
find_package(glm CONFIG REQUIRED)

find_path(BLACKHOLE_GLEW_INCLUDE_DIR NAMES GL/glew.h)
find_library(BLACKHOLE_GLEW_LIBRARY NAMES GLEW)

if(NOT BLACKHOLE_GLEW_INCLUDE_DIR OR NOT BLACKHOLE_GLEW_LIBRARY)
    message(FATAL_ERROR "GLEW headers and library are required")
endif()

find_library(COCOA_FRAMEWORK Cocoa)
find_library(COREVIDEO_FRAMEWORK CoreVideo)
find_library(FOUNDATION_FRAMEWORK Foundation)
find_library(IOKIT_FRAMEWORK IOKit)
find_library(METAL_FRAMEWORK Metal)

add_executable(
    BlackHole
    BlackHole.mm
    Scene.cpp
    Engine.cpp
    MetalRayTracer.mm
)

target_include_directories(
    BlackHole
    PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${BLACKHOLE_GLEW_INCLUDE_DIR}
)

target_link_libraries(
    BlackHole
    PRIVATE
    glfw
    ${BLACKHOLE_GLEW_LIBRARY}
    glm::glm
    OpenGL::GL
    ${COCOA_FRAMEWORK}
    ${COREVIDEO_FRAMEWORK}
    ${FOUNDATION_FRAMEWORK}
    ${IOKIT_FRAMEWORK}
    ${METAL_FRAMEWORK}
)

target_compile_options(
    BlackHole
    PRIVATE
    $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>
)

if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
    target_compile_options(
        BlackHole
        PRIVATE
        $<$<COMPILE_LANGUAGE:CXX>:-Wall>
        $<$<COMPILE_LANGUAGE:CXX>:-Wextra>
        $<$<COMPILE_LANGUAGE:CXX>:-Wpedantic>
        $<$<COMPILE_LANGUAGE:OBJCXX>:-Wall>
        $<$<COMPILE_LANGUAGE:OBJCXX>:-Wextra>
    )
endif()
