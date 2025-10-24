//+------------------------------------------------------------------+
//| GPU Engine Hub                                                   |
//| EA responsável por orquestrar o pipeline GPU assíncrono.         |
//| Integração direta com a DLL GPU_Engine e os visualizadores.      |
//+------------------------------------------------------------------+
#property copyright "2025"
#property version   "1.000"
#property strict

#include <GPU/GPU_Engine.mqh>
#include <GPU/GPU_Shared.mqh>
#include <GPU/GPU_Hotkeys.mqh>

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
input bool   InpGpuVerboseLog = false;

input ZigzagFeedMode InpFeedMode        = Feed_PivotHold;
input int            InpZigZagDepth     = 12;
input int            InpZigZagDeviation = 5;
input int            InpZigZagBackstep  = 3;

input double InpGaussSigmaPeriod = 48.0;
input double InpMaskThreshold    = 0.05;
input double InpMaskSoftness     = 0.20;

input double InpMaskMinPeriod   = 18.0;
input double InpMaskMaxPeriod   = 512.0;
input int    InpMaxCandidates   = 12;
input bool   InpUseManualCycles = false;

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

enum KalmanPresetOption
  {
   KalmanSmooth   = 0,
   KalmanBalanced = 1,
   KalmanReactive = 2,
   KalmanManual   = 3
  };

input KalmanPresetOption InpKalmanPreset         = KalmanBalanced;
input double             InpKalmanProcessNoise   = 1.0e-4;
input double             InpKalmanMeasurementNoise = 2.5e-3;
input double             InpKalmanInitVariance   = 0.5;
input double             InpKalmanPlvThreshold   = 0.65;
input int                InpKalmanMaxIterations  = 48;
input double             InpKalmanConvergenceEps = 1.0e-4;

input bool   InpEnableHotkeys        = true;
input int    InpHotkeyWaveToggle     = 116; // F5
input int    InpHotkeyPhaseToggle    = 117; // F6
input int    InpWaveSubwindow        = 1;
input int    InpPhaseSubwindow       = 2;
input bool   InpWaveShowNoise        = true;
input bool   InpWaveShowCycles       = true;
input int    InpWaveMaxCycles        = 12;
input bool   InpAutoAttachWave       = true;
input bool   InpAutoAttachPhase      = true;

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
double            g_phase_unwrapped_shared[];
double            g_amplitude_shared[];
double            g_period_shared[];
double            g_frequency_shared[];
double            g_eta_shared[];
double            g_countdown_shared[];
double            g_recon_shared[];
double            g_kalman_shared[];
double            g_turn_shared[];
double            g_confidence_shared[];
double            g_amp_delta_shared[];
double            g_direction_shared[];
double            g_power_shared[];
double            g_velocity_shared[];
double            g_plv_cycles_shared[];
double            g_snr_cycles_shared[];
datetime          g_lastUpdateTime = 0;

int               g_zigzagHandle   = INVALID_HANDLE;
double            g_zigzagRaw[];
double            g_zigzagSeries[];
double            g_seriesChron[];
int               g_pivotIndex[];
double            g_pivotValue[];
double            g_cyclePeriods[];
double            g_phase_all_shared[];
double            g_phase_unwrapped_all_shared[];
double            g_amplitude_all_shared[];
double            g_period_all_shared[];
double            g_frequency_all_shared[];
double            g_eta_all_shared[];
double            g_countdown_all_shared[];
double            g_direction_all_shared[];
double            g_recon_all_shared[];
double            g_kalman_all_shared[];
double            g_turn_all_shared[];
double            g_confidence_all_shared[];
double            g_amp_delta_all_shared[];
double            g_power_all_shared[];
double            g_velocity_all_shared[];

double            g_lastAvgMs = 0.0;
double            g_lastMaxMs = 0.0;
int               g_lastFrameCount = 0;
int               g_lastFetchBars  = 0;

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

