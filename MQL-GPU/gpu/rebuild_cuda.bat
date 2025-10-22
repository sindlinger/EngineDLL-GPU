@echo off
setlocal

set "VCVARS=C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
set "CMAKE=C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"

call "%VCVARS%"
if errorlevel 1 (
    echo [ERRO] Falha ao inicializar ambiente do Visual Studio.
    exit /b 1
)

set "SRC_DIR=%~dp0"
if "%SRC_DIR:~-1%"=="\" set "SRC_DIR=%SRC_DIR:~0,-1%"
set "BUILD_DIR=%SRC_DIR%\build"

"%CMAKE%" -S "%SRC_DIR%" -B "%BUILD_DIR%" -G "Visual Studio 17 2022" -A x64 -DCMAKE_BUILD_TYPE=Release
if errorlevel 1 (
    echo [ERRO] cmake configure falhou.
    exit /b 1
)

"%CMAKE%" --build "%BUILD_DIR%" --config Release --target GpuBridge > "%BUILD_DIR%\\build_output.log" 2>&1
if errorlevel 1 (
    echo [ERRO] cmake build falhou. Consulte %BUILD_DIR%\build_output.log
    type "%BUILD_DIR%\build_output.log"
    exit /b 1
)

echo [OK] GpuBridge.dll recompilada em:
echo        %BUILD_DIR%\Release\GpuBridge.dll
type "%BUILD_DIR%\build_output.log"
exit /b 0
