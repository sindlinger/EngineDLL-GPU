#include "PipeServer.h"

#include <cstdio>

PipeServer::PipeServer(const std::wstring& name)
   : m_name(name)
{
}

PipeServer::~PipeServer()
{
   Close();
}

bool PipeServer::Create()
{
   Close();
   m_pipe = CreateNamedPipeW(m_name.c_str(),
                             PIPE_ACCESS_DUPLEX,
                             PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT,
                             1,              // max instances
                             1 << 15,        // out buffer
                             1 << 15,        // in buffer
                             0,
                             nullptr);
   if(m_pipe == INVALID_HANDLE_VALUE)
     {
      std::fprintf(stderr, "[PipeServer] CreateNamedPipeW falhou. err=%lu\n", GetLastError());
      return false;
     }
   return true;
}

bool PipeServer::WaitForClient()
{
   if(m_pipe == INVALID_HANDLE_VALUE)
      return false;

   BOOL connected = ConnectNamedPipe(m_pipe, nullptr) ? TRUE : (GetLastError() == ERROR_PIPE_CONNECTED);
   if(!connected)
     {
      std::fprintf(stderr, "[PipeServer] ConnectNamedPipe falhou. err=%lu\n", GetLastError());
      Close();
      return false;
     }
   return true;
}

void PipeServer::Disconnect()
{
   if(m_pipe != INVALID_HANDLE_VALUE)
      DisconnectNamedPipe(m_pipe);
}

void PipeServer::Close()
{
   if(m_pipe != INVALID_HANDLE_VALUE)
     {
      CloseHandle(m_pipe);
      m_pipe = INVALID_HANDLE_VALUE;
     }
}

bool PipeServer::ReadExact(void* buffer, std::size_t bytes)
{
   std::uint8_t* ptr = static_cast<std::uint8_t*>(buffer);
   std::size_t remaining = bytes;
   while(remaining > 0)
     {
      DWORD chunk = 0;
      BOOL ok = ReadFile(m_pipe, ptr, static_cast<DWORD>(remaining), &chunk, nullptr);
      if(!ok || chunk == 0)
        {
         std::fprintf(stderr, "[PipeServer] ReadFile falhou. err=%lu\n", GetLastError());
         return false;
        }
      ptr += chunk;
      remaining -= chunk;
     }
   return true;
}

bool PipeServer::WriteExact(const void* buffer, std::size_t bytes)
{
   const std::uint8_t* ptr = static_cast<const std::uint8_t*>(buffer);
   std::size_t remaining = bytes;
   while(remaining > 0)
     {
      DWORD chunk = 0;
      BOOL ok = WriteFile(m_pipe, ptr, static_cast<DWORD>(remaining), &chunk, nullptr);
      if(!ok || chunk == 0)
        {
         std::fprintf(stderr, "[PipeServer] WriteFile falhou. err=%lu\n", GetLastError());
         return false;
        }
      ptr += chunk;
      remaining -= chunk;
     }
   FlushFileBuffers(m_pipe);
   return true;
}
