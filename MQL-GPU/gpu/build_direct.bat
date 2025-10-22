@echo off
REM Compilacao direta com NVCC (sem CMake)
setlocal

set CUDA_PATH=C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v13.0
set PATH=%CUDA_PATH%\bin;%PATH%

echo ========================================
echo Building GpuBridge.dll - Direct NVCC
echo ========================================

cd /d "%~dp0"

REM Compile all .cu files
nvcc -shared -o GpuBridge.dll ^
  -arch=sm_75 ^
  -O3 ^
  -use_fast_math ^
  --compiler-options "/MD /EHsc /W3 /wd4819" ^
  BatchWaveformFft.cu ^
  WaveformFft.cu ^
  CwtKernels.cu ^
  SupDemKernels.cu ^
  SpectralAnalysisKernels.cu ^
  GpuContext.cpp ^
  GpuStatus.cpp ^
  GpuLogger.cpp ^
  exports.cpp ^
  dllmain.cpp ^
  -lcufft

if %ERRORLEVEL% NEQ 0 (
    echo.
    echo ====================================
    echo Build FAILED!
    echo ====================================
    pause
    exit /b 1
)

echo.
echo ====================================
echo Build SUCCESS!
echo ====================================
echo DLL: %CD%\GpuBridge.dll

dir GpuBridge.dll

pause
