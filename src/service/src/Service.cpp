#include "Service.h"

#include "PipeServer.h"
#include "ServiceProtocol.h"

#include <algorithm>
#include <cstddef>
#include <cstring>
#include <iostream>
#include <sstream>
#include <iomanip>
#include <chrono>
#include <vector>
#include <fstream>
#include <cstdlib>
#include <filesystem>
#include <windows.h>

#ifdef max
# undef max
#endif
#ifdef min
# undef min
#endif

#include "GpuEngineExports.h"

const char* BUILD_ID = "GPT5-2025-10-24 rev.1";

namespace
{
std::ofstream g_log;
bool g_logging_enabled = true;

std::filesystem::path LogFilePath()
{
    return std::filesystem::path("logs") / "gpu_service.log";
}

bool LoggingEnabled()
{
    static bool initialized = false;
    if(!initialized)
      {
       initialized = true;
       if(const char* env = std::getenv("GPU_SERVICE_LOG"))
         {
          if(_stricmp(env, "0") == 0 || _stricmp(env, "false") == 0 || _stricmp(env, "off") == 0)
             g_logging_enabled = false;
         }
      }
    return g_logging_enabled;
}

std::string NowTimestamp()
{
    using clock = std::chrono::system_clock;
    auto now = clock::now();
    auto t = clock::to_time_t(now);
    auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(now.time_since_epoch()) % 1000;
    std::tm tm{};
    localtime_s(&tm, &t);
    std::ostringstream oss;
    oss << std::put_time(&tm, "%H:%M:%S") << '.' << std::setw(3) << std::setfill('0') << ms.count();
    return oss.str();
}

void LogMsg(const std::string& msg)
{
    if(!LoggingEnabled())
       return;

    const std::string line = '[' + NowTimestamp() + "] " + msg;
    std::cout << line << std::endl;
    if(g_log.is_open())
    {
        g_log << line << std::endl;
        g_log.flush();
    }
}
}

namespace
{
class EngineState
{
public:
   int Init(const gpu_service::InitRequest& req)
   {
      Shutdown();
      return GpuEngine_Init(req.device_id,
                            req.window_size,
                            req.hop_size,
                            req.max_batch,
                            req.enable_profiling != 0);
   }

   void Shutdown()
   {
      GpuEngine_Shutdown();
   }
};

EngineState g_engine;

constexpr wchar_t PIPE_NAME[] = L"\\\\.\\pipe\\WaveSpecGpuSvc";

void PrintBanner()
{
    const DWORD pid = GetCurrentProcessId();
    LogMsg("[GpuEngineService] ==================================================");
    LogMsg("[GpuEngineService] GPU Engine Service v2");
    LogMsg(std::string("[GpuEngineService] Build: ") + BUILD_ID + " | PID: " + std::to_string(pid));
    LogMsg(std::string("[GpuEngineService] Pipe: ") + R"(\\.\pipe\WaveSpecGpuSvc)");
    if(LoggingEnabled())
       LogMsg(std::string("[GpuEngineService] Log file: ") + LogFilePath().string());
    LogMsg("[GpuEngineService] ==================================================");
}




template<typename T>
bool ReadStruct(PipeServer& pipe, const std::uint8_t*& cursor, const std::uint8_t* end, T& out)
{
   if(static_cast<std::size_t>(end - cursor) < sizeof(T))
      return false;
   std::memcpy(&out, cursor, sizeof(T));
   cursor += sizeof(T);
   return true;
}

} // namespace

Service::Service() = default;

