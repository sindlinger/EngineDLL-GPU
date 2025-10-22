@echo off
echo ========================================
echo Verifying GpuBridge.dll Deployment
echo ========================================

set SOURCE_DLL="%~dp0gpu\build\Release\GpuBridge.dll"
set TOTAL_FOUND=0
set TOTAL_MISSING=0

echo.
echo Source DLL: %SOURCE_DLL%
for %%F in (%SOURCE_DLL%) do echo Size: %%~zF bytes
echo.

REM ========================================
REM Check Main Libraries
REM ========================================
echo === Main Libraries ===
if exist "%~dp0Libraries\GpuBridge.dll" (
    echo [OK] %~dp0Libraries\GpuBridge.dll
    set /A TOTAL_FOUND+=1
) else (
    echo [MISSING] %~dp0Libraries\GpuBridge.dll
    set /A TOTAL_MISSING+=1
)

REM ========================================
REM Check Dukascopy Agents
REM ========================================
echo.
echo === Dukascopy MT5 Agents ===
for /L %%i in (2000,1,2008) do (
    set "DLL_PATH=C:\Program Files\Dukascopy MetaTrader 5\Tester\Agent-0.0.0.0-%%i\MQL5\Libraries\GpuBridge.dll"
    if exist "!DLL_PATH!" (
        echo [OK] Dukascopy Agent %%i
        set /A TOTAL_FOUND+=1
    ) else (
        if exist "C:\Program Files\Dukascopy MetaTrader 5\Tester\Agent-0.0.0.0-%%i" (
            echo [MISSING] Dukascopy Agent %%i
            set /A TOTAL_MISSING+=1
        )
    )
)

REM ========================================
REM Check Standard MT5 Agents
REM ========================================
echo.
echo === Standard MT5 Agents ===
for /L %%i in (2000,1,2015) do (
    set "DLL_PATH=C:\Program Files\MetaTrader 5\Tester\Agent-0.0.0.0-%%i\MQL5\Libraries\GpuBridge.dll"
    if exist "!DLL_PATH!" (
        echo [OK] Standard Agent %%i
        set /A TOTAL_FOUND+=1
    ) else (
        if exist "C:\Program Files\MetaTrader 5\Tester\Agent-0.0.0.0-%%i" (
            echo [MISSING] Standard Agent %%i
            set /A TOTAL_MISSING+=1
        )
    )
)

REM ========================================
REM Check AppData Agents - Terminal 1
REM ========================================
echo.
echo === AppData Agents (Terminal 1) ===
for /L %%i in (3000,1,3001) do (
    set "DLL_PATH=C:\Users\pichau\AppData\Roaming\MetaQuotes\Tester\3CA1B4AB7DFED5C81B1C7F1007926D06\Agent-127.0.0.1-%%i\MQL5\Libraries\GpuBridge.dll"
    if exist "!DLL_PATH!" (
        echo [OK] Agent 3CA1B4AB %%i
        set /A TOTAL_FOUND+=1
    ) else (
        if exist "C:\Users\pichau\AppData\Roaming\MetaQuotes\Tester\3CA1B4AB7DFED5C81B1C7F1007926D06\Agent-127.0.0.1-%%i" (
            echo [MISSING] Agent 3CA1B4AB %%i
            set /A TOTAL_MISSING+=1
        )
    )
)

REM ========================================
REM Check AppData Agents - Terminal 2
REM ========================================
echo.
echo === AppData Agents (Terminal 2) ===
for /L %%i in (3000,1,3023) do (
    set "DLL_PATH=C:\Users\pichau\AppData\Roaming\MetaQuotes\Tester\D0E8209F77C8CF37AD8BF550E51FF075\Agent-127.0.0.1-%%i\MQL5\Libraries\GpuBridge.dll"
    if exist "!DLL_PATH!" (
        echo [OK] Agent D0E8209F %%i
        set /A TOTAL_FOUND+=1
    ) else (
        if exist "C:\Users\pichau\AppData\Roaming\MetaQuotes\Tester\D0E8209F77C8CF37AD8BF550E51FF075\Agent-127.0.0.1-%%i" (
            echo [MISSING] Agent D0E8209F %%i
            set /A TOTAL_MISSING+=1
        )
    )
)

echo.
echo ========================================
echo Verification Summary
echo ========================================
echo DLLs Found: %TOTAL_FOUND%
echo DLLs Missing: %TOTAL_MISSING%
echo ========================================
echo.

if %TOTAL_MISSING% GTR 0 (
    echo Run DeployDLL.bat to copy missing DLLs
)

pause
