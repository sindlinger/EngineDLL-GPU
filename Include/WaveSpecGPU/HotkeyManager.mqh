//+------------------------------------------------------------------+
//| HotkeyManager.mqh                                                |
//| Lightweight helper to map keyboard shortcuts to actions.         |
//+------------------------------------------------------------------+
#ifndef __WAVESPEC_GPU_HOTKEY_MANAGER_MQH__
#define __WAVESPEC_GPU_HOTKEY_MANAGER_MQH__

class CHotkeyManager
  {
private:
   int m_keys[];
   int m_actions[];

public:
            CHotkeyManager()
            {
               Reset();
            }

   void     Reset()
            {
               ArrayResize(m_keys, 0);
               ArrayResize(m_actions, 0);
            }

   bool     Register(const int key_code,
                     const int action_id)
            {
               if(key_code <= 0)
                  return false;

               const int count = ArraySize(m_keys);
               for(int i=0; i<count; ++i)
                 {
                  if(m_keys[i] == key_code)
                    {
                     m_actions[i] = action_id;
                     return true;
                    }
                 }

               const int new_size = count + 1;
               ArrayResize(m_keys, new_size);
               ArrayResize(m_actions, new_size);
               m_keys[new_size-1]    = key_code;
               m_actions[new_size-1] = action_id;
               return true;
            }

   int      HandleChartEvent(const int id,
                             const long &lparam) const
            {
               if(id != CHARTEVENT_KEYDOWN)
                  return -1;

               const int key = (int)lparam;
               const int count = ArraySize(m_keys);
               for(int i=0; i<count; ++i)
                 {
                  if(m_keys[i] == key)
                     return m_actions[i];
                 }
               return -1;
            }
  };

#endif // __WAVESPEC_GPU_HOTKEY_MANAGER_MQH__
