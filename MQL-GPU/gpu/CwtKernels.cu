#include "GpuContext.h"
#include <sstream>
#include <cmath>

namespace gpu {

namespace {

constexpr int kBlockSize = 256;

// Morlet Wavelet function: cos(omega0*t) * exp(-t^2/2)
__device__ double MorletWavelet(double t, double omega0) {
    double envelope = exp(-0.5 * t * t);
    double oscillation = cos(omega0 * t);
    return oscillation * envelope;
}

// Compute CWT coefficient for ONE scale at ONE position
// This kernel is launched with one thread per scale
__global__ void ComputeCwtCoefficientsKernel(
    const double* __restrict__ signal,
    const double* __restrict__ scales,
    double* __restrict__ cwt_coeffs,
    int signal_len,
    int num_scales,
    int position,
    double omega0,
    int support_factor
) {
    int scale_idx = blockIdx.x * blockDim.x + threadIdx.x;
    if(scale_idx >= num_scales) return;

    double scale = scales[scale_idx];
    if(scale <= 0.0) {
        cwt_coeffs[scale_idx] = 0.0;
        return;
    }

    double normalization = rsqrt(scale);  // 1/sqrt(scale) - optimized GPU intrinsic
    int support = static_cast<int>(support_factor * scale);

    int left = max(0, position - support);
    int right = min(signal_len - 1, position + support);

    double coefficient = 0.0;

    // Convolve signal with scaled Morlet wavelet
    for(int i = left; i <= right; i++) {
        double t = static_cast<double>(i - position) / scale;
        double wavelet_value = MorletWavelet(t, omega0);
        coefficient += signal[i] * wavelet_value * normalization;
    }

    cwt_coeffs[scale_idx] = coefficient;
}

// Reconstruct signal using weighted sum of CWT coefficients
// One thread per output position
__global__ void ReconstructFromCwtKernel(
    const double* __restrict__ cwt_coeffs,
    const double* __restrict__ scales,
    double* __restrict__ reconstruction,
    int num_scales
) {
    // Each position gets reconstructed independently
    // This kernel is called once per position, so we only have scale dimension here

    double sum = 0.0;
    double weight_sum = 0.0;

    for(int s = 0; s < num_scales; s++) {
        // Weight inversely proportional to scale (higher freq = more weight)
        double weight = 1.0 / (scales[s] + 1e-10);
        sum += weight * cwt_coeffs[s];
        weight_sum += weight;
    }

    *reconstruction = (weight_sum > 1e-10) ? (sum / weight_sum) : 0.0;
}

// Find dominant scale (max magnitude)
__global__ void FindDominantScaleKernel(
    const double* __restrict__ cwt_coeffs,
    const double* __restrict__ scales,
    int num_scales,
    double* __restrict__ dominant_scale_out
) {
    // Shared memory for reduction
    __shared__ double s_magnitudes[kBlockSize];
    __shared__ int s_indices[kBlockSize];

    int tid = threadIdx.x;
    int idx = blockIdx.x * blockDim.x + threadIdx.x;

    // Load data
    if(idx < num_scales) {
        s_magnitudes[tid] = fabs(cwt_coeffs[idx]);
        s_indices[tid] = idx;
    } else {
        s_magnitudes[tid] = -1.0;
        s_indices[tid] = -1;
    }
    __syncthreads();

    // Reduction to find max
    for(int stride = blockDim.x / 2; stride > 0; stride >>= 1) {
        if(tid < stride) {
            if(s_magnitudes[tid + stride] > s_magnitudes[tid]) {
                s_magnitudes[tid] = s_magnitudes[tid + stride];
                s_indices[tid] = s_indices[tid + stride];
            }
        }
        __syncthreads();
    }

    // Thread 0 writes result
    if(tid == 0 && s_indices[0] >= 0) {
        *dominant_scale_out = scales[s_indices[0]];
    }
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

} // namespace

// Main CWT computation function
// Processes ONE position at a time (called from MQL5 loop)
int RunCwtOnGpu(const double* host_signal,
                const double* host_scales,
                int signal_len,
                int num_scales,
                int position,
                double omega0,
                int support_factor,
                double* host_reconstruction_out,
                double* host_dominant_scale_out) {

    // Validation
    if(host_signal == nullptr || host_scales == nullptr ||
       host_reconstruction_out == nullptr || host_dominant_scale_out == nullptr) {
        return STATUS_INVALID_ARGUMENT;
    }
    if(signal_len <= 0 || num_scales <= 0 || position < 0 || position >= signal_len) {
        return STATUS_INVALID_ARGUMENT;
    }

    auto& ctx = GpuContext::Instance();
    if(!ctx.IsInitialized()) {
        LogMessage("RunCwtOnGpu called before initialization");
        return STATUS_NOT_INITIALIZED;
    }

    CwtResources& cwt = ctx.Cwt();
    if(!cwt.ready ||
       cwt.signal_length != static_cast<size_t>(signal_len) ||
       cwt.num_scales != static_cast<size_t>(num_scales)) {
        LogMessage("RunCwtOnGpu called without proper configuration");
        return STATUS_NOT_CONFIGURED;
    }

    // Transfer signal and scales to device (only once per bar ideally)
    size_t signal_bytes = sizeof(double) * signal_len;
    size_t scales_bytes = sizeof(double) * num_scales;

    int status = ToStatus(cudaMemcpyAsync(cwt.d_signal,
                                          host_signal,
                                          signal_bytes,
                                          cudaMemcpyHostToDevice,
                                          cwt.stream),
                          "cudaMemcpyAsync host->device (CWT signal)");
    if(status != STATUS_OK) return status;

    status = ToStatus(cudaMemcpyAsync(cwt.d_scales,
                                      host_scales,
                                      scales_bytes,
                                      cudaMemcpyHostToDevice,
                                      cwt.stream),
                      "cudaMemcpyAsync host->device (CWT scales)");
    if(status != STATUS_OK) return status;

    // Compute CWT coefficients for all scales at this position
    int grid_scales = (num_scales + kBlockSize - 1) / kBlockSize;
    ComputeCwtCoefficientsKernel<<<grid_scales, kBlockSize, 0, cwt.stream>>>(
        cwt.d_signal,
        cwt.d_scales,
        cwt.d_cwt_coeffs,
        signal_len,
        num_scales,
        position,
        omega0,
        support_factor
    );
    status = ToStatus(cudaGetLastError(), "ComputeCwtCoefficientsKernel launch");
    if(status != STATUS_OK) return status;

    // Find dominant scale
    double* d_dominant_temp;
    cudaMalloc(&d_dominant_temp, sizeof(double));

    int grid_dominant = 1;  // Single block reduction
    FindDominantScaleKernel<<<grid_dominant, kBlockSize, 0, cwt.stream>>>(
        cwt.d_cwt_coeffs,
        cwt.d_scales,
        num_scales,
        d_dominant_temp
    );
    status = ToStatus(cudaGetLastError(), "FindDominantScaleKernel launch");
    if(status != STATUS_OK) {
        cudaFree(d_dominant_temp);
        return status;
    }

    // Reconstruct signal value at this position
    ReconstructFromCwtKernel<<<1, 1, 0, cwt.stream>>>(
        cwt.d_cwt_coeffs,
        cwt.d_scales,
        cwt.d_reconstruction,
        num_scales
    );
    status = ToStatus(cudaGetLastError(), "ReconstructFromCwtKernel launch");
    if(status != STATUS_OK) {
        cudaFree(d_dominant_temp);
        return status;
    }

    // Transfer results back to host
    status = ToStatus(cudaMemcpyAsync(host_reconstruction_out,
                                      cwt.d_reconstruction,
                                      sizeof(double),
                                      cudaMemcpyDeviceToHost,
                                      cwt.stream),
                      "cudaMemcpyAsync device->host (CWT reconstruction)");
    if(status != STATUS_OK) {
        cudaFree(d_dominant_temp);
        return status;
    }

    status = ToStatus(cudaMemcpyAsync(host_dominant_scale_out,
                                      d_dominant_temp,
                                      sizeof(double),
                                      cudaMemcpyDeviceToHost,
                                      cwt.stream),
                      "cudaMemcpyAsync device->host (CWT dominant scale)");
    if(status != STATUS_OK) {
        cudaFree(d_dominant_temp);
        return status;
    }

    // Synchronize stream to ensure completion
    status = ToStatus(cudaStreamSynchronize(cwt.stream),
                      "cudaStreamSynchronize (CWT)");

    cudaFree(d_dominant_temp);
    return status;
}

} // namespace gpu
