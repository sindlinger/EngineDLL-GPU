#include "GpuEngineExports.h"
#include "GpuEngineCore.h"

#include <vector>
#include <cstring>
#include <algorithm>

using namespace gpuengine;

extern "C" {

int GpuEngine_Init(int device_id,
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

void GpuEngine_Shutdown()
{
    GetEngine().Shutdown();
}

int GpuEngine_SubmitJob(const double* frames,
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
    desc.upscale           = upscale_factor <= 0 ? 1 : upscale_factor;
    desc.cycles.periods    = (cycle_count > 0 ? cycle_periods : nullptr);
    desc.cycles.count      = cycle_count;
    desc.cycles.width      = cycle_width;
    desc.phase.blend            = std::clamp(phase_blend, 0.0, 1.0);
    desc.phase.phase_gain       = std::max(phase_gain, 0.0);
    desc.phase.freq_gain        = std::max(freq_gain, 0.0);
    desc.phase.amp_gain         = std::max(amp_gain, 0.0);
    desc.phase.freq_prior_blend = std::clamp(freq_prior_blend, 0.0, 1.0);
    desc.phase.min_period       = min_period;
    desc.phase.max_period       = max_period;
    desc.phase.snr_floor        = snr_floor;
    desc.phase.frames_for_snr   = frames_for_snr;
    if(desc.mask.sigma_period <= 0.0)
        desc.mask.sigma_period = 48.0;
    if(desc.mask.threshold < 0.0)
        desc.mask.threshold = 0.0;
    if(desc.mask.threshold > 1.0)
        desc.mask.threshold = 1.0;
    if(desc.mask.softness < 0.0)
        desc.mask.softness = 0.0;
    if(desc.cycles.width <= 0.0)
        desc.cycles.width = 0.25;
    if(desc.phase.min_period < 1.0)
        desc.phase.min_period = 1.0;
    if(desc.phase.max_period < desc.phase.min_period)
        desc.phase.max_period = desc.phase.min_period;
    if(desc.phase.frames_for_snr <= 0)
        desc.phase.frames_for_snr = 1;
    if(desc.phase.max_period < desc.phase.min_period)
        desc.phase.max_period = desc.phase.min_period;
    if(desc.phase.snr_floor < 0.0)
        desc.phase.snr_floor = 0.0;

    JobHandle handle;
    int status = GetEngine().SubmitJob(desc, handle);
    if(status == STATUS_OK && out_handle)
        *out_handle = handle.internal_id;
    return status;
}

int GpuEngine_PollStatus(std::uint64_t handle_value,
                         int* out_status)
{
    JobHandle handle;
    handle.internal_id = handle_value;
    return GetEngine().PollStatus(handle, *out_status);
}

int GpuEngine_FetchResult(std::uint64_t handle_value,
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
                                         amplitude_out,
                                         period_out,
                                         eta_out,
                                         recon_out,
                                         confidence_out,
                                         amp_delta_out,
                                         result_info);
    if(status == STATUS_OK && info)
        *info = result_info;
    return status;
}

int GpuEngine_GetStats(double* avg_ms, double* max_ms)
{
    if(!avg_ms || !max_ms)
        return STATUS_INVALID_CONFIG;
    return GetEngine().GetStats(*avg_ms, *max_ms);
}

int GpuEngine_GetLastError(char* buffer, int buffer_len)
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
