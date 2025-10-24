#include "GpuEngineClientApi.h"

#include <windows.h>

#include <algorithm>
#include <mutex>
#include <string>
#include <vector>
#include <cstring>

#include "ServiceProtocol.h"

namespace
{
constexpr wchar_t PIPE_NAME[] = L"\\\\.\\pipe\\WaveSpecGpuSvc";

std::mutex g_mutex;
std::string g_last_error;

void SetLastErrorString(const std::string& msg)
{
   g_last_error = msg;
}

class PipeClient
{
public:
   ~PipeClient()
   {
      Close();
   }

   bool EnsureConnected()
   {
      if(m_pipe != INVALID_HANDLE_VALUE)
         return true;

      while(true)
        {
         HANDLE hPipe = CreateFileW(PIPE_NAME,
                                     GENERIC_READ | GENERIC_WRITE,
                                     0,
                                     nullptr,
                                     OPEN_EXISTING,
                                     0,
                                     nullptr);
         if(hPipe != INVALID_HANDLE_VALUE)
           {
            m_pipe = hPipe;
            return true;
           }

         DWORD err = GetLastError();
         if(err != ERROR_PIPE_BUSY)
           {
            SetLastErrorString("CreateFileW falhou: " + std::to_string(err));
            return false;
           }

         if(!WaitNamedPipeW(PIPE_NAME, 3000))
           {
            err = GetLastError();
            SetLastErrorString("WaitNamedPipe falhou: " + std::to_string(err));
            return false;
           }
        }
   }

   void Close()
   {
      if(m_pipe != INVALID_HANDLE_VALUE)
        {
         CloseHandle(m_pipe);
         m_pipe = INVALID_HANDLE_VALUE;
        }
   }

   bool WriteExact(const void* data, std::size_t bytes)
   {
      const std::uint8_t* ptr = static_cast<const std::uint8_t*>(data);
      std::size_t remaining = bytes;
      while(remaining > 0)
        {
         DWORD written = 0;
         if(!WriteFile(m_pipe, ptr, static_cast<DWORD>(remaining), &written, nullptr) || written == 0)
           {
            SetLastErrorString("WriteFile falhou: " + std::to_string(GetLastError()));
            Close();
            return false;
           }
         ptr += written;
         remaining -= written;
        }
      return true;
   }

   bool ReadExact(void* data, std::size_t bytes)
   {
      std::uint8_t* ptr = static_cast<std::uint8_t*>(data);
      std::size_t remaining = bytes;
      while(remaining > 0)
        {
         DWORD read = 0;
         if(!ReadFile(m_pipe, ptr, static_cast<DWORD>(remaining), &read, nullptr) || read == 0)
           {
            SetLastErrorString("ReadFile falhou: " + std::to_string(GetLastError()));
            Close();
            return false;
           }
         ptr += read;
         remaining -= read;
        }
      return true;
   }

   bool SendCommand(gpu_service::Command cmd, const void* payload, std::uint32_t payload_sz)
     {
      gpu_service::MessageHeader header{ gpu_service::MESSAGE_MAGIC, gpu_service::PROTOCOL_VERSION, static_cast<std::uint16_t>(cmd), payload_sz };
      if(!WriteExact(&header, sizeof(header)))
         return false;
      if(payload_sz > 0 && !WriteExact(payload, payload_sz))
         return false;
      return true;
     }

   bool ReadMessage(gpu_service::Command expected, std::vector<std::uint8_t>& payload_out)
     {
      gpu_service::MessageHeader header{};
      if(!ReadExact(&header, sizeof(header)))
         return false;
      if(header.magic != gpu_service::MESSAGE_MAGIC)
        {
         SetLastErrorString("Magic inválido recebido");
         Close();
         return false;
        }
      if(header.version != gpu_service::PROTOCOL_VERSION)
        {
         SetLastErrorString("Versão de protocolo incompatível");
         Close();
         return false;
        }
      if(header.command != static_cast<std::uint16_t>(expected))
        {
         SetLastErrorString("Comando inesperado na resposta");
         Close();
         return false;
        }
      payload_out.resize(header.payload_sz);
      if(header.payload_sz > 0 && !ReadExact(payload_out.data(), payload_out.size()))
         return false;
      return true;
     }

private:
   HANDLE m_pipe = INVALID_HANDLE_VALUE;
};

PipeClient g_client;

inline int StatusToInt(gpu_service::Status status)
{
   return static_cast<int>(status);
}

} // namespace

