# GpuBridge.dll Deployment Status

## ✅ Successfully Deployed (27 locations)

### Main Library
- ✅ `C:\Users\pichau\AppData\Roaming\MetaQuotes\Terminal\MQL-GPU\Libraries\GpuBridge.dll`

### AppData Agents (26 agents)
- ✅ Agent D0E8209F 3000-3023 (24 agents)
- ✅ Agent 3CA1B4AB 3000-3001 (2 agents)

**Path pattern:**
```
C:\Users\pichau\AppData\Roaming\MetaQuotes\Tester\{TERMINAL_ID}\Agent-127.0.0.1-{PORT}\MQL5\Libraries\GpuBridge.dll
```

---

## ⚠️ Requires Manual Copy (Admin Required)

### Dukascopy MetaTrader 5 (9 agents)
**Reason**: No write permission to `C:\Program Files\`

**Required actions:**
1. Open Command Prompt as **Administrator**
2. Run the following commands:

```cmd
cd C:\Users\pichau\AppData\Roaming\MetaQuotes\Terminal\MQL-GPU

REM Create Libraries folders
for /L %i in (2000,1,2008) do mkdir "C:\Program Files\Dukascopy MetaTrader 5\Tester\Agent-0.0.0.0-%i\MQL5\Libraries" 2>nul

REM Copy DLL
for /L %i in (2000,1,2008) do copy /Y "gpu\build\Release\GpuBridge.dll" "C:\Program Files\Dukascopy MetaTrader 5\Tester\Agent-0.0.0.0-%i\MQL5\Libraries\"
```

**Affected agents:**
- Agent-0.0.0.0-2000
- Agent-0.0.0.0-2001
- Agent-0.0.0.0-2002
- Agent-0.0.0.0-2003
- Agent-0.0.0.0-2004
- Agent-0.0.0.0-2005
- Agent-0.0.0.0-2006
- Agent-0.0.0.0-2007
- Agent-0.0.0.0-2008

---

### Standard MetaTrader 5 (16 agents)
**Reason**: No write permission to `C:\Program Files\`

**Required actions:**
1. Open Command Prompt as **Administrator**
2. Run the following commands:

```cmd
cd C:\Users\pichau\AppData\Roaming\MetaQuotes\Terminal\MQL-GPU

REM Create Libraries folders
for /L %i in (2000,1,2015) do mkdir "C:\Program Files\MetaTrader 5\Tester\Agent-0.0.0.0-%i\MQL5\Libraries" 2>nul

REM Copy DLL
for /L %i in (2000,1,2015) do copy /Y "gpu\build\Release\GpuBridge.dll" "C:\Program Files\MetaTrader 5\Tester\Agent-0.0.0.0-%i\MQL5\Libraries\"
```

**Affected agents:**
- Agent-0.0.0.0-2000 through 2015 (16 agents)

---

## 📊 Summary

| Location | Status | Count |
|----------|--------|-------|
| **Main Libraries** | ✅ Deployed | 1 |
| **AppData Agents** | ✅ Deployed | 26 |
| **Dukascopy Agents** | ⚠️ Manual | 9 |
| **Standard MT5 Agents** | ⚠️ Manual | 16 |
| **TOTAL** | | 52 |

---

## 🔧 Automated Deployment Script

For future updates, use the deployment script:

```cmd
DeployDLL.bat
```

This script attempts to copy to all locations but will skip those requiring admin.

---

## ✅ Verification

To verify all copies, run:

```cmd
DeployDLL_Verify.bat
```

This will show which agents have the DLL and which are missing.

---

## 📝 Notes

1. **AppData agents** don't require admin → automatically deployed ✅
2. **Program Files agents** require admin → manual deployment needed ⚠️
3. DLL version: **143KB** (compiled Oct 16, 2024)
4. Source location: `MQL-GPU\gpu\build\Release\GpuBridge.dll`

---

## 🚀 Testing After Deployment

Once deployed, test with:

```mql5
#include <FFT\GpuParallelProcessor.mqh>

void OnStart() {
    CGpuParallelProcessor gpu;
    GpuProcessingConfig config;
    config.window_size = 512;

    if(gpu.Initialize(config)) {
        Print("✅ GPU initialized successfully!");
        Print("DLL loaded from: ", MQLInfoString(MQL_PROGRAM_PATH));
    } else {
        Print("❌ GPU initialization failed");
        Print("Check: DLL in Libraries folder?");
    }

    gpu.Shutdown();
}
```

Run this script on each MT5 instance to verify DLL accessibility.
