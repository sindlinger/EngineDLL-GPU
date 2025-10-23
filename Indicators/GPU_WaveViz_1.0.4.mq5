//+------------------------------------------------------------------+
//| GPU_WaveViz 1.0.4 (Service Edition)                             |
//| Visualiza dados publicados pelo EA GPU_EngineHub utilizando     |
//| a arquitetura GPU Engine Service (v2).                          |
//+------------------------------------------------------------------+
#property copyright "2025"
#property link      "WaveSpec GPU"
#property version   "1.004"
#property indicator_separate_window
#property indicator_buffers 20
#property indicator_plots   14

#property indicator_label1  "Wave"
#property indicator_type1   DRAW_LINE
#property indicator_color1  clrGold
#property indicator_width1  2

#property indicator_label2  "Preview"
#property indicator_type2   DRAW_LINE
#property indicator_color2  clrDarkGoldenrod
#property indicator_style2  STYLE_DOT

#property indicator_label3  "Noise"
#property indicator_type3   DRAW_LINE
#property indicator_color3  clrSilver

#property indicator_label4  "Cycle1"
#property indicator_type4   DRAW_LINE
#property indicator_color4  clrDodgerBlue

#property indicator_label5  "Cycle2"
#property indicator_type5   DRAW_LINE
#property indicator_color5  clrDeepSkyBlue

#property indicator_label6  "Cycle3"
#property indicator_type6   DRAW_LINE
#property indicator_color6  clrAqua

#property indicator_label7  "Cycle4"
#property indicator_type7   DRAW_LINE
#property indicator_color7  clrSpringGreen

#property indicator_label8  "Cycle5"
#property indicator_type8   DRAW_LINE
#property indicator_color8  clrGreen

#property indicator_label9  "Cycle6"
#property indicator_type9   DRAW_LINE
#property indicator_color9  clrYellowGreen

#property indicator_label10 "Cycle7"
#property indicator_type10  DRAW_LINE
#property indicator_color10 clrOrange

#property indicator_label11 "Cycle8"
#property indicator_type11  DRAW_LINE
#property indicator_color11 clrTomato

#property indicator_label12 "Cycle9"
#property indicator_type12  DRAW_LINE
#property indicator_color12 clrCrimson

#property indicator_label13 "Cycle10"
#property indicator_type13  DRAW_LINE
#property indicator_color13 clrViolet

#property indicator_label14 "Cycle11"
#property indicator_type14  DRAW_LINE
#property indicator_color14 clrMagenta

#include <GPU/GPU_Shared.mqh>

input bool InpShowPreview = true;
input bool InpShowNoise   = true;
input int  InpMaxCycles   = 12;
input bool InpShowHud     = true;

// buffers principais
static double g_wave[];
static double g_preview[];
static double g_noise[];
static double g_cycles[11][];
static double g_countdown[];
static double g_power[];
static double g_velocity[];

