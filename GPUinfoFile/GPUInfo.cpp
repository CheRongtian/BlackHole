#include "GPUInfo.h"
#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <Windows.h>
#include <combaseapi.h>
#include <dxgi1_4.h>
#include <pdh.h>
#include <pdhmsg.h>
#endif
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cctype>
#include <cstdio>
#include <cstring>
#include <thread>
#include <unordered_map>
#include <vector>
#include <sstream>

namespace xm::device 
{
    struct GpuAdapterMetrics 
    {
        std::string name;
        std::string kind;
        std::uint32_t vendorId = 0;
        std::uint32_t deviceId = 0;
        std::uint64_t localBudgetBytes = 0;
        std::uint64_t localUsageBytes = 0;
        std::uint64_t sharedBudgetBytes = 0;
        std::uint64_t sharedUsageBytes = 0;
        double utilizationPercent = 0.0;
    };

    struct GpuMetricsSnapshot 
    {
        bool supported = false;
        std::string message;
        std::string debugDetails;
        std::vector<GpuAdapterMetrics> adapters;
    };

    std::vector<GpuReport> snapshotToGpuReports(const GpuMetricsSnapshot& snapshot) 
    {
        std::vector<GpuReport> out;
        out.reserve(snapshot.adapters.size());
        for(const auto& adapter : snapshot.adapters) 
        {
            GpuReport report{};
            report.name = adapter.name;
            report.load = static_cast<float>(adapter.utilizationPercent);
            report.localUsedSpace = static_cast<float>(adapter.localUsageBytes);
            report.localMaxSpace = static_cast<float>(adapter.localBudgetBytes);
            report.sharedUsedSpace = static_cast<float>(adapter.sharedUsageBytes);
            report.sharedMaxSpace = static_cast<float>(adapter.sharedBudgetBytes);
            report.totalMemory = static_cast<float>(adapter.localBudgetBytes + adapter.sharedBudgetBytes);
            out.push_back(std::move(report));
        }
        return out;
    }

    namespace 
    {
        #ifdef _WIN32
        std::string wideToUtf8(const wchar_t* text) 
        {
            if(text == nullptr || *text == L'\0') return {};
            const int need = WideCharToMultiByte(CP_UTF8, 0, text, -1, nullptr, 0, nullptr, nullptr);
            if(need <= 1) return {};
            std::string out(static_cast<std::size_t>(need), '\0');
            WideCharToMultiByte(CP_UTF8, 0, text, -1, out.data(), need, nullptr, nullptr);
            out.pop_back();
            return out;
        }

        std::string luidKey(const LUID luid) 
        {
            char buf[64] = {};
            std::snprintf(
                buf, sizeof(buf), "luid_0x%08x_0x%08x",
                static_cast<unsigned int>(luid.HighPart),
                static_cast<unsigned int>(luid.LowPart));
            return std::string(buf);
        }

        std::string toLowerCopy(std::string s) 
        {
            for(char& ch : s) 
            {
                const unsigned char uc = static_cast<unsigned char>(ch);
                ch = static_cast<char>(std::tolower(uc));
            }
            return s;
        }

        std::string classifyAdapter(const DXGI_ADAPTER_DESC1& desc) 
        {
            if((desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) != 0) return "software";
            if(desc.DedicatedVideoMemory > 0) return "discrete";
            if(desc.VendorId == 0x8086U) return "integrated";
            return "unknown";
        }

        std::string parseLuidKeyFromInstance(const char* instanceName) 
        {
            if(instanceName == nullptr) return {};
            const std::string text = toLowerCopy(std::string(instanceName));
            const std::string marker = "luid_0x";
            const std::size_t pos = text.find(marker);
            if(pos == std::string::npos) return {};
            std::size_t idx = pos + marker.size();
            const std::size_t highBegin = idx;
            while(idx < text.size() && std::isxdigit(static_cast<unsigned char>(text[idx])) != 0) ++idx;
            if(idx == highBegin || idx >= text.size() || text[idx] != '_') return {};
            ++idx;
            if(idx + 2 >= text.size() || text[idx] != '0' || text[idx + 1] != 'x') return {};
            idx += 2;
            const std::size_t lowBegin = idx;
            while(idx < text.size() && std::isxdigit(static_cast<unsigned char>(text[idx])) != 0) ++idx;
            if(idx == lowBegin) return {};
            return text.substr(pos, idx - pos);
        }

