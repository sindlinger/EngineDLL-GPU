@echo off
echo ========================================
echo Building GpuBridge.dll with IFFT
echo ========================================
cd /d "%~dp0"

REM Try common Visual Studio CMake locations
set CMAKE_PATHS[0]="C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"
set CMAKE_PATHS[1]="C:\Program Files\Microsoft Visual Studio\2022\Professional\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"
set CMAKE_PATHS[2]="C:\Program Files\Microsoft Visual Studio\2022\Enterprise\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"
set CMAKE_PATHS[3]="C:\Program Files\CMake\bin\cmake.exe"

set CMAKE_EXE=
for /L %%i in (0,1,3) do (
    if exist !CMAKE_PATHS[%%i]! (
        set CMAKE_EXE=!CMAKE_PATHS[%%i]!
        goto :found
    )
)

:found
if "%CMAKE_EXE%"=="" (
    echo ERROR: CMake not found!
    echo Please install CMake or Visual Studio 2022
    pause
    exit /b 1
)

echo Using CMake: %CMAKE_EXE%
echo.

if not exist "build" mkdir build
cd build

%CMAKE_EXE% -G "Visual Studio 17 2022" -A x64 ..
if %ERRORLEVEL% NEQ 0 goto :error

%CMAKE_EXE% --build . --config Release
if %ERRORLEVEL% NEQ 0 goto :error

echo.
echo ====================================
echo Build SUCCESS!
echo ====================================
copy /Y Release\GpuBridge.dll ..\..\Libraries\
if %ERRORLEVEL% EQU 0 (
    echo DLL copied to Libraries folder
)
pause
exit /b 0

:error
echo.
echo ====================================
echo Build FAILED!
echo ====================================
pause
exit /b 1
