#pragma once

#include <cstdint>
#include <vector>

#include "GpuEngineExports.h"

namespace gpu_service
{
constexpr std::uint32_t MESSAGE_MAGIC = 0x55475057; // "WGPU"
constexpr std::uint16_t PROTOCOL_VERSION = 1;

enum class Command : std::uint16_t
  {
   Ping      = 1,
   Init      = 2,
   SubmitJob = 3,
   Poll      = 4,
   Fetch     = 5,
   Shutdown  = 6
  };

enum class Status : std::int32_t
  {
   Ok                = 0,
   InitFailed        = -1,
   SubmitFailed      = -2,
   PollFailed        = -3,
   FetchFailed       = -4,
   DecodeError       = -10,
   NotImplemented    = -11,
   InternalError     = -12
  };

struct MessageHeader
  {
   std::uint32_t magic      = MESSAGE_MAGIC;
   std::uint16_t version    = PROTOCOL_VERSION;
   std::uint16_t command    = 0;
   std::uint32_t payload_sz = 0;
  };

struct StatusResponse
  {
   std::int32_t status;
  };

struct InitRequest
  {
   std::int32_t device_id;
   std::int32_t window_size;
   std::int32_t hop_size;
   std::int32_t max_batch;
   std::int32_t enable_profiling; // bool (0/1)
  };

struct SubmitJobRequest
  {
   std::int32_t frame_count;
   std::int32_t frame_length;
   std::uint32_t flags;
   std::uint64_t user_tag;

   double mask_sigma_period;
   double mask_threshold;
   double mask_softness;
   double mask_min_period;
   double mask_max_period;
   std::int32_t upscale_factor;

   std::int32_t cycle_count;
   double cycle_width;

   std::int32_t kalman_preset;
   double kalman_process_noise;
   double kalman_measurement_noise;
   double kalman_init_variance;
   double kalman_plv_threshold;
   std::int32_t kalman_max_iterations;
   double kalman_epsilon;

   std::uint32_t frames_len;     // doubles following
   std::uint32_t preview_len;    // doubles following
   std::uint32_t cycles_len;     // doubles following
  };

struct SubmitJobResponse
  {
   std::int32_t status;
   std::uint64_t handle;
  };

struct PollRequest
  {
   std::uint64_t handle;
  };

struct PollResponse
  {
   std::int32_t status;
   std::int32_t job_status;
  };

struct FetchRequest
  {
   std::uint64_t handle;
  };

struct FetchResponseHeader
  {
   std::int32_t status;
   gpuengine::ResultInfo info;
   std::uint32_t total_samples;
   std::uint32_t cycle_samples;
   std::uint32_t per_cycle_count;
  };

} // namespace gpu_service