        void accumulateCounterArrayByLuid(const HCOUNTER counter, std::unordered_map<std::string, double>& outValues) 
        {
            DWORD bufferBytes = 0;
            DWORD itemCount = 0;
            PDH_STATUS code = PdhGetFormattedCounterArrayA(counter, PDH_FMT_DOUBLE, &bufferBytes, &itemCount, nullptr);
            if(code != PDH_MORE_DATA || bufferBytes == 0 || itemCount == 0) return;
            std::vector<unsigned char> buf(bufferBytes);
            auto* items = reinterpret_cast<PPDH_FMT_COUNTERVALUE_ITEM_A>(buf.data());
            code = PdhGetFormattedCounterArrayA(counter, PDH_FMT_DOUBLE, &bufferBytes, &itemCount, items);
            if(code != ERROR_SUCCESS) return;
            for(DWORD i = 0; i < itemCount; ++i) 
            {
                if(items[i].FmtValue.CStatus != ERROR_SUCCESS) continue;
                const std::string key = parseLuidKeyFromInstance(items[i].szName);
                if(key.empty())continue;
                outValues[key] += items[i].FmtValue.doubleValue;
            }
        }

        void maxCounterArrayByLuid(const HCOUNTER counter, std::unordered_map<std::string, double>& outValues) 
        {
            DWORD bufferBytes = 0;
            DWORD itemCount = 0;
            PDH_STATUS code = PdhGetFormattedCounterArrayA(counter, PDH_FMT_DOUBLE, &bufferBytes, &itemCount, nullptr);
            if(code != PDH_MORE_DATA || bufferBytes == 0 || itemCount == 0) return;
            std::vector<unsigned char> buf(bufferBytes);
            auto* items = reinterpret_cast<PPDH_FMT_COUNTERVALUE_ITEM_A>(buf.data());
            code = PdhGetFormattedCounterArrayA(counter, PDH_FMT_DOUBLE, &bufferBytes, &itemCount, items);
            if(code != ERROR_SUCCESS) return;
            for(DWORD i = 0; i < itemCount; ++i) 
            {
                if(items[i].FmtValue.CStatus != ERROR_SUCCESS) continue;
                const std::string key = parseLuidKeyFromInstance(items[i].szName);
                if(key.empty()) continue;
                const double v = items[i].FmtValue.doubleValue;
                auto it = outValues.find(key);
                if(it == outValues.end()) outValues[key] = v; 
                else it->second = std::max(it->second, v);
            }
        }

        std::string makePciDedupeGroupKey(const std::uint32_t vendorId, const std::uint32_t deviceId, const std::uint32_t subSysId) 
        {
            char buf[96] = {};
            std::snprintf(
                buf, sizeof(buf), "v%08x_d%08x_s%08x",
                static_cast<unsigned int>(vendorId),
                static_cast<unsigned int>(deviceId),
                static_cast<unsigned int>(subSysId));
            return std::string(buf);
        }

        bool isBetterGpuCandidate(const std::vector<GpuAdapterMetrics>& adapters, const std::size_t candidateIndex, const std::size_t currentBestIndex) 
        {
            const GpuAdapterMetrics& c = adapters[candidateIndex];
            const GpuAdapterMetrics& b = adapters[currentBestIndex];
            const std::uint64_t memC = c.localUsageBytes + c.sharedUsageBytes;
            const std::uint64_t memB = b.localUsageBytes + b.sharedUsageBytes;
            if(memC != memB) return memC > memB;
            const std::uint64_t utilC = static_cast<std::uint64_t>(std::lround(std::max(0.0, c.utilizationPercent) * 1000.0));
            const std::uint64_t utilB = static_cast<std::uint64_t>(std::lround(std::max(0.0, b.utilizationPercent) * 1000.0));
            if(utilC != utilB) return utilC > utilB;
            const unsigned bitsC = (c.sharedBudgetBytes > 0 ? 2u : 0u) | (c.localBudgetBytes > 0 ? 1u : 0u);
            const unsigned bitsB = (b.sharedBudgetBytes > 0 ? 2u : 0u) | (b.localBudgetBytes > 0 ? 1u : 0u);
            if(bitsC != bitsB) return bitsC > bitsB;
            return candidateIndex < currentBestIndex;
        }

