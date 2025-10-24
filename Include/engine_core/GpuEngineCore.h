#pragma once

#include "GpuEngineTypes.h"
#include "GpuEngineJob.h"

#include <condition_variable>
#include <mutex>
#include <thread>
#include <unordered_map>
#include <queue>
#include <atomic>
#include <string>
#include <memory>

namespace gpuengine
{
class CudaProcessor;

class Engine
{
public:
    Engine();
    ~Engine();

    int  Initialize(const Config& cfg);
    void Shutdown();

    int  SubmitJob(const JobDesc& desc, JobHandle& out_handle);
    int  PollStatus(const JobHandle& handle, int& out_status);
    int  FetchResult(const JobHandle& handle,
                     double* wave_out,
                     double* preview_out,
                     double* cycles_out,
                     double* noise_out,
                     double* phase_out,
                     double* phase_unwrapped_out,
                     double* amplitude_out,
                     double* period_out,
                     double* frequency_out,
                     double* eta_out,
                     double* countdown_out,
                     double* recon_out,
                     double* kalman_out,
                     double* confidence_out,
                     double* amp_delta_out,
                     double* turn_signal_out,
                     double* direction_out,
                     double* power_out,
                     double* velocity_out,
                     double* phase_all_out,
                     double* phase_unwrapped_all_out,
                     double* amplitude_all_out,
                     double* period_all_out,
                     double* frequency_all_out,
                     double* eta_all_out,
                     double* countdown_all_out,
                     double* direction_all_out,
                     double* recon_all_out,
                     double* kalman_all_out,
                     double* turn_all_out,
                     double* confidence_all_out,
                     double* amp_delta_all_out,
                     double* power_all_out,
                     double* velocity_all_out,
                     double* plv_cycles_out,
                     double* snr_cycles_out,
                     ResultInfo& info);

    int  GetStats(double& avg_ms, double& max_ms);
    int  GetLastError(std::string& out_message) const;

private:
    void WorkerLoop();
    void ResetState();

    Config m_config{};

    std::vector<std::thread> m_workers;
    std::queue<std::uint64_t> m_job_queue;
    std::unordered_map<std::uint64_t, std::shared_ptr<JobRecord>> m_jobs;

    std::mutex              m_queue_mutex;
    std::condition_variable m_queue_cv;
    std::atomic<bool>       m_running{false};

    std::atomic<std::uint64_t> m_next_id{1ULL};

    // stats
    std::mutex m_stats_mutex;
    double     m_total_ms = 0.0;
    double     m_max_ms   = 0.0;
    std::uint64_t m_completed_jobs = 0ULL;

    // error handling
    mutable std::mutex m_error_mutex;
    std::string        m_last_error;

    std::unique_ptr<CudaProcessor> m_processor;
};

Engine& GetEngine();

} // namespace gpuengine
