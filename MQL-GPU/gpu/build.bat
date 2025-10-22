@echo off
cd /d "%~dp0"
if not exist "build" mkdir build
cd build
cmake -G "Visual Studio 17 2022" -A x64 ..
cmake --build . --config Release
if %ERRORLEVEL% EQU 0 (
    echo.
    echo ====================================
    echo Build successful!
    echo ====================================
    copy /Y Release\GpuBridge.dll ..\..\Libraries\
    echo DLL copied to Libraries folder
) else (
    echo.
    echo ====================================
    echo Build FAILED!
    echo ====================================
)
pause
