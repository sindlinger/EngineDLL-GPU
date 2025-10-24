#pragma once

#include <string>
#include <windows.h>

class PipeServer
{
public:
   explicit PipeServer(const std::wstring& name);
   ~PipeServer();

   bool Create();
   bool WaitForClient();
   void Disconnect();
   void Close();

   bool ReadExact(void* buffer, std::size_t bytes);
   bool WriteExact(const void* buffer, std::size_t bytes);

private:
   std::wstring m_name;
   HANDLE       m_pipe = INVALID_HANDLE_VALUE;
};
