//+------------------------------------------------------------------+
//| WaveSpecGPU Hub                                                  |
//| EA responsável por orquestrar o pipeline GPU assíncrono.         |
//| Nesta fase inicial apenas define a estrutura do hub e a          |
//| integração com o wrapper GpuEngine (DLL ainda em desenvolvimento)|
//+------------------------------------------------------------------+
#property copyright "2025"
#property version   "1.000"
#property strict

#include <WaveSpecGPU/GpuEngine.mqh>
#include <WaveSpecGPU/WaveSpecShared.mqh>
#include <WaveSpecGPU/HotkeyManager.mqh>
#include <WaveSpecGPU/SubwindowController.mqh>

enum ZigzagFeedMode
  {
   Feed_PivotHold = 0,
   Feed_PivotBridge = 1,
   Feed_PivotMidpoint = 2
  };

//--- configuração básica do hub
input int    InpGPUDevice     = 0;
input int    InpFFTWindow     = 4096;
input int    InpHop           = 1024;
input int    InpBatchSize     = 128;
input int    InpUpscaleFactor = 1;
input bool   InpProfiling     = false;
input int    InpTimerPeriodMs = 250;
input bool   InpShowHud       = true;

input ZigzagFeedMode InpFeedMode        = Feed_PivotHold;
input int            InpZigZagDepth     = 12;
input int            InpZigZagDeviation = 5;
input int            InpZigZagBackstep  = 3;

input double InpGaussSigmaPeriod = 48.0;
input double InpMaskThreshold    = 0.05;
input double InpMaskSoftness     = 0.20;

input double InpCycleWidth    = 0.25;
input double InpCyclePeriod1  = 18.0;
input double InpCyclePeriod2  = 24.0;
input double InpCyclePeriod3  = 30.0;
input double InpCyclePeriod4  = 36.0;
input double InpCyclePeriod5  = 45.0;
input double InpCyclePeriod6  = 60.0;
input double InpCyclePeriod7  = 75.0;
input double InpCyclePeriod8  = 90.0;
input double InpCyclePeriod9  = 120.0;
input double InpCyclePeriod10 = 150.0;
input double InpCyclePeriod11 = 180.0;
input double InpCyclePeriod12 = 240.0;

// parâmetros do PLL/Phase tracker
input double InpPhaseBlend           = 0.65;
input double InpPhaseGain            = 0.08;
input double InpPhaseFreqGain        = 0.002;
input double InpPhaseAmpGain         = 0.08;
input double InpPhaseFreqPriorBlend  = 0.15;
input double InpPhaseMinPeriod       = 8.0;
input double InpPhaseMaxPeriod       = 512.0;
input double InpPhaseSnrFloor        = 0.25;
input int    InpPhaseFramesForSnr    = 1;

input bool   InpEnableHotkeys        = true;
input int    InpHotkeyWaveToggle     = 116; // F5
input int    InpHotkeyPhaseToggle    = 117; // F6
input int    InpWaveSubwindow        = 1;
input int    InpPhaseSubwindow       = 2;
input bool   InpWaveShowNoise        = true;
input bool   InpWaveShowCycles       = true;
input int    InpWaveMaxCycles        = 12;

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
   int      frame_count;
   int      frame_length;
   int      cycle_count;
  };

CGpuEngineClient g_engine;
PendingJob        g_jobs[];
double            g_batch_buffer[];
double            g_wave_shared[];
double            g_preview_shared[];
double            g_cycles_shared[];
double            g_noise_shared[];
double            g_phase_shared[];
double            g_amplitude_shared[];
double            g_period_shared[];
double            g_eta_shared[];
double            g_recon_shared[];
double            g_confidence_shared[];
double            g_amp_delta_shared[];
datetime          g_lastUpdateTime = 0;

int               g_zigzagHandle   = INVALID_HANDLE;
double            g_zigzagRaw[];
double            g_zigzagSeries[];
double            g_seriesChron[];
int               g_pivotIndex[];
double            g_pivotValue[];
double            g_cyclePeriods[];