//+------------------------------------------------------------------+
int OnInit()
{
   SetIndexBuffer(0, g_wave,     INDICATOR_DATA);
   SetIndexBuffer(1, g_preview,  INDICATOR_DATA);
   SetIndexBuffer(2, g_noise,    INDICATOR_DATA);

   for(int i=0; i<11; ++i)
   {
      SetIndexBuffer(3+i, g_cycles[i], INDICATOR_DATA);
      ArraySetAsSeries(g_cycles[i], true);
   }

   SetIndexBuffer(14, g_countdown, INDICATOR_CALCULATIONS);
   SetIndexBuffer(15, g_power,     INDICATOR_CALCULATIONS);
   SetIndexBuffer(16, g_velocity,  INDICATOR_CALCULATIONS);

   ArraySetAsSeries(g_wave,     true);
   ArraySetAsSeries(g_preview,  true);
   ArraySetAsSeries(g_noise,    true);
   ArraySetAsSeries(g_countdown,true);
   ArraySetAsSeries(g_power,    true);
   ArraySetAsSeries(g_velocity, true);

   IndicatorSetString(INDICATOR_SHORTNAME, "GPU WaveViz 1.0.4");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void ResetBuffers(const int rates_total)
{
   ArrayInitialize(g_wave,     EMPTY_VALUE);
   ArrayInitialize(g_preview,  EMPTY_VALUE);
   ArrayInitialize(g_noise,    EMPTY_VALUE);
   ArrayInitialize(g_countdown,EMPTY_VALUE);
   ArrayInitialize(g_power,    EMPTY_VALUE);
   ArrayInitialize(g_velocity, EMPTY_VALUE);
   for(int i=0; i<11; ++i)
      ArrayInitialize(g_cycles[i], EMPTY_VALUE);
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
   ResetBuffers(rates_total);

   const int frame_length = GPUShared::frame_length;
   const int frame_count  = GPUShared::frame_count;
   const int cycle_count  = MathMax(MathMin(InpMaxCycles, GPUShared::cycle_count), 0);

   if(frame_length <= 0 || frame_count <= 0 || rates_total <= 0)
      return rates_total;

   const int total_span = frame_length * frame_count;
   const int available  = MathMin(frame_length, rates_total);
   const int offset     = (frame_count - 1) * frame_length;

   bool has_plv = (ArraySize(GPUShared::plv_cycles) >= cycle_count);

   int selected_count = 0;
   int selected_indices[];
   if(cycle_count > 0)
   {
      ArrayResize(selected_indices, cycle_count);
      bool used[];
      ArrayResize(used, GPUShared::cycle_count);
      ArrayInitialize(used, false);
      for(int rank=0; rank<cycle_count; ++rank)
      {
         double best = -DBL_MAX;
         int best_idx = -1;
         for(int c=0; c<GPUShared::cycle_count; ++c)
         {
            if(used[c])
               continue;
            const double plv = has_plv ? GPUShared::plv_cycles[c] : (GPUShared::cycle_count-c);
            if(plv > best)
            {
               best = plv;
               best_idx = c;
            }
         }
         if(best_idx < 0)
            break;
         selected_indices[selected_count++] = best_idx;
         used[best_idx] = true;
      }
      ArrayResize(selected_indices, selected_count);
   }

   for(int i=0; i<available; ++i)
   {
      const int src = offset + i;
      g_wave[i] = GPUShared::wave[src];
      if(InpShowPreview)
         g_preview[i] = (ArraySize(GPUShared::preview) > src ? GPUShared::preview[src] : EMPTY_VALUE);
      if(InpShowNoise && ArraySize(GPUShared::noise) > src)
         g_noise[i] = GPUShared::noise[src];

      if(ArraySize(GPUShared::countdown) > src)
         g_countdown[i] = GPUShared::countdown[src];
      if(ArraySize(GPUShared::power) > src)
         g_power[i] = GPUShared::power[src];
      if(ArraySize(GPUShared::velocity) > src)
         g_velocity[i] = GPUShared::velocity[src];

      for(int rank=0; rank<selected_count && rank<11; ++rank)
      {
         const int cycle_idx = selected_indices[rank];
         const int base = cycle_idx * total_span;
         if(ArraySize(GPUShared::recon_all) >= base + src + 1)
            g_cycles[rank][i] = GPUShared::recon_all[base + src];
         else if(ArraySize(GPUShared::cycles) >= base + src + 1)
            g_cycles[rank][i] = GPUShared::cycles[base + src];
      }
   }

   string name = "GPU WaveViz 1.0.4";
   if(selected_count > 0)
   {
      const int idx = selected_indices[0];
      const double period = (ArraySize(GPUShared::cycle_periods) > idx ? GPUShared::cycle_periods[idx] : 0.0);
      const double plv = (has_plv ? GPUShared::plv_cycles[idx] : EMPTY_VALUE);
      name = StringFormat("WaveViz 1.0.4 | Dominante #%d T=%.1f PLV=%.3f", idx+1, period, plv);
   }
   IndicatorSetString(INDICATOR_SHORTNAME, name);

   if(InpShowHud)
   {
      Comment(StringFormat("GPU Engine Service | frames=%d len=%d | dominante=%d | PLV=%.3f | SNR=%.3f",\
              GPUShared::frame_count,
              GPUShared::frame_length,
              GPUShared::dominant_cycle+1,
              GPUShared::dominant_plv,
              GPUShared::dominant_snr));
   }
   else
   {
      Comment("");
   }

   return rates_total;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(InpShowHud)
      Comment("");
}

