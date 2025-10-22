#pragma once

#include "GpuEngineTypes.h"
#include "GpuEngineJob.h"

#include <cstddef>
#include <memory>
#include <unordered_map>
#include <cuda_runtime_api.h>
#include <cufft.h>
#include <cuComplex.h>

// Forward declarations for CUDA types to avoid exposing CUDA headers in public includes
typedef struct CUstream_st* cudaStream_t;
typedef struct CUevent_st*  cudaEvent_t;

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

    // configuration
    Config m_config{};
    bool   m_initialized = false;

    // device buffers
    double*              m_d_time_in      = nullptr;
    double*              m_d_time_filtered= nullptr;
    double*              m_d_time_noise   = nullptr;
    double*              m_d_time_cycles  = nullptr;
    double*              m_d_preview_mask = nullptr;
    double*              m_d_cycle_masks  = nullptr;
    double*              m_d_cycle_periods = nullptr;

    std::size_t          m_time_capacity  = 0; // samples capacity
    std::size_t          m_cycle_capacity = 0; // samples capacity (per cycle)

    cuDoubleComplex*     m_d_freq_original   = nullptr;
    cuDoubleComplex*     m_d_freq_filtered   = nullptr;
    cuDoubleComplex*     m_d_freq_cycles     = nullptr;

    std::size_t          m_freq_capacity     = 0; // complex bins capacity
    std::size_t          m_freq_cycle_stride = 0;

    cudaStream_t         m_main_stream = nullptr;
    cudaEvent_t          m_timing_start = nullptr;
    cudaEvent_t          m_timing_end   = nullptr;

    std::unordered_map<int, PlanBundle> m_plan_cache;
};

} // namespace gpuengine
