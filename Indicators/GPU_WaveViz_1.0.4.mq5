//+------------------------------------------------------------------+
//|       CyclePhaseView_FollowFirst_v7.57.mq5                      |
//|   v7.56: BUFFERS ALTERNADOS + CONTAGEM REGRESSIVA               |
//|   Organiza??o: C1-ETA, C1-LEAK, C1-STATE, C1-SIG (alternados)   |
//|   ETAs com countdown: Decrementa a cada barra at? revers?o      |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025"
#property link      ""
#include <GPU/GPU_Shared.mqh>
#include <GPU/GPU_Engine.mqh>
#property version   "1.004"

#property description "v7.56: ALTERNATING BUFFERS + COUNTDOWN ETAs"
#property description "Buffers alternados por ciclo: C1[ETA,LEAK,STATE,SIG], C2[ETA,LEAK,STATE,SIG]..."
#property description "ETAs com contagem regressiva: Decrementa -1 a cada barra"
#property description "73 buffers DATA: 24 visual + 48 alternados + 1 confluence"

// NO-REPAINT POLICY: This indicator never rewrites historical bars
// and never reorders Dominant slots dynamically. Do NOT reintroduce
// any form of repaint or future-data usage in this file.
#property indicator_separate_window
// 85 BUFFERS: 24 visual + 48 alternados + 12 CALCULATIONS + 1 CONFLUENCE
#property indicator_buffers 85
#property indicator_plots   73  // 24 visuais + 48 alternados + 1 confluence

#import "GpuBridge.dll"
int  GpuSessionInit(int device_id);
void GpuSessionClose();
int  GpuConfigureWaveform(int length);
int  RunWaveformFft(double &values[], double &fft_real[], double &fft_imag[], int length);
int  RunWaveformIfft(double &fft_real[], double &fft_imag[], double &output[], int length);
#import

#define GPU_STATUS_OK 0
#define GPU_STATUS_ALREADY_INITIALIZED -2

bool g_gpu_waveform_session_initialized = false;
int  g_gpu_waveform_last_length = 0;

enum FFT_ZIGZAG_SERIES_MODE
  {
   ZIGZAG_CONTINUOUS = 0,   // Interpola entre extremos
   ZIGZAG_ALTERNATING = 1   // Mantém platôs topo/fundo
  };

enum FFT_ZIGZAG_SOURCE_MODE
  {
   ZIG_SOURCE_CURRENT = 0,
   ZIG_SOURCE_LOWER1  = 1,
   ZIG_SOURCE_LOWER2  = 2
  };

#define MAX_ZIG_HANDLES 3

ENUM_TIMEFRAMES g_zig_handle_tfs[MAX_ZIG_HANDLES] = {(ENUM_TIMEFRAMES)-1, (ENUM_TIMEFRAMES)-1, (ENUM_TIMEFRAMES)-1};
int             g_zig_handles[MAX_ZIG_HANDLES]    = {INVALID_HANDLE, INVALID_HANDLE, INVALID_HANDLE};

bool EnsureWaveformGpuConfigured(const int length)
{
    int status = GpuConfigureWaveform(length);
    if(status != GPU_STATUS_OK)
    {
        PrintFormat("[GPU] GpuConfigureWaveform failed: %d", status);
        return false;
    }
    g_gpu_waveform_last_length = length;
    return true;
}

ENUM_TIMEFRAMES ResolveTimeframe(const ENUM_TIMEFRAMES tf)
{
    if(tf == PERIOD_CURRENT)
        return (ENUM_TIMEFRAMES)_Period;
    return tf;
}

static const ENUM_TIMEFRAMES kTimeframeOrder[] =
{
    PERIOD_M1, PERIOD_M2, PERIOD_M3, PERIOD_M4, PERIOD_M5, PERIOD_M6,
    PERIOD_M10, PERIOD_M12, PERIOD_M15, PERIOD_M20, PERIOD_M30,
    PERIOD_H1, PERIOD_H2, PERIOD_H3, PERIOD_H4, PERIOD_H6, PERIOD_H8, PERIOD_H12,
    PERIOD_D1, PERIOD_W1, PERIOD_MN1
};

int FindTimeframeIndex(const ENUM_TIMEFRAMES tf)
{
    for(int i = 0; i < ArraySize(kTimeframeOrder); ++i)
    {
        if(kTimeframeOrder[i] == tf)
            return i;
    }
    return -1;
}

ENUM_TIMEFRAMES GetNthLowerTimeframe(ENUM_TIMEFRAMES base, int steps)
{
    int idx = FindTimeframeIndex(base);
    if(idx == -1)
        return base;

    int target = idx - steps;
    if(target < 0)
        target = 0;
    return kTimeframeOrder[target];
}

ENUM_TIMEFRAMES DetermineLowerTimeframe(const int steps, const ENUM_TIMEFRAMES custom)
{
    if(custom != PERIOD_CURRENT)
        return ResolveTimeframe(custom);
    return GetNthLowerTimeframe((ENUM_TIMEFRAMES)_Period, steps);
}

void ResetZigZagHandles()
{
    for(int i = 0; i < MAX_ZIG_HANDLES; ++i)
    {
        if(g_zig_handles[i] != INVALID_HANDLE)
        {
            IndicatorRelease(g_zig_handles[i]);
            g_zig_handles[i] = INVALID_HANDLE;
        }
        g_zig_handle_tfs[i] = (ENUM_TIMEFRAMES)-1;
    }
}

int FindZigZagHandleSlot(const ENUM_TIMEFRAMES tf)
{
    for(int i = 0; i < MAX_ZIG_HANDLES; ++i)
    {
        if(g_zig_handles[i] != INVALID_HANDLE && g_zig_handle_tfs[i] == tf)
            return i;
    }
    return -1;
}

bool EnsureZigZagHandleForTf(const ENUM_TIMEFRAMES tf)
{
    ENUM_TIMEFRAMES resolved = ResolveTimeframe(tf);
    if(FindZigZagHandleSlot(resolved) != -1)
        return true;

    int slot = -1;
    for(int i = 0; i < MAX_ZIG_HANDLES; ++i)
    {
        if(g_zig_handles[i] == INVALID_HANDLE)
        {
            slot = i;
            break;
        }
    }
    if(slot == -1)
    {
        slot = MAX_ZIG_HANDLES - 1;
        IndicatorRelease(g_zig_handles[slot]);
        g_zig_handles[slot] = INVALID_HANDLE;
    }

    ResetLastError();
    int handle = iCustom(_Symbol, resolved, "GPU_WaveViz/ZigZag", InpZigZagDepth, InpZigZagDeviation, InpZigZagBackstep);
    if(handle == INVALID_HANDLE)
    {
        int err = GetLastError();
        PrintFormat("GPU_WaveViz: falha ao inicializar ZigZag [%d] (erro %d)", (int)resolved, err);
        g_zig_handle_tfs[slot] = (ENUM_TIMEFRAMES)-1;
        return false;
    }

    g_zig_handles[slot] = handle;
    g_zig_handle_tfs[slot] = resolved;
    return true;
}

int GetZigZagHandleForTf(const ENUM_TIMEFRAMES tf)
{
    ENUM_TIMEFRAMES resolved = ResolveTimeframe(tf);
    int slot = FindZigZagHandleSlot(resolved);
    return (slot != -1) ? g_zig_handles[slot] : INVALID_HANDLE;
}

ENUM_TIMEFRAMES GetActiveZigZagTimeframe()
{
    switch(InpZigZagSource)
    {
        case ZIG_SOURCE_LOWER1: return DetermineLowerTimeframe(1, InpZigZagLowerTF1);
        case ZIG_SOURCE_LOWER2: return DetermineLowerTimeframe(2, InpZigZagLowerTF2);
        default:                return (ENUM_TIMEFRAMES)_Period;
    }
}

bool BuildZigZagPriceSeries(const int start_pos,
                            const double &high[],
                            const double &low[],
                            const datetime &time[],
                            const FFT_ZIGZAG_SERIES_MODE mode,
                            const ENUM_TIMEFRAMES source_tf)
{
    if(InpAppliedPrice != FFT_PRICE_ZIGZAG)
        return false;

    ENUM_TIMEFRAMES resolved_tf = ResolveTimeframe(source_tf);
    int handle = GetZigZagHandleForTf(resolved_tf);
    if(handle == INVALID_HANDLE)
        return false;

    int point_indices[];
    double point_values[];
    ArrayResize(point_indices, InpFFTWindow);
    ArrayResize(point_values, InpFFTWindow);
    int point_count = 0;

    if(resolved_tf == (ENUM_TIMEFRAMES)_Period)
    {
        ResetLastError();
        double zz_main[];
        double zz_high[];
        double zz_low[];
        ArrayResize(zz_main, InpFFTWindow);
        ArrayResize(zz_high, InpFFTWindow);
        ArrayResize(zz_low, InpFFTWindow);

        int copied_main = CopyBuffer(handle, 0, start_pos, InpFFTWindow, zz_main);
        int copied_high = CopyBuffer(handle, 1, start_pos, InpFFTWindow, zz_high);
        int copied_low  = CopyBuffer(handle, 2, start_pos, InpFFTWindow, zz_low);

        if(copied_main != InpFFTWindow || copied_high != InpFFTWindow || copied_low != InpFFTWindow)
        {
            int err = GetLastError();
            PrintFormat("GPU_WaveViz: CopyBuffer ZigZag falhou (copied=%d/%d/%d, esperado=%d, erro=%d)",
                        copied_main, copied_high, copied_low, InpFFTWindow, err);
            return false;
        }

        for(int j = 0; j < InpFFTWindow; ++j)
        {
            double value = zz_main[j];
            if(value == 0.0 || !MathIsValidNumber(value))
            {
                if(zz_high[j] != 0.0 && MathIsValidNumber(zz_high[j]))
                    value = zz_high[j];
                else if(zz_low[j] != 0.0 && MathIsValidNumber(zz_low[j]))
                    value = zz_low[j];
            }

            if(value != 0.0 && MathIsValidNumber(value))
            {
                point_indices[point_count] = j;
                point_values[point_count]  = value;
                ++point_count;
            }
        }
    }
    else
    {
        int required = InpFFTWindow;
        double zz_main[];
        double zz_high[];
        double zz_low[];
        ArrayResize(zz_main, required);
        ArrayResize(zz_high, required);
        ArrayResize(zz_low,  required);

        ResetLastError();
        int copied_main = CopyBuffer(handle, 0, 0, required, zz_main);
        int copied_high = CopyBuffer(handle, 1, 0, required, zz_high);
        int copied_low  = CopyBuffer(handle, 2, 0, required, zz_low);

        if(copied_main <= 0 || copied_high <= 0 || copied_low <= 0)
        {
            int err = GetLastError();
            PrintFormat("GPU_WaveViz: CopyBuffer ZigZag lower TF falhou (copied=%d/%d/%d, esperado=%d, erro=%d)",
                        copied_main, copied_high, copied_low, required, err);
            return false;
        }

        int effective = copied_main;
        if(copied_high < effective) effective = copied_high;
        if(copied_low  < effective) effective = copied_low;

        for(int idx = effective - 1; idx >= 0; --idx)
        {
            double value = zz_main[idx];
            if(value == 0.0 || !MathIsValidNumber(value))
            {
                if(idx < copied_high && zz_high[idx] != 0.0 && MathIsValidNumber(zz_high[idx]))
                    value = zz_high[idx];
                else if(idx < copied_low && zz_low[idx] != 0.0 && MathIsValidNumber(zz_low[idx]))
                    value = zz_low[idx];
            }

            if(value != 0.0 && MathIsValidNumber(value))
            {
                int mapped_index = (effective - 1) - idx;
                point_indices[point_count] = mapped_index;
                point_values[point_count]  = value;
                ++point_count;
            }
        }
    }

    if(point_count < 2)
        return false;

    int first_idx = point_indices[0];
    double first_val = point_values[0];
    for(int j = 0; j <= first_idx && j < InpFFTWindow; ++j)
        price_data[j] = first_val;

    if(mode == ZIGZAG_CONTINUOUS)
    {
        for(int p = 0; p < point_count - 1; ++p)
        {
            int start_idx = point_indices[p];
            int end_idx   = point_indices[p + 1];
            double start_val = point_values[p];
            double end_val   = point_values[p + 1];
            int span = end_idx - start_idx;

            if(span <= 0)
            {
                price_data[start_idx] = start_val;
                continue;
            }

            for(int offset = 0; offset <= span && (start_idx + offset) < InpFFTWindow; ++offset)
            {
                double t = (double)offset / (double)span;
                price_data[start_idx + offset] = start_val + (end_val - start_val) * t;
            }
        }
    }
    else // ZIGZAG_ALTERNATING
    {
        for(int p = 0; p < point_count - 1; ++p)
        {
            int start_idx = point_indices[p];
            int end_idx   = point_indices[p + 1];
            double plateau_val = point_values[p];

            if(end_idx < start_idx)
                continue;

            for(int idx = start_idx; idx <= end_idx && idx < InpFFTWindow; ++idx)
                price_data[idx] = plateau_val;
        }
    }

    int last_idx = point_indices[point_count - 1];
    double last_val = point_values[point_count - 1];
    for(int j = last_idx; j < InpFFTWindow; ++j)
        price_data[j] = last_val;

    return true;
}

// RGB helper e enum de paletas vêm do header compartilhado
#include "..\\..\\..\\Include\\zeroproxy\\PaletteDefinitions.mqh"

inline double Clamp01(const double value)
{
    if(value < 0.0)
        return 0.0;
    if(value > 1.0)
        return 1.0;
    return value;
}

inline double EncodeSRGB(const double linear)
{
    if(linear <= 0.0)
        return 0.0;
    if(linear >= 1.0)
        return 1.0;
    if(linear <= 0.0031308)
        return 12.92 * linear;
    return 1.055 * MathPow(linear, 1.0 / 2.4) - 0.055;
}

inline void WavelengthToLinearRGB(const double wavelength_nm, double &r, double &g, double &b)
{
    double w = wavelength_nm;
    double R = 0.0, G = 0.0, B = 0.0;

    if(w >= 380.0 && w < 440.0)
    {
        R = -(w - 440.0) / (440.0 - 380.0);
        G = 0.0;
        B = 1.0;
    }
    else if(w >= 440.0 && w < 490.0)
    {
        R = 0.0;
        G = (w - 440.0) / (490.0 - 440.0);
        B = 1.0;
    }
    else if(w >= 490.0 && w < 510.0)
    {
        R = 0.0;
        G = 1.0;
        B = -(w - 510.0) / (510.0 - 490.0);
    }
    else if(w >= 510.0 && w < 580.0)
    {
        R = (w - 510.0) / (580.0 - 510.0);
        G = 1.0;
        B = 0.0;
    }
    else if(w >= 580.0 && w < 645.0)
    {
        R = 1.0;
        G = -(w - 645.0) / (645.0 - 580.0);
        B = 0.0;
    }
    else if(w >= 645.0 && w <= 780.0)
    {
        R = 1.0;
        G = 0.0;
        B = 0.0;
    }

    double factor = 0.0;
    if(w >= 380.0 && w < 420.0)
        factor = 0.3 + 0.7 * (w - 380.0) / (420.0 - 380.0);
    else if(w >= 420.0 && w <= 700.0)
        factor = 1.0;
    else if(w > 700.0 && w <= 780.0)
        factor = 0.3 + 0.7 * (780.0 - w) / (780.0 - 700.0);

    r = Clamp01(R * factor);
    g = Clamp01(G * factor);
    b = Clamp01(B * factor);
}

inline color SpectralMixToColor(const double primary_nm, const double secondary_nm, const double primary_weight, const double secondary_weight)
{
    double w1 = MathMax(primary_weight, 0.0);
    double w2 = MathMax(secondary_weight, 0.0);

    double r1 = 0.0, g1 = 0.0, b1 = 0.0;
    double r2 = 0.0, g2 = 0.0, b2 = 0.0;

    if(w1 > 0.0)
        WavelengthToLinearRGB(primary_nm, r1, g1, b1);
    if(w2 > 0.0 && secondary_nm > 0.0)
        WavelengthToLinearRGB(secondary_nm, r2, g2, b2);

    double total = w1 + w2;
    if(total <= 0.0)
        total = 1.0;

    double r = (r1 * w1 + r2 * w2) / total;
    double g = (g1 * w1 + g2 * w2) / total;
    double b = (b1 * w1 + b2 * w2) / total;

    double sr = EncodeSRGB(r);
    double sg = EncodeSRGB(g);
    double sb = EncodeSRGB(b);

    return RGB((int)MathRound(sr * 255.0), (int)MathRound(sg * 255.0), (int)MathRound(sb * 255.0));
}

inline double AdjustChannel(const double channel, const double gamma, const double contrast, const double brightness)
{
    double value = channel;
    if(gamma > 0.0 && gamma != 1.0)
        value = MathPow(value, 1.0 / gamma);
    if(contrast != 1.0)
        value = (value - 0.5) * contrast + 0.5;
    if(brightness != 0.0)
        value += brightness;
    return Clamp01(value);
}

inline color ApplyPaletteAdjustments(const color base, const double gamma, const double contrast, const double brightness)
{
    double r = (double)(base & 0xFF) / 255.0;
    double g = (double)((base >> 8) & 0xFF) / 255.0;
    double b = (double)((base >> 16) & 0xFF) / 255.0;

    r = AdjustChannel(r, gamma, contrast, brightness);
    g = AdjustChannel(g, gamma, contrast, brightness);
    b = AdjustChannel(b, gamma, contrast, brightness);

    return RGB((int)MathRound(r * 255.0), (int)MathRound(g * 255.0), (int)MathRound(b * 255.0));
}

color default_palette[12];


//--- Plot 1 (Wave1)
#property indicator_label1  "Wave1"
#property indicator_type1   DRAW_LINE
#property indicator_color1  clrRed
#property indicator_style1  STYLE_SOLID
#property indicator_width1  1
//--- Plot 2 (Wave2)
#property indicator_label2  "Wave2"
#property indicator_type2   DRAW_LINE
#property indicator_color2  clrOrangeRed
#property indicator_style2  STYLE_SOLID
#property indicator_width2  1
//--- Plot 3 (Wave3)
#property indicator_label3  "Wave3"
#property indicator_type3   DRAW_LINE
#property indicator_color3  clrOrange
#property indicator_style3  STYLE_SOLID
#property indicator_width3  1
//--- Plot 4 (Wave4)
#property indicator_label4  "Wave4"
#property indicator_type4   DRAW_LINE
#property indicator_color4  clrGold
#property indicator_style4  STYLE_SOLID
#property indicator_width4  1
//--- Plot 5 (Wave5)
#property indicator_label5  "Wave5"
#property indicator_type5   DRAW_LINE
#property indicator_color5  clrYellow
#property indicator_style5  STYLE_SOLID
#property indicator_width5  1
//--- Plot 6 (Wave6)
#property indicator_label6  "Wave6"
#property indicator_type6   DRAW_LINE
#property indicator_color6  clrChartreuse
#property indicator_style6  STYLE_SOLID
#property indicator_width6  1
//--- Plot 7 (Wave7)
#property indicator_label7  "Wave7"
#property indicator_type7   DRAW_LINE
#property indicator_color7  clrLime
#property indicator_style7  STYLE_SOLID
#property indicator_width7  1
//--- Plot 8 (Wave8)
#property indicator_label8  "Wave8"
#property indicator_type8   DRAW_LINE
#property indicator_color8  clrSpringGreen
#property indicator_style8  STYLE_SOLID
#property indicator_width8  1
//--- Plot 9 (Wave9)
#property indicator_label9  "Wave9"
#property indicator_type9   DRAW_LINE
#property indicator_color9  clrAqua
#property indicator_style9  STYLE_SOLID
#property indicator_width9  1
//--- Plot 10 (Wave10)
#property indicator_label10  "Wave10"
#property indicator_type10   DRAW_LINE
#property indicator_color10  clrDodgerBlue
#property indicator_style10  STYLE_SOLID
#property indicator_width10  1
//--- Plot 11 (Wave11)
#property indicator_label11  "Wave11"
#property indicator_type11   DRAW_LINE
#property indicator_color11  clrBlueViolet
#property indicator_style11  STYLE_SOLID
#property indicator_width11  1
//--- Plot 12 (Wave12)
#property indicator_label12  "Wave12"
#property indicator_type12   DRAW_LINE
#property indicator_color12  clrMagenta
#property indicator_style12  STYLE_SOLID
#property indicator_width12  1

