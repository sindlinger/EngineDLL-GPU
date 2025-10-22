#pragma once

#include "GpuEngineTypes.h"

#if defined(_WIN32)
  #if defined(GPU_ENGINE_BUILD)
    #define GPU_EXPORT __declspec(dllexport)
  #else
    #define GPU_EXPORT __declspec(dllimport)
  #endif
#else
  #define GPU_EXPORT
#endif

extern "C" {

GPU_EXPORT int  GpuEngine_Init(int device_id,
                               int window_size,
                               int hop_size,
                               int max_batch_size,
                               bool enable_profiling);
GPU_EXPORT void GpuEngine_Shutdown();

GPU_EXPORT int  GpuEngine_SubmitJob(const double* frames,
                                    int frame_count,
                                    int frame_length,
                                    std::uint64_t user_tag,
                                    std::uint32_t flags,
                                    const double* preview_mask,
                                    double mask_sigma_period,
                                    double mask_threshold,
                                    double mask_softness,
                                    int upscale_factor,
                                    const double* cycle_periods,
                                    int cycle_count,
                                    double cycle_width,
                                    double phase_blend,
                                    double phase_gain,
                                    double freq_gain,
                                    double amp_gain,
                                    double freq_prior_blend,
                                    double min_period,
                                    double max_period,
                                    double snr_floor,
                                    int    frames_for_snr,
                                    std::uint64_t* out_handle);

GPU_EXPORT int  GpuEngine_PollStatus(std::uint64_t handle_value,
                                     int* out_status);

GPU_EXPORT int  GpuEngine_FetchResult(std::uint64_t handle_value,
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
                                      gpuengine::ResultInfo* info);

GPU_EXPORT int  GpuEngine_GetStats(double* avg_ms,
                                   double* max_ms);

GPU_EXPORT int  GpuEngine_GetLastError(char* buffer,
                                       int buffer_len);

}
