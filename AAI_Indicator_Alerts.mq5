//+------------------------------------------------------------------+
//|                       AAI_Indicator_Alerts.mq5                     |
//|           v3.1 - Fixed TerminalInfoInteger compilation error     |
//|       Sends Telegram alerts based on AAI_Indicator_SignalBrain   |
//|                                                                  |
//| Copyright 2025, AlfredAI Project                                 |
//+------------------------------------------------------------------+
#property indicator_chart_window
#property strict
#property version "3.1"
#property description "Sends rich, formatted Telegram alerts for high-confidence signals."

// --- This indicator has no buffers or plots; it only sends alerts.
#property indicator_plots 0

//--- Indicator Inputs
input int    MinConfidenceThreshold = 10;     // Min confidence score (0-100) to trigger an alert
input bool   AlertsDryRun      = true;     // If true, prints alerts to Terminal instead of sending
input string TelegramToken       = "REPLACE_WITH_YOUR_TOKEN";
input string TelegramChatID      = "REPLACE_WITH_YOUR_CHAT_ID";

// --- Globals
static datetime g_lastAlertBarTime = 0; // Throttling: Ensures one alert per bar
int g_sb_handle = INVALID_HANDLE;
int g_ze_handle = INVALID_HANDLE;
int g_bc_handle = INVALID_HANDLE;
int g_atr_handle = INVALID_HANDLE;

#define EVT_TG_OK   "[EVT_TG_OK]"
#define EVT_TG_FAIL "[EVT_TG_FAIL]"

// --- Constants to mirror EA calculations for consistency ---
#define SL_BUFFER_POINTS 10
#define FIXED_RR 1.6
#define ATR_PERIOD 14

// --- Helper Enums (copied from SignalBrain for decoding)
enum ENUM_TRADE_SIGNAL
{
    SIGNAL_NONE = 0,
    SIGNAL_BUY  = 1,
    SIGNAL_SELL = -1
};

enum ENUM_REASON_CODE
{
    REASON_NONE,
    REASON_BUY_HTF_CONTINUATION,
    REASON_SELL_HTF_CONTINUATION,
    REASON_BUY_LIQ_GRAB_ALIGNED,
    REASON_SELL_LIQ_GRAB_ALIGNED,
    REASON_NO_ZONE,
    REASON_LOW_ZONE_STRENGTH,
    REASON_BIAS_CONFLICT,
    REASON_TEST_SCENARIO
};

//+------------------------------------------------------------------+
//| Custom indicator initialization function                         |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- Check if WebRequest is allowed (using direct integer value for compatibility)
   if((int)TerminalInfoInteger(26) == 0) // 26 is the value for TERMINAL_INFO_WEBREQUEST_ALLOWED
     {
      Print("Error: WebRequest is not enabled. Please go to Tools -> Options -> Expert Advisors and add 'https://api.telegram.org'.");
     }
     
   // --- Initialize Indicator Handles ---
   g_sb_handle = iCustom(_Symbol, _Period, "AAI_Indicator_SignalBrain");
   g_ze_handle = iCustom(_Symbol, _Period, "AAI_Indicator_ZoneEngine");
   g_bc_handle = iCustom(_Symbol, _Period, "AAI_Indicator_BiasCompass");
   g_atr_handle = iATR(_Symbol, _Period, ATR_PERIOD);
   
   if(g_sb_handle == INVALID_HANDLE || g_ze_handle == INVALID_HANDLE || g_bc_handle == INVALID_HANDLE || g_atr_handle == INVALID_HANDLE)
   {
      Print("Error: Failed to initialize one or more indicator handles. Alerts will not function.");
      return(INIT_FAILED);
   }

   Print("✅ AAI Alerts Initialized. Monitoring for signals with confidence >= ", MinConfidenceThreshold);
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Deinitialization                                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    if(g_sb_handle != INVALID_HANDLE) IndicatorRelease(g_sb_handle);
    if(g_ze_handle != INVALID_HANDLE) IndicatorRelease(g_ze_handle);
    if(g_bc_handle != INVALID_HANDLE) IndicatorRelease(g_bc_handle);
    if(g_atr_handle != INVALID_HANDLE) IndicatorRelease(g_atr_handle);
}

