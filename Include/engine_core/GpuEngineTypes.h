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
    int     max_cycle_count  = 24;
    int     stream_count     = 2;
    bool    enable_profiling = false;
};

struct MaskParams
{
    double sigma_period   = 48.0;  // period (bars) translated to gaussian sigma in bins
    double threshold      = 0.05;  // relative magnitude threshold
    double softness       = 0.2;   // gain curve softness
    double min_period     = 8.0;   // lower bound (bars) for band-pass
    double max_period     = 512.0; // upper bound (bars) for band-pass
    int    max_candidates = 24;    // number of spectral peaks to keep when auto-selecting cycles
};

struct CycleParams
{
    const double* periods   = nullptr; // pointer to array of cycle periods (bars)
    int           count     = 0;
    double        width     = 0.25;    // fractional width relative to centre frequency
};

enum class KalmanPreset : int
{
    Smooth   = 0,
    Balanced = 1,
    Reactive = 2,
    Manual   = 3
};

struct KalmanParams
{
    KalmanPreset preset            = KalmanPreset::Balanced;
    double       process_noise     = 1.0e-4;
    double       measurement_noise = 2.5e-3;
    double       init_variance     = 0.5;
    double       plv_threshold     = 0.65;
    int          max_iterations    = 48;
    double       convergence_eps   = 1.0e-4;
};

struct JobDesc
{
    const double* frames        = nullptr;  // pointer to host data (size = frame_count * frame_length)
    const double* preview_mask  = nullptr;  // optional per-bin preview mask (freq domain)
    int           frame_count   = 0;
    int           frame_length  = 0;
    std::uint64_t user_tag      = 0ULL;
    std::uint32_t flags         = 0U;
    int           upscale       = 1;
    MaskParams    mask{};
    CycleParams   cycles{};
    KalmanParams  kalman{};
};

struct ResultInfo
{
    std::uint64_t user_tag      = 0ULL;
    int           frame_count   = 0;
    int           frame_length  = 0;
    int           cycle_count   = 0;
    int           dominant_cycle= -1;
    double        dominant_period = 0.0;
    double        dominant_snr    = 0.0;
    double        dominant_plv    = 0.0;
    double        dominant_confidence = 0.0;
    double        line_phase_deg   = 0.0;
    double        line_amplitude   = 0.0;
    double        line_period      = 0.0;
    double        line_eta         = 0.0;
    double        line_confidence  = 0.0;
    double        line_value       = 0.0;
    double        elapsed_ms    = 0.0;
    int           status        = STATUS_ERROR;
};

} // namespace gpuengine
