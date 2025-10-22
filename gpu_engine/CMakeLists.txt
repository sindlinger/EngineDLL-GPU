cmake_minimum_required(VERSION 3.21)
project(GpuEngine LANGUAGES CXX CUDA)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CUDA_STANDARD 17)
set(CMAKE_WINDOWS_EXPORT_ALL_SYMBOLS ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

if(NOT CMAKE_CONFIGURATION_TYPES AND NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

find_package(CUDAToolkit REQUIRED)

add_library(GpuEngine SHARED
    src/GpuEngineCore.cpp
    src/CudaProcessor.cu
    src/exports.cpp
)

target_include_directories(GpuEngine
    PUBLIC
        include
        ${CUDAToolkit_INCLUDE_DIRS}
)

target_link_libraries(GpuEngine
    PRIVATE
        CUDA::cufft
        CUDA::cudart
)

set(CMAKE_CUDA_ARCHITECTURES "86")

set_target_properties(GpuEngine PROPERTIES
    CUDA_SEPARABLE_COMPILATION ON
    CUDA_EXTENSIONS OFF
    CUDA_ARCHITECTURES "${CMAKE_CUDA_ARCHITECTURES}"
)

target_compile_definitions(GpuEngine PRIVATE GPU_ENGINE_BUILD)
