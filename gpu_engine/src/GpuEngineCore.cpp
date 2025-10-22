#include "GpuEngineCore.h"
#include "CudaProcessor.h"

#define _USE_MATH_DEFINES
#include <algorithm>
#include <chrono>
#include <cstring>
#include <stdexcept>
#include <string>
#include <cmath>

namespace gpuengine
{
namespace
{
constexpr int kDefaultWorkerCount = 2;
constexpr double kPi    = 3.14159265358979323846;
constexpr double kTwoPi = 6.28318530717958647692;

inline double Clamp(double value, double min_value, double max_value)
{
    if(value < min_value) return min_value;
    if(value > max_value) return max_value;
    return value;
}

inline double NormalizeTwoPi(double angle)
{
    double res = std::fmod(angle, kTwoPi);
    if(res < 0.0)
        res += kTwoPi;
    return res;
}

void RunPhaseTracker(JobRecord& job)
{
    const int frame_count  = job.desc.frame_count;
    const int frame_length = job.desc.frame_length;
    const int cycle_count  = job.desc.cycles.count;
    const std::size_t total = static_cast<std::size_t>(frame_count) * frame_length;

    job.phase.assign(total, 0.0);
    job.amplitude.assign(total, 0.0);
    job.inst_period.assign(total, 0.0);
    job.eta.assign(total, 0.0);
    job.recon.assign(total, 0.0);
    job.confidence.assign(total, 0.0);
    job.amp_delta.assign(total, 0.0);

    job.result.dominant_cycle = -1;
    job.result.dominant_period = 0.0;
    job.result.dominant_snr = 0.0;
    job.result.pll_phase_deg = 0.0;
    job.result.pll_amplitude = 0.0;
    job.result.pll_period = 0.0;
    job.result.pll_eta = 0.0;
    job.result.pll_confidence = 0.0;
    job.result.pll_reconstructed = 0.0;

    if(total == 0 || cycle_count <= 0 || job.cycles.empty())
        return;

    const PhaseParams& params = job.desc.phase;

    const int frames_to_watch = std::max(1, std::min(frame_count, params.frames_for_snr));
    const std::size_t span = static_cast<std::size_t>(frames_to_watch) * frame_length;
    const std::size_t start_index = (total > span ? total - span : 0);

    double noise_energy = 0.0;
    for(std::size_t i = start_index; i < total; ++i)
    {
        double n = (i < job.noise.size() ? job.noise[i] : 0.0);
        noise_energy += n * n;
    }
    const double span_count = static_cast<double>(total - start_index);
    if(span_count <= 0.0)
        return;
    noise_energy /= span_count;
    const double noise_rms = std::sqrt(std::max(noise_energy, 0.0));

    double best_snr = -1.0;
    int best_index = -1;

    for(int c = 0; c < cycle_count; ++c)
    {
        const std::size_t offset = static_cast<std::size_t>(c) * total;
        if(offset + total > job.cycles.size())
            break;
        double energy = 0.0;
        for(std::size_t i = start_index; i < total; ++i)
        {
            double v = job.cycles[offset + i];
            energy += v * v;
        }
        energy /= span_count;
        double snr = energy / (noise_energy + 1.0e-10);
        if(snr > best_snr)
        {
            best_snr = snr;
            best_index = c;
        }
    }

    if(best_index < 0 || best_snr < params.snr_floor)
        return;

    const std::size_t best_offset = static_cast<std::size_t>(best_index) * total;
    if(best_offset + total > job.cycles.size())
        return;

    job.result.dominant_cycle = best_index;
    job.result.dominant_snr   = best_snr;

    double dominant_period = params.max_period;
    if(best_index < static_cast<int>(job.cycle_periods.size()) && job.cycle_periods[best_index] > 0.0)
        dominant_period = job.cycle_periods[best_index];
    dominant_period = Clamp(dominant_period, params.min_period, params.max_period);
    job.result.dominant_period = dominant_period;

    const double* cycle_ptr = job.cycles.data() + best_offset;
    const double* input_ptr = job.input_copy.data();

    double phase = 0.0;
    const double desired_omega = kTwoPi / Clamp(dominant_period, params.min_period, params.max_period);
    double omega = desired_omega;
    double amplitude = cycle_ptr[0];
    double prev_amplitude = amplitude;

    const double omega_min = kTwoPi / params.max_period;
    const double omega_max = kTwoPi / std::max(params.min_period, 1.0);
    const double snr_confidence = best_snr / (best_snr + 1.0);

    for(std::size_t i = 0; i < total; ++i)
    {
        const double cycle_sample = cycle_ptr[i];
        const double input_sample = (i < job.input_copy.size() ? input_ptr[i] : cycle_sample);
        const double measurement = params.blend * cycle_sample + (1.0 - params.blend) * input_sample;

        const double predicted = amplitude * std::cos(phase);
        const double error = measurement - predicted;
        const double safe_amp = std::max(std::abs(amplitude), 1.0e-6);

        const double phase_correction = params.phase_gain * (error / safe_amp);
        phase = NormalizeTwoPi(phase + omega + phase_correction);

        const double freq_correction = params.freq_gain * error * std::sin(phase);
        omega = Clamp(omega + freq_correction, omega_min, omega_max);

        omega = (1.0 - params.freq_prior_blend) * omega + params.freq_prior_blend * desired_omega;

        const double amp_correction = params.amp_gain * error * std::cos(phase);
        amplitude = std::max(amplitude + amp_correction, 1.0e-6);

        const double recon = amplitude * std::cos(phase);
        const double inst_period = kTwoPi / std::max(omega, 1.0e-6);
        const double eta = (kTwoPi - phase) / std::max(omega, 1.0e-6);

        const double confidence_error = 1.0 / (1.0 + std::abs(error) / (std::abs(measurement) + 1.0e-6));
        const double confidence = confidence_error * snr_confidence;

        job.phase[i]      = phase * 180.0 / kPi;
        job.amplitude[i]  = amplitude;
        job.inst_period[i]= inst_period;
        job.eta[i]        = eta;
        job.recon[i]      = recon;
        job.confidence[i] = confidence;
        job.amp_delta[i]  = amplitude - prev_amplitude;

        prev_amplitude = amplitude;
    }

    if(!job.phase.empty())
    {
        const std::size_t last = total - 1;
        job.result.pll_phase_deg  = job.phase[last];
        job.result.pll_amplitude  = job.amplitude[last];
        job.result.pll_period     = job.inst_period[last];
        job.result.dominant_period= job.inst_period[last];
        job.result.pll_eta        = job.eta[last];
        job.result.pll_confidence = job.confidence[last];
        job.result.pll_reconstructed = job.recon[last];
    }
}
}

Engine::Engine() = default;
Engine::~Engine()
{
    Shutdown();
}

int Engine::Initialize(const Config& cfg)
{
    if(cfg.window_size <= 0 || cfg.max_batch_size <= 0 || cfg.max_cycle_count < 0)
    {
        std::lock_guard<std::mutex> lock(m_error_mutex);
        m_last_error = "Invalid configuration";
        return STATUS_INVALID_CONFIG;
    }

    ResetState();
    m_config = cfg;
    m_running = true;

    m_processor = std::make_unique<CudaProcessor>();
    int gpu_status = m_processor->Initialize(cfg);
    if(gpu_status != STATUS_OK)
    {
        std::lock_guard<std::mutex> lock(m_error_mutex);
        m_last_error = "Failed to initialise CUDA processor";
        m_running = false;
        m_processor.reset();
        return gpu_status;
    }

    const int worker_count = std::max(1, std::max(cfg.stream_count, kDefaultWorkerCount));
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
    bool was_running = m_running.exchange(false);

    {
        std::lock_guard<std::mutex> lock(m_queue_mutex);
        while(!m_job_queue.empty())
            m_job_queue.pop();
    }
    m_queue_cv.notify_all();

    if(was_running)
    {
        for(auto& worker: m_workers)
        {
            if(worker.joinable())
                worker.join();
        }
    }
    m_workers.clear();

    if(m_processor)
    {
        m_processor->Shutdown();
        m_processor.reset();
    }
}

int Engine::SubmitJob(const JobDesc& desc, JobHandle& out_handle)
{
    if(!m_running.load())
        return STATUS_NOT_INITIALISED;

    if(desc.frames == nullptr || desc.frame_count <= 0 || desc.frame_length <= 0)
    {
        std::lock_guard<std::mutex> lock(m_error_mutex);
        m_last_error = "SubmitJob: invalid frame parameters";
        return STATUS_INVALID_CONFIG;
    }
    if(desc.cycles.count > m_config.max_cycle_count)
    {
        std::lock_guard<std::mutex> lock(m_error_mutex);
        m_last_error = "SubmitJob: cycle_count exceeds max_cycle_count";
        return STATUS_INVALID_CONFIG;
    }
    if(desc.cycles.count > 0 && desc.cycles.periods == nullptr)
    {
        std::lock_guard<std::mutex> lock(m_error_mutex);
        m_last_error = "SubmitJob: cycle periods pointer is null";
        return STATUS_INVALID_CONFIG;
    }

    auto record = std::make_shared<JobRecord>();
    record->desc = desc;
    const int total = desc.frame_count * desc.frame_length;
    record->input_copy.assign(desc.frames, desc.frames + total);
    if(desc.preview_mask != nullptr)
    {
        const int freq_bins = desc.frame_length / 2 + 1;
        record->preview_mask.assign(desc.preview_mask,
                                    desc.preview_mask + freq_bins);
        record->desc.preview_mask = record->preview_mask.data();
    }

    if(desc.cycles.count > 0)
    {
        record->cycle_periods.assign(desc.cycles.periods,
                                     desc.cycles.periods + desc.cycles.count);
        record->desc.cycles.periods = record->cycle_periods.data();
    }
    record->wave.reserve(total);
    record->preview.reserve(total);
    record->cycles.reserve(static_cast<std::size_t>(std::max(desc.cycles.count, 1)) * total);
    record->noise.reserve(total);
    record->phase.reserve(total);
    record->amplitude.reserve(total);
    record->inst_period.reserve(total);
    record->eta.reserve(total);
    record->recon.reserve(total);
    record->confidence.reserve(total);
    record->amp_delta.reserve(total);
    record->submit_time = std::chrono::steady_clock::now();

    JobHandle handle;
    handle.internal_id = m_next_id.fetch_add(1ULL);
    handle.user_tag    = desc.user_tag;
    record->handle = handle;
    record->result.user_tag = desc.user_tag;
    record->result.frame_count = desc.frame_count;
    record->result.frame_length = desc.frame_length;
    record->result.cycle_count  = desc.cycles.count;

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
                        double* phase_out,
                        double* amplitude_out,
                        double* period_out,
                        double* eta_out,
                        double* recon_out,
                        double* confidence_out,
                        double* amp_delta_out,
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
    if(cycles_out && !record->cycles.empty())
        std::copy(record->cycles.begin(), record->cycles.end(), cycles_out);
    if(noise_out)
        std::copy(record->noise.begin(), record->noise.end(), noise_out);
    if(phase_out && !record->phase.empty())
        std::copy(record->phase.begin(), record->phase.end(), phase_out);
    if(amplitude_out && !record->amplitude.empty())
        std::copy(record->amplitude.begin(), record->amplitude.end(), amplitude_out);
    if(period_out && !record->inst_period.empty())
        std::copy(record->inst_period.begin(), record->inst_period.end(), period_out);
    if(eta_out && !record->eta.empty())
        std::copy(record->eta.begin(), record->eta.end(), eta_out);
    if(recon_out && !record->recon.empty())
        std::copy(record->recon.begin(), record->recon.end(), recon_out);
    if(confidence_out && !record->confidence.empty())
        std::copy(record->confidence.begin(), record->confidence.end(), confidence_out);
    if(amp_delta_out && !record->amp_delta.empty())
        std::copy(record->amp_delta.begin(), record->amp_delta.end(), amp_delta_out);

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

        auto start_cpu = std::chrono::steady_clock::now();
        int status = (m_processor ? m_processor->Process(*job) : STATUS_NOT_INITIALISED);

        if(status != STATUS_OK || job->result.status != STATUS_READY)
        {
            job->status.store(STATUS_ERROR);
            job->result.status = STATUS_ERROR;
            std::lock_guard<std::mutex> lock_err(m_error_mutex);
            m_last_error = "GPU processing failed";
        }
        else
        {
            RunPhaseTracker(*job);
            job->status.store(STATUS_READY);
            if(job->result.elapsed_ms <= 0.0)
            {
                auto end_cpu = std::chrono::steady_clock::now();
                job->result.elapsed_ms = std::chrono::duration<double, std::milli>(end_cpu - start_cpu).count();
            }

            {
                std::lock_guard<std::mutex> lock_err(m_error_mutex);
                m_last_error.clear();
            }

            std::lock_guard<std::mutex> lock_stats(m_stats_mutex);
            m_total_ms += job->result.elapsed_ms;
            m_max_ms = std::max(m_max_ms, job->result.elapsed_ms);
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
