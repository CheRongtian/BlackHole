#include "MetalRayTracer.hpp"

#import <Foundation/Foundation.h>

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <iostream>
#include <vector>

struct MetalPixelRGBA
{
    unsigned char r;
    unsigned char g;
    unsigned char b;
    unsigned char a;
};

static_assert(sizeof(MetalPixelRGBA) == 4, "MetalPixelRGBA must be exactly 4 bytes");

struct MetalRaytraceParams
{
    float cameraPosX;
    float cameraPosY;
    float cameraPosZ;
    float pad0;

    float targetX;
    float targetY;
    float targetZ;
    float pad1;

    float fovYRadians;
    float aspect;
    std::uint32_t renderWidth;
    std::uint32_t renderHeight;

    std::uint32_t maxSteps;
    float dLambda;
    float escapeR;
    float horizonR;

    float diskR1;
    float diskR2;
    std::uint32_t objectCount;
    float pad2;

    std::uint32_t sampleIndex;
    float jitterX;
    float jitterY;
    float pad3;
};

static_assert(sizeof(MetalRaytraceParams) == 96, "MetalRaytraceParams must match the Metal layout");

static const char* METAL_RAYTRACE_SHADER = R"METAL(
#include <metal_stdlib>
using namespace metal;

constant uint TEMPORAL_SAMPLE_COUNT = 8;

struct Params
{
    float cameraPosX;
    float cameraPosY;
    float cameraPosZ;
    float pad0;

    float targetX;
    float targetY;
    float targetZ;
    float pad1;

    float fovYRadians;
    float aspect;
    uint renderWidth;
    uint renderHeight;

    uint maxSteps;
    float dLambda;
    float escapeR;
    float horizonR;

    float diskR1;
    float diskR2;
    uint objectCount;
    float pad2;

    uint sampleIndex;
    float jitterX;
    float jitterY;
    float pad3;
};

struct Object
{
    float4 posRadius;
    float4 color;
    float mass;
    float3 velocity;
};

struct RayState
{
    float3 q;
    float3 v;
    float E;
};

struct Derivative
{
    float3 dq;
    float3 dv;
};

float safeSin(float x)
{
    float s = sin(x);

    if(fabs(s) < 1e-5f)
        return (s < 0.0f) ? -1e-5f : 1e-5f;

    return s;
}

float3 rayCartesian(RayState ray)
{
    float r = ray.q.x;
    float theta = ray.q.y;
    float phi = ray.q.z;

    return float3(
        r * sin(theta) * cos(phi),
        r * sin(theta) * sin(phi),
        r * cos(theta));
}

bool interceptDisk(float3 oldPos, float3 newPos, constant Params& p, thread float& radiusAtHit)
{
    bool crossed = oldPos.y * newPos.y < 0.0f;
    if(!crossed) return false;

    float denominator = newPos.y - oldPos.y;
    if(fabs(denominator) < 1e-8f) return false;

    float crossingT = clamp(-oldPos.y / denominator, 0.0f, 1.0f);
    float3 crossingPoint = mix(oldPos, newPos, crossingT);
    float diskRadius = length(float2(crossingPoint.x, crossingPoint.z));

    if(diskRadius < p.diskR1 || diskRadius > p.diskR2) return false;

    radiusAtHit = diskRadius;
    return true;
}