double            g_lastAvgMs = 0.0;
double            g_lastMaxMs = 0.0;

int               g_handleWaveViz  = INVALID_HANDLE;
int               g_handlePhaseViz = INVALID_HANDLE;
bool              g_waveVisible    = false;
bool              g_phaseVisible   = false;

CHotkeyManager    g_hotkeys;

enum HubActions
  {
   HubAction_None = -1,
   HubAction_ToggleWave = 1,
   HubAction_TogglePhase = 2
  };

const string WAVE_IND_SHORTNAME  = "WaveSpecZZ GPU";
const string PHASE_IND_SHORTNAME = "PhaseViz GPU";

void ToggleWaveView();
void TogglePhaseView();

//+------------------------------------------------------------------+
int CollectCyclePeriods(double &dest[])
  {
   static double periods[12];
   periods[0]  = InpCyclePeriod1;
   periods[1]  = InpCyclePeriod2;
   periods[2]  = InpCyclePeriod3;
   periods[3]  = InpCyclePeriod4;
   periods[4]  = InpCyclePeriod5;
   periods[5]  = InpCyclePeriod6;
   periods[6]  = InpCyclePeriod7;
   periods[7]  = InpCyclePeriod8;
   periods[8]  = InpCyclePeriod9;
   periods[9]  = InpCyclePeriod10;
   periods[10] = InpCyclePeriod11;
   periods[11] = InpCyclePeriod12;

   ArrayResize(dest, 0);
   for(int i=0; i<12; ++i)
     {
      if(periods[i] <= 0.0)
         continue;
      int idx = ArraySize(dest);
      ArrayResize(dest, idx+1);
      dest[idx] = periods[i];
     }
   return ArraySize(dest);
  }

//+------------------------------------------------------------------+
bool BuildZigZagSeries(const int samples_needed)
  {
   if(g_zigzagHandle == INVALID_HANDLE || samples_needed <= 0)
      return false;

   ArraySetAsSeries(g_zigzagRaw, true);
   ArrayResize(g_zigzagRaw, samples_needed);
   int copied = CopyBuffer(g_zigzagHandle, 0, 0, samples_needed, g_zigzagRaw);
   if(copied != samples_needed)
     {
      PrintFormat("[Hub] ZigZag CopyBuffer insuficiente (%d/%d)", copied, samples_needed);
      return false;
     }

   ArraySetAsSeries(g_zigzagSeries, true);
   ArrayResize(g_zigzagSeries, samples_needed);
   ArrayInitialize(g_zigzagSeries, 0.0);

   ArrayResize(g_pivotIndex, 0);
   ArrayResize(g_pivotValue, 0);

   for(int i=samples_needed-1; i>=0; --i)
     {
      double price = g_zigzagRaw[i];
      if(price == EMPTY_VALUE || price == 0.0)
         continue;
      int pos = ArraySize(g_pivotIndex);
      ArrayResize(g_pivotIndex, pos+1);
      ArrayResize(g_pivotValue, pos+1);
      g_pivotIndex[pos] = i;
      g_pivotValue[pos] = price;
      g_zigzagSeries[i] = price;
     }

   int pivot_count = ArraySize(g_pivotIndex);
   if(pivot_count < 2)
      return false;

   for(int k=0; k<pivot_count-1; ++k)
     {
      int start_idx = g_pivotIndex[k];
      int end_idx   = g_pivotIndex[k+1];
      double start_val = g_pivotValue[k];
      double end_val   = g_pivotValue[k+1];
      int span = start_idx - end_idx;
      if(span < 0)
         continue;

      for(int offset=0; offset<=span; ++offset)
        {
         int idx = start_idx - offset;
         double value = start_val;
         switch(InpFeedMode)
           {
            case Feed_PivotBridge:
              {
               double t = (span == 0) ? 0.0 : double(offset) / double(span);
               value = start_val + (end_val - start_val) * t;
              }
              break;
            case Feed_PivotMidpoint:
              value = 0.5 * (start_val + end_val);
              break;
            default:
              value = start_val;
              break;
           }
         g_zigzagSeries[idx] = value;
        }
     }

   int first_idx = g_pivotIndex[0];
   for(int idx=samples_needed-1; idx>first_idx; --idx)
      g_zigzagSeries[idx] = g_pivotValue[0];

   int last_idx = g_pivotIndex[pivot_count-1];
   for(int idx=last_idx-1; idx>=0; --idx)
      g_zigzagSeries[idx] = g_pivotValue[pivot_count-1];

   return true;
  }

