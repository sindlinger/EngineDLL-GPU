#include "GpuContext.h"
#include "GpuStatus.h"
#include <cuda_runtime.h>
#include <device_launch_parameters.h>
#include <sstream>

namespace gpu {

namespace {

constexpr int kBlockSize = 256;

// ============================================================================
// KERNELS CUDA - Executam em paralelo na GPU
// ============================================================================

__global__ void MagnitudeKernel(const double* __restrict__ real,
                                const double* __restrict__ imag,
                                double* __restrict__ magnitude,
                                int length,
                                int batch_count) {
  int batch_idx = blockIdx.y;
  int elem_idx = blockIdx.x * blockDim.x + threadIdx.x;

  if(batch_idx >= batch_count || elem_idx >= length) {
    return;
  }

  int global_idx = batch_idx * length + elem_idx;
  double r = real[global_idx];
  double i = imag[global_idx];
  magnitude[global_idx] = sqrt(r * r + i * i);
}

__global__ void PhaseKernel(const double* __restrict__ real,
                            const double* __restrict__ imag,
                            double* __restrict__ phase,
                            int length,
                            int batch_count) {
  int batch_idx = blockIdx.y;
  int elem_idx = blockIdx.x * blockDim.x + threadIdx.x;

  if(batch_idx >= batch_count || elem_idx >= length) {
    return;
  }

  int global_idx = batch_idx * length + elem_idx;
  phase[global_idx] = atan2(imag[global_idx], real[global_idx]);
}

__global__ void PowerKernel(const double* __restrict__ real,
                            const double* __restrict__ imag,
                            double* __restrict__ power,
                            int length,
                            int batch_count) {
  int batch_idx = blockIdx.y;
  int elem_idx = blockIdx.x * blockDim.x + threadIdx.x;

  if(batch_idx >= batch_count || elem_idx >= length) {
    return;
  }

  int global_idx = batch_idx * length + elem_idx;
  double r = real[global_idx];
  double i = imag[global_idx];
  power[global_idx] = r * r + i * i;
}

__global__ void FindMaxIndexKernel(const double* __restrict__ input,
                                   int length,
                                   int batch_count,
                                   int* __restrict__ max_indices) {
  int batch_idx = blockIdx.x;

  if(batch_idx >= batch_count) {
    return;
  }

  extern __shared__ double shared_vals[];
  int* shared_indices = (int*)&shared_vals[blockDim.x];

  int tid = threadIdx.x;
  int offset = batch_idx * length;

  double max_val = -1e308;
  int max_idx = 0;

  for(int i = tid; i < length; i += blockDim.x) {
    double val = input[offset + i];
    if(val > max_val) {
      max_val = val;
      max_idx = i;
    }
  }

  shared_vals[tid] = max_val;
  shared_indices[tid] = max_idx;
  __syncthreads();

  for(int stride = blockDim.x / 2; stride > 0; stride >>= 1) {
    if(tid < stride) {
      if(shared_vals[tid + stride] > shared_vals[tid]) {
        shared_vals[tid] = shared_vals[tid + stride];
        shared_indices[tid] = shared_indices[tid + stride];
      }
    }
    __syncthreads();
  }

  if(tid == 0) {
    max_indices[batch_idx] = shared_indices[0];
  }
}

__global__ void SumReductionKernel(const double* __restrict__ input,
                                   int length,
                                   int batch_count,
                                   double* __restrict__ batch_sums) {
  int batch_idx = blockIdx.x;

  if(batch_idx >= batch_count) {
    return;
  }

  extern __shared__ double shared_data[];

  int tid = threadIdx.x;
  int offset = batch_idx * length;

  double sum = 0.0;
  for(int i = tid; i < length; i += blockDim.x) {
    sum += input[offset + i];
  }

  shared_data[tid] = sum;
  __syncthreads();

  for(int stride = blockDim.x / 2; stride > 0; stride >>= 1) {
    if(tid < stride) {
      shared_data[tid] += shared_data[tid + stride];
    }
    __syncthreads();
  }

  if(tid == 0) {
    batch_sums[batch_idx] = shared_data[0];
  }
}

// Helper para converter cudaError_t em Status
inline int ToStatus(cudaError_t err, const char* operation) {
  if(err == cudaSuccess) {
    return STATUS_OK;
  }

  std::ostringstream oss;
  oss << operation << " failed: " << cudaGetErrorString(err);
  LogMessage(oss.str());

  return STATUS_EXECUTION_ERROR;
}

} // anonymous namespace

// ============================================================================
// FUNÇÕES PÚBLICAS - Chamadas pelo MQL5
// ============================================================================

int ComputeMagnitudeSpectrumGpu(const double* host_real,
                                const double* host_imag,
                                double* host_magnitude,
                                int length,
                                int batch_count) {
  if(host_real == nullptr || host_imag == nullptr || host_magnitude == nullptr) {
    return STATUS_INVALID_ARGUMENT;
  }
  if(length <= 0 || batch_count <= 0) {
    return STATUS_INVALID_ARGUMENT;
  }

  auto& ctx = GpuContext::Instance();
  if(!ctx.IsInitialized()) {
    return STATUS_NOT_INITIALIZED;
  }

  size_t total_bytes = sizeof(double) * length * batch_count;

  double *d_real = nullptr, *d_imag = nullptr, *d_magnitude = nullptr;

  int status = ToStatus(cudaMalloc(&d_real, total_bytes), "cudaMalloc real");
  if(status != STATUS_OK) return status;

  status = ToStatus(cudaMalloc(&d_imag, total_bytes), "cudaMalloc imag");
  if(status != STATUS_OK) {
    cudaFree(d_real);
    return status;
  }

  status = ToStatus(cudaMalloc(&d_magnitude, total_bytes), "cudaMalloc magnitude");
  if(status != STATUS_OK) {
    cudaFree(d_real);
    cudaFree(d_imag);
    return status;
  }

  status = ToStatus(cudaMemcpy(d_real, host_real, total_bytes, cudaMemcpyHostToDevice), "memcpy real H2D");
  if(status != STATUS_OK) goto cleanup;

  status = ToStatus(cudaMemcpy(d_imag, host_imag, total_bytes, cudaMemcpyHostToDevice), "memcpy imag H2D");
  if(status != STATUS_OK) goto cleanup;

  {
    dim3 block(kBlockSize);
    dim3 grid((length + kBlockSize - 1) / kBlockSize, batch_count);
    MagnitudeKernel<<<grid, block>>>(d_real, d_imag, d_magnitude, length, batch_count);

    status = ToStatus(cudaGetLastError(), "MagnitudeKernel launch");
    if(status != STATUS_OK) goto cleanup;
  }

  status = ToStatus(cudaMemcpy(host_magnitude, d_magnitude, total_bytes, cudaMemcpyDeviceToHost), "memcpy magnitude D2H");
  if(status != STATUS_OK) goto cleanup;

  status = ToStatus(cudaDeviceSynchronize(), "cudaDeviceSynchronize");

cleanup:
  cudaFree(d_real);
  cudaFree(d_imag);
  cudaFree(d_magnitude);

  return status;
}

int ComputePhaseSpectrumGpu(const double* host_real,
                            const double* host_imag,
                            double* host_phase,
                            int length,
                            int batch_count) {
  if(host_real == nullptr || host_imag == nullptr || host_phase == nullptr) {
    return STATUS_INVALID_ARGUMENT;
  }
  if(length <= 0 || batch_count <= 0) {
    return STATUS_INVALID_ARGUMENT;
  }

  auto& ctx = GpuContext::Instance();
  if(!ctx.IsInitialized()) {
    return STATUS_NOT_INITIALIZED;
  }

  size_t total_bytes = sizeof(double) * length * batch_count;

  double *d_real = nullptr, *d_imag = nullptr, *d_phase = nullptr;

  int status = ToStatus(cudaMalloc(&d_real, total_bytes), "cudaMalloc real");
  if(status != STATUS_OK) return status;

  status = ToStatus(cudaMalloc(&d_imag, total_bytes), "cudaMalloc imag");
  if(status != STATUS_OK) {
    cudaFree(d_real);
    return status;
  }

  status = ToStatus(cudaMalloc(&d_phase, total_bytes), "cudaMalloc phase");
  if(status != STATUS_OK) {
    cudaFree(d_real);
    cudaFree(d_imag);
    return status;
  }

  status = ToStatus(cudaMemcpy(d_real, host_real, total_bytes, cudaMemcpyHostToDevice), "memcpy real H2D");
  if(status != STATUS_OK) goto cleanup;

  status = ToStatus(cudaMemcpy(d_imag, host_imag, total_bytes, cudaMemcpyHostToDevice), "memcpy imag H2D");
  if(status != STATUS_OK) goto cleanup;

  {
    dim3 block(kBlockSize);
    dim3 grid((length + kBlockSize - 1) / kBlockSize, batch_count);
    PhaseKernel<<<grid, block>>>(d_real, d_imag, d_phase, length, batch_count);

    status = ToStatus(cudaGetLastError(), "PhaseKernel launch");
    if(status != STATUS_OK) goto cleanup;
  }

  status = ToStatus(cudaMemcpy(host_phase, d_phase, total_bytes, cudaMemcpyDeviceToHost), "memcpy phase D2H");
  if(status != STATUS_OK) goto cleanup;

  status = ToStatus(cudaDeviceSynchronize(), "cudaDeviceSynchronize");

cleanup:
  cudaFree(d_real);
  cudaFree(d_imag);
  cudaFree(d_phase);

  return status;
}

int ComputePowerSpectrumGpu(const double* host_real,
                            const double* host_imag,
                            double* host_power,
                            int length,
                            int batch_count) {
  if(host_real == nullptr || host_imag == nullptr || host_power == nullptr) {
    return STATUS_INVALID_ARGUMENT;
  }
  if(length <= 0 || batch_count <= 0) {
    return STATUS_INVALID_ARGUMENT;
  }

  auto& ctx = GpuContext::Instance();
  if(!ctx.IsInitialized()) {
    return STATUS_NOT_INITIALIZED;
  }

  size_t total_bytes = sizeof(double) * length * batch_count;

  double *d_real = nullptr, *d_imag = nullptr, *d_power = nullptr;

  int status = ToStatus(cudaMalloc(&d_real, total_bytes), "cudaMalloc real");
  if(status != STATUS_OK) return status;

  status = ToStatus(cudaMalloc(&d_imag, total_bytes), "cudaMalloc imag");
  if(status != STATUS_OK) {
    cudaFree(d_real);
    return status;
  }

  status = ToStatus(cudaMalloc(&d_power, total_bytes), "cudaMalloc power");
  if(status != STATUS_OK) {
    cudaFree(d_real);
    cudaFree(d_imag);
    return status;
  }

  status = ToStatus(cudaMemcpy(d_real, host_real, total_bytes, cudaMemcpyHostToDevice), "memcpy real H2D");
  if(status != STATUS_OK) goto cleanup;

  status = ToStatus(cudaMemcpy(d_imag, host_imag, total_bytes, cudaMemcpyHostToDevice), "memcpy imag H2D");
  if(status != STATUS_OK) goto cleanup;

  {
    dim3 block(kBlockSize);
    dim3 grid((length + kBlockSize - 1) / kBlockSize, batch_count);
    PowerKernel<<<grid, block>>>(d_real, d_imag, d_power, length, batch_count);

    status = ToStatus(cudaGetLastError(), "PowerKernel launch");
    if(status != STATUS_OK) goto cleanup;
  }

  status = ToStatus(cudaMemcpy(host_power, d_power, total_bytes, cudaMemcpyDeviceToHost), "memcpy power D2H");
  if(status != STATUS_OK) goto cleanup;

  status = ToStatus(cudaDeviceSynchronize(), "cudaDeviceSynchronize");

cleanup:
  cudaFree(d_real);
  cudaFree(d_imag);
  cudaFree(d_power);

  return status;
}

int FindDominantFrequencyGpu(const double* host_magnitude,
                              int length,
                              int batch_count,
                              int* host_dominant_indices) {
  if(host_magnitude == nullptr || host_dominant_indices == nullptr) {
    return STATUS_INVALID_ARGUMENT;
  }
  if(length <= 0 || batch_count <= 0) {
    return STATUS_INVALID_ARGUMENT;
  }

  auto& ctx = GpuContext::Instance();
  if(!ctx.IsInitialized()) {
    return STATUS_NOT_INITIALIZED;
  }

  size_t data_bytes = sizeof(double) * length * batch_count;
  size_t indices_bytes = sizeof(int) * batch_count;

  double *d_magnitude = nullptr;
  int *d_indices = nullptr;

  int status = ToStatus(cudaMalloc(&d_magnitude, data_bytes), "cudaMalloc magnitude");
  if(status != STATUS_OK) return status;

  status = ToStatus(cudaMalloc(&d_indices, indices_bytes), "cudaMalloc indices");
  if(status != STATUS_OK) {
    cudaFree(d_magnitude);
    return status;
  }

  status = ToStatus(cudaMemcpy(d_magnitude, host_magnitude, data_bytes, cudaMemcpyHostToDevice), "memcpy magnitude H2D");
  if(status != STATUS_OK) goto cleanup;

  {
    dim3 block(kBlockSize);
    dim3 grid(batch_count);
    size_t shared_mem = kBlockSize * (sizeof(double) + sizeof(int));
    FindMaxIndexKernel<<<grid, block, shared_mem>>>(d_magnitude, length, batch_count, d_indices);

    status = ToStatus(cudaGetLastError(), "FindMaxIndexKernel launch");
    if(status != STATUS_OK) goto cleanup;
  }

  status = ToStatus(cudaMemcpy(host_dominant_indices, d_indices, indices_bytes, cudaMemcpyDeviceToHost), "memcpy indices D2H");
  if(status != STATUS_OK) goto cleanup;

  status = ToStatus(cudaDeviceSynchronize(), "cudaDeviceSynchronize");

cleanup:
  cudaFree(d_magnitude);
  cudaFree(d_indices);

  return status;
}

int ComputeTotalPowerGpu(const double* host_power_spectrum,
                         int length,
                         int batch_count,
                         double* host_total_power) {
  if(host_power_spectrum == nullptr || host_total_power == nullptr) {
    return STATUS_INVALID_ARGUMENT;
  }
  if(length <= 0 || batch_count <= 0) {
    return STATUS_INVALID_ARGUMENT;
  }

  auto& ctx = GpuContext::Instance();
  if(!ctx.IsInitialized()) {
    return STATUS_NOT_INITIALIZED;
  }

  size_t data_bytes = sizeof(double) * length * batch_count;
  size_t sums_bytes = sizeof(double) * batch_count;

  double *d_power = nullptr;
  double *d_sums = nullptr;

  int status = ToStatus(cudaMalloc(&d_power, data_bytes), "cudaMalloc power");
  if(status != STATUS_OK) return status;

  status = ToStatus(cudaMalloc(&d_sums, sums_bytes), "cudaMalloc sums");
  if(status != STATUS_OK) {
    cudaFree(d_power);
    return status;
  }

  status = ToStatus(cudaMemcpy(d_power, host_power_spectrum, data_bytes, cudaMemcpyHostToDevice), "memcpy power H2D");
  if(status != STATUS_OK) goto cleanup;

  {
    dim3 block(kBlockSize);
    dim3 grid(batch_count);
    size_t shared_mem = kBlockSize * sizeof(double);
    SumReductionKernel<<<grid, block, shared_mem>>>(d_power, length, batch_count, d_sums);

    status = ToStatus(cudaGetLastError(), "SumReductionKernel launch");
    if(status != STATUS_OK) goto cleanup;
  }

  status = ToStatus(cudaMemcpy(host_total_power, d_sums, sums_bytes, cudaMemcpyDeviceToHost), "memcpy sums D2H");
  if(status != STATUS_OK) goto cleanup;

  status = ToStatus(cudaDeviceSynchronize(), "cudaDeviceSynchronize");

cleanup:
  cudaFree(d_power);
  cudaFree(d_sums);

  return status;
}

} // namespace gpu
