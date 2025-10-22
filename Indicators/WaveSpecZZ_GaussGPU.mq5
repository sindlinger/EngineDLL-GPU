//+------------------------------------------------------------------+
//| WaveSpecZZ_GaussGPU                                             |
//| Visualizador dos buffers publicados pelo EA WaveSpecGPU_Hub.    |
//| Lê WaveSpecShared e desenha linha filtrada, ruído e 12 ciclos.   |
//+------------------------------------------------------------------+
#property copyright "2025"
#property version   "1.00"
#property indicator_separate_window
#property indicator_buffers 14
#property indicator_plots   14

#property indicator_label1  "Wave"
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

#include <WaveSpecGPU/WaveSpecShared.mqh>

input bool InpShowNoise   = true;
input bool InpShowCycles  = true;
input int  InpMaxCycles   = 12;

double g_bufWave[];
double g_bufNoise[];
double g_bufCycle[12][];

//+------------------------------------------------------------------+
int OnInit()
  {
   SetIndexBuffer(0, g_bufWave,  INDICATOR_DATA);
   SetIndexBuffer(1, g_bufNoise, INDICATOR_DATA);

   for(int i=0; i<12; ++i)
      SetIndexBuffer(i+2, g_bufCycle[i], INDICATOR_DATA);

   ArraySetAsSeries(g_bufWave,  true);
   ArraySetAsSeries(g_bufNoise, true);
   for(int i=0; i<12; ++i)
      ArraySetAsSeries(g_bufCycle[i], true);

   IndicatorSetString(INDICATOR_SHORTNAME, "WaveSpecZZ GPU");

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
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
   const int frame_length = WaveSpecShared::frame_length;
   const int frame_count  = WaveSpecShared::frame_count;
   const int total_span   = frame_length * frame_count;
   const int cycle_count  = MathMin(WaveSpecShared::cycle_count, MathMax(InpMaxCycles, 0));

   ArrayInitialize(g_bufWave,  EMPTY_VALUE);
   ArrayInitialize(g_bufNoise, EMPTY_VALUE);
   for(int c=0; c<12; ++c)
      ArrayInitialize(g_bufCycle[c], EMPTY_VALUE);

   if(frame_length <= 0 || frame_count <= 0 || rates_total <= 0)
      return rates_total;

   if(ArraySize(WaveSpecShared::wave) < total_span ||
      ArraySize(WaveSpecShared::noise) < total_span)
      return rates_total;

   const int samples_total = frame_length;
   const int available = MathMin(samples_total, rates_total);
   const int frame_offset = (frame_count - 1) * frame_length;

   for(int i=0; i<available; ++i)
     {
      const int src_index = frame_offset + i;
      g_bufWave[i] = WaveSpecShared::wave[src_index];
      if(InpShowNoise)
         g_bufNoise[i] = WaveSpecShared::noise[src_index];
      if(InpShowCycles && cycle_count > 0 && ArraySize(WaveSpecShared::cycles) >= total_span * cycle_count)
        {
         for(int c=0; c<cycle_count; ++c)
           {
            const int cycle_base = c * total_span;
            g_bufCycle[c][i] = WaveSpecShared::cycles[cycle_base + src_index];
           }
        }
     }

   return rates_total;
  }
