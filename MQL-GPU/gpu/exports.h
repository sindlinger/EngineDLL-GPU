#pragma once

#ifdef _WIN32
#define GPU_EXPORT extern "C" __declspec(dllexport)
#else
#define GPU_EXPORT extern "C"
#endif

GPU_EXPORT int GpuSessionInit(int device_id);
GPU_EXPORT void GpuSessionClose();
GPU_EXPORT int GpuConfigureWaveform(int length);
GPU_EXPORT int GpuConfigureBatchWaveform(int fft_size, int max_batch_count);
GPU_EXPORT int RunWaveformFft(const double* input,
                              double* fft_real,
                              double* fft_imag,
                              int length);
GPU_EXPORT int RunWaveformIfft(const double* fft_real,
                               const double* fft_imag,
                               double* output,
                               int length);
GPU_EXPORT int GpuConfigureSupDem(int capacity);
GPU_EXPORT int RunSupDemVolume(const double* volume,
                               const double* open,
                               const double* high,
                               const double* low,
                               const double* close,
                               double* media_out,
                               double* banda_sup_out,
                               int length,
                               int periodo_media,
                               double multip_desvio);
GPU_EXPORT int GpuConfigureCwt(int signal_len, int num_scales);
GPU_EXPORT int RunCwtOnGpu(const double* signal,
                           const double* scales,
                           int signal_len,
                           int num_scales,
                           int position,
                           double omega0,
                           int support_factor,
                           double* reconstruction_out,
                           double* dominant_scale_out);
GPU_EXPORT int ComputeMagnitudeSpectrumGpu(const double* fft_real,
                                           const double* fft_imag,
                                           double* magnitude,
                                           int length,
                                           int batch_count);
GPU_EXPORT int ComputePhaseSpectrumGpu(const double* fft_real,
                                       const double* fft_imag,
                                       double* phase,
                                       int length,
                                       int batch_count);
GPU_EXPORT int ComputePowerSpectrumGpu(const double* fft_real,
                                       const double* fft_imag,
                                       double* power,
                                       int length,
                                       int batch_count);
GPU_EXPORT int FindDominantFrequencyGpu(const double* magnitude,
                                        int length,
                                        int batch_count,
                                        int* dominant_indices);
GPU_EXPORT int ComputeTotalPowerGpu(const double* power_spectrum,
                                    int length,
                                    int batch_count,
                                    double* total_power);
