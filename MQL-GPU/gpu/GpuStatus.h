#pragma once

// GPU status codes shared between the CUDA DLL and MQL5 callers.
// Non-zero values indicate fatal conditions (GPU-only execution).
namespace gpu {

enum Status : int {
    STATUS_OK = 0,
    STATUS_NOT_INITIALIZED = -1,
    STATUS_ALREADY_INITIALIZED = -2,
    STATUS_INVALID_ARGUMENT = -3,
    STATUS_DEVICE_ERROR = -4,
    STATUS_MEMORY_ERROR = -5,
    STATUS_PLAN_ERROR = -6,
    STATUS_EXECUTION_ERROR = -7,
    STATUS_NOT_CONFIGURED = -8,
    STATUS_UNSUPPORTED = -9,
    STATUS_INTERNAL_ERROR = -10
};

const char* StatusToString(int code);

} // namespace gpu
