cmake_minimum_required(VERSION 3.21)
project(GpuEngine LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_WINDOWS_EXPORT_ALL_SYMBOLS ON)

add_library(GpuEngine SHARED
    src/GpuEngineCore.cpp
    src/exports.cpp
)

target_include_directories(GpuEngine PUBLIC include)

target_compile_definitions(GpuEngine PRIVATE GPU_ENGINE_BUILD)
