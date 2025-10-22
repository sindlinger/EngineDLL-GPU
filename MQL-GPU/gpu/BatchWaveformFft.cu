#include "GpuContext.h"
#include <cufft.h>
#include <vector>
#include <sstream>

namespace gpu {

namespace {

constexpr int kBlockSize = 256;

__global__ void BatchSplitComplexKernel(const cufftDoubleComplex* __restrict__ src,
                                        double* __restrict__ real_out,
                                        double* __restrict__ imag_out,
                                        int fft_size,
                                        int batch_count) {
    int batch_idx = blockIdx.y;
    int elem_idx = blockIdx.x * blockDim.x + threadIdx.x;

    if(batch_idx >= batch_count || elem_idx >= fft_size) {
        return;
    }

    int global_idx = batch_idx * fft_size + elem_idx;
    cufftDoubleComplex value = src[global_idx];
    real_out[global_idx] = value.x;
    imag_out[global_idx] = value.y;
}

int ToStatus(cudaError_t err, const char* context) {
    if(err == cudaSuccess) {
        return STATUS_OK;
    }
    std::ostringstream oss;
    oss << context << " cuda_error=" << static_cast<int>(err);
    LogMessage(oss.str());
    return STATUS_DEVICE_ERROR;
}

int ToStatus(cufftResult res, const char* context) {
    if(res == CUFFT_SUCCESS) {
        return STATUS_OK;
    }
    std::ostringstream oss;
    oss << context << " cufft_error=" << static_cast<int>(res);
    LogMessage(oss.str());
    return STATUS_EXECUTION_ERROR;
}

} // namespace

// BATCH FFT: Processa múltiplas FFTs EM PARALELO na GPU
int RunBatchWaveformFft(const double* host_input_batch,
                        double* host_real_out_batch,
                        double* host_imag_out_batch,
                        int fft_size,
                        int batch_count) {
    if(host_input_batch == nullptr || host_real_out_batch == nullptr || host_imag_out_batch == nullptr) {
        return STATUS_INVALID_ARGUMENT;
    }
    if(fft_size <= 0 || batch_count <= 0) {
        return STATUS_INVALID_ARGUMENT;
    }

    auto& ctx = GpuContext::Instance();
    if(!ctx.IsInitialized()) {
        LogMessage("RunBatchWaveformFft called before initialization");
        return STATUS_NOT_INITIALIZED;
    }

    // ⚡ Get persistent batch resources (memory allocated ONCE, reused forever)
    auto& batch = ctx.BatchWaveform();

    // Ensure batch is configured for this size and count
    if(!batch.ready ||
       batch.fft_size != static_cast<size_t>(fft_size) ||
       batch.max_batch_count < static_cast<size_t>(batch_count)) {

        // Auto-configure if needed (allocates memory ONCE)
        int status = ctx.ConfigureBatchWaveform(static_cast<size_t>(fft_size),
                                                 static_cast<size_t>(batch_count));
        if(status != STATUS_OK) {
            return status;
        }
    }

    size_t total_real_bytes = sizeof(double) * static_cast<size_t>(fft_size) * static_cast<size_t>(batch_count);

    // ⚡ USAR MEMÓRIA PERSISTENTE - Sem alocações! Apenas copia dados
    int status = ToStatus(cudaMemcpyAsync(batch.d_input_batch,
                                          host_input_batch,
                                          total_real_bytes,
                                          cudaMemcpyHostToDevice,
                                          batch.stream),
                          "cudaMemcpyAsync host->device (batch input)");
    if(status != STATUS_OK) {
        return status;
    }

    // ⚡ Executar BATCH FFT usando plano persistente - Todas FFTs em paralelo!
    status = ToStatus(cufftExecD2Z(batch.plan_batch,
                                   reinterpret_cast<cufftDoubleReal*>(batch.d_input_batch),
                                   batch.d_fft_batch),
                      "cufftExecD2Z (batch persistent)");
    if(status != STATUS_OK) {
        return status;
    }

    // ⚡ Split complex em paralelo usando stream dedicado
    dim3 block(kBlockSize);
    dim3 grid((fft_size + kBlockSize - 1) / kBlockSize, batch_count);

    BatchSplitComplexKernel<<<grid, block, 0, batch.stream>>>(batch.d_fft_batch,
                                                               batch.d_real_batch,
                                                               batch.d_imag_batch,
                                                               fft_size,
                                                               batch_count);

    status = ToStatus(cudaGetLastError(), "BatchSplitComplexKernel launch");
    if(status != STATUS_OK) {
        return status;
    }

    // ⚡ Copiar resultados de volta usando memória persistente
    status = ToStatus(cudaMemcpyAsync(host_real_out_batch,
                                      batch.d_real_batch,
                                      total_real_bytes,
                                      cudaMemcpyDeviceToHost,
                                      batch.stream),
                      "cudaMemcpyAsync device->host (batch real)");
    if(status != STATUS_OK) {
        return status;
    }

    status = ToStatus(cudaMemcpyAsync(host_imag_out_batch,
                                      batch.d_imag_batch,
                                      total_real_bytes,
                                      cudaMemcpyDeviceToHost,
                                      batch.stream),
                      "cudaMemcpyAsync device->host (batch imag)");
    if(status != STATUS_OK) {
        return status;
    }

    // Sincronizar stream (espera todas operações assíncronas terminarem)
    status = ToStatus(cudaStreamSynchronize(batch.stream), "cudaStreamSynchronize (batch)");

    if(status == STATUS_OK) {
        const double scale = 1.0 / static_cast<double>(fft_size);
        for(int b = 0; b < batch_count; ++b) {
            int offset = b * fft_size;
            for(int i = 0; i < fft_size; ++i) {
                host_real_out_batch[offset + i] *= scale;
                host_imag_out_batch[offset + i] *= scale;
            }
        }
    }

    // ✅ SEM CLEANUP! Memória permanece na GPU para próxima chamada!
    return status;
}

} // namespace gpu
