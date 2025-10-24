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
    std::vector<double>       phase_unwrapped; // dominant phase (deg, cumulative)
    std::vector<double>       phase_all;    // flattened per-cycle phase (deg)
    std::vector<double>       phase_unwrapped_all;
    std::vector<double>       amplitude;
    std::vector<double>       amplitude_all;
    std::vector<double>       inst_period;
    std::vector<double>       inst_period_all;
    std::vector<double>       inst_frequency;
    std::vector<double>       inst_frequency_all;
    std::vector<double>       eta;
    std::vector<double>       recon;
    std::vector<double>       recon_all;
    std::vector<double>       eta_all;
    std::vector<double>       countdown;    // bars to turnaround (alias of eta but smoothed)
    std::vector<double>       countdown_all;
    std::vector<double>       direction;
    std::vector<double>       direction_all;
    std::vector<double>       power;
    std::vector<double>       power_all;
    std::vector<double>       velocity;
    std::vector<double>       velocity_all;
    std::vector<double>       kalman_line;
    std::vector<double>       kalman_all;
    std::vector<double>       turn_signal;  // pulses when phase resets (for "dente" visual)
    std::vector<double>       turn_all;
    std::vector<double>       confidence;
    std::vector<double>       confidence_all;
    std::vector<double>       amp_delta;
    std::vector<double>       amp_delta_all;
    std::vector<double>       plv_cycle;
    std::vector<double>       snr_cycle;
    ResultInfo                result;
    std::atomic<int>          status { STATUS_IN_PROGRESS };
    std::chrono::steady_clock::time_point submit_time;
};

} // namespace gpuengine