bool interceptObject(
    float3 oldPos,
    float3 newPos,
    constant Object* objects,
    uint objectCount,
    thread float4& objectColor,
    thread float3& hitCenter,
    thread float& hitRadius,
    thread float3& hitPoint)
{
    float3 segment = newPos - oldPos;
    float a = dot(segment, segment);
    if(a < 1e-12f) return false;

    bool foundHit = false;
    float closestT = 2.0f;

    for(uint objectIndex = 0; objectIndex < objectCount; ++objectIndex)
    {
        float3 center = objects[objectIndex].posRadius.xyz;
        float radius = objects[objectIndex].posRadius.w;
        float3 offset = oldPos - center;
        float b = 2.0f * dot(offset, segment);
        float c = dot(offset, offset) - radius * radius;
        float discriminant = b * b - 4.0f * a * c;

        if(discriminant < 0.0f) continue;

        float squareRoot = sqrt(discriminant);
        float inverseDenominator = 0.5f / a;
        float nearT = (-b - squareRoot) * inverseDenominator;
        float farT = (-b + squareRoot) * inverseDenominator;
        float candidateT = nearT;

        if(candidateT < 0.0f || candidateT > 1.0f) candidateT = farT;
        if(candidateT < 0.0f || candidateT > 1.0f || candidateT >= closestT) continue;

        closestT = candidateT;
        objectColor = objects[objectIndex].color;
        hitCenter = center;
        hitRadius = radius;
        hitPoint = oldPos + candidateT * segment;
        foundHit = true;
    }

    return foundHit;
}

RayState makeRay(float3 pos, float3 dir, constant Params& p)
{
    RayState ray;

    float r = length(pos);
    float phi = atan2(pos.y, pos.x);
    float theta = acos(clamp(pos.z / r, -1.0f, 1.0f));

    float sinTheta = safeSin(theta);
    float cosTheta = cos(theta);
    float sinPhi = sin(phi);
    float cosPhi = cos(phi);

    float dr = dot(pos, dir) / r;
    float dtheta =
        (dir.x*cosTheta*cosPhi + dir.y*cosTheta*sinPhi - dir.z*sinTheta) / r;
    float dphi = (-dir.x*sinPhi + dir.y*cosPhi) / (r*sinTheta);
    float f = max(1.0f - p.horizonR/r, 1e-5f);
    float angular = dtheta*dtheta + sinTheta*sinTheta*dphi*dphi;
    float E2 = dr*dr + f*r*r*angular;

    ray.q = float3(r, theta, phi);
    ray.v = float3(dr, dtheta, dphi);
    ray.E = sqrt(max(E2, 0.0f));
    return ray;
}

Derivative geodesicRHS(RayState ray, constant Params& p)
{
    Derivative out;

    float r = max(ray.q.x, p.horizonR * 1.00001f);
    float theta = ray.q.y;
    float dr = ray.v.x;
    float dtheta = ray.v.y;
    float dphi = ray.v.z;
    float sinTheta = safeSin(theta);
    float cosTheta = cos(theta);
    float f = max(1.0f - p.horizonR / r, 1e-5f);
    float dt_dlambda = ray.E / f;

    out.dq = ray.v;

    float d2r =
        -(p.horizonR/(2.0f*r*r))*f*dt_dlambda*dt_dlambda +
        (p.horizonR/(2.0f*r*r*f))*dr*dr +
        r*f*(dtheta*dtheta + sinTheta*sinTheta*dphi*dphi);
    float d2theta = -(2.0f/r)*dr*dtheta + sinTheta*cosTheta*dphi*dphi;
    float d2phi = -(2.0f/r)*dr*dphi - 2.0f*cosTheta/sinTheta*dtheta*dphi;

    out.dv = float3(d2r, d2theta, d2phi);
    return out;
}

RayState addState(RayState base, Derivative k, float factor)
{
    RayState out = base;
    out.q = base.q + factor*k.dq;
    out.v = base.v + factor*k.dv;
    return out;
}

void rk4Step(thread RayState& ray, float h, constant Params& p)
{
    Derivative k1 = geodesicRHS(ray, p);
    Derivative k2 = geodesicRHS(addState(ray, k1, h * 0.5f), p);
    Derivative k3 = geodesicRHS(addState(ray, k2, h * 0.5f), p);
    Derivative k4 = geodesicRHS(addState(ray, k3, h), p);

    ray.q += (h/6.0f)*(k1.dq + 2.0f*k2.dq + 2.0f*k3.dq + k4.dq);
    ray.v += (h/6.0f)*(k1.dv + 2.0f*k2.dv + 2.0f*k3.dv + k4.dv);
}

