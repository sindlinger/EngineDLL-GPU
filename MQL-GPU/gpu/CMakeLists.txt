cmake_minimum_required(VERSION 3.21)
project(GpuBridge LANGUAGES CXX CUDA)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

if(NOT WIN32)
    message(WARNING "GpuBridge DLL is intended for Windows MetaTrader deployments.")
endif()

add_library(GpuBridge SHARED
    exports.cpp
    GpuContext.cpp
    GpuLogger.cpp
    GpuStatus.cpp
)

if(WIN32)
    target_sources(GpuBridge PRIVATE dllmain.cpp)
endif()

target_include_directories(GpuBridge PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})

find_package(CUDAToolkit REQUIRED)

target_link_libraries(GpuBridge PRIVATE CUDA::cudart CUDA::cufft)

set_target_properties(GpuBridge PROPERTIES
    CUDA_SEPARABLE_COMPILATION ON
    CUDA_ARCHITECTURES 86
    WINDOWS_EXPORT_ALL_SYMBOLS OFF
    OUTPUT_NAME "GpuBridge"
)

target_sources(GpuBridge PRIVATE
    WaveformFft.cu
    BatchWaveformFft.cu
    SupDemKernels.cu
    CwtKernels.cu
    SpectralAnalysisKernels.cu
)
