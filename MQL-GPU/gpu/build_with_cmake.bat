@echo off
echo ========================================
echo Building GpuBridge.dll with BATCH FFT
echo ========================================

cd /d "%~dp0"

REM Adicionar CMake ao PATH
set "CMAKE_PATH=C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin"
set "PATH=%CMAKE_PATH%;%PATH%"

REM Verificar CMake
cmake --version
if %ERRORLEVEL% NEQ 0 (
    echo ERROR: CMake not found!
    pause
    exit /b 1
)

REM Limpar build anterior
if exist "build" rmdir /s /q build
mkdir build
cd build

REM Configurar com CMake
echo.
echo Configuring with CMake...
cmake -G "Visual Studio 17 2022" -A x64 ..
if %ERRORLEVEL% NEQ 0 (
    echo ERROR: CMake configuration failed!
    cd ..
    pause
    exit /b 1
)

REM Compilar
echo.
echo Building Release...
cmake --build . --config Release
if %ERRORLEVEL% NEQ 0 (
    echo.
    echo ====================================
    echo Build FAILED!
    echo ====================================
    cd ..
    pause
    exit /b 1
)

REM Copiar DLL
echo.
echo ====================================
echo Build successful!
echo ====================================
copy /Y Release\GpuBridge.dll ..\..\Libraries\
if %ERRORLEVEL% EQU 0 (
    echo DLL copied to Libraries folder
    dir ..\..\Libraries\GpuBridge.dll
) else (
    echo ERROR: Failed to copy DLL!
)

cd ..
pause