const string WAVE_IND_SHORTNAME  = "GPU WaveViz";
const string PHASE_IND_SHORTNAME = "GPU PhaseViz";

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

   int factor = 1;
   int handle = g_zigzagHandle;
   if(handle == INVALID_HANDLE)
      return false;

   const int fetch_samples = samples_needed * factor;

   ArraySetAsSeries(g_zigzagRaw, true);
   ArrayResize(g_zigzagRaw, fetch_samples);
   int copied = CopyBuffer(handle, 0, 0, fetch_samples, g_zigzagRaw);
   if(copied != fetch_samples)
     {
      if(factor > 1)
        {
         Print("[Hub] Upsampling ZigZag insuficiente, revertendo timeframe base.");
         factor = 1;
         handle = g_zigzagHandle;
         ArrayResize(g_zigzagRaw, samples_needed);
         copied = CopyBuffer(handle, 0, 0, samples_needed, g_zigzagRaw);
         if(copied != samples_needed)
           {
            PrintFormat("[Hub] ZigZag CopyBuffer insuficiente (%d/%d)", copied, samples_needed);
            return false;
           }
        }
      else
        {
         PrintFormat("[Hub] ZigZag CopyBuffer insuficiente (%d/%d)", copied, fetch_samples);
         return false;
        }
     }

   const int work_len = (factor == 1 ? samples_needed : fetch_samples);
   double work_series[];
   ArrayResize(work_series, work_len);
   ArrayInitialize(work_series, 0.0);

   ArrayResize(g_pivotIndex, 0);
   ArrayResize(g_pivotValue, 0);

   for(int i=work_len-1; i>=0; --i)
     {
      double price = g_zigzagRaw[i];
      if(price == EMPTY_VALUE || price == 0.0)
         continue;
      int pos = ArraySize(g_pivotIndex);
      ArrayResize(g_pivotIndex, pos+1);
      ArrayResize(g_pivotValue, pos+1);
      g_pivotIndex[pos] = i;
      g_pivotValue[pos] = price;
      work_series[i] = price;
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
         work_series[idx] = value;
        }
     }

   int first_idx = g_pivotIndex[0];
   for(int idx=work_len-1; idx>first_idx; --idx)
      work_series[idx] = g_pivotValue[0];

   int last_idx = g_pivotIndex[pivot_count-1];
   for(int idx=last_idx-1; idx>=0; --idx)
      work_series[idx] = g_pivotValue[pivot_count-1];

   ArraySetAsSeries(g_zigzagSeries, true);
   ArrayResize(g_zigzagSeries, samples_needed);
   if(factor == 1)
     {
      for(int i=0; i<samples_needed; ++i)
         g_zigzagSeries[i] = work_series[i];
     }
   else
     {
      for(int i=0; i<samples_needed; ++i)
        {
         int src_idx = i * factor;
         if(src_idx >= work_len)
            src_idx = work_len - 1;
         g_zigzagSeries[i] = work_series[src_idx];
        }
     }

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
   GpuEngineResultInfo info = GPUShared::last_info;
   string line3 = StringFormat("Frames %d/%d | hop=%d | amostras=%d",
                               g_lastFrameCount, InpBatchSize, InpHop, g_lastFetchBars);
   string line4 = StringFormat("Dominante idx=%d | período=%.2f | SNR=%.3f | Conf=%.2f",
                               info.dominant_cycle, info.dominant_period, info.dominant_snr, info.dominant_confidence);
   Comment(line1, "\n", line2, "\n", line3, "\n", line4);
  }

//+------------------------------------------------------------------+
void ToggleWaveView()
  {
   const long chart_id = ChartID();
   if(!g_waveVisible)
     {
      const int max_cycles = (int)MathMax(1, MathMin(12, InpWaveMaxCycles));
      g_handleWaveViz = iCustom(_Symbol, _Period, "GPU_WaveViz",
                                InpWaveShowNoise, InpWaveShowCycles, max_cycles);
      if(g_handleWaveViz == INVALID_HANDLE)
        {
         Print("[Hub] Falha ao criar GPU_WaveViz via iCustom");
         return;
        }
      if(!ChartIndicatorAdd(chart_id, InpWaveSubwindow, g_handleWaveViz))
        {
         IndicatorRelease(g_handleWaveViz);
         g_handleWaveViz = INVALID_HANDLE;
         Print("[Hub] ChartIndicatorAdd falhou para GPU_WaveViz");
         return;
        }
      g_waveVisible = true;
      PrintFormat("[Hub] GPU WaveViz ON (sub janela %d)", InpWaveSubwindow);
     }
   else
     {
      ChartIndicatorDelete(chart_id, InpWaveSubwindow, WAVE_IND_SHORTNAME);
      if(g_handleWaveViz != INVALID_HANDLE)
        {
         IndicatorRelease(g_handleWaveViz);
         g_handleWaveViz = INVALID_HANDLE;
        }
      g_waveVisible = false;
      Print("[Hub] GPU WaveViz OFF");
     }
  }

