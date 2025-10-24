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
                                    double mask_min_period,
                                    double mask_max_period,
                                    int upscale_factor,
                                    const double* cycle_periods,
                                    int cycle_count,
                                    double cycle_width,
                                    int kalman_preset,
                                    double kalman_process_noise,
                                    double kalman_measurement_noise,
                                    double kalman_init_variance,
                                    double kalman_plv_threshold,
                                    int    kalman_max_iterations,
                                    double kalman_epsilon,
                                    std::uint64_t* out_handle);

GPU_EXPORT int  GpuEngine_PollStatus(std::uint64_t handle_value,
                                     int* out_status);

GPU_EXPORT int  GpuEngine_FetchResult(std::uint64_t handle_value,
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
                                      gpuengine::ResultInfo* info);

GPU_EXPORT int  GpuEngine_GetStats(double* avg_ms,
                                   double* max_ms);

GPU_EXPORT int  GpuEngine_GetLastError(char* buffer,
                                       int buffer_len);

}
