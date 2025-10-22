//+------------------------------------------------------------------+
//|                                              WaveSpecZZ_GaussGPU |
//| ZigZag-driven GPU FFT filter with Gaussian spectral masking      |
//| Author: Codex assistant                                          |
//+------------------------------------------------------------------+
#property copyright "2025"
#property version   "0.100"

#property indicator_separate_window
#property indicator_buffers 14
#property indicator_plots   14

#property indicator_label1  "LineFiltered"
#property indicator_type1   DRAW_LINE
#property indicator_color1  clrGold
#property indicator_width1  2

#property indicator_label2  "Noise"
#property indicator_type2   DRAW_LINE
#property indicator_color2  clrSilver
#property indicator_width2  1

#property indicator_label3  "Cycle1"
#property indicator_type3   DRAW_LINE
#property indicator_color3  clrDodgerBlue

#property indicator_label4  "Cycle2"
#property indicator_type4   DRAW_LINE
#property indicator_color4  clrDeepSkyBlue

#property indicator_label5  "Cycle3"
#property indicator_type5   DRAW_LINE
#property indicator_color5  clrAqua

#property indicator_label6  "Cycle4"
#property indicator_type6   DRAW_LINE
#property indicator_color6  clrSpringGreen

#property indicator_label7  "Cycle5"
#property indicator_type7   DRAW_LINE
#property indicator_color7  clrGreen

#property indicator_label8  "Cycle6"
#property indicator_type8   DRAW_LINE
#property indicator_color8  clrYellowGreen

#property indicator_label9  "Cycle7"
#property indicator_type9   DRAW_LINE
#property indicator_color9  clrOrange

#property indicator_label10 "Cycle8"
#property indicator_type10  DRAW_LINE
#property indicator_color10 clrTomato

#property indicator_label11 "Cycle9"
#property indicator_type11  DRAW_LINE
#property indicator_color11 clrCrimson

#property indicator_label12 "Cycle10"
#property indicator_type12  DRAW_LINE
#property indicator_color12 clrViolet

#property indicator_label13 "Cycle11"
#property indicator_type13  DRAW_LINE
#property indicator_color13 clrMagenta

#property indicator_label14 "Cycle12"
#property indicator_type14  DRAW_LINE
#property indicator_color14 clrSlateBlue

#include <WaveSpecZZ/WaveDebugUtils.mqh>
#include <zeroproxy/FFT/GpuBridgeExtended.mqh>
#include <WaveSpecGPU/GpuBatchProcessor.mqh>

#import "GpuBridge.dll"
int  GpuSessionInit(int device_id);
void GpuSessionClose();
int  GpuConfigureWaveform(int length);
int  RunWaveformFft(double &values[], double &fft_real[], double &fft_imag[], int length);
int  RunWaveformIfft(double &fft_real[], double &fft_imag[], double &output[], int length);
#import

#define GPU_STATUS_OK 0
#define GPU_STATUS_ALREADY_INITIALIZED -2

enum ZigzagFeedMode
  {
   Feed_PivotHold = 0,
   Feed_PivotBridge = 1,
   Feed_PivotMidpoint = 2
  };

//--- Inputs
input int              InpFFTWindow        = 4096;     // Janela FFT (potência de dois)
input int              InpUpscaleFactor    = 1;        // Upscaling antes da FFT
input int              InpBatchSize        = 128;      // Janelas processadas por batch
input ZigzagFeedMode   InpFeedMode         = Feed_PivotHold;
input int              InpZigZagDepth      = 12;
input int              InpZigZagDeviation  = 5;
input int              InpZigZagBackstep   = 3;
input double           InpGaussSigmaPeriod = 48.0;     // Período equivalente (barras) do Gaussian
input double           InpMaskThreshold    = 0.05;     // Limiar relativo para ativar ganho
input double           InpMaskSoftness     = 0.20;     // Mistura com o ganho relativo
input bool             InpUseGpu           = true;
input int              InpGpuDeviceId      = -1;
input bool             InpShowComment      = true;
input int              InpCommentFontSize  = 12;
input string           InpCommentFontName  = "Arial";
input color            InpCommentColor     = clrWhite;
input bool             InpDebugLog         = false;