//+------------------------------------------------------------------+
//| Main Calculation - Runs on new bar to check for alerts           |
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
    if(rates_total < 2) return(rates_total);

    // --- Operate on the last closed bar ---
    int closed_bar_idx = rates_total - 2;
    datetime closed_bar_time = time[closed_bar_idx];

    // --- Throttle: Only one alert per bar ---
    if(closed_bar_time <= g_lastAlertBarTime) return(rates_total);

    // --- 1. Fetch latest data from SignalBrain ---
    double sb_data[4]; // 0:Signal, 1:Confidence, 2:Reason, 3:ZoneTF
    if(CopyBuffer(g_sb_handle, 0, 1, 4, sb_data) < 4) return(rates_total);

    ENUM_TRADE_SIGNAL signal = (ENUM_TRADE_SIGNAL)sb_data[0];
    double confidence        = sb_data[1];
    ENUM_REASON_CODE reason  = (ENUM_REASON_CODE)sb_data[2];

    // --- 2. Check Alert Conditions ---
    if(signal != SIGNAL_NONE && confidence >= MinConfidenceThreshold)
    {
        // --- 3. Gather Confluence Data for the message ---
        double ze_strength = 0;
        double htf_bias = 0;
        double ze_arr[1], bc_arr[1];
        if(CopyBuffer(g_ze_handle, 0, 1, 1, ze_arr) > 0) ze_strength = ze_arr[0];
        if(CopyBuffer(g_bc_handle, 0, 1, 1, bc_arr) > 0) htf_bias = bc_arr[0];
        
        // --- 4. Conditions met, send the alert ---
        SendTelegramAlert(signal, confidence, reason, ze_strength, htf_bias);
        g_lastAlertBarTime = closed_bar_time; // Update timestamp to prevent re-alerting
    }

    return(rates_total);
}

//+------------------------------------------------------------------+
//|               SEND TELEGRAM ALERT FUNCTION                     |
//+------------------------------------------------------------------+
void SendTelegramAlert(ENUM_TRADE_SIGNAL signal, double confidence, ENUM_REASON_CODE reason, double ze_strength, double htf_bias)
{
   // --- 1. Calculate SL/TP to include in the message (mirroring EA logic) ---
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return;
   
   double atr_val = 0;
   double atr_arr[1];
   if(CopyBuffer(g_atr_handle, 0, 1, 1, atr_arr) > 0) atr_val = atr_arr[0];
   if(atr_val == 0) return; // Cannot calculate SL without ATR
   
   const int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   const double pip_size = PipSize();
   const double sl_dist = atr_val + (SL_BUFFER_POINTS * _Point);
   
   double entry = (signal == SIGNAL_BUY) ? tick.ask : tick.bid;
   double sl = 0, tp = 0;
   
   if(signal == SIGNAL_BUY){
       sl = NormalizeDouble(entry - sl_dist, digits);
       tp = NormalizeDouble(entry + FIXED_RR * (entry - sl), digits);
   } else {
       sl = NormalizeDouble(entry + sl_dist, digits);
       tp = NormalizeDouble(entry - FIXED_RR * (sl - entry), digits);
   }
   
   int sl_pips = (int)MathRound(MathAbs(entry - sl) / pip_size);
   int tp_pips = (int)MathRound(MathAbs(entry - tp) / pip_size);
   string reason_text = ReasonCodeToString(reason);

   // --- 2. Format the rich message ---
   string side = (signal == SIGNAL_BUY) ? "BUY" : "SELL";
   
   string msg_p1 = StringFormat("[Alfred_AI] %s %s • %s • conf %d • ZE %d/100 • bias %d",
                                _Symbol, PeriodToString(_Period), side, (int)confidence,
                                (int)ze_strength, (int)htf_bias);

   string msg_p2 = StringFormat("Entry %.5f | SL %.5f (%dp) | TP %.5f (%dp) | R %.2f",
                                entry, sl, sl_pips, tp, tp_pips, FIXED_RR);
    
   string msg_p3 = StringFormat("Reason: %s (%d)", reason_text, (int)reason);

   string full_message = msg_p1 + "\n" + msg_p2 + "\n" + msg_p3;
   
   // --- 3. Handle DryRun or send the message ---
   if(AlertsDryRun || TelegramToken == "REPLACE_WITH_YOUR_TOKEN" || TelegramChatID == "REPLACE_WITH_YOUR_CHAT_ID")
   {
      Print("--- AAI Alert (Dry Run) ---\n", full_message);
      return;
   }

   // --- 4. URL Encode and construct the final URL ---
   string url_message = full_message;
   StringReplace(url_message, " ", "%20");
   StringReplace(url_message, "\n", "%0A");
   StringReplace(url_message, "|", "%7C");
   StringReplace(url_message, "•", "%E2%80%A2");

   string url = "https://api.telegram.org/bot" + TelegramToken +
                "/sendMessage?chat_id=" + TelegramChatID +
                "&text=" + url_message;

   // --- 5. Send the WebRequest ---
   char post_data[];
   char result[];
   int result_code;
   string result_headers;

   ResetLastError();
   result_code = WebRequest("GET", url, NULL, NULL, 5000, post_data, 0, result, result_headers);

   // --- 6. Handle the response ---
   if(result_code == 200)
     {
      PrintFormat("%s Telegram alert sent for %s", EVT_TG_OK, _Symbol);
     }
   else
     {
      PrintFormat("%s Failed to send alert for %s. Code: %d, Error: %s", EVT_TG_FAIL, _Symbol, result_code, GetLastErrorDescription(GetLastError()));
     }
}


