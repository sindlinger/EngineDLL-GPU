#include "GpuEngineCore.h"

#include <algorithm>
#include <chrono>
#include <cstring>
#include <stdexcept>
#include <string>

namespace gpuengine
{
namespace
{
constexpr int kDefaultWorkerCount = 2;

void CopyFramesToOutput(const JobRecord& job,
                        std::vector<double>& wave,
                        std::vector<double>& preview,
                        std::vector<double>& cycles,
                        std::vector<double>& noise)
{
    const int frames = job.desc.frame_count;
    const int len    = job.desc.frame_length;
    const int total  = frames * len;

    wave.resize(total);
    preview.resize(total);
    cycles.resize(total); // placeholder (single band)
    noise.resize(total);

    std::copy(job.input_copy.begin(), job.input_copy.end(), wave.begin());
    std::copy(job.input_copy.begin(), job.input_copy.end(), preview.begin());
    std::fill(cycles.begin(), cycles.end(), 0.0);
    std::fill(noise.begin(), noise.end(), 0.0);
}
}

Engine::Engine() = default;
Engine::~Engine()
{
    Shutdown();
}

int Engine::Initialize(const Config& cfg)
{
    if(cfg.window_size <= 0 || cfg.max_batch_size <= 0)
    {
        std::lock_guard<std::mutex> lock(m_error_mutex);
        m_last_error = "Invalid configuration";
        return STATUS_INVALID_CONFIG;
    }

    ResetState();
    m_config = cfg;
    m_running = true;

    const int worker_count = std::max(1, kDefaultWorkerCount);
    for(int i=0;i<worker_count;++i)
    {
        m_workers.emplace_back([this](){ WorkerLoop(); });
    }

    return STATUS_OK;
}

void Engine::ResetState()
{
    Shutdown();
    m_jobs.clear();
    while(!m_job_queue.empty())
        m_job_queue.pop();
    m_total_ms = 0.0;
    m_max_ms   = 0.0;
    m_completed_jobs = 0ULL;
    m_next_id = 1ULL;
}

void Engine::Shutdown()
{
    if(!m_running.exchange(false))
        return;

    {
        std::lock_guard<std::mutex> lock(m_queue_mutex);
        while(!m_job_queue.empty())
            m_job_queue.pop();
    }
    m_queue_cv.notify_all();

    for(auto& worker: m_workers)
    {
        if(worker.joinable())
            worker.join();
    }
    m_workers.clear();
}

int Engine::SubmitJob(const JobDesc& desc, JobHandle& out_handle)
{
    if(!m_running.load())
        return STATUS_NOT_INITIALISED;

    if(desc.frames == nullptr || desc.frame_count <= 0 || desc.frame_length <= 0)
        return STATUS_INVALID_CONFIG;

    auto record = std::make_shared<JobRecord>();
    record->desc = desc;
    const int total = desc.frame_count * desc.frame_length;
    record->input_copy.assign(desc.frames, desc.frames + total);
    record->wave.reserve(total);
    record->preview.reserve(total);
    record->cycles.reserve(total);
    record->noise.reserve(total);
    record->submit_time = std::chrono::steady_clock::now();

    JobHandle handle;
    handle.internal_id = m_next_id.fetch_add(1ULL);
    handle.user_tag    = desc.user_tag;
    record->handle = handle;
    record->result.user_tag = desc.user_tag;
    record->result.frame_count = desc.frame_count;
    record->result.frame_length = desc.frame_length;

    {
        std::lock_guard<std::mutex> lock(m_queue_mutex);
        m_jobs.emplace(handle.internal_id, record);
        m_job_queue.push(handle.internal_id);
    }
    m_queue_cv.notify_one();

    out_handle = handle;
    return STATUS_OK;
}

int Engine::PollStatus(const JobHandle& handle, int& out_status)
{
    auto it = m_jobs.find(handle.internal_id);
    if(it == m_jobs.end())
    {
        out_status = STATUS_ERROR;
        return STATUS_ERROR;
    }
    out_status = it->second->status.load();
    return STATUS_OK;
}

int Engine::FetchResult(const JobHandle& handle,
                        double* wave_out,
                        double* preview_out,
                        double* cycles_out,
                        double* noise_out,
                        ResultInfo& info)
{
    auto it = m_jobs.find(handle.internal_id);
    if(it == m_jobs.end())
        return STATUS_ERROR;

    auto record = it->second;
    if(record->status.load() != STATUS_READY)
        return STATUS_IN_PROGRESS;

    const int total = record->desc.frame_count * record->desc.frame_length;

    if(wave_out)
        std::copy(record->wave.begin(), record->wave.end(), wave_out);
    if(preview_out)
        std::copy(record->preview.begin(), record->preview.end(), preview_out);
    if(cycles_out)
        std::copy(record->cycles.begin(), record->cycles.end(), cycles_out);
    if(noise_out)
        std::copy(record->noise.begin(), record->noise.end(), noise_out);

    info = record->result;

    {
        std::lock_guard<std::mutex> lock(m_queue_mutex);
        m_jobs.erase(it);
    }

    return STATUS_OK;
}

int Engine::GetStats(double& avg_ms, double& max_ms)
{
    std::lock_guard<std::mutex> lock(m_stats_mutex);
    if(m_completed_jobs == 0)
    {
        avg_ms = 0.0;
        max_ms = 0.0;
        return STATUS_OK;
    }
    avg_ms = m_total_ms / static_cast<double>(m_completed_jobs);
    max_ms = m_max_ms;
    return STATUS_OK;
}

int Engine::GetLastError(std::string& out_message) const
{
    std::lock_guard<std::mutex> lock(m_error_mutex);
    out_message = m_last_error;
    return out_message.empty() ? STATUS_OK : STATUS_ERROR;
}

void Engine::WorkerLoop()
{
    while(m_running.load())
    {
        std::shared_ptr<JobRecord> job;
        {
            std::unique_lock<std::mutex> lock(m_queue_mutex);
            m_queue_cv.wait(lock, [this]() {
                return !m_running.load() || !m_job_queue.empty();
            });

            if(!m_running.load())
                break;

            if(m_job_queue.empty())
                continue;

            auto job_id = m_job_queue.front();
            m_job_queue.pop();
            auto it = m_jobs.find(job_id);
            if(it == m_jobs.end())
                continue;
            job = it->second;
        }

        // Placeholder processing (simulate GPU work)
        auto start = std::chrono::steady_clock::now();
        CopyFramesToOutput(*job, job->wave, job->preview, job->cycles, job->noise);
        auto end   = std::chrono::steady_clock::now();

        double elapsed = std::chrono::duration<double, std::milli>(end - start).count();
        job->result.elapsed_ms = elapsed;
        job->result.status     = STATUS_READY;
        job->status.store(STATUS_READY);

        {
            std::lock_guard<std::mutex> lock_stats(m_stats_mutex);
            m_total_ms += elapsed;
            m_max_ms = std::max(m_max_ms, elapsed);
            ++m_completed_jobs;
        }
    }
}

Engine& GetEngine()
{
    static Engine engine;
    return engine;
}

} // namespace gpuengine