//--- Ciclos
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
input double InpCycleWidth    = 0.25; // largura relativa (fração da freq central)

//--- Buffers principais
double g_bufLineFiltered[];
double g_bufNoise[];
double g_bufCycle1[];
double g_bufCycle2[];
double g_bufCycle3[];
double g_bufCycle4[];
double g_bufCycle5[];
double g_bufCycle6[];
double g_bufCycle7[];
double g_bufCycle8[];
double g_bufCycle9[];
double g_bufCycle10[];
double g_bufCycle11[];
double g_bufCycle12[];

//--- Trabalho
double g_fftRe[];
double g_fftIm[];
double g_fftReOriginal[];
double g_fftImOriginal[];
double g_fftReTemp[];
double g_fftImTemp[];
double g_maskMain[];
double g_maskTemp[];

double g_seriesZigzag[];
double g_seriesUpscaled[];
double g_seriesFiltered[];
double g_seriesNoise[];

double g_cyclePeriods[12];

CGpuBatchProcessor g_gpuProcessor;

int    g_windowLen    = 0;
int    g_effectiveLen = 0;
int    g_batchSize    = 0;

double g_accumChron[];
double g_weightChron[];
double g_cycleAccum[12][];
double g_cycleWeight[12][];

double g_waveChron[];
double g_previewChron[];

double g_batchInput[];
double g_batchFftRe[];
double g_batchFftIm[];

int    g_lastRatesTotal = 0;
int    g_lastUpscale    = 1;
double g_lastLineRms    = 0.0;
double g_lastNoiseRms   = 0.0;
uint   g_lastElapsedMs  = 0;

const string COMMENT_OBJ_NAME = "WaveSpecZZ_GaussGPU_HUD";
bool g_commentCreated = false;
int  g_commentWindow  = -1;

//--- helpers -------------------------------------------------------
void SetCyclesAsSeries(const bool value)
  {
   ArraySetAsSeries(g_bufCycle1, value);
   ArraySetAsSeries(g_bufCycle2, value);
   ArraySetAsSeries(g_bufCycle3, value);
   ArraySetAsSeries(g_bufCycle4, value);
   ArraySetAsSeries(g_bufCycle5, value);
   ArraySetAsSeries(g_bufCycle6, value);
   ArraySetAsSeries(g_bufCycle7, value);
   ArraySetAsSeries(g_bufCycle8, value);
   ArraySetAsSeries(g_bufCycle9, value);
   ArraySetAsSeries(g_bufCycle10, value);
   ArraySetAsSeries(g_bufCycle11, value);
   ArraySetAsSeries(g_bufCycle12, value);
  }

void ClearCycleBuffer(const int idx)
  {
   switch(idx)
     {
      case 0:  ArrayInitialize(g_bufCycle1,  EMPTY_VALUE); break;
      case 1:  ArrayInitialize(g_bufCycle2,  EMPTY_VALUE); break;
      case 2:  ArrayInitialize(g_bufCycle3,  EMPTY_VALUE); break;
      case 3:  ArrayInitialize(g_bufCycle4,  EMPTY_VALUE); break;
      case 4:  ArrayInitialize(g_bufCycle5,  EMPTY_VALUE); break;
      case 5:  ArrayInitialize(g_bufCycle6,  EMPTY_VALUE); break;
      case 6:  ArrayInitialize(g_bufCycle7,  EMPTY_VALUE); break;
      case 7:  ArrayInitialize(g_bufCycle8,  EMPTY_VALUE); break;
      case 8:  ArrayInitialize(g_bufCycle9,  EMPTY_VALUE); break;
     case 9:  ArrayInitialize(g_bufCycle10, EMPTY_VALUE); break;
     case 10: ArrayInitialize(g_bufCycle11, EMPTY_VALUE); break;
      case 11: ArrayInitialize(g_bufCycle12, EMPTY_VALUE); break;
      default: break;
     }
  }

void ClearAllCycles()
  {
   for(int i=0;i<12;i++)
      ClearCycleBuffer(i);
  }

