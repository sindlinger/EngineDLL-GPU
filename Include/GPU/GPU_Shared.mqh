//+------------------------------------------------------------------+
//| GPU_Shared                                                       |
//| Shared buffers publicados pelo hub para indicadores/agents.     |
//+------------------------------------------------------------------+
#ifndef __WAVESPEC_SHARED_MQH__
#define __WAVESPEC_SHARED_MQH__

#include <GPU/GPU_Engine.mqh>

namespace GPUShared
  {
   datetime last_update   = 0;
   int      frame_count   = 0;
   int      frame_length  = 0;
   int      cycle_count   = 0;

  double   wave[];
  double   preview[];
  double   noise[];
  double   cycles[];
  double   cycle_periods[];
  double   phase[];
  double   amplitude[];
  double   period[];
  double   eta[];
  double   recon[];
  double   confidence[];
  double   amp_delta[];
  double   dominant_snr = 0.0;
  int      dominant_cycle = -1;

  GpuEngineResultInfo last_info;

  void EnsureSize(const int total,
                  const int cycles_total,
                  const int cycles_count)
    {
     ArrayResize(wave,    total);
     ArrayResize(preview, total);
     ArrayResize(noise,   total);
     ArrayResize(cycles,  cycles_total);
     ArrayResize(cycle_periods, cycles_count);
     ArrayResize(phase,      total);
     ArrayResize(amplitude,  total);
     ArrayResize(period,     total);
     ArrayResize(eta,        total);
     ArrayResize(recon,      total);
     ArrayResize(confidence, total);
     ArrayResize(amp_delta,  total);
    }

   void Publish(const double &wave_src[],
                const double &preview_src[],
                const double &noise_src[],
                const double &cycles_src[],
                const double &cycle_periods_src[],
                const double &phase_src[],
                const double &amplitude_src[],
                const double &period_src[],
                const double &eta_src[],
                const double &recon_src[],
                const double &confidence_src[],
                const double &amp_delta_src[],
                const GpuEngineResultInfo &info)
     {
      frame_count  = info.frame_count;
      frame_length = info.frame_length;
      cycle_count  = info.cycle_count;
      const int total = frame_count * frame_length;
      const int cycles_total = total * MathMax(cycle_count, 0);

      EnsureSize(total, cycles_total, cycle_count);

      ArrayCopy(wave,    wave_src,    0, 0, total);
      ArrayCopy(preview, preview_src, 0, 0, total);
      ArrayCopy(noise,   noise_src,   0, 0, total);
      if(cycles_total > 0)
        ArrayCopy(cycles, cycles_src, 0, 0, cycles_total);
      else
        ArrayResize(cycles, 0);

      if(cycle_count > 0 && ArraySize(cycle_periods_src) >= cycle_count)
         ArrayCopy(cycle_periods, cycle_periods_src, 0, 0, cycle_count);
      else
        {
         ArrayResize(cycle_periods, cycle_count);
         ArrayInitialize(cycle_periods, 0.0);
        }

      ArrayInitialize(phase,      EMPTY_VALUE);
      ArrayInitialize(amplitude,  EMPTY_VALUE);
      ArrayInitialize(period,     EMPTY_VALUE);
      ArrayInitialize(eta,        EMPTY_VALUE);
      ArrayInitialize(recon,      EMPTY_VALUE);
      ArrayInitialize(confidence, EMPTY_VALUE);
      ArrayInitialize(amp_delta,  EMPTY_VALUE);

      if(ArraySize(phase_src) >= total)
         ArrayCopy(phase,      phase_src,      0, 0, total);
      if(ArraySize(amplitude_src) >= total)
         ArrayCopy(amplitude,  amplitude_src,  0, 0, total);
      if(ArraySize(period_src) >= total)
         ArrayCopy(period,     period_src,     0, 0, total);
      if(ArraySize(eta_src) >= total)
         ArrayCopy(eta,        eta_src,        0, 0, total);
      if(ArraySize(recon_src) >= total)
         ArrayCopy(recon,      recon_src,      0, 0, total);
      if(ArraySize(confidence_src) >= total)
         ArrayCopy(confidence, confidence_src, 0, 0, total);
      if(ArraySize(amp_delta_src) >= total)
         ArrayCopy(amp_delta,  amp_delta_src,  0, 0, total);

      dominant_cycle = info.dominant_cycle;
      dominant_snr   = info.dominant_snr;

      last_info   = info;
      last_update = TimeCurrent();
     }
  }

#endif // __WAVESPEC_SHARED_MQH__