//--- Plot 13 (WavePeriod1)
#property indicator_label13  "WavePeriod1"
#property indicator_type13   DRAW_NONE
#property indicator_color13  clrGray
#property indicator_style13  STYLE_SOLID
#property indicator_width13  1
//--- Plot 14 (WavePeriod2)
#property indicator_label14  "WavePeriod2"
#property indicator_type14   DRAW_NONE
#property indicator_color14  clrGray
#property indicator_style14  STYLE_SOLID
#property indicator_width14  1
//--- Plot 15 (WavePeriod3)
#property indicator_label15  "WavePeriod3"
#property indicator_type15   DRAW_NONE
#property indicator_color15  clrGray
#property indicator_style15  STYLE_SOLID
#property indicator_width15  1
//--- Plot 16 (WavePeriod4)
#property indicator_label16  "WavePeriod4"
#property indicator_type16   DRAW_NONE
#property indicator_color16  clrGray
#property indicator_style16  STYLE_SOLID
#property indicator_width16  1
//--- Plot 17 (WavePeriod5)
#property indicator_label17  "WavePeriod5"
#property indicator_type17   DRAW_NONE
#property indicator_color17  clrGray
#property indicator_style17  STYLE_SOLID
#property indicator_width17  1
//--- Plot 18 (WavePeriod6)
#property indicator_label18  "WavePeriod6"
#property indicator_type18   DRAW_NONE
#property indicator_color18  clrGray
#property indicator_style18  STYLE_SOLID
#property indicator_width18  1
//--- Plot 19 (WavePeriod7)
#property indicator_label19  "WavePeriod7"
#property indicator_type19   DRAW_NONE
#property indicator_color19  clrGray
#property indicator_style19  STYLE_SOLID
#property indicator_width19  1
//--- Plot 20 (WavePeriod8)
#property indicator_label20  "WavePeriod8"
#property indicator_type20   DRAW_NONE
#property indicator_color20  clrGray
#property indicator_style20  STYLE_SOLID
#property indicator_width20  1
//--- Plot 21 (WavePeriod9)
#property indicator_label21  "WavePeriod9"
#property indicator_type21   DRAW_NONE
#property indicator_color21  clrGray
#property indicator_style21  STYLE_SOLID
#property indicator_width21  1
//--- Plot 22 (WavePeriod10)
#property indicator_label22  "WavePeriod10"
#property indicator_type22   DRAW_NONE
#property indicator_color22  clrGray
#property indicator_style22  STYLE_SOLID
#property indicator_width22  1
//--- Plot 23 (WavePeriod11)
#property indicator_label23  "WavePeriod11"
#property indicator_type23   DRAW_NONE
#property indicator_color23  clrGray
#property indicator_style23  STYLE_SOLID
#property indicator_width23  1
//--- Plot 24 (WavePeriod12)
#property indicator_label24  "WavePeriod12"
#property indicator_type24   DRAW_NONE
#property indicator_color24  clrGray
#property indicator_style24  STYLE_SOLID
#property indicator_width24  1
// Plot 73 (Confluence Lot Multiplier)
#property indicator_label73  "SIG-CONF"
#property indicator_type73   DRAW_NONE

//--- DEPRECATED: Inputs de Per?odos dos Ciclos (N?O S?O MAIS USADOS!)
// ATEN??O: Estes valores eram OFFSETS VISUAIS, n?o per?odos reais!
// Os per?odos reais agora v?m 100% da FFT (detec??o autom?tica)
// Mantidos aqui apenas para compatibilidade com configura??es antigas
input int                InpPeriodCycle1 = 5;      // [DEPRECATED] Offset Visual Ciclo 1
input int                InpPeriodCycle2 = 10;     // [DEPRECATED] Offset Visual Ciclo 2
input int                InpPeriodCycle3 = 13;     // [DEPRECATED] Offset Visual Ciclo 3
input int                InpPeriodCycle4 = 17;     // [DEPRECATED] Offset Visual Ciclo 4
input int                InpPeriodCycle5 = 19;     // [DEPRECATED] Offset Visual Ciclo 5
input int                InpPeriodCycle6 = 26;     // [DEPRECATED] Offset Visual Ciclo 6
input int                InpPeriodCycle7 = 39;     // [DEPRECATED] Offset Visual Ciclo 7
input int                InpPeriodCycle8 = 52;     // [DEPRECATED] Offset Visual Ciclo 8

//--- Inputs do C?lculo de Ciclo (FFT)
input int  InpFFTWindow   = 8000;  // Janela da FFT (64, 128, 256)
input int  InpMinPeriod   = 18;    // Per?odo m?nimo do ciclo a detectar
input int  InpMaxPeriod   = 52;    // Per?odo m?ximo do ciclo a detectar
input int  InpTrendPeriod = 1024;  // Per?odo do filtro de tend?ncia (maior que InpMaxPeriod)
input double InpBandwidth = 0.5;   // Largura da banda do filtro (0.05-0.3)

enum FFT_APPLIED_PRICE_SOURCE
  {
   FFT_PRICE_CLOSE    = PRICE_CLOSE,
   FFT_PRICE_OPEN     = PRICE_OPEN,
   FFT_PRICE_HIGH     = PRICE_HIGH,
   FFT_PRICE_LOW      = PRICE_LOW,
   FFT_PRICE_MEDIAN   = PRICE_MEDIAN,
   FFT_PRICE_TYPICAL  = PRICE_TYPICAL,
   FFT_PRICE_WEIGHTED = PRICE_WEIGHTED,
   FFT_PRICE_ZIGZAG   = 1000
  };
input FFT_APPLIED_PRICE_SOURCE InpAppliedPrice = FFT_PRICE_CLOSE;  // Pre?o a ser aplicado
input int InpZigZagDepth    = 12;  // Profundidade ZigZag (usado quando InpAppliedPrice=FFT_PRICE_ZIGZAG)
input int InpZigZagDeviation= 5;   // Desvio ZigZag
input int InpZigZagBackstep = 3;   // Backstep ZigZag
input FFT_ZIGZAG_SOURCE_MODE InpZigZagSource = ZIG_SOURCE_LOWER2;  // Timeframe do ZigZag utilizado
input ENUM_TIMEFRAMES        InpZigZagLowerTF1 = PERIOD_CURRENT;   // Timeframe ZigZag alternativo 1
input ENUM_TIMEFRAMES        InpZigZagLowerTF2 = PERIOD_CURRENT;   // Timeframe ZigZag alternativo 2
input FFT_ZIGZAG_SERIES_MODE InpZigZagSeriesMode = ZIGZAG_ALTERNATING; // Modo de constru??o da s?rie ZigZag
input int InpHistoryChunk   = 1000;     // Barras historicas processadas por chamada
input int InpHistoryMaxBars = 5000;   // Limite de barras do histórico (0 = todo)

//--- Windowing Function para reduzir Spectral Leakage
enum WINDOW_TYPE {
    WINDOW_NONE = 0,      // Sem janela (Rectangular)
    WINDOW_HANN = 1,      // Hann (bom balan?o)
    WINDOW_HAMMING = 2,   // Hamming (menos leakage)
    WINDOW_BLACKMAN = 3,  // Blackman (melhor, mas mais lento)
    WINDOW_BARTLETT = 4   // Bartlett (Triangular)
};
input WINDOW_TYPE InpWindowType = WINDOW_BLACKMAN;  // Tipo de janela FFT

enum PHASE_TYPE { PHASE_NONE=0, PHASE_INFRA=1, PHASE_SUPRA=2 };

// ETA calculation mode (combobox input)
enum ETA_MODE
{
    ETA_PHASE_NEXT_EXTREMUM = 0,  // Estimate by instantaneous phase to next extremum
    ETA_REALFFT = 1               // Estimate by FFT group delay at dominant bin
};

input ETA_MODE InpETAMode = ETA_PHASE_NEXT_EXTREMUM;  // ETA calculation method

//--- Inputs de Detec??o de Sinal e Visualiza??o
input bool   InpShowETALines      = true;  // Mostrar linhas verticais de proje??o ETA
input bool   InpShowAllCycleETAs  = false; // Mostrar ETAs de todos os ciclos
input bool   InpShowETALabels     = true;  // Mostrar ETA atual ao lado de cada linha
input double InpBaseTop           = 75.0; // N?vel da linha C1
input double InpBaseStep          = 10.0; // Decremento por ciclo (C2=C1-10, ...)
//--- Inputs de Painel
input bool   InpShowPanel = true;
input int    InpPanelCorner = CORNER_LEFT_UPPER;
input int    InpPanelX = 10;
input int    InpPanelY = 25;

//--- Inputs de Proje??o Futura (Ichimoku Style)
input bool   InpShowFutureProjection = true;  // Mostrar proje??o futura
input int    InpProjectionBars = 26;          // N?mero de barras futuras (como Ichimoku)
input int    InpProjectionTransparency = 128; // Transparencia da projecao (0-255)
//--- Sele??o de visibilidade das waves
input bool   InpShowWave1  = true;
input bool   InpShowWave2  = true;
input bool   InpShowWave3  = true;
input bool   InpShowWave4  = true;
input bool   InpShowWave5  = true;
input bool   InpShowWave6  = true;
input bool   InpShowWave7  = true;
input bool   InpShowWave8  = true;
input bool   InpShowWave9  = true;
input bool   InpShowWave10 = true;
input bool   InpShowWave11 = true;
input bool   InpShowWave12 = true;
//--- Buffers de Plotagem (cores das Waves 1..12)
double ColorBuffer1[],  ColorBuffer2[],  ColorBuffer3[],  ColorBuffer4[];
double ColorBuffer5[],  ColorBuffer6[],  ColorBuffer7[],  ColorBuffer8[];
double ColorBuffer9[],  ColorBuffer10[], ColorBuffer11[], ColorBuffer12[]; // >0.5 = bullish

//--- Buffers de C?lculo (Waveforms 1..12)
double WaveBuffer1[],  WaveBuffer2[],  WaveBuffer3[],  WaveBuffer4[];
double WaveBuffer5[],  WaveBuffer6[],  WaveBuffer7[],  WaveBuffer8[];
double WaveBuffer9[],  WaveBuffer10[], WaveBuffer11[], WaveBuffer12[];

//--- Buffers informativos de período (WavePeriod 1..12)
double WavePeriodBuffer1[],  WavePeriodBuffer2[],  WavePeriodBuffer3[],  WavePeriodBuffer4[];
double WavePeriodBuffer5[],  WavePeriodBuffer6[],  WavePeriodBuffer7[],  WavePeriodBuffer8[];
double WavePeriodBuffer9[],  WavePeriodBuffer10[], WavePeriodBuffer11[], WavePeriodBuffer12[];

//--- Buffers de ETA ajustada (Wave 1..12 exibidas)
double EtaCycle1[],   EtaCycle2[],   EtaCycle3[],   EtaCycle4[];
double EtaCycle5[],   EtaCycle6[],   EtaCycle7[],   EtaCycle8[];
double EtaCycle9[],   EtaCycle10[],  EtaCycle11[],  EtaCycle12[];

//--- Buffers de ETA bruta (Wave 1..12 - l?gica interna)
double EtaRawCycle1[],  EtaRawCycle2[],  EtaRawCycle3[],  EtaRawCycle4[];
double EtaRawCycle5[],  EtaRawCycle6[],  EtaRawCycle7[],  EtaRawCycle8[];
double EtaRawCycle9[],  EtaRawCycle10[], EtaRawCycle11[], EtaRawCycle12[];

//--- Buffers de ETA LEAKAGE (Wave 1..12 - intrus?es detectadas)
double LeakETA1[],  LeakETA2[],  LeakETA3[],  LeakETA4[];
double LeakETA5[],  LeakETA6[],  LeakETA7[],  LeakETA8[];
double LeakETA9[],  LeakETA10[], LeakETA11[], LeakETA12[];

//--- Buffers FOLLOW FIRST (Wave 1..12 - sinais discretos)
// Valores: +100 (entrada compra), -100 (entrada venda), ±60 (pr?-sinal), 0 (inativo)
double SigBuffer1[],  SigBuffer2[],  SigBuffer3[],  SigBuffer4[];
double SigBuffer5[],  SigBuffer6[],  SigBuffer7[],  SigBuffer8[];
double SigBuffer9[],  SigBuffer10[], SigBuffer11[], SigBuffer12[];
double SigConfluence[]; // +mult for buy confluence, -mult for sell, 0 none

//--- Controle de cores/visibilidade das waves
bool  g_wave_visible[12];
color g_wave_colors[12];

//--- Vari?veis globais
double fft_real[], fft_imag[], price_data[], spectrum[];
double detrended_data[], trend_data[];

//--- Scientific FFT Phase Analysis (v7.51 - NEW)
double fft_phase[];           // Array de fases dos coeficientes FFT
double fft_unwrapped_phase[]; // Fase unwrapped para continuidade
double fft_group_delay[];     // Group delay calculado da fase
int g_dominant_indices[12];   // ?ndices FFT dos 12 ciclos dominantes

//--- Estrutura para ajudar a ordenar os ciclos
struct CycleInfo { int index; double power; };
double g_dominant_periods[12]; // Armazena os per?odos dominantes para cada barra (12 ciclos)

//+------------------------------------------------------------------+
//| PERSISTENT PERIOD TRACKING SYSTEM (v7.52 - NEW)                 |
//| Rastreamento por PER?ODO (n?o por posi??o) para ETA est?vel     |
//+------------------------------------------------------------------+
struct PeriodTracker {
    double   period;              // Per?odo em barras (ex: 18.5, 25.3)
    int      fft_index;           // ?ndice FFT correspondente
    double   eta;                 // ETA atual (com sinal: +bullish, -bearish)
    bool     is_active;           // Se foi detectado na ?ltima FFT
    int      bars_inactive;       // Quantas barras consecutivas est? inativo
    datetime last_seen;           // Timestamp da ?ltima detec??o
    double   power;               // Poder espectral (magnitude FFT)

    // Hist?rico de fase assim?trica (vinculado ao per?odo)
    int      bullish_durations[5];   // ?ltimas 5 dura??es bullish
    int      bearish_durations[5];   // ?ltimas 5 dura??es bearish
    int      phase_change_count;     // Contador de mudan?as de fase
};

PeriodTracker g_period_trackers[];  // Array din?mico de trackers
int g_tracker_count = 0;             // Quantidade de trackers ativos

// Configura??es do sistema de tracking
input double InpTrackerTolerance = 5.0;  // Toler?ncia de matching (% diferen?a)
input int    InpMaxInactiveBars = 3;     // M?ximo de barras inativas antes de remover

//--- Arrays para ETAs individuais de cada ciclo (para compatibilidade)
double g_cycle_etas[12];        // ETA atual de cada ciclo (countdown) - 12 ciclos
double g_cycle_periods[12];     // Per?odo de cada ciclo - 12 ciclos
int    g_cycle_start_bar[12];   // Barra onde cada ciclo come?ou - 12 ciclos
bool   g_cycle_active[12];      // Se o ciclo estÃ¡ ativo - 12 ciclos
bool   g_reset_state_cache = false;  // Sinaliza reset dos estados prÃ©vios

//--- Asymmetric ETA Tracking System (v7.49 - Adaptive Phase Duration Learning)
// Stores last 5 phase durations separately for bullish/bearish phases
// [cycle_index][duration_history_index]
int g_bullish_phase_durations[12][5];   // Last 5 bullish phase durations per cycle
int g_bearish_phase_durations[12][5];   // Last 5 bearish phase durations per cycle
int g_phase_change_count[12];            // Debug: Count phase changes per cycle
double g_phase_duration_estimate[12][2];  // Cached expected durations [bull, bear] por ciclo

//--- ZigZag support (GPU_WaveViz mode)



//| STATE CHANGE TRACKING (v7.54 - NEW)                             |
//+------------------------------------------------------------------+
struct PhaseTransition {
    datetime time;           // Quando ocorreu a mudan?a
    int      bar_index;      // ?ndice da barra
    double   old_state;      // Estado anterior (-1, 0, +1)
    double   new_state;      // Novo estado
    double   period;         // Per?odo do ciclo naquele momento
    double   eta_at_change;  // ETA no momento da mudan?a
};

PhaseTransition g_last_transitions[12];  // ?ltima transi??o de cada ciclo
int g_csv_last_bar = -1;                 // ?ltima barra exportada para CSV
int g_file_handle = INVALID_HANDLE;      // Handle do arquivo CSV

//+------------------------------------------------------------------+
//| LEAKAGE TRACKING SYSTEM (v7.53 - NEW)                           |
//| Detecta e rastreia intrus?es tempor?rias de frequ?ncias vazadas |
//+------------------------------------------------------------------+
struct CycleState {
    int      main_tracker_idx;     // ?ndice do tracker principal para este ciclo
    int      leak_tracker_idx;     // ?ndice do tracker intruso (-1 se n?o h?)
    double   main_eta_continuous;  // ETA cont?nuo do principal (n?o pausa)
    int      leak_bars_active;     // Quantas barras o leak est? ativo
    bool     is_leak_active;       // Flag: intrus?o detectada?
    datetime leak_start_time;      // Quando a intrus?o come?ou
};

CycleState g_cycle_states[12];  // Estado de cada um dos 12 ciclos

// Mapeamento estável de tracker->slot (para evitar "repaint" visual)
int g_slot_tracker_idx[12];

// --- New auxiliary leakage tracking (independent of old plotting) ---
int g_aux_leak_tracker_idx[12];   // leak tracker currently assigned per cycle (-1 if none)
int g_aux_leak_bars_active[12];   // consecutive bars leak has been active per cycle
int g_aux_leak_gate_state[12];    // gate by main state: -1,0,+1 (block new leak until state change)

// --- Continuous ETA tracking in seconds (to enforce monotonic countdown)
double g_last_eta_seconds[12];

// Configura??es de detec??o de leakage
input double InpLeakPeriodRatio = 0.30;   // Leak deve ter per?odo < X% do principal
input int    InpLeakMinBars     = 2;      // M?nimo de barras para considerar leak
input int    InpLeakMaxBars     = 8;      // M?ximo de barras antes de remover leak
input double InpLeakPowerRatio  = 0.70;   // Leak deve ter power >= X% do principal


//+------------------------------------------------------------------+
//| STATE MAPPING CONFIGURATION (v7.54)                             |
//+------------------------------------------------------------------+
input group "=== STATE MAPPING & EXPORT ==="
input bool   InpShowStateGrid    = true;   // Mostrar grid visual de estados
input bool   InpExportToCSV      = false;  // Exportar hist?rico para CSV
input string InpCSVFilename      = "CycleStates.csv";  // Nome do arquivo CSV
input int    InpCSVUpdateBars    = 10;     // Atualizar CSV a cada X barras (0=disabled)

