#include "GpuStatus.h"

namespace gpu {

const char* StatusToString(int code) {
    switch(static_cast<Status>(code)) {
        case STATUS_OK: return "success";
        case STATUS_NOT_INITIALIZED: return "GPU context not initialized";
        case STATUS_ALREADY_INITIALIZED: return "GPU context already initialized";
        case STATUS_INVALID_ARGUMENT: return "invalid argument";
        case STATUS_DEVICE_ERROR: return "CUDA device error";
        case STATUS_MEMORY_ERROR: return "CUDA memory allocation error";
        case STATUS_PLAN_ERROR: return "cuFFT plan creation error";
        case STATUS_EXECUTION_ERROR: return "execution error";
        case STATUS_NOT_CONFIGURED: return "resources not configured";
        case STATUS_UNSUPPORTED: return "operation unsupported";
        case STATUS_INTERNAL_ERROR: return "internal error";
        default: return "unknown status";
    }
}

} // namespace gpu
