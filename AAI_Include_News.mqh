//+------------------------------------------------------------------+
//|  AAI_Include_News.mqh                                           |
//|  CSV-driven news window helper (Common Files).                   |
//|  Strictly closed-bar friendly (no timers, no ticks reliance).    |
//+------------------------------------------------------------------+
#pragma once
#include <Arrays/ArrayObj.mqh>

struct AAI_NewsEvent {
  datetime t_server;      // event time in server time
  string   scope;         // "*", currency code ("USD"), or exact symbol ("XAUUSD")
  int      impact;        // 2=High, 1=Medium, 0=Low
  int      before_min;    // minutes before
  int      after_min;     // minutes after
  string   title;         // optional, not used in gating
};

class AAI_NewsStore : public CObject {
public:
  CArrayObj rows; // owns AAI_NewsEvent*

  void Clear() {
    for(int i=0;i<rows.Total();++i){
      AAI_NewsEvent *e = (AAI_NewsEvent*)rows.At(i);
      delete e;
    }
    rows.Clear();
  }

  // impact string -> int
  static int ImpactToInt(const string s){
    string t = StringToLower(s);
    if(StringFind(t,"high")   != -1) return 2;
    if(StringFind(t,"medium") != -1) return 1;
    return 0;
  }

  bool LoadCsv(const string fnameCommon, const bool timesAreUTC){
    Clear();
    int h = FileOpen(fnameCommon, FILE_READ|FILE_CSV|FILE_ANSI|FILE_COMMON);
    if(h == INVALID_HANDLE) return false;

    // Compute UTC->server offset safely as 'long' and cast back to datetime on use.
    long offset = 0;
    if(timesAreUTC){
      // TimeCurrent() and TimeGMT() are 'datetime' (long). Subtract to seconds offset.
      offset = (long)TimeCurrent() - (long)TimeGMT();
    }

    while(!FileIsEnding(h)){
      string ts = FileReadString(h);
      if(StringLen(ts)==0){ continue; }               // blank line
      if(StringGetCharacter(ts,0) == '#'){            // comment row: read & skip rest of line
        // consume the rest of the line safely (fields count may vary)
        // We’ll skip tokenizing for comments; move to next line by reading till EOL
        // Using CSV mode, FileReadString already steps fields; we just continue.
        // (No-op)
        continue;
      }

      string scope = FileReadString(h);
      string impact_s = FileReadString(h);
      double before_d = FileReadNumber(h);
      double after_d  = FileReadNumber(h);
      string title = FileReadString(h);

      datetime t_csv = StringToTime(ts);
      if(t_csv == 0) continue;

      // Convert to server time using offset (cast to datetime explicitly to avoid warnings).
      datetime t_srv = (datetime)((long)t_csv + offset);

      AAI_NewsEvent *e = new AAI_NewsEvent;
      e.t_server   = t_srv;
      e.scope      = scope;
      e.impact     = ImpactToInt(impact_s);
      e.before_min = (int)MathMax(0, (int)before_d);
      e.after_min  = (int)MathMax(0, (int)after_d);
      e.title      = title;
      rows.Add(e);
    }

    FileClose(h);
    return (rows.Total() > 0);
  }

  // Check if 'now' (server time) is inside any relevant window for 'sym'
  bool InWindow(const string sym, const datetime now,
                const bool filterHigh=true, const bool filterMedium=true, const bool filterLow=false) const
  {
    string base = (StringLen(sym)>=6 ? StringSubstr(sym,0,3) : "");
    string quote= (StringLen(sym)>=6 ? StringSubstr(sym,3,3) : "");

    for(int i=0;i<rows.Total();++i){
      const AAI_NewsEvent *e = (const AAI_NewsEvent*)rows.At(i);
      // impact filter
      if( (e->impact==2 && !filterHigh) ||
          (e->impact==1 && !filterMedium) ||
          (e->impact==0 && !filterLow) ) continue;

      // scope match: *, exact symbol, base or quote
      bool match = (e->scope=="*") || (e->scope==sym) || (e->scope==base) || (e->scope==quote);
      if(!match) continue;

      datetime a = (datetime)((long)e->t_server - (long)e->before_min*60L);
      datetime b = (datetime)((long)e->t_server + (long)e->after_min *60L);
      if(now >= a && now <= b) return true;
    }
    return false;
  }
};

// Global (or make it a member of your EA)
static AAI_NewsStore AAI_NEWS;

inline bool AAI_News_LoadCsv(const string fnameCommon, const bool timesAreUTC){
  return AAI_NEWS.LoadCsv(fnameCommon, timesAreUTC);
}

inline bool AAI_News_InWindow(const string sym, const datetime now,
                              const bool filterHigh, const bool filterMedium, const bool filterLow)
{
  return AAI_NEWS.InWindow(sym, now, filterHigh, filterMedium, filterLow);
}

inline void AAI_News_Clear(){
  AAI_NEWS.Clear();
}
