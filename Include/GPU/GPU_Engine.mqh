//+------------------------------------------------------------------+
//| GPU_Engine.mqh - GPU Engine Client Wrapper                      |
//| Interface assíncrona utilizada pelo hub para falar com a DLL.   |
//+------------------------------------------------------------------+
#ifndef __WAVESPEC_GPU_ENGINE_MQH__
#define __WAVESPEC_GPU_ENGINE_MQH__

double g_gpuEmptyPreviewMask[] = { EMPTY_VALUE };
double g_gpuEmptyCyclePeriods[] = { EMPTY_VALUE };

struct GpuEngineResultInfo
  {
  ulong   user_tag;
  int     frame_count;
  int     frame_length;
  int     cycle_count;
  int     dominant_cycle;
  double  dominant_period;
  double  dominant_snr;
  double  pll_phase_deg;
  double  pll_amplitude;
  double  pll_period;
  double  pll_eta;
  double  pll_confidence;
  double  pll_reconstructed;
  double  elapsed_ms;
  int     status;        // mirror of the last status code
  };

enum GpuEngineStatus
  {
   GPU_ENGINE_OK          =  0,
   GPU_ENGINE_READY       =  1,
   GPU_ENGINE_IN_PROGRESS =  2,
   GPU_ENGINE_TIMEOUT     =  3,
   GPU_ENGINE_ERROR      = -1
  };

#import "GpuEngine.dll"
int  GpuEngine_Init(int device_id,
                    int window_size,
                    int hop_size,
                    int max_batch_size,
                    bool enable_profiling);
void GpuEngine_Shutdown();
int  GpuEngine_SubmitJob(const double &frames[],
                         int frame_count,
                         int frame_length,
                         ulong user_tag,
                         uint flags,
                         const double &preview_mask[],
                         double mask_sigma_period,
                         double mask_threshold,
                         double mask_softness,
                         int upscale_factor,
                         const double &cycle_periods[],
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
                         ulong &out_handle);
int  GpuEngine_PollStatus(ulong handle,
                          int &out_status);
int  GpuEngine_FetchResult(ulong handle,
                           double &wave_out[],
                           double &preview_out[],
                           double &cycles_out[],
                           double &noise_out[],
                           double &phase_out[],
                           double &amplitude_out[],
                           double &period_out[],
                           double &eta_out[],
                           double &recon_out[],
                           double &confidence_out[],
                           double &amp_delta_out[],
                           GpuEngineResultInfo &info);
int  GpuEngine_GetStats(double &avg_ms,
                        double &max_ms);
int  GpuEngine_GetLastError(string &out_message);
#import

class CGpuEngineClient
  {
private:
   bool   m_ready;
   int    m_window_size;
   int    m_hop_size;
   int    m_batch_size;
   int    m_device_id;
   bool   m_profiling;

public:
            CGpuEngineClient()
            {
               m_ready       = false;
               m_window_size = 0;
               m_hop_size    = 0;
               m_batch_size  = 0;
               m_device_id   = 0;
               m_profiling   = false;
            }

   bool     Initialize(const int device_id,
                       const int window_size,
                       const int hop_size,
                       const int batch_size,
                       const bool enable_profiling)
            {
               m_device_id   = device_id;
               m_window_size = window_size;
               m_hop_size    = hop_size;
               m_batch_size  = batch_size;
               m_profiling   = enable_profiling;

               int status = GpuEngine_Init(m_device_id,
                                           m_window_size,
                                           m_hop_size,
                                           m_batch_size,
                                           m_profiling);
               if(status != GPU_ENGINE_OK)
                 {
                  LogError("GpuEngine_Init", status);
                  m_ready = false;
                  return false;
                 }

               m_ready = true;
               return true;
            }

   void     Shutdown()
            {
               if(m_ready)
                 {
                  GpuEngine_Shutdown();
                  m_ready = false;
                 }
            }

   bool     SubmitJob(const double &frames[],
                      const int frame_count,
                      const ulong user_tag,
                      const uint flags,
                      ulong &out_handle)
            {
               return SubmitJobEx(frames,
                                  frame_count,
                                  user_tag,
                                  flags,
                                  g_gpuEmptyPreviewMask,
                                  g_gpuEmptyCyclePeriods,
                                  0,
                                  0.25,
                                  48.0,
                                  0.05,
                                  0.20,
                                  1,
                                  0.65,
                                  0.08,
                                  0.002,
                                  0.08,
                                  0.15,
                                  8.0,
                                  512.0,
                                  0.25,
                                  1,
                                  out_handle);
            }

   bool     SubmitJobEx(const double &frames[],
                        const int frame_count,
                        const ulong user_tag,
                        const uint flags,
                        const double &preview_mask[],
                        const double &cycle_periods[],
                        const int cycle_count,
                        const double cycle_width,
                        const double mask_sigma_period,
                        const double mask_threshold,
                        const double mask_softness,
                        const int upscale_factor,
                        const double phase_blend,
                        const double phase_gain,
                        const double freq_gain,
                        const double amp_gain,
                        const double freq_prior_blend,
                        const double min_period,
                        const double max_period,
                        const double snr_floor,
                        const int    frames_for_snr,
                        ulong &out_handle)
            {
               if(!m_ready)
                  return false;

               int status = GpuEngine_SubmitJob(frames,
                                                frame_count,
                                                m_window_size,
                                                user_tag,
                                                flags,
                                                preview_mask,
                                                mask_sigma_period,
                                                mask_threshold,
                                                mask_softness,
                                                upscale_factor,
                                                cycle_periods,
                                                cycle_count,
                                                cycle_width,
                                                phase_blend,
                                                phase_gain,
                                                freq_gain,
                                                amp_gain,
                                                freq_prior_blend,
                                                min_period,
                                                max_period,
                                                snr_floor,
                                                frames_for_snr,
                                                 out_handle);
               if(status != GPU_ENGINE_OK)
                 {
                  LogError("GpuEngine_SubmitJob", status);
                  return false;
                 }
               return true;
            }

   int      PollStatus(const ulong handle,
                       int &out_status)
            {
               out_status = GPU_ENGINE_ERROR;
               if(!m_ready)
                  return GPU_ENGINE_ERROR;
               return GpuEngine_PollStatus(handle, out_status);
            }

   bool     FetchResult(const ulong handle,
                        double &wave_out[],
                        double &preview_out[],
                        double &cycles_out[],
                        double &noise_out[],
                        double &phase_out[],
                        double &amplitude_out[],
                        double &period_out[],
                        double &eta_out[],
                        double &recon_out[],
                        double &confidence_out[],
                        double &amp_delta_out[],
                        GpuEngineResultInfo &info)
            {
               if(!m_ready)
                  return false;
               int status = GpuEngine_FetchResult(handle,
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
                                                   info);
               if(status != GPU_ENGINE_OK)
                 {
                  LogError("GpuEngine_FetchResult", status);
                  return false;
                 }
               return true;
            }

   bool     GetStats(double &avg_ms,
                     double &max_ms)
            {
               if(!m_ready)
                  return false;
               int status = GpuEngine_GetStats(avg_ms, max_ms);
               return (status == GPU_ENGINE_OK);
            }

private:
   void     LogError(const string context,
                     const int status)
            {
               string msg;
               if(GpuEngine_GetLastError(msg) == GPU_ENGINE_OK)
                  PrintFormat("[GpuEngine] %s falhou (status=%d): %s",
                               context, status, msg);
               else
                  PrintFormat("[GpuEngine] %s falhou (status=%d)", context, status);
            }
  };

#endif // __WAVESPEC_GPU_ENGINE_MQH__
