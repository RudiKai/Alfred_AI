//+------------------------------------------------------------------+
//|                   AAI_Indicator_Dashboard.mq5                    |
//|            Displays a visual summary of EA performance           |
//|                   Copyright 2025, AlfredAI Project               |
//|                 https://github.com/rudikai/alfredai              |
//+------------------------------------------------------------------+
#property strict
#property indicator_chart_window
#property indicator_plots 0
#property version   "1.0"

#include <Arrays/ArrayString.mqh>

//--- Indicator Inputs
input string InpSessionName  = "RUDI-001";
input int    InpLookbackLines = 5000;

//--- Global Variables
string   g_dashboard_prefix = "AAI_Dashboard_";
datetime g_last_file_check = 0;
int      g_update_interval_sec = 5; // How often to check the file

//--- Stats
string   g_stat_trades = "---";
string   g_stat_winrate = "---";
string   g_stat_pnl = "---";

//+------------------------------------------------------------------+
//| A helper to create/update text labels on the chart               |
//+------------------------------------------------------------------+
void DrawLabel(string name, string text, int x, int y, int size, color clr)
  {
   string obj_name = g_dashboard_prefix + name;
   if(ObjectFind(0, obj_name) < 0)
     {
      ObjectCreate(0, obj_name, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, obj_name, OBJPROP_XDISTANCE, x);
      ObjectSetInteger(0, obj_name, OBJPROP_YDISTANCE, y);
      ObjectSetInteger(0, obj_name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetString(0, obj_name, OBJPROP_FONT, "Arial");
      ObjectSetInteger(0, obj_name, OBJPROP_ANCHOR, ANCHOR_LEFT);
      ObjectSetInteger(0, obj_name, OBJPROP_BACK, false);
     }
   ObjectSetString(0, obj_name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, obj_name, OBJPROP_FONTSIZE, size);
   ObjectSetInteger(0, obj_name, OBJPROP_COLOR, clr);
  }

//+------------------------------------------------------------------+
//| Main function to redraw the dashboard UI                         |
//+------------------------------------------------------------------+
void RedrawDashboard()
  {
   DrawLabel("Title", "AlfredAI Daily Stats", 10, 20, 12, clrDodgerBlue);
   DrawLabel("Trades", "Trades Today: " + g_stat_trades, 10, 40, 10, clrWhite);
   DrawLabel("Winrate", "Win Rate: " + g_stat_winrate, 10, 55, 10, clrWhite);
   DrawLabel("PnL", "Net PnL: " + g_stat_pnl, 10, 70, 10, (StringToDouble(g_stat_pnl) >= 0 ? clrLimeGreen : clrCrimson));
   ChartRedraw();
  }

//+------------------------------------------------------------------+
//| Reads the journal and calculates today's stats                   |
//+------------------------------------------------------------------+
void UpdateStatsFromJournal()
  {
   string journal_filename = "AAI_Journal_" + InpSessionName + ".log";
   int handle = FileOpen(journal_filename, FILE_READ|FILE_TXT, ';', CP_UTF8);
   if(handle == INVALID_HANDLE)
     {
      g_stat_trades = "No Log";
      return;
     }

   int trades = 0;
   int wins = 0;
   double total_pnl = 0;
   string today_date = TimeToString(TimeCurrent(), TIME_DATE);

   CArrayString *lines = new CArrayString();
   while(!FileIsEnding(handle))
     {
      lines.Add(FileReadString(handle));
     }
   FileClose(handle);

   // Read last N lines for performance
   int start_line = MathMax(0, lines.Total() - InpLookbackLines);

   for(int i = start_line; i < lines.Total(); i++)
     {
      string line = lines.At(i);
      string parts[];
      if(StringSplit(line, '|', parts) < 5) continue;

      string event_val = "", ts_val = "", pnl_val = "";

      for(int j = 0; j < ArraySize(parts); j++)
        {
         string current_part = parts[j];
         string key_val[];
         if(StringSplit(current_part, '=', key_val) != 2) continue;

         if(key_val[0] == "event") event_val = key_val[1];
         if(key_val[0] == "ts") ts_val = key_val[1];
         if(key_val[0] == "pnl") pnl_val = key_val[1];
        }

      string log_date = TimeToString(StringToTime(ts_val), TIME_DATE);
      if(log_date != today_date) continue;

      if((event_val == "Close" || event_val == "SL" || event_val == "TP" || event_val == "OrderClose") && pnl_val != "0.00")
        {
         double pnl = StringToDouble(pnl_val);
         trades++;
         total_pnl += pnl;
         if(pnl > 0) wins++;
        }
     }

   g_stat_trades = IntegerToString(trades);
   g_stat_pnl = DoubleToString(total_pnl, 2);
   g_stat_winrate = (trades > 0) ? DoubleToString((double)wins / trades * 100.0, 1) + "%" : "0.0%";

   delete lines;
  }

//+------------------------------------------------------------------+
//| Indicator initialization function                                |
//+------------------------------------------------------------------+
int OnInit()
  {
   EventSetTimer(g_update_interval_sec);
   UpdateStatsFromJournal();
   RedrawDashboard();
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Indicator deinitialization function                              |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   ObjectsDeleteAll(0, g_dashboard_prefix);
   ChartRedraw();
  }

//+------------------------------------------------------------------+
//| Indicator timer function                                         |
//+------------------------------------------------------------------+
void OnTimer()
  {
   UpdateStatsFromJournal();
   RedrawDashboard();
  }

//+------------------------------------------------------------------+
//| OnCalculate - required but logic is in OnTimer                   |
//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
  {
   return(rates_total);
  }
//+------------------------------------------------------------------+

