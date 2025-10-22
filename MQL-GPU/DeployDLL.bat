@echo off
echo ========================================
echo Deploying GpuBridge.dll to ALL MT5 Instances
echo ========================================

set SOURCE_DLL="%~dp0gpu\build\Release\GpuBridge.dll"

if not exist %SOURCE_DLL% (
    echo ERROR: Source DLL not found: %SOURCE_DLL%
    pause
    exit /b 1
)

echo Source DLL: %SOURCE_DLL%
echo.

REM ========================================
REM Libraries Principal
REM ========================================
echo Copying to main Libraries folder...
xcopy /Y %SOURCE_DLL% "%~dp0Libraries\" >nul
if %ERRORLEVEL% EQU 0 (
    echo [OK] Libraries\GpuBridge.dll
) else (
    echo [FAIL] Libraries\
)

REM ========================================
REM Dukascopy MetaTrader 5 - Program Files
REM ========================================
echo.
echo Deploying to Dukascopy MT5 Agents...

for /L %%i in (2000,1,2008) do (
    set "DEST=C:\Program Files\Dukascopy MetaTrader 5\Tester\Agent-0.0.0.0-%%i\MQL5\Libraries\"
    if exist "!DEST!" (
        xcopy /Y %SOURCE_DLL% "!DEST!" >nul 2>&1
        if !ERRORLEVEL! EQU 0 (
            echo [OK] Dukascopy Agent %%i
        ) else (
            echo [SKIP] Dukascopy Agent %%i - no write permission
        )
    )
)

REM ========================================
REM Standard MetaTrader 5 - Program Files
REM ========================================
echo.
echo Deploying to Standard MT5 Agents...

for /L %%i in (2000,1,2015) do (
    set "DEST=C:\Program Files\MetaTrader 5\Tester\Agent-0.0.0.0-%%i\MQL5\Libraries\"
    if exist "!DEST!" (
        xcopy /Y %SOURCE_DLL% "!DEST!" >nul 2>&1
        if !ERRORLEVEL! EQU 0 (
            echo [OK] Standard Agent %%i
        ) else (
            echo [SKIP] Standard Agent %%i - no write permission
        )
    )
)

REM ========================================
REM AppData Agents - 3CA1B4AB (Terminal 1)
REM ========================================
echo.
echo Deploying to AppData Agents (Terminal 1)...

for /L %%i in (3000,1,3001) do (
    set "DEST=C:\Users\pichau\AppData\Roaming\MetaQuotes\Tester\3CA1B4AB7DFED5C81B1C7F1007926D06\Agent-127.0.0.1-%%i\MQL5\Libraries\"
    if exist "!DEST!" (
        xcopy /Y %SOURCE_DLL% "!DEST!" >nul 2>&1
        if !ERRORLEVEL! EQU 0 (
            echo [OK] Agent 3CA1B4AB %%i
        ) else (
            echo [SKIP] Agent 3CA1B4AB %%i
        )
    )
)

REM ========================================
REM AppData Agents - D0E8209F (Terminal 2)
REM ========================================
echo.
echo Deploying to AppData Agents (Terminal 2)...

for /L %%i in (3000,1,3023) do (
    set "DEST=C:\Users\pichau\AppData\Roaming\MetaQuotes\Tester\D0E8209F77C8CF37AD8BF550E51FF075\Agent-127.0.0.1-%%i\MQL5\Libraries\"
    if exist "!DEST!" (
        xcopy /Y %SOURCE_DLL% "!DEST!" >nul 2>&1
        if !ERRORLEVEL! EQU 0 (
            echo [OK] Agent D0E8209F %%i
        ) else (
            echo [SKIP] Agent D0E8209F %%i
        )
    )
)

echo.
echo ========================================
echo Deployment Complete!
echo ========================================
echo.
echo Run verification script to check all copies:
echo   DeployDLL_Verify.bat
echo.
pause
