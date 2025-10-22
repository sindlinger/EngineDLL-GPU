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
    std::vector<double>       preview_mask;
    std::vector<double>       cycle_periods;
    std::vector<double>       wave;
    std::vector<double>       preview;
    std::vector<double>       cycles;       // flattened (cycle_count * total_samples)
    std::vector<double>       noise;
    std::vector<double>       phase;        // dominant phase (deg)
    std::vector<double>       amplitude;
    std::vector<double>       inst_period;
    std::vector<double>       eta;
    std::vector<double>       recon;
    std::vector<double>       confidence;
    std::vector<double>       amp_delta;
    ResultInfo                result;
    std::atomic<int>          status { STATUS_IN_PROGRESS };
    std::chrono::steady_clock::time_point submit_time;
};

} // namespace gpuengine