//+------------------------------------------------------------------+
//|                      HELPER FUNCTIONS                          |
//+------------------------------------------------------------------+
// --- Returns Pip Size for the current symbol
double PipSize()
{
   return (_Digits == 3 || _Digits == 5) ? 10 * _Point : _Point;
}

//--- Converts reason code to a full, readable string
string ReasonCodeToString(ENUM_REASON_CODE code)
{
    switch(code)
    {
        case REASON_BUY_HTF_CONTINUATION:   return "Trend Continuation (Buy)";
        case REASON_SELL_HTF_CONTINUATION:  return "Trend Continuation (Sell)";
        case REASON_BUY_LIQ_GRAB_ALIGNED:   return "Liquidity Grab (Buy)";
        case REASON_SELL_LIQ_GRAB_ALIGNED:  return "Liquidity Grab (Sell)";
        case REASON_TEST_SCENARIO:          return "Test Scenario";
        case REASON_BIAS_CONFLICT:          return "Bias Conflict";
        case REASON_LOW_ZONE_STRENGTH:      return "Low Zone Strength";
        case REASON_NO_ZONE:                return "No Zone Contact";
        case REASON_NONE:
        default:                            return "Signal Confluence";
    }
}

//--- Converts MQL5 ENUM_TIMEFRAMES to a readable string
string PeriodToString(ENUM_TIMEFRAMES period)
{
   switch(period)
   {
      case PERIOD_M1:  return "M1";  case PERIOD_M5:  return "M5";
      case PERIOD_M15: return "M15"; case PERIOD_M30: return "M30";
      case PERIOD_H1:  return "H1";  case PERIOD_H2:  return "H2";
      case PERIOD_H4:  return "H4";  case PERIOD_D1:  return "D1";
      case PERIOD_W1:  return "W1";  case PERIOD_MN1: return "MN1";
      default:         return EnumToString(period);
   }
}

//--- Translates MQL5 GetLastError() into a readable string
string GetLastErrorDescription(int error_code)
{
    switch(error_code)
    {
        case 4014: return "WebRequest function is not allowed";
        case 4015: return "Error opening URL";
        case 4016: return "Error connecting to URL";
        case 4017: return "Error sending request";
        case 4018: return "Error receiving data";
        default:   return "Unknown WebRequest error (" + (string)error_code + ")";
    }
}
//+------------------------------------------------------------------+

