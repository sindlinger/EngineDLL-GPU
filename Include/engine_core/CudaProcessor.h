#pragma once

#include "GpuEngineTypes.h"
#include "GpuEngineJob.h"

#include <cuda_runtime.h>
#include <cufft.h>
#include <cuComplex.h>

#include <cstddef>
#include <unordered_map>

namespace gpuengine
{

class CudaProcessor
{
public:
    CudaProcessor();
    ~CudaProcessor();

    int  Initialize(const Config& cfg);
    void Shutdown();

    int  Process(JobRecord& job);

private:
    struct PlanBundle
    {
        cufftHandle forward = 0;
        cufftHandle inverse = 0;
        int         batch   = 0;
    };

    int  EnsureDeviceConfigured(const Config& cfg);
    int  EnsureBuffers(const Config& cfg);
    void ReleaseBuffers();
    void ReleasePlans();
    PlanBundle* AcquirePlan(int batch_size);
    int  ProcessInternal(JobRecord& job, PlanBundle& plan);

    Config m_config{};
    bool   m_initialized = false;

    double*         m_d_time_in        = nullptr;
    double*         m_d_time_original  = nullptr;
    double*         m_d_time_filtered  = nullptr;
    double*         m_d_time_noise     = nullptr;
    double*         m_d_time_cycles    = nullptr;
    double*         m_d_preview_mask   = nullptr;
    double*         m_d_cycle_masks    = nullptr;
    double*         m_d_cycle_periods  = nullptr;
    cuDoubleComplex* m_d_freq_original = nullptr;
    cuDoubleComplex* m_d_freq_filtered = nullptr;
    cuDoubleComplex* m_d_freq_cycles   = nullptr;

    std::size_t m_time_capacity   = 0;
    std::size_t m_freq_capacity   = 0;
    std::size_t m_cycle_capacity  = 0;
    std::size_t m_freq_cycle_stride = 0;

    cudaStream_t m_main_stream  = nullptr;
    cudaEvent_t  m_timing_start = nullptr;
    cudaEvent_t  m_timing_end   = nullptr;

    std::unordered_map<int, PlanBundle> m_plan_cache;
};

} // namespace gpuengine