void SetCycleValue(const int idx, const int shift, const double value)
  {
   switch(idx)
     {
      case 0:  g_bufCycle1[shift]  = value; break;
      case 1:  g_bufCycle2[shift]  = value; break;
      case 2:  g_bufCycle3[shift]  = value; break;
      case 3:  g_bufCycle4[shift]  = value; break;
      case 4:  g_bufCycle5[shift]  = value; break;
      case 5:  g_bufCycle6[shift]  = value; break;
      case 6:  g_bufCycle7[shift]  = value; break;
      case 7:  g_bufCycle8[shift]  = value; break;
     case 8:  g_bufCycle9[shift]  = value; break;
     case 9:  g_bufCycle10[shift] = value; break;
     case 10: g_bufCycle11[shift] = value; break;
     case 11: g_bufCycle12[shift] = value; break;
     default: break;
     }
  }

string FormatFeedMode()
  {
   switch(InpFeedMode)
     {
      case Feed_PivotHold:    return "PivotHold";
      case Feed_PivotBridge:  return "PivotBridge";
      case Feed_PivotMidpoint:return "PivotMidpoint";
     }
   return "Unknown";
  }

void RemoveCommentLabel()
  {
   if(ObjectFind(0, COMMENT_OBJ_NAME) >= 0)
      ObjectDelete(0, COMMENT_OBJ_NAME);
   g_commentCreated = false;
   g_commentWindow  = -1;
  }

void EnsureCommentLabel()
  {
   if(!InpShowComment)
      return;

   int target_window = ChartWindowFind(0, "WaveSpecZZ Gauss GPU");
   if(target_window < 0)
      target_window = 0;

   if(g_commentCreated && g_commentWindow != target_window)
      RemoveCommentLabel();

   if(g_commentCreated)
      return;

   if(ObjectFind(0, COMMENT_OBJ_NAME) >= 0)
      ObjectDelete(0, COMMENT_OBJ_NAME);

   if(ObjectCreate(0, COMMENT_OBJ_NAME, OBJ_LABEL, target_window, 0, 0))
     {
      ObjectSetInteger(0, COMMENT_OBJ_NAME, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, COMMENT_OBJ_NAME, OBJPROP_XDISTANCE, 6);
      ObjectSetInteger(0, COMMENT_OBJ_NAME, OBJPROP_YDISTANCE, 6);
      ObjectSetInteger(0, COMMENT_OBJ_NAME, OBJPROP_BACK, false);
      ObjectSetInteger(0, COMMENT_OBJ_NAME, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, COMMENT_OBJ_NAME, OBJPROP_SELECTABLE, false);
      g_commentCreated = true;
      g_commentWindow  = target_window;
     }
  }

void UpdateCommentLabel()
  {
   if(!InpShowComment)
     {
      RemoveCommentLabel();
      return;
     }

   EnsureCommentLabel();
   if(!g_commentCreated)
      return;

   string text = StringFormat("Feed: %s\nFFT: %d (x%d) | σ: %.2f\nRMS Line: %.5f | RMS Noise: %.5f\nTick: %ums",
                              FormatFeedMode(),
                              InpFFTWindow,
                              g_lastUpscale,
                              InpGaussSigmaPeriod,
                              g_lastLineRms,
                              g_lastNoiseRms,
                              g_lastElapsedMs);

   ObjectSetInteger(0, COMMENT_OBJ_NAME, OBJPROP_FONTSIZE, InpCommentFontSize);
   ObjectSetString(0, COMMENT_OBJ_NAME, OBJPROP_FONT, InpCommentFontName);
   ObjectSetInteger(0, COMMENT_OBJ_NAME, OBJPROP_COLOR, InpCommentColor);
   ObjectSetString(0, COMMENT_OBJ_NAME, OBJPROP_TEXT, text);
  }

bool IsPow2(const int value)
  {
   if(value <= 0)
      return false;
   return (value & (value - 1)) == 0;
  }

//--- utilidades -----------------------------------------------------
void InitCyclePeriods()
  {
   g_cyclePeriods[0]  = InpCyclePeriod1;
   g_cyclePeriods[1]  = InpCyclePeriod2;
   g_cyclePeriods[2]  = InpCyclePeriod3;
   g_cyclePeriods[3]  = InpCyclePeriod4;
   g_cyclePeriods[4]  = InpCyclePeriod5;
   g_cyclePeriods[5]  = InpCyclePeriod6;
   g_cyclePeriods[6]  = InpCyclePeriod7;
   g_cyclePeriods[7]  = InpCyclePeriod8;
   g_cyclePeriods[8]  = InpCyclePeriod9;
   g_cyclePeriods[9]  = InpCyclePeriod10;
   g_cyclePeriods[10] = InpCyclePeriod11;
   g_cyclePeriods[11] = InpCyclePeriod12;
  }

