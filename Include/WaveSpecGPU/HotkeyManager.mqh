//+------------------------------------------------------------------+
//| HotkeyManager.mqh                                                |
//| Lightweight helper to map keyboard shortcuts to actions.         |
//+------------------------------------------------------------------+
#ifndef __WAVESPEC_GPU_HOTKEY_MANAGER_MQH__
#define __WAVESPEC_GPU_HOTKEY_MANAGER_MQH__

class CHotkeyManager
  {
private:
   static const int MAX_KEYS = 16;
   int   m_keys[MAX_KEYS];
   int   m_actions[MAX_KEYS];
   int   m_count;

public:
            CHotkeyManager()
            {
               Reset();
            }

   void     Reset()
            {
               m_count = 0;
               for(int i=0; i<MAX_KEYS; ++i)
                 {
                  m_keys[i]    = 0;
                  m_actions[i] = -1;
                 }
            }

   bool     Register(const int key_code,
                     const int action_id)
            {
               if(key_code <= 0)
                  return false;

               for(int i=0; i<m_count; ++i)
                 {
                  if(m_keys[i] == key_code)
                    {
                     m_actions[i] = action_id;
                     return true;
                    }
                 }

               if(m_count >= MAX_KEYS)
                  return false;

               m_keys[m_count]    = key_code;
               m_actions[m_count] = action_id;
               ++m_count;
               return true;
            }

   int      HandleChartEvent(const int id,
                             const long &lparam) const
            {
               if(id != CHARTEVENT_KEYDOWN)
                  return -1;

               const int key = (int)lparam;
               for(int i=0; i<m_count; ++i)
                 {
                  if(m_keys[i] == key)
                     return m_actions[i];
                 }
               return -1;
            }
  };

#endif // __WAVESPEC_GPU_HOTKEY_MANAGER_MQH__
