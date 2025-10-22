//+------------------------------------------------------------------+
//| GPU_WaveViz                                                     |
//| Visualizador dos buffers publicados pelo EA GPU_EngineHub.      |
//| Lê GPU_Shared e desenha linha filtrada, ruído e 12 ciclos.       |
//+------------------------------------------------------------------+
#property copyright "2025"
#property version   "1.000"
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

#include <GPU/GPU_Shared.mqh>

input bool InpShowNoise   = true;
input bool InpShowCycles  = true;
input int  InpMaxCycles   = 12;

double g_bufWave[];
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

//+------------------------------------------------------------------+
void ClearCycleBuffers()
  {
   ArrayInitialize(g_bufCycle1, EMPTY_VALUE);
   ArrayInitialize(g_bufCycle2, EMPTY_VALUE);
   ArrayInitialize(g_bufCycle3, EMPTY_VALUE);
   ArrayInitialize(g_bufCycle4, EMPTY_VALUE);
   ArrayInitialize(g_bufCycle5, EMPTY_VALUE);
   ArrayInitialize(g_bufCycle6, EMPTY_VALUE);
   ArrayInitialize(g_bufCycle7, EMPTY_VALUE);
   ArrayInitialize(g_bufCycle8, EMPTY_VALUE);
   ArrayInitialize(g_bufCycle9, EMPTY_VALUE);
   ArrayInitialize(g_bufCycle10, EMPTY_VALUE);
   ArrayInitialize(g_bufCycle11, EMPTY_VALUE);
   ArrayInitialize(g_bufCycle12, EMPTY_VALUE);
  }

void SetCycleValue(const int index,
                   const int bar_index,
                   const double value)
  {
   switch(index)
     {
      case 0: g_bufCycle1[bar_index]  = value; break;
      case 1: g_bufCycle2[bar_index]  = value; break;
      case 2: g_bufCycle3[bar_index]  = value; break;
      case 3: g_bufCycle4[bar_index]  = value; break;
      case 4: g_bufCycle5[bar_index]  = value; break;
      case 5: g_bufCycle6[bar_index]  = value; break;
      case 6: g_bufCycle7[bar_index]  = value; break;
      case 7: g_bufCycle8[bar_index]  = value; break;
      case 8: g_bufCycle9[bar_index]  = value; break;
      case 9: g_bufCycle10[bar_index] = value; break;
      case 10:g_bufCycle11[bar_index] = value; break;
      case 11:g_bufCycle12[bar_index] = value; break;
     }
  }

int OnInit()
  {
   SetIndexBuffer(0, g_bufWave,  INDICATOR_DATA);
   SetIndexBuffer(1, g_bufNoise, INDICATOR_DATA);
   SetIndexBuffer(2, g_bufCycle1,  INDICATOR_DATA);
   SetIndexBuffer(3, g_bufCycle2,  INDICATOR_DATA);
   SetIndexBuffer(4, g_bufCycle3,  INDICATOR_DATA);
   SetIndexBuffer(5, g_bufCycle4,  INDICATOR_DATA);
   SetIndexBuffer(6, g_bufCycle5,  INDICATOR_DATA);
   SetIndexBuffer(7, g_bufCycle6,  INDICATOR_DATA);
   SetIndexBuffer(8, g_bufCycle7,  INDICATOR_DATA);
   SetIndexBuffer(9, g_bufCycle8,  INDICATOR_DATA);
   SetIndexBuffer(10,g_bufCycle9,  INDICATOR_DATA);
   SetIndexBuffer(11,g_bufCycle10, INDICATOR_DATA);
   SetIndexBuffer(12,g_bufCycle11, INDICATOR_DATA);
   SetIndexBuffer(13,g_bufCycle12, INDICATOR_DATA);

   ArraySetAsSeries(g_bufWave,  true);
   ArraySetAsSeries(g_bufNoise, true);
   ArraySetAsSeries(g_bufCycle1,  true);
   ArraySetAsSeries(g_bufCycle2,  true);
   ArraySetAsSeries(g_bufCycle3,  true);
   ArraySetAsSeries(g_bufCycle4,  true);
   ArraySetAsSeries(g_bufCycle5,  true);
   ArraySetAsSeries(g_bufCycle6,  true);
   ArraySetAsSeries(g_bufCycle7,  true);
   ArraySetAsSeries(g_bufCycle8,  true);
   ArraySetAsSeries(g_bufCycle9,  true);
   ArraySetAsSeries(g_bufCycle10, true);
   ArraySetAsSeries(g_bufCycle11, true);
   ArraySetAsSeries(g_bufCycle12, true);

   IndicatorSetString(INDICATOR_SHORTNAME, "GPU WaveViz");

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
   const int frame_length = GPUShared::frame_length;
    const int frame_count  = GPUShared::frame_count;
    const int total_span   = frame_length * frame_count;
    const int cycle_count  = MathMin(GPUShared::cycle_count, MathMax(InpMaxCycles, 0));

   ArrayInitialize(g_bufWave,  EMPTY_VALUE);
   ArrayInitialize(g_bufNoise, EMPTY_VALUE);
   ClearCycleBuffers();

   if(frame_length <= 0 || frame_count <= 0 || rates_total <= 0)
      return rates_total;

   if(ArraySize(GPUShared::wave) < total_span ||
      ArraySize(GPUShared::noise) < total_span)
      return rates_total;

   const int samples_total = frame_length;
   const int available = MathMin(samples_total, rates_total);
   const int frame_offset = (frame_count - 1) * frame_length;

   for(int i=0; i<available; ++i)
     {
      const int src_index = frame_offset + i;
      g_bufWave[i] = GPUShared::wave[src_index];
      if(InpShowNoise)
         g_bufNoise[i] = GPUShared::noise[src_index];
      if(InpShowCycles && cycle_count > 0 && ArraySize(GPUShared::cycles) >= total_span * cycle_count)
        {
         for(int c=0; c<cycle_count; ++c)
           {
            const int cycle_base = c * total_span;
            SetCycleValue(c, i, GPUShared::cycles[cycle_base + src_index]);
           }
        }
     }

   return rates_total;
  }