//--- ZigZag feed ----------------------------------------------------
int FetchZigZag(double &out[], const int length,
                const double &high[], const double &low[], const double &close[])
  {
   ArrayResize(out, length);
   ArrayInitialize(out, 0.0);

   static int zz_handle = INVALID_HANDLE;
   if(zz_handle == INVALID_HANDLE)
     {
      zz_handle = iCustom(_Symbol, _Period, "ZigZag", InpZigZagDepth, InpZigZagDeviation, InpZigZagBackstep);
      if(zz_handle == INVALID_HANDLE)
        {
         Print("Falha ao criar ZigZag");
         return 0;
        }
     }

   int available = BarsCalculated(zz_handle);
   if(available <= 0)
     {
      Print("ZigZag sem barras calculadas");
      return 0;
     }
   int copy_count = MathMin(length, available);

   double zz_main[];
   ArrayResize(zz_main, copy_count);
   if(CopyBuffer(zz_handle, 0, 0, copy_count, zz_main) != copy_count)
     {
      Print("CopyBuffer ZigZag falhou");
      return 0;
     }

   double zz_ext[];
   ArrayResize(zz_ext, length);
   double oldest = (copy_count>0) ? zz_main[copy_count-1] : 0.0;
   for(int i=0;i<length;i++)
     {
      if(i < copy_count) zz_ext[i] = zz_main[i];
      else zz_ext[i] = oldest;
     }

   // Convert zigzag to chronological order (oldest -> newest)
   double tmp[];
   ArrayResize(tmp, length);
   for(int i=0;i<length;i++) tmp[i] = zz_ext[length-1-i];

   switch(InpFeedMode)
     {
      case Feed_PivotHold:
         {
            double last = tmp[0];
            if(last == 0.0)
              {
               for(int i=0;i<length;i++) if(tmp[i]!=0.0){ last = tmp[i]; break; }
               if(last == 0.0)
                 {
                  double h0 = high[0];
                  double l0 = low[0];
                  if(!MathIsValidNumber(h0) || !MathIsValidNumber(l0))
                     last = close[0];
                  else
                     last = 0.5*(h0 + l0);
                 }
              }
            for(int i=0;i<length;i++)
              {
               double v = tmp[i];
               if(v == 0.0)
                  out[i] = last;
               else
                 {
                  out[i] = v;
                  last   = v;
                 }
              }
         }
         break;
      case Feed_PivotBridge:
         {
            ArrayCopy(out, tmp, 0, 0, length);
            int prev_idx = -1;
            double prev_val = 0.0;
            for(int i=0;i<length;i++)
              {
               double v = out[i];
               if(v != 0.0)
                 {
                  out[i] = v;
                  if(prev_idx < 0)
                    {
                     for(int j=0;j<=i;j++)
                        out[j] = v;
                    }
                  else
                    {
                     int span = i - prev_idx;
                     if(span <= 0) span = 1;
                     double step = (v - prev_val) / span;
                     for(int j=0;j<span;j++)
                        out[prev_idx + j] = prev_val + step*j;
                    }
                  prev_idx = i;
                  prev_val = v;
                 }
              }
            if(prev_idx >= 0)
              {
               for(int j=prev_idx;j<length;j++)
                  out[j] = prev_val;
              }
            else
               for(int i=0;i<length;i++)
                 {
                  int shift = length - 1 - i;
                  double h = high[shift];
                  double l = low[shift];
                  if(!MathIsValidNumber(h) || !MathIsValidNumber(l))
                     out[i] = close[shift];
                  else
                     out[i] = 0.5*(h + l);
                 }
         }
         break;
      case Feed_PivotMidpoint:
         {
            for(int i=0;i<length;i++)
              {
               if(tmp[i] != 0.0) out[i] = tmp[i];
               else
                 {
                  int shift = length - 1 - i;
                  double h = high[shift];
                  double l = low[shift];
                  if(!MathIsValidNumber(h) || !MathIsValidNumber(l))
                     out[i] = close[shift];
                  else
                     out[i] = 0.5 * (h + l);
                 }
              }
         }
         break;
     }

   return length;
  }

