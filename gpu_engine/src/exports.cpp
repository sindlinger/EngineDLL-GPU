#include "GpuEngineCore.h"

#include <vector>
#include <cstring>

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
                        std::uint64_t* out_handle)
{
    JobDesc desc;
    desc.frames       = frames;
    desc.frame_count  = frame_count;
    desc.frame_length = frame_length;
    desc.user_tag     = user_tag;
    desc.flags        = flags;

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
