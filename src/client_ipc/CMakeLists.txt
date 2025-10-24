set(BIN_DIR "${GPU_CANONICAL_BIN}")
if(NOT IS_ABSOLUTE "${BIN_DIR}")
    set(BIN_DIR "${CMAKE_SOURCE_DIR}/${BIN_DIR}")
endif()

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_library(GpuEngineClient SHARED
    src/Client.cpp
)

target_include_directories(GpuEngineClient
    PRIVATE
        ${PROJECT_SOURCE_DIR}/include/client_ipc
        ${PROJECT_SOURCE_DIR}/include/ipc
        ${PROJECT_SOURCE_DIR}/include/engine_core
)

target_compile_definitions(GpuEngineClient PRIVATE GPU_ENGINE_BUILD)

set_target_properties(GpuEngineClient PROPERTIES
    OUTPUT_NAME "GpuEngineClient"
    RUNTIME_OUTPUT_DIRECTORY "${BIN_DIR}"
    LIBRARY_OUTPUT_DIRECTORY "${BIN_DIR}"
    ARCHIVE_OUTPUT_DIRECTORY "${BIN_DIR}"
    EXPORT_COMPILE_COMMANDS ON)
