#define GPU_ENGINE_BUILD
#include "GpuEngineExports.h"
#include "GpuEngineCore.h"

#include <vector>
#include <cstring>
#include <algorithm>

using namespace gpuengine;

extern "C" {

GPU_EXPORT int GpuEngine_Init(int device_id,
                   int window_size,
                   int hop_size,
                   int max_batch_size,
                   bool enable_profiling)
{
    Config cfg;
    cfg.device_id        = device_id;
    cfg.window_size      = window_size;
    cfg.hop_size         = hop_size;
    cfg.max_batch_size   = max_batch_size;
    cfg.enable_profiling = enable_profiling;
    return GetEngine().Initialize(cfg);
}

GPU_EXPORT void GpuEngine_Shutdown()
{
    GetEngine().Shutdown();
}

GPU_EXPORT int GpuEngine_SubmitJob(const double* frames,
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
                        std::uint64_t* out_handle)
{
    JobDesc desc;
    desc.frames       = frames;
    desc.frame_count  = frame_count;
    desc.frame_length = frame_length;
    desc.user_tag     = user_tag;
    desc.flags        = flags;
    desc.preview_mask = preview_mask;
    desc.mask.sigma_period = mask_sigma_period;
    desc.mask.threshold    = mask_threshold;
    desc.mask.softness     = mask_softness;
    desc.mask.min_period   = mask_min_period;
    desc.mask.max_period   = mask_max_period;
    desc.mask.max_candidates = (cycle_count > 0 ? cycle_count : desc.mask.max_candidates);
    desc.upscale           = upscale_factor <= 0 ? 1 : upscale_factor;
    desc.cycles.periods    = (cycle_count > 0 ? cycle_periods : nullptr);
    desc.cycles.count      = cycle_count;
    desc.cycles.width      = cycle_width;
    desc.kalman.preset            = static_cast<KalmanPreset>(std::clamp(kalman_preset, 0, 3));
    desc.kalman.process_noise     = kalman_process_noise;
    desc.kalman.measurement_noise = kalman_measurement_noise;
    desc.kalman.init_variance     = kalman_init_variance;
    desc.kalman.plv_threshold     = kalman_plv_threshold;
    desc.kalman.max_iterations    = kalman_max_iterations;
    desc.kalman.convergence_eps   = kalman_epsilon;
    if(desc.mask.sigma_period <= 0.0)
        desc.mask.sigma_period = 48.0;
    if(desc.mask.threshold < 0.0)
        desc.mask.threshold = 0.0;
    if(desc.mask.threshold > 1.0)
        desc.mask.threshold = 1.0;
    if(desc.mask.softness < 0.0)
        desc.mask.softness = 0.0;
    if(desc.mask.min_period < 1.0)
        desc.mask.min_period = 1.0;
    if(desc.mask.max_period < desc.mask.min_period)
        desc.mask.max_period = desc.mask.min_period;
    if(desc.cycles.width <= 0.0)
        desc.cycles.width = 0.25;
    if(desc.mask.max_candidates < 1)
        desc.mask.max_candidates = 1;
    if(desc.kalman.process_noise <= 0.0)
        desc.kalman.process_noise = 1.0e-4;
    if(desc.kalman.measurement_noise <= 0.0)
        desc.kalman.measurement_noise = 2.5e-3;
    if(desc.kalman.init_variance <= 0.0)
        desc.kalman.init_variance = 0.5;
    if(desc.kalman.max_iterations <= 0)
        desc.kalman.max_iterations = 48;
    if(desc.kalman.convergence_eps <= 0.0)
        desc.kalman.convergence_eps = 1.0e-4;
    desc.kalman.plv_threshold = std::clamp(desc.kalman.plv_threshold, 0.0, 1.0);

    JobHandle handle;
    int status = GetEngine().SubmitJob(desc, handle);
    if(status == STATUS_OK && out_handle)
        *out_handle = handle.internal_id;
    return status;
}

GPU_EXPORT int GpuEngine_PollStatus(std::uint64_t handle_value,
                         int* out_status)
{
    JobHandle handle;
    handle.internal_id = handle_value;
    return GetEngine().PollStatus(handle, *out_status);
}

GPU_EXPORT int GpuEngine_FetchResult(std::uint64_t handle_value,
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
                          ResultInfo* info)
{
    JobHandle handle;
    handle.internal_id = handle_value;
    ResultInfo result_info;
    int status = GetEngine().FetchResult(handle,
                                         wave_out,
                                         preview_out,
                                         cycles_out,
                                         noise_out,
                                         phase_out,
                                         phase_unwrapped_out,
                                         amplitude_out,
                                         period_out,
                                         frequency_out,
                                         eta_out,
                                         countdown_out,
                                         recon_out,
                                         kalman_out,
                                         confidence_out,
                                         amp_delta_out,
                                         turn_signal_out,
                                         direction_out,
                                         power_out,
                                         velocity_out,
                                         phase_all_out,
                                         phase_unwrapped_all_out,
                                         amplitude_all_out,
                                         period_all_out,
                                         frequency_all_out,
                                         eta_all_out,
                                         countdown_all_out,
                                         direction_all_out,
                                         recon_all_out,
                                         kalman_all_out,
                                         turn_all_out,
                                         confidence_all_out,
                                         amp_delta_all_out,
                                         power_all_out,
                                         velocity_all_out,
                                         plv_cycles_out,
                                         snr_cycles_out,
                                         result_info);
    if(status == STATUS_OK && info)
        *info = result_info;
    return status;
}

GPU_EXPORT int GpuEngine_GetStats(double* avg_ms, double* max_ms)
{
    if(!avg_ms || !max_ms)
        return STATUS_INVALID_CONFIG;
    return GetEngine().GetStats(*avg_ms, *max_ms);
}

GPU_EXPORT int GpuEngine_GetLastError(char* buffer, int buffer_len)
{
    if(buffer == nullptr || buffer_len <= 0)
        return STATUS_INVALID_CONFIG;
    std::string msg;
    int status = GetEngine().GetLastError(msg);
    std::strncpy(buffer, msg.c_str(), buffer_len-1);
    buffer[buffer_len-1] = '\0';
    return status;
}

} // extern "C"
