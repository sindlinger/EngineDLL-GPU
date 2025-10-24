cmake_minimum_required(VERSION 3.21)
project(WaveSpecGPU LANGUAGES CXX CUDA)

set(CMAKE_POSITION_INDEPENDENT_CODE ON)

if(NOT DEFINED GPU_CANONICAL_BIN)
    set(GPU_CANONICAL_BIN "${CMAKE_SOURCE_DIR}/bin" CACHE PATH "Canonical output directory for GPU binaries")
endif()

add_subdirectory(src/engine_core)
add_subdirectory(src/client_ipc)
add_subdirectory(src/service)
