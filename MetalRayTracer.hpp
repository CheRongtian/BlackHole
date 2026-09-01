#ifndef BLACK_HOLE_METAL_RAY_TRACER_HPP
#define BLACK_HOLE_METAL_RAY_TRACER_HPP

#include "Scene.hpp"

#import <Metal/Metal.h>

#include <cstdint>
#include <vector>

class MetalRayTracer
{
public:
    MetalRayTracer();

    MetalRayTracer(const MetalRayTracer&) = delete;
    MetalRayTracer& operator=(const MetalRayTracer&) = delete;

    void render(
        std::vector<unsigned char>& pixels,
        std::vector<unsigned char>& materialPixels,
        int displayWidth,
        int displayHeight);

private:
    id<MTLDevice> device = nil;
    id<MTLCommandQueue> commandQueue = nil;
    id<MTLComputePipelineState> pipeline = nil;
    id<MTLBuffer> outputBuffer = nil;
    id<MTLBuffer> accumulationBuffer = nil;
    id<MTLBuffer> materialOutputBuffer = nil;
    id<MTLBuffer> materialAccumulationBuffer = nil;

    std::uint32_t accumulatedSampleCount = 0;
    bool hasPreviousCamera = false;
    glm::vec3 previousCameraPos = glm::vec3(0.0f);
    glm::vec3 previousCameraTarget = glm::vec3(0.0f);
    float previousCameraFovY = 0.0f;
};

#endif