static int HandleStatusResponse(const std::vector<std::uint8_t>& payload)
{
   if(payload.size() != sizeof(gpu_service::StatusResponse))
     {
      SetLastErrorString("Payload de status inesperado");
      return -1;
     }
   gpu_service::StatusResponse resp{};
   std::memcpy(&resp, payload.data(), sizeof(resp));
   return resp.status;
}

extern "C" {

GPU_EXPORT int GpuEngine_Init(int device_id,
                              int window_size,
                              int hop_size,
                              int max_batch_size,
                              bool enable_profiling)
{
    std::lock_guard<std::mutex> lock(g_mutex);
    g_last_error.clear();
    if(!g_client.EnsureConnected())
        return static_cast<int>(gpu_service::Status::InternalError);

    gpu_service::InitRequest req{ device_id, window_size, hop_size, max_batch_size, enable_profiling ? 1 : 0 };
    if(!g_client.SendCommand(gpu_service::Command::Init, &req, sizeof(req)))
        return static_cast<int>(gpu_service::Status::InternalError);

    std::vector<std::uint8_t> payload;
    if(!g_client.ReadMessage(gpu_service::Command::Init, payload))
        return static_cast<int>(gpu_service::Status::InternalError);

    return HandleStatusResponse(payload);
}

GPU_EXPORT void GpuEngine_Shutdown()
{
    std::lock_guard<std::mutex> lock(g_mutex);
    g_last_error.clear();
    if(g_client.EnsureConnected())
      {
       g_client.SendCommand(gpu_service::Command::Shutdown, nullptr, 0);
       std::vector<std::uint8_t> payload;
       g_client.ReadMessage(gpu_service::Command::Shutdown, payload);
      }
    g_client.Close();
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
    std::lock_guard<std::mutex> lock(g_mutex);
    g_last_error.clear();
    if(!g_client.EnsureConnected())
        return static_cast<int>(gpu_service::Status::InternalError);

    const std::uint32_t frames_len = static_cast<std::uint32_t>(static_cast<std::uint64_t>(frame_count) * frame_length);

    gpu_service::SubmitJobRequest req{};
    req.frame_count = frame_count;
    req.frame_length = frame_length;
    req.flags = flags;
    req.user_tag = user_tag;
    req.mask_sigma_period = mask_sigma_period;
    req.mask_threshold = mask_threshold;
    req.mask_softness  = mask_softness;
    req.mask_min_period = mask_min_period;
    req.mask_max_period = mask_max_period;
    req.upscale_factor = upscale_factor;
    req.cycle_count    = cycle_count;
    req.cycle_width    = cycle_width;
    req.kalman_preset  = kalman_preset;
    req.kalman_process_noise = kalman_process_noise;
    req.kalman_measurement_noise = kalman_measurement_noise;
    req.kalman_init_variance = kalman_init_variance;
    req.kalman_plv_threshold = kalman_plv_threshold;
    req.kalman_max_iterations = kalman_max_iterations;
    req.kalman_epsilon = kalman_epsilon;
    req.frames_len     = frames_len;
    req.preview_len    = 0; // preview mask desativado por enquanto
    req.cycles_len     = (cycle_periods && cycle_count > 0) ? static_cast<std::uint32_t>(cycle_count) : 0;

    const std::size_t payload_size = sizeof(req)
                                     + static_cast<std::size_t>(req.frames_len)  * sizeof(double)
                                     + static_cast<std::size_t>(req.preview_len) * sizeof(double)
                                     + static_cast<std::size_t>(req.cycles_len)  * sizeof(double);

    std::vector<std::uint8_t> payload(payload_size);
    std::uint8_t* cursor = payload.data();
    std::memcpy(cursor, &req, sizeof(req));
    cursor += sizeof(req);

    if(req.frames_len > 0)
      {
       std::memcpy(cursor, frames, req.frames_len * sizeof(double));
       cursor += req.frames_len * sizeof(double);
      }
    if(false)
      {
       std::memcpy(cursor, preview_mask, req.preview_len * sizeof(double));
       cursor += req.preview_len * sizeof(double);
      }
    if(req.cycles_len > 0 && cycle_periods)
      {
       std::memcpy(cursor, cycle_periods, req.cycles_len * sizeof(double));
      }

    if(!g_client.SendCommand(gpu_service::Command::SubmitJob, payload.data(), static_cast<std::uint32_t>(payload.size())))
        return static_cast<int>(gpu_service::Status::InternalError);

    std::vector<std::uint8_t> response;
    if(!g_client.ReadMessage(gpu_service::Command::SubmitJob, response))
        return static_cast<int>(gpu_service::Status::InternalError);

    if(response.size() != sizeof(gpu_service::SubmitJobResponse))
      {
       SetLastErrorString("Resposta SubmitJob tamanho incorreto");
       return static_cast<int>(gpu_service::Status::InternalError);
      }

    gpu_service::SubmitJobResponse resp{};
    std::memcpy(&resp, response.data(), sizeof(resp));
    if(out_handle)
        *out_handle = resp.handle;
    return resp.status;
}

GPU_EXPORT int GpuEngine_PollStatus(std::uint64_t handle_value,
                                    int* out_status)
{
    std::lock_guard<std::mutex> lock(g_mutex);
    g_last_error.clear();
    if(!g_client.EnsureConnected())
        return static_cast<int>(gpu_service::Status::InternalError);

    gpu_service::PollRequest req{ handle_value };
    if(!g_client.SendCommand(gpu_service::Command::Poll, &req, sizeof(req)))
        return static_cast<int>(gpu_service::Status::InternalError);

    std::vector<std::uint8_t> response;
    if(!g_client.ReadMessage(gpu_service::Command::Poll, response))
        return static_cast<int>(gpu_service::Status::InternalError);

    if(response.size() != sizeof(gpu_service::PollResponse))
      {
       SetLastErrorString("Resposta Poll tamanho incorreto");
       return static_cast<int>(gpu_service::Status::InternalError);
      }

    gpu_service::PollResponse resp{};
    std::memcpy(&resp, response.data(), sizeof(resp));
    if(out_status)
        *out_status = resp.job_status;
    return resp.status;
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
                                     gpuengine::ResultInfo* info)
{
    if(!wave_out || !preview_out || !noise_out || !phase_out || !phase_unwrapped_out ||
       !amplitude_out || !period_out || !frequency_out || !eta_out || !countdown_out ||
       !recon_out || !kalman_out || !confidence_out || !amp_delta_out || !turn_signal_out ||
       !direction_out || !power_out || !velocity_out)
      {
       SetLastErrorString("Buffers inválidos em FetchResult");
       return static_cast<int>(gpu_service::Status::FetchFailed);
      }

    std::lock_guard<std::mutex> lock(g_mutex);
    g_last_error.clear();
    if(!g_client.EnsureConnected())
        return static_cast<int>(gpu_service::Status::InternalError);

    gpu_service::FetchRequest req{ handle_value };
    if(!g_client.SendCommand(gpu_service::Command::Fetch, &req, sizeof(req)))
        return static_cast<int>(gpu_service::Status::InternalError);

    std::vector<std::uint8_t> response;
    if(!g_client.ReadMessage(gpu_service::Command::Fetch, response))
        return static_cast<int>(gpu_service::Status::InternalError);

    if(response.size() < sizeof(gpu_service::FetchResponseHeader))
      {
       SetLastErrorString("Resposta Fetch truncada");
       return static_cast<int>(gpu_service::Status::InternalError);
      }

    gpu_service::FetchResponseHeader resp{};
    std::memcpy(&resp, response.data(), sizeof(resp));
    if(resp.status != static_cast<int>(gpu_service::Status::Ok))
        return resp.status;

    std::size_t offset = sizeof(resp);
    const std::size_t total = resp.total_samples;
    const std::size_t cycles_total = resp.cycle_samples;
    const std::size_t per_cycle_count = resp.per_cycle_count;

    const std::size_t single_blocks = 18; // includes direction/power/velocity
    const std::size_t per_cycle_blocks = 15; // phase_all...velocity_all

    const std::size_t expected = total * sizeof(double) * single_blocks
                               + cycles_total * sizeof(double) * (per_cycle_blocks + 1)
                               + per_cycle_count * sizeof(double) * 2;
    if(response.size() - offset != expected)
      {
       SetLastErrorString("Payload Fetch tamanho incorreto");
       return static_cast<int>(gpu_service::Status::InternalError);
      }

    auto copy_array = [&](double* dest, std::size_t count) {
       if(count == 0)
          return true;
       if(offset + count * sizeof(double) > response.size())
       {
          SetLastErrorString("Payload Fetch fora de faixa");
          return false;
       }
       if(dest)
          std::memcpy(dest, response.data() + offset, count * sizeof(double));
       offset += count * sizeof(double);
       return true;
    };

    if(!copy_array(wave_out, total) || !copy_array(preview_out, total) ||
       !copy_array(noise_out, total) || !copy_array(phase_out, total) ||
       !copy_array(phase_unwrapped_out, total) || !copy_array(amplitude_out, total) ||
       !copy_array(period_out, total) || !copy_array(frequency_out, total) ||
       !copy_array(eta_out, total) || !copy_array(countdown_out, total) ||
       !copy_array(recon_out, total) || !copy_array(kalman_out, total) ||
       !copy_array(confidence_out, total) || !copy_array(amp_delta_out, total) ||
       !copy_array(turn_signal_out, total) || !copy_array(direction_out, total) ||
       !copy_array(power_out, total) || !copy_array(velocity_out, total))
      {
       return static_cast<int>(gpu_service::Status::InternalError);
      }

    if(cycles_total > 0)
      {
       if(!copy_array(cycles_out, cycles_total) ||
          !copy_array(phase_all_out, cycles_total) ||
          !copy_array(phase_unwrapped_all_out, cycles_total) ||
          !copy_array(amplitude_all_out, cycles_total) ||
          !copy_array(period_all_out, cycles_total) ||
          !copy_array(frequency_all_out, cycles_total) ||
          !copy_array(eta_all_out, cycles_total) ||
          !copy_array(countdown_all_out, cycles_total) ||
          !copy_array(direction_all_out, cycles_total) ||
          !copy_array(recon_all_out, cycles_total) ||
          !copy_array(kalman_all_out, cycles_total) ||
          !copy_array(turn_all_out, cycles_total) ||
          !copy_array(confidence_all_out, cycles_total) ||
          !copy_array(amp_delta_all_out, cycles_total) ||
          !copy_array(power_all_out, cycles_total) ||
          !copy_array(velocity_all_out, cycles_total))
         {
          return static_cast<int>(gpu_service::Status::InternalError);
         }
      }

    if(per_cycle_count > 0)
      {
       if(!copy_array(plv_cycles_out, per_cycle_count) ||
          !copy_array(snr_cycles_out, per_cycle_count))
         {
          return static_cast<int>(gpu_service::Status::InternalError);
         }
      }

    // ensure offset consumed all
    if(offset != response.size())
    {
        SetLastErrorString("Payload Fetch tamanho inconsist.");
        return static_cast<int>(gpu_service::Status::InternalError);
    }

    if(info)
      *info = resp.info;

    return static_cast<int>(gpu_service::Status::Ok);
}

GPU_EXPORT int GpuEngine_GetStats(double* avg_ms, double* max_ms)
{
    if(avg_ms) *avg_ms = 0.0;
    if(max_ms) *max_ms = 0.0;
    return static_cast<int>(gpu_service::Status::NotImplemented);
}

GPU_EXPORT int GpuEngine_GetLastError(char* buffer, int buffer_len)
{
    std::lock_guard<std::mutex> lock(g_mutex);
    if(buffer && buffer_len > 0)
      {
       const int to_copy = static_cast<int>(std::min<std::size_t>(g_last_error.size(), buffer_len - 1));
       std::memcpy(buffer, g_last_error.data(), to_copy);
       buffer[to_copy] = '\0';
      }
    return static_cast<int>(gpu_service::Status::Ok);
}

} // extern "C"
