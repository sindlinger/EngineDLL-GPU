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
  double  dominant_plv;
  double  dominant_confidence;
  double  line_phase_deg;
  double  line_amplitude;
  double  line_period;
  double  line_eta;
  double  line_confidence;
  double  line_value;
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
                         double mask_min_period,
                         double mask_max_period,
                         int upscale_factor,
                         const double &cycle_periods[],
                         int cycle_count,
                         double cycle_width,
                         int    kalman_preset,
                         double kalman_process_noise,
                         double kalman_measurement_noise,
                         double kalman_init_variance,
                         double kalman_plv_threshold,
                         int    kalman_max_iterations,
                         double kalman_epsilon,
                         ulong &out_handle);
int  GpuEngine_PollStatus(ulong handle,
                          int &out_status);
int  GpuEngine_FetchResult(ulong handle,
                           double &wave_out[],
                           double &preview_out[],
                           double &cycles_out[],
                           double &noise_out[],
                           double &phase_out[],
                           double &phase_unwrapped_out[],
                           double &amplitude_out[],
                           double &period_out[],
                           double &frequency_out[],
                           double &eta_out[],
                           double &countdown_out[],
                           double &recon_out[],
                           double &kalman_out[],
                           double &confidence_out[],
                           double &amp_delta_out[],
                           double &turn_signal_out[],
                           double &phase_all_out[],
                           double &phase_unwrapped_all_out[],
                           double &amplitude_all_out[],
                           double &period_all_out[],
                           double &frequency_all_out[],
                           double &eta_all_out[],
                           double &countdown_all_out[],
                           double &direction_all_out[],
                           double &recon_all_out[],
                           double &kalman_all_out[],
                           double &turn_all_out[],
                           double &confidence_all_out[],
                           double &amp_delta_all_out[],
                           double &power_all_out[],
                           double &velocity_all_out[],
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
                                  8.0,
                                  512.0,
                                  1,
                                  1,
                                  1.0e-4,
                                  2.5e-3,
                                  0.5,
                                  0.65,
                                  48,
                                  1.0e-4,
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
                        const double mask_min_period,
                        const double mask_max_period,
                        const int upscale_factor,
                        const int kalman_preset,
                        const double kalman_process_noise,
                        const double kalman_measurement_noise,
                        const double kalman_init_variance,
                        const double kalman_plv_threshold,
                        const int    kalman_max_iterations,
                        const double kalman_epsilon,
                        ulong &out_handle)
            {
               if(!m_ready)
                  return false;

               double safe_mask_min = MathMax(1.0, mask_min_period);
               double safe_mask_max = MathMax(safe_mask_min, mask_max_period);
               int    safe_upscale  = MathMax(upscale_factor, 1);
               int    safe_preset   = (int)MathMax(0, MathMin(3, kalman_preset));
               double safe_process  = MathMax(1.0e-8, kalman_process_noise);
               double safe_measure  = MathMax(1.0e-8, kalman_measurement_noise);
               double safe_init_var = MathMax(1.0e-6, kalman_init_variance);
               double safe_plv      = MathMax(0.0, MathMin(1.0, kalman_plv_threshold));
               int    safe_iters    = MathMax(1, kalman_max_iterations);
               double safe_eps      = MathMax(1.0e-6, kalman_epsilon);

               int status = GpuEngine_SubmitJob(frames,
                                                frame_count,
                                                m_window_size,
                                                user_tag,
                                                flags,
                                                preview_mask,
                                                mask_sigma_period,
                                                mask_threshold,
                                                mask_softness,
                                                safe_mask_min,
                                                safe_mask_max,
                                                safe_upscale,
                                                cycle_periods,
                                                cycle_count,
                                                cycle_width,
                                                safe_preset,
                                                safe_process,
                                                safe_measure,
                                                safe_init_var,
                                                safe_plv,
                                                safe_iters,
                                                safe_eps,
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
                       double &phase_unwrapped_out[],
                       double &amplitude_out[],
                       double &period_out[],
                       double &frequency_out[],
                       double &eta_out[],
                       double &countdown_out[],
                       double &recon_out[],
                       double &kalman_out[],
                       double &confidence_out[],
                       double &amp_delta_out[],
                       double &turn_signal_out[],
                       double &direction_out[],
                       double &power_out[],
                       double &velocity_out[],
                       double &phase_all_out[],
                       double &phase_unwrapped_all_out[],
                       double &amplitude_all_out[],
                       double &period_all_out[],
                       double &frequency_all_out[],
                       double &eta_all_out[],
                       double &countdown_all_out[],
                       double &direction_all_out[],
                       double &recon_all_out[],
                       double &kalman_all_out[],
                       double &turn_all_out[],
                       double &confidence_all_out[],
                       double &amp_delta_all_out[],
                       double &power_all_out[],
                       double &velocity_all_out[],
                       double &plv_cycles_out[],
                       double &snr_cycles_out[],
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
