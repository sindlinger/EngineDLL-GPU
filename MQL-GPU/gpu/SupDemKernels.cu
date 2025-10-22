#include "GpuContext.h"

#include <cmath>
#include <sstream>

namespace gpu {

namespace {

constexpr int kBlockSize = 256;

__global__ void ComputeSupDemVolumeKernel(const double* __restrict__ volume,
                                          double* __restrict__ media,
                                          double* __restrict__ banda_sup,
                                          int length,
                                          int periodo_media,
                                          double multip_desvio) {
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if(idx >= length) {
        return;
    }

    double value = volume[idx];

    if(periodo_media <= 1 || idx < periodo_media - 1) {
        media[idx] = value;
        banda_sup[idx] = value;
        return;
    }

    double sum = 0.0;
    double sum_sq = 0.0;
    for(int j = 0; j < periodo_media; ++j) {
        double v = volume[idx - j];
        sum += v;
        sum_sq += v * v;
    }

    double mean = sum / static_cast<double>(periodo_media);
    double variance = (sum_sq / static_cast<double>(periodo_media)) - (mean * mean);
    if(variance < 0.0) {
        variance = 0.0;
    }
    double stddev = std::sqrt(variance);
    media[idx] = mean;
    banda_sup[idx] = mean + multip_desvio * stddev;
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

int RunSupDemVolumeKernel(const double* volume,
                          const double* open,
                          const double* high,
                          const double* low,
                          const double* close,
                          double* media_out,
                          double* banda_sup_out,
                          int length,
                          int periodo_media,
                          double multip_desvio) {
    if(volume == nullptr || media_out == nullptr || banda_sup_out == nullptr) {
        return STATUS_INVALID_ARGUMENT;
    }
    if(length <= 0 || periodo_media <= 0) {
        return STATUS_INVALID_ARGUMENT;
    }
    auto& ctx = GpuContext::Instance();
    if(!ctx.IsInitialized()) {
        return STATUS_NOT_INITIALIZED;
    }
    SupDemResources& sup = ctx.SupDem();
    if(!sup.ready || sup.capacity < static_cast<size_t>(length)) {
        return STATUS_NOT_CONFIGURED;
    }

    size_t bytes = static_cast<size_t>(length) * sizeof(double);

    int status = ToStatus(cudaMemcpyAsync(sup.d_volume,
                                          volume,
                                          bytes,
                                          cudaMemcpyHostToDevice,
                                          sup.stream),
                          "SupDem copy volume");
    if(status != STATUS_OK) {
        return status;
    }

    if(open != nullptr && sup.d_open != nullptr) {
        status = ToStatus(cudaMemcpyAsync(sup.d_open,
                                          open,
                                          bytes,
                                          cudaMemcpyHostToDevice,
                                          sup.stream),
                          "SupDem copy open");
        if(status != STATUS_OK) {
            return status;
        }
    }
    if(high != nullptr && sup.d_high != nullptr) {
        status = ToStatus(cudaMemcpyAsync(sup.d_high,
                                          high,
                                          bytes,
                                          cudaMemcpyHostToDevice,
                                          sup.stream),
                          "SupDem copy high");
        if(status != STATUS_OK) {
            return status;
        }
    }
    if(low != nullptr && sup.d_low != nullptr) {
        status = ToStatus(cudaMemcpyAsync(sup.d_low,
                                          low,
                                          bytes,
                                          cudaMemcpyHostToDevice,
                                          sup.stream),
                          "SupDem copy low");
        if(status != STATUS_OK) {
            return status;
        }
    }
    if(close != nullptr && sup.d_close != nullptr) {
        status = ToStatus(cudaMemcpyAsync(sup.d_close,
                                          close,
                                          bytes,
                                          cudaMemcpyHostToDevice,
                                          sup.stream),
                          "SupDem copy close");
        if(status != STATUS_OK) {
            return status;
        }
    }

    int grid = (length + kBlockSize - 1) / kBlockSize;
    ComputeSupDemVolumeKernel<<<grid, kBlockSize, 0, sup.stream>>>(
        sup.d_volume,
        sup.d_media,
        sup.d_banda_sup,
        length,
        periodo_media,
        multip_desvio);
    status = ToStatus(cudaGetLastError(), "SupDem kernel launch");
    if(status != STATUS_OK) {
        return status;
    }

    status = ToStatus(cudaMemcpyAsync(media_out,
                                      sup.d_media,
                                      bytes,
                                      cudaMemcpyDeviceToHost,
                                      sup.stream),
                      "SupDem copy media back");
    if(status != STATUS_OK) {
        return status;
    }
    status = ToStatus(cudaMemcpyAsync(banda_sup_out,
                                      sup.d_banda_sup,
                                      bytes,
                                      cudaMemcpyDeviceToHost,
                                      sup.stream),
                      "SupDem copy banda back");
    if(status != STATUS_OK) {
        return status;
    }

    status = ToStatus(cudaStreamSynchronize(sup.stream), "SupDem stream sync");
    if(status != STATUS_OK) {
        return status;
    }

    return STATUS_OK;
}

} // namespace gpu