kernel void raytraceKernel(
    device uchar4* output [[buffer(0)]],
    constant Params& p [[buffer(1)]],
    constant Object* objects [[buffer(2)]],
    device float4* accumulation [[buffer(3)]],
    device uchar4* materialOutput [[buffer(4)]],
    device float4* materialAccumulation [[buffer(5)]],
    uint2 gid [[thread_position_in_grid]])
{
    if(gid.x >= p.renderWidth || gid.y >= p.renderHeight) return;
    if(p.sampleIndex >= TEMPORAL_SAMPLE_COUNT) return;

    float3 cameraPos = float3(p.cameraPosX, p.cameraPosY, p.cameraPosZ);
    float3 target = float3(p.targetX, p.targetY, p.targetZ);
    float3 forward = normalize(target - cameraPos);
    float3 worldUp = float3(0.0f, 1.0f, 0.0f);
    float3 right = cross(forward, worldUp);

    if(dot(right, right) < 1e-8f)
        right = float3(0.0f, 0.0f, 1.0f);
    else
        right = normalize(right);

    float3 up = normalize(cross(right, forward));
    float tanHalfFov = tan(p.fovYRadians * 0.5f);
    float sampleX = float(gid.x) + 0.5f + p.jitterX;
    float sampleY = float(gid.y) + 0.5f + p.jitterY;
    float u = (2.0f*(sampleX/float(p.renderWidth)) - 1.0f) * p.aspect * tanHalfFov;
    float v = (1.0f - 2.0f*(sampleY/float(p.renderHeight))) * tanHalfFov;
    float3 dir = normalize(u*right + v*up + forward);

    RayState ray = makeRay(cameraPos, dir, p);
    bool captured = false;
    bool diskHit = false;
    bool objectHit = false;
    float diskRadiusAtHit = 0.0f;
    float4 objectColor = float4(0.0f);
    float3 hitCenter = float3(0.0f);
    float hitRadius = 0.0f;
    float3 objectHitPoint = float3(0.0f);

    for(uint i = 0; i < p.maxSteps; ++i)
    {
        if(ray.q.x <= p.horizonR * 1.01f)
        {
            captured = true;
            break;
        }

        if(ray.q.x > p.escapeR && ray.v.x > 0.0f) break;

        float previousR = ray.q.x;
        float3 oldPos = rayCartesian(ray);
        rk4Step(ray, p.dLambda, p);

        if(!all(isfinite(ray.q)) || !all(isfinite(ray.v)))
        {
            if(previousR <= p.horizonR * 1.02f) captured = true;
            break;
        }

        float3 newPos = rayCartesian(ray);

        if(interceptObject(
            oldPos,
            newPos,
            objects,
            p.objectCount,
            objectColor,
            hitCenter,
            hitRadius,
            objectHitPoint))
        {
            objectHit = true;
            break;
        }

        if(interceptDisk(oldPos, newPos, p, diskRadiusAtHit))
        {
            diskHit = true;
            break;
        }

        if(ray.q.x <= p.horizonR * 1.01f)
        {
            captured = true;
            break;
        }
    }

    uint index = gid.y*p.renderWidth + gid.x;
    float4 currentColor = float4(0.0f);
    float4 currentMaterial = float4(0.0f);

    if(objectHit)
    {
        float3 normal = normalize((objectHitPoint - hitCenter) / max(hitRadius, 1e-6f));
        float3 lightDirection = normalize(float3(-0.35f, 0.80f, 0.48f));
        float3 viewDirection = normalize(cameraPos - objectHitPoint);
        float diffuse = max(dot(normal, lightDirection), 0.0f);
        float3 reflectedLight = reflect(-lightDirection, normal);
        float specular =
            pow(max(dot(reflectedLight, viewDirection), 0.0f), 24.0f) * 0.30f;
        float3 shadedColor = clamp(
            objectColor.rgb * (0.22f + 0.78f * diffuse) + specular,
            0.0f,
            1.0f);
        float objectAlpha = clamp(objectColor.a, 0.0f, 1.0f);

        currentColor = float4(shadedColor * objectAlpha, objectAlpha);
        currentMaterial.b = 1.0f;
    }
    else if(diskHit)
    {
        float diskT = clamp(
            (diskRadiusAtHit - p.diskR1) / (p.diskR2 - p.diskR1),
            0.0f,
            1.0f);
        float3 innerColor = float3(1.0f, 0.15f, 0.01f);
        float3 outerColor = float3(1.0f, 0.72f, 0.10f);
        float3 diskColor = mix(innerColor, outerColor, diskT);

        currentColor = float4(diskColor, 1.0f);
        currentMaterial.g = 1.0f;
    }
    else if(captured)
    {
        currentColor = float4(0.0f, 0.0f, 0.0f, 1.0f);
        currentMaterial.r = 1.0f;
    }

    float4 accumulatedColor = currentColor;
    float4 accumulatedMaterial = currentMaterial;

    if(p.sampleIndex > 0)
    {
        float sampleWeight = 1.0f / float(p.sampleIndex + 1);
        accumulatedColor = mix(accumulation[index], currentColor, sampleWeight);
        accumulatedMaterial = mix(materialAccumulation[index], currentMaterial, sampleWeight);
    }

    accumulatedColor = clamp(accumulatedColor, 0.0f, 1.0f);
    accumulatedMaterial = clamp(accumulatedMaterial, 0.0f, 1.0f);
    accumulation[index] = accumulatedColor;
    materialAccumulation[index] = accumulatedMaterial;
    output[index] = uchar4(
        uchar(accumulatedColor.r * 255.0f + 0.5f),
        uchar(accumulatedColor.g * 255.0f + 0.5f),
        uchar(accumulatedColor.b * 255.0f + 0.5f),
        uchar(accumulatedColor.a * 255.0f + 0.5f));
    materialOutput[index] = uchar4(
        uchar(accumulatedMaterial.r * 255.0f + 0.5f),
        uchar(accumulatedMaterial.g * 255.0f + 0.5f),
        uchar(accumulatedMaterial.b * 255.0f + 0.5f),
        0);
}
)METAL";