//+------------------------------------------------------------------+
void TogglePhaseView()
  {
   const long chart_id = ChartID();
   if(!g_phaseVisible)
     {
      g_handlePhaseViz = iCustom(_Symbol, _Period, "GPU_PhaseViz");
      if(g_handlePhaseViz == INVALID_HANDLE)
        {
         Print("[Hub] Falha ao criar GPU_PhaseViz via iCustom");
         return;
        }
      if(!ChartIndicatorAdd(chart_id, InpPhaseSubwindow, g_handlePhaseViz))
        {
         IndicatorRelease(g_handlePhaseViz);
         g_handlePhaseViz = INVALID_HANDLE;
         Print("[Hub] ChartIndicatorAdd falhou para GPU_PhaseViz");
         return;
        }
      g_phaseVisible = true;
      PrintFormat("[Hub] GPU PhaseViz ON (sub janela %d)", InpPhaseSubwindow);
     }
   else
     {
      ChartIndicatorDelete(chart_id, InpPhaseSubwindow, PHASE_IND_SHORTNAME);
      if(g_handlePhaseViz != INVALID_HANDLE)
        {
         IndicatorRelease(g_handlePhaseViz);
         g_handlePhaseViz = INVALID_HANDLE;
        }
      g_phaseVisible = false;
      Print("[Hub] GPU PhaseViz OFF");
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

   uint timer_period_ms = (uint)MathMax((double)InpTimerPeriodMs, 1.0);
   EventSetMillisecondTimer(timer_period_ms);
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

   if(InpAutoAttachWave)
      ToggleWaveView();
   if(InpAutoAttachPhase)
      TogglePhaseView();

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
  ArrayFree(g_phase_unwrapped_shared);
  ArrayFree(g_amplitude_shared);
  ArrayFree(g_period_shared);
  ArrayFree(g_frequency_shared);
  ArrayFree(g_eta_shared);
  ArrayFree(g_countdown_shared);
  ArrayFree(g_recon_shared);
  ArrayFree(g_kalman_shared);
  ArrayFree(g_turn_shared);
  ArrayFree(g_confidence_shared);
  ArrayFree(g_amp_delta_shared);
  ArrayFree(g_direction_shared);
  ArrayFree(g_power_shared);
  ArrayFree(g_velocity_shared);
  ArrayFree(g_plv_cycles_shared);
  ArrayFree(g_snr_cycles_shared);
  ArrayFree(g_phase_all_shared);
  ArrayFree(g_phase_unwrapped_all_shared);
  ArrayFree(g_amplitude_all_shared);
  ArrayFree(g_period_all_shared);
  ArrayFree(g_frequency_all_shared);
  ArrayFree(g_eta_all_shared);
  ArrayFree(g_countdown_all_shared);
  ArrayFree(g_direction_all_shared);
  ArrayFree(g_recon_all_shared);
  ArrayFree(g_kalman_all_shared);
  ArrayFree(g_turn_all_shared);
  ArrayFree(g_confidence_all_shared);
  ArrayFree(g_amp_delta_all_shared);
  ArrayFree(g_power_all_shared);
  ArrayFree(g_velocity_all_shared);
   const long chart_id = ChartID();
   if(g_waveVisible)
     {
      ChartIndicatorDelete(chart_id, InpWaveSubwindow, WAVE_IND_SHORTNAME);
      if(g_handleWaveViz != INVALID_HANDLE)
        IndicatorRelease(g_handleWaveViz);
     }
   if(g_phaseVisible)
     {
      ChartIndicatorDelete(chart_id, InpPhaseSubwindow, PHASE_IND_SHORTNAME);
      if(g_handlePhaseViz != INVALID_HANDLE)
        IndicatorRelease(g_handlePhaseViz);
     }
   g_handleWaveViz  = INVALID_HANDLE;
   g_handlePhaseViz = INVALID_HANDLE;
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

   const int frame_len   = InpFFTWindow;
   const int max_frames  = InpBatchSize;
   const int hop         = MathMax(InpHop, 1);
   if(frame_len <= 0 || max_frames <= 0 || hop <= 0)
      return;

   static int last_warn_bars = -1;
   const int bars_ready = BarsCalculated(g_zigzagHandle);
   if(bars_ready <= 0)
     {
      if(last_warn_bars != bars_ready)
         Print("[Hub] ZigZag ainda sem dados calculados.");
      last_warn_bars = bars_ready;
      return;
     }
   if(bars_ready < frame_len)
     {
      if(last_warn_bars != bars_ready)
         PrintFormat("[Hub] ZigZag ainda sem barras suficientes (%d < %d)", bars_ready, frame_len);
      last_warn_bars = bars_ready;
      return;
     }
   last_warn_bars = -1;

   int frames_possible = 1 + (bars_ready - frame_len) / hop;
   if(frames_possible < 1)
      frames_possible = 1;

   int frame_count = (int)MathMin((double)max_frames, (double)frames_possible);

   const int window_span = frame_len + (frame_count-1) * hop;
   int fetch_bars        = window_span + hop;
   if(fetch_bars > bars_ready)
      fetch_bars = bars_ready;

   if(!BuildZigZagSeries(fetch_bars))
      return;
   if(!PrepareBatchFrames(frame_len, frame_count))
      return;

   g_lastFrameCount = frame_count;
   g_lastFetchBars  = fetch_bars;

   int manual_cycle_count = 0;
   if(InpUseManualCycles)
      manual_cycle_count = CollectCyclePeriods(g_cyclePeriods);
   if(manual_cycle_count == 0)
      ArrayResize(g_cyclePeriods, 0);

   ulong handle = 0;
   ulong tag = (ulong)TimeCurrent();
   bool submitted = false;
   int job_cycle_count = 0;
   uint job_flags = JOB_FLAG_STFT;

   if(InpUseManualCycles && manual_cycle_count > 0)
     {
      job_cycle_count = manual_cycle_count;
      job_flags |= JOB_FLAG_CYCLES;
      submitted = g_engine.SubmitJobEx(g_batch_buffer,
                                       frame_count,
                                       tag,
                                       job_flags,
                                       g_gpuEmptyPreviewMask,
                                       g_cyclePeriods,
                                       manual_cycle_count,
                                       InpCycleWidth,
                                       InpGaussSigmaPeriod,
                                       InpMaskThreshold,
                                       InpMaskSoftness,
                                       InpMaskMinPeriod,
                                       InpMaskMaxPeriod,
                                       InpUpscaleFactor,
                                       (int)InpKalmanPreset,
                                       InpKalmanProcessNoise,
                                       InpKalmanMeasurementNoise,
                                       InpKalmanInitVariance,
                                       InpKalmanPlvThreshold,
                                       InpKalmanMaxIterations,
                                       InpKalmanConvergenceEps,
                                       handle);
     }
   else
     {
      job_cycle_count = MathMax(InpMaxCandidates, 0);
      if(job_cycle_count > 0)
         job_flags |= JOB_FLAG_CYCLES;
      submitted = g_engine.SubmitJobEx(g_batch_buffer,
                                       frame_count,
                                       tag,
                                       job_flags,
                                       g_gpuEmptyPreviewMask,
                                       g_gpuEmptyCyclePeriods,
                                       job_cycle_count,
                                       InpCycleWidth,
                                       InpGaussSigmaPeriod,
                                       InpMaskThreshold,
                                       InpMaskSoftness,
                                       InpMaskMinPeriod,
                                       InpMaskMaxPeriod,
                                       InpUpscaleFactor,
                                       (int)InpKalmanPreset,
                                       InpKalmanProcessNoise,
                                       InpKalmanMeasurementNoise,
                                       InpKalmanInitVariance,
                                       InpKalmanPlvThreshold,
                                       InpKalmanMaxIterations,
                                       InpKalmanConvergenceEps,
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
   job.cycle_count  = job_cycle_count;
   PushJob(job);
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
         ArrayResize(g_preview_shared,total);
         ArrayResize(g_noise_shared,  total);
         ArrayResize(g_cycles_shared, cycles_total);
         ArrayResize(g_phase_shared,            total);
         ArrayResize(g_phase_unwrapped_shared,  total);
         ArrayResize(g_amplitude_shared,        total);
         ArrayResize(g_period_shared,           total);
         ArrayResize(g_frequency_shared,        total);
         ArrayResize(g_eta_shared,              total);
         ArrayResize(g_countdown_shared,        total);
         ArrayResize(g_recon_shared,            total);
         ArrayResize(g_kalman_shared,           total);
         ArrayResize(g_turn_shared,             total);
         ArrayResize(g_confidence_shared,       total);
         ArrayResize(g_amp_delta_shared,        total);
         ArrayResize(g_direction_shared,        total);
         ArrayResize(g_power_shared,            total);
         ArrayResize(g_velocity_shared,         total);

         ArrayResize(g_phase_all_shared,            cycles_total);
         ArrayResize(g_phase_unwrapped_all_shared,  cycles_total);
         ArrayResize(g_amplitude_all_shared,        cycles_total);
         ArrayResize(g_period_all_shared,           cycles_total);
         ArrayResize(g_frequency_all_shared,        cycles_total);
         ArrayResize(g_eta_all_shared,              cycles_total);
         ArrayResize(g_countdown_all_shared,        cycles_total);
         ArrayResize(g_direction_all_shared,        cycles_total);
         ArrayResize(g_recon_all_shared,            cycles_total);
         ArrayResize(g_kalman_all_shared,           cycles_total);
         ArrayResize(g_turn_all_shared,             cycles_total);
         ArrayResize(g_confidence_all_shared,       cycles_total);
         ArrayResize(g_amp_delta_all_shared,        cycles_total);
         ArrayResize(g_power_all_shared,            cycles_total);
         ArrayResize(g_velocity_all_shared,         cycles_total);

         bool fetched = g_engine.FetchResult(g_jobs[i].handle,
                                             g_wave_shared,
                                             g_preview_shared,
                                             g_cycles_shared,
                                             g_noise_shared,
                                             g_phase_shared,
                                             g_phase_unwrapped_shared,
                                             g_amplitude_shared,
                                             g_period_shared,
                                             g_frequency_shared,
                                             g_eta_shared,
                                             g_countdown_shared,
                                             g_recon_shared,
                                             g_kalman_shared,
                                             g_confidence_shared,
                                             g_amp_delta_shared,
                                             g_turn_shared,
                                             g_direction_shared,
                                             g_power_shared,
                                             g_velocity_shared,
                                             g_phase_all_shared,
                                             g_phase_unwrapped_all_shared,
                                             g_amplitude_all_shared,
                                             g_period_all_shared,
                                             g_frequency_all_shared,
                                             g_eta_all_shared,
                                             g_countdown_all_shared,
                                             g_direction_all_shared,
                                             g_recon_all_shared,
                                             g_kalman_all_shared,
                                             g_turn_all_shared,
                                             g_confidence_all_shared,
                                             g_amp_delta_all_shared,
                                             g_power_all_shared,
                                             g_velocity_all_shared,
                                             g_plv_cycles_shared,
                                             g_snr_cycles_shared,
                                             info);

        if(fetched)
          {
            for(int idx=0; idx<total; ++idx)
              {
               g_direction_shared[idx] = (g_countdown_shared[idx] >= 0.0 ? 1.0 : -1.0);
               g_power_shared[idx]     = g_amplitude_shared[idx] * g_amplitude_shared[idx];
               g_velocity_shared[idx]  = g_frequency_shared[idx];
              }
           g_lastUpdateTime = TimeCurrent();
           g_engine.GetStats(g_lastAvgMs, g_lastMaxMs);
            if(info.cycle_count > 0)
              {
               const int cycles_total_actual = total * info.cycle_count;
               if(cycles_total_actual < ArraySize(g_cycles_shared))
                  ArrayResize(g_cycles_shared, cycles_total_actual);
               if(ArraySize(g_cyclePeriods) != info.cycle_count)
                  ArrayResize(g_cyclePeriods, info.cycle_count);
               ArrayResize(g_phase_all_shared,            cycles_total_actual);
               ArrayResize(g_phase_unwrapped_all_shared,  cycles_total_actual);
               ArrayResize(g_amplitude_all_shared,        cycles_total_actual);
               ArrayResize(g_period_all_shared,           cycles_total_actual);
               ArrayResize(g_frequency_all_shared,        cycles_total_actual);
               ArrayResize(g_eta_all_shared,              cycles_total_actual);
               ArrayResize(g_countdown_all_shared,        cycles_total_actual);
               ArrayResize(g_direction_all_shared,        cycles_total_actual);
               ArrayResize(g_recon_all_shared,            cycles_total_actual);
               ArrayResize(g_kalman_all_shared,           cycles_total_actual);
               ArrayResize(g_turn_all_shared,             cycles_total_actual);
               ArrayResize(g_confidence_all_shared,       cycles_total_actual);
               ArrayResize(g_amp_delta_all_shared,        cycles_total_actual);
               ArrayResize(g_power_all_shared,            cycles_total_actual);
               ArrayResize(g_velocity_all_shared,         cycles_total_actual);
               ArrayResize(g_plv_cycles_shared, info.cycle_count);
               ArrayResize(g_snr_cycles_shared, info.cycle_count);
              }
            else
              {
               ArrayResize(g_cycles_shared, 0);
               ArrayResize(g_cyclePeriods, 0);
               ArrayResize(g_phase_all_shared, 0);
               ArrayResize(g_phase_unwrapped_all_shared, 0);
               ArrayResize(g_amplitude_all_shared, 0);
               ArrayResize(g_period_all_shared, 0);
               ArrayResize(g_frequency_all_shared, 0);
               ArrayResize(g_eta_all_shared, 0);
               ArrayResize(g_countdown_all_shared, 0);
               ArrayResize(g_direction_all_shared, 0);
               ArrayResize(g_recon_all_shared, 0);
               ArrayResize(g_kalman_all_shared, 0);
               ArrayResize(g_turn_all_shared, 0);
               ArrayResize(g_confidence_all_shared, 0);
               ArrayResize(g_amp_delta_all_shared, 0);
               ArrayResize(g_power_all_shared, 0);
               ArrayResize(g_velocity_all_shared, 0);
               ArrayResize(g_plv_cycles_shared, 0);
               ArrayResize(g_snr_cycles_shared, 0);
              }
            DispatchSignals(info,
                             g_wave_shared,
                             g_preview_shared,
                             g_noise_shared,
                             g_cycles_shared);
           }

         RemoveJob(i);
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
  GPUShared::Publish(wave,
                     preview,
                     noise,
                     cycles,
                     g_cyclePeriods,
                     g_phase_shared,
                     g_phase_unwrapped_shared,
                     g_amplitude_shared,
                     g_period_shared,
                     g_frequency_shared,
                      g_eta_shared,
                      g_countdown_shared,
                      g_recon_shared,
                      g_kalman_shared,
                      g_turn_shared,
                      g_confidence_shared,
                      g_amp_delta_shared,
                      g_direction_shared,
                      g_power_shared,
                      g_velocity_shared,
                      g_phase_all_shared,
                      g_phase_unwrapped_all_shared,
                      g_amplitude_all_shared,
                      g_period_all_shared,
                      g_frequency_all_shared,
                      g_eta_all_shared,
                      g_countdown_all_shared,
                      g_direction_all_shared,
                      g_recon_all_shared,
                      g_kalman_all_shared,
                      g_turn_all_shared,
                      g_confidence_all_shared,
                      g_amp_delta_all_shared,
                      g_power_all_shared,
                      g_velocity_all_shared,
                      g_plv_cycles_shared,
                      g_snr_cycles_shared,
                      info);
   // TODO: disparar eventos ou sinalizar variáveis globais, se necessário.
   PrintFormat("[Hub] Job %I64u concluído | frames=%d | elapsed=%.2f ms",
               info.user_tag, info.frame_count, info.elapsed_ms);
   if(info.cycle_count > 0)
      PrintFormat("[Hub] Ciclos retornados: %d", info.cycle_count);
   if(info.dominant_cycle >= 0)
      PrintFormat("[Hub] Dominante idx=%d | período=%.2f | SNR=%.3f | confiança=%.2f",
                  info.dominant_cycle, info.dominant_period, info.dominant_snr, info.dominant_confidence);
  }

//+------------------------------------------------------------------+
void PushJob(const PendingJob &job)
  {
   const int idx = ArraySize(g_jobs);
   ArrayResize(g_jobs, idx + 1);
   g_jobs[idx] = job;
  }

void RemoveJob(const int index)
  {
   const int total = ArraySize(g_jobs);
   if(index < 0 || index >= total)
      return;
   for(int i=index; i<total-1; ++i)
      g_jobs[i] = g_jobs[i+1];
   ArrayResize(g_jobs, total-1);
  }