//--- Upscaling ------------------------------------------------------
int UpscaleSeries(const double &src[], const int len, double &dst[], const int factor)
  {
   if(factor <= 1)
     {
      ArrayResize(dst, len);
      ArrayCopy(dst, src);
      return len;
     }

   int target = len * factor;
   ArrayResize(dst, target);
   if(len <= 1)
     {
      for(int i=0;i<target;i++) dst[i] = src[0];
      return target;
     }

   for(int i=0;i<len-1;i++)
     {
      double v0 = src[i];
      double v1 = src[i+1];
      for(int s=0;s<factor;s++)
        {
         double t = (double)s / factor;
         dst[i*factor + s] = v0 + (v1 - v0) * t;
        }
     }
   dst[target-1] = src[len-1];
   return target;
  }

//--- Gaussian Mask --------------------------------------------------
void BuildGaussianMask(const int length, double sigma_period, double threshold, double softness,
                       const double &fft_re[], const double &fft_im[], double &mask_out[])
  {
   ArrayResize(mask_out, length);
   if(sigma_period <= 0.0)
      sigma_period = 1.0;

   double freq_resolution = 1.0 / length; // ciclos por amostra
   double sigma_freq = 1.0 / sigma_period;
   if(sigma_freq <= 0.0)
      sigma_freq = freq_resolution;

   double max_mag = 0.0;
   for(int k=0;k<length;k++)
     {
      double mag = MathSqrt(fft_re[k]*fft_re[k] + fft_im[k]*fft_im[k]);
      if(mag > max_mag) max_mag = mag;
     }
   if(max_mag <= 0.0) max_mag = 1.0;

   for(int k=0;k<length;k++)
     {
      double freq = (k <= length/2) ? (k * freq_resolution) : (-(length - k) * freq_resolution);
      double gauss = MathExp(-0.5 * (freq/sigma_freq)*(freq/sigma_freq));
      double mag = MathSqrt(fft_re[k]*fft_re[k] + fft_im[k]*fft_im[k]) / max_mag;
      double gain = gauss;
      if(mag < threshold)
         gain *= mag / threshold;
      else
         gain *= (1.0 - softness) + softness * mag;
      mask_out[k] = MathMin(1.0, MathMax(0.0, gain));
     }
  }

void ApplyMask(double &fft_re[], double &fft_im[], const double &mask[], const int length)
  {
   for(int k=0;k<length;k++)
     {
      fft_re[k] *= mask[k];
      fft_im[k] *= mask[k];
     }
  }

//--- IFFT helper ----------------------------------------------------
bool PerformIfft(double &fft_re[], double &fft_im[], double &output[], const int length)
  {
   if(!EnsureGpuReady(length))
      return false;

   int status = RunWaveformIfft(fft_re, fft_im, output, length);
   if(status != GPU_STATUS_OK)
     {
      PrintFormat("RunWaveformIfft falhou: %d", status);
      return false;
     }
   return true;
  }

bool PerformFft(double &series[], double &fft_re[], double &fft_im[], const int length)
  {
   if(!EnsureGpuReady(length))
      return false;

   ArrayResize(fft_re, length);
   ArrayResize(fft_im, length);
   int status = RunWaveformFft(series, fft_re, fft_im, length);
   if(status != GPU_STATUS_OK)
     {
      PrintFormat("RunWaveformFft falhou: %d", status);
      return false;
     }
   return true;
  }

