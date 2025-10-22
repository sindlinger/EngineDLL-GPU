#pragma once

#include "GpuEngineTypes.h"
#include <vector>
#include <atomic>
#include <chrono>

namespace gpuengine
{
struct JobHandle
{
    std::uint64_t internal_id = 0ULL;
    std::uint64_t user_tag    = 0ULL;
};

struct JobRecord
{
    JobHandle                 handle;
    JobDesc                   desc;
    std::vector<double>       input_copy;   // placeholder host buffer
    std::vector<double>       wave;
    std::vector<double>       preview;
    std::vector<double>       cycles;
    std::vector<double>       noise;
    ResultInfo                result;
    std::atomic<int>          status { STATUS_IN_PROGRESS };
    std::chrono::steady_clock::time_point submit_time;
};

} // namespace gpuengine
