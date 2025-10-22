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
    int     max_cycle_count  = 12;
    int     stream_count     = 2;
    bool    enable_profiling = false;
};

struct MaskParams
{
    double sigma_period = 48.0;  // period (bars) translated to gaussian sigma in bins
    double threshold    = 0.05;  // relative magnitude threshold
    double softness     = 0.2;   // gain curve softness
};

struct CycleParams
{
    const double* periods   = nullptr; // pointer to array of cycle periods (bars)
    int           count     = 0;
    double        width     = 0.25;    // fractional width relative to centre frequency
};

struct PhaseParams
{
    double blend            = 0.65;
    double phase_gain       = 0.08;
    double freq_gain        = 0.002;
    double amp_gain         = 0.08;
    double freq_prior_blend = 0.15;
    double min_period       = 8.0;
    double max_period       = 512.0;
    double snr_floor        = 0.25;
    int    frames_for_snr   = 1;
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
    PhaseParams   phase{};
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
    double        pll_phase_deg   = 0.0;
    double        pll_amplitude   = 0.0;
    double        pll_period      = 0.0;
    double        pll_eta         = 0.0;
    double        pll_confidence  = 0.0;
    double        pll_reconstructed = 0.0;
    double        elapsed_ms    = 0.0;
    int           status        = STATUS_ERROR;
};

} // namespace gpuengine