MetalRayTracer::MetalRayTracer()
{
    device = MTLCreateSystemDefaultDevice();

    if(!device)
    {
        std::cerr << "Metal device was not found.\n";
        std::exit(EXIT_FAILURE);
    }

    commandQueue = [device newCommandQueue];

    if(!commandQueue)
    {
        std::cerr << "Failed to create Metal command queue.\n";
        std::exit(EXIT_FAILURE);
    }

    NSString* source = [NSString stringWithUTF8String:METAL_RAYTRACE_SHADER];
    MTLCompileOptions* options = [[MTLCompileOptions alloc] init];
    options.mathMode = MTLMathModeFast;

    NSError* error = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:source options:options error:&error];

    if(!library)
    {
        std::cerr << "Metal shader compilation failed:\n"
                  << [[error localizedDescription] UTF8String] << "\n";
        std::exit(EXIT_FAILURE);
    }

    id<MTLFunction> function = [library newFunctionWithName:@"raytraceKernel"];

    if(!function)
    {
        std::cerr << "Failed to find raytraceKernel in Metal library.\n";
        std::exit(EXIT_FAILURE);
    }

    pipeline = [device newComputePipelineStateWithFunction:function error:&error];

    if(!pipeline)
    {
        std::cerr << "Failed to create Metal compute pipeline:\n"
                  << [[error localizedDescription] UTF8String] << "\n";
        std::exit(EXIT_FAILURE);
    }

    outputBuffer = [device
        newBufferWithLength:METAL_RENDER_WIDTH * METAL_RENDER_HEIGHT * sizeof(MetalPixelRGBA)
        options:MTLResourceStorageModeShared];
    accumulationBuffer = [device
        newBufferWithLength:METAL_RENDER_WIDTH * METAL_RENDER_HEIGHT * sizeof(float) * 4
        options:MTLResourceStorageModePrivate];
    materialOutputBuffer = [device
        newBufferWithLength:METAL_RENDER_WIDTH * METAL_RENDER_HEIGHT * sizeof(MetalPixelRGBA)
        options:MTLResourceStorageModeShared];
    materialAccumulationBuffer = [device
        newBufferWithLength:METAL_RENDER_WIDTH * METAL_RENDER_HEIGHT * sizeof(float) * 4
        options:MTLResourceStorageModePrivate];

    if(!outputBuffer || !accumulationBuffer ||
       !materialOutputBuffer || !materialAccumulationBuffer)
    {
        std::cerr << "Failed to create Metal ray-tracing buffers.\n";
        std::exit(EXIT_FAILURE);
    }

    std::cout << "Metal GPU: " << [[device name] UTF8String] << "\n";
    std::cout << "Metal raytrace resolution: "
              << METAL_RENDER_WIDTH << " x " << METAL_RENDER_HEIGHT << "\n";
    std::cout << "Metal MAX_STEPS: " << METAL_MAX_STEPS << "\n";
    std::cout << "Accretion disk: "
              << METAL_DISK_R1_RS << " r_s -> " << METAL_DISK_R2_RS << " r_s\n";
    std::cout << "Temporal anti-aliasing: "
              << TEMPORAL_SAMPLE_COUNT << " samples while camera is still\n";
}