//+------------------------------------------------------------------+
bool PrepareBatchFrames(const int frame_len,
                        const int frame_count)
  {
   const int window_span = frame_len + (frame_count-1) * InpHop;
   if(window_span <= 0)
      return false;
   if(ArraySize(g_zigzagSeries) < window_span)
      return false;

   ArraySetAsSeries(g_seriesChron, false);
   ArrayResize(g_seriesChron, window_span);
   for(int t=0; t<window_span; ++t)
      g_seriesChron[t] = g_zigzagSeries[window_span-1 - t];

   ArrayResize(g_batch_buffer, frame_len * frame_count);
   int dst = 0;
   for(int frame=0; frame<frame_count; ++frame)
     {
      const int start = frame * InpHop;
      for(int n=0; n<frame_len; ++n)
         g_batch_buffer[dst++] = g_seriesChron[start + n];
     }
   return true;
  }

//+------------------------------------------------------------------+
void UpdateHud()
  {
   if(!InpShowHud)
     {
      Comment("");
      return;
     }

   string line1 = StringFormat("Jobs pendentes: %d | Último update: %s",
                               ArraySize(g_jobs), TimeToString(g_lastUpdateTime, TIME_SECONDS));
   string line2 = StringFormat("GPU avg %.2f ms | max %.2f ms", g_lastAvgMs, g_lastMaxMs);
   GpuEngineResultInfo info = WaveSpecShared::last_info;
   string line3 = StringFormat("Dominante idx=%d | período=%.2f | SNR=%.3f | Conf=%.2f",
                               info.dominant_cycle, info.dominant_period, info.dominant_snr, info.pll_confidence);
   Comment(line1, "\n", line2, "\n", line3);
  }

//+------------------------------------------------------------------+
void ToggleWaveView()
  {
   const long chart_id = ChartID();
   if(!g_waveVisible)
     {
      const int max_cycles = (int)MathMax(1, MathMin(12, InpWaveMaxCycles));
      g_handleWaveViz = iCustom(_Symbol, _Period, "WaveSpecZZ_GaussGPU",
                                InpWaveShowNoise, InpWaveShowCycles, max_cycles);
      if(g_handleWaveViz == INVALID_HANDLE)
        {
         Print("[Hub] Falha ao criar WaveSpecZZ_GaussGPU via iCustom");
         return;
        }
      if(!CSubwindowController::Attach(chart_id, InpWaveSubwindow, g_handleWaveViz))
        {
         IndicatorRelease(g_handleWaveViz);
         g_handleWaveViz = INVALID_HANDLE;
         Print("[Hub] ChartIndicatorAdd falhou para WaveSpecZZ_GaussGPU");
         return;
        }
      g_waveVisible = true;
      PrintFormat("[Hub] WaveSpec view ON (sub janela %d)", InpWaveSubwindow);
     }
   else
     {
      CSubwindowController::Detach(chart_id, InpWaveSubwindow, g_handleWaveViz, WAVE_IND_SHORTNAME);
      g_waveVisible = false;
      Print("[Hub] WaveSpec view OFF");
     }
  }

