# GPU Setup & Validation

## Prerequisites
- Windows 10/11 x64 with MetaTrader 5 installed under `C:\Users\pichau\AppData\Roaming\MetaQuotes\Terminal\3CA1B4AB7DFED5C81B1C7F1007926D06`.
- NVIDIA RTX A4500 (SM 86) with Studio or Game Ready driver ≥ 536.xx.
- CUDA Toolkit 12.3 (or newer) plus Visual Studio 2022 with Desktop C++ workload and the “CUDA” integration.
- CMake ≥ 3.21 for generating the build files.

## Build Steps
```powershell
cmake -S gpu -B build -G "Visual Studio 17 2022" -A x64 -DCMAKE_BUILD_TYPE=Release
cmake --build build --config Release --target GpuBridge
```
The resulting `GpuBridge.dll` is placed in `build\Release\`. Copy it to:
```
C:\Users\pichau\AppData\Roaming\MetaQuotes\Terminal\3CA1B4AB7DFED5C81B1C7F1007926D06\MQL5\Libraries
```

## MetaTrader Configuration
- In each Expert Advisor/Indicator input, enable **Allow DLL imports**.
- In Strategy Tester, open the EA’s “Settings → Common” tab and enable DLL imports before running optimizations.
- Confirm the platform is running 64-bit; the DLL exports are x64 only.

## Runtime Diagnostics
- The DLL writes to `gpu_runtime.log` (same directory as the DLL). Inspect it after each tester pass to confirm status codes (`status=0`).
- Use `nvidia-smi dmon -s pucm` in a separate terminal to watch utilization and memory usage while MetaTrader runs optimizations.
- Any non-zero status returned to MQL5 forces the EA to call `ExpertRemove()`; investigate the log rather than retrying with CPU.

## Validation Checklist
1. Run the Waveform indicator alone on a chart; it should log successful GPU configuration and plot without CPU fallback.
2. Load the SupDem volume profile indicator; verify that `RunSupDemVolume` returns `status=0` in `gpu_runtime.log` and that the volume bands appear instantly.
3. Execute a short Strategy Tester optimization (e.g., 10 passes). Record the elapsed time and compare against historical CPU-only runs.
4. When adding new kernels, repeat steps 1–3, keeping before/after performance notes in pull requests.

## Troubleshooting
- `STATUS_DEVICE_ERROR`: verify the correct GPU is selected and no other process monopolizes the device; reboot if the CUDA context is wedged.
- `STATUS_PLAN_ERROR`: ensure the FFT window size is supported; cuFFT requires power-of-two lengths when using the current plan.
- `STATUS_NOT_CONFIGURED`: the EA called a GPU routine before configuration—confirm `GpuConfigureWaveform` is invoked at init.
- `STATUS_UNSUPPORTED`: indicates an outdated DLL; rebuild the CUDA project to ensure SupDem kernels are included.
