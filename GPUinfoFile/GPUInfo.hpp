#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace xm::device
{
    struct GPUReport
    {
        std::string name;
        float load = 0.0f;
        float localUsedSpace = 0.0f;
        float localMaxSpace = 0.0f;
        float sharedUsedSpace = 0.0f;
        float sharedMaxSpace = 0.0f;
        float totalMemory = 0.0f;
    };

    class GPUInfo
    {
        public:
        std::vector<GPUReport>Collect()const;
    };
}