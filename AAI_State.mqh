//+------------------------------------------------------------------+
//|                        AAI_State.mqh                             |
//|      Manages persistent state (e.g., daily PnL) via file I/O     |
//|                   Copyright 2025, AlfredAI Project               |
//|                 https://github.com/rudikai/alfredai              |
//+------------------------------------------------------------------+
#ifndef ALFREDAI_STATE_MQH
#define ALFREDAI_STATE_MQH

// --- New Code for AAI_State.mqh ---
#property strict

#include <AAI/AlfredAI_Utils.mqh>

//+------------------------------------------------------------------+
//| Manages persistent state for the EA                              |
//+------------------------------------------------------------------+
class AAI_State
  {
private:
   // --- State Variables ---
   double   m_daily_pnl;
   int      m_daily_trades;
   datetime m_last_reset;

   // --- File Handling ---
   string   m_session;
   string   m_file_path;

public:
   //+------------------------------------------------------------------+
   //| Constructor                                                      |
   //+------------------------------------------------------------------+
            AAI_State() : m_daily_pnl(0.0), m_daily_trades(0), m_last_reset(0)
     {
     }

   //+------------------------------------------------------------------+
   //| Initialize with a session name                                   |
   //+------------------------------------------------------------------+
   bool     Init(const string session)
     {
      m_session = session;
      m_file_path = "AAI_State_" + m_session + ".ini";
      return true;
     }

   //+------------------------------------------------------------------+
   //| Load state from the .ini file                                    |
   //+------------------------------------------------------------------+
   bool     Load()
     {
      int handle = FileOpen(m_file_path, FILE_READ|FILE_TXT, ';', CP_UTF8);
      if(handle == INVALID_HANDLE)
        {
         // File doesn't exist, which is fine on first run.
         return true;
        }

      while(!FileIsEnding(handle))
        {
         string line = FileReadString(handle);
         string parts[];
         if(StringSplit(line, '=', parts) == 2)
           {
            StringTrimLeft(parts[0]); StringTrimRight(parts[0]);
            StringTrimLeft(parts[1]); StringTrimRight(parts[1]);
            
            if(parts[0] == "daily_pnl")
               m_daily_pnl = StringToDouble(parts[1]);
            else if(parts[0] == "daily_trades")
               m_daily_trades = (int)StringToInteger(parts[1]);
            else if(parts[0] == "last_reset")
               m_last_reset = (datetime)StringToInteger(parts[1]);
           }
        }
      FileClose(handle);
      return true;
     }

   //+------------------------------------------------------------------+
   //| Save the current state to the .ini file                          |
   //+------------------------------------------------------------------+
   bool     Save()
     {
      int handle = FileOpen(m_file_path, FILE_WRITE|FILE_TXT, ';', CP_UTF8);
      if(handle == INVALID_HANDLE)
        {
         PrintFormat("AAI_State: Error opening file %s for writing. Error code: %d", m_file_path, GetLastError());
         return false;
        }

      FileWriteString(handle, "daily_pnl=" + DoubleToString(m_daily_pnl, 2) + "\n");
      FileWriteString(handle, "daily_trades=" + IntegerToString(m_daily_trades) + "\n");
      FileWriteString(handle, "last_reset=" + IntegerToString(m_last_reset) + "\n");

      FileClose(handle);
      return true;
     }

   //+------------------------------------------------------------------+
   //| Accessors                                                        |
   //+------------------------------------------------------------------+
   double   DailyPnL() const        { return m_daily_pnl;    }
   void     SetDailyPnL(double v)   { m_daily_pnl = v;       }
   int      DailyTrades() const     { return m_daily_trades; }
   void     SetDailyTrades(int v)   { m_daily_trades = v;    }
   datetime LastReset() const       { return m_last_reset;   }
   void     SetLastReset(datetime t){ m_last_reset = t;      }

   //+------------------------------------------------------------------+
   //| Resets daily counters if the UTC date has changed                |
   //+------------------------------------------------------------------+
   void     TouchDailyReset()
     {
      MqlDateTime current_dt, last_reset_dt;
      TimeToStruct(TimeGMT(), current_dt);
      TimeToStruct(m_last_reset, last_reset_dt);

      if(current_dt.day   != last_reset_dt.day || 
         current_dt.mon  != last_reset_dt.mon || 
         current_dt.year != last_reset_dt.year)
        {
         m_daily_pnl    = 0.0;
         m_daily_trades = 0;
         m_last_reset   = TimeGMT();
         Save(); // Save immediately after reset
         Print("AAI_State: Daily counters have been reset.");
        }
     }
  };

#endif // ALFREDAI_STATE_MQH

