#include "exports.h"

#include "GpuContext.h"
#include "GpuStatus.h"

namespace gpu {
int RunWaveformFft(const double* host_input,
                   double* host_real_out,
                   double* host_imag_out,
                   int length);

int RunWaveformIfft(const double* host_real_in,
                    const double* host_imag_in,
                    double* host_output,
                    int length);

int RunBatchWaveformFft(const double* host_input_batch,
                        double* host_real_out_batch,
                        double* host_imag_out_batch,
                        int fft_size,
                        int batch_count);

int RunSupDemVolumeKernel(const double* volume,
                          const double* open,
                          const double* high,
                          const double* low,
                          const double* close,
                          double* media_out,
                          double* banda_sup_out,
                          int length,
                          int periodo_media,
                          double multip_desvio);

int RunCwtOnGpu(const double* host_signal,
                const double* host_scales,
                int signal_len,
                int num_scales,
                int position,
                double omega0,
                int support_factor,
                double* host_reconstruction_out,
                double* host_dominant_scale_out);

int ComputeMagnitudeSpectrumGpu(const double* host_real,
                                const double* host_imag,
                                double* host_magnitude,
                                int length,
                                int batch_count);

int ComputePhaseSpectrumGpu(const double* host_real,
                            const double* host_imag,
                            double* host_phase,
                            int length,
                            int batch_count);

int ComputePowerSpectrumGpu(const double* host_real,
                            const double* host_imag,
                            double* host_power,
                            int length,
                            int batch_count);

int FindDominantFrequencyGpu(const double* host_magnitude,
                              int length,
                              int batch_count,
                              int* host_dominant_indices);

int ComputeTotalPowerGpu(const double* host_power_spectrum,
                         int length,
                         int batch_count,
                         double* host_total_power);
} // namespace gpu

GPU_EXPORT int GpuSessionInit(int device_id) {
    return gpu::GpuContext::Instance().Initialize(device_id);
}

GPU_EXPORT void GpuSessionClose() {
    gpu::GpuContext::Instance().Shutdown();
}

GPU_EXPORT int GpuConfigureWaveform(int length) {
    if(length <= 0) {
        return gpu::STATUS_INVALID_ARGUMENT;
    }
    return gpu::GpuContext::Instance().ConfigureWaveform(static_cast<size_t>(length));
}

GPU_EXPORT int GpuConfigureBatchWaveform(int fft_size, int max_batch_count) {
    if(fft_size <= 0 || max_batch_count <= 0) {
        return gpu::STATUS_INVALID_ARGUMENT;
    }
    return gpu::GpuContext::Instance().ConfigureBatchWaveform(
        static_cast<size_t>(fft_size),
        static_cast<size_t>(max_batch_count)
    );
}

GPU_EXPORT int RunWaveformFft(const double* input,
                              double* fft_real,
                              double* fft_imag,
                              int length) {
    return gpu::RunWaveformFft(input, fft_real, fft_imag, length);
}

GPU_EXPORT int RunWaveformIfft(const double* fft_real,
                               const double* fft_imag,
                               double* output,
                               int length) {
    return gpu::RunWaveformIfft(fft_real, fft_imag, output, length);
}

GPU_EXPORT int RunBatchWaveformFft(const double* input_batch,
                                   double* fft_real_batch,
                                   double* fft_imag_batch,
                                   int fft_size,
                                   int batch_count) {
    return gpu::RunBatchWaveformFft(input_batch, fft_real_batch, fft_imag_batch, fft_size, batch_count);
}

GPU_EXPORT int GpuConfigureSupDem(int capacity) {
    if(capacity <= 0) {
        return gpu::STATUS_INVALID_ARGUMENT;
    }
    return gpu::GpuContext::Instance().ConfigureSupDem(static_cast<size_t>(capacity));
}

GPU_EXPORT int RunSupDemVolume(const double* volume,
                               const double* open,
                               const double* high,
                               const double* low,
                               const double* close,
                               double* media_out,
                               double* banda_sup_out,
                               int length,
                               int periodo_media,
                               double multip_desvio) {
    return gpu::RunSupDemVolumeKernel(volume,
                                      open,
                                      high,
                                      low,
                                      close,
                                      media_out,
                                      banda_sup_out,
                                      length,
                                      periodo_media,
                                      multip_desvio);
}

GPU_EXPORT int GpuConfigureCwt(int signal_len, int num_scales) {
    if(signal_len <= 0 || num_scales <= 0) {
        return gpu::STATUS_INVALID_ARGUMENT;
    }
    return gpu::GpuContext::Instance().ConfigureCwt(
        static_cast<size_t>(signal_len),
        static_cast<size_t>(num_scales)
    );
}

GPU_EXPORT int RunCwtOnGpu(const double* signal,
                           const double* scales,
                           int signal_len,
                           int num_scales,
                           int position,
                           double omega0,
                           int support_factor,
                           double* reconstruction_out,
                           double* dominant_scale_out) {
    return gpu::RunCwtOnGpu(signal,
                            scales,
                            signal_len,
                            num_scales,
                            position,
                            omega0,
                            support_factor,
                            reconstruction_out,
                            dominant_scale_out);
}

GPU_EXPORT int ComputeMagnitudeSpectrumGpu(const double* fft_real,
                                           const double* fft_imag,
                                           double* magnitude,
                                           int length,
                                           int batch_count) {
    return gpu::ComputeMagnitudeSpectrumGpu(fft_real, fft_imag, magnitude, length, batch_count);
}

GPU_EXPORT int ComputePhaseSpectrumGpu(const double* fft_real,
                                       const double* fft_imag,
                                       double* phase,
                                       int length,
                                       int batch_count) {
    return gpu::ComputePhaseSpectrumGpu(fft_real, fft_imag, phase, length, batch_count);
}

GPU_EXPORT int ComputePowerSpectrumGpu(const double* fft_real,
                                       const double* fft_imag,
                                       double* power,
                                       int length,
                                       int batch_count) {
    return gpu::ComputePowerSpectrumGpu(fft_real, fft_imag, power, length, batch_count);
}

GPU_EXPORT int FindDominantFrequencyGpu(const double* magnitude,
                                        int length,
                                        int batch_count,
                                        int* dominant_indices) {
    return gpu::FindDominantFrequencyGpu(magnitude, length, batch_count, dominant_indices);
}

GPU_EXPORT int ComputeTotalPowerGpu(const double* power_spectrum,
                                    int length,
                                    int batch_count,
                                    double* total_power) {
    return gpu::ComputeTotalPowerGpu(power_spectrum, length, batch_count, total_power);
}
