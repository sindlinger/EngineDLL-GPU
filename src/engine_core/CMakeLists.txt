cmake_minimum_required(VERSION 3.21)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CUDA_STANDARD 17)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

find_package(CUDAToolkit REQUIRED)

set(BIN_DIR "${GPU_CANONICAL_BIN}")
if(NOT IS_ABSOLUTE "${BIN_DIR}")
    set(BIN_DIR "${CMAKE_SOURCE_DIR}/${BIN_DIR}")
endif()

set(CUDA_DEVRT_LIBRARY "${BIN_DIR}/cudadevrt.lib")
if(NOT EXISTS "${CUDA_DEVRT_LIBRARY}")
    message(FATAL_ERROR "cudadevrt library not found at ${CUDA_DEVRT_LIBRARY}")
endif()

set(CMAKE_CUDA_ARCHITECTURES "86")

add_library(GpuEngine SHARED
    src/GpuEngineCore.cpp
    src/CudaProcessor.cu
    src/exports.cpp
)

target_include_directories(GpuEngine
    PUBLIC
        ${PROJECT_SOURCE_DIR}/include/engine_core
        ${CUDAToolkit_INCLUDE_DIRS}
)

target_link_libraries(GpuEngine
    PRIVATE
        CUDA::cufft
        CUDA::cudart
        "${CUDA_DEVRT_LIBRARY}"
)

set_target_properties(GpuEngine PROPERTIES
    CUDA_SEPARABLE_COMPILATION ON
    CUDA_EXTENSIONS OFF
    CUDA_ARCHITECTURES "${CMAKE_CUDA_ARCHITECTURES}"
    CUDA_RESOLVE_DEVICE_SYMBOLS ON
    CUDA_RUNTIME_LIBRARY Hybrid
    RUNTIME_OUTPUT_DIRECTORY "${BIN_DIR}"
    LIBRARY_OUTPUT_DIRECTORY "${BIN_DIR}"
    ARCHIVE_OUTPUT_DIRECTORY "${BIN_DIR}"
    EXPORT_COMPILE_COMMANDS ON
)
