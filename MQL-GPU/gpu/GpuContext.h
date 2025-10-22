#pragma once

#include <cstddef>
#include <cstdint>
#include <cuda_runtime.h>
#include <cufft.h>
#include <mutex>

#include "GpuLogger.h"
#include "GpuStatus.h"

namespace gpu {

struct WaveformResources {
    size_t length;
    cufftHandle plan;
    cufftHandle plan_inverse;
    double* d_input;
    cufftDoubleComplex* d_fft;
    double* d_real;
    double* d_imag;
    cudaStream_t stream_fft;
    cudaStream_t stream_post;
    bool ready;

    WaveformResources();
    void Reset();
};

struct SupDemResources {
    size_t capacity;
    double* d_volume;
    double* d_media;
    double* d_banda_sup;
    double* d_high;
    double* d_low;
    double* d_open;
    double* d_close;
    int* d_flags;
    cudaStream_t stream;
    bool ready;

    SupDemResources();
    void Reset();
};

struct CwtResources {
    size_t signal_length;
    size_t num_scales;
    double* d_signal;
    double* d_scales;
    double* d_cwt_coeffs;
    double* d_reconstruction;
    cudaStream_t stream;
    bool ready;

    CwtResources();
    void Reset();
};

// BATCH FFT Resources - Memória persistente para processamento em lote
struct BatchWaveformResources {
    size_t fft_size;          // Tamanho de cada FFT individual
    size_t max_batch_count;   // Máximo de FFTs simultâneas
    cufftHandle plan_batch;   // Plano cuFFT para batch
    double* d_input_batch;    // Input para todas FFTs (reutilizável)
    cufftDoubleComplex* d_fft_batch;  // Resultados FFT complexos
    double* d_real_batch;     // Parte real (reutilizável)
    double* d_imag_batch;     // Parte imaginária (reutilizável)
    cudaStream_t stream;      // Stream dedicado para batch
    bool ready;

    BatchWaveformResources();
    void Reset();
};

class GpuContext {
public:
    static GpuContext& Instance();

    int Initialize(int device_id);
    void Shutdown();

    bool IsInitialized() const { return initialized_; }

    int ConfigureWaveform(size_t length);
    WaveformResources& Waveform() { return waveform_; }
    const WaveformResources& Waveform() const { return waveform_; }

    int ConfigureSupDem(size_t capacity);
    SupDemResources& SupDem() { return supdem_; }
    const SupDemResources& SupDem() const { return supdem_; }

    int ConfigureCwt(size_t signal_length, size_t num_scales);
    CwtResources& Cwt() { return cwt_; }
    const CwtResources& Cwt() const { return cwt_; }

    int ConfigureBatchWaveform(size_t fft_size, size_t max_batch_count);
    BatchWaveformResources& BatchWaveform() { return batch_waveform_; }
    const BatchWaveformResources& BatchWaveform() const { return batch_waveform_; }

private:
    GpuContext();
    ~GpuContext();

    GpuContext(const GpuContext&) = delete;
    GpuContext& operator=(const GpuContext&) = delete;

    int device_id_;
    bool initialized_;
    mutable std::mutex mutex_;
    WaveformResources waveform_;
    SupDemResources supdem_;
    CwtResources cwt_;
    BatchWaveformResources batch_waveform_;
};

} // namespace gpu
