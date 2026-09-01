#include "GPUInfo.hpp"
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <vector>

namespace xm::device 
{
    std::vector<GPUReport> GPUInfo::Collect() const 
    {
        std::vector<GPUReport> out;
    
        // 获取系统中所有支持 Metal 的 GPU 设备
        NSArray<id<MTLDevice>> *devices = MTLCopyAllDevices();
    
        for(id<MTLDevice> device in devices) 
        {
            GPUReport report{};
        
            // 1. 获取 GPU 名称
            report.name = [[device name] UTF8String];
        
            // 2. 获取显存空间 (单位：字节)
            // 注意：苹果 M 系列芯片使用的是统一内存 (Unified Memory)。
            // recommendedMaxWorkingSetSize 表示系统推荐分配给 GPU 的最大内存。
            report.totalMemory = static_cast<float>([device recommendedMaxWorkingSetSize]);
            report.localMaxSpace = report.totalMemory;
        
            // currentAllocatedSize 返回的是当前进程在 GPU 上分配的显存。
            // （macOS 对于公开获取全局系统的真实 VRAM 占用限制很严，这里以当前进程占位）
            report.localUsedSpace = static_cast<float>([device currentAllocatedSize]);
        
            report.sharedMaxSpace = 0.0f;
            report.sharedUsedSpace = 0.0f;
        
            // 3. 负载 (Load)
            // 坦率地说，macOS 没有提供公开的 API 来直接读取全局 GPU 的百分比负载。
            // 任务管理器(活动监视器)使用的是底层的 IOKit 私有 API，强行调用可能会导致应用无法上架或崩溃。
            // 这里暂时置为 0，这在跨平台开发中是一个常见的妥协。
            report.load = 0.0f;
        
            out.push_back(report);
        }
        return out;
    }
}