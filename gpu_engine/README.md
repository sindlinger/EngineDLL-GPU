# GpuEngine Prototype

This folder contains the initial C++ scaffolding for the asynchronous GPU engine.
It mirrors the API described in `docs/GpuEngine_API.md` and currently provides a
CPU-only placeholder that simulates the job queue/worker pipeline.

Key components:

- `include/GpuEngineTypes.h` – structs/enums shared between the DLL and wrappers.
- `include/GpuEngineJob.h` – job record used by the internal queue.
- `include/GpuEngineCore.h` – `gpuengine::Engine` class managing the queue and workers.
- `src/GpuEngineCore.cpp` – placeholder implementation (copies input to output).
- `src/exports.cpp` – `extern "C"` interface for the DLL expected by MQL.

To complete the implementation you need to replace the placeholder processing in
`CopyFramesToOutput()` with the actual CUDA pipeline (cuFFT, masks, IFFT, etc.),
add proper pinned buffers/streams, and compile the project into `GpuEngine.dll`.