//+------------------------------------------------------------------+
//| FOLLOW THE FIRST CONFIGURATION (v7.55 - NEW)                    |
//+------------------------------------------------------------------+
input group "=== FOLLOW THE FIRST ==="
input bool   InpEnableFollowFirst = true;   // Ativar sistema FollowFirst
input double InpMinPeriodToFollow = 15.0;   // Per?odo m?nimo para seguir (filtro)
input double InpMaxPeriodToFollow = 100.0;  // Per?odo m?ximo para seguir
input bool   InpShowFFPanel       = true;   // Mostrar painel FollowFirst
input int    InpExitBarsBeforeEnd = 3;      // Sair X barras antes do fim do ciclo
input int    InpEntryBarsBeforeEnd = 0;     // Emitir sinal X barras antes do fim da fase (0 = na virada)
// Treino: quantas mudan?as de fase cada ciclo precisa antes de habilitar sinais
input bool   InpFFAllowMultipleSignals = true; // Permitir m?ltiplos pulsos SIG mesmo em posi??o
input bool   InpSIGIgnoreSameDirection = true;  // Ignorar mesma dire??o em barras subsequentes at? ocorrer dire??o oposta
input double InpConfluencePercent      = 80.0;  // % de ciclos virando na mesma barra para ativar conflu?ncia
input int    InpConfluenceLotMult      = 3;     // Multiplicador de lote quando h? conflu?ncia (sinalizado em SIG-CONF)

// Vari?veis globais FollowFirst
enum FFMode {
    FF_WAITING_PEAK,    // Esperando PRIMEIRO PICO (verde)
    FF_WAITING_VALLEY   // Esperando PRIMEIRO FUNDO (vermelho)
};

struct FollowFirstState {
    FFMode   mode;                   // Modo atual: esperando pico ou fundo
    int      active_cycle;           // Qual ciclo est? sendo seguido (-1 = nenhum)
    double   active_period;          // Per?odo do ciclo ativo
    double   active_eta_start;       // ETA quando entrou
    datetime entry_time;             // Quando entrou
    int      entry_bar;              // Barra de entrada
    int      bars_in_position;       // Quantas barras est? na posi??o
    bool     peak_found;             // Flag: j? encontrou pico neste ciclo
    bool     valley_found;           // Flag: j? encontrou fundo neste ciclo
};

FollowFirstState g_ff_state;
// Controle de repeti??o por ciclo
int g_sig_last_dir[12];   // 0=nenhum, +1=compra, -1=venda (por ciclo)
int g_sig_last_bar[12];   // ?ltima barra sinalizada (por ciclo)

// Op??es de visualiza??o de marcadores das viradas
input bool   InpShowSIGSymbols    = true;   // Desenhar setas nas viradas
input int    InpSIGMaxMarkers     = 200;    // M?ximo de marcadores de virada no gr?fico

//+------------------------------------------------------------------+
//| Fun??o de detec??o de sinal profissional                        |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Windowing Functions para reduzir Spectral Leakage               |
//+------------------------------------------------------------------+

// Janela de Hann (Hanning) - Bom balan?o entre resolu??o e leakage
void ApplyHannWindow(double &data[], int n) {
    for(int i = 0; i < n; i++) {
        double window = 0.5 * (1.0 - cos(2.0 * M_PI * i / (n - 1)));
        data[i] *= window;
    }
}

// Janela de Hamming - Melhor supress?o de leakage que Hann
void ApplyHammingWindow(double &data[], int n) {
    for(int i = 0; i < n; i++) {
        double window = 0.54 - 0.46 * cos(2.0 * M_PI * i / (n - 1));
        data[i] *= window;
    }
}

// Janela de Blackman - Melhor supress?o, mas resolu??o menor
void ApplyBlackmanWindow(double &data[], int n) {
    for(int i = 0; i < n; i++) {
        double window = 0.42 - 0.5 * cos(2.0 * M_PI * i / (n - 1))
                           + 0.08 * cos(4.0 * M_PI * i / (n - 1));
        data[i] *= window;
    }
}

// Janela de Bartlett (Triangular)
void ApplyBartlettWindow(double &data[], int n) {
    for(int i = 0; i < n; i++) {
        double window = 1.0 - fabs((2.0 * i - n + 1) / (n - 1));
        data[i] *= window;
    }
}

// Aplicar janela selecionada
void ApplyWindow(double &data[], int n, WINDOW_TYPE window_type) {
    switch(window_type) {
        case WINDOW_NONE:
            // Sem janela (Rectangular) - n?o faz nada
            break;
        case WINDOW_HANN:
            ApplyHannWindow(data, n);
            break;
        case WINDOW_HAMMING:
            ApplyHammingWindow(data, n);
            break;
        case WINDOW_BLACKMAN:
            ApplyBlackmanWindow(data, n);
            break;
        case WINDOW_BARTLETT:
            ApplyBartlettWindow(data, n);
            break;
    }
}

//+------------------------------------------------------------------+
void FourierTransformManual(const double &data[], int n)
{
   if(n <= 1) return;
   double temp_data[];
   ArrayCopy(temp_data, data, 0, 0, n);
   for(int i = 1, j = 0; i < n; i++)
     {
      int bit = n >> 1;
      for(; (j & bit) != 0; bit >>= 1) j ^= bit;
      j ^= bit;
      if(i < j) { double temp = temp_data[i]; temp_data[i] = temp_data[j]; temp_data[j] = temp; }
     }
   ArrayCopy(fft_real, temp_data, 0, 0, n);
   ArrayInitialize(fft_imag, 0.0);
   for(int len = 2; len <= n; len <<= 1)
     {
      double ang = -2 * M_PI / len;
      double wlen_real = cos(ang), wlen_imag = sin(ang);
      for(int i = 0; i < n; i += len)
        {
         double w_real = 1.0, w_imag = 0.0;
         for(int j = 0; j < len / 2; j++)
           {
            int idx1 = i + j, idx2 = i + j + len / 2;
            double t_real = fft_real[idx2] * w_real - fft_imag[idx2] * w_imag;
            double t_imag = fft_real[idx2] * w_imag + fft_imag[idx2] * w_real;
            fft_real[idx2] = fft_real[idx1] - t_real;
            fft_imag[idx2] = fft_imag[idx1] - t_imag;
            fft_real[idx1] += t_real;
            fft_imag[idx1] += t_imag;
            double w_temp = w_real;
            w_real = w_real * wlen_real - w_imag * wlen_imag;
            w_imag = w_temp * wlen_imag + w_imag * wlen_real;
           }
        }
     }
}

//+------------------------------------------------------------------+
//| Calculate Phase from FFT Coefficients (Scientific Method)       |
//| phase = atan2(imaginary, real)                                   |
//+------------------------------------------------------------------+
void CalculateFFTPhase(int n)
{
    ArrayResize(fft_phase, n);

    for(int i = 0; i < n; i++)
    {
        // Calculate phase using atan2(imaginary, real)
        // atan2 retorna fase entre -p e +p
        fft_phase[i] = MathArctan2(fft_imag[i], fft_real[i]);
    }
}

//+------------------------------------------------------------------+
//| Unwrap Phase for Continuity (removes 2p jumps)                  |
//| Baseado no algoritmo numpy.unwrap                                |
//+------------------------------------------------------------------+
void UnwrapPhase(int n)
{
    ArrayResize(fft_unwrapped_phase, n);

    if(n == 0) return;

    // Primeira fase permanece inalterada
    fft_unwrapped_phase[0] = fft_phase[0];

    // Detectar e corrigir saltos de 2p
    for(int i = 1; i < n; i++)
    {
        double diff = fft_phase[i] - fft_phase[i-1];

        // Se diferen?a > p, subtrai 2p
        // Se diferen?a < -p, adiciona 2p
        double correction = 0;

        if(diff > M_PI)
            correction = -2.0 * M_PI;
        else if(diff < -M_PI)
            correction = 2.0 * M_PI;

        fft_unwrapped_phase[i] = fft_unwrapped_phase[i-1] + diff + correction;
    }
}

//+------------------------------------------------------------------+
//| Calculate Group Delay from Unwrapped Phase                      |
//| group_delay = -df/d? = -d(unwrapped_phase)/d(frequency)         |
//| Usa diferencia??o num?rica (gradiente)                          |
//+------------------------------------------------------------------+
void CalculateGroupDelay(int n, double sample_rate)
{
    ArrayResize(fft_group_delay, n);

    if(n < 3)
    {
        ArrayInitialize(fft_group_delay, 0.0);
        return;
    }

    // CORRE??O: Calcular gradiente diretamente em termos de ?NDICE FFT
    // N?o em frequ?ncia angular, pois isso causa valores muito grandes

    // Primeira amostra (forward difference)
    fft_group_delay[0] = -(fft_unwrapped_phase[1] - fft_unwrapped_phase[0]);

    // Amostras centrais (central difference - mais preciso)
    for(int i = 1; i < n - 1; i++)
    {
        fft_group_delay[i] = -(fft_unwrapped_phase[i+1] - fft_unwrapped_phase[i-1]) / 2.0;
    }

    // ?ltima amostra (backward difference)
    fft_group_delay[n-1] = -(fft_unwrapped_phase[n-1] - fft_unwrapped_phase[n-2]);

    // Normalizar para valores razo?veis (group delay em "amostras")
    // Limitar a valores entre -100 e +100 barras
    for(int i = 0; i < n; i++)
    {
        if(fft_group_delay[i] > 100.0) fft_group_delay[i] = 100.0;
        if(fft_group_delay[i] < -100.0) fft_group_delay[i] = -100.0;
    }
}

//+------------------------------------------------------------------+
//| Utility: derive seconds per bar (nominal timeframe aware)       |
//+------------------------------------------------------------------+
double GetSecondsPerBar(int bar_index, const datetime &time[])
{
    double nominal = (double)PeriodSeconds((ENUM_TIMEFRAMES)_Period);
    if(nominal <= 0.0)
        nominal = 60.0; // fallback to 1 minute

    if(bar_index <= 0)
        return nominal;

    double actual = (double)(time[bar_index] - time[bar_index - 1]);
    if(actual <= 0.0)
        return nominal;

    // Cap excessive gaps (weekends) to keep ETA stable
    double cap = nominal * 4.0;
    if(actual > cap)
        actual = nominal;

    return actual;
}

//+------------------------------------------------------------------+
//| Calculate Scientific ETA based on FFT Phase Analysis            |
//| Returns estimated seconds until phase reversal                  |
//+------------------------------------------------------------------+
double CalculateScientificETASeconds(int fft_index, double phase_length_seconds, double current_phase_progress, double seconds_per_bar)
{
    if(phase_length_seconds <= 0.0 || seconds_per_bar <= 0.0)
        return 0.0;

    if(fft_index < 0 || fft_index >= ArraySize(fft_group_delay))
        return 0.0;

    if(current_phase_progress < 0.0)
        current_phase_progress = 0.0;
    if(current_phase_progress > 1.0)
        current_phase_progress = 1.0;

    double eta_base = (1.0 - current_phase_progress) * phase_length_seconds;

    double group_delay_samples = fft_group_delay[fft_index];

    double group_delay_seconds = group_delay_samples * seconds_per_bar;

    double max_adjustment = phase_length_seconds * 0.25;
    if(group_delay_seconds > max_adjustment) group_delay_seconds = max_adjustment;
    if(group_delay_seconds < -max_adjustment) group_delay_seconds = -max_adjustment;

    double eta = eta_base + (group_delay_seconds * 0.25);

    if(eta < 0.0) eta = 0.0;
    double upper_bound = phase_length_seconds * 1.5;
    if(eta > upper_bound) eta = upper_bound;

    return eta;
}

//+------------------------------------------------------------------+
//| ETA via instantaneous phase to next extremum                    |
//| Uses quarter-period delay as 90° shift to get Q component       |
//| Returns ETA in seconds (converted from bar-domain measurements) |
//+------------------------------------------------------------------+
double ComputeETA_PhaseNextExtremum(int i, int c, const double &cycle_buffer[], double period_bars, double seconds_per_bar)
{
    if(period_bars <= 0.0 || seconds_per_bar <= 0.0) return 0.0;
    int q = (int)MathMax(1.0, MathRound(period_bars / 4.0));
    if(i - q < 0) return 0.0;

    double I = cycle_buffer[i];
    double Q = cycle_buffer[i - q]; // ~90° shift for near-monocomponent signal

    double phi = MathArctan2(Q, I);            // [-π, π]
    if(phi < 0.0) phi += 2.0 * M_PI;           // [0, 2π)

    double k = MathCeil(phi / M_PI);           // next multiple of π ahead
    double target = k * M_PI;
    double dphi = target - phi;                 // [0, π]

    // Convert phase to bars using ω = 2π/period
    double period_seconds = period_bars * seconds_per_bar;
    if(period_seconds <= 0.0) return 0.0;

    double eta_seconds = (dphi / (2.0 * M_PI)) * period_seconds;

    // Clamp to reasonable bounds
    if(eta_seconds < 0.0) eta_seconds = 0.0;
    double max_eta_seconds = period_seconds * 1.5;
    if(eta_seconds > max_eta_seconds) eta_seconds = max_eta_seconds;

    return eta_seconds;
}

//+------------------------------------------------------------------+
//| ETA via Real FFT Group Delay (seconds)                          |
//| Implements τ_g = -dφ/dω using unwrapped phase                  |
//| φ from FFT at dominant bin, ω_k = 2πk/N, Δω = 2π/N             |
//| Returns magnitude in seconds (sign applied elsewhere)           |
//+------------------------------------------------------------------+
double ComputeETA_RealFFT(int fft_index, double period_bars, int n, double seconds_per_bar)
{
    if(period_bars <= 0.0 || n <= 0 || seconds_per_bar <= 0.0) return 0.0;
    // Need a valid interior bin to compute central difference
    if(fft_index < 0) return 0.0;

    int phase_count = ArraySize(fft_unwrapped_phase);
    int max_n = (phase_count > 0) ? MathMin(n, phase_count) : n;
    if(fft_index >= max_n) return 0.0;

    double delta_omega = (max_n > 0) ? (2.0 * M_PI / (double)max_n) : 0.0;
    if(delta_omega == 0.0) return 0.0;

    // Numerical derivative of unwrapped phase along frequency bins
    double dphi = 0.0;
    if(fft_index > 0 && fft_index < max_n - 1)
        dphi = (fft_unwrapped_phase[fft_index + 1] - fft_unwrapped_phase[fft_index - 1]) / 2.0;
    else if(fft_index == 0 && max_n >= 2)
        dphi = (fft_unwrapped_phase[1] - fft_unwrapped_phase[0]);
    else if(fft_index == max_n - 1 && max_n >= 2)
        dphi = (fft_unwrapped_phase[max_n - 1] - fft_unwrapped_phase[max_n - 2]);
    else
        dphi = 0.0;

    // Group delay in samples (bars/sample rate = 1 bar per sample)
    double tau_g = -(dphi / delta_omega);

    // Clamp to reasonable bounds relative to this cycle's period (bars)
    double max_eta_bars = period_bars * 1.5;
    if(tau_g >  max_eta_bars) tau_g =  max_eta_bars;
    if(tau_g < -max_eta_bars) tau_g = -max_eta_bars;

    double eta_seconds = MathAbs(tau_g) * seconds_per_bar;

    double period_seconds = period_bars * seconds_per_bar;
    double max_eta_seconds = period_seconds * 1.5;
    if(eta_seconds > max_eta_seconds)
        eta_seconds = max_eta_seconds;

    return eta_seconds;
}

//+------------------------------------------------------------------+
//| PERSISTENT PERIOD TRACKING FUNCTIONS (v7.52)                    |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Verifica se dois per?odos s?o o mesmo (com toler?ncia)          |
//+------------------------------------------------------------------+
bool IsSamePeriod(double period1, double period2, double tolerance_pct)
{
    if(period1 <= 0 || period2 <= 0) return false;

    double diff = MathAbs(period1 - period2);
    double avg = (period1 + period2) / 2.0;
    double diff_pct = (diff / avg) * 100.0;

    return (diff_pct <= tolerance_pct);
}

//+------------------------------------------------------------------+
//| Encontra tracker mais pr?ximo ao per?odo (retorna ?ndice)       |
//| Retorna -1 se n?o encontrar match dentro da toler?ncia          |
//+------------------------------------------------------------------+
int FindClosestTracker(double period, double tolerance_pct)
{
    int best_match = -1;
    double smallest_diff = 999999;

    for(int i = 0; i < g_tracker_count; i++)
    {
        if(g_period_trackers[i].bars_inactive > 0) continue;  // S? considerar ativos

        double diff = MathAbs(g_period_trackers[i].period - period);

        // Verificar se est? dentro da toler?ncia
        if(IsSamePeriod(period, g_period_trackers[i].period, tolerance_pct))
        {
            if(diff < smallest_diff)
            {
                smallest_diff = diff;
                best_match = i;
            }
        }
    }

    return best_match;
}

//+------------------------------------------------------------------+
//| Atualiza tracker existente com novos dados da FFT               |
//+------------------------------------------------------------------+
void UpdateTracker(int tracker_idx, double period, int fft_index, double power, datetime current_time)
{
    if(tracker_idx < 0 || tracker_idx >= g_tracker_count) return;

    g_period_trackers[tracker_idx].period = period;        // Atualizar per?odo (pode ter pequena varia??o)
    g_period_trackers[tracker_idx].fft_index = fft_index;
    g_period_trackers[tracker_idx].power = power;
    g_period_trackers[tracker_idx].is_active = true;
    g_period_trackers[tracker_idx].bars_inactive = 0;      // Resetar contador
    g_period_trackers[tracker_idx].last_seen = current_time;
}

//+------------------------------------------------------------------+
//| Adiciona novo tracker ao array                                  |
//+------------------------------------------------------------------+
int AddTracker(double period, int fft_index, double power, datetime current_time)
{
    ArrayResize(g_period_trackers, g_tracker_count + 1);

    g_period_trackers[g_tracker_count].period = period;
    g_period_trackers[g_tracker_count].fft_index = fft_index;
    g_period_trackers[g_tracker_count].eta = period / 2.0;  // Inicializar ETA com metade do per?odo
    g_period_trackers[g_tracker_count].is_active = true;
    g_period_trackers[g_tracker_count].bars_inactive = 0;
    g_period_trackers[g_tracker_count].last_seen = current_time;
    g_period_trackers[g_tracker_count].power = power;
    g_period_trackers[g_tracker_count].phase_change_count = 0;

    // Inicializar hist?rico de fases
    for(int j = 0; j < 5; j++)
    {
        g_period_trackers[g_tracker_count].bullish_durations[j] = 0;
        g_period_trackers[g_tracker_count].bearish_durations[j] = 0;
    }

    g_tracker_count++;

    return (g_tracker_count - 1);  // Retorna ?ndice do novo tracker
}

//+------------------------------------------------------------------+
//| Marca trackers n?o detectados como inativos                     |
//| Remove trackers inativos por tempo demais                       |
//+------------------------------------------------------------------+
void DeactivateUnseenTrackers(datetime current_time)
{
    for(int i = g_tracker_count - 1; i >= 0; i--)  // Backward para permitir remo??o
    {
        if(!g_period_trackers[i].is_active)
        {
            g_period_trackers[i].bars_inactive++;

            // Remover se inativo por tempo demais
            if(g_period_trackers[i].bars_inactive >= InpMaxInactiveBars)
            {
                // Remover tracker (shift array)
                for(int j = i; j < g_tracker_count - 1; j++)
                {
                    g_period_trackers[j] = g_period_trackers[j + 1];
                }
                g_tracker_count--;
                ArrayResize(g_period_trackers, g_tracker_count);
            }
        }
    }

    // Resetar flag is_active para pr?xima itera??o
    for(int i = 0; i < g_tracker_count; i++)
    {
        g_period_trackers[i].is_active = false;
    }
}

