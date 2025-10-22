#include "GpuContext.h"

#include <sstream>

namespace gpu {

namespace {

constexpr int kBlockSize = 256;

__global__ void SplitComplexKernel(const cufftDoubleComplex* __restrict__ src,
                                   double* __restrict__ real_out,
                                   double* __restrict__ imag_out,
                                   int n) {
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if(idx >= n) {
        return;
    }
    cufftDoubleComplex value = src[idx];
    real_out[idx] = value.x;
    imag_out[idx] = value.y;
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

int RunWaveformFft(const double* host_input,
                   double* host_real_out,
                   double* host_imag_out,
                   int length) {
    if(host_input == nullptr || host_real_out == nullptr || host_imag_out == nullptr) {
        return STATUS_INVALID_ARGUMENT;
    }
    if(length <= 0) {
        return STATUS_INVALID_ARGUMENT;
    }

    auto& ctx = GpuContext::Instance();
    if(!ctx.IsInitialized()) {
        LogMessage("RunWaveformFft called before initialization");
        return STATUS_NOT_INITIALIZED;
    }

    WaveformResources& wf = ctx.Waveform();
    if(!wf.ready || wf.length != static_cast<size_t>(length)) {
        LogMessage("RunWaveformFft called without configuration");
        return STATUS_NOT_CONFIGURED;
    }

    size_t real_bytes = sizeof(double) * static_cast<size_t>(length);

    int status = ToStatus(cudaMemcpyAsync(wf.d_input,
                                          host_input,
                                          real_bytes,
                                          cudaMemcpyHostToDevice,
                                          wf.stream_fft),
                          "cudaMemcpyAsync host->device (waveform input)");
    if(status != STATUS_OK) {
        return status;
    }

    status = ToStatus(cufftExecD2Z(wf.plan,
                                   reinterpret_cast<cufftDoubleReal*>(wf.d_input),
                                   wf.d_fft),
                      "cufftExecD2Z");
    if(status != STATUS_OK) {
        return status;
    }

    int grid = (length + kBlockSize - 1) / kBlockSize;
    SplitComplexKernel<<<grid, kBlockSize, 0, wf.stream_post>>>(wf.d_fft,
                                                                wf.d_real,
                                                                wf.d_imag,
                                                                length);
    status = ToStatus(cudaGetLastError(), "SplitComplexKernel launch");
    if(status != STATUS_OK) {
        return status;
    }

    status = ToStatus(cudaMemcpyAsync(host_real_out,
                                      wf.d_real,
                                      real_bytes,
                                      cudaMemcpyDeviceToHost,
                                      wf.stream_post),
                      "cudaMemcpyAsync device->host (real)");
    if(status != STATUS_OK) {
        return status;
    }

    status = ToStatus(cudaMemcpyAsync(host_imag_out,
                                      wf.d_imag,
                                      real_bytes,
                                      cudaMemcpyDeviceToHost,
                                      wf.stream_post),
                      "cudaMemcpyAsync device->host (imag)");
    if(status != STATUS_OK) {
        return status;
    }

    status = ToStatus(cudaStreamSynchronize(wf.stream_post), "cudaStreamSynchronize (post)");
    if(status != STATUS_OK) {
        return status;
    }

    status = ToStatus(cudaStreamSynchronize(wf.stream_fft), "cudaStreamSynchronize (fft)");
    if(status != STATUS_OK) {
        return status;
    }

    // Normalizar saída para corresponder à convenção FFT usada no MQL (divisão por N)
    const double scale = 1.0 / static_cast<double>(length);
    for(int i = 0; i < length; ++i) {
        host_real_out[i] *= scale;
        host_imag_out[i] *= scale;
    }

    return STATUS_OK;
}

__global__ void CombineComplexKernel(const double* __restrict__ real_in,
                                     const double* __restrict__ imag_in,
                                     cufftDoubleComplex* __restrict__ complex_out,
                                     int n) {
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if(idx >= n) {
        return;
    }
    complex_out[idx].x = real_in[idx];
    complex_out[idx].y = imag_in[idx];
}

int RunWaveformIfft(const double* host_real_in,
                    const double* host_imag_in,
                    double* host_output,
                    int length) {
    if(host_real_in == nullptr || host_imag_in == nullptr || host_output == nullptr) {
        return STATUS_INVALID_ARGUMENT;
    }
    if(length <= 0) {
        return STATUS_INVALID_ARGUMENT;
    }

    auto& ctx = GpuContext::Instance();
    if(!ctx.IsInitialized()) {
        LogMessage("RunWaveformIfft called before initialization");
        return STATUS_NOT_INITIALIZED;
    }

    WaveformResources& wf = ctx.Waveform();
    if(!wf.ready || wf.length != static_cast<size_t>(length)) {
        LogMessage("RunWaveformIfft called without configuration");
        return STATUS_NOT_CONFIGURED;
    }

    size_t real_bytes = sizeof(double) * static_cast<size_t>(length);

    // Copy real and imaginary parts to device
    int status = ToStatus(cudaMemcpyAsync(wf.d_real,
                                          host_real_in,
                                          real_bytes,
                                          cudaMemcpyHostToDevice,
                                          wf.stream_fft),
                          "cudaMemcpyAsync host->device (ifft real)");
    if(status != STATUS_OK) {
        return status;
    }

    status = ToStatus(cudaMemcpyAsync(wf.d_imag,
                                      host_imag_in,
                                      real_bytes,
                                      cudaMemcpyHostToDevice,
                                      wf.stream_fft),
                      "cudaMemcpyAsync host->device (ifft imag)");
    if(status != STATUS_OK) {
        return status;
    }

    // Combine real and imaginary into complex array
    int grid = (length + kBlockSize - 1) / kBlockSize;
    CombineComplexKernel<<<grid, kBlockSize, 0, wf.stream_fft>>>(wf.d_real,
                                                                  wf.d_imag,
                                                                  wf.d_fft,
                                                                  length);
    status = ToStatus(cudaGetLastError(), "CombineComplexKernel launch");
    if(status != STATUS_OK) {
        return status;
    }

    // Execute inverse FFT (Z2D)
    status = ToStatus(cufftExecZ2D(wf.plan_inverse,
                                   wf.d_fft,
                                   reinterpret_cast<cufftDoubleReal*>(wf.d_input)),
                      "cufftExecZ2D");
    if(status != STATUS_OK) {
        return status;
    }

    // Copy result back to host
    status = ToStatus(cudaMemcpyAsync(host_output,
                                      wf.d_input,
                                      real_bytes,
                                      cudaMemcpyDeviceToHost,
                                      wf.stream_post),
                      "cudaMemcpyAsync device->host (ifft output)");
    if(status != STATUS_OK) {
        return status;
    }

    status = ToStatus(cudaStreamSynchronize(wf.stream_post), "cudaStreamSynchronize (ifft post)");
    if(status != STATUS_OK) {
        return status;
    }

    status = ToStatus(cudaStreamSynchronize(wf.stream_fft), "cudaStreamSynchronize (ifft)");
    if(status != STATUS_OK) {
        return status;
    }

    // IFFT needs normalization by 1/N
    for(int i = 0; i < length; i++) {
        host_output[i] /= static_cast<double>(length);
    }

    return STATUS_OK;
}

} // namespace gpu
