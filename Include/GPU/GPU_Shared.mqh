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
  double   phase_unwrapped[];
  double   amplitude[];
  double   period[];
  double   frequency[];
  double   eta[];
  double   countdown[];
  double   recon[];
  double   kalman[];
  double   turn[];
  double   confidence[];
  double   amp_delta[];
  double   direction[];
  double   power[];
  double   velocity[];

  double   phase_all[];
  double   phase_unwrapped_all[];
  double   amplitude_all[];
  double   period_all[];
  double   frequency_all[];
  double   eta_all[];
  double   countdown_all[];
  double   direction_all[];
  double   recon_all[];
  double   kalman_all[];
  double   turn_all[];
  double   confidence_all[];
  double   amp_delta_all[];
  double   power_all[];
  double   velocity_all[];
  double   plv_cycles[];
  double   snr_cycles[];
  double   dominant_snr = 0.0;
  double   dominant_plv = 0.0;
  double   dominant_confidence = 0.0;
  double   line_phase_deg = 0.0;
  double   line_amplitude = 0.0;
  double   line_period = 0.0;
  double   line_eta = 0.0;
  double   line_confidence = 0.0;
  double   line_value = 0.0;
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
     ArrayResize(phase_unwrapped, total);
     ArrayResize(amplitude,  total);
     ArrayResize(period,     total);
     ArrayResize(frequency,  total);
     ArrayResize(eta,        total);
     ArrayResize(countdown,  total);
     ArrayResize(recon,      total);
     ArrayResize(kalman,     total);
     ArrayResize(turn,       total);
     ArrayResize(confidence, total);
     ArrayResize(amp_delta,  total);
      ArrayResize(direction,  total);
      ArrayResize(power,      total);
     ArrayResize(velocity,   total);
     ArrayResize(plv_cycles, cycles_count);
     ArrayResize(snr_cycles, cycles_count);

     ArrayResize(phase_all,            cycles_total);
     ArrayResize(phase_unwrapped_all,  cycles_total);
     ArrayResize(amplitude_all,        cycles_total);
     ArrayResize(period_all,           cycles_total);
     ArrayResize(frequency_all,        cycles_total);
     ArrayResize(eta_all,              cycles_total);
     ArrayResize(countdown_all,        cycles_total);
     ArrayResize(direction_all,        cycles_total);
     ArrayResize(recon_all,            cycles_total);
     ArrayResize(kalman_all,           cycles_total);
     ArrayResize(turn_all,             cycles_total);
     ArrayResize(confidence_all,       cycles_total);
     ArrayResize(amp_delta_all,        cycles_total);
     ArrayResize(power_all,            cycles_total);
     ArrayResize(velocity_all,         cycles_total);
    }

   void Publish(const double &wave_src[],
                const double &preview_src[],
                const double &noise_src[],
                const double &cycles_src[],
                const double &cycle_periods_src[],
                const double &phase_src[],
                const double &phase_unwrapped_src[],
                const double &amplitude_src[],
                const double &period_src[],
                const double &frequency_src[],
                const double &eta_src[],
                const double &countdown_src[],
                const double &recon_src[],
                const double &kalman_src[],
                const double &turn_src[],
                const double &confidence_src[],
                const double &amp_delta_src[],
                const double &direction_src[],
                const double &power_src[],
                const double &velocity_src[],
                const double &phase_all_src[],
                const double &phase_unwrapped_all_src[],
                const double &amplitude_all_src[],
                const double &period_all_src[],
                const double &frequency_all_src[],
                const double &eta_all_src[],
                const double &countdown_all_src[],
                const double &direction_all_src[],
                const double &recon_all_src[],
                const double &kalman_all_src[],
                const double &turn_all_src[],
                const double &confidence_all_src[],
                const double &amp_delta_all_src[],
                const double &power_all_src[],
                const double &velocity_all_src[],
                const double &plv_cycles_src[],
                const double &snr_cycles_src[],
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
      ArrayInitialize(phase_unwrapped, EMPTY_VALUE);
      ArrayInitialize(amplitude,  EMPTY_VALUE);
      ArrayInitialize(period,     EMPTY_VALUE);
      ArrayInitialize(frequency,  EMPTY_VALUE);
      ArrayInitialize(eta,        EMPTY_VALUE);
      ArrayInitialize(countdown,  EMPTY_VALUE);
      ArrayInitialize(recon,      EMPTY_VALUE);
      ArrayInitialize(kalman,     EMPTY_VALUE);
      ArrayInitialize(turn,       EMPTY_VALUE);
      ArrayInitialize(confidence, EMPTY_VALUE);
      ArrayInitialize(amp_delta,  EMPTY_VALUE);
      ArrayInitialize(direction,  EMPTY_VALUE);
     ArrayInitialize(power,      EMPTY_VALUE);
     ArrayInitialize(velocity,   EMPTY_VALUE);
      ArrayInitialize(plv_cycles, EMPTY_VALUE);
      ArrayInitialize(snr_cycles, EMPTY_VALUE);

      ArrayInitialize(phase_all,            EMPTY_VALUE);
      ArrayInitialize(phase_unwrapped_all,  EMPTY_VALUE);
      ArrayInitialize(amplitude_all,        EMPTY_VALUE);
      ArrayInitialize(period_all,           EMPTY_VALUE);
      ArrayInitialize(frequency_all,        EMPTY_VALUE);
      ArrayInitialize(eta_all,              EMPTY_VALUE);
      ArrayInitialize(countdown_all,        EMPTY_VALUE);
      ArrayInitialize(direction_all,        EMPTY_VALUE);
      ArrayInitialize(recon_all,            EMPTY_VALUE);
      ArrayInitialize(kalman_all,           EMPTY_VALUE);
      ArrayInitialize(turn_all,             EMPTY_VALUE);
      ArrayInitialize(confidence_all,       EMPTY_VALUE);
      ArrayInitialize(amp_delta_all,        EMPTY_VALUE);
      ArrayInitialize(power_all,            EMPTY_VALUE);
      ArrayInitialize(velocity_all,         EMPTY_VALUE);

      if(ArraySize(phase_src) >= total)
         ArrayCopy(phase,      phase_src,      0, 0, total);
      if(ArraySize(phase_unwrapped_src) >= total)
         ArrayCopy(phase_unwrapped, phase_unwrapped_src, 0, 0, total);
      if(ArraySize(amplitude_src) >= total)
         ArrayCopy(amplitude,  amplitude_src,  0, 0, total);
      if(ArraySize(period_src) >= total)
         ArrayCopy(period,     period_src,     0, 0, total);
      if(ArraySize(frequency_src) >= total)
         ArrayCopy(frequency,  frequency_src,  0, 0, total);
      if(ArraySize(eta_src) >= total)
         ArrayCopy(eta,        eta_src,        0, 0, total);
      if(ArraySize(countdown_src) >= total)
         ArrayCopy(countdown,  countdown_src,  0, 0, total);
      if(ArraySize(recon_src) >= total)
         ArrayCopy(recon,      recon_src,      0, 0, total);
      if(ArraySize(kalman_src) >= total)
         ArrayCopy(kalman,     kalman_src,     0, 0, total);
      if(ArraySize(turn_src) >= total)
         ArrayCopy(turn,       turn_src,       0, 0, total);
      if(ArraySize(confidence_src) >= total)
         ArrayCopy(confidence, confidence_src, 0, 0, total);
      if(ArraySize(amp_delta_src) >= total)
         ArrayCopy(amp_delta,  amp_delta_src,  0, 0, total);
      if(ArraySize(direction_src) >= total)
         ArrayCopy(direction,  direction_src,  0, 0, total);
      if(ArraySize(power_src) >= total)
         ArrayCopy(power,      power_src,      0, 0, total);
      if(ArraySize(velocity_src) >= total)
         ArrayCopy(velocity,   velocity_src,   0, 0, total);
      if(ArraySize(plv_cycles_src) >= cycle_count)
         ArrayCopy(plv_cycles, plv_cycles_src, 0, 0, cycle_count);
      if(ArraySize(snr_cycles_src) >= cycle_count)
         ArrayCopy(snr_cycles, snr_cycles_src, 0, 0, cycle_count);

      if(ArraySize(phase_all_src) >= cycles_total)
         ArrayCopy(phase_all, phase_all_src, 0, 0, cycles_total);
      if(ArraySize(phase_unwrapped_all_src) >= cycles_total)
         ArrayCopy(phase_unwrapped_all, phase_unwrapped_all_src, 0, 0, cycles_total);
      if(ArraySize(amplitude_all_src) >= cycles_total)
         ArrayCopy(amplitude_all, amplitude_all_src, 0, 0, cycles_total);
      if(ArraySize(period_all_src) >= cycles_total)
         ArrayCopy(period_all, period_all_src, 0, 0, cycles_total);
      if(ArraySize(frequency_all_src) >= cycles_total)
         ArrayCopy(frequency_all, frequency_all_src, 0, 0, cycles_total);
      if(ArraySize(eta_all_src) >= cycles_total)
         ArrayCopy(eta_all, eta_all_src, 0, 0, cycles_total);
      if(ArraySize(countdown_all_src) >= cycles_total)
         ArrayCopy(countdown_all, countdown_all_src, 0, 0, cycles_total);
      if(ArraySize(direction_all_src) >= cycles_total)
         ArrayCopy(direction_all, direction_all_src, 0, 0, cycles_total);
      if(ArraySize(recon_all_src) >= cycles_total)
         ArrayCopy(recon_all, recon_all_src, 0, 0, cycles_total);
      if(ArraySize(kalman_all_src) >= cycles_total)
         ArrayCopy(kalman_all, kalman_all_src, 0, 0, cycles_total);
      if(ArraySize(turn_all_src) >= cycles_total)
         ArrayCopy(turn_all, turn_all_src, 0, 0, cycles_total);
      if(ArraySize(confidence_all_src) >= cycles_total)
         ArrayCopy(confidence_all, confidence_all_src, 0, 0, cycles_total);
      if(ArraySize(amp_delta_all_src) >= cycles_total)
         ArrayCopy(amp_delta_all, amp_delta_all_src, 0, 0, cycles_total);
      if(ArraySize(power_all_src) >= cycles_total)
         ArrayCopy(power_all, power_all_src, 0, 0, cycles_total);
      if(ArraySize(velocity_all_src) >= cycles_total)
         ArrayCopy(velocity_all, velocity_all_src, 0, 0, cycles_total);

     dominant_cycle = info.dominant_cycle;
     dominant_snr   = info.dominant_snr;
     dominant_plv   = info.dominant_plv;
     dominant_confidence = info.dominant_confidence;
     line_phase_deg      = info.line_phase_deg;
     line_amplitude      = info.line_amplitude;
     line_period         = info.line_period;
     line_eta            = info.line_eta;
     line_confidence     = info.line_confidence;
     line_value          = info.line_value;

      last_info   = info;
      last_update = TimeCurrent();
     }
  }

#endif // __WAVESPEC_SHARED_MQH__
