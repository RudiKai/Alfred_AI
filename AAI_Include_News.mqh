//+------------------------------------------------------------------+
//|                     AAI_Include_News.mqh                         |
//|                  v1.0 - News/Event CSV Gate                      |
//|              Copyright 2025, AlfredAI Project                    |
//+------------------------------------------------------------------+
#ifndef AAI_INCLUDE_NEWS_MQH
#define AAI_INCLUDE_NEWS_MQH

#property strict

#include <Arrays/ArrayObj.mqh>
#include <Arrays/ArrayString.mqh>

// --- For parsing CSV
#ifndef AAI_STR_TRIM_DEFINED
#define AAI_STR_TRIM_DEFINED
void AAI_Trim(string &s)
{
   StringTrimLeft(s);
   StringTrimRight(s);
}
#endif

// --- Enum from EA for consistency
enum ENUM_NEWS_Mode { NEWS_OFF=0, NEWS_REQUIRED=1, NEWS_PREFERRED=2 };

//+------------------------------------------------------------------+
//| Holds the data for a single parsed news event.                   |
//+------------------------------------------------------------------+
class CNewsEvent : public CObject
{
public:
    datetime time_event;
    string   scope;
    string   impact;
    long     before_sec;
    long     after_sec;
    string   title;
};

//+------------------------------------------------------------------+
//| Manages loading and checking against a news event CSV.           |
//+------------------------------------------------------------------+
class AAI_NewsGate
{
private:
    CArrayObj* m_events;
    bool              m_enabled;
    ENUM_NEWS_Mode    m_mode;
    bool              m_times_are_utc;
    bool              m_filter_high;
    bool              m_filter_medium;
    bool              m_filter_low;
    int               m_penalty;
    
    string            m_symbol_base;
    string            m_symbol_quote;
    
    //+--------------------------------------------------------------+
    //| Loads and parses the news CSV from the common files path.    |
    //+--------------------------------------------------------------+
    void LoadCsv(const string csv_name)
    {
        if(csv_name == "" || m_events == NULL) return;

        int handle = FileOpen(csv_name, FILE_READ | FILE_TXT | FILE_COMMON | FILE_ANSI);
        if(handle == INVALID_HANDLE)
        {
            // Fail-open: if file is missing, we just don't have any events. Log once.
            if(!MQLInfoInteger(MQL_TESTER)) // Don't spam tester logs
                PrintFormat("[NewsGate] WARN: CSV file not found at MQL5\\Files\\%s. Gate will be permissive.", csv_name);
            return;
        }

        while(!FileIsEnding(handle))
        {
            string line = FileReadString(handle);
            AAI_Trim(line);

            if(StringGetCharacter(line, 0) == '#' || line == "") continue;

            string parts[];
            if(StringSplit(line, ',', parts) < 5) continue;

            CNewsEvent *event = new CNewsEvent();
            if(!event) continue;

            // 1. Time
            string time_str = parts[0];
            AAI_Trim(time_str);
            event.time_event = StringToTime(time_str);
            
            // 2. Scope
            event.scope = parts[1];
            AAI_Trim(event.scope);

            // 3. Impact
            event.impact = parts[2];
            AAI_Trim(event.impact);

            // 4. Window Before (minutes)
            event.before_sec = (long)StringToInteger(parts[3]) * 60;

            // 5. Window After (minutes)
            event.after_sec = (long)StringToInteger(parts[4]) * 60;
            
            // 6. Title (optional)
            if(ArraySize(parts) > 5)
            {
               event.title = parts[5];
               AAI_Trim(event.title);
            }

            m_events.Add(event);
        }
        
        FileClose(handle);
        PrintFormat("[NewsGate] Loaded %d events from %s.", m_events.Total(), csv_name);
    }

public:
    //+--------------------------------------------------------------+
    //| Constructor                                                  |
    //+--------------------------------------------------------------+
    AAI_NewsGate()
    {
        m_events = new CArrayObj();
        m_enabled = false;
    }

    //+--------------------------------------------------------------+
    //| Destructor                                                   |
    //+--------------------------------------------------------------+
   ~AAI_NewsGate()
    {
if(m_events != NULL && CheckPointer(m_events) != POINTER_INVALID)
        {
for(int i = m_events.Total() - 1; i >= 0; --i) { delete m_events.At(i); }
m_events.Clear();
            delete m_events;
        }
    }

    //+--------------------------------------------------------------+
    //| Initializes the gate with settings from the EA.              |
    //+--------------------------------------------------------------+
    bool Init(
        bool enable,
        string csv_name,
        ENUM_NEWS_Mode mode,
        bool times_are_utc,
        bool filter_high,
        bool filter_medium,
        bool filter_low,
        int penalty
    )
    {
        m_enabled = enable;
        if(!m_enabled || mode == NEWS_OFF) return true;
        
        m_mode = mode;
        m_times_are_utc = times_are_utc;
        m_filter_high = filter_high;
        m_filter_medium = filter_medium;
        m_filter_low = filter_low;
        m_penalty = penalty;
        
        // Get symbol currencies for scope matching
        m_symbol_base = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_BASE);
        m_symbol_quote = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_PROFIT);

if(m_events != NULL && CheckPointer(m_events) != POINTER_INVALID)
        {
            m_events.Clear();
            LoadCsv(csv_name);
        }
        
        return true;
    }

    //+--------------------------------------------------------------+
    //| Checks if the current time falls within a news event window. |
    //+--------------------------------------------------------------+
    bool CheckGate(datetime now_server, double &confidence)
    {
        if(!m_enabled || m_mode == NEWS_OFF || m_events.Total() == 0) return true;

        datetime now_check = m_times_are_utc ? TimeGMT() : now_server;

        for(int i = 0; i < m_events.Total(); i++)
        {
            CNewsEvent *event = (CNewsEvent*)m_events.At(i);
            if(!event) continue;

            // Filter by Impact
            if((StringFind(event.impact, "High", 0) >= 0 && !m_filter_high) ||
               (StringFind(event.impact, "Medium", 0) >= 0 && !m_filter_medium) ||
               (StringFind(event.impact, "Low", 0) >= 0 && !m_filter_low))
            {
                continue;
            }
            
            // Filter by Scope
            bool scope_match = (event.scope == "*" ||
                                event.scope == _Symbol ||
                                event.scope == m_symbol_base ||
                                event.scope == m_symbol_quote);
            
            if(!scope_match) continue;
            
            // Check if current time is inside the event window
datetime window_start = (datetime)((long)event.time_event - (long)event.before_sec);
datetime window_end   = (datetime)((long)event.time_event + (long)event.after_sec);
            
            if(now_check >= window_start && now_check <= window_end)
            {
                if(m_mode == NEWS_REQUIRED)
                {
                    // Block the trade
                    return false;
                }
                else if(m_mode == NEWS_PREFERRED)
                {
                    // Apply penalty and continue checking other gates
                    confidence = MathMax(0, confidence - m_penalty);
                    // One penalty is enough, no need to check other news events
                    return true; 
                }
            }
        }

        return true; // No blocking news event found
    }
};

#endif // AAI_INCLUDE_NEWS_MQH
