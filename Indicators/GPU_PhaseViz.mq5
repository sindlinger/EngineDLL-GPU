//+------------------------------------------------------------------+
//|                                             GPU_PhaseViz.mq5     |
//| Visualizador da fase/amplitude/ETA fornecidas pela DLL.         |
//+------------------------------------------------------------------+
#property copyright "2025"
#property version   "1.000"
#property indicator_separate_window
#property indicator_buffers 12
#property indicator_plots   12

#property indicator_label1  "Phase(deg)"
#property indicator_type1   DRAW_LINE
#property indicator_color1  clrGold
#property indicator_width1  2

#property indicator_label2  "Amplitude"
#property indicator_type2   DRAW_LINE
#property indicator_color2  clrDodgerBlue

#property indicator_label3  "Period(bars)"
#property indicator_type3   DRAW_LINE
#property indicator_color3  clrLime

#property indicator_label4  "ETA(bars)"
#property indicator_type4   DRAW_LINE
#property indicator_color4  clrOrange

#property indicator_label5  "Reconstructed"
#property indicator_type5   DRAW_LINE
#property indicator_color5  clrWhite

#property indicator_label6  "Confidence"
#property indicator_type6   DRAW_LINE
#property indicator_color6  clrPaleGreen

#property indicator_label7  "dAmp"
#property indicator_type7   DRAW_LINE
#property indicator_color7  clrMediumVioletRed

#property indicator_label8  "Phase Unwrapped"
#property indicator_type8   DRAW_LINE
#property indicator_color8  clrSlateBlue

#property indicator_label9  "Kalman"
#property indicator_type9   DRAW_LINE
#property indicator_color9  clrYellow
#property indicator_width9  2

#property indicator_label10 "TurnPulse"
#property indicator_type10  DRAW_HISTOGRAM
#property indicator_color10 clrOrangeRed
#property indicator_width10 2

#property indicator_label11 "Countdown"
#property indicator_type11  DRAW_LINE
#property indicator_color11 clrTomato

#property indicator_label12 "Direction"
#property indicator_type12  DRAW_NONE

#include <GPU/GPU_Shared.mqh>

double g_bufPhase[];
double g_bufAmplitude[];
double g_bufPeriod[];
double g_bufEta[];
double g_bufRecon[];
double g_bufConfidence[];
double g_bufAmpDelta[];
double g_bufPhaseUnwrapped[];
double g_bufKalman[];
double g_bufTurn[];
double g_bufCountdown[];
double g_bufDirection[];

