//+------------------------------------------------------------------+
//|                     AAI_Include_News.mqh                         |
//|               Handles news/event gating from CSV                 |
//|                   Copyright 2025, AlfredAI Project               |
//|                 https://github.com/rudikai/alfredai              |
//+------------------------------------------------------------------+
#ifndef AAI_INCLUDE_NEWS_MQH
#define AAI_INCLUDE_NEWS_MQH

#property strict

// --- CSV format: time_utc, scope, impact, window_before_min, window_after_min, title
struct NewsEvent
{
   datetime time_utc;
   string   scope;
   string   impact; // "High", "Medium", "Low"
   long     window_before_sec;
   long     window_after_sec;
};

// --- Matches EA Inputs ---
enum ENUM_NEWS_Mode { NEWS_OFF=0, NEWS_REQUIRED=1, NEWS_PREFERRED=2 };

//+------------------------------------------------------------------+
//| AAI_NewsGate Class                                               |
//| Manages loading and checking against a news event CSV file.      |
//+------------------------------------------------------------------+
class AAI_NewsGate
{
private:
   bool           m_enabled;
   ENUM_NEWS_Mode m_mode;
   bool           m_times_are_utc;
   bool           m_filter_high;
   bool           m_filter_medium;
   bool           m_filter_low;
   int            m_penalty;
   NewsEvent      m_events[];

   //+------------------------------------------------------------------+
   //| Parses a single line from the CSV file.                          |
   //+------------------------------------------------------------------+
   bool ParseLine(const string line, NewsEvent &ev)
     {
      string parts[];
      if(StringSplit(line, ',', parts) < 5)
         return false;

      // 1. Time
      ev.time_utc = StringToTime(parts[0]);
      if(ev.time_utc <= 0) return false;

      // 2. Scope
      StringTrimLeft(parts[1]); StringTrimRight(parts[1]);
      ev.scope = parts[1];

      // 3. Impact
      StringTrimLeft(parts[2]); StringTrimRight(parts[2]);
      ev.impact = parts[2];

      // 4. Window Before/After (minutes -> seconds)
      ev.window_before_sec = (long)StringToInteger(parts[3]) * 60;
      ev.window_after_sec  = (long)StringToInteger(parts[4]) * 60;

      return true;
     }

public:
               AAI_NewsGate() {}

   //+------------------------------------------------------------------+
   //| Initializes the gate and loads the CSV file.                     |
   //+------------------------------------------------------------------+
   void Init(bool enable, string csv_name, ENUM_NEWS_Mode mode, bool is_utc, bool f_h, bool f_m, bool f_l, int penalty)
     {
      m_enabled       = enable;
      m_mode          = mode;
      m_times_are_utc = is_utc;
      m_filter_high   = f_h;
      m_filter_medium = f_m;
      m_filter_low    = f_l;
      m_penalty       = penalty;

      ArrayFree(m_events);

      if(!m_enabled || m_mode == NEWS_OFF)
        {
         Print("[NEWS] Gate disabled by inputs.");
         return;
        }

      int handle = FileOpen(csv_name, FILE_READ|FILE_TXT|FILE_COMMON, ',', CP_UTF8);
      if(handle == INVALID_HANDLE)
        {
         PrintFormat("[NEWS_WARN] Failed to open news file '%s' (error %d). Gate will be open.", csv_name, GetLastError());
         m_enabled = false; // Fail-open
         return;
        }

      int count = 0;
      while(!FileIsEnding(handle))
        {
         string line = FileReadString(handle);
         StringTrimLeft(line);
         if(StringLen(line) == 0 || StringGetCharacter(line, 0) == '#')
            continue;

         NewsEvent ev;
         if(ParseLine(line, ev))
           {
            int size = ArraySize(m_events);
            ArrayResize(m_events, size + 1);
            m_events[size] = ev;
            count++;
           }
        }
      FileClose(handle);
      PrintFormat("[NEWS] Loaded %d events from '%s'.", count, csv_name);
     }

   //+------------------------------------------------------------------+
   //| Checks if the current time falls within any filtered news event. |
   //| Returns false if blocked (REQUIRED) or true if passed.         |
   //| Modifies conf_io if penalized (PREFERRED).                     |
   //| Sets is_in_window_flag to 1 if in a news window, else 0.       |
   //+------------------------------------------------------------------+
   bool CheckGate(datetime server_now, double &conf_io, int &is_in_window_flag)
     {
      is_in_window_flag = 0; // Default to not in window
      if(!m_enabled || m_mode == NEWS_OFF)
         return true;

      datetime now_utc = server_now;
      if(!m_times_are_utc)
        {
         long server_offset = TimeGMTOffset();
         now_utc = (datetime)((long)server_now - server_offset);
        }

      string sym_base = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_BASE);
      string sym_quote = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_PROFIT);

      for(int i = 0; i < ArraySize(m_events); i++)
        {
         const NewsEvent ev = m_events[i]; // FIX: Removed reference (&)

         // --- Filter by impact ---
         bool impact_match = (m_filter_high   && ev.impact == "High")   ||
                             (m_filter_medium && ev.impact == "Medium") ||
                             (m_filter_low    && ev.impact == "Low");
         if(!impact_match)
            continue;

         // --- Filter by scope ---
         bool scope_match = (ev.scope == "*" || ev.scope == _Symbol ||
                             ev.scope == sym_base || ev.scope == sym_quote);
         if(!scope_match)
            continue;

         // --- Check time window ---
         datetime start_block = (datetime)((long)ev.time_utc - ev.window_before_sec); // FIX: Explicit cast
         datetime end_block   = (datetime)((long)ev.time_utc + ev.window_after_sec);  // FIX: Explicit cast

         if(now_utc >= start_block && now_utc <= end_block)
           {
            is_in_window_flag = 1; // We are in a news window
            if(m_mode == NEWS_REQUIRED)
              {
               return false; // Block
              }
            else if(m_mode == NEWS_PREFERRED)
              {
               conf_io = MathMax(0.0, conf_io - m_penalty);
              }
            // A match was found, no need to check other events
            return true;
           }
        }

      // No matching event found in a blocking window
      return true;
     }
};

#endif // AAI_INCLUDE_NEWS_MQH

