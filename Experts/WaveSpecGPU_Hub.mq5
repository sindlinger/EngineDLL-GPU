//+------------------------------------------------------------------+
//| WaveSpecGPU Hub                                                  |
//| EA responsável por orquestrar o pipeline GPU assíncrono.         |
//| Nesta fase inicial apenas define a estrutura do hub e a          |
//| integração com o wrapper GpuEngine (DLL ainda em desenvolvimento)|
//+------------------------------------------------------------------+
#property copyright "2025"
#property version   "0.01"
#property strict

#include <WaveSpecGPU/GpuEngine.mqh>

//--- configuração básica do hub
input int    InpGPUDevice     = 0;
input int    InpFFTWindow     = 4096;
input int    InpHop           = 1024;
input int    InpBatchSize     = 128;
input bool   InpProfiling     = false;
input int    InpTimerPeriodMs = 250;

//--- flags para jobs (placeholder)
enum JobFlags
  {
   JOB_FLAG_STFT   = 1,
   JOB_FLAG_CYCLES = 2
  };

struct PendingJob
  {
   ulong    handle;
   ulong    user_tag;
   datetime submitted_at;
  };

CGpuEngineClient g_engine;
PendingJob        g_jobs[];
double            g_batch_buffer[];
double            g_wave_shared[];
double            g_preview_shared[];
double            g_cycles_shared[];
double            g_noise_shared[];
datetime          g_lastUpdateTime = 0;

//+------------------------------------------------------------------+
int OnInit()
  {
   if(!g_engine.Initialize(InpGPUDevice, InpFFTWindow, InpHop, InpBatchSize, InpProfiling))
     {
      Print("[Hub] Falha ao inicializar GpuEngine. EA será desativado.");
      return INIT_FAILED;
     }

   EventSetTimer(InpTimerPeriodMs/1000.0);
   ArrayResize(g_wave_shared,    InpFFTWindow);
   ArrayResize(g_preview_shared, InpFFTWindow);
   ArrayResize(g_cycles_shared,  InpFFTWindow*12);
   ArrayResize(g_noise_shared,   InpFFTWindow);

   PrintFormat("[Hub] Inicializado | GPU=%d | window=%d | hop=%d | batch=%d",
               InpGPUDevice, InpFFTWindow, InpHop, InpBatchSize);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   g_engine.Shutdown();
   ArrayFree(g_jobs);
   ArrayFree(g_batch_buffer);
   ArrayFree(g_wave_shared);
   ArrayFree(g_preview_shared);
   ArrayFree(g_cycles_shared);
   ArrayFree(g_noise_shared);
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   SubmitPendingBatches();
   PollCompletedJobs();
  }

//+------------------------------------------------------------------+
void OnTimer()
  {
   SubmitPendingBatches();
   PollCompletedJobs();
  }

//+------------------------------------------------------------------+
void SubmitPendingBatches()
  {
   // TODO: montar batches reais a partir dos dados de mercado / ZigZag.
   // Nesta etapa inicial, apenas submete um lote fictício quando não há jobs pendentes.
   if(ArraySize(g_jobs) == 0)
      EnqueueJobSample();
  }

//+------------------------------------------------------------------+
void PollCompletedJobs()
  {
   for(int i=ArraySize(g_jobs)-1; i>=0; --i)
     {
      int status;
      if(g_engine.PollStatus(g_jobs[i].handle, status) != GPU_ENGINE_OK)
         continue;

      if(status == GPU_ENGINE_READY)
        {
         GpuEngineResultInfo info;
         if(g_engine.FetchResult(g_jobs[i].handle,
                                 g_wave_shared,
                                 g_preview_shared,
                                 g_cycles_shared,
                                 g_noise_shared,
                                 info))
           {
            g_lastUpdateTime = TimeCurrent();
            DispatchSignals(info);
           }

         ArrayRemove(g_jobs, i);
        }
     }
  }

//+------------------------------------------------------------------+
void DispatchSignals(const GpuEngineResultInfo &info)
  {
   // TODO: publicar os buffers em uma estrutura compartilhada e/ou
   // disparar eventos para indicadores / EAs auxiliares.
   PrintFormat("[Hub] Job %I64u concluído | frames=%d | elapsed=%.2f ms",
               info.user_tag, info.frame_count, info.elapsed_ms);
  }

//+------------------------------------------------------------------+
bool EnqueueJobSample()
  {
   // Exemplo mínimo de submissão dummy – real pipeline preencherá g_batch_buffer
   const int frames = InpBatchSize;
   ArrayResize(g_batch_buffer, frames * InpFFTWindow);
   for(int i=0; i<ArraySize(g_batch_buffer); ++i)
      g_batch_buffer[i] = 0.0;

   ulong handle;
   ulong tag = (ulong)TimeCurrent();
   if(!g_engine.SubmitJob(g_batch_buffer, frames, tag, JOB_FLAG_STFT|JOB_FLAG_CYCLES, handle))
      return false;

   PendingJob job;
   job.handle       = handle;
   job.user_tag     = tag;
   job.submitted_at = TimeCurrent();
   ArrayPush(g_jobs, job);
   return true;
  }