//+------------------------------------------------------------------+
//| Retorna os 12 trackers mais fortes (por poder espectral)        |
//| Preenche arrays g_dominant_periods[] e g_dominant_indices[]     |
//+------------------------------------------------------------------+
void GetTop12Trackers()
{
    // Criar array tempor?rio com ?ndices ordenados por poder
    int sorted_indices[];
    ArrayResize(sorted_indices, g_tracker_count);

    for(int i = 0; i < g_tracker_count; i++)
        sorted_indices[i] = i;

    // Bubble sort por poder (decrescente)
    for(int i = 0; i < g_tracker_count - 1; i++)
    {
        for(int j = 0; j < g_tracker_count - i - 1; j++)
        {
            if(g_period_trackers[sorted_indices[j]].power <
               g_period_trackers[sorted_indices[j+1]].power)
            {
                int temp = sorted_indices[j];
                sorted_indices[j] = sorted_indices[j+1];
                sorted_indices[j+1] = temp;
            }
        }
    }

    // Preencher arrays de dominantes (top 12)
    ArrayInitialize(g_cycle_active, false);

    int count = MathMin(12, g_tracker_count);
    for(int i = 0; i < count; i++)
    {
        int tracker_idx = sorted_indices[i];
        g_dominant_periods[i] = g_period_trackers[tracker_idx].period;
        g_dominant_indices[i] = g_period_trackers[tracker_idx].fft_index;
        g_cycle_active[i] = true;

        // Inicializar CycleState para este ciclo
        g_cycle_states[i].main_tracker_idx = tracker_idx;
        g_cycle_states[i].leak_tracker_idx = -1;  // Nenhum leak por padr?o
        g_cycle_states[i].is_leak_active = false;
    }
}

//+------------------------------------------------------------------+
//| Atualiza slots Dominant 1..12 com mapeamento estável            |
//| Mantém tracker anterior no mesmo slot enquanto existir           |
//+------------------------------------------------------------------+
void UpdateStableSlots()
{
    // Liberar slots com trackers inválidos (sumiram do array)
    for(int s = 0; s < 12; s++)
    {
        int t = g_slot_tracker_idx[s];
        if(t < 0 || t >= g_tracker_count)
            g_slot_tracker_idx[s] = -1;
    }

    // Ordenar trackers por power (desc) para seleção dos livres
    int sorted[];
    ArrayResize(sorted, g_tracker_count);
    for(int i = 0; i < g_tracker_count; i++)
        sorted[i] = i;

    for(int i = 0; i < g_tracker_count - 1; i++)
    {
        for(int j = 0; j < g_tracker_count - i - 1; j++)
        {
            if(g_period_trackers[sorted[j]].power < g_period_trackers[sorted[j+1]].power)
            {
                int tmp = sorted[j];
                sorted[j] = sorted[j+1];
                sorted[j+1] = tmp;
            }
        }
    }

    int used[];
    ArrayResize(used, g_tracker_count);
    ArrayInitialize(used, 0);

    // Marcar e manter os trackers já mapeados em cada slot
    ArrayInitialize(g_cycle_active, false);
    for(int s = 0; s < 12; s++)
    {
        int t = g_slot_tracker_idx[s];
        if(t >= 0 && t < g_tracker_count)
        {
            used[t] = 1;
            g_cycle_active[s] = true;
            g_dominant_periods[s] = g_period_trackers[t].period;
            g_dominant_indices[s] = g_period_trackers[t].fft_index;
            g_cycle_states[s].main_tracker_idx = t;
        }
        else
        {
            g_cycle_states[s].main_tracker_idx = -1;
        }
    }

    // Preencher slots livres com os trackers mais fortes não usados
    for(int s = 0; s < 12; s++)
    {
        if(g_slot_tracker_idx[s] >= 0 && g_slot_tracker_idx[s] < g_tracker_count)
            continue; // já preenchido

        int chosen = -1;
        for(int k = 0; k < g_tracker_count; k++)
        {
            int idx = sorted[k];
            if(used[idx])
                continue;
            chosen = idx;
            break;
        }

        if(chosen != -1)
        {
            g_slot_tracker_idx[s] = chosen;
            used[chosen] = 1;
            g_cycle_active[s] = true;
            g_dominant_periods[s] = g_period_trackers[chosen].period;
            g_dominant_indices[s] = g_period_trackers[chosen].fft_index;
            g_cycle_states[s].main_tracker_idx = chosen;
        }
        else
        {
            g_slot_tracker_idx[s] = -1;
            g_cycle_active[s] = false;
            g_dominant_periods[s] = 0.0;
            g_dominant_indices[s] = 0;
            g_cycle_states[s].main_tracker_idx = -1;
        }
    }
}

//+------------------------------------------------------------------+
//| LEAKAGE DETECTION FUNCTIONS (v7.53)                             |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Verifica se um tracker ? intrus?o tempor?ria                    |
//| Crit?rios: per?odo < 30% do principal, power alto, recente      |
//+------------------------------------------------------------------+
bool IsLeakage(int candidate_idx, int main_tracker_idx)
{
    if(candidate_idx < 0 || candidate_idx >= g_tracker_count) return false;
    if(main_tracker_idx < 0 || main_tracker_idx >= g_tracker_count) return false;
    if(candidate_idx == main_tracker_idx) return false;  // N?o pode ser leak de si mesmo

    double main_period = g_period_trackers[main_tracker_idx].period;
    double candidate_period = g_period_trackers[candidate_idx].period;
    double main_power = g_period_trackers[main_tracker_idx].power;
    double candidate_power = g_period_trackers[candidate_idx].power;

    // 1. Per?odo muito menor que o principal (< X% do principal)
    if(candidate_period >= main_period * InpLeakPeriodRatio) return false;

    // 2. Power alto o suficiente (>= X% do principal)
    if(candidate_power < main_power * InpLeakPowerRatio) return false;

    // 3. Deve ser recente (poucos bars_inactive)
    if(g_period_trackers[candidate_idx].bars_inactive > InpLeakMinBars) return false;

    return true;
}

//+------------------------------------------------------------------+
//| Detecta e associa leakages aos ciclos principais               |
//| Chamado ap?s GetTop12Trackers()                                |
//+------------------------------------------------------------------+
void DetectLeakages()
{
    // Para cada um dos 12 ciclos principais
    for(int c = 0; c < 12; c++)
    {
        if(!g_cycle_active[c]) continue;

        int main_idx = g_cycle_states[c].main_tracker_idx;
        if(main_idx < 0 || main_idx >= g_tracker_count) continue;

        // Resetar leak anterior se passou do tempo m?ximo
        if(g_cycle_states[c].is_leak_active)
        {
            g_cycle_states[c].leak_bars_active++;

            if(g_cycle_states[c].leak_bars_active > InpLeakMaxBars)
            {
                // Leak expirou
                g_cycle_states[c].is_leak_active = false;
                g_cycle_states[c].leak_tracker_idx = -1;
                g_cycle_states[c].leak_bars_active = 0;
            }
        }

        // Procurar novos leaks entre TODOS os trackers
        int best_leak_idx = -1;
        double highest_leak_power = 0;

        for(int i = 0; i < g_tracker_count; i++)
        {
            if(g_period_trackers[i].bars_inactive > 0) continue;

            if(IsLeakage(i, main_idx))
            {
                // Pegar o leak com maior power
                if(g_period_trackers[i].power > highest_leak_power)
                {
                    highest_leak_power = g_period_trackers[i].power;
                    best_leak_idx = i;
                }
            }
        }

        // Se encontrou leak v?lido, ativar
        if(best_leak_idx >= 0)
        {
            if(!g_cycle_states[c].is_leak_active)
            {
                // Novo leak detectado
                g_cycle_states[c].is_leak_active = true;
                g_cycle_states[c].leak_tracker_idx = best_leak_idx;
                g_cycle_states[c].leak_bars_active = 1;
                g_cycle_states[c].leak_start_time = TimeCurrent();
            }
            else if(g_cycle_states[c].leak_tracker_idx == best_leak_idx)
            {
                // Leak continua ativo (mesmo tracker)
                // leak_bars_active j? foi incrementado acima
            }
            else
            {
                // Leak mudou para outro tracker - reiniciar
                g_cycle_states[c].leak_tracker_idx = best_leak_idx;
                g_cycle_states[c].leak_bars_active = 1;
                g_cycle_states[c].leak_start_time = TimeCurrent();
            }
        }
        else
        {
            // Nenhum leak encontrado - desativar se estava ativo
            if(g_cycle_states[c].is_leak_active)
            {
                g_cycle_states[c].is_leak_active = false;
                g_cycle_states[c].leak_tracker_idx = -1;
                g_cycle_states[c].leak_bars_active = 0;
            }
        }
    }
}

//+------------------------------------------------------------------+
//| FUN??ES AUXILIARES DE ACESSO A BUFFERS (Refatora??o v7.57)       |
//+------------------------------------------------------------------+

// --- Fun??es para SIG Buffers ---
void SetSigBufferValue(int cycle_idx, int bar_idx, double value)
{
    if(cycle_idx < 0 || cycle_idx >= 12 || bar_idx < 0) return;
    switch(cycle_idx)
    {
        case 0:  if(bar_idx < ArraySize(SigBuffer1))  SigBuffer1[bar_idx]  = value; break;
        case 1:  if(bar_idx < ArraySize(SigBuffer2))  SigBuffer2[bar_idx]  = value; break;
        case 2:  if(bar_idx < ArraySize(SigBuffer3))  SigBuffer3[bar_idx]  = value; break;
        case 3:  if(bar_idx < ArraySize(SigBuffer4))  SigBuffer4[bar_idx]  = value; break;
        case 4:  if(bar_idx < ArraySize(SigBuffer5))  SigBuffer5[bar_idx]  = value; break;
        case 5:  if(bar_idx < ArraySize(SigBuffer6))  SigBuffer6[bar_idx]  = value; break;
        case 6:  if(bar_idx < ArraySize(SigBuffer7))  SigBuffer7[bar_idx]  = value; break;
        case 7:  if(bar_idx < ArraySize(SigBuffer8))  SigBuffer8[bar_idx]  = value; break;
        case 8:  if(bar_idx < ArraySize(SigBuffer9))  SigBuffer9[bar_idx]  = value; break;
        case 9:  if(bar_idx < ArraySize(SigBuffer10)) SigBuffer10[bar_idx] = value; break;
        case 10: if(bar_idx < ArraySize(SigBuffer11)) SigBuffer11[bar_idx] = value; break;
        case 11: if(bar_idx < ArraySize(SigBuffer12)) SigBuffer12[bar_idx] = value; break;
    }
}

double GetSigBufferValue(int cycle_idx, int bar_idx)
{
    if(cycle_idx < 0 || cycle_idx >= 12 || bar_idx < 0) return 0.0;
    switch(cycle_idx)
    {
        case 0:  if(bar_idx < ArraySize(SigBuffer1))  return SigBuffer1[bar_idx];  break;
        case 1:  if(bar_idx < ArraySize(SigBuffer2))  return SigBuffer2[bar_idx];  break;
        case 2:  if(bar_idx < ArraySize(SigBuffer3))  return SigBuffer3[bar_idx];  break;
        case 3:  if(bar_idx < ArraySize(SigBuffer4))  return SigBuffer4[bar_idx];  break;
        case 4:  if(bar_idx < ArraySize(SigBuffer5))  return SigBuffer5[bar_idx];  break;
        case 5:  if(bar_idx < ArraySize(SigBuffer6))  return SigBuffer6[bar_idx];  break;
        case 6:  if(bar_idx < ArraySize(SigBuffer7))  return SigBuffer7[bar_idx];  break;
        case 7:  if(bar_idx < ArraySize(SigBuffer8))  return SigBuffer8[bar_idx];  break;
        case 8:  if(bar_idx < ArraySize(SigBuffer9))  return SigBuffer9[bar_idx];  break;
        case 9:  if(bar_idx < ArraySize(SigBuffer10)) return SigBuffer10[bar_idx]; break;
        case 10: if(bar_idx < ArraySize(SigBuffer11)) return SigBuffer11[bar_idx]; break;
        case 11: if(bar_idx < ArraySize(SigBuffer12)) return SigBuffer12[bar_idx]; break;
    }
    return 0.0;
}

// --- Fun??es para Color Buffers e estados derivados ---
double GetColorBufferValue(int cycle_idx, int bar_idx)
{
    if(cycle_idx < 0 || cycle_idx >= 12 || bar_idx < 0) return EMPTY_VALUE;
    switch(cycle_idx)
    {
        case 0:  if(bar_idx < ArraySize(ColorBuffer1))  return ColorBuffer1[bar_idx];  break;
        case 1:  if(bar_idx < ArraySize(ColorBuffer2))  return ColorBuffer2[bar_idx];  break;
        case 2:  if(bar_idx < ArraySize(ColorBuffer3))  return ColorBuffer3[bar_idx];  break;
        case 3:  if(bar_idx < ArraySize(ColorBuffer4))  return ColorBuffer4[bar_idx];  break;
        case 4:  if(bar_idx < ArraySize(ColorBuffer5))  return ColorBuffer5[bar_idx];  break;
        case 5:  if(bar_idx < ArraySize(ColorBuffer6))  return ColorBuffer6[bar_idx];  break;
        case 6:  if(bar_idx < ArraySize(ColorBuffer7))  return ColorBuffer7[bar_idx];  break;
        case 7:  if(bar_idx < ArraySize(ColorBuffer8))  return ColorBuffer8[bar_idx];  break;
        case 8:  if(bar_idx < ArraySize(ColorBuffer9))  return ColorBuffer9[bar_idx];  break;
        case 9:  if(bar_idx < ArraySize(ColorBuffer10)) return ColorBuffer10[bar_idx]; break;
        case 10: if(bar_idx < ArraySize(ColorBuffer11)) return ColorBuffer11[bar_idx]; break;
        case 11: if(bar_idx < ArraySize(ColorBuffer12)) return ColorBuffer12[bar_idx]; break;
    }
    return EMPTY_VALUE;
}

double GetCycleStateValue(int cycle_idx, int bar_idx)
{
    if(cycle_idx < 0 || cycle_idx >= 12 || bar_idx < 0) return 0.0;
    if(!g_cycle_active[cycle_idx]) return 0.0;

    double color_value = GetColorBufferValue(cycle_idx, bar_idx);
    if(color_value == EMPTY_VALUE) return 0.0;
    return (color_value > 0.5) ? 1.0 : -1.0;
}

void CollectCycleStates(int bar_index, double &states[])
{
    for(int c = 0; c < 12; c++)
        states[c] = GetCycleStateValue(c, bar_index);
}

// --- Fun??o para ETA Buffers ---
double GetEtaBufferValue(int cycle_idx, int bar_idx)
{
    if(cycle_idx < 0 || cycle_idx >= 12 || bar_idx < 0) return 0.0;
    switch(cycle_idx)
    {
        case 0:  if(bar_idx < ArraySize(EtaCycle1))  return EtaCycle1[bar_idx];  break;
        case 1:  if(bar_idx < ArraySize(EtaCycle2))  return EtaCycle2[bar_idx];  break;
        case 2:  if(bar_idx < ArraySize(EtaCycle3))  return EtaCycle3[bar_idx];  break;
        case 3:  if(bar_idx < ArraySize(EtaCycle4))  return EtaCycle4[bar_idx];  break;
        case 4:  if(bar_idx < ArraySize(EtaCycle5))  return EtaCycle5[bar_idx];  break;
        case 5:  if(bar_idx < ArraySize(EtaCycle6))  return EtaCycle6[bar_idx];  break;
        case 6:  if(bar_idx < ArraySize(EtaCycle7))  return EtaCycle7[bar_idx];  break;
        case 7:  if(bar_idx < ArraySize(EtaCycle8))  return EtaCycle8[bar_idx];  break;
        case 8:  if(bar_idx < ArraySize(EtaCycle9))  return EtaCycle9[bar_idx];  break;
        case 9:  if(bar_idx < ArraySize(EtaCycle10)) return EtaCycle10[bar_idx]; break;
        case 10: if(bar_idx < ArraySize(EtaCycle11)) return EtaCycle11[bar_idx]; break;
        case 11: if(bar_idx < ArraySize(EtaCycle12)) return EtaCycle12[bar_idx]; break;
    }
    return 0.0;
}

double GetEtaRawValue(int cycle_idx, int bar_idx)
{
    if(cycle_idx < 0 || cycle_idx >= 12 || bar_idx < 0) return 0.0;
    switch(cycle_idx)
    {
        case 0:  if(bar_idx < ArraySize(EtaRawCycle1))  return EtaRawCycle1[bar_idx];  break;
        case 1:  if(bar_idx < ArraySize(EtaRawCycle2))  return EtaRawCycle2[bar_idx];  break;
        case 2:  if(bar_idx < ArraySize(EtaRawCycle3))  return EtaRawCycle3[bar_idx];  break;
        case 3:  if(bar_idx < ArraySize(EtaRawCycle4))  return EtaRawCycle4[bar_idx];  break;
        case 4:  if(bar_idx < ArraySize(EtaRawCycle5))  return EtaRawCycle5[bar_idx];  break;
        case 5:  if(bar_idx < ArraySize(EtaRawCycle6))  return EtaRawCycle6[bar_idx];  break;
        case 6:  if(bar_idx < ArraySize(EtaRawCycle7))  return EtaRawCycle7[bar_idx];  break;
        case 7:  if(bar_idx < ArraySize(EtaRawCycle8))  return EtaRawCycle8[bar_idx];  break;
        case 8:  if(bar_idx < ArraySize(EtaRawCycle9))  return EtaRawCycle9[bar_idx];  break;
        case 9:  if(bar_idx < ArraySize(EtaRawCycle10)) return EtaRawCycle10[bar_idx]; break;
        case 10: if(bar_idx < ArraySize(EtaRawCycle11)) return EtaRawCycle11[bar_idx]; break;
        case 11: if(bar_idx < ArraySize(EtaRawCycle12)) return EtaRawCycle12[bar_idx]; break;
    }
    return 0.0;
}

void EnsureRawBuffersSize(int size)
{
    if(size <= 0) return;

    if(ArraySize(EtaRawCycle1)  < size) ArrayResize(EtaRawCycle1,  size);
    if(ArraySize(EtaRawCycle2)  < size) ArrayResize(EtaRawCycle2,  size);
    if(ArraySize(EtaRawCycle3)  < size) ArrayResize(EtaRawCycle3,  size);
    if(ArraySize(EtaRawCycle4)  < size) ArrayResize(EtaRawCycle4,  size);
    if(ArraySize(EtaRawCycle5)  < size) ArrayResize(EtaRawCycle5,  size);
    if(ArraySize(EtaRawCycle6)  < size) ArrayResize(EtaRawCycle6,  size);
    if(ArraySize(EtaRawCycle7)  < size) ArrayResize(EtaRawCycle7,  size);
    if(ArraySize(EtaRawCycle8)  < size) ArrayResize(EtaRawCycle8,  size);
    if(ArraySize(EtaRawCycle9)  < size) ArrayResize(EtaRawCycle9,  size);
    if(ArraySize(EtaRawCycle10) < size) ArrayResize(EtaRawCycle10, size);
    if(ArraySize(EtaRawCycle11) < size) ArrayResize(EtaRawCycle11, size);
    if(ArraySize(EtaRawCycle12) < size) ArrayResize(EtaRawCycle12, size);
}