        void dedupeDuplicatePciAdapters(GpuMetricsSnapshot& snapshot, std::vector<std::uint32_t>& adapterSubSysIds, std::ostringstream& debug) 
        {
            const std::size_t n = snapshot.adapters.size();
            if(n == 0 || adapterSubSysIds.size() != n) return;
            std::unordered_map<std::string, std::vector<std::size_t>> groups;
            groups.reserve(n);
            for(std::size_t i = 0; i < n; ++i) 
            {
                const GpuAdapterMetrics& row = snapshot.adapters[i];
                const std::string gkey = makePciDedupeGroupKey(row.vendorId, row.deviceId, adapterSubSysIds[i]);
                groups[gkey].push_back(i);
            }
            std::vector<bool> keep(n, true);
            for(auto& entry : groups) 
            {
                const std::string& gkey = entry.first;
                std::vector<std::size_t>& idxs = entry.second;
                if(idxs.size() < 2) continue;
                std::size_t best = idxs[0];
                for(std::size_t k = 1; k < idxs.size(); ++k) 
                {
                    const std::size_t j = idxs[k];
                    if(isBetterGpuCandidate(snapshot.adapters, j, best)) best = j;
                }
                for(const std::size_t j : idxs) 
                {
                    if(j != best) 
                    {
                        keep[j] = false;
                        debug << "dedupe_drop idx=" << j << " pci=" << gkey << " keep_idx=" << best << " reason=same_pci_identity_duplicate_adapter\n";
                    }
                }
            }
            std::vector<GpuAdapterMetrics> outAdapters;
            std::vector<std::uint32_t> outSubSys;
            outAdapters.reserve(n);
            outSubSys.reserve(n);
            for(std::size_t i = 0; i < n; ++i) 
            {
                if(keep[i]) 
                {
                    outAdapters.push_back(std::move(snapshot.adapters[i]));
                    outSubSys.push_back(adapterSubSysIds[i]);
                }
            }
            snapshot.adapters = std::move(outAdapters);
            adapterSubSysIds = std::move(outSubSys);
        }
    #endif
    }

