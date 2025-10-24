set(BIN_DIR "${GPU_CANONICAL_BIN}")
if(NOT IS_ABSOLUTE "${BIN_DIR}")
    set(BIN_DIR "${CMAKE_SOURCE_DIR}/${BIN_DIR}")
endif()

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_executable(GpuEngineService
    src/main.cpp
    src/Service.cpp
    src/PipeServer.cpp
)

target_include_directories(GpuEngineService
    PRIVATE
        ${PROJECT_SOURCE_DIR}/include/service
        ${PROJECT_SOURCE_DIR}/include/ipc
        ${PROJECT_SOURCE_DIR}/include/engine_core
)

target_link_libraries(GpuEngineService PRIVATE GpuEngine)

set_target_properties(GpuEngineService PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY "${BIN_DIR}"
    EXPORT_COMPILE_COMMANDS ON)
