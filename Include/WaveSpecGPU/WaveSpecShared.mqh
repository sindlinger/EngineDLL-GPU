//+------------------------------------------------------------------+
//| WaveSpecShared                                                   |
//| Shared buffers published by the GPU hub for viewers/agents.     |
//+------------------------------------------------------------------+
#ifndef __WAVESPEC_SHARED_MQH__
#define __WAVESPEC_SHARED_MQH__

#include <WaveSpecGPU/GpuEngine.mqh>

namespace WaveSpecShared
  {
   datetime last_update   = 0;
   int      frame_count   = 0;
   int      frame_length  = 0;

   double   wave[];
   double   preview[];
   double   noise[];
   double   cycles[];

   GpuEngineResultInfo last_info;

   void EnsureSize(const int total)
     {
      ArrayResize(wave,    total);
      ArrayResize(preview, total);
      ArrayResize(noise,   total);
      ArrayResize(cycles,  total);
     }

   void Publish(const double &wave_src[],
                const double &preview_src[],
                const double &noise_src[],
                const double &cycles_src[],
                const GpuEngineResultInfo &info)
     {
      frame_count  = info.frame_count;
      frame_length = info.frame_length;
      const int total = frame_count * frame_length;

      EnsureSize(total);

      ArrayCopy(wave,    wave_src,    0, 0, total);
      ArrayCopy(preview, preview_src, 0, 0, total);
      ArrayCopy(noise,   noise_src,   0, 0, total);
      ArrayCopy(cycles,  cycles_src,  0, 0, total);

      last_info   = info;
      last_update = TimeCurrent();
     }
  }

#endif // __WAVESPEC_SHARED_MQH__