    std::vector<GpuReport> GPUInfo::Collect() const 
    {
        #ifdef _WIN32
        GpuMetricsSnapshot snapshot;
        std::ostringstream debug;

        IDXGIFactory1* factory = nullptr;
        if(CreateDXGIFactory1(__uuidof(IDXGIFactory1), reinterpret_cast<void**>(&factory)) != S_OK || factory == nullptr) 
        {
            snapshot.supported = false;
            snapshot.message = "CreateDXGIFactory1 failed";
            (void)snapshot;
            return {};
        }

        std::vector<std::uint32_t> adapterSubSysIds;
        std::unordered_map<std::string, std::size_t> luidToIndex;

        for(UINT i = 0;; ++i) 
        {
            IDXGIAdapter1* adapter = nullptr;
            if(factory->EnumAdapters1(i, &adapter) != S_OK || adapter == nullptr) break;
            DXGI_ADAPTER_DESC1 desc{};
            if(adapter->GetDesc1(&desc) == S_OK) 
            {
                const bool isSoftware = (desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) != 0;
                const bool isMicrosoftAdapter = (desc.VendorId == 0x1414U);
                if(isSoftware || isMicrosoftAdapter) 
                {
                    adapter->Release();
                    continue;
                }

                bool hasOutput = false;
                IDXGIOutput* output = nullptr;
                if(adapter->EnumOutputs(0, &output) == S_OK && output != nullptr) 
                {
                    hasOutput = true;
                    output->Release();
                }

                const bool noMemoryFootprint = (desc.DedicatedVideoMemory == 0 && desc.SharedSystemMemory == 0);
                if(!hasOutput && noMemoryFootprint) 
                {
                    adapter->Release();
                    continue;
                }

                GpuAdapterMetrics row;
                row.name = wideToUtf8(desc.Description);
                row.kind = classifyAdapter(desc);
                row.vendorId = desc.VendorId;
                row.deviceId = desc.DeviceId;
                row.localBudgetBytes = desc.DedicatedVideoMemory;
                row.sharedBudgetBytes = desc.SharedSystemMemory;

                IDXGIAdapter3* adapter3 = nullptr;
                if(adapter->QueryInterface(__uuidof(IDXGIAdapter3), reinterpret_cast<void**>(&adapter3)) == S_OK && adapter3 != nullptr) 
                {
                    DXGI_QUERY_VIDEO_MEMORY_INFO localInfo{};
                    DXGI_QUERY_VIDEO_MEMORY_INFO sharedInfo{};
                    if(adapter3->QueryVideoMemoryInfo(0, DXGI_MEMORY_SEGMENT_GROUP_LOCAL, &localInfo) == S_OK) 
                    {
                        row.localBudgetBytes = localInfo.Budget;
                        row.localUsageBytes = localInfo.CurrentUsage;
                    }
                    if(adapter3->QueryVideoMemoryInfo(0, DXGI_MEMORY_SEGMENT_GROUP_NON_LOCAL, &sharedInfo) == S_OK) 
                    {
                        row.sharedBudgetBytes = sharedInfo.Budget;
                        row.sharedUsageBytes = sharedInfo.CurrentUsage;
                    }
                    adapter3->Release();
                }

                const std::string key = toLowerCopy(luidKey(desc.AdapterLuid));
                luidToIndex[key] = snapshot.adapters.size();
                snapshot.adapters.push_back(row);
                adapterSubSysIds.push_back(desc.SubSysId);
                debug << "adapter_map idx=" << (snapshot.adapters.size() - 1) << " key=" << key << " name=" << row.name << " vendor=0x" << std::hex << row.vendorId << " device=0x" << std::hex << row.deviceId << std::dec << "\n";
            }
            adapter->Release();
        }
        factory->Release();

        if(snapshot.adapters.empty()) 
        {
            snapshot.supported = false;
            snapshot.message = "No DXGI adapter found";
            (void)snapshot;
            return {};
        }

        HQUERY query = nullptr;
        if(PdhOpenQueryA(nullptr, 0, &query) != ERROR_SUCCESS) 
        {
            snapshot.supported = true;
            snapshot.message = "PDH query open failed, memory metrics only";
            return snapshotToGpuReports(snapshot);
        }

        HCOUNTER engineCounter = nullptr;
        HCOUNTER dedicatedUsageCounter = nullptr;
        HCOUNTER sharedUsageCounter = nullptr;
        HCOUNTER dedicatedLimitCounter = nullptr;
        HCOUNTER sharedLimitCounter = nullptr;

        const bool hasEngineCounter = PdhAddEnglishCounterA(query, "\\GPU Engine(*)\\Utilization Percentage", 0, &engineCounter) == ERROR_SUCCESS;
        const bool hasDedicatedUsageCounter = PdhAddEnglishCounterA(query, "\\GPU Adapter Memory(*)\\Dedicated Usage", 0, &dedicatedUsageCounter) == ERROR_SUCCESS;
        const bool hasSharedUsageCounter = PdhAddEnglishCounterA(query, "\\GPU Adapter Memory(*)\\Shared Usage", 0, &sharedUsageCounter) == ERROR_SUCCESS;
        const bool hasDedicatedLimitCounter = PdhAddEnglishCounterA(query, "\\GPU Adapter Memory(*)\\Dedicated Limit", 0, &dedicatedLimitCounter) == ERROR_SUCCESS;
        const bool hasSharedLimitCounter = PdhAddEnglishCounterA(query, "\\GPU Adapter Memory(*)\\Shared Limit", 0, &sharedLimitCounter) == ERROR_SUCCESS;

        if(!hasEngineCounter && !hasDedicatedUsageCounter && !hasSharedUsageCounter && !hasDedicatedLimitCounter && !hasSharedLimitCounter)
        {
            PdhCloseQuery(query);
            snapshot.supported = true;
            snapshot.message = "GPU PDH counters unavailable, memory metrics only";
            return snapshotToGpuReports(snapshot);
        }

        if(PdhCollectQueryData(query) != ERROR_SUCCESS) 
        {
            PdhCloseQuery(query);
            snapshot.supported = true;
            snapshot.message = "PDH first sample failed, memory metrics only";
            return snapshotToGpuReports(snapshot);
        }

        std::this_thread::sleep_for(std::chrono::milliseconds(120));

        if(PdhCollectQueryData(query) != ERROR_SUCCESS) 
        {
            PdhCloseQuery(query);
            snapshot.supported = true;
            snapshot.message = "PDH second sample failed, memory metrics only";
            return snapshotToGpuReports(snapshot);
        }

        std::unordered_map<std::string, double> utilByLuid;
        std::unordered_map<std::string, double> dedicatedUsageByLuid;
        std::unordered_map<std::string, double> sharedUsageByLuid;
        std::unordered_map<std::string, double> dedicatedLimitByLuid;
        std::unordered_map<std::string, double> sharedLimitByLuid;

        if(hasEngineCounter) maxCounterArrayByLuid(engineCounter, utilByLuid);
        if(hasDedicatedUsageCounter) accumulateCounterArrayByLuid(dedicatedUsageCounter, dedicatedUsageByLuid);
        if(hasSharedUsageCounter) accumulateCounterArrayByLuid(sharedUsageCounter, sharedUsageByLuid);
        if(hasDedicatedLimitCounter) accumulateCounterArrayByLuid(dedicatedLimitCounter, dedicatedLimitByLuid);
        if(hasSharedLimitCounter) accumulateCounterArrayByLuid(sharedLimitCounter, sharedLimitByLuid);

        for(const auto& [key, value] : utilByLuid) debug << "counter engine_max key=" << key << " value=" << value << "\n";
        for(const auto& [key, value] : dedicatedUsageByLuid) debug << "counter dedicated_usage key=" << key << " value=" << value << "\n";
        for(const auto& [key, value] : sharedUsageByLuid) debug << "counter shared_usage key=" << key << " value=" << value << "\n";
        for(const auto& [key, value] : dedicatedLimitByLuid) debug << "counter dedicated_limit key=" << key << " value=" << value << "\n";
        for(const auto& [key, value] : sharedLimitByLuid) debug << "counter shared_limit key=" << key << " value=" << value << "\n";
        for(const auto& [key, util] : utilByLuid) 
        {
            const auto it = luidToIndex.find(key);
            if(it == luidToIndex.end()) continue;
            const double clipped = std::max(0.0, std::min(100.0, util));
            snapshot.adapters[it->second].utilizationPercent = clipped;
        }

        for(const auto& [key, usage] : dedicatedUsageByLuid) 
        {
            const auto it = luidToIndex.find(key);
            if(it == luidToIndex.end()) continue;
            const double safeUsage = std::max(0.0, usage);
            snapshot.adapters[it->second].localUsageBytes = static_cast<std::uint64_t>(safeUsage);
        }

        for(const auto& [key, usage] : sharedUsageByLuid) 
        {
            const auto it = luidToIndex.find(key);
            if(it == luidToIndex.end()) continue;
            const double safeUsage = std::max(0.0, usage);
            snapshot.adapters[it->second].sharedUsageBytes = static_cast<std::uint64_t>(safeUsage);
        }

        for(const auto& [key, limit] : dedicatedLimitByLuid) 
        {
            const auto it = luidToIndex.find(key);
            if(it == luidToIndex.end()) continue;
            const double safeLimit = std::max(0.0, limit);
            if(safeLimit > 0.0) snapshot.adapters[it->second].localBudgetBytes = static_cast<std::uint64_t>(safeLimit);
        }

        for(const auto& [key, limit] : sharedLimitByLuid) 
        {
            const auto it = luidToIndex.find(key);
            if(it == luidToIndex.end()) continue;
            const double safeLimit = std::max(0.0, limit);
            if(safeLimit > 0.0) snapshot.adapters[it->second].sharedBudgetBytes = static_cast<std::uint64_t>(safeLimit);
        }

        for(auto& row : snapshot.adapters) 
        {
            if(row.localUsageBytes == 0 && row.sharedUsageBytes > 0 && row.localBudgetBytes > 0 && row.sharedBudgetBytes == 0) row.localUsageBytes = row.sharedUsageBytes;
            if(row.sharedBudgetBytes == 0 && row.localBudgetBytes > 0 && row.sharedUsageBytes > 0) row.sharedBudgetBytes = row.localBudgetBytes;
        }

        dedupeDuplicatePciAdapters(snapshot, adapterSubSysIds, debug);
        PdhCloseQuery(query);
        snapshot.supported = true;
        snapshot.debugDetails = debug.str();
        return snapshotToGpuReports(snapshot);

        #else
        return {};
        #endif
    }

}