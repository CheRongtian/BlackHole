#include "Engine.hpp"
#include "MetalRayTracer.hpp"
#include "Scene.hpp"

#import <Foundation/Foundation.h>

#include <chrono>
#include <iostream>
#include <vector>

using Clock = std::chrono::steady_clock;

int main()
{
    @autoreleasepool
    {
        Engine engine;
        setupCameraCallbacks(engine.window);

        std::vector<unsigned char> pixels(
            METAL_RENDER_WIDTH * METAL_RENDER_HEIGHT * 4,
            0);
        std::vector<unsigned char> materialPixels(
            METAL_RENDER_WIDTH * METAL_RENDER_HEIGHT * 4,
            0);
        MetalRayTracer metalRayTracer;

        int frameCount = 0;
        double lastPrintTime = std::chrono::duration<double>(
            Clock::now().time_since_epoch()).count();

        while(!glfwWindowShouldClose(engine.window))
        {
            metalRayTracer.render(
                pixels,
                materialPixels,
                engine.WIDTH,
                engine.HEIGHT);
            engine.renderScene(pixels, materialPixels, SagA.r_s);

            frameCount++;
            double currentTime = std::chrono::duration<double>(
                Clock::now().time_since_epoch()).count();
            double elapsed = currentTime - lastPrintTime;

            if(elapsed >= 1.0)
            {
                double fps = static_cast<double>(frameCount) / elapsed;
                std::cout << "Metal FPS: " << fps << std::endl;

                frameCount = 0;
                lastPrintTime = currentTime;
            }
        }
    }

    return 0;
}
