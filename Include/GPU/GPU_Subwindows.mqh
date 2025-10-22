//+------------------------------------------------------------------+
//| GPU_Subwindows.mqh                                              |
//| Utilities built on top of fxsaber's SUBWINDOW helper.            |
//+------------------------------------------------------------------+
#ifndef __GPU_SUBWINDOW_CONTROLLER_MQH__
#define __GPU_SUBWINDOW_CONTROLLER_MQH__

#include <fxsaber/SubWindow.mqh>

class CSubwindowController
  {
public:
   static bool EnsureCount(const long chart_id,
                           const int desired_subwindow)
     {
      if(desired_subwindow < 0)
         return false;

      int total = (int)ChartGetInteger(chart_id, CHART_WINDOWS_TOTAL);
      while(total <= desired_subwindow)
        {
         if(!SUBWINDOW::Copy(chart_id, MathMax(total - 1, 0), total))
            return false;
         total = (int)ChartGetInteger(chart_id, CHART_WINDOWS_TOTAL);
        }
      return true;
     }

   static bool Attach(const long chart_id,
                      const int sub_window,
                      const int indicator_handle)
     {
      if(indicator_handle == INVALID_HANDLE)
         return false;
      if(!EnsureCount(chart_id, sub_window))
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

      if(removed)
        {
         const int remaining = (int)ChartIndicatorsTotal(chart_id, sub_window);
         if(sub_window > 0 && remaining == 0)
           {
            SUBWINDOW::Delete(chart_id, (uint)sub_window);
            ChartRedraw(chart_id);
           }
        }
      return removed;
     }
  };

#endif // __GPU_SUBWINDOW_CONTROLLER_MQH__
