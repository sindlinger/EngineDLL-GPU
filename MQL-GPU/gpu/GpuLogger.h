#pragma once

#include <string>

namespace gpu {

void LogMessage(const std::string& message);
void LogStatus(const std::string& context, int status_code);

} // namespace gpu