void EnsureAuxBuffersSize(int size)
{
    if(size <= 0) return;

    if(ArraySize(WaveBuffer1)  < size) ArrayResize(WaveBuffer1,  size);
    if(ArraySize(WaveBuffer2)  < size) ArrayResize(WaveBuffer2,  size);
    if(ArraySize(WaveBuffer3)  < size) ArrayResize(WaveBuffer3,  size);
    if(ArraySize(WaveBuffer4)  < size) ArrayResize(WaveBuffer4,  size);
    if(ArraySize(WaveBuffer5)  < size) ArrayResize(WaveBuffer5,  size);
    if(ArraySize(WaveBuffer6)  < size) ArrayResize(WaveBuffer6,  size);
    if(ArraySize(WaveBuffer7)  < size) ArrayResize(WaveBuffer7,  size);
    if(ArraySize(WaveBuffer8)  < size) ArrayResize(WaveBuffer8,  size);
    if(ArraySize(WaveBuffer9)  < size) ArrayResize(WaveBuffer9,  size);
    if(ArraySize(WaveBuffer10) < size) ArrayResize(WaveBuffer10, size);
    if(ArraySize(WaveBuffer11) < size) ArrayResize(WaveBuffer11, size);
    if(ArraySize(WaveBuffer12) < size) ArrayResize(WaveBuffer12, size);

    if(ArraySize(EtaCycle1)  < size) ArrayResize(EtaCycle1,  size);
    if(ArraySize(EtaCycle2)  < size) ArrayResize(EtaCycle2,  size);
    if(ArraySize(EtaCycle3)  < size) ArrayResize(EtaCycle3,  size);
    if(ArraySize(EtaCycle4)  < size) ArrayResize(EtaCycle4,  size);
    if(ArraySize(EtaCycle5)  < size) ArrayResize(EtaCycle5,  size);
    if(ArraySize(EtaCycle6)  < size) ArrayResize(EtaCycle6,  size);
    if(ArraySize(EtaCycle7)  < size) ArrayResize(EtaCycle7,  size);
    if(ArraySize(EtaCycle8)  < size) ArrayResize(EtaCycle8,  size);
    if(ArraySize(EtaCycle9)  < size) ArrayResize(EtaCycle9,  size);
    if(ArraySize(EtaCycle10) < size) ArrayResize(EtaCycle10, size);
    if(ArraySize(EtaCycle11) < size) ArrayResize(EtaCycle11, size);
    if(ArraySize(EtaCycle12) < size) ArrayResize(EtaCycle12, size);

    if(ArraySize(ColorBuffer1)  < size) ArrayResize(ColorBuffer1,  size);
    if(ArraySize(ColorBuffer2)  < size) ArrayResize(ColorBuffer2,  size);
    if(ArraySize(ColorBuffer3)  < size) ArrayResize(ColorBuffer3,  size);
    if(ArraySize(ColorBuffer4)  < size) ArrayResize(ColorBuffer4,  size);
    if(ArraySize(ColorBuffer5)  < size) ArrayResize(ColorBuffer5,  size);
    if(ArraySize(ColorBuffer6)  < size) ArrayResize(ColorBuffer6,  size);
    if(ArraySize(ColorBuffer7)  < size) ArrayResize(ColorBuffer7,  size);
    if(ArraySize(ColorBuffer8)  < size) ArrayResize(ColorBuffer8,  size);
    if(ArraySize(ColorBuffer9)  < size) ArrayResize(ColorBuffer9,  size);
    if(ArraySize(ColorBuffer10) < size) ArrayResize(ColorBuffer10, size);
    if(ArraySize(ColorBuffer11) < size) ArrayResize(ColorBuffer11, size);
    if(ArraySize(ColorBuffer12) < size) ArrayResize(ColorBuffer12, size);

    if(ArraySize(LeakETA1)  < size) ArrayResize(LeakETA1,  size);
    if(ArraySize(LeakETA2)  < size) ArrayResize(LeakETA2,  size);
    if(ArraySize(LeakETA3)  < size) ArrayResize(LeakETA3,  size);
    if(ArraySize(LeakETA4)  < size) ArrayResize(LeakETA4,  size);
    if(ArraySize(LeakETA5)  < size) ArrayResize(LeakETA5,  size);
    if(ArraySize(LeakETA6)  < size) ArrayResize(LeakETA6,  size);
    if(ArraySize(LeakETA7)  < size) ArrayResize(LeakETA7,  size);
    if(ArraySize(LeakETA8)  < size) ArrayResize(LeakETA8,  size);
    if(ArraySize(LeakETA9)  < size) ArrayResize(LeakETA9,  size);
    if(ArraySize(LeakETA10) < size) ArrayResize(LeakETA10, size);
    if(ArraySize(LeakETA11) < size) ArrayResize(LeakETA11, size);
    if(ArraySize(LeakETA12) < size) ArrayResize(LeakETA12, size);

    if(ArraySize(WavePeriodBuffer1)  < size) ArrayResize(WavePeriodBuffer1,  size);
    if(ArraySize(WavePeriodBuffer2)  < size) ArrayResize(WavePeriodBuffer2,  size);
    if(ArraySize(WavePeriodBuffer3)  < size) ArrayResize(WavePeriodBuffer3,  size);
    if(ArraySize(WavePeriodBuffer4)  < size) ArrayResize(WavePeriodBuffer4,  size);
    if(ArraySize(WavePeriodBuffer5)  < size) ArrayResize(WavePeriodBuffer5,  size);
    if(ArraySize(WavePeriodBuffer6)  < size) ArrayResize(WavePeriodBuffer6,  size);
    if(ArraySize(WavePeriodBuffer7)  < size) ArrayResize(WavePeriodBuffer7,  size);
    if(ArraySize(WavePeriodBuffer8)  < size) ArrayResize(WavePeriodBuffer8,  size);
    if(ArraySize(WavePeriodBuffer9)  < size) ArrayResize(WavePeriodBuffer9,  size);
    if(ArraySize(WavePeriodBuffer10) < size) ArrayResize(WavePeriodBuffer10, size);
    if(ArraySize(WavePeriodBuffer11) < size) ArrayResize(WavePeriodBuffer11, size);
    if(ArraySize(WavePeriodBuffer12) < size) ArrayResize(WavePeriodBuffer12, size);

    if(ArraySize(SigBuffer1)  < size) ArrayResize(SigBuffer1,  size);
    if(ArraySize(SigBuffer2)  < size) ArrayResize(SigBuffer2,  size);
    if(ArraySize(SigBuffer3)  < size) ArrayResize(SigBuffer3,  size);
    if(ArraySize(SigBuffer4)  < size) ArrayResize(SigBuffer4,  size);
    if(ArraySize(SigBuffer5)  < size) ArrayResize(SigBuffer5,  size);
    if(ArraySize(SigBuffer6)  < size) ArrayResize(SigBuffer6,  size);
    if(ArraySize(SigBuffer7)  < size) ArrayResize(SigBuffer7,  size);
    if(ArraySize(SigBuffer8)  < size) ArrayResize(SigBuffer8,  size);
    if(ArraySize(SigBuffer9)  < size) ArrayResize(SigBuffer9,  size);
    if(ArraySize(SigBuffer10) < size) ArrayResize(SigBuffer10, size);
    if(ArraySize(SigBuffer11) < size) ArrayResize(SigBuffer11, size);
    if(ArraySize(SigBuffer12) < size) ArrayResize(SigBuffer12, size);
}

//+------------------------------------------------------------------+
//| FOLLOW THE FIRST - Altern?ncia PICO-FUNDO (v7.55)              |
//+------------------------------------------------------------------+
void ProcessFollowFirst(int bar_index, const double &etas[])
{
    if(!InpEnableFollowFirst) return;
    if(bar_index != 0) return;

    // Esta fun??o agora gerencia apenas o ESTADO de SA?DA e contagem de barras
    if(g_ff_state.active_cycle < 0) return;

    g_ff_state.bars_in_position++;

    int c = g_ff_state.active_cycle;
    // Condi??o de sa?da: ETA est? perto de 0
    if(MathAbs(etas[c]) <= InpExitBarsBeforeEnd)
    {
        g_ff_state.active_cycle = -1; // Libera para procurar novo sinal
        // Alterna o modo para o pr?ximo sinal
        g_ff_state.mode = (g_ff_state.mode == FF_WAITING_PEAK) ? FF_WAITING_VALLEY : FF_WAITING_PEAK;
    }
}

//+------------------------------------------------------------------+
//| Processa a l?gica de SINAL do Follow First (v7.56)             |
//| Encapsula a detec??o de virada de cor e popula o buffer FF.      |
//+------------------------------------------------------------------+
void ProcessFollowFirstSignal(int bar_index, const double &state_data[], const double &state_data_prev[])
{
    if(!InpEnableFollowFirst || bar_index < 1) return;
    if(!InpFFAllowMultipleSignals && g_ff_state.active_cycle != -1) return;

    // Para cada ciclo que virou na barra, emitir sinal independente
    int buy_turns = 0, sell_turns = 0;
    int active_cycles = 0;
    for (int c = 0; c < 12; c++)
    {
        if(!g_cycle_active[c]) continue; else active_cycles++;
        double period = g_dominant_periods[c];
        if (period < InpMinPeriodToFollow || period > InpMaxPeriodToFollow) continue;

        double prev_state = state_data_prev[c];
        double curr_state = state_data[c];
        if(prev_state == 0.0) continue; // sem hist?rico

        double eta_prev_raw = GetEtaRawValue(c, bar_index - 1);
        double eta_curr_raw = GetEtaRawValue(c, bar_index);

        bool states_equal = (curr_state == prev_state);
        bool pre_signal_triggered = false;
        int  pre_signal_dir = 0;
        double pre_signal_value = 0.0;

        if(InpEntryBarsBeforeEnd > 0 && states_equal)
        {
            double threshold = (double)InpEntryBarsBeforeEnd;
            if(curr_state > 0.0 && eta_prev_raw > 0.0 && eta_curr_raw > 0.0)
            {
                if(eta_prev_raw > threshold && eta_curr_raw <= threshold)
                {
                    pre_signal_dir = -1;
                    pre_signal_triggered = true;
                }
            }
            else if(curr_state < 0.0 && eta_prev_raw < 0.0 && eta_curr_raw < 0.0)
            {
                double prev_abs = MathAbs(eta_prev_raw);
                double curr_abs = MathAbs(eta_curr_raw);
                if(prev_abs > threshold && curr_abs <= threshold)
                {
                    pre_signal_dir = +1;
                    pre_signal_triggered = true;
                }
            }
        }

        if(pre_signal_triggered)
        {
            pre_signal_value = (pre_signal_dir > 0) ? 60.0 : -60.0;
            SetSigBufferValue(c, bar_index, pre_signal_value);
            if(!InpFFAllowMultipleSignals)
            {
                g_sig_last_dir[c] = pre_signal_dir;
                g_sig_last_bar[c] = bar_index;
            }
            if(pre_signal_dir > 0) buy_turns++; else sell_turns++;

            if(!InpFFAllowMultipleSignals)
            {
                g_ff_state.mode = (pre_signal_dir > 0) ? FF_WAITING_PEAK : FF_WAITING_VALLEY;
                g_ff_state.active_cycle = c;
                g_ff_state.active_period = period;
                g_ff_state.bars_in_position = 0;
                g_ff_state.active_eta_start = MathAbs(eta_curr_raw);
                break;
            }
            else
            {
                continue;
            }
        }

        if(states_equal) continue; // sem virada e sem pr?-sinal

        bool to_bull = (prev_state == -1.0 && curr_state == 1.0);
        bool to_bear = (prev_state == 1.0 && curr_state == -1.0);

        if(to_bear)
        {
            if(InpSIGIgnoreSameDirection && g_sig_last_dir[c] == -1 && bar_index > g_sig_last_bar[c]) continue;
            SetSigBufferValue(c, bar_index, -100.0);
            g_sig_last_dir[c] = -1;
            g_sig_last_bar[c] = bar_index;
            sell_turns++;
            if(!InpFFAllowMultipleSignals)
            {
                g_ff_state.mode = FF_WAITING_VALLEY;
                g_ff_state.active_cycle = c;
                g_ff_state.active_period = period;
                g_ff_state.bars_in_position = 0;
                g_ff_state.active_eta_start = MathAbs(eta_curr_raw);
                break;
            }
        }
        else if(to_bull)
        {
            if(InpSIGIgnoreSameDirection && g_sig_last_dir[c] == +1 && bar_index > g_sig_last_bar[c]) continue;
            SetSigBufferValue(c, bar_index, 100.0);
            g_sig_last_dir[c] = +1;
            g_sig_last_bar[c] = bar_index;
            buy_turns++;
            if(!InpFFAllowMultipleSignals)
            {
                g_ff_state.mode = FF_WAITING_PEAK;
                g_ff_state.active_cycle = c;
                g_ff_state.active_period = period;
                g_ff_state.bars_in_position = 0;
                g_ff_state.active_eta_start = MathAbs(eta_curr_raw);
                break;
            }
        }
    }
    // Conflu?ncia por barra
    double conf_val = 0.0;
    if(active_cycles > 0)
    {
        double buy_pct = (100.0 * buy_turns) / active_cycles;
        double sell_pct = (100.0 * sell_turns) / active_cycles;
        if(buy_pct >= InpConfluencePercent && buy_pct >= sell_pct) conf_val = +InpConfluenceLotMult;
        else if(sell_pct >= InpConfluencePercent && sell_pct > buy_pct) conf_val = -InpConfluenceLotMult;
    }
    SigConfluence[bar_index] = conf_val;
    return;
}

//+------------------------------------------------------------------+
//| Popular buffers de leakage com ETAs das intrus?es (v7.53)      |
//| Chamado para cada barra ap?s calcular ciclos principais        |
//+------------------------------------------------------------------+
void PopulateLeakBuffers(int bar_index)
{
    double seconds_per_bar = (double)PeriodSeconds((ENUM_TIMEFRAMES)_Period);
    if(seconds_per_bar <= 0.0)
        seconds_per_bar = 60.0;

    // Para cada um dos 12 ciclos
    for(int c = 0; c < 12; c++)
    {
        double leak_eta_bars = 0.0;  // Valor padr?o (sem leak)

        // Verificar se este ciclo tem leak ativo
        if(g_cycle_states[c].is_leak_active &&
           g_cycle_states[c].leak_tracker_idx >= 0 &&
           g_cycle_states[c].leak_tracker_idx < g_tracker_count)
        {
            int leak_idx = g_cycle_states[c].leak_tracker_idx;
            // Calcular ETA do leak (mesmo metodo do principal, mas com periodo do leak)
            double leak_period = g_period_trackers[leak_idx].period;
            int leak_fft_idx = g_period_trackers[leak_idx].fft_index;

            double leak_phase_target_bars = MathMax(1.0, leak_period);
            if(leak_phase_target_bars < (double)g_cycle_states[c].leak_bars_active)
                leak_phase_target_bars = (double)g_cycle_states[c].leak_bars_active;

            double leak_phase_target_seconds = leak_phase_target_bars * seconds_per_bar;
            double leak_elapsed_seconds = (double)g_cycle_states[c].leak_bars_active * seconds_per_bar;

            double leak_phase_progress = (leak_phase_target_seconds > 0.0)
                                         ? MathMin(1.0, leak_elapsed_seconds / leak_phase_target_seconds)
                                         : 0.0;

            double leak_eta_seconds = CalculateScientificETASeconds(leak_fft_idx, leak_phase_target_seconds, leak_phase_progress, seconds_per_bar);

            if(leak_eta_seconds <= 0.0)
            {
                double leak_remaining_seconds = MathMax(0.0, leak_phase_target_seconds - leak_elapsed_seconds);
                leak_eta_seconds = leak_remaining_seconds;
            }

            leak_eta_bars = (seconds_per_bar > 0.0) ? leak_eta_seconds / seconds_per_bar : 0.0;

            double main_eta = GetEtaBufferValue(c, bar_index);
            if(main_eta > 0.0)
                leak_eta_bars = MathAbs(leak_eta_bars);
            else if(main_eta < 0.0)
                leak_eta_bars = -MathAbs(leak_eta_bars);
            else
                leak_eta_bars = MathAbs(leak_eta_bars);
        }

        // Popular buffer correspondente ao ciclo
        switch(c) {
            case 0:  LeakETA1[bar_index] = leak_eta_bars;   break; case 1:  LeakETA2[bar_index] = leak_eta_bars;   break;
            case 2:  LeakETA3[bar_index] = leak_eta_bars;   break; case 3:  LeakETA4[bar_index] = leak_eta_bars;   break;
            case 4:  LeakETA5[bar_index] = leak_eta_bars;   break; case 5:  LeakETA6[bar_index] = leak_eta_bars;   break;
            case 6:  LeakETA7[bar_index] = leak_eta_bars;   break; case 7:  LeakETA8[bar_index] = leak_eta_bars;   break;
            case 8:  LeakETA9[bar_index] = leak_eta_bars;   break; case 9:  LeakETA10[bar_index] = leak_eta_bars;  break;
            case 10: LeakETA11[bar_index] = leak_eta_bars;  break; case 11: LeakETA12[bar_index] = leak_eta_bars;  break;
        }
    }
}