void MetalRayTracer::render(
    std::vector<unsigned char>& pixels,
    std::vector<unsigned char>& materialPixels,
    int displayWidth,
    int displayHeight)
{
    @autoreleasepool
    {
        const bool cameraChanged =
            !hasPreviousCamera ||
            glm::length(camera.pos - previousCameraPos) > 1.0e4f ||
            glm::length(camera.target - previousCameraTarget) > 1.0e4f ||
            std::fabs(camera.fovY - previousCameraFovY) > 1.0e-5f;

        if(cameraChanged)
        {
            accumulatedSampleCount = 0;
            previousCameraPos = camera.pos;
            previousCameraTarget = camera.target;
            previousCameraFovY = camera.fovY;
            hasPreviousCamera = true;
        }

        static constexpr float jitterOffsets[TEMPORAL_SAMPLE_COUNT][2] =
        {
            { 0.000f,  0.000f},
            {-0.250f, -0.250f},
            { 0.250f,  0.250f},
            { 0.250f, -0.250f},
            {-0.250f,  0.250f},
            {-0.375f,  0.000f},
            { 0.375f,  0.000f},
            { 0.000f,  0.000f}
        };

        std::uint32_t jitterIndex =
            std::min(accumulatedSampleCount, TEMPORAL_SAMPLE_COUNT - 1);
        MetalRaytraceParams params{};
        const double inverseSchwarzschildRadius = 1.0 / SagA.r_s;

        params.cameraPosX = static_cast<float>(camera.pos.x * inverseSchwarzschildRadius);
        params.cameraPosY = static_cast<float>(camera.pos.y * inverseSchwarzschildRadius);
        params.cameraPosZ = static_cast<float>(camera.pos.z * inverseSchwarzschildRadius);
        params.targetX = static_cast<float>(camera.target.x * inverseSchwarzschildRadius);
        params.targetY = static_cast<float>(camera.target.y * inverseSchwarzschildRadius);
        params.targetZ = static_cast<float>(camera.target.z * inverseSchwarzschildRadius);
        params.fovYRadians = glm::radians(camera.fovY);
        params.aspect = static_cast<float>(displayWidth) / static_cast<float>(displayHeight);
        params.renderWidth = METAL_RENDER_WIDTH;
        params.renderHeight = METAL_RENDER_HEIGHT;
        params.maxSteps = METAL_MAX_STEPS;
        params.dLambda =
            static_cast<float>(METAL_D_LAMBDA_METERS * inverseSchwarzschildRadius);
        params.escapeR =
            static_cast<float>(METAL_ESCAPE_R_METERS * inverseSchwarzschildRadius);
        params.horizonR = 1.0f;
        params.diskR1 = METAL_DISK_R1_RS;
        params.diskR2 = METAL_DISK_R2_RS;
        params.objectCount = static_cast<std::uint32_t>(objects.size());
        params.sampleIndex = accumulatedSampleCount;
        params.jitterX = jitterOffsets[jitterIndex][0];
        params.jitterY = jitterOffsets[jitterIndex][1];

        std::vector<Object> normalizedObjects = objects;

        for(Object& object : normalizedObjects)
        {
            object.posRadius.x =
                static_cast<float>(object.posRadius.x * inverseSchwarzschildRadius);
            object.posRadius.y =
                static_cast<float>(object.posRadius.y * inverseSchwarzschildRadius);
            object.posRadius.z =
                static_cast<float>(object.posRadius.z * inverseSchwarzschildRadius);
            object.posRadius.w =
                static_cast<float>(object.posRadius.w * inverseSchwarzschildRadius);
        }

        id<MTLCommandBuffer> commandBuffer = [commandQueue commandBuffer];
        id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];

        [encoder setComputePipelineState:pipeline];
        [encoder setBuffer:outputBuffer offset:0 atIndex:0];
        [encoder setBytes:&params length:sizeof(params) atIndex:1];
        [encoder
            setBytes:normalizedObjects.data()
            length:normalizedObjects.size() * sizeof(Object)
            atIndex:2];
        [encoder setBuffer:accumulationBuffer offset:0 atIndex:3];
        [encoder setBuffer:materialOutputBuffer offset:0 atIndex:4];
        [encoder setBuffer:materialAccumulationBuffer offset:0 atIndex:5];

        MTLSize gridSize = MTLSizeMake(METAL_RENDER_WIDTH, METAL_RENDER_HEIGHT, 1);
        NSUInteger threadWidth = pipeline.threadExecutionWidth;
        NSUInteger maxThreads = pipeline.maxTotalThreadsPerThreadgroup;
        NSUInteger threadHeight = std::max<NSUInteger>(
            1,
            std::min<NSUInteger>(8, maxThreads / threadWidth));
        MTLSize threadgroupSize = MTLSizeMake(threadWidth, threadHeight, 1);

        [encoder dispatchThreads:gridSize threadsPerThreadgroup:threadgroupSize];
        [encoder endEncoding];
        [commandBuffer commit];
        [commandBuffer waitUntilCompleted];

        if(commandBuffer.status == MTLCommandBufferStatusError)
        {
            std::cerr << "Metal command buffer failed:\n"
                      << [[[commandBuffer error] localizedDescription] UTF8String]
                      << "\n";
            return;
        }

        if(accumulatedSampleCount < TEMPORAL_SAMPLE_COUNT)
            ++accumulatedSampleCount;

        const MetalPixelRGBA* gpuPixels =
            static_cast<const MetalPixelRGBA*>([outputBuffer contents]);
        const MetalPixelRGBA* gpuMaterialPixels =
            static_cast<const MetalPixelRGBA*>([materialOutputBuffer contents]);

        for(int y = 0; y < METAL_RENDER_HEIGHT; ++y)
        {
            int sourceY = METAL_RENDER_HEIGHT - 1 - y;

            for(int x = 0; x < METAL_RENDER_WIDTH; ++x)
            {
                int sourceIndex = sourceY * METAL_RENDER_WIDTH + x;
                int destinationIndex = (y * METAL_RENDER_WIDTH + x) * 4;
                const MetalPixelRGBA& sourcePixel = gpuPixels[sourceIndex];
                const MetalPixelRGBA& sourceMaterial = gpuMaterialPixels[sourceIndex];

                pixels[destinationIndex + 0] = sourcePixel.r;
                pixels[destinationIndex + 1] = sourcePixel.g;
                pixels[destinationIndex + 2] = sourcePixel.b;
                pixels[destinationIndex + 3] = sourcePixel.a;
                materialPixels[destinationIndex + 0] = sourceMaterial.r;
                materialPixels[destinationIndex + 1] = sourceMaterial.g;
                materialPixels[destinationIndex + 2] = sourceMaterial.b;
                materialPixels[destinationIndex + 3] = sourceMaterial.a;
            }
        }
    }
}
