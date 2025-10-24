#pragma once

#include "GpuEngineExports.h"

// A very thin stub that will later convert DLL calls into IPC messages directed
// to the external GPU service. For now these functions simply return
// STATUS_NOT_INITIALISED so the library can link and callers can detect the
// unimplemented path.

namespace gpuengine_client
{
inline int NotImplemented() { return gpuengine::STATUS_NOT_INITIALISED; }
} // namespace gpuengine_client
