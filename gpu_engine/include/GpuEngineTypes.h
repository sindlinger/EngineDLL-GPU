#pragma once

#include <cstdint>

namespace gpuengine
{
// Status codes mirrored in the MQL wrapper
enum StatusCode
{
    STATUS_OK              = 0,
    STATUS_READY           = 1,
    STATUS_IN_PROGRESS     = 2,
    STATUS_TIMEOUT         = 3,
    STATUS_ERROR           = -1,
    STATUS_INVALID_CONFIG  = -2,
    STATUS_NOT_INITIALISED = -3,
    STATUS_QUEUE_FULL      = -4
};

struct Config
{
    int     device_id        = 0;
    int     window_size      = 0;
    int     hop_size         = 0;
    int     max_batch_size   = 0;
    bool    enable_profiling = false;
};

struct JobDesc
{
    const double* frames        = nullptr;  // pointer to host data (size = frame_count * frame_length)
    int           frame_count   = 0;
    int           frame_length  = 0;
    std::uint64_t user_tag      = 0ULL;
    std::uint32_t flags         = 0U;
};

struct ResultInfo
{
    std::uint64_t user_tag      = 0ULL;
    int           frame_count   = 0;
    int           frame_length  = 0;
    double        elapsed_ms    = 0.0;
    int           status        = STATUS_ERROR;
};

} // namespace gpuengine
