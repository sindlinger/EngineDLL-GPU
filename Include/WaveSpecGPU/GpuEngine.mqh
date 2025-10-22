//+------------------------------------------------------------------+
//| WaveSpecGPU - GPU Engine Client Wrapper                         |
//| Defines the asynchronous interface used by the EA hub to        |
//| communicate with the CUDA backend (GpuEngine.dll).              |
//+------------------------------------------------------------------+
#ifndef __WAVESPEC_GPU_ENGINE_MQH__
#define __WAVESPEC_GPU_ENGINE_MQH__

struct GpuEngineResultInfo
  {
   ulong   user_tag;
   int     frame_count;
   int     frame_length;
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
                         ulong &out_handle);
int  GpuEngine_PollStatus(ulong handle,
                          int &out_status);
int  GpuEngine_FetchResult(ulong handle,
                           double &wave_out[],
                           double &preview_out[],
                           double &cycles_out[],
                           double &noise_out[],
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
               if(!m_ready)
                  return false;

               int status = GpuEngine_SubmitJob(frames,
                                                 frame_count,
                                                 m_window_size,
                                                 user_tag,
                                                 flags,
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
                        GpuEngineResultInfo &info)
            {
               if(!m_ready)
                  return false;
               int status = GpuEngine_FetchResult(handle,
                                                   wave_out,
                                                   preview_out,
                                                   cycles_out,
                                                   noise_out,
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