int OnInit()
  {
   SetIndexBuffer(0, g_bufPhase,         INDICATOR_DATA);
   SetIndexBuffer(1, g_bufAmplitude,     INDICATOR_DATA);
   SetIndexBuffer(2, g_bufPeriod,        INDICATOR_DATA);
   SetIndexBuffer(3, g_bufEta,           INDICATOR_DATA);
   SetIndexBuffer(4, g_bufRecon,         INDICATOR_DATA);
   SetIndexBuffer(5, g_bufConfidence,    INDICATOR_DATA);
   SetIndexBuffer(6, g_bufAmpDelta,      INDICATOR_DATA);
   SetIndexBuffer(7, g_bufPhaseUnwrapped,INDICATOR_DATA);
   SetIndexBuffer(8, g_bufKalman,        INDICATOR_DATA);
   SetIndexBuffer(9, g_bufTurn,          INDICATOR_DATA);
   SetIndexBuffer(10, g_bufCountdown,    INDICATOR_DATA);
   SetIndexBuffer(11, g_bufDirection,    INDICATOR_DATA);

   ArraySetAsSeries(g_bufPhase,         true);
   ArraySetAsSeries(g_bufAmplitude,     true);
   ArraySetAsSeries(g_bufPeriod,        true);
   ArraySetAsSeries(g_bufEta,           true);
   ArraySetAsSeries(g_bufRecon,         true);
   ArraySetAsSeries(g_bufConfidence,    true);
   ArraySetAsSeries(g_bufAmpDelta,      true);
   ArraySetAsSeries(g_bufPhaseUnwrapped,true);
   ArraySetAsSeries(g_bufKalman,        true);
   ArraySetAsSeries(g_bufTurn,          true);
   ArraySetAsSeries(g_bufCountdown,     true);
   ArraySetAsSeries(g_bufDirection,     true);

   IndicatorSetString(INDICATOR_SHORTNAME, "GPU PhaseViz");

   return(INIT_SUCCEEDED);
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
   if(rates_total <= 0)
      return prev_calculated;

   const int frame_count  = GPUShared::frame_count;
   const int frame_length = GPUShared::frame_length;
   if(frame_count <= 0 || frame_length <= 0)
     {
      g_bufPhase[0]          = EMPTY_VALUE;
      g_bufAmplitude[0]      = EMPTY_VALUE;
      g_bufPeriod[0]         = EMPTY_VALUE;
      g_bufEta[0]            = EMPTY_VALUE;
      g_bufRecon[0]          = EMPTY_VALUE;
      g_bufConfidence[0]     = EMPTY_VALUE;
      g_bufAmpDelta[0]       = EMPTY_VALUE;
      g_bufPhaseUnwrapped[0] = EMPTY_VALUE;
      g_bufKalman[0]         = EMPTY_VALUE;
      g_bufTurn[0]           = EMPTY_VALUE;
      return rates_total;
     }

   const int total = frame_count * frame_length;
   if(ArraySize(GPUShared::phase) < total ||
      ArraySize(GPUShared::phase_unwrapped) < total ||
      ArraySize(GPUShared::amplitude) < total ||
      ArraySize(GPUShared::period) < total ||
      ArraySize(GPUShared::eta) < total ||
      ArraySize(GPUShared::countdown) < total ||
      ArraySize(GPUShared::recon) < total ||
      ArraySize(GPUShared::kalman) < total ||
      ArraySize(GPUShared::turn) < total ||
      ArraySize(GPUShared::confidence) < total ||
      ArraySize(GPUShared::amp_delta) < total ||
      ArraySize(GPUShared::direction) < total)
     {
      return rates_total;
     }

   if(GPUShared::last_info.dominant_cycle < 0)
     {
      g_bufPhase[0]          = EMPTY_VALUE;
      g_bufAmplitude[0]      = EMPTY_VALUE;
      g_bufPeriod[0]         = EMPTY_VALUE;
      g_bufEta[0]            = EMPTY_VALUE;
      g_bufCountdown[0]      = EMPTY_VALUE;
      g_bufRecon[0]          = EMPTY_VALUE;
      g_bufConfidence[0]     = EMPTY_VALUE;
      g_bufAmpDelta[0]       = EMPTY_VALUE;
      g_bufPhaseUnwrapped[0] = EMPTY_VALUE;
      g_bufKalman[0]         = EMPTY_VALUE;
      g_bufTurn[0]           = EMPTY_VALUE;
      g_bufDirection[0]      = EMPTY_VALUE;
      return rates_total;
     }

   const int src_index = total - 1;

   g_bufPhase[0]          = GPUShared::phase[src_index];
   g_bufAmplitude[0]      = GPUShared::amplitude[src_index];
   g_bufPeriod[0]         = GPUShared::period[src_index];
   g_bufEta[0]            = GPUShared::eta[src_index];
   g_bufCountdown[0]      = GPUShared::countdown[src_index];
   g_bufRecon[0]          = GPUShared::recon[src_index];
   g_bufConfidence[0]     = GPUShared::confidence[src_index];
   g_bufAmpDelta[0]       = GPUShared::amp_delta[src_index];
   g_bufPhaseUnwrapped[0] = GPUShared::phase_unwrapped[src_index];
   g_bufKalman[0]         = GPUShared::kalman[src_index];
   g_bufTurn[0]           = GPUShared::turn[src_index];
   g_bufDirection[0]      = GPUShared::direction[src_index];

   return rates_total;
  }
