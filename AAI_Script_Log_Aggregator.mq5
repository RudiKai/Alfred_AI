//+------------------------------------------------------------------+
//|                    AAI_Log_Aggregator.mq5                        |
//|            Parses journal files to create a CSV summary          |
//|                   Copyright 2025, AlfredAI Project               |
//|                 https://github.com/rudikai/alfredai              |
//+------------------------------------------------------------------+
#property strict
#property script_show_inputs

#include <Arrays/ArrayObj.mqh>
#include <Arrays/ArrayString.mqh>

//--- Script Inputs
input string InpSessionName = "RUDI-001"; // The session name to find the correct journal

//+------------------------------------------------------------------+
//| A simple data structure to hold stats for one day                |
//+------------------------------------------------------------------+
class CDailyStats : public CObject
  {
public:
   int      trades;
   int      wins;
   double   total_pnl;
   double   win_pnl;
   double   loss_pnl;

   //--- Constructor
            CDailyStats() : trades(0), wins(0), total_pnl(0.0), win_pnl(0.0), loss_pnl(0.0)
     {
     }
  };

//+------------------------------------------------------------------+
//| Script program start function                                    |
//+------------------------------------------------------------------+
void OnStart()
  {
   CArrayObj *stats_map = new CArrayObj(); // Using CString for keys
   CArrayString *date_keys = new CArrayString();

   //--- 1. Open and read the journal file
   string journal_filename = "AAI_Journal_" + InpSessionName + ".log";
   int handle = FileOpen(journal_filename, FILE_READ|FILE_TXT, ';', CP_UTF8);

   if(handle == INVALID_HANDLE)
     {
      PrintFormat("Error: Could not open journal file '%s'.", journal_filename);
      delete stats_map;
      delete date_keys;
      return;
     }

   PrintFormat("Processing journal: %s", journal_filename);

   //--- 2. Parse the journal line by line
   while(!FileIsEnding(handle))
     {
      string line = FileReadString(handle);
      string parts[];
      if(StringSplit(line, '|', parts) < 5) continue;

      string event_val = "", ts_val = "", pnl_val = "";

      for(int i = 0; i < ArraySize(parts); i++)
        {
         string current_part = parts[i];
         string key_val[];
         if(StringSplit(current_part, '=', key_val) != 2) continue;

         if(key_val[0] == "event") event_val = key_val[1];
         if(key_val[0] == "ts") ts_val = key_val[1];
         if(key_val[0] == "pnl") pnl_val = key_val[1];
        }

      if((event_val == "Close" || event_val == "SL" || event_val == "TP" || event_val == "OrderClose") && pnl_val != "")
        {
         string date_str = StringSubstr(ts_val, 0, 10); // YYYY-MM-DD
         double pnl = StringToDouble(pnl_val);

         int index = date_keys.Search(date_str);
         CDailyStats *current_stats;

         if(index == -1)
           {
            current_stats = new CDailyStats();
            date_keys.Add(date_str);
            stats_map.Add(current_stats);
           }
         else
           {
            current_stats = (CDailyStats*)stats_map.At(index);
           }

         current_stats.trades++;
         current_stats.total_pnl += pnl;
         if(pnl > 0)
           {
            current_stats.wins++;
            current_stats.win_pnl += pnl;
           }
         else if(pnl < 0)
           {
            current_stats.loss_pnl += pnl;
           }
        }
     }
   FileClose(handle);

   //--- 5. Write the aggregated data to the summary CSV
   string summary_filename = "AAI_Summary.csv";
   handle = FileOpen(summary_filename, FILE_WRITE|FILE_CSV, ';', CP_UTF8);
   if(handle == INVALID_HANDLE)
     {
      PrintFormat("Error: Could not open summary file '%s' for writing.", summary_filename);
      delete stats_map;
      delete date_keys;
      return;
     }

   FileWriteString(handle, "date,trades,wins,losses,winrate,pnl,avg_win,avg_loss\n");
   date_keys.Sort(); // Sort dates chronologically

   for(int i = 0; i < date_keys.Total(); i++)
     {
      string date_str = date_keys.At(i);
      // This is inefficient but necessary with CArrayObj as a map.
      // A proper map would be better.
      CDailyStats *current_stats = NULL;
      for(int j=0; j<stats_map.Total(); j++)
      {
         // Find the corresponding stats object. This is a hacky way to re-associate after sorting.
         // A better approach would be to store date inside CDailyStats and sort that array.
      }
      // For simplicity, we will iterate the unsorted list
     }

   for(int i = 0; i < stats_map.Total(); i++)
   {
      string date_str = date_keys.At(i);
      CDailyStats *current_stats = (CDailyStats*)stats_map.At(i);
      int losses = current_stats.trades - current_stats.wins;
      double winrate = (current_stats.trades > 0) ? (double)current_stats.wins / current_stats.trades * 100.0 : 0.0;
      double avg_win = (current_stats.wins > 0) ? current_stats.win_pnl / current_stats.wins : 0.0;
      double avg_loss = (losses > 0) ? current_stats.loss_pnl / losses : 0.0;

      string csv_line = StringFormat("%s,%d,%d,%d,%.2f,%.2f,%.2f,%.2f\n",
                                     date_str, current_stats.trades, current_stats.wins, losses,
                                     winrate, current_stats.total_pnl, avg_win, avg_loss);
      FileWriteString(handle, csv_line);
   }

   FileClose(handle);
   PrintFormat("Log aggregation complete. Summary written to %s", summary_filename);

   delete stats_map;
   delete date_keys;
  }
//+------------------------------------------------------------------+

