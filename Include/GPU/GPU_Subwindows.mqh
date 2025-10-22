//+------------------------------------------------------------------+
//| SubwindowController.mqh                                          |
//| Helpers to attach/detach indicators to specific subwindows.      |
//+------------------------------------------------------------------+
#ifndef __WAVESPEC_GPU_SUBWINDOW_CONTROLLER_MQH__
#define __WAVESPEC_GPU_SUBWINDOW_CONTROLLER_MQH__

class CSubwindowController
  {
public:
   static bool Attach(const long chart_id,
                      const int sub_window,
                      const int indicator_handle)
     {
      if(indicator_handle == INVALID_HANDLE)
         return false;
      return ChartIndicatorAdd(chart_id, sub_window, indicator_handle);
     }

   static bool Detach(const long chart_id,
                      const int sub_window,
                      int &indicator_handle,
                      const string short_name)
     {
      if(indicator_handle == INVALID_HANDLE)
         return false;
      const bool removed = ChartIndicatorDelete(chart_id, sub_window, short_name);
      IndicatorRelease(indicator_handle);
      indicator_handle = INVALID_HANDLE;
      return removed;
     }
  };

#endif // __WAVESPEC_GPU_SUBWINDOW_CONTROLLER_MQH__
