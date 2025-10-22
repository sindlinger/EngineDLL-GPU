#include "GpuLogger.h"

#include <chrono>
#include <ctime>
#include <fstream>
#include <iomanip>
#include <mutex>
#include <sstream>

namespace gpu {

namespace {

std::string LogFilePath() {
    // Log alongside the DLL by default; MetaTrader callers can relocate via deployment scripts.
    return "gpu_runtime.log";
}

std::string CurrentTimestamp() {
    auto now = std::chrono::system_clock::now();
    std::time_t tt = std::chrono::system_clock::to_time_t(now);
    std::tm tm_snapshot;
#ifdef _WIN32
    localtime_s(&tm_snapshot, &tt);
#else
    localtime_r(&tt, &tm_snapshot);
#endif
    std::ostringstream oss;
    oss << std::put_time(&tm_snapshot, "%Y-%m-%d %H:%M:%S");
    return oss.str();
}

std::mutex& LogMutex() {
    static std::mutex m;
    return m;
}

} // namespace

void LogMessage(const std::string& message) {
    std::lock_guard<std::mutex> lock(LogMutex());
    std::ofstream log(LogFilePath(), std::ios::app);
    if(!log.is_open()) {
        return;
    }
    log << CurrentTimestamp() << " | " << message << '\n';
}

void LogStatus(const std::string& context, int status_code) {
    std::ostringstream oss;
    oss << context << " status=" << status_code;
    LogMessage(oss.str());
}

} // namespace gpu