//+------------------------------------------------------------------+
void TogglePhaseView()
  {
   const long chart_id = ChartID();
   if(!g_phaseVisible)
     {
      g_handlePhaseViz = iCustom(_Symbol, _Period, "PhaseViz_GPU");
      if(g_handlePhaseViz == INVALID_HANDLE)
        {
         Print("[Hub] Falha ao criar PhaseViz_GPU via iCustom");
         return;
        }
      if(!CSubwindowController::Attach(chart_id, InpPhaseSubwindow, g_handlePhaseViz))
        {
         IndicatorRelease(g_handlePhaseViz);
         g_handlePhaseViz = INVALID_HANDLE;
         Print("[Hub] ChartIndicatorAdd falhou para PhaseViz_GPU");
         return;
        }
      g_phaseVisible = true;
      PrintFormat("[Hub] PhaseViz view ON (sub janela %d)", InpPhaseSubwindow);
     }
   else
     {
      CSubwindowController::Detach(chart_id, InpPhaseSubwindow, g_handlePhaseViz, PHASE_IND_SHORTNAME);
      g_phaseVisible = false;
      Print("[Hub] PhaseViz view OFF");
     }
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   if(!g_engine.Initialize(InpGPUDevice, InpFFTWindow, InpHop, InpBatchSize, InpProfiling))
     {
      Print("[Hub] Falha ao inicializar GpuEngine. EA será desativado.");
      return INIT_FAILED;
     }

   g_zigzagHandle = iCustom(_Symbol, _Period, "ZigZag", InpZigZagDepth, InpZigZagDeviation, InpZigZagBackstep);
   if(g_zigzagHandle == INVALID_HANDLE)
     {
      Print("[Hub] Não foi possível criar instância do ZigZag.");
      g_engine.Shutdown();
      return INIT_FAILED;
     }

   EventSetTimer(InpTimerPeriodMs/1000.0);
   ArrayResize(g_wave_shared,    0);
   ArrayResize(g_preview_shared, 0);
   ArrayResize(g_cycles_shared,  0);
   ArrayResize(g_noise_shared,   0);
   ArrayResize(g_phase_shared,       0);
   ArrayResize(g_amplitude_shared,   0);
   ArrayResize(g_period_shared,      0);
   ArrayResize(g_eta_shared,         0);
   ArrayResize(g_recon_shared,       0);
   ArrayResize(g_confidence_shared,  0);
   ArrayResize(g_amp_delta_shared,   0);

   ArraySetAsSeries(g_zigzagRaw,    true);
   ArraySetAsSeries(g_zigzagSeries, true);
   ArraySetAsSeries(g_seriesChron,  false);

   CollectCyclePeriods(g_cyclePeriods);

   g_hotkeys.Reset();
   if(InpEnableHotkeys)
     {
      if(InpHotkeyWaveToggle > 0)
         g_hotkeys.Register(InpHotkeyWaveToggle, HubAction_ToggleWave);
      if(InpHotkeyPhaseToggle > 0)
         g_hotkeys.Register(InpHotkeyPhaseToggle, HubAction_TogglePhase);
     }

   PrintFormat("[Hub] Inicializado | GPU=%d | window=%d | hop=%d | batch=%d",
               InpGPUDevice, InpFFTWindow, InpHop, InpBatchSize);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   g_engine.Shutdown();
   if(g_zigzagHandle != INVALID_HANDLE)
     {
      IndicatorRelease(g_zigzagHandle);
      g_zigzagHandle = INVALID_HANDLE;
     }
   ArrayFree(g_jobs);
   ArrayFree(g_batch_buffer);
   ArrayFree(g_wave_shared);
   ArrayFree(g_preview_shared);
   ArrayFree(g_cycles_shared);
   ArrayFree(g_noise_shared);
   ArrayFree(g_zigzagRaw);
   ArrayFree(g_zigzagSeries);
   ArrayFree(g_seriesChron);
   ArrayFree(g_pivotIndex);
   ArrayFree(g_pivotValue);
   ArrayFree(g_cyclePeriods);
   ArrayFree(g_phase_shared);
   ArrayFree(g_amplitude_shared);
   ArrayFree(g_period_shared);
   ArrayFree(g_eta_shared);
   ArrayFree(g_recon_shared);
   ArrayFree(g_confidence_shared);
   ArrayFree(g_amp_delta_shared);
   if(g_waveVisible)
      CSubwindowController::Detach(0, InpWaveSubwindow, g_handleWaveViz, "WaveSpecZZ GPU");
   if(g_phaseVisible)
      CSubwindowController::Detach(0, InpPhaseSubwindow, g_handlePhaseViz, "PhaseViz GPU");
   g_waveVisible  = false;
   g_phaseVisible = false;
   Comment("");
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
void OnChartEvent(const int id,
                  const long &lparam,
                  const double &dparam,
                  const string &sparam)
  {
   const int action = g_hotkeys.HandleChartEvent(id, lparam);
   switch(action)
     {
      case HubAction_ToggleWave:
         ToggleWaveView();
         break;
      case HubAction_TogglePhase:
         TogglePhaseView();
         break;
      default:
         break;
     }
  }

//+------------------------------------------------------------------+
void SubmitPendingBatches()
  {
   if(ArraySize(g_jobs) > 0)
      return;

   const int frame_len  = InpFFTWindow;
   const int frame_count= InpBatchSize;
   if(frame_len <= 0 || frame_count <= 0)
      return;

   const int window_span = frame_len + (frame_count-1) * InpHop;
   const int fetch_bars  = window_span + InpHop;

   if(!BuildZigZagSeries(fetch_bars))
      return;
   if(!PrepareBatchFrames(frame_len, frame_count))
      return;

   int cycle_count = CollectCyclePeriods(g_cyclePeriods);
   if(cycle_count == 0)
      ArrayResize(g_cyclePeriods, 0); // garante array vazio

   ulong handle = 0;
   ulong tag = (ulong)TimeCurrent();
   bool submitted = false;

   const double phase_min = MathMax(1.0, InpPhaseMinPeriod);
   const double phase_max = MathMax(phase_min, InpPhaseMaxPeriod);
   const double phase_snr_floor = MathMax(0.0, InpPhaseSnrFloor);
   const int    phase_frames_snr = (int)MathMax(1, InpPhaseFramesForSnr);

   if(cycle_count > 0)
     {
      submitted = g_engine.SubmitJobEx(g_batch_buffer,
                                       frame_count,
                                       tag,
                                       JOB_FLAG_STFT|JOB_FLAG_CYCLES,
                                       g_gpuEmptyPreviewMask,
                                       g_cyclePeriods,
                                       cycle_count,
                                       InpCycleWidth,
                                       InpGaussSigmaPeriod,
                                       InpMaskThreshold,
                                       InpMaskSoftness,
                                       InpUpscaleFactor,
                                       InpPhaseBlend,
                                       InpPhaseGain,
                                       InpPhaseFreqGain,
                                       InpPhaseAmpGain,
                                       InpPhaseFreqPriorBlend,
                                       phase_min,
                                       phase_max,
                                       phase_snr_floor,
                                       phase_frames_snr,
                                       handle);
     }
   else
     {
      submitted = g_engine.SubmitJobEx(g_batch_buffer,
                                       frame_count,
                                       tag,
                                       JOB_FLAG_STFT,
                                       g_gpuEmptyPreviewMask,
                                       g_gpuEmptyCyclePeriods,
                                       0,
                                       InpCycleWidth,
                                       InpGaussSigmaPeriod,
                                       InpMaskThreshold,
                                       InpMaskSoftness,
                                       InpUpscaleFactor,
                                       InpPhaseBlend,
                                       InpPhaseGain,
                                       InpPhaseFreqGain,
                                       InpPhaseAmpGain,
                                       InpPhaseFreqPriorBlend,
                                       phase_min,
                                       phase_max,
                                       phase_snr_floor,
                                       phase_frames_snr,
                                       handle);
     }

   if(!submitted)
      return;

   PendingJob job;
   job.handle       = handle;
   job.user_tag     = tag;
   job.submitted_at = TimeCurrent();
   job.frame_count  = frame_count;
   job.frame_length = frame_len;
   job.cycle_count  = cycle_count;
   ArrayPush(g_jobs, job);
   UpdateHud();
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
         const int total = g_jobs[i].frame_count * g_jobs[i].frame_length;
         const int expected_cycles = MathMax(g_jobs[i].cycle_count, 0);
         const int cycles_total = total * expected_cycles;

         ArrayResize(g_wave_shared,    total);
         ArrayResize(g_preview_shared, total);
         ArrayResize(g_noise_shared,   total);
         ArrayResize(g_cycles_shared,  cycles_total);
         ArrayResize(g_phase_shared,       total);
         ArrayResize(g_amplitude_shared,   total);
         ArrayResize(g_period_shared,      total);
         ArrayResize(g_eta_shared,         total);
         ArrayResize(g_recon_shared,       total);
         ArrayResize(g_confidence_shared,  total);
         ArrayResize(g_amp_delta_shared,   total);

         bool fetched = false;
        if(expected_cycles > 0)
            fetched = g_engine.FetchResult(g_jobs[i].handle,
                                           g_wave_shared,
                                           g_preview_shared,
                                           g_cycles_shared,
                                           g_noise_shared,
                                           g_phase_shared,
                                           g_amplitude_shared,
                                           g_period_shared,
                                           g_eta_shared,
                                           g_recon_shared,
                                           g_confidence_shared,
                                           g_amp_delta_shared,
                                           info);
        else
            fetched = g_engine.FetchResult(g_jobs[i].handle,
                                           g_wave_shared,
                                           g_preview_shared,
                                           g_cycles_shared,
                                           g_noise_shared,
                                           g_phase_shared,
                                           g_amplitude_shared,
                                           g_period_shared,
                                           g_eta_shared,
                                           g_recon_shared,
                                           g_confidence_shared,
                                           g_amp_delta_shared,
                                           info);

         if(fetched)
           {
            g_lastUpdateTime = TimeCurrent();
            g_engine.GetStats(g_lastAvgMs, g_lastMaxMs);
            if(info.cycle_count > 0)
              {
               const int cycles_total_actual = total * info.cycle_count;
               if(cycles_total_actual < ArraySize(g_cycles_shared))
                  ArrayResize(g_cycles_shared, cycles_total_actual);
               if(ArraySize(g_cyclePeriods) != info.cycle_count)
                  ArrayResize(g_cyclePeriods, info.cycle_count);
              }
            else
              {
               ArrayResize(g_cycles_shared, 0);
               ArrayResize(g_cyclePeriods, 0);
              }
            DispatchSignals(info,
                             g_wave_shared,
                             g_preview_shared,
                             g_noise_shared,
                             g_cycles_shared);
           }

         ArrayRemove(g_jobs, i);
        }
     }

   UpdateHud();
  }

//+------------------------------------------------------------------+
void DispatchSignals(const GpuEngineResultInfo &info,
                     const double &wave[],
                     const double &preview[],
                     const double &noise[],
                     const double &cycles[])
  {
   WaveSpecShared::Publish(wave,
                           preview,
                           noise,
                           cycles,
                           g_cyclePeriods,
                           g_phase_shared,
                           g_amplitude_shared,
                           g_period_shared,
                           g_eta_shared,
                           g_recon_shared,
                           g_confidence_shared,
                           g_amp_delta_shared,
                           info);
   // TODO: disparar eventos ou sinalizar variáveis globais, se necessário.
   PrintFormat("[Hub] Job %I64u concluído | frames=%d | elapsed=%.2f ms",
               info.user_tag, info.frame_count, info.elapsed_ms);
   if(info.cycle_count > 0)
      PrintFormat("[Hub] Ciclos retornados: %d", info.cycle_count);
   if(info.dominant_cycle >= 0)
      PrintFormat("[Hub] Dominante idx=%d | período=%.2f | SNR=%.3f | confiança=%.2f",
                  info.dominant_cycle, info.dominant_period, info.dominant_snr, info.pll_confidence);
  }

//+------------------------------------------------------------------+
