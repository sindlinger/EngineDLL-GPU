#include "CudaProcessor.h"

#include <cuda_runtime.h>
#include <cuda.h>
#include <cufft.h>
#include <cuComplex.h>

#include <algorithm>
#include <vector>
#include <cmath>

namespace gpuengine
{

namespace
{
constexpr double kEps = 1e-12;
constexpr double kEmptyValueSentinel = 2147483647.0;

#define CUDA_CHECK(cmd)                                                      \
    do                                                                       \
    {                                                                        \
        cudaError_t _err = (cmd);                                            \
        if(_err != cudaSuccess)                                              \
            return STATUS_ERROR;                                             \
    } while(false)

#define CUDA_CHECK_VOID(cmd)                                                 \
    do                                                                       \
    {                                                                        \
        cudaError_t _err = (cmd);                                            \
        if(_err != cudaSuccess)                                              \
            return;                                                          \
    } while(false)

#define CUFFT_CHECK(cmd)                                                     \
    do                                                                       \
    {                                                                        \
        cufftResult _res = (cmd);                                            \
        if(_res != CUFFT_SUCCESS)                                            \
            return STATUS_ERROR;                                             \
    } while(false)

__global__ void BuildBandpassMaskKernel(double* mask,
                                        int freq_bins,
                                        double min_bin,
                                        double max_bin,
                                        double centre_bin,
                                        double sigma_bins,
                                        double threshold,
                                        double softness)
{
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if(idx >= freq_bins)
        return;

    if(idx == 0)
    {
        mask[idx] = 0.0;
        return;
    }

    double bin = static_cast<double>(idx);
    if(bin < min_bin || bin > max_bin)
    {
        mask[idx] = 0.0;
        return;
    }

    double sigma = fmax(sigma_bins, 1.0);
    double diff  = (bin - centre_bin) / sigma;
    double gaussian = exp(-0.5 * diff * diff);
    double weight = gaussian;
    if(weight < threshold)
    {
        double ratio = fmax(weight, kEps) / fmax(threshold, kEps);
        weight = pow(ratio, 1.0 + softness * 4.0);
    }

    mask[idx] = fmin(fmax(weight, 0.0), 1.0);
}

__global__ void ApplyMaskKernel(const cuDoubleComplex* __restrict__ in_spec,
                                cuDoubleComplex* __restrict__ out_spec,
                                const double* __restrict__ mask,
                                int freq_bins,
                                int batch)
{
    int bin = blockIdx.x * blockDim.x + threadIdx.x;
    int frame = blockIdx.y;
    if(bin >= freq_bins || frame >= batch)
        return;

    int idx = frame * freq_bins + bin;
    double gain = mask[bin];
    cuDoubleComplex value = in_spec[idx];
    out_spec[idx] = make_cuDoubleComplex(value.x * gain,
                                         value.y * gain);
}

__global__ void ZeroDcKernel(cuDoubleComplex* spec,
                             int freq_bins,
                             int batch)
{
    int frame = blockIdx.x * blockDim.x + threadIdx.x;
    if(frame >= batch)
        return;

    spec[frame * freq_bins] = make_cuDoubleComplex(0.0, 0.0);
}

__global__ void ScaleRealKernel(double* data, double scale, int total)
{
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if(idx >= total)
        return;
    data[idx] *= scale;
}

__global__ void ComputeNoiseKernel(const double* original,
                                   const double* filtered,
                                   double* noise,
                                   int total)
{
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if(idx >= total)
        return;
    noise[idx] = original[idx] - filtered[idx];
}

__global__ void BuildCycleMasksKernel(double* cycle_masks,
                                      const double* periods,
                                      int cycle_count,
                                      int freq_bins,
                                      double frame_length,
                                      double width)
{
    int bin = blockIdx.x * blockDim.x + threadIdx.x;
    int cycle = blockIdx.y;
    if(bin >= freq_bins || cycle >= cycle_count)
        return;

    double period = fmax(periods[cycle], 1.0);
    double centre_bin = frame_length / period;
    double sigma = fmax(centre_bin * width, 1.0);
    double diff = static_cast<double>(bin) - centre_bin;
    double weight = exp(-0.5 * (diff / sigma) * (diff / sigma));
    cycle_masks[cycle * freq_bins + bin] = weight;
}

__global__ void ApplyCycleMaskKernel(const cuDoubleComplex* __restrict__ base,
                                     cuDoubleComplex* __restrict__ out,
                                     const double* __restrict__ cycle_masks,
                                     int freq_bins,
                                     int batch,
                                     int cycle_index)
{
    int bin = blockIdx.x * blockDim.x + threadIdx.x;
    int frame = blockIdx.y;
    if(bin >= freq_bins || frame >= batch)
        return;

    int idx = frame * freq_bins + bin;
    double gain = cycle_masks[cycle_index * freq_bins + bin];
    cuDoubleComplex value = base[idx];
    out[idx] = make_cuDoubleComplex(value.x * gain,
                                    value.y * gain);
}

} // namespace

CudaProcessor::CudaProcessor() = default;
CudaProcessor::~CudaProcessor()
{
    Shutdown();
}

int CudaProcessor::Initialize(const Config& cfg)
{
    if(m_initialized)
        Shutdown();

    int status = EnsureDeviceConfigured(cfg);
    if(status != STATUS_OK)
        return status;

    status = EnsureBuffers(cfg);
    if(status != STATUS_OK)
        return status;

    CUDA_CHECK(cudaStreamCreateWithFlags(&m_main_stream, cudaStreamNonBlocking));
    CUDA_CHECK(cudaEventCreate(&m_timing_start));
    CUDA_CHECK(cudaEventCreate(&m_timing_end));

    m_config      = cfg;
    m_initialized = true;
    return STATUS_OK;
}

void CudaProcessor::Shutdown()
{
    if(!m_initialized)
        return;

    ReleasePlans();
    ReleaseBuffers();

    if(m_main_stream)
        cudaStreamDestroy(m_main_stream);
    if(m_timing_start)
        cudaEventDestroy(m_timing_start);
    if(m_timing_end)
        cudaEventDestroy(m_timing_end);

    m_main_stream   = nullptr;
    m_timing_start  = nullptr;
    m_timing_end    = nullptr;
    m_initialized   = false;
}

int CudaProcessor::EnsureDeviceConfigured(const Config& cfg)
{
    CUDA_CHECK(cudaSetDevice(cfg.device_id));
    return STATUS_OK;
}

int CudaProcessor::EnsureBuffers(const Config& cfg)
{
    std::size_t time_required = static_cast<std::size_t>(cfg.max_batch_size) * cfg.window_size;
    std::size_t freq_bins     = static_cast<std::size_t>(cfg.window_size / 2 + 1);
    std::size_t freq_required = static_cast<std::size_t>(cfg.max_batch_size) * freq_bins;
    std::size_t cycle_required= static_cast<std::size_t>(cfg.max_cycle_count) * freq_bins;

    if(time_required <= m_time_capacity &&
       freq_required <= m_freq_capacity &&
       cycle_required <= m_cycle_capacity)
        return STATUS_OK;

    ReleaseBuffers();

    m_time_capacity  = time_required;
    m_freq_capacity  = freq_required;
    m_cycle_capacity = cycle_required;
    m_freq_cycle_stride = freq_bins * cfg.max_batch_size;

    CUDA_CHECK(cudaMalloc(reinterpret_cast<void**>(&m_d_time_in),        m_time_capacity * sizeof(double)));
    CUDA_CHECK(cudaMalloc(reinterpret_cast<void**>(&m_d_time_original),  m_time_capacity * sizeof(double)));
    CUDA_CHECK(cudaMalloc(reinterpret_cast<void**>(&m_d_time_filtered),  m_time_capacity * sizeof(double)));
    CUDA_CHECK(cudaMalloc(reinterpret_cast<void**>(&m_d_time_noise),     m_time_capacity * sizeof(double)));
    CUDA_CHECK(cudaMalloc(reinterpret_cast<void**>(&m_d_time_cycles),    m_time_capacity * cfg.max_cycle_count * sizeof(double)));

    CUDA_CHECK(cudaMalloc(reinterpret_cast<void**>(&m_d_preview_mask), freq_bins * sizeof(double)));
    CUDA_CHECK(cudaMalloc(reinterpret_cast<void**>(&m_d_cycle_masks),  m_cycle_capacity * sizeof(double)));
    CUDA_CHECK(cudaMalloc(reinterpret_cast<void**>(&m_d_cycle_periods), cfg.max_cycle_count * sizeof(double)));

    CUDA_CHECK(cudaMalloc(reinterpret_cast<void**>(&m_d_freq_original), m_freq_capacity * sizeof(cuDoubleComplex)));
    CUDA_CHECK(cudaMalloc(reinterpret_cast<void**>(&m_d_freq_filtered), m_freq_capacity * sizeof(cuDoubleComplex)));
    CUDA_CHECK(cudaMalloc(reinterpret_cast<void**>(&m_d_freq_cycles),   m_freq_capacity * cfg.max_cycle_count * sizeof(cuDoubleComplex)));

    return STATUS_OK;
}

void CudaProcessor::ReleaseBuffers()
{
    auto release = [](void*& ptr)
    {
        if(ptr)
        {
            cudaFree(ptr);
            ptr = nullptr;
        }
    };

    release(reinterpret_cast<void*&>(m_d_time_in));
    release(reinterpret_cast<void*&>(m_d_time_original));
    release(reinterpret_cast<void*&>(m_d_time_filtered));
    release(reinterpret_cast<void*&>(m_d_time_noise));
    release(reinterpret_cast<void*&>(m_d_time_cycles));
    release(reinterpret_cast<void*&>(m_d_preview_mask));
    release(reinterpret_cast<void*&>(m_d_cycle_masks));
    release(reinterpret_cast<void*&>(m_d_cycle_periods));
    release(reinterpret_cast<void*&>(m_d_freq_original));
    release(reinterpret_cast<void*&>(m_d_freq_filtered));
    release(reinterpret_cast<void*&>(m_d_freq_cycles));

    m_time_capacity   = 0;
    m_freq_capacity   = 0;
    m_cycle_capacity  = 0;
    m_freq_cycle_stride = 0;
}

void CudaProcessor::ReleasePlans()
{
    for(auto& entry : m_plan_cache)
    {
        cufftHandle fwd = entry.second.forward;
        cufftHandle inv = entry.second.inverse;
        if(fwd) cufftDestroy(fwd);
        if(inv) cufftDestroy(inv);
    }
    m_plan_cache.clear();
}

CudaProcessor::PlanBundle* CudaProcessor::AcquirePlan(int batch_size)
{
    auto it = m_plan_cache.find(batch_size);
    if(it != m_plan_cache.end())
        return &it->second;

    PlanBundle bundle;
    int n[1]       = { m_config.window_size };
    int inembed[1] = { m_config.window_size };
    int onembed[1] = { m_config.window_size / 2 + 1 };
    int istride    = 1;
    int ostride    = 1;
    int idist      = m_config.window_size;
    int odist      = m_config.window_size / 2 + 1;

    cufftResult res = cufftPlanMany(&bundle.forward,
                                    1,
                                    n,
                                    inembed,
                                    istride,
                                    idist,
                                    onembed,
                                    ostride,
                                    odist,
                                    CUFFT_D2Z,
                                    batch_size);
    if(res != CUFFT_SUCCESS)
        return nullptr;

    res = cufftPlanMany(&bundle.inverse,
                         1,
                         n,
                         onembed,
                         ostride,
                         odist,
                         inembed,
                         istride,
                         idist,
                         CUFFT_Z2D,
                         batch_size);
    if(res != CUFFT_SUCCESS)
    {
        cufftDestroy(bundle.forward);
        return nullptr;
    }

    bundle.batch = batch_size;
    auto inserted = m_plan_cache.emplace(batch_size, bundle);
    return &inserted.first->second;
}

int CudaProcessor::Process(JobRecord& job)
{
    if(!m_initialized)
        return STATUS_NOT_INITIALISED;

    int batch = job.desc.frame_count;
    if(batch <= 0 || batch > m_config.max_batch_size)
        return STATUS_INVALID_CONFIG;

    PlanBundle* plan = AcquirePlan(batch);
    if(plan == nullptr)
        return STATUS_ERROR;

    return ProcessInternal(job, *plan);
}

int CudaProcessor::ProcessInternal(JobRecord& job, PlanBundle& plan)
{
    const int frame_len  = job.desc.frame_length;
    const int batch      = job.desc.frame_count;
    const int freq_bins  = frame_len / 2 + 1;
    const std::size_t total_samples = static_cast<std::size_t>(batch) * frame_len;
    const std::size_t freq_samples  = static_cast<std::size_t>(batch) * freq_bins;

    std::vector<double> demeaned(total_samples, 0.0);
    for(int frame = 0; frame < batch; ++frame)
    {
        const std::size_t offset = static_cast<std::size_t>(frame) * frame_len;
        const double* src = job.input_copy.data() + offset;
        double* dst = demeaned.data() + offset;
        double sum = 0.0;
        for(int i = 0; i < frame_len; ++i)
            sum += src[i];
        const double mean = (frame_len > 0 ? sum / static_cast<double>(frame_len) : 0.0);
        for(int i = 0; i < frame_len; ++i)
            dst[i] = src[i] - mean;
    }

    CUDA_CHECK(cudaMemcpyAsync(m_d_time_original,
                               job.input_copy.data(),
                               total_samples * sizeof(double),
                               cudaMemcpyHostToDevice,
                               m_main_stream));

    CUDA_CHECK(cudaMemcpyAsync(m_d_time_in,
                               demeaned.data(),
                               total_samples * sizeof(double),
                               cudaMemcpyHostToDevice,
                               m_main_stream));

    if(job.preview_mask.empty() && job.desc.preview_mask != nullptr)
    {
        job.preview_mask.assign(job.desc.preview_mask,
                                job.desc.preview_mask + freq_bins);
    }

    double min_period = std::max(job.desc.mask.min_period, 1.0);
    double max_period = std::max(job.desc.mask.max_period, min_period);
    if(max_period < min_period)
        std::swap(max_period, min_period);
    double min_bin = static_cast<double>(frame_len) / std::max(max_period, 1.0);
    double max_bin = static_cast<double>(frame_len) / std::max(min_period, 1.0);
    min_bin = std::max(1.0, std::min(min_bin, static_cast<double>(freq_bins - 1)));
    max_bin = std::max(min_bin, std::min(max_bin, static_cast<double>(freq_bins - 1)));
    double centre_bin = 0.5 * (min_bin + max_bin);
    double sigma_bins = (job.desc.mask.sigma_period > 0.0)
                            ? static_cast<double>(frame_len) / job.desc.mask.sigma_period
                            : std::max((max_bin - min_bin) / 2.0, 1.0);
    sigma_bins = std::max(sigma_bins, 1.0);

    if(!job.preview_mask.empty())
    {
        CUDA_CHECK(cudaMemcpyAsync(m_d_preview_mask,
                                   job.preview_mask.data(),
                                   freq_bins * sizeof(double),
                                   cudaMemcpyHostToDevice,
                                   m_main_stream));
    }
    else
    {
        int threads = 256;
        int blocks  = (freq_bins + threads - 1) / threads;
        BuildBandpassMaskKernel<<<blocks, threads, 0, m_main_stream>>>(
            m_d_preview_mask,
            freq_bins,
            min_bin,
            max_bin,
            centre_bin,
            sigma_bins,
            job.desc.mask.threshold,
            job.desc.mask.softness);
        CUDA_CHECK(cudaGetLastError());
    }

    CUFFT_CHECK(cufftSetStream(plan.forward, m_main_stream));
    CUFFT_CHECK(cufftSetStream(plan.inverse, m_main_stream));

    CUDA_CHECK(cudaEventRecord(m_timing_start, m_main_stream));

    CUFFT_CHECK(cufftExecD2Z(plan.forward,
                             reinterpret_cast<cufftDoubleReal*>(m_d_time_in),
                             reinterpret_cast<cufftDoubleComplex*>(m_d_freq_original)));

    // copy original spectrum to filtered buffer
    CUDA_CHECK(cudaMemcpyAsync(m_d_freq_filtered,
                               m_d_freq_original,
                               freq_samples * sizeof(cuDoubleComplex),
                               cudaMemcpyDeviceToDevice,
                               m_main_stream));

    dim3 threadsDc(128, 1, 1);
    dim3 blocksDc((batch + threadsDc.x - 1) / threadsDc.x, 1, 1);
    ZeroDcKernel<<<blocksDc, threadsDc, 0, m_main_stream>>>(
        m_d_freq_original,
        freq_bins,
        batch);
    CUDA_CHECK(cudaGetLastError());
    ZeroDcKernel<<<blocksDc, threadsDc, 0, m_main_stream>>>(
        m_d_freq_filtered,
        freq_bins,
        batch);
    CUDA_CHECK(cudaGetLastError());

    dim3 threadsMask(256, 1, 1);
    dim3 blocksMask((freq_bins + threadsMask.x - 1) / threadsMask.x,
                    batch,
                    1);

    ApplyMaskKernel<<<blocksMask, threadsMask, 0, m_main_stream>>>(
        m_d_freq_original,
        m_d_freq_filtered,
        m_d_preview_mask,
        freq_bins,
        batch);
    CUDA_CHECK(cudaGetLastError());

    CUFFT_CHECK(cufftExecZ2D(plan.inverse,
                             reinterpret_cast<cufftDoubleComplex*>(m_d_freq_filtered),
                             reinterpret_cast<cufftDoubleReal*>(m_d_time_filtered)));

    double scale = 1.0 / static_cast<double>(frame_len);
    int threadsScale = 256;
    int blocksScale  = (total_samples + threadsScale - 1) / threadsScale;
    ScaleRealKernel<<<blocksScale, threadsScale, 0, m_main_stream>>>(
        m_d_time_filtered,
        scale,
        static_cast<int>(total_samples));
    CUDA_CHECK(cudaGetLastError());

    ComputeNoiseKernel<<<blocksScale, threadsScale, 0, m_main_stream>>>(
        m_d_time_original,
        m_d_time_filtered,
        m_d_time_noise,
        static_cast<int>(total_samples));
    CUDA_CHECK(cudaGetLastError());

    job.cycle_periods.clear();
    const bool manual_cycles = (job.desc.cycles.periods != nullptr &&
                                job.desc.cycles.count > 0 &&
                                job.desc.cycles.periods[0] != kEmptyValueSentinel);

    if(manual_cycles)
    {
        const int manual_count = std::min(job.desc.cycles.count, m_config.max_cycle_count);
        for(int i = 0; i < manual_count; ++i)
        {
            double period = job.desc.cycles.periods[i];
            if(period > 0.0 && std::isfinite(period))
                job.cycle_periods.push_back(period);
        }
    }
    else
    {
        int target_candidates = job.desc.cycles.count > 0 ? job.desc.cycles.count : job.desc.mask.max_candidates;
        if(target_candidates <= 0)
            target_candidates = job.desc.mask.max_candidates;
        target_candidates = std::max(0, std::min(target_candidates, m_config.max_cycle_count));

        if(target_candidates > 0)
        {
            std::vector<cuDoubleComplex> host_spectrum(freq_samples);
            CUDA_CHECK(cudaMemcpyAsync(host_spectrum.data(),
                                       m_d_freq_filtered,
                                       freq_samples * sizeof(cuDoubleComplex),
                                       cudaMemcpyDeviceToHost,
                                       m_main_stream));
            CUDA_CHECK(cudaStreamSynchronize(m_main_stream));

            std::vector<double> energy(freq_bins, 0.0);
            for(int frame = 0; frame < batch; ++frame)
            {
                const cuDoubleComplex* frame_spec = host_spectrum.data() + frame * freq_bins;
                for(int bin = 1; bin < freq_bins; ++bin)
                {
                    double period = static_cast<double>(frame_len) / std::max<double>(bin, 1.0);
                    if(period < min_period || period > max_period)
                        continue;
                    cuDoubleComplex value = frame_spec[bin];
                    double mag2 = value.x * value.x + value.y * value.y;
                    energy[bin] += mag2;
                }
            }

            std::vector<int> bins;
            bins.reserve(freq_bins);
            for(int bin = 1; bin < freq_bins; ++bin)
            {
                if(energy[bin] > 0.0)
                    bins.push_back(bin);
            }
            if(bins.empty())
            {
                for(int bin = 1; bin < freq_bins; ++bin)
                    bins.push_back(bin);
            }

            std::sort(bins.begin(), bins.end(), [&](int a, int b) {
                return energy[a] > energy[b];
            });

            std::vector<int> selected_bins;
            for(int bin : bins)
            {
                bool too_close = false;
                for(int existing : selected_bins)
                {
                    if(std::abs(existing - bin) <= 1)
                    {
                        too_close = true;
                        break;
                    }
                }
                if(too_close)
                    continue;
                selected_bins.push_back(bin);
                if(static_cast<int>(selected_bins.size()) >= target_candidates)
                    break;
            }

            if(selected_bins.empty() && !bins.empty())
                selected_bins.push_back(bins.front());

            std::vector<double> auto_periods;
            auto_periods.reserve(selected_bins.size());
            for(int bin : selected_bins)
            {
                double period = static_cast<double>(frame_len) / std::max<double>(bin, 1.0);
                if(period > 0.0 && std::isfinite(period))
                    auto_periods.push_back(period);
            }

            std::sort(auto_periods.begin(), auto_periods.end());
            if(static_cast<int>(auto_periods.size()) > m_config.max_cycle_count)
                auto_periods.resize(m_config.max_cycle_count);
            job.cycle_periods = std::move(auto_periods);
        }
    }

    int cycle_count = static_cast<int>(job.cycle_periods.size());
    if(cycle_count > 0)
    {
        CUDA_CHECK(cudaMemcpyAsync(m_d_cycle_periods,
                                   job.cycle_periods.data(),
                                   cycle_count * sizeof(double),
                                   cudaMemcpyHostToDevice,
                                   m_main_stream));

        dim3 threadsCycleMask(256, 1, 1);
        dim3 blocksCycleMask((freq_bins + threadsCycleMask.x - 1) / threadsCycleMask.x,
                             cycle_count,
                             1);

        BuildCycleMasksKernel<<<blocksCycleMask, threadsCycleMask, 0, m_main_stream>>>(
            m_d_cycle_masks,
            m_d_cycle_periods,
            cycle_count,
            freq_bins,
            static_cast<double>(frame_len),
            job.desc.cycles.width);
        CUDA_CHECK(cudaGetLastError());

        for(int cycle_index=0; cycle_index<cycle_count; ++cycle_index)
        {
            cuDoubleComplex* cycle_freq = m_d_freq_cycles + cycle_index * freq_samples;
            ApplyCycleMaskKernel<<<blocksMask, threadsMask, 0, m_main_stream>>>(
                m_d_freq_original,
                cycle_freq,
                m_d_cycle_masks,
                freq_bins,
                batch,
                cycle_index);
            CUDA_CHECK(cudaGetLastError());

            CUFFT_CHECK(cufftExecZ2D(plan.inverse,
                                     reinterpret_cast<cufftDoubleComplex*>(cycle_freq),
                                     reinterpret_cast<cufftDoubleReal*>(m_d_time_cycles + cycle_index * total_samples)));

            ScaleRealKernel<<<blocksScale, threadsScale, 0, m_main_stream>>>(
                m_d_time_cycles + cycle_index * total_samples,
                scale,
                static_cast<int>(total_samples));
            CUDA_CHECK(cudaGetLastError());
        }
    }

    CUDA_CHECK(cudaEventRecord(m_timing_end, m_main_stream));

    // copy results back to host
    job.wave.resize(total_samples);
    job.preview.resize(total_samples);
    job.noise.resize(total_samples);
    job.result.cycle_count = cycle_count;
    if(cycle_count > 0)
        job.cycles.resize(static_cast<std::size_t>(cycle_count) * total_samples);
    else
        job.cycles.clear();

    CUDA_CHECK(cudaMemcpyAsync(job.wave.data(),
                               m_d_time_filtered,
                               total_samples * sizeof(double),
                               cudaMemcpyDeviceToHost,
                               m_main_stream));

    CUDA_CHECK(cudaMemcpyAsync(job.preview.data(),
                               m_d_time_filtered,
                               total_samples * sizeof(double),
                               cudaMemcpyDeviceToHost,
                               m_main_stream));

    CUDA_CHECK(cudaMemcpyAsync(job.noise.data(),
                               m_d_time_noise,
                               total_samples * sizeof(double),
                               cudaMemcpyDeviceToHost,
                               m_main_stream));

    if(cycle_count > 0)
    {
        CUDA_CHECK(cudaMemcpyAsync(job.cycles.data(),
                                   m_d_time_cycles,
                                   job.cycles.size() * sizeof(double),
                                   cudaMemcpyDeviceToHost,
                                   m_main_stream));
    }

    CUDA_CHECK(cudaStreamSynchronize(m_main_stream));

    float elapsed_ms = 0.0f;
    cudaError_t evt_status = cudaEventElapsedTime(&elapsed_ms, m_timing_start, m_timing_end);
    if(evt_status == cudaSuccess)
        job.result.elapsed_ms = static_cast<double>(elapsed_ms);
    else
        job.result.elapsed_ms = 0.0;
    job.result.status     = STATUS_READY;

    return STATUS_OK;
}

} // namespace gpuengine