int Service::Run()
{
   if(LoggingEnabled())
     {
      const auto log_path = LogFilePath();
      try
        {
         std::filesystem::create_directories(log_path.parent_path());
        }
      catch(...)
        {
         // Ignore directory creation errors; we'll attempt to open anyway
        }

      g_log.open(log_path, std::ios::app);
      if(g_log.is_open())
        {
         g_log << "\n==== Serviço iniciado (" << BUILD_ID << ") ====\n";
         g_log.flush();
        }
     }

   PipeServer server(PIPE_NAME);
   PrintBanner();

   while(true)
     {
      if(!server.Create())
        {
         Sleep(1000);
         continue;
        }

      LogMsg("Aguardando conexÃ£o de cliente...");
      if(!server.WaitForClient())
        {
         std::cout << "[GpuEngineService] Falha ao conectar. Tentando novamente." << std::endl;
         continue;
        }

      LogMsg("Cliente conectado");
      ProcessClient(server);
      server.Disconnect();
      server.Close();
     }

   return 0;
}

bool Service::ProcessClient(PipeServer& pipe)
{
   using namespace gpu_service;

   while(true)
     {
      MessageHeader header{};
      if(!pipe.ReadExact(&header, sizeof(header)))
        {
         LogMsg("Cliente desconectou ou leitura falhou");
         return false;
        }

      if(header.magic != MESSAGE_MAGIC)
        {
         std::cout << "[GpuEngineService] Magic invÃ¡lido recebido. Encerrando conexÃ£o." << std::endl;
         SendStatus(pipe, Command::Ping, Status::DecodeError);
         return false;
        }

      const Command cmd = static_cast<Command>(header.command);
      std::vector<std::uint8_t> payload(header.payload_sz);
      if(header.payload_sz > 0 && !pipe.ReadExact(payload.data(), payload.size()))
        {
         std::cout << "[GpuEngineService] Falha ao ler payload. Encerrando." << std::endl;
         return false;
        }

      LogMsg("Comando=" + std::to_string(header.command) + ", payload=" + std::to_string(header.payload_sz));

      const std::uint8_t* cursor = payload.data();
      const std::uint8_t* end    = payload.data() + payload.size();

      switch(cmd)
        {
         case Command::Ping:
            SendStatus(pipe, cmd, Status::Ok);
            break;

         case Command::Init:
           {
            InitRequest req{};
            if(!ReadStruct(pipe, cursor, end, req))
              {
               SendStatus(pipe, cmd, Status::DecodeError);
               break;
              }

            LogMsg("GpuEngine_Init(device=" + std::to_string(req.device_id) +
                    ", window=" + std::to_string(req.window_size) +
                    ", hop=" + std::to_string(req.hop_size) +
                    ", batch=" + std::to_string(req.max_batch) + ")");

            int rc = g_engine.Init(req);
            if(rc != 0)
              {
               char buffer[256] = {0};
               if(GpuEngine_GetLastError(buffer, sizeof(buffer)) == 0)
                  LogMsg(std::string("GpuEngine_Init falhou (rc=" + std::to_string(rc) + "): ") + buffer);
               else
                  LogMsg(std::string("GpuEngine_Init falhou (rc=") + std::to_string(rc) + ")");
              }
            else
              {
               LogMsg("GpuEngine_Init concluído com sucesso (max_cycles=24)");
              }

            SendStatus(pipe, cmd, rc == 0 ? Status::Ok : Status::InitFailed);
            break;
           }

         case Command::SubmitJob:
           {
            SubmitJobRequest req{};
            if(!ReadStruct(pipe, cursor, end, req))
              {
               SendStatus(pipe, cmd, Status::DecodeError);
               break;
              }

            std::size_t expected = static_cast<std::size_t>(req.frames_len) * sizeof(double)
                                   + static_cast<std::size_t>(req.preview_len) * sizeof(double)
                                   + static_cast<std::size_t>(req.cycles_len) * sizeof(double);
            if(static_cast<std::size_t>(end - cursor) < expected)
              {
               SendStatus(pipe, cmd, Status::DecodeError);
               break;
              }

            std::vector<double> frames(req.frames_len);
            if(req.frames_len > 0)
              {
               std::memcpy(frames.data(), cursor, req.frames_len * sizeof(double));
               cursor += req.frames_len * sizeof(double);
              }

            std::vector<double> preview(req.preview_len);
            if(req.preview_len > 0)
              {
               std::memcpy(preview.data(), cursor, req.preview_len * sizeof(double));
               cursor += req.preview_len * sizeof(double);
              }

            std::vector<double> cycles(req.cycles_len);
            if(req.cycles_len > 0)
              {
               std::memcpy(cycles.data(), cursor, req.cycles_len * sizeof(double));
               cursor += req.cycles_len * sizeof(double);
              }

            LogMsg("SubmitJob handle user_tag=" + std::to_string(req.user_tag) + " frames=" + std::to_string(req.frame_count) + " len=" + std::to_string(req.frame_length) + " cycles=" + std::to_string(req.cycle_count));
            std::uint64_t handle = 0;
            LogMsg("SubmitJob user_tag=" + std::to_string(req.user_tag) +
                   " frames=" + std::to_string(req.frame_count) +
                   " len=" + std::to_string(req.frame_length) +
                   " cycles=" + std::to_string(req.cycle_count));

            int rc = GpuEngine_SubmitJob(frames.data(), req.frame_count, req.frame_length, req.user_tag, req.flags,
                                         preview.empty() ? nullptr : preview.data(),
                                         req.mask_sigma_period,
                                         req.mask_threshold,
                                         req.mask_softness,
                                         req.mask_min_period,
                                         req.mask_max_period,
                                         req.upscale_factor,
                                         cycles.empty() ? nullptr : cycles.data(),
                                         req.cycle_count,
                                         req.cycle_width,
                                         req.kalman_preset,
                                         req.kalman_process_noise,
                                         req.kalman_measurement_noise,
                                         req.kalman_init_variance,
                                         req.kalman_plv_threshold,
                                         req.kalman_max_iterations,
                                         req.kalman_epsilon,
                                         &handle);

            if(rc == 0)
               LogMsg("SubmitJob OK handle=" + std::to_string(handle));
            else
               LogMsg("SubmitJob falhou rc=" + std::to_string(rc));

            SubmitJobResponse resp{ rc == 0 ? static_cast<int>(Status::Ok) : static_cast<int>(Status::SubmitFailed), handle };
            MessageHeader resp_header{ MESSAGE_MAGIC, PROTOCOL_VERSION, static_cast<std::uint16_t>(Command::SubmitJob), static_cast<std::uint32_t>(sizeof(resp)) };
            pipe.WriteExact(&resp_header, sizeof(resp_header));
            pipe.WriteExact(&resp, sizeof(resp));

            if(rc == 0)
               m_jobs[handle] = { req.frame_count, req.frame_length, req.cycle_count };
            break;
           }

         case Command::Poll:
           {
            PollRequest req{};
            if(!ReadStruct(pipe, cursor, end, req))
              {
               SendStatus(pipe, cmd, Status::DecodeError);
               break;
              }
            int job_status = 0;
            int rc = GpuEngine_PollStatus(req.handle, &job_status);
            if(rc == 0)
               LogMsg("PollStatus handle=" + std::to_string(req.handle) + " status=" + std::to_string(job_status));
            else
               LogMsg("PollStatus falhou handle=" + std::to_string(req.handle) + " rc=" + std::to_string(rc));

            PollResponse resp{ rc == 0 ? static_cast<int>(Status::Ok) : static_cast<int>(Status::PollFailed), job_status };
            MessageHeader resp_header{ MESSAGE_MAGIC, PROTOCOL_VERSION, static_cast<std::uint16_t>(Command::Poll), static_cast<std::uint32_t>(sizeof(resp)) };
            pipe.WriteExact(&resp_header, sizeof(resp_header));
            pipe.WriteExact(&resp, sizeof(resp));
            break;
           }

         case Command::Fetch:
           {
            FetchRequest req{};
            if(!ReadStruct(pipe, cursor, end, req))
              {
               SendStatus(pipe, cmd, Status::DecodeError);
               break;
              }

            auto it = m_jobs.find(req.handle);
            if(it == m_jobs.end())
              {
               SendStatus(pipe, cmd, Status::FetchFailed);
               break;
              }
            const JobMetadata meta = it->second;

            const std::size_t total = static_cast<std::size_t>(meta.frame_count) * static_cast<std::size_t>(meta.frame_length);
            if(total == 0)
              {
               SendStatus(pipe, cmd, Status::FetchFailed);
               break;
              }

            std::vector<double> wave(total), preview(total), noise(total), phase(total), phase_unwrapped(total),
                                 amplitude(total), period(total), frequency(total), eta(total), countdown(total),
                                 recon(total), kalman(total), confidence(total), amp_delta(total), turn(total),
                                 direction(total), power(total), velocity(total);

            const std::size_t cycles_total_requested = meta.cycle_count > 0 ? static_cast<std::size_t>(meta.cycle_count) * total : 0;
            std::vector<double> cycles(cycles_total_requested);

            std::vector<double> phase_all, phase_unwrapped_all, amplitude_all, period_all, frequency_all,
                                 eta_all, countdown_all, direction_all, recon_all, kalman_all,
                                 turn_all, confidence_all, amp_delta_all, power_all, velocity_all;
            std::vector<double> plv_all(meta.cycle_count > 0 ? meta.cycle_count : 0);
            std::vector<double> snr_all(meta.cycle_count > 0 ? meta.cycle_count : 0);

            if(cycles_total_requested > 0)
            {
               phase_all.resize(cycles_total_requested);
               phase_unwrapped_all.resize(cycles_total_requested);
               amplitude_all.resize(cycles_total_requested);
               period_all.resize(cycles_total_requested);
               frequency_all.resize(cycles_total_requested);
               eta_all.resize(cycles_total_requested);
               countdown_all.resize(cycles_total_requested);
               direction_all.resize(cycles_total_requested);
               recon_all.resize(cycles_total_requested);
               kalman_all.resize(cycles_total_requested);
               turn_all.resize(cycles_total_requested);
               confidence_all.resize(cycles_total_requested);
               amp_delta_all.resize(cycles_total_requested);
               power_all.resize(cycles_total_requested);
               velocity_all.resize(cycles_total_requested);
            }

            gpuengine::ResultInfo info{};
            int rc = GpuEngine_FetchResult(req.handle,
                                           wave.data(),
                                           preview.data(),
                                           cycles_total_requested > 0 ? cycles.data() : nullptr,
                                           noise.data(),
                                           phase.data(),
                                           phase_unwrapped.data(),
                                           amplitude.data(),
                                           period.data(),
                                           frequency.data(),
                                           eta.data(),
                                           countdown.data(),
                                           recon.data(),
                                           kalman.data(),
                                           confidence.data(),
                                           amp_delta.data(),
                                           turn.data(),
                                           direction.data(),
                                           power.data(),
                                           velocity.data(),
                                           cycles_total_requested > 0 ? phase_all.data() : nullptr,
                                           cycles_total_requested > 0 ? phase_unwrapped_all.data() : nullptr,
                                           cycles_total_requested > 0 ? amplitude_all.data() : nullptr,
                                           cycles_total_requested > 0 ? period_all.data() : nullptr,
                                           cycles_total_requested > 0 ? frequency_all.data() : nullptr,
                                           cycles_total_requested > 0 ? eta_all.data() : nullptr,
                                           cycles_total_requested > 0 ? countdown_all.data() : nullptr,
                                           cycles_total_requested > 0 ? direction_all.data() : nullptr,
                                           cycles_total_requested > 0 ? recon_all.data() : nullptr,
                                           cycles_total_requested > 0 ? kalman_all.data() : nullptr,
                                           cycles_total_requested > 0 ? turn_all.data() : nullptr,
                                           cycles_total_requested > 0 ? confidence_all.data() : nullptr,
                                           cycles_total_requested > 0 ? amp_delta_all.data() : nullptr,
                                           cycles_total_requested > 0 ? power_all.data() : nullptr,
                                           cycles_total_requested > 0 ? velocity_all.data() : nullptr,
                                           (meta.cycle_count > 0 ? plv_all.data() : nullptr),
                                           (meta.cycle_count > 0 ? snr_all.data() : nullptr),
                                           &info);
            if(rc != 0)
              {
               LogMsg("FetchResult falhou handle=" + std::to_string(req.handle) + " rc=" + std::to_string(rc));
               SendStatus(pipe, cmd, Status::FetchFailed);
               break;
              }

            const std::size_t cycles_total = info.cycle_count > 0 ? static_cast<std::size_t>(info.cycle_count) * total : 0;
            LogMsg("FetchResult OK handle=" + std::to_string(req.handle) +
                   " frames=" + std::to_string(info.frame_count) +
                   " cycles=" + std::to_string(info.cycle_count));
            if(cycles_total == 0)
            {
               cycles.clear();
               phase_all.clear();
               phase_unwrapped_all.clear();
               amplitude_all.clear();
               period_all.clear();
               frequency_all.clear();
               eta_all.clear();
               countdown_all.clear();
               direction_all.clear();
               recon_all.clear();
               kalman_all.clear();
               turn_all.clear();
               confidence_all.clear();
               amp_delta_all.clear();
               power_all.clear();
               velocity_all.clear();
               plv_all.clear();
               snr_all.clear();
            }
            else if(cycles_total < cycles_total_requested)
            {
               cycles.resize(cycles_total);
               phase_all.resize(cycles_total);
               phase_unwrapped_all.resize(cycles_total);
               amplitude_all.resize(cycles_total);
               period_all.resize(cycles_total);
               frequency_all.resize(cycles_total);
               eta_all.resize(cycles_total);
               countdown_all.resize(cycles_total);
               direction_all.resize(cycles_total);
               recon_all.resize(cycles_total);
               kalman_all.resize(cycles_total);
               turn_all.resize(cycles_total);
               confidence_all.resize(cycles_total);
               amp_delta_all.resize(cycles_total);
               power_all.resize(cycles_total);
               velocity_all.resize(cycles_total);
            }
            if(static_cast<std::size_t>(info.cycle_count) != plv_all.size())
            {
               plv_all.resize(std::max(info.cycle_count, 0));
            }
            if(static_cast<std::size_t>(info.cycle_count) != snr_all.size())
            {
               snr_all.resize(std::max(info.cycle_count, 0));
            }

            FetchResponseHeader resp_hdr{};
            resp_hdr.status = static_cast<int>(Status::Ok);
            resp_hdr.info   = info;
            resp_hdr.total_samples = static_cast<std::uint32_t>(total);
            resp_hdr.cycle_samples = static_cast<std::uint32_t>(cycles_total);
            resp_hdr.per_cycle_count = static_cast<std::uint32_t>(std::max(info.cycle_count, 0));

            const std::uint64_t single_bytes = static_cast<std::uint64_t>(total) * sizeof(double) * 18;
            const std::uint64_t per_cycle_series = static_cast<std::uint64_t>(cycles_total) * sizeof(double) * 15;
            const std::uint64_t cycles_bytes = static_cast<std::uint64_t>(cycles_total) * sizeof(double);
            const std::uint64_t per_cycle_metrics = static_cast<std::uint64_t>(resp_hdr.per_cycle_count) * sizeof(double) * 2;
            const std::uint64_t arrays_bytes = single_bytes + cycles_bytes + per_cycle_series + per_cycle_metrics;
            MessageHeader resp_header{ MESSAGE_MAGIC, PROTOCOL_VERSION, static_cast<std::uint16_t>(Command::Fetch), static_cast<std::uint32_t>(sizeof(resp_hdr) + arrays_bytes) };

            pipe.WriteExact(&resp_header, sizeof(resp_header));
            pipe.WriteExact(&resp_hdr, sizeof(resp_hdr));
            pipe.WriteExact(wave.data(), total * sizeof(double));
            pipe.WriteExact(preview.data(), total * sizeof(double));
            pipe.WriteExact(noise.data(), total * sizeof(double));
            pipe.WriteExact(phase.data(), total * sizeof(double));
            pipe.WriteExact(phase_unwrapped.data(), total * sizeof(double));
            pipe.WriteExact(amplitude.data(), total * sizeof(double));
            pipe.WriteExact(period.data(), total * sizeof(double));
            pipe.WriteExact(frequency.data(), total * sizeof(double));
            pipe.WriteExact(eta.data(), total * sizeof(double));
            pipe.WriteExact(countdown.data(), total * sizeof(double));
            pipe.WriteExact(recon.data(), total * sizeof(double));
            pipe.WriteExact(kalman.data(), total * sizeof(double));
            pipe.WriteExact(confidence.data(), total * sizeof(double));
            pipe.WriteExact(amp_delta.data(), total * sizeof(double));
            pipe.WriteExact(turn.data(), total * sizeof(double));
            pipe.WriteExact(direction.data(), total * sizeof(double));
            pipe.WriteExact(power.data(), total * sizeof(double));
            pipe.WriteExact(velocity.data(), total * sizeof(double));
            if(cycles_total > 0)
            {
                pipe.WriteExact(cycles.data(), cycles_total * sizeof(double));
                pipe.WriteExact(phase_all.data(), cycles_total * sizeof(double));
                pipe.WriteExact(phase_unwrapped_all.data(), cycles_total * sizeof(double));
                pipe.WriteExact(amplitude_all.data(), cycles_total * sizeof(double));
                pipe.WriteExact(period_all.data(), cycles_total * sizeof(double));
                pipe.WriteExact(frequency_all.data(), cycles_total * sizeof(double));
                pipe.WriteExact(eta_all.data(), cycles_total * sizeof(double));
                pipe.WriteExact(countdown_all.data(), cycles_total * sizeof(double));
                pipe.WriteExact(direction_all.data(), cycles_total * sizeof(double));
                pipe.WriteExact(recon_all.data(), cycles_total * sizeof(double));
                pipe.WriteExact(kalman_all.data(), cycles_total * sizeof(double));
                pipe.WriteExact(turn_all.data(), cycles_total * sizeof(double));
                pipe.WriteExact(confidence_all.data(), cycles_total * sizeof(double));
                pipe.WriteExact(amp_delta_all.data(), cycles_total * sizeof(double));
                pipe.WriteExact(power_all.data(), cycles_total * sizeof(double));
                pipe.WriteExact(velocity_all.data(), cycles_total * sizeof(double));
            }
            if(resp_hdr.per_cycle_count > 0)
            {
               pipe.WriteExact(plv_all.data(), resp_hdr.per_cycle_count * sizeof(double));
               pipe.WriteExact(snr_all.data(), resp_hdr.per_cycle_count * sizeof(double));
            }

            m_jobs.erase(it);
            break;
           }

         case Command::Shutdown:
           {
            g_engine.Shutdown();
            SendStatus(pipe, cmd, Status::Ok);
            return false;
           }

         default:
            SendStatus(pipe, cmd, Status::NotImplemented);
            break;
        }
     }
}

bool Service::SendStatus(PipeServer& pipe, gpu_service::Command command, gpu_service::Status status)
{
   gpu_service::MessageHeader header{ gpu_service::MESSAGE_MAGIC, gpu_service::PROTOCOL_VERSION, static_cast<std::uint16_t>(command), static_cast<std::uint32_t>(sizeof(gpu_service::StatusResponse)) };
   gpu_service::StatusResponse response{ static_cast<std::int32_t>(status) };
   return pipe.WriteExact(&header, sizeof(header)) && pipe.WriteExact(&response, sizeof(response));
}
