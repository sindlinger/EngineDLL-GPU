#include "GpuContext.h"

#include <sstream>

namespace gpu {

namespace {

void SafeCudaFree(void* ptr) {
    if(ptr) {
        cudaFree(ptr);
    }
}

void SafeCudaFreeHost(void* ptr) {
    if(ptr) {
        cudaFreeHost(ptr);
    }
}

void SafeStreamDestroy(cudaStream_t stream) {
    if(stream) {
        cudaStreamDestroy(stream);
    }
}

void SafePlanDestroy(cufftHandle plan) {
    if(plan != 0) {
        cufftDestroy(plan);
    }
}

} // namespace

WaveformResources::WaveformResources()
    : length(0),
      plan(0),
      plan_inverse(0),
      d_input(nullptr),
      d_fft(nullptr),
      d_real(nullptr),
      d_imag(nullptr),
      stream_fft(nullptr),
      stream_post(nullptr),
      ready(false) {}

void WaveformResources::Reset() {
    SafePlanDestroy(plan);
    plan = 0;
    SafePlanDestroy(plan_inverse);
    plan_inverse = 0;
    SafeCudaFree(d_input);
    SafeCudaFree(d_fft);
    SafeCudaFree(d_real);
    SafeCudaFree(d_imag);
    d_input = nullptr;
    d_fft = nullptr;
    d_real = nullptr;
    d_imag = nullptr;
    SafeStreamDestroy(stream_fft);
    SafeStreamDestroy(stream_post);
    stream_fft = nullptr;
    stream_post = nullptr;
    length = 0;
    ready = false;
}

SupDemResources::SupDemResources()
    : capacity(0),
      d_volume(nullptr),
      d_media(nullptr),
      d_banda_sup(nullptr),
      d_high(nullptr),
      d_low(nullptr),
      d_open(nullptr),
      d_close(nullptr),
      d_flags(nullptr),
      stream(nullptr),
      ready(false) {}

void SupDemResources::Reset() {
    SafeCudaFree(d_volume);
    SafeCudaFree(d_media);
    SafeCudaFree(d_banda_sup);
    SafeCudaFree(d_high);
    SafeCudaFree(d_low);
    SafeCudaFree(d_open);
    SafeCudaFree(d_close);
    SafeCudaFree(d_flags);
    d_volume = nullptr;
    d_media = nullptr;
    d_banda_sup = nullptr;
    d_high = nullptr;
    d_low = nullptr;
    d_open = nullptr;
    d_close = nullptr;
    d_flags = nullptr;
    SafeStreamDestroy(stream);
    stream = nullptr;
    capacity = 0;
    ready = false;
}

CwtResources::CwtResources()
    : signal_length(0),
      num_scales(0),
      d_signal(nullptr),
      d_scales(nullptr),
      d_cwt_coeffs(nullptr),
      d_reconstruction(nullptr),
      stream(nullptr),
      ready(false) {}

void CwtResources::Reset() {
    SafeCudaFree(d_signal);
    SafeCudaFree(d_scales);
    SafeCudaFree(d_cwt_coeffs);
    SafeCudaFree(d_reconstruction);
    d_signal = nullptr;
    d_scales = nullptr;
    d_cwt_coeffs = nullptr;
    d_reconstruction = nullptr;
    SafeStreamDestroy(stream);
    stream = nullptr;
    signal_length = 0;
    num_scales = 0;
    ready = false;
}

BatchWaveformResources::BatchWaveformResources()
    : fft_size(0),
      max_batch_count(0),
      plan_batch(0),
      d_input_batch(nullptr),
      d_fft_batch(nullptr),
      d_real_batch(nullptr),
      d_imag_batch(nullptr),
      stream(nullptr),
      ready(false) {}

void BatchWaveformResources::Reset() {
    SafePlanDestroy(plan_batch);
    plan_batch = 0;
    SafeCudaFree(d_input_batch);
    SafeCudaFree(d_fft_batch);
    SafeCudaFree(d_real_batch);
    SafeCudaFree(d_imag_batch);
    d_input_batch = nullptr;
    d_fft_batch = nullptr;
    d_real_batch = nullptr;
    d_imag_batch = nullptr;
    SafeStreamDestroy(stream);
    stream = nullptr;
    fft_size = 0;
    max_batch_count = 0;
    ready = false;
}

GpuContext& GpuContext::Instance() {
    static GpuContext ctx;
    return ctx;
}

GpuContext::GpuContext()
    : device_id_(0),
      initialized_(false),
      waveform_(),
      supdem_(),
      cwt_() {}

GpuContext::~GpuContext() {
    Shutdown();
}

int GpuContext::Initialize(int device_id) {
    std::lock_guard<std::mutex> lock(mutex_);
    if(initialized_) {
        return STATUS_ALREADY_INITIALIZED;
    }

    int device_count = 0;
    cudaError_t err = cudaGetDeviceCount(&device_count);
    if(err != cudaSuccess || device_count <= 0) {
        LogMessage("cudaGetDeviceCount failed or no CUDA devices available");
        return STATUS_DEVICE_ERROR;
    }

    if(device_id < 0 || device_id >= device_count) {
        std::ostringstream oss;
        oss << "invalid device id " << device_id << ", total=" << device_count;
        LogMessage(oss.str());
        return STATUS_INVALID_ARGUMENT;
    }

    err = cudaSetDevice(device_id);
    if(err != cudaSuccess) {
        std::ostringstream oss;
        oss << "cudaSetDevice failed err=" << static_cast<int>(err);
        LogMessage(oss.str());
        return STATUS_DEVICE_ERROR;
    }

    device_id_ = device_id;
    initialized_ = true;
    LogMessage("GPU context initialized");
    return STATUS_OK;
}

void GpuContext::Shutdown() {
    std::lock_guard<std::mutex> lock(mutex_);
    if(!initialized_) {
        return;
    }

    waveform_.Reset();
    supdem_.Reset();
    cwt_.Reset();

    cudaDeviceReset();
    initialized_ = false;
    LogMessage("GPU context shutdown");
}

int GpuContext::ConfigureWaveform(size_t length) {
    std::lock_guard<std::mutex> lock(mutex_);
    if(!initialized_) {
        return STATUS_NOT_INITIALIZED;
    }
    if(length == 0) {
        return STATUS_INVALID_ARGUMENT;
    }

    if(waveform_.ready && waveform_.length == length) {
        return STATUS_OK;
    }

    waveform_.Reset();
    waveform_.length = length;

    cudaError_t err_fft_stream = cudaStreamCreateWithFlags(&waveform_.stream_fft, cudaStreamNonBlocking);
    if(err_fft_stream != cudaSuccess) {
        waveform_.Reset();
        LogMessage("cudaStreamCreate (fft) failed");
        return STATUS_DEVICE_ERROR;
    }

    cudaError_t err_post_stream = cudaStreamCreateWithFlags(&waveform_.stream_post, cudaStreamNonBlocking);
    if(err_post_stream != cudaSuccess) {
        waveform_.Reset();
        LogMessage("cudaStreamCreate (post) failed");
        return STATUS_DEVICE_ERROR;
    }

    size_t real_bytes = sizeof(double) * length;
    size_t complex_bytes = sizeof(cufftDoubleComplex) * length;

    if(cudaMalloc(reinterpret_cast<void**>(&waveform_.d_input), real_bytes) != cudaSuccess ||
       cudaMalloc(reinterpret_cast<void**>(&waveform_.d_fft), complex_bytes) != cudaSuccess ||
       cudaMalloc(reinterpret_cast<void**>(&waveform_.d_real), real_bytes) != cudaSuccess ||
       cudaMalloc(reinterpret_cast<void**>(&waveform_.d_imag), real_bytes) != cudaSuccess) {
        waveform_.Reset();
        LogMessage("cudaMalloc failed for waveform buffers");
        return STATUS_MEMORY_ERROR;
    }

    if(cufftPlan1d(&waveform_.plan, static_cast<int>(length), CUFFT_D2Z, 1) != CUFFT_SUCCESS) {
        waveform_.Reset();
        LogMessage("cufftPlan1d failed");
        return STATUS_PLAN_ERROR;
    }

    if(cufftSetStream(waveform_.plan, waveform_.stream_fft) != CUFFT_SUCCESS) {
        waveform_.Reset();
        LogMessage("cufftSetStream failed");
        return STATUS_PLAN_ERROR;
    }

    // Create inverse FFT plan (Z2D)
    if(cufftPlan1d(&waveform_.plan_inverse, static_cast<int>(length), CUFFT_Z2D, 1) != CUFFT_SUCCESS) {
        waveform_.Reset();
        LogMessage("cufftPlan1d (inverse) failed");
        return STATUS_PLAN_ERROR;
    }

    if(cufftSetStream(waveform_.plan_inverse, waveform_.stream_fft) != CUFFT_SUCCESS) {
        waveform_.Reset();
        LogMessage("cufftSetStream (inverse) failed");
        return STATUS_PLAN_ERROR;
    }

    waveform_.ready = true;
    std::ostringstream oss;
    oss << "Waveform configured length=" << length;
    LogMessage(oss.str());
    return STATUS_OK;
}

int GpuContext::ConfigureSupDem(size_t capacity) {
    std::lock_guard<std::mutex> lock(mutex_);
    if(!initialized_) {
        return STATUS_NOT_INITIALIZED;
    }
    if(capacity == 0) {
        return STATUS_INVALID_ARGUMENT;
    }

    if(supdem_.ready && supdem_.capacity >= capacity) {
        return STATUS_OK;
    }

    supdem_.Reset();
    supdem_.capacity = capacity;

    if(cudaStreamCreateWithFlags(&supdem_.stream, cudaStreamNonBlocking) != cudaSuccess) {
        supdem_.Reset();
        LogMessage("cudaStreamCreate failed for SupDem");
        return STATUS_DEVICE_ERROR;
    }

    size_t bytes = sizeof(double) * capacity;
    size_t int_bytes = sizeof(int) * capacity;

    if(cudaMalloc(reinterpret_cast<void**>(&supdem_.d_volume), bytes) != cudaSuccess ||
       cudaMalloc(reinterpret_cast<void**>(&supdem_.d_media), bytes) != cudaSuccess ||
       cudaMalloc(reinterpret_cast<void**>(&supdem_.d_banda_sup), bytes) != cudaSuccess ||
       cudaMalloc(reinterpret_cast<void**>(&supdem_.d_high), bytes) != cudaSuccess ||
       cudaMalloc(reinterpret_cast<void**>(&supdem_.d_low), bytes) != cudaSuccess ||
       cudaMalloc(reinterpret_cast<void**>(&supdem_.d_open), bytes) != cudaSuccess ||
       cudaMalloc(reinterpret_cast<void**>(&supdem_.d_close), bytes) != cudaSuccess ||
       cudaMalloc(reinterpret_cast<void**>(&supdem_.d_flags), int_bytes) != cudaSuccess) {
        supdem_.Reset();
        LogMessage("cudaMalloc failed for SupDem buffers");
        return STATUS_MEMORY_ERROR;
    }

    supdem_.ready = true;
    std::ostringstream oss;
    oss << "SupDem configured capacity=" << capacity;
    LogMessage(oss.str());
    return STATUS_OK;
}

int GpuContext::ConfigureCwt(size_t signal_length, size_t num_scales) {
    std::lock_guard<std::mutex> lock(mutex_);
    if(!initialized_) {
        return STATUS_NOT_INITIALIZED;
    }
    if(signal_length == 0 || num_scales == 0) {
        return STATUS_INVALID_ARGUMENT;
    }

    // Check if already configured with same dimensions
    if(cwt_.ready &&
       cwt_.signal_length == signal_length &&
       cwt_.num_scales == num_scales) {
        return STATUS_OK;
    }

    cwt_.Reset();
    cwt_.signal_length = signal_length;
    cwt_.num_scales = num_scales;

    // Create CUDA stream
    if(cudaStreamCreateWithFlags(&cwt_.stream, cudaStreamNonBlocking) != cudaSuccess) {
        cwt_.Reset();
        LogMessage("cudaStreamCreate failed for CWT");
        return STATUS_DEVICE_ERROR;
    }

    // Allocate device memory
    size_t signal_bytes = sizeof(double) * signal_length;
    size_t scales_bytes = sizeof(double) * num_scales;
    size_t coeffs_bytes = sizeof(double) * num_scales;
    size_t reconstruction_bytes = sizeof(double);  // Single value per position

    if(cudaMalloc(reinterpret_cast<void**>(&cwt_.d_signal), signal_bytes) != cudaSuccess ||
       cudaMalloc(reinterpret_cast<void**>(&cwt_.d_scales), scales_bytes) != cudaSuccess ||
       cudaMalloc(reinterpret_cast<void**>(&cwt_.d_cwt_coeffs), coeffs_bytes) != cudaSuccess ||
       cudaMalloc(reinterpret_cast<void**>(&cwt_.d_reconstruction), reconstruction_bytes) != cudaSuccess) {
        cwt_.Reset();
        LogMessage("cudaMalloc failed for CWT buffers");
        return STATUS_MEMORY_ERROR;
    }

    cwt_.ready = true;
    std::ostringstream oss;
    oss << "CWT configured signal_length=" << signal_length << " num_scales=" << num_scales;
    LogMessage(oss.str());
    return STATUS_OK;
}

int GpuContext::ConfigureBatchWaveform(size_t fft_size, size_t max_batch_count) {
    std::lock_guard<std::mutex> lock(mutex_);
    if(!initialized_) {
        return STATUS_NOT_INITIALIZED;
    }
    if(fft_size == 0 || max_batch_count == 0) {
        return STATUS_INVALID_ARGUMENT;
    }

    // Check if already configured with same or larger capacity
    if(batch_waveform_.ready &&
       batch_waveform_.fft_size == fft_size &&
       batch_waveform_.max_batch_count >= max_batch_count) {
        return STATUS_OK;
    }

    batch_waveform_.Reset();
    batch_waveform_.fft_size = fft_size;
    batch_waveform_.max_batch_count = max_batch_count;

    // Create CUDA stream for batch operations
    if(cudaStreamCreateWithFlags(&batch_waveform_.stream, cudaStreamNonBlocking) != cudaSuccess) {
        batch_waveform_.Reset();
        LogMessage("cudaStreamCreate failed for BatchWaveform");
        return STATUS_DEVICE_ERROR;
    }

    // Create cuFFT plan for batch processing
    int rank = 1;
    int n[] = {static_cast<int>(fft_size)};
    int istride = 1, ostride = 1;
    int idist = static_cast<int>(fft_size);
    int odist = static_cast<int>(fft_size);
    int inembed[] = {static_cast<int>(fft_size)};
    int onembed[] = {static_cast<int>(fft_size)};

    cufftResult res = cufftPlanMany(&batch_waveform_.plan_batch,
                                    rank,
                                    n,
                                    inembed, istride, idist,
                                    onembed, ostride, odist,
                                    CUFFT_D2Z,
                                    static_cast<int>(max_batch_count));

    if(res != CUFFT_SUCCESS) {
        batch_waveform_.Reset();
        std::ostringstream oss;
        oss << "cufftPlanMany failed fft_size=" << fft_size << " batch=" << max_batch_count;
        LogMessage(oss.str());
        return STATUS_EXECUTION_ERROR;
    }

    // Associate stream with plan
    cufftSetStream(batch_waveform_.plan_batch, batch_waveform_.stream);

    // Allocate persistent GPU memory
    size_t total_real_bytes = sizeof(double) * fft_size * max_batch_count;
    size_t total_complex_bytes = sizeof(cufftDoubleComplex) * fft_size * max_batch_count;

    if(cudaMalloc(reinterpret_cast<void**>(&batch_waveform_.d_input_batch), total_real_bytes) != cudaSuccess ||
       cudaMalloc(reinterpret_cast<void**>(&batch_waveform_.d_fft_batch), total_complex_bytes) != cudaSuccess ||
       cudaMalloc(reinterpret_cast<void**>(&batch_waveform_.d_real_batch), total_real_bytes) != cudaSuccess ||
       cudaMalloc(reinterpret_cast<void**>(&batch_waveform_.d_imag_batch), total_real_bytes) != cudaSuccess) {
        batch_waveform_.Reset();
        LogMessage("cudaMalloc failed for BatchWaveform buffers");
        return STATUS_MEMORY_ERROR;
    }

    batch_waveform_.ready = true;
    std::ostringstream oss;
    oss << "BatchWaveform configured fft_size=" << fft_size << " max_batch=" << max_batch_count
        << " mem=" << ((total_real_bytes * 3 + total_complex_bytes) / (1024*1024)) << "MB";
    LogMessage(oss.str());
    return STATUS_OK;
}

} // namespace gpu