//+------------------------------------------------------------------+
//| Popular LEAK ETA em buffers auxiliares (NOVO)                  |
//| Independente das tentativas antigas de plotagem                |
//+------------------------------------------------------------------+
void PopulateLeakAuxBuffers_New(int bar_index)
{
    for(int c = 0; c < 12; c++)
    {
        bool wrote = false;
        double leak_val = 0.0;

        if(!g_cycle_active[c])
        {
            g_aux_leak_tracker_idx[c] = -1;
            g_aux_leak_bars_active[c] = 0;
            // mantém gate como está; será liberado na mudança de estado
        }
        else
        {
            int main_idx = g_cycle_states[c].main_tracker_idx;
            if(main_idx >= 0 && main_idx < g_tracker_count)
            {
                double main_period = g_period_trackers[main_idx].period;
                double main_power  = g_period_trackers[main_idx].power;

                // estado atual da linha (cor)
                int curr_state = 0;
                switch(c) {
                    case 0:  curr_state = (ColorBuffer1[bar_index]  > 0.5) ? +1 : -1; break;
                    case 1:  curr_state = (ColorBuffer2[bar_index]  > 0.5) ? +1 : -1; break;
                    case 2:  curr_state = (ColorBuffer3[bar_index]  > 0.5) ? +1 : -1; break;
                    case 3:  curr_state = (ColorBuffer4[bar_index]  > 0.5) ? +1 : -1; break;
                    case 4:  curr_state = (ColorBuffer5[bar_index]  > 0.5) ? +1 : -1; break;
                    case 5:  curr_state = (ColorBuffer6[bar_index]  > 0.5) ? +1 : -1; break;
                    case 6:  curr_state = (ColorBuffer7[bar_index]  > 0.5) ? +1 : -1; break;
                    case 7:  curr_state = (ColorBuffer8[bar_index]  > 0.5) ? +1 : -1; break;
                    case 8:  curr_state = (ColorBuffer9[bar_index]  > 0.5) ? +1 : -1; break;
                    case 9:  curr_state = (ColorBuffer10[bar_index] > 0.5) ? +1 : -1; break;
                    case 10: curr_state = (ColorBuffer11[bar_index] > 0.5) ? +1 : -1; break;
                    case 11: curr_state = (ColorBuffer12[bar_index] > 0.5) ? +1 : -1; break;
                }

                // libera gate se mudou de estado
                if(g_aux_leak_gate_state[c] != 0 && g_aux_leak_gate_state[c] != curr_state)
                    g_aux_leak_gate_state[c] = 0;

                // se gate ativo para esta fase, não iniciar novo leak
                if(g_aux_leak_gate_state[c] == curr_state && g_aux_leak_gate_state[c] != 0)
                {
                    // skip
                }
                else
                {
                    // selecionar melhor leak
                    int best = -1; double best_pwr = 0.0;
                    for(int t = 0; t < g_tracker_count; t++)
                    {
                        if(t == main_idx) continue;
                        if(g_period_trackers[t].bars_inactive > InpLeakMinBars) continue;
                        double p = g_period_trackers[t].period;
                        double pw = g_period_trackers[t].power;
                        if(p < main_period * InpLeakPeriodRatio && pw >= main_power * InpLeakPowerRatio)
                        {
                            if(best == -1 || pw > best_pwr) { best = t; best_pwr = pw; }
                        }
                    }

                    if(best != -1)
                    {
                        if(g_aux_leak_tracker_idx[c] == best) g_aux_leak_bars_active[c]++;
                        else { g_aux_leak_tracker_idx[c] = best; g_aux_leak_bars_active[c] = 1; }

                        double leak_period = g_period_trackers[best].period;
                        int period_i = (int)MathMax(1.0, MathCeil(leak_period));
                        int remaining_i = period_i - g_aux_leak_bars_active[c];

                        if(remaining_i <= 0)
                        {
                            // terminou: bloquear novos leaks até mudar de estado
                            g_aux_leak_tracker_idx[c] = -1;
                            g_aux_leak_bars_active[c] = 0;
                            g_aux_leak_gate_state[c] = curr_state;
                        }
                        else
                        {
                            leak_val = (double)remaining_i; // base magnitude in bars
                            // Sign by current line state: green=positive, red=negative
                            if(curr_state < 0) leak_val = -leak_val; else leak_val = +leak_val;
                            wrote = true;
                        }
                    }
                    else
                    {
                        g_aux_leak_tracker_idx[c] = -1;
                        g_aux_leak_bars_active[c] = 0;
                        // não escrever zeros
                    }
                }
            }
            else
            {
                g_aux_leak_tracker_idx[c] = -1;
                g_aux_leak_bars_active[c] = 0;
                // não escrever zeros
            }
        }

        if(wrote)
        {
            switch(c)
            {
                case 0:  LeakETA1[bar_index] = leak_val;  break; case 1:  LeakETA2[bar_index]  = leak_val; break;
                case 2:  LeakETA3[bar_index] = leak_val;  break; case 3:  LeakETA4[bar_index]  = leak_val; break;
                case 4:  LeakETA5[bar_index] = leak_val;  break; case 5:  LeakETA6[bar_index]  = leak_val; break;
                case 6:  LeakETA7[bar_index] = leak_val;  break; case 7:  LeakETA8[bar_index]  = leak_val; break;
                case 8:  LeakETA9[bar_index] = leak_val;  break; case 9:  LeakETA10[bar_index] = leak_val; break;
                case 10: LeakETA11[bar_index] = leak_val; break; case 11: LeakETA12[bar_index] = leak_val; break;
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Detectar mudan?as de estado e registrar (v7.54)                 |
//+------------------------------------------------------------------+
void DetectStateChanges(const double &current_states[])
{
    static double previous_states[12] = {0,0,0,0,0,0,0,0,0,0,0,0};
    static bool first_call = true;

    if(g_reset_state_cache)
    {
        for(int c = 0; c < 12; c++)
            previous_states[c] = 0.0;
        first_call = true;
        g_reset_state_cache = false;
    }

    if(first_call) {
        // Primeira chamada: apenas copiar estados
        ArrayCopy(previous_states, current_states);
        first_call = false;
        return;
    }

    datetime current_time = TimeCurrent();

    for(int c = 0; c < 12; c++)
    {
        if(!g_cycle_active[c]) continue;

        // Detectar mudanÃ§a de estado
        if(current_states[c] != previous_states[c] && previous_states[c] != 0)
        {
            // MudanÃ§a detectada!
            g_last_transitions[c].time = current_time;
            g_last_transitions[c].bar_index = 0;  // Barra atual
            g_last_transitions[c].old_state = previous_states[c];
            g_last_transitions[c].new_state = current_states[c];
            g_last_transitions[c].period = g_dominant_periods[c];

            // Ler ETA atual do buffer correspondente
            double eta = GetEtaRawValue(c, 0);
            g_last_transitions[c].eta_at_change = eta;
        }
    }

    // Atualizar estados anteriores
    ArrayCopy(previous_states, current_states);
}

//+------------------------------------------------------------------+
//| Inicializar sistema de exporta??o CSV (v7.54)                   |
//+------------------------------------------------------------------+
void InitializeCSVExport()
{
    if(!InpExportToCSV) return;

    // Criar arquivo CSV
    string filename = InpCSVFilename;
    g_file_handle = FileOpen(filename, FILE_WRITE|FILE_CSV|FILE_ANSI, ",");

    if(g_file_handle == INVALID_HANDLE)
    {
        return;
    }

    // Escrever cabe?alho
    string header = "Time,BarIndex";

    for(int c = 1; c <= 12; c++)
    {
        header += StringFormat(",C%d_State,C%d_Period,C%d_ETA,C%d_Leak", c, c, c, c);
    }

    FileWrite(g_file_handle, header);
    FileClose(g_file_handle);
}

//+------------------------------------------------------------------+
//| Exportar linha para CSV (v7.54)                                 |
//+------------------------------------------------------------------+
void ExportToCSV(datetime time, int bar_index)
{
    if(!InpExportToCSV || InpCSVUpdateBars == 0) return;

    // Verificar se j? exportamos esta barra
    if(bar_index == g_csv_last_bar) return;

    // Verificar intervalo de atualiza??o
    if(bar_index % InpCSVUpdateBars != 0) return;

    // Abrir arquivo em modo append
    string filename = InpCSVFilename;
    int handle = FileOpen(filename, FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI, ",");

    if(handle == INVALID_HANDLE)
    {
        return;
    }

    // Ir para o final do arquivo
    FileSeek(handle, 0, SEEK_END);

    // Montar linha de dados
    string line = TimeToString(time, TIME_DATE|TIME_MINUTES) + "," + IntegerToString(bar_index);

    for(int c = 0; c < 12; c++)
    {
        double state = GetCycleStateValue(c, bar_index);
        double period = g_dominant_periods[c];
        double eta = GetEtaRawValue(c, bar_index);
        double leak = 0.0;

        switch(c) {
            case 0:  if(bar_index < ArraySize(LeakETA1))  leak = LeakETA1[bar_index];   break;
            case 1:  if(bar_index < ArraySize(LeakETA2))  leak = LeakETA2[bar_index];   break;
            case 2:  if(bar_index < ArraySize(LeakETA3))  leak = LeakETA3[bar_index];   break;
            case 3:  if(bar_index < ArraySize(LeakETA4))  leak = LeakETA4[bar_index];   break;
            case 4:  if(bar_index < ArraySize(LeakETA5))  leak = LeakETA5[bar_index];   break;
            case 5:  if(bar_index < ArraySize(LeakETA6))  leak = LeakETA6[bar_index];   break;
            case 6:  if(bar_index < ArraySize(LeakETA7))  leak = LeakETA7[bar_index];   break;
            case 7:  if(bar_index < ArraySize(LeakETA8))  leak = LeakETA8[bar_index];   break;
            case 8:  if(bar_index < ArraySize(LeakETA9))  leak = LeakETA9[bar_index];   break;
            case 9:  if(bar_index < ArraySize(LeakETA10)) leak = LeakETA10[bar_index]; break;
            case 10: if(bar_index < ArraySize(LeakETA11)) leak = LeakETA11[bar_index]; break;
            case 11: if(bar_index < ArraySize(LeakETA12)) leak = LeakETA12[bar_index]; break;
        }

        line += StringFormat(",%.0f,%.1f,%.1f,%.1f", state, period, eta, leak);
    }

    FileWrite(handle, line);
    FileClose(handle);

    g_csv_last_bar = bar_index;
}

//+------------------------------------------------------------------+
//| Desenha painel com informa??es dos TRACKERS (v7.52)             |
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| Desenha legendas dos trackers no gr?fico (DEBUG)                 |
//+------------------------------------------------------------------+
input bool InpShowTrackerInfo = true;  // Mostrar info dos trackers

void ShowCycleListDebug()
{
    if(!InpShowTrackerInfo) return;
    string s = "Cycles (Top12):\n";
    for(int c = 0; c < 12; c++)
    {
        if(!g_cycle_active[c])
        {
            s += StringFormat("C%d: inactive\n", c+1);
            continue;
        }

        int main_idx = g_cycle_states[c].main_tracker_idx;
        double per = g_dominant_periods[c];
        int bin = g_dominant_indices[c];
        double pwr = (main_idx>=0 && main_idx<g_tracker_count) ? g_period_trackers[main_idx].power : 0.0;

        // Frequency and number of cycles in the FFT window
        int n_phase = ArraySize(fft_unwrapped_phase);
        int n = (n_phase > 0) ? MathMin(InpFFTWindow, n_phase) : InpFFTWindow;
        if(n <= 0) n = InpFFTWindow;
        double freq_cyc_per_bar = (n > 0) ? ((double)bin / (double)n) : 0.0;  // cycles per bar
        double num_cycles_window = freq_cyc_per_bar * (double)n;               // ≈ bin

        string leak = "-";
        if(g_cycle_states[c].is_leak_active)
        {
            int li = g_cycle_states[c].leak_tracker_idx;
            if(li>=0 && li<g_tracker_count)
                leak = StringFormat("%.1f", g_period_trackers[li].period);
        }

        // Optional: show RealFFT group delay when mode is enabled
        string extra = "";
        if(InpETAMode == ETA_REALFFT)
        {
            double nominal_seconds = (double)PeriodSeconds((ENUM_TIMEFRAMES)_Period);
            if(nominal_seconds <= 0.0) nominal_seconds = 60.0;
            double tg_seconds = ComputeETA_RealFFT(bin, per, n, nominal_seconds);
            double tg_bars = (nominal_seconds > 0.0) ? tg_seconds / nominal_seconds : 0.0;
            // tg is measured in bars; include unit for clarity
            extra = StringFormat(" | tg=%.1f bars", tg_bars);
        }

        s += StringFormat(
            "C%d: P=%.1f | bin=%d | f=%.6f cyc/bar | cyclesWin=%.0f | Pow=%.2f | Leak=%s%s\n",
            c+1, per, bin, freq_cyc_per_bar, num_cycles_window, pwr, leak, extra
        );
    }
    Comment(s);
}

//+------------------------------------------------------------------+
//| Fun??o de inicializa??o do indicador customizado                 |
//+------------------------------------------------------------------+
int OnInit()
{
    int gpu_status = GpuSessionInit(0);
    if(gpu_status != GPU_STATUS_OK && gpu_status != GPU_STATUS_ALREADY_INITIALIZED)
    {
        PrintFormat("[GPU] GpuSessionInit failed: %d", gpu_status);
        return(INIT_FAILED);
    }
    if(!EnsureWaveformGpuConfigured(InpFFTWindow))
        return(INIT_FAILED);
    g_gpu_waveform_session_initialized = true;

    ResetZigZagHandles();
    if(InpAppliedPrice == FFT_PRICE_ZIGZAG)
    {
        ENUM_TIMEFRAMES tf_current = (ENUM_TIMEFRAMES)_Period;
        if(!EnsureZigZagHandleForTf(tf_current))
            return(INIT_FAILED);

        if(InpZigZagSource == ZIG_SOURCE_LOWER1 || InpZigZagSource == ZIG_SOURCE_LOWER2)
        {
            ENUM_TIMEFRAMES tf_lower1 = DetermineLowerTimeframe(1, InpZigZagLowerTF1);
            if(tf_lower1 != tf_current)
            {
                if(!EnsureZigZagHandleForTf(tf_lower1))
                    return(INIT_FAILED);
            }
            if(InpZigZagSource == ZIG_SOURCE_LOWER2)
            {
                ENUM_TIMEFRAMES tf_lower2 = DetermineLowerTimeframe(2, InpZigZagLowerTF2);
                if(tf_lower2 != tf_current && tf_lower2 != tf_lower1)
                {
                    if(!EnsureZigZagHandleForTf(tf_lower2))
                        return(INIT_FAILED);
                }
            }
        }
    }

    // Inicializar estado FollowFirst
    g_ff_state.mode = FF_WAITING_PEAK;
    g_ff_state.active_cycle = -1;
    g_ff_state.active_period = 0;
    g_ff_state.active_eta_start = 0;
    g_ff_state.entry_time = 0;
    g_ff_state.entry_bar = 0;
    g_ff_state.bars_in_position = 0;
    g_ff_state.peak_found = false;
    g_ff_state.valley_found = false;


    // Controle de repeti??o por ciclo: reset
    for(int c=0;c<12;c++){ g_sig_last_dir[c]=0; g_sig_last_bar[c]=-1; }
    // Sem gating/treino: sinais de transi??o liberados imediatamente

    // Map indicator buffers (data + color)

    // Wave buffers (plots 1-12) and WavePeriod buffers (plots 13-24)
    SetIndexBuffer(0,  WaveBuffer1,  INDICATOR_DATA);
    SetIndexBuffer(1,  WaveBuffer2,  INDICATOR_DATA);
    SetIndexBuffer(2,  WaveBuffer3,  INDICATOR_DATA);
    SetIndexBuffer(3,  WaveBuffer4,  INDICATOR_DATA);
    SetIndexBuffer(4,  WaveBuffer5,  INDICATOR_DATA);
    SetIndexBuffer(5,  WaveBuffer6,  INDICATOR_DATA);
    SetIndexBuffer(6,  WaveBuffer7,  INDICATOR_DATA);
    SetIndexBuffer(7,  WaveBuffer8,  INDICATOR_DATA);
    SetIndexBuffer(8,  WaveBuffer9,  INDICATOR_DATA);
    SetIndexBuffer(9,  WaveBuffer10, INDICATOR_DATA);
    SetIndexBuffer(10, WaveBuffer11, INDICATOR_DATA);
    SetIndexBuffer(11, WaveBuffer12, INDICATOR_DATA);

    SetIndexBuffer(12, WavePeriodBuffer1,  INDICATOR_DATA);
    SetIndexBuffer(13, WavePeriodBuffer2,  INDICATOR_DATA);
    SetIndexBuffer(14, WavePeriodBuffer3,  INDICATOR_DATA);
    SetIndexBuffer(15, WavePeriodBuffer4,  INDICATOR_DATA);
    SetIndexBuffer(16, WavePeriodBuffer5,  INDICATOR_DATA);
    SetIndexBuffer(17, WavePeriodBuffer6,  INDICATOR_DATA);
    SetIndexBuffer(18, WavePeriodBuffer7,  INDICATOR_DATA);
    SetIndexBuffer(19, WavePeriodBuffer8,  INDICATOR_DATA);
    SetIndexBuffer(20, WavePeriodBuffer9,  INDICATOR_DATA);
    SetIndexBuffer(21, WavePeriodBuffer10, INDICATOR_DATA);
    SetIndexBuffer(22, WavePeriodBuffer11, INDICATOR_DATA);
    SetIndexBuffer(23, WavePeriodBuffer12, INDICATOR_DATA);

    // Alternating ETA/Leak/State/SIG buffers per cycle (plots 25-72)
// Alternating ETA/Leak/State/SIG buffers per cycle (plots 25-72)

    // Confluence buffer (plot 73)
    SetIndexBuffer(84, SigConfluence, INDICATOR_DATA);
    ArrayInitialize(SigConfluence, 0.0);



    // Ocultar buffers auxiliares e manter apenas as waveforms visíveis
    for(int p=0; p<12; ++p)
      {
       PlotIndexSetInteger(p, PLOT_DRAW_TYPE, DRAW_LINE);
       PlotIndexSetString(p, PLOT_LABEL, StringFormat("Wave%d", p+1));
       PlotIndexSetDouble(p, PLOT_EMPTY_VALUE, EMPTY_VALUE);
      }

    for(int p=12; p<24; ++p)
      {
       PlotIndexSetInteger(p, PLOT_DRAW_TYPE, DRAW_NONE);
       PlotIndexSetString(p, PLOT_LABEL, StringFormat("WavePeriod%d", (p-12)+1));
       PlotIndexSetDouble(p, PLOT_EMPTY_VALUE, EMPTY_VALUE);
      }

bool input_visibility[12] =
      {
       InpShowWave1,  InpShowWave2,  InpShowWave3,  InpShowWave4,
       InpShowWave5,  InpShowWave6,  InpShowWave7,  InpShowWave8,
       InpShowWave9,  InpShowWave10, InpShowWave11, InpShowWave12
      };


    // Cores padrão para as 12 waves
    color wave_colors[12] = {
        clrRed, clrOrangeRed, clrOrange, clrGold,
        clrYellow, clrChartreuse, clrLime, clrSpringGreen,
        clrAqua, clrDodgerBlue, clrBlueViolet, clrMagenta
    };

    for(int idx = 0; idx < 12; ++idx)
      {
       int plot_wave = idx;
       int plot_period = 12 + idx;
       g_wave_visible[idx] = input_visibility[idx];
       g_wave_colors[idx]  = wave_colors[idx];

       PlotIndexSetInteger(plot_wave, PLOT_DRAW_TYPE, g_wave_visible[idx] ? DRAW_LINE : DRAW_NONE);
       PlotIndexSetString(plot_wave, PLOT_LABEL, StringFormat("Wave%d", idx + 1));
       PlotIndexSetDouble(plot_wave, PLOT_EMPTY_VALUE, EMPTY_VALUE);
       PlotIndexSetInteger(plot_wave, PLOT_LINE_COLOR, 0, wave_colors[idx]);

       PlotIndexSetInteger(plot_period, PLOT_DRAW_TYPE, DRAW_NONE);
       PlotIndexSetString(plot_period, PLOT_LABEL, StringFormat("WavePeriod%d", idx + 1));
       PlotIndexSetDouble(plot_period, PLOT_EMPTY_VALUE, EMPTY_VALUE);
      }

    for(int p=36; p<=84; ++p)
      {
       PlotIndexSetInteger(p, PLOT_DRAW_TYPE, DRAW_NONE);
       PlotIndexSetDouble(p, PLOT_EMPTY_VALUE, EMPTY_VALUE);
      }

    IndicatorSetString(INDICATOR_SHORTNAME, "CyclePhase-12Cycles-v7.42-NEW");
    
    ArrayResize(price_data, InpFFTWindow); ArrayResize(detrended_data, InpFFTWindow);
    ArrayResize(trend_data, InpFFTWindow); ArrayResize(fft_real, InpFFTWindow);
    ArrayResize(fft_imag, InpFFTWindow); ArrayResize(spectrum, InpFFTWindow / 2);

    // Inicializar arrays de rastreamento de ciclos
    // IMPORTANTE: Per?odos reais v?m da FFT, n?o dos par?metros InpPeriodCycle1-8
    // (InpPeriodCycle1-8 s?o OFFSETS VISUAIS, n?o per?odos!)
    for(int c = 0; c < 12; c++) {
        g_cycle_periods[c] = 0;      // Ser? preenchido pela FFT
        g_cycle_etas[c] = 0;         // Ser? calculado ap?s FFT detectar per?odos
        g_cycle_start_bar[c] = 0;
        g_cycle_active[c] = false;   // Ser? ativado quando FFT detectar ciclos
    }

    // Inicializar sistema de ETA cient?fico (v7.51)
    for(int c = 0; c < 12; c++) {
        for(int h = 0; h < 5; h++) {
            g_bullish_phase_durations[c][h] = 0;
            g_bearish_phase_durations[c][h] = 0;
        }
        g_phase_change_count[c] = 0;
        g_dominant_indices[c] = 0;
    }


    // Inicializar CycleStates (v7.53)
    for(int c = 0; c < 12; c++) {
        g_cycle_states[c].main_tracker_idx = -1;
        g_cycle_states[c].leak_tracker_idx = -1;
        g_cycle_states[c].main_eta_continuous = 0.0;
        g_cycle_states[c].leak_bars_active = 0;
        g_cycle_states[c].is_leak_active = false;
        g_cycle_states[c].leak_start_time = 0;
            g_phase_duration_estimate[c][0] = 0.0;
            g_phase_duration_estimate[c][1] = 0.0;
        g_last_eta_seconds[c] = 0.0;
    }


    // Inicializar mapeamento estável dos slots
    for(int s=0; s<12; s++) g_slot_tracker_idx[s] = -1;

    // Inicializar estado de leakage auxiliar
    for(int c=0; c<12; c++) { g_aux_leak_tracker_idx[c] = -1; g_aux_leak_bars_active[c] = 0; g_aux_leak_gate_state[c] = 0; }

    // Inicializar sistema de CSV export (v7.54)
    if(InpExportToCSV) {        
        InitializeCSVExport();
    }

    // Inicializar hist?rico de transi??es
    for(int c = 0; c < 12; c++) {
        g_last_transitions[c].time = 0;
        g_last_transitions[c].bar_index = -1;
        g_last_transitions[c].old_state = 0;
        g_last_transitions[c].new_state = 0;
        g_last_transitions[c].period = 0;
        g_last_transitions[c].eta_at_change = 0;
    }

    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Fun??o auxiliar para calcular um ciclo                           |
//+------------------------------------------------------------------+
void CalculateCycle(int i, const double &price_array[], double &cycle_buffer[], const double period)
{
    if(period <= 0 || i < 2) { cycle_buffer[i] = 0; return; }

    // --- CORRE??O "OUT OF RANGE" ---
    // O array 'price_array' ? o array de pre?os completo do gr?fico (ex: 'close').
    // Os ?ndices i, i-1, e i-2 s?o v?lidos neste contexto.
    double p_i   = price_array[i];
    double p_i_1 = price_array[i-1];
    double p_i_2 = price_array[i-2];

    // Acessar valores anteriores do pr?prio buffer de ciclo que est? sendo calculado.
    double c_i_1 = cycle_buffer[i-1];
    double c_i_2 = cycle_buffer[i-2];

    // --- L?gica do filtro passa-banda (inalterada) ---
    double omega = 2.0 * M_PI / period;
    double bw = fmax(0.01, fmin(0.49, InpBandwidth));
    double alpha_filter = sin(omega) * sinh(log(2.0) / 2.0 * bw * omega / sin(omega));
    double b0 = alpha_filter, b1 = 0, b2 = -alpha_filter;
    double a0 = 1.0 + alpha_filter, a1 = -2.0 * cos(omega), a2 = 1.0 - alpha_filter;
    b0 /= a0; b1 /= a0; b2 /= a0; a1 /= a0; a2 /= a0;
    
    // C?lculo final usando as vari?veis seguras
    cycle_buffer[i] = b0 * p_i + b1 * p_i_1 + b2 * p_i_2 - a1 * c_i_1 - a2 * c_i_2;
}

//+------------------------------------------------------------------+
//| ASYMMETRIC ETA HELPER FUNCTIONS (v7.49)                         |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Store phase duration in historical tracking array               |
//+------------------------------------------------------------------+
void StorePhaseHistory(int cycle_idx, bool is_bullish, int duration)
{
    if(cycle_idx < 0 || cycle_idx >= 12) return;
    if(duration < 1) return;

    if(is_bullish) {
        for(int i = 4; i > 0; i--) {
            g_bullish_phase_durations[cycle_idx][i] = g_bullish_phase_durations[cycle_idx][i-1];
        }
        g_bullish_phase_durations[cycle_idx][0] = duration;
    } else {
        for(int i = 4; i > 0; i--) {
            g_bearish_phase_durations[cycle_idx][i] = g_bearish_phase_durations[cycle_idx][i-1];
        }
        g_bearish_phase_durations[cycle_idx][0] = duration;
    }

    int orientation = is_bullish ? 0 : 1;
    g_phase_duration_estimate[cycle_idx][orientation] = (double)duration;
}


//+------------------------------------------------------------------+
//| Calculate median of historical phase durations                   |
//+------------------------------------------------------------------+
int GetMedianPhaseDuration(int cycle_idx, bool is_bullish)
{
    if(cycle_idx < 0 || cycle_idx >= 12) return 0;

    // Collect valid (non-zero) values directly from global array
    int valid_values[];
    int valid_count = 0;

    for(int i = 0; i < 5; i++) {
        int value = is_bullish ? g_bullish_phase_durations[cycle_idx][i] : g_bearish_phase_durations[cycle_idx][i];

        if(value > 0) {
            ArrayResize(valid_values, valid_count + 1);
            valid_values[valid_count] = value;
            valid_count++;
        }
    }

    if(valid_count == 0) return 0;

    ArraySort(valid_values);

        int median_idx = valid_count / 2;
    return valid_values[median_idx];
}

double EstimatePhaseDuration(int cycle_idx, bool is_bullish, double period, int bars_completed)
{
    if(cycle_idx < 0 || cycle_idx >= 12)
        return MathMax(1.0, (double)bars_completed);

    int orientation = is_bullish ? 0 : 1;
    double estimate = g_phase_duration_estimate[cycle_idx][orientation];

    if(estimate <= 0.0)
    {
        int median = GetMedianPhaseDuration(cycle_idx, is_bullish);
        if(median > 0)
            estimate = (double)median;
    }

    if(estimate <= 0.0)
    {
        int opposite_median = GetMedianPhaseDuration(cycle_idx, !is_bullish);
        if(opposite_median > 0)
            estimate = (double)opposite_median;
    }

    if(estimate <= 0.0 && period > 0.0)
        estimate = period;

    if(estimate <= 0.0)
        estimate = MathMax(1.0, (double)bars_completed);

    if(period > 0.0 && estimate > period * 2.0)
        estimate = period * 2.0;

    if(estimate < (double)bars_completed)
        estimate = (double)bars_completed;

    if(estimate < 1.0)
        estimate = 1.0;

    return estimate;
}

//+------------------------------------------------------------------+
//| Count bars in current phase (backwards from bar i)              |
//+------------------------------------------------------------------+
int CountBarsInCurrentPhase(int bar_idx, const double &color_buffer[])
{
    if(bar_idx < 0) return 0;

    double current_color = color_buffer[bar_idx];
    int count = 1;

    // Count backwards while color is the same
    for(int lookback = bar_idx - 1; lookback >= 0; lookback--) {
        if(color_buffer[lookback] == current_color) {
            count++;
        } else {
            break;  // Color changed, stop counting
        }
    }

    return count;
}

//+------------------------------------------------------------------+
//| Atualiza cor e ETA para um ciclo ativo                           |
//+------------------------------------------------------------------+
void UpdateCycleEtaAndState(int i, int c, const double &cycle_buffer[], double &color_buffer[], double &eta_buffer[], double &eta_raw_buffer[], double seconds_per_bar)
{
    if(seconds_per_bar <= 0.0)
        seconds_per_bar = (double)PeriodSeconds((ENUM_TIMEFRAMES)_Period);
    if(seconds_per_bar <= 0.0)
        seconds_per_bar = 60.0;

    if(i < 1)
    {
        bool start_bullish = (cycle_buffer[i] >= 0.0);
        color_buffer[i] = start_bullish ? 1.0 : 0.0;
        eta_buffer[i] = 0.0;
        eta_raw_buffer[i] = 0.0;
        g_cycle_states[c].main_eta_continuous = 0.0;
        g_last_eta_seconds[c] = 0.0;
        return;
    }

    double prev_color = color_buffer[i-1];
    bool was_bullish = (prev_color > 0.5);

    bool is_bullish = (cycle_buffer[i] >= cycle_buffer[i-1]);
    color_buffer[i] = is_bullish ? 1.0 : 0.0;

    double period_bars = g_dominant_periods[c];
    int effective_fft_index = g_dominant_indices[c];

    if(period_bars <= 0.0)
    {
        eta_buffer[i] = 0.0;
        eta_raw_buffer[i] = 0.0;
        g_cycle_states[c].main_eta_continuous = 0.0;
        g_last_eta_seconds[c] = 0.0;
        return;
    }

    double eta_seconds = 0.0;
    int bars_in_current_phase = CountBarsInCurrentPhase(i, color_buffer);
    if(InpETAMode == ETA_PHASE_NEXT_EXTREMUM)
    {
        eta_seconds = ComputeETA_PhaseNextExtremum(i, c, cycle_buffer, period_bars, seconds_per_bar);
    }
    else if(InpETAMode == ETA_REALFFT)
    {
        eta_seconds = ComputeETA_RealFFT(effective_fft_index, period_bars, InpFFTWindow, seconds_per_bar);
    }
    else
    {
        double target_phase_bars = EstimatePhaseDuration(c, is_bullish, period_bars, bars_in_current_phase);
        if(target_phase_bars < 1.0)
            target_phase_bars = 1.0;
        if(target_phase_bars < (double)bars_in_current_phase)
            target_phase_bars = (double)bars_in_current_phase;

        double target_phase_seconds = target_phase_bars * seconds_per_bar;

        double elapsed_seconds = (double)bars_in_current_phase * seconds_per_bar;
        double phase_progress = (target_phase_seconds > 0.0)
                                ? MathMin(1.0, elapsed_seconds / target_phase_seconds)
                                : 0.0;

        double eta_scientific_seconds = 0.0;
        if(effective_fft_index > 0 && effective_fft_index < ArraySize(fft_group_delay))
            eta_scientific_seconds = CalculateScientificETASeconds(effective_fft_index, target_phase_seconds, phase_progress, seconds_per_bar);

        int estimated_duration = GetMedianPhaseDuration(c, is_bullish);
        double eta_structural_remaining_seconds = MathMax(0.0, target_phase_seconds - elapsed_seconds);
        double eta_history_remaining_seconds = -1.0;
        if(estimated_duration > 0)
            eta_history_remaining_seconds = MathMax(0.0, (double)estimated_duration * seconds_per_bar - elapsed_seconds);

        double weight_sum = 0.0;
        if(target_phase_seconds > 0.0) { eta_seconds += eta_structural_remaining_seconds * 0.5; weight_sum += 0.5; }
        if(eta_history_remaining_seconds >= 0.0) { eta_seconds += eta_history_remaining_seconds * 0.35; weight_sum += 0.35; }
        if(eta_scientific_seconds > 0.0) { eta_seconds += eta_scientific_seconds * 0.15; weight_sum += 0.15; }
        if(weight_sum > 0.0) eta_seconds /= weight_sum; else eta_seconds = eta_structural_remaining_seconds;

        if(eta_seconds < 0.0) eta_seconds = 0.0;
        double max_ref_seconds = target_phase_seconds;
        double estimated_duration_seconds = (double)estimated_duration * seconds_per_bar;
        if(estimated_duration > 0 && estimated_duration_seconds > max_ref_seconds) max_ref_seconds = estimated_duration_seconds;
        double period_seconds = period_bars * seconds_per_bar;
        if(period_seconds > max_ref_seconds) max_ref_seconds = period_seconds;
        if(max_ref_seconds <= 0.0) max_ref_seconds = seconds_per_bar;
        double max_eta_seconds = max_ref_seconds * 1.5;
        if(eta_seconds > max_eta_seconds) eta_seconds = max_eta_seconds;
    }

    bool color_changed = (color_buffer[i] != prev_color);
    double prev_eta_seconds = g_last_eta_seconds[c];

    if(color_changed)
    {
        int prev_phase_duration = CountBarsInCurrentPhase(i-1, color_buffer);
        StorePhaseHistory(c, was_bullish, prev_phase_duration);
        g_phase_change_count[c]++;
    }
    else if(prev_eta_seconds > 0.0)
    {
        double expected_seconds = MathMax(0.0, prev_eta_seconds - seconds_per_bar);
        if(eta_seconds > expected_seconds)
            eta_seconds = expected_seconds;
    }

    double eta_bars = (seconds_per_bar > 0.0) ? (eta_seconds / seconds_per_bar) : 0.0;

    double eta_signed = (color_buffer[i] > 0.5) ? eta_bars : -eta_bars;
    eta_raw_buffer[i] = eta_signed;

    double eta_display = eta_signed;
    if(color_buffer[i] > 0.5 && eta_display >= 0.0 && eta_display < 1.0)
        eta_display = 1.0;

    eta_buffer[i] = eta_display;
    g_cycle_states[c].main_eta_continuous = eta_seconds;
    g_last_eta_seconds[c] = eta_seconds;
}

//+------------------------------------------------------------------+
//| Fun??o de itera??o do indicador customizado                      |
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
    PrintFormat("[GPU_WaveViz] OnCalculate start: rates_total=%d prev_calculated=%d", rates_total, prev_calculated);
    // Depuraï¿½ï¿½o inicial do OnCalculate
    static int calculateCount = 0;
    static datetime lastCalculateLog = 0;
    static bool s_history_complete = false;
    static int  s_history_cursor   = 0;
    calculateCount++;

    if (calculateCount == 1 || (TimeCurrent() - lastCalculateLog) > 300)
    {


        lastCalculateLog = TimeCurrent();
    }


    int chunk = (int)MathMax(1, InpHistoryChunk);
    int start = 0;
    int end_index = rates_total;
    int effective_prev = prev_calculated;
    int history_limit = (InpHistoryMaxBars <= 0) ? 0 : InpHistoryMaxBars;
    int history_start = (history_limit > 0 && rates_total > history_limit) ? rates_total - history_limit : 0;

    PrintFormat("[GPU_WaveViz] Step: history window prepared (chunk=%d history_start=%d history_limit=%d)", chunk, history_start, history_limit);

    EnsureRawBuffersSize(rates_total);
    EnsureAuxBuffersSize(rates_total);

    if(prev_calculated == 0)
    {
        // Primeira execucao ou reset - inicializar todos os buffers
        ArrayInitialize(EtaCycle1, 0.0);  ArrayInitialize(EtaCycle2, 0.0);
        ArrayInitialize(EtaCycle3, 0.0);  ArrayInitialize(EtaCycle4, 0.0);
        ArrayInitialize(EtaCycle5, 0.0);  ArrayInitialize(EtaCycle6, 0.0);
        ArrayInitialize(EtaCycle7, 0.0);  ArrayInitialize(EtaCycle8, 0.0);
        ArrayInitialize(EtaCycle9, 0.0);  ArrayInitialize(EtaCycle10, 0.0);
        ArrayInitialize(EtaCycle11, 0.0); ArrayInitialize(EtaCycle12, 0.0);

        ArrayInitialize(EtaRawCycle1, 0.0);  ArrayInitialize(EtaRawCycle2, 0.0);
        ArrayInitialize(EtaRawCycle3, 0.0);  ArrayInitialize(EtaRawCycle4, 0.0);
        ArrayInitialize(EtaRawCycle5, 0.0);  ArrayInitialize(EtaRawCycle6, 0.0);
        ArrayInitialize(EtaRawCycle7, 0.0);  ArrayInitialize(EtaRawCycle8, 0.0);
        ArrayInitialize(EtaRawCycle9, 0.0);  ArrayInitialize(EtaRawCycle10, 0.0);
        ArrayInitialize(EtaRawCycle11,0.0);  ArrayInitialize(EtaRawCycle12,0.0);

        ArrayInitialize(WaveBuffer1, 0.0);   ArrayInitialize(WaveBuffer2, 0.0);
        ArrayInitialize(WaveBuffer3, 0.0);   ArrayInitialize(WaveBuffer4, 0.0);
        ArrayInitialize(WaveBuffer5, 0.0);   ArrayInitialize(WaveBuffer6, 0.0);
        ArrayInitialize(WaveBuffer7, 0.0);   ArrayInitialize(WaveBuffer8, 0.0);
        ArrayInitialize(WaveBuffer9, 0.0);   ArrayInitialize(WaveBuffer10, 0.0);
        ArrayInitialize(WaveBuffer11, 0.0);  ArrayInitialize(WaveBuffer12, 0.0);

        ArrayInitialize(WavePeriodBuffer1, 0.0);  ArrayInitialize(WavePeriodBuffer2, 0.0);
        ArrayInitialize(WavePeriodBuffer3, 0.0);  ArrayInitialize(WavePeriodBuffer4, 0.0);
        ArrayInitialize(WavePeriodBuffer5, 0.0);  ArrayInitialize(WavePeriodBuffer6, 0.0);
        ArrayInitialize(WavePeriodBuffer7, 0.0);  ArrayInitialize(WavePeriodBuffer8, 0.0);
        ArrayInitialize(WavePeriodBuffer9, 0.0);  ArrayInitialize(WavePeriodBuffer10, 0.0);
        ArrayInitialize(WavePeriodBuffer11,0.0);  ArrayInitialize(WavePeriodBuffer12,0.0);

        ArrayInitialize(ColorBuffer1, 0.0);  ArrayInitialize(ColorBuffer2, 0.0);
        ArrayInitialize(ColorBuffer3, 0.0);  ArrayInitialize(ColorBuffer4, 0.0);
        ArrayInitialize(ColorBuffer5, 0.0);  ArrayInitialize(ColorBuffer6, 0.0);
        ArrayInitialize(ColorBuffer7, 0.0);  ArrayInitialize(ColorBuffer8, 0.0);
        ArrayInitialize(ColorBuffer9, 0.0);  ArrayInitialize(ColorBuffer10, 0.0);
        ArrayInitialize(ColorBuffer11,0.0);  ArrayInitialize(ColorBuffer12,0.0);

        ArrayInitialize(LeakETA1, 0.0);  ArrayInitialize(LeakETA2, 0.0);
        ArrayInitialize(LeakETA3, 0.0);  ArrayInitialize(LeakETA4, 0.0);
        ArrayInitialize(LeakETA5, 0.0);  ArrayInitialize(LeakETA6, 0.0);
        ArrayInitialize(LeakETA7, 0.0);  ArrayInitialize(LeakETA8, 0.0);
        ArrayInitialize(LeakETA9, 0.0);  ArrayInitialize(LeakETA10, 0.0);
        ArrayInitialize(LeakETA11,0.0);  ArrayInitialize(LeakETA12,0.0);

        ArrayInitialize(SigBuffer1, 0.0);  ArrayInitialize(SigBuffer2, 0.0);
        ArrayInitialize(SigBuffer3, 0.0);  ArrayInitialize(SigBuffer4, 0.0);
        ArrayInitialize(SigBuffer5, 0.0);  ArrayInitialize(SigBuffer6, 0.0);
        ArrayInitialize(SigBuffer7, 0.0);  ArrayInitialize(SigBuffer8, 0.0);
        ArrayInitialize(SigBuffer9, 0.0);  ArrayInitialize(SigBuffer10, 0.0);
        ArrayInitialize(SigBuffer11,0.0);  ArrayInitialize(SigBuffer12,0.0);

        ArrayResize(g_period_trackers, 0);
        g_tracker_count = 0;

        for(int c = 0; c < 12; c++)
        {
            g_cycle_active[c] = false;
            g_dominant_periods[c] = 0.0;
            g_dominant_indices[c] = 0;
            g_cycle_states[c].main_tracker_idx = -1;
            g_cycle_states[c].leak_tracker_idx = -1;
            g_cycle_states[c].main_eta_continuous = 0.0;
            g_cycle_states[c].leak_bars_active = 0;
            g_cycle_states[c].is_leak_active = false;
            g_cycle_states[c].leak_start_time = 0;
            g_phase_duration_estimate[c][0] = 0.0;
            g_phase_duration_estimate[c][1] = 0.0;
            g_sig_last_dir[c] = 0;
            g_sig_last_bar[c] = -1;
            g_phase_change_count[c] = 0;
            g_cycle_periods[c] = 0.0;
            g_cycle_etas[c] = 0.0;
            g_cycle_start_bar[c] = 0;

            for(int h = 0; h < 5; h++)
            {
                g_bullish_phase_durations[c][h] = 0;
                g_bearish_phase_durations[c][h] = 0;
            }

            g_last_transitions[c].time = 0;
            g_last_transitions[c].bar_index = -1;
            g_last_transitions[c].old_state = 0;
            g_last_transitions[c].new_state = 0;
            g_last_transitions[c].period = 0;
            g_last_transitions[c].eta_at_change = 0;
            g_last_eta_seconds[c] = 0.0;
        }

        g_ff_state.mode = FF_WAITING_PEAK;
        g_ff_state.active_cycle = -1;
        g_ff_state.active_period = 0.0;
        g_ff_state.active_eta_start = 0.0;
        g_ff_state.entry_time = 0;
        g_ff_state.entry_bar = 0;
        g_ff_state.bars_in_position = 0;
        g_ff_state.peak_found = false;
        g_ff_state.valley_found = false;

        ArrayInitialize(SigConfluence, 0.0);
        g_csv_last_bar = -1;
        g_reset_state_cache = true;
        s_history_cursor = history_start;
        s_history_complete = (rates_total <= history_start);

        // Reset slots estáveis
        for(int s=0; s<12; s++) g_slot_tracker_idx[s] = -1;

        // Reset leakage auxiliar
        for(int c=0; c<12; c++) { g_aux_leak_tracker_idx[c] = -1; g_aux_leak_bars_active[c] = 0; g_aux_leak_gate_state[c] = 0; }
    }
    else
    {
        if(effective_prev > rates_total)
            effective_prev = rates_total;
        if(effective_prev < history_start)
            effective_prev = history_start;
    }

    if(rates_total <= 0)
        return(0);

    if(!s_history_complete)
    {
        if(s_history_cursor > rates_total)
            s_history_cursor = rates_total;
        if(s_history_cursor < history_start)
            s_history_cursor = history_start;

        start = s_history_cursor;
        if(start < history_start)
            start = history_start;

        end_index = (int)MathMin(rates_total, s_history_cursor + chunk);
        s_history_cursor = end_index;

        if(end_index >= rates_total)
            s_history_complete = true;
    }
    else
    {
        start = (int)MathMax(effective_prev - 1, history_start);
        end_index = rates_total;
    }

    // Loop padrÃ£o do OnCalculate
    bool logged_price_source   = false;
    bool logged_trend_filter   = false;
    bool logged_windowing      = false;
    bool logged_fft            = false;
    bool logged_phase_analysis = false;
    bool logged_cycle_scan     = false;
    bool logged_tracker_update = false;
    bool logged_leak           = false;
    bool logged_state_update   = false;
    bool logged_follow_first   = false;
    bool logged_export         = false;
    int processed_bars = 0;
    for(int i = start; i < end_index && !IsStopped(); i++)
    {
        //--- 1. Obter os dados de preï¿½o
        int start_pos = i - InpFFTWindow + 1;
        if(start_pos < 0)
            continue;

        switch(InpAppliedPrice)
        {
            case FFT_PRICE_CLOSE:     ArrayCopy(price_data, close, 0, start_pos, InpFFTWindow); break;
            case FFT_PRICE_OPEN:      ArrayCopy(price_data, open,  0, start_pos, InpFFTWindow); break;
            case FFT_PRICE_HIGH:      ArrayCopy(price_data, high,  0, start_pos, InpFFTWindow); break;
            case FFT_PRICE_LOW:       ArrayCopy(price_data, low,   0, start_pos, InpFFTWindow); break;
            case FFT_PRICE_MEDIAN:    for(int j=0; j<InpFFTWindow; j++) price_data[j] = (high[start_pos+j] + low[start_pos+j]) / 2.0; break;
            case FFT_PRICE_TYPICAL:   for(int j=0; j<InpFFTWindow; j++) price_data[j] = (high[start_pos+j] + low[start_pos+j] + close[start_pos+j]) / 3.0; break;
            case FFT_PRICE_WEIGHTED:  for(int j=0; j<InpFFTWindow; j++) price_data[j] = (high[start_pos+j] + low[start_pos+j] + 2*close[start_pos+j]) / 4.0; break;
            case FFT_PRICE_ZIGZAG:
              {
                ENUM_TIMEFRAMES zig_tf = GetActiveZigZagTimeframe();
                if(!BuildZigZagPriceSeries(start_pos, high, low, time, InpZigZagSeriesMode, zig_tf))
                    continue;
                if(!logged_price_source)
                {
                    PrintFormat("[GPU_WaveViz] Step: ZigZag price series populated (mode=%d source=%d timeframe=%d)", (int)InpZigZagSeriesMode, (int)InpZigZagSource, (int)zig_tf);
                    logged_price_source = true;
                }
                break;
              }
            default:
                ArrayCopy(price_data, close, 0, start_pos, InpFFTWindow);
                if(!logged_price_source)
                {
                    PrintFormat("[GPU_WaveViz] Step: price series populated using applied price mode=%d", (int)InpAppliedPrice);
                    logged_price_source = true;
                }
                break;
        }
        processed_bars++;

        //--- 2. APLICAï¿½ï¿½O DO FILTRO DE TENDï¿½NCIA (PRï¿½-FILTRAGEM)
        double omega = 2.0 * M_PI / InpTrendPeriod;
        double alpha = (1.0 - sin(omega)) / cos(omega);
        double c = (1.0 - alpha) / 2.0;
        trend_data[0] = c * (price_data[0] + price_data[0]);
        trend_data[1] = c * (price_data[1] + price_data[0]) + alpha * trend_data[0];
        for(int j = 2; j < InpFFTWindow; j++)
        {
            trend_data[j] = c * (price_data[j] + price_data[j-1]) + alpha * trend_data[j-1];
        }
        for(int j = 0; j < InpFFTWindow; j++)
        {
            detrended_data[j] = price_data[j] - trend_data[j];
        }

        if(!logged_trend_filter)
        {
            PrintFormat("[GPU_WaveViz] Step: trend filter applied (period=%d)", InpTrendPeriod);
            logged_trend_filter = true;
        }

        //--- 3. Aplicar Windowing Function ANTES da FFT para reduzir spectral leakage
        ApplyWindow(detrended_data, InpFFTWindow, InpWindowType);

        if(!logged_windowing)
        {
            PrintFormat("[GPU_WaveViz] Step: window function applied (type=%d)", (int)InpWindowType);
            logged_windowing = true;
        }

        bool used_gpu_fft = false;
        static bool gpu_warning_logged = false;
        if(g_gpu_waveform_session_initialized)
        {
            if(g_gpu_waveform_last_length != InpFFTWindow)
            {
                if(!EnsureWaveformGpuConfigured(InpFFTWindow))
                {
                    Print("[GPU] Configuration failed. Reverting to CPU FFT.");
                    g_gpu_waveform_session_initialized = false;
                }
            }
            if(g_gpu_waveform_session_initialized)
            {
                int fft_status = RunWaveformFft(detrended_data, fft_real, fft_imag, InpFFTWindow);
                if(fft_status != GPU_STATUS_OK)
                {
                    PrintFormat("[GPU] RunWaveformFft failed: %d na barra %d. Reverting to CPU FFT.", fft_status, i);
                    g_gpu_waveform_session_initialized = false;
                    gpu_warning_logged = false;
                }
                else
                {
                    used_gpu_fft = true;
                    gpu_warning_logged = false;
                }
            }
        }

        if(!used_gpu_fft)
        {
            if(!gpu_warning_logged)
            {
                Print("[GPU] CPU FFT fallback ativo.");
                gpu_warning_logged = true;
            }
            FourierTransformManual(detrended_data, InpFFTWindow);
        }

        if(!logged_fft)
        {
            PrintFormat("[GPU_WaveViz] Step: FFT executed via %s (length=%d)", used_gpu_fft ? "GPU" : "CPU", InpFFTWindow);
            logged_fft = true;
        }

        int spectrum_size = InpFFTWindow / 2;
        for(int j = 0; j < spectrum_size; j++)
        {
            spectrum[j] = (fft_real[j] * fft_real[j]) + (fft_imag[j] * fft_imag[j]);
        }

        //--- 4b. SCIENTIFIC FFT PHASE ANALYSIS (v7.51 - NEW)
        // Calcular fase, unwrap e group delay para prediï¿½ï¿½o precisa
        CalculateFFTPhase(InpFFTWindow);
        UnwrapPhase(InpFFTWindow);
        CalculateGroupDelay(InpFFTWindow, 1.0); // sample_rate = 1.0 barra/sample

        if(!logged_phase_analysis)
        {
            Print("[GPU_WaveViz] Step: phase analysis completed (phase, unwrap, group delay)");
            logged_phase_analysis = true;
        }

        //--- 4c. Encontrar os Top 12 ciclos reais
        CycleInfo all_cycles[];
        int min_index = (int)ceil((double)InpFFTWindow / InpMaxPeriod);
        int max_index = (int)floor((double)InpFFTWindow / InpMinPeriod);
        int cycle_count = 0;
        for(int j = min_index; j <= max_index && j < spectrum_size; j++)
        {
            ArrayResize(all_cycles, cycle_count + 1);
            all_cycles[cycle_count].index = j;
            all_cycles[cycle_count].power = spectrum[j];
            cycle_count++;
        }

        if(!logged_cycle_scan)
        {
            PrintFormat("[GPU_WaveViz] Step: cycle scan completed (candidates=%d)", cycle_count);
            logged_cycle_scan = true;
        }

        //--- 5. PERSISTENT PERIOD TRACKING (v7.52 - NEW)
        // Ao invï¿½s de ordenar e perder identidade, fazemos MATCHING de perï¿½odos

        datetime current_time = time[i];

        // Para cada perï¿½odo detectado pela FFT
        for(int j = 0; j < cycle_count; j++)
        {
            double period = (all_cycles[j].index > 0) ? (double)InpFFTWindow / all_cycles[j].index : 0;
            if(period <= 0) continue;

            int fft_index = all_cycles[j].index;
            double power = all_cycles[j].power;

            // Tentar encontrar tracker existente para este perï¿½odo
            int tracker_idx = FindClosestTracker(period, InpTrackerTolerance);

            if(tracker_idx >= 0)
            {
                // ATUALIZAR tracker existente
                UpdateTracker(tracker_idx, period, fft_index, power, current_time);
            }
            else
            {
                // CRIAR novo tracker
                AddTracker(period, fft_index, power, current_time);
            }
        }

        // Marcar trackers nï¿½o vistos como inativos
        DeactivateUnseenTrackers(current_time);

        // Atualizar slots Dominant 1..12 com mapeamento estável
        UpdateStableSlots();

        // Detectar leakages (intrusï¿½es temporï¿½rias) (v7.53)
        DetectLeakages();

        if(!logged_tracker_update)
        {
            Print("[GPU_WaveViz] Step: tracker pool updated (match/deactivate/slots)");
            logged_tracker_update = true;
        }

        if(!logged_leak)
        {
            Print("[GPU_WaveViz] Step: leakage detection executed");
            logged_leak = true;
        }

        double seconds_per_bar = GetSecondsPerBar(i, time);

        //--- 6. Atualizar ciclos dominantes (Top-12 por poder)
        if(g_cycle_active[0])  { CalculateCycle(i, close, WaveBuffer1,  g_dominant_periods[0]);  UpdateCycleEtaAndState(i, 0,  WaveBuffer1,  ColorBuffer1,  EtaCycle1,  EtaRawCycle1,  seconds_per_bar); WavePeriodBuffer1[i]  = g_dominant_periods[0]; }  else { WaveBuffer1[i]  = 0.0; EtaCycle1[i]  = 0.0; EtaRawCycle1[i]  = 0.0; ColorBuffer1[i]  = 0.0; WavePeriodBuffer1[i]  = 0.0; g_last_eta_seconds[0] = 0.0; }
        if(g_cycle_active[1])  { CalculateCycle(i, close, WaveBuffer2,  g_dominant_periods[1]);  UpdateCycleEtaAndState(i, 1,  WaveBuffer2,  ColorBuffer2,  EtaCycle2,  EtaRawCycle2,  seconds_per_bar); WavePeriodBuffer2[i]  = g_dominant_periods[1]; }  else { WaveBuffer2[i]  = 0.0; EtaCycle2[i]  = 0.0; EtaRawCycle2[i]  = 0.0; ColorBuffer2[i]  = 0.0; WavePeriodBuffer2[i]  = 0.0; g_last_eta_seconds[1] = 0.0; }
        if(g_cycle_active[2])  { CalculateCycle(i, close, WaveBuffer3,  g_dominant_periods[2]);  UpdateCycleEtaAndState(i, 2,  WaveBuffer3,  ColorBuffer3,  EtaCycle3,  EtaRawCycle3,  seconds_per_bar); WavePeriodBuffer3[i]  = g_dominant_periods[2]; }  else { WaveBuffer3[i]  = 0.0; EtaCycle3[i]  = 0.0; EtaRawCycle3[i]  = 0.0; ColorBuffer3[i]  = 0.0; WavePeriodBuffer3[i]  = 0.0; g_last_eta_seconds[2] = 0.0; }
        if(g_cycle_active[3])  { CalculateCycle(i, close, WaveBuffer4,  g_dominant_periods[3]);  UpdateCycleEtaAndState(i, 3,  WaveBuffer4,  ColorBuffer4,  EtaCycle4,  EtaRawCycle4,  seconds_per_bar); WavePeriodBuffer4[i]  = g_dominant_periods[3]; }  else { WaveBuffer4[i]  = 0.0; EtaCycle4[i]  = 0.0; EtaRawCycle4[i]  = 0.0; ColorBuffer4[i]  = 0.0; WavePeriodBuffer4[i]  = 0.0; g_last_eta_seconds[3] = 0.0; }
        if(g_cycle_active[4])  { CalculateCycle(i, close, WaveBuffer5,  g_dominant_periods[4]);  UpdateCycleEtaAndState(i, 4,  WaveBuffer5,  ColorBuffer5,  EtaCycle5,  EtaRawCycle5,  seconds_per_bar); WavePeriodBuffer5[i]  = g_dominant_periods[4]; }  else { WaveBuffer5[i]  = 0.0; EtaCycle5[i]  = 0.0; EtaRawCycle5[i]  = 0.0; ColorBuffer5[i]  = 0.0; WavePeriodBuffer5[i]  = 0.0; g_last_eta_seconds[4] = 0.0; }
        if(g_cycle_active[5])  { CalculateCycle(i, close, WaveBuffer6,  g_dominant_periods[5]);  UpdateCycleEtaAndState(i, 5,  WaveBuffer6,  ColorBuffer6,  EtaCycle6,  EtaRawCycle6,  seconds_per_bar); WavePeriodBuffer6[i]  = g_dominant_periods[5]; }  else { WaveBuffer6[i]  = 0.0; EtaCycle6[i]  = 0.0; EtaRawCycle6[i]  = 0.0; ColorBuffer6[i]  = 0.0; WavePeriodBuffer6[i]  = 0.0; g_last_eta_seconds[5] = 0.0; }
        if(g_cycle_active[6])  { CalculateCycle(i, close, WaveBuffer7,  g_dominant_periods[6]);  UpdateCycleEtaAndState(i, 6,  WaveBuffer7,  ColorBuffer7,  EtaCycle7,  EtaRawCycle7,  seconds_per_bar); WavePeriodBuffer7[i]  = g_dominant_periods[6]; }  else { WaveBuffer7[i]  = 0.0; EtaCycle7[i]  = 0.0; EtaRawCycle7[i]  = 0.0; ColorBuffer7[i]  = 0.0; WavePeriodBuffer7[i]  = 0.0; g_last_eta_seconds[6] = 0.0; }
        if(g_cycle_active[7])  { CalculateCycle(i, close, WaveBuffer8,  g_dominant_periods[7]);  UpdateCycleEtaAndState(i, 7,  WaveBuffer8,  ColorBuffer8,  EtaCycle8,  EtaRawCycle8,  seconds_per_bar); WavePeriodBuffer8[i]  = g_dominant_periods[7]; }  else { WaveBuffer8[i]  = 0.0; EtaCycle8[i]  = 0.0; EtaRawCycle8[i]  = 0.0; ColorBuffer8[i]  = 0.0; WavePeriodBuffer8[i]  = 0.0; g_last_eta_seconds[7] = 0.0; }
        if(g_cycle_active[8])  { CalculateCycle(i, close, WaveBuffer9,  g_dominant_periods[8]);  UpdateCycleEtaAndState(i, 8,  WaveBuffer9,  ColorBuffer9,  EtaCycle9,  EtaRawCycle9,  seconds_per_bar); WavePeriodBuffer9[i]  = g_dominant_periods[8]; }  else { WaveBuffer9[i]  = 0.0; EtaCycle9[i]  = 0.0; EtaRawCycle9[i]  = 0.0; ColorBuffer9[i]  = 0.0; WavePeriodBuffer9[i]  = 0.0; g_last_eta_seconds[8] = 0.0; }
        if(g_cycle_active[9])  { CalculateCycle(i, close, WaveBuffer10, g_dominant_periods[9]);  UpdateCycleEtaAndState(i, 9,  WaveBuffer10, ColorBuffer10, EtaCycle10, EtaRawCycle10, seconds_per_bar); WavePeriodBuffer10[i] = g_dominant_periods[9]; }  else { WaveBuffer10[i] = 0.0; EtaCycle10[i] = 0.0; EtaRawCycle10[i] = 0.0; ColorBuffer10[i] = 0.0; WavePeriodBuffer10[i] = 0.0; g_last_eta_seconds[9] = 0.0; }
        if(g_cycle_active[10]) { CalculateCycle(i, close, WaveBuffer11, g_dominant_periods[10]); UpdateCycleEtaAndState(i, 10, WaveBuffer11, ColorBuffer11, EtaCycle11, EtaRawCycle11, seconds_per_bar); WavePeriodBuffer11[i] = g_dominant_periods[10]; } else { WaveBuffer11[i] = 0.0; EtaCycle11[i] = 0.0; EtaRawCycle11[i] = 0.0; ColorBuffer11[i] = 0.0; WavePeriodBuffer11[i] = 0.0; g_last_eta_seconds[10] = 0.0; }
        if(g_cycle_active[11]) { CalculateCycle(i, close, WaveBuffer12, g_dominant_periods[11]); UpdateCycleEtaAndState(i, 11, WaveBuffer12, ColorBuffer12, EtaCycle12, EtaRawCycle12, seconds_per_bar); WavePeriodBuffer12[i] = g_dominant_periods[11]; } else { WaveBuffer12[i] = 0.0; EtaCycle12[i] = 0.0; EtaRawCycle12[i] = 0.0; ColorBuffer12[i] = 0.0; WavePeriodBuffer12[i] = 0.0; g_last_eta_seconds[11] = 0.0; }

        //--- 7. LEAK ETA AUX BUFFERS (NEW)
        PopulateLeakAuxBuffers_New(i);

        if(!logged_state_update)
        {
            Print("[GPU_WaveViz] Step: dominant cycles updated and auxiliary buffers refreshed");
            logged_state_update = true;
        }

        //--- 8. ESTADOS DERIVADOS DAS CORES (v7.60)
        double state_data[12];
        CollectCycleStates(i, state_data);
        DetectStateChanges(state_data);

        double state_data_prev[12];
        if(i > 0)
            CollectCycleStates(i - 1, state_data_prev);
        else
            ArrayInitialize(state_data_prev, 0.0);
//--- 9. FOLLOW THE FIRST (v7.55) ---
        // Gerenciar estado de SAï¿½DA (apenas na barra 0)
        double etas_current[12];
        for(int cff = 0; cff < 12; cff++)
            etas_current[cff] = GetEtaRawValue(cff, i);
        if (s_history_complete && i == rates_total - 1) ProcessFollowFirst(0, etas_current);

        // Gerenciar estado de ENTRADA (a cada barra)
        ProcessFollowFirstSignal(i, state_data, state_data_prev);

        if(!logged_follow_first)
        {
            Print("[GPU_WaveViz] Step: FollowTheFirst flow updated (exit/entry)");
            logged_follow_first = true;
        }

        // 9b. Debug panel + dynamic labels on last bar
        if(InpShowTrackerInfo && i == rates_total - 1)
        {
            ShowCycleListDebug();
            for(int c2 = 0; c2 < 12; c2++)
            {
                string lbl = g_cycle_active[c2] ? StringFormat("Dominant %d (P=%.1f)", c2+1, g_dominant_periods[c2])
                                                : StringFormat("Dominant %d", c2+1);
                PlotIndexSetString(c2, PLOT_LABEL, lbl);
            }
        }

        //--- 10. EXPORTAR PARA CSV (v7.54 - opcional)
        if(InpExportToCSV && i == 0)
        {
            ExportToCSV(time[i], i);
            if(!logged_export)
            {
                Print("[GPU_WaveViz] Step: CSV export executed for latest history chunk");
                logged_export = true;
            }
        }


    } // Fecha o loop for principal



    PrintFormat("[GPU_WaveViz] OnCalculate end: processed_bars=%d start=%d end_index=%d", processed_bars, start, end_index);
    return(end_index);
} // Fecha a fun??o OnCalculate
//+------------------------------------------------------------------+
//| Indicator deinitialization                                       |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    if(g_gpu_waveform_session_initialized)
    {
        GpuSessionClose();
        g_gpu_waveform_session_initialized = false;
        Print("[GPU] ✓ GPU Session closed successfully");
    }
    ResetZigZagHandles();
}
