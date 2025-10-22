//+------------------------------------------------------------------+
//| GPU Bridge Extended Wrapper                                      |
//| Centralises the exports made available by GpuBridge.dll for MQL5 |
//+------------------------------------------------------------------+
#ifndef __GPU_BRIDGE_EXTENDED_MQH__
#define __GPU_BRIDGE_EXTENDED_MQH__

#define GPU_STATUS_OK                    0
#define GPU_STATUS_NOT_INITIALISED      -1
#define GPU_STATUS_ALREADY_INITIALIZED  -2
#define GPU_STATUS_INVALID_ARGUMENT     -3
#define GPU_STATUS_DEVICE_ERROR         -4
#define GPU_STATUS_MEMORY_ERROR         -5
#define GPU_STATUS_PLAN_ERROR           -6
#define GPU_STATUS_EXECUTION_ERROR      -7
#define GPU_STATUS_NOT_CONFIGURED       -8
#define GPU_STATUS_UNSUPPORTED          -9
#define GPU_STATUS_INTERNAL_ERROR       -10

#import "GpuBridge.dll"
int  GpuSessionInit(int device_id);
void GpuSessionClose();

int  GpuConfigureWaveform(int length);
int  GpuConfigureBatchWaveform(int fft_size, int max_batch_count);
int  GpuConfigureSupDem(int capacity);
int  GpuConfigureCwt(int signal_len, int num_scales);

int  RunWaveformFft(double &values[], double &fft_real[], double &fft_imag[], int length);
int  RunWaveformIfft(double &fft_real[], double &fft_imag[], double &output[], int length);
int  RunBatchWaveformFft(const double &values[],
                         double &fft_real[],
                         double &fft_imag[],
                         int fft_size,
                         int batch_count);

int  RunSupDemVolume(const double &volume[],
                     const double &open[],
                     const double &high[],
                     const double &low[],
                     const double &close[],
                     double &media_out[],
                     double &banda_sup_out[],
                     int length,
                     int periodo_media,
                     double multip_desvio);

int  RunCwtOnGpu(const double &signal[],
                 const double &scales[],
                 int signal_len,
                 int num_scales,
                 int position,
                 double omega0,
                 int support_factor,
                 double &reconstruction_out[],
                 double &dominant_scale_out[]);

int  ComputeMagnitudeSpectrumGpu(const double &fft_real[],
                                 const double &fft_imag[],
                                 double &magnitude[],
                                 int length,
                                 int batch_count);

int  ComputePhaseSpectrumGpu(const double &fft_real[],
                             const double &fft_imag[],
                             double &phase[],
                             int length,
                             int batch_count);

int  ComputePowerSpectrumGpu(const double &fft_real[],
                             const double &fft_imag[],
                             double &power[],
                             int length,
                             int batch_count);

int  FindDominantFrequencyGpu(const double &magnitude[],
                              int length,
                              int batch_count,
                              int &dominant_indices[]);

int  ComputeTotalPowerGpu(const double &power_spectrum[],
                          int length,
                          int batch_count,
                          double &total_power[]);
#import

inline bool GpuStatusIsOk(const int status)
  {
   return (status == GPU_STATUS_OK || status == GPU_STATUS_ALREADY_INITIALIZED);
  }

#endif // __GPU_BRIDGE_EXTENDED_MQH__