//--- Processamento principal ---------------------------------------
bool ProcessWindowLatest(const int length,
                         const double &high[], const double &low[], const double &close[])
  {
   if(length <= 0)
      return false;

   ArrayResize(g_seriesZigzag, length);
   if(FetchZigZag(g_seriesZigzag, length, high, low, close) != length)
      return false;

   int upscale = MathMax(1, InpUpscaleFactor);
   int eff_len = UpscaleSeries(g_seriesZigzag, length, g_seriesUpscaled, upscale);

   if(!PerformFft(g_seriesUpscaled, g_fftRe, g_fftIm, eff_len))
      return false;

   ArrayResize(g_fftReOriginal, eff_len);
   ArrayResize(g_fftImOriginal, eff_len);
   ArrayCopy(g_fftReOriginal, g_fftRe);
   ArrayCopy(g_fftImOriginal, g_fftIm);

   BuildGaussianMask(eff_len, InpGaussSigmaPeriod * upscale, InpMaskThreshold, InpMaskSoftness,
                     g_fftReOriginal, g_fftImOriginal, g_maskMain);
   ApplyMask(g_fftRe, g_fftIm, g_maskMain, eff_len);

   ArrayResize(g_seriesFiltered, eff_len);
   if(!PerformIfft(g_fftRe, g_fftIm, g_seriesFiltered, eff_len))
      return false;

   // Downsample if needed
   double filteredUpscaled[];
   ArrayResize(filteredUpscaled, eff_len);
   ArrayCopy(filteredUpscaled, g_seriesFiltered, 0, 0, eff_len);

   ArrayResize(g_seriesFiltered, length);
  if(upscale > 1)
    {
     for(int i=0;i<length;i++)
       {
        int idx_up = i*upscale + (upscale/2);
         if(idx_up >= eff_len) idx_up = eff_len - 1;
         g_seriesFiltered[i] = filteredUpscaled[idx_up];
        }
     }
   else
      ArrayCopy(g_seriesFiltered, filteredUpscaled, 0, 0, length);

   ArrayResize(g_seriesNoise, length);
   for(int i=0;i<length;i++)
      g_seriesNoise[i] = g_seriesZigzag[i] - g_seriesFiltered[i];

   double sumLine=0.0, sumNoise=0.0;
   for(int i=0;i<length;i++)
     {
      sumLine  += g_seriesFiltered[i]*g_seriesFiltered[i];
      sumNoise += g_seriesNoise[i]*g_seriesNoise[i];
     }
   g_lastLineRms  = (length>0)? MathSqrt(sumLine / length) : 0.0;
   g_lastNoiseRms = (length>0)? MathSqrt(sumNoise / length) : 0.0;
   g_lastEffectiveLength = eff_len;
   g_lastUpscale         = upscale;

   // Escreve buffers principais (convertendo para série MT5)
   for(int i=0;i<length;i++)
     {
      int shift = length - 1 - i;
      g_bufLineFiltered[shift] = g_seriesFiltered[i];
      g_bufNoise[shift]        = g_seriesNoise[i];
     }

   // --- ciclos ---
   for(int c=0;c<12;c++)
     {
      ClearCycleBuffer(c);
      ArrayResize(g_fftReTemp, eff_len);
      ArrayResize(g_fftImTemp, eff_len);
      ArrayCopy(g_fftReTemp, g_fftReOriginal);
      ArrayCopy(g_fftImTemp, g_fftImOriginal);

      double center_period = g_cyclePeriods[c];
      if(center_period <= 0.0) center_period = 1.0;
      double center_freq = (double)upscale / center_period;
      double width = MathMax(0.01, InpCycleWidth);

      ArrayResize(g_maskTemp, eff_len);
      double freq_resolution = 1.0 / eff_len;
      for(int k=0;k<eff_len;k++)
        {
         double freq = (k <= eff_len/2) ? (k * freq_resolution) : (-(eff_len - k) * freq_resolution);
         double rel = MathAbs(freq - center_freq) / MathMax(center_freq, 1e-9);
         double gain = MathExp(-0.5 * (rel/width)*(rel/width));
         g_maskTemp[k] = gain;
        }
      ApplyMask(g_fftReTemp, g_fftImTemp, g_maskTemp, eff_len);

      double series_cycle_up[];
      ArrayResize(series_cycle_up, eff_len);
      if(!PerformIfft(g_fftReTemp, g_fftImTemp, series_cycle_up, eff_len))
         continue;

      double series_cycle[];
      ArrayResize(series_cycle, length);
      if(upscale > 1)
        {
         for(int i=0;i<length;i++)
           {
            int idx_up = i*upscale + (upscale/2);
            if(idx_up >= eff_len) idx_up = eff_len - 1;
            series_cycle[i] = series_cycle_up[idx_up];
           }
        }
      else
         ArrayCopy(series_cycle, series_cycle_up, 0, 0, length);

      for(int i=0;i<length;i++)
        {
         int shift = length - 1 - i;
         SetCycleValue(c, shift, series_cycle[i]);
        }
     }

   return true;
  }

