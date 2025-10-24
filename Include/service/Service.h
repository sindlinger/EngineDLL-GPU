#pragma once

#include <cstdint>
#include <unordered_map>

#include "ServiceProtocol.h"

class PipeServer;

class Service
{
public:
   Service();
   int Run();

private:
   struct JobMetadata
     {
      int frame_count = 0;
      int frame_length = 0;
      int cycle_count = 0;
     };

   bool ProcessClient(PipeServer& pipe);
   bool SendStatus(PipeServer& pipe, gpu_service::Command command, gpu_service::Status status);

   std::unordered_map<std::uint64_t, JobMetadata> m_jobs;
};