//--- Interface do indicador ----------------------------------------
int OnInit()
  {
   Print("[WaveSpecZZ_GaussGPU] inicializando");

   if(!IsPow2(InpFFTWindow))
     {
      Print("InpFFTWindow deve ser potência de 2");
      return INIT_FAILED;
     }

   RemoveCommentLabel();

   ArraySetAsSeries(g_bufLineFiltered, true);
   ArraySetAsSeries(g_bufNoise,        true);
   SetCyclesAsSeries(true);

   SetIndexBuffer(0, g_bufLineFiltered, INDICATOR_DATA);
   SetIndexBuffer(1, g_bufNoise,        INDICATOR_DATA);
   SetIndexBuffer(2,  g_bufCycle1,  INDICATOR_DATA);
   SetIndexBuffer(3,  g_bufCycle2,  INDICATOR_DATA);
   SetIndexBuffer(4,  g_bufCycle3,  INDICATOR_DATA);
   SetIndexBuffer(5,  g_bufCycle4,  INDICATOR_DATA);
   SetIndexBuffer(6,  g_bufCycle5,  INDICATOR_DATA);
   SetIndexBuffer(7,  g_bufCycle6,  INDICATOR_DATA);
   SetIndexBuffer(8,  g_bufCycle7,  INDICATOR_DATA);
   SetIndexBuffer(9,  g_bufCycle8,  INDICATOR_DATA);
   SetIndexBuffer(10, g_bufCycle9,  INDICATOR_DATA);
   SetIndexBuffer(11, g_bufCycle10, INDICATOR_DATA);
   SetIndexBuffer(12, g_bufCycle11, INDICATOR_DATA);
   SetIndexBuffer(13, g_bufCycle12, INDICATOR_DATA);

   for(int c=0;c<12;c++)
      PlotIndexSetDouble(2+c, PLOT_EMPTY_VALUE, EMPTY_VALUE);

   PlotIndexSetDouble(0, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetDouble(1, PLOT_EMPTY_VALUE, EMPTY_VALUE);

   ArrayInitialize(g_bufLineFiltered, EMPTY_VALUE);
   ArrayInitialize(g_bufNoise,        EMPTY_VALUE);
   ClearAllCycles();

   InitCyclePeriods();
   IndicatorSetString(INDICATOR_SHORTNAME, "WaveSpecZZ Gauss GPU");
   PlotIndexSetInteger(0, PLOT_DRAW_BEGIN, InpFFTWindow);
   PlotIndexSetInteger(1, PLOT_DRAW_BEGIN, InpFFTWindow);
   for(int c=0;c<12;c++)
      PlotIndexSetInteger(2+c, PLOT_DRAW_BEGIN, InpFFTWindow);
   g_lastRatesTotal = 0;
   g_lastElapsedMs  = 0;
   UpdateCommentLabel();

   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   ShutdownGpu();
   RemoveCommentLabel();
  }

int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
  {
  if(rates_total < InpFFTWindow)
    {
      if(InpDebugLog)
         PrintFormat("[GaussGPU] OnCalculate skip: rates_total=%d < window=%d", rates_total, InpFFTWindow);
      g_lastElapsedMs = 0;
      UpdateCommentLabel();
      return prev_calculated;
     }

   uint tick_start = GetTickCount();

   if(!ProcessWindowLatest(InpFFTWindow, high, low, close))
      return prev_calculated;

   uint elapsed = GetTickCount() - tick_start;

   if(InpDebugLog)
     {
      int oldest_shift = InpFFTWindow - 1;
      PrintFormat("[GaussGPU] OnCalculate: rates_total=%d prev=%d window=%d oldest_shift=%d elapsed=%ums",
                  rates_total, prev_calculated, InpFFTWindow, oldest_shift, elapsed);
     }

   g_lastRatesTotal = rates_total;
   g_lastElapsedMs  = elapsed;
   UpdateCommentLabel();
   return rates_total;
  }
