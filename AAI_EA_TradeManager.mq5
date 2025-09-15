// ====================== AAI METRICS (PF/WR/Avg/MaxDD/AvgDur) ======================
#ifndef AAI_METRICS_DEFINED
#define AAI_METRICS_DEFINED
int    AAI_trades = 0;
int    AAI_wins = 0, AAI_losses = 0;
double AAI_gross_profit = 0.0;
// sum of positive net P&L
double AAI_gross_loss   = 0.0;
// sum of negative net P&L (stored as positive abs)
double AAI_sum_win      = 0.0;
// for avg win
double AAI_sum_loss_abs = 0.0;    // for avg loss (abs)
int    AAI_win_count = 0, AAI_loss_count = 0;
double AAI_curve = 0.0;           // equity curve (closed-trade increments)
double AAI_peak  = 0.0;           // peak of curve
double AAI_max_dd = 0.0;
// max drawdown (abs) on closed-trade curve

long   AAI_last_in_pos_id = -1;
datetime AAI_last_in_time = 0;
ulong  AAI_last_out_deal = 0;     // dedupe out deals
ulong  AAI_last_in_deal  = 0;
// (reuses exec hook dedupe if present)

// Net P&L for a deal: profit + commission + swap
double AAI_NetDealPL(ulong deal_ticket)
{
   if(!HistoryDealSelect((long)deal_ticket)) return 0.0;
   double p  = HistoryDealGetDouble(deal_ticket, DEAL_PROFIT);
   double c  = HistoryDealGetDouble(deal_ticket, DEAL_COMMISSION);
   double sw = HistoryDealGetDouble(deal_ticket, DEAL_SWAP);
   return p + c + sw;
}

// Update drawdown stats on closed-trade increments
void AAI_UpdateCurve(double net_pl)
{
   AAI_curve += net_pl;
   if(AAI_curve > AAI_peak) AAI_peak = AAI_curve;
   double dd = AAI_peak - AAI_curve;
   if(dd > AAI_max_dd) AAI_max_dd = dd;
}
#endif

double AAI_dur_sum_sec = 0.0;
int    AAI_dur_count   = 0;

// ==================== /AAI METRICS ======================
//+------------------------------------------------------------------+
//| AAI_EA_Trade_Manager.mq5                                         |
//|           v4.1 - Timing Bug Fixes                                |
//|                                                                  |
//| (Consumes all data from the refactored AAI_Indicator_SignalBrain)|
//|                                                                  |
//| Copyright 2025, AlfredAI Project                                 |
//+------------------------------------------------------------------+
#property strict
#property version   "4.1"
#property description "Manages trades based on signals from the central SignalBrain indicator."
#include <Trade\Trade.mqh>
#include <Arrays\ArrayLong.mqh>

#define EVT_INIT  "[INIT]"
#define EVT_BAR   "[BAR]"
#define EVT_ENTRY "[ENTRY]"
#define EVT_EXIT  "[EXIT]"
#define EVT_TS    "[TS]"
#define EVT_PARTIAL "[PARTIAL]"
#define EVT_JOURNAL "[JOURNAL]"
#define EVT_ENTRY_CHECK "[EVT_ENTRY_CHECK]"
#define EVT_ORDER_BLOCKED "[EVT_ORDER_BLOCKED]"
#define EVT_WAIT "[EVT_WAIT]"
#define EVT_HEARTBEAT "[EVT_HEARTBEAT]"
#define EVT_TICK "[TICK]"
#define EVT_FIRST_BAR_OR_NEW "[EVT_FIRST_BAR_OR_NEW]"
#define EVT_WARN "[EVT_WARN]"
#define DBG_GATES "[DBG_GATES]"
#define DBG_STOPS "[DBG_STOPS]"
#define DBG_ZE    "[DBG_ZE]"
#define DBG_SPD   "[DBG_SPD]"
#define DBG_OVER  "[DBG_OVER]"
#define EVT_SUPPRESS "[EVT_SUPPRESS]"
#define EVT_COOLDOWN "[EVT_COOLDOWN]"
#define DBG_CONF  "[DBG_CONF]"
#define AAI_BLOCK_LOG "[AAI_BLOCK]"
#define INIT_ERROR "[INIT_ERROR]"
#define EVT_IDEA "[EVT_IDEA]"
#define EVT_SKIP "[EVT_SKIP]"
#define EVT_TG_OK "[EVT_TG_OK]"
#define EVT_TG_FAIL "[EVT_TG_FAIL]"


// === TICKET #2: Constants for NEW SignalBrain buffer indexes ===
#define SB_BUF_SIGNAL   0
#define SB_BUF_CONF     1
#define SB_BUF_REASON   2
#define SB_BUF_ZE       3
#define SB_BUF_SMC_SIG  4
#define SB_BUF_SMC_CONF 5
#define SB_BUF_BC       6

// --- EA Fixes (Part B): Indicator Path Helper ---
#define AAI_IND_PREFIX "AlfredAI\\"
inline string AAI_Ind(const string name)
{
   if(StringFind(name, AAI_IND_PREFIX) == 0) // already prefixed
      return name;
   return AAI_IND_PREFIX + name;
}



// --- T006: HUD Object Name ---
const string HUD_OBJECT_NAME = "AAI_HUD";
// ===================== AAI UTILS (idempotent) =======================
#ifndef AAI_UTILS_DEFINED
#define AAI_UTILS_DEFINED

// TICKET #2: New defensive read helper
inline bool Read1(int h,int b,int shift,double &out,const string id){
   double v[1]; if(CopyBuffer(h,b,shift,1,v)==1){ out=v[0]; return true; }
   static datetime lastWarn=0; datetime bt=iTime(_Symbol,_Period,shift);
   if(bt!=lastWarn){ PrintFormat("[%s_READFAIL] t=%s",id,TimeToString(bt,TIME_DATE|TIME_SECONDS)); lastWarn=bt; }
   return false;
}


// Fallback for printing ZE gate nicely
string ZE_GateToStr(int gate)
{
   switch(gate){
      case 0: return "ZE_OFF";
      case 1: return "ZE_PREFERRED";
      case 2: return "ZE_REQUIRED";
   }
   return "ZE_?";
}

// Helper to get short timeframe string (e.g., "M15")
string TFToStringShort(ENUM_TIMEFRAMES tf)
{
   string s = EnumToString(tf);
   StringReplace(s, "PERIOD_", "");
   return s;
}
int CurrentSpreadPoints()
{
    MqlTick t;
    if(!SymbolInfoTick(_Symbol, t)) return(INT_MAX);
    if(_Point <= 0.0) return(INT_MAX);
    return (int)MathRound((t.ask - t.bid) / _Point);
}
// --- Timeframe label helpers ---
inline string TfLabel(ENUM_TIMEFRAMES tf) {
   string s = EnumToString(tf);
   // e.g., "PERIOD_M15"
   int p = StringFind(s, "PERIOD_");
   return (p == 0 ? StringSubstr(s, 7) : s);
   // → "M15"
}

inline string CurrentTfLabel() {
   ENUM_TIMEFRAMES eff = (SignalTimeframe == PERIOD_CURRENT)
                         ?
   (ENUM_TIMEFRAMES)_Period
                         : SignalTimeframe;
   return TfLabel(eff);
}



#endif


// HYBRID toggle + timeout
input bool Hybrid_RequireApproval = false;
input int  Hybrid_TimeoutSec      = 600;
// Subfolders under MQL5/Files (no trailing backslash)
string   g_dir_base   = "AlfredAI";
string   g_dir_intent = "AlfredAI\\intents";
string   g_dir_cmds   = "AlfredAI\\cmds";

// Pending intent state
string   g_pending_id = "";
datetime g_pending_ts = 0;

// Store last computed order params for approval placement
string   g_last_side  = "";
double   g_last_entry = 0.0, g_last_sl = 0.0, g_last_tp = 0.0, g_last_vol = 0.0;
double   g_last_rr    = 0.0, g_last_conf_raw = 0.0, g_last_conf_eff = 0.0, g_last_ze = 0.0;
string   g_last_comment = "";


//--- Helper Enums
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
enum ENUM_EXECUTION_MODE { SignalsOnly, AutoExecute };
enum ENUM_APPROVAL_MODE  { None, Manual };
enum ENUM_ENTRY_MODE { FirstBarOrEdge, EdgeOnly };
enum ENUM_OVEREXT_MODE { HardBlock, WaitForBand };
enum ENUM_ZE_GATE_MODE { ZE_OFF=0, ZE_PREFERRED=1, ZE_REQUIRED=2 };
enum ENUM_BC_ALIGN_MODE { BC_OFF = 0, BC_PREFERRED = 1, BC_REQUIRED = 2 };
//--- EA Inputs
input ENUM_EXECUTION_MODE ExecutionMode = AutoExecute;
input ENUM_APPROVAL_MODE  ApprovalMode  = None;
input ENUM_ENTRY_MODE     EntryMode     = FirstBarOrEdge;
input ulong    MagicNumber          = 1337;
input ENUM_TIMEFRAMES SignalTimeframe = PERIOD_CURRENT;
input int SB_ReadShift = 1;
input int WarmupBars = 200;

// TICKET #2 --- All Pass-Through Inputs for the new SignalBrain ---
input group "--- SignalBrain Pass-Through Inputs ---";
// Core SB Settings
input bool   SB_SafeTest        = false;
input bool   SB_UseZE           = true;
input bool   SB_UseBC           = true;
input bool   SB_UseSMC          = true;
input int    SB_WarmupBars      = 150;
input int    SB_FastMA          = 10;
input int    SB_SlowMA          = 30;
input int    SB_MinZoneStrength = 4;
input bool   SB_EnableDebug     = true;
// SB Confidence Model
input int    SB_Bonus_ZE        = 25;
input int    SB_Bonus_BC        = 25;
input int    SB_Bonus_SMC       = 25;
// BC Pass-Through
input int    SB_BC_FastMA       = 10;
input int    SB_BC_SlowMA       = 30;
// ZE Pass-Through
input double SB_ZE_MinImpulseMovePips = 10.0;
// SMC Pass-Through
input bool   SB_SMC_UseFVG      = true;
input bool   SB_SMC_UseOB       = true;
input bool   SB_SMC_UseBOS      = true;
input double SB_SMC_FVG_MinPips = 1.0;
input int    SB_SMC_OB_Lookback = 20;
input int    SB_SMC_BOS_Lookback= 50;


//--- Risk Management Inputs ---
input group "Risk Management (M15 Baseline)"
input double   RiskPct           = 0.25;
input double   MinLotSize           = 0.01;
input double   MaxLotSize           = 10.0;
input int      SL_Buffer_Points  = 10;
//--- Trade Management Inputs ---
input group "Trade Management (M15 Baseline)"
input bool     PerBarDebounce       = true;
input uint     DuplicateGuardMs     = 300;
input int      CooldownAfterSLBars  = 2;
input int      MaxSpreadPoints      = 30;
input int      MaxSlippagePoints    = 20;
input int      FridayCloseHour      = 22;
input bool     EnableLogging        = true;
//--- Telegram Alerts ---
input group "Telegram Alerts"
input bool   UseTelegramFromEA = false;
input string TelegramToken       = "";
input string TelegramChatID      = "";
input bool   AlertsDryRun      = true;
//--- Session Inputs (idempotent) ---
#ifndef AAI_SESSION_INPUTS_DEFINED
#define AAI_SESSION_INPUTS_DEFINED
input bool SessionEnable = true;
input int  SessionStartHourServer = 9; // server time
input int  SessionEndHourServer   = 23;  // server time
#endif

#ifndef AAI_HYBRID_INPUTS_DEFINED
#define AAI_HYBRID_INPUTS_DEFINED
// Auto-trading window (server time). Outside -> alerts only.
input string AutoHourRanges = "8-14,19-23";    // comma-separated hour ranges
// Day mask for auto-trading (server time): Sun=0..Sat=6
input bool AutoSun=false, AutoMon=true, AutoTue=true, AutoWed=false, AutoThu=true, AutoFri=true, AutoSat=false;
// Alert channels + throttle
input bool  HybridAlertPopup       = true;
input bool  HybridAlertPush        = true; // requires terminal Push enabled
input bool  HybridAlertWriteIntent = true; // write intent file under g_dir_intent
input int   HybridAlertThrottleSec = 60; // min seconds between alerts for the same bar
#endif

//--- Adaptive Spread Inputs (idempotent) ---
#ifndef AAI_SPREAD_INPUTS_DEFINED
#define AAI_SPREAD_INPUTS_DEFINED
// Re-purposed MaxSpreadPoints from Trade Management as the hard cap
input int SpreadMedianWindowTicks    = 120;
input int SpreadHeadroomPoints       = 5; // allow median + headroom
#endif
////////////// 
#ifndef AAI_STR_TRIM_DEFINED
#define AAI_STR_TRIM_DEFINED
void AAI_Trim(string &s)
{
   StringTrimLeft(s);
   StringTrimRight(s);
}
#endif
//////////
//--- Exit Strategy Inputs (M15 Baseline) ---
input group "Exit Strategy"
input bool     Exit_FixedRR        = true;
input double   Fixed_RR            = 1.6;
input double   Partial_Pct         = 50.0;
input double   Partial_R_multiple  = 1.0;
input int      BE_Offset_Points    = 1;
input int      Trail_Start_Pips    = 22;
input int      Trail_Stop_Pips     = 10;
//--- Entry Filter Inputs (M15 Baseline) ---
input group "Entry Filters"
input int        MinConfidence        = 50; // TICKET #2: Default changed to 50
// --- T011: Over-extension Inputs ---
input group "Over-extension Guard"
input ENUM_OVEREXT_MODE OverExtMode = WaitForBand;
input int    OverExt_MA_Period      = 20;
input int    OverExt_ATR_Period     = 14;
input double OverExt_ATR_Mult       = 2.0;
input int    OverExt_WaitBars       = 3;
//--- Confluence Module Inputs (M15 Baseline) ---
input group "Confluence Modules"
input ENUM_BC_ALIGN_MODE BC_AlignMode   = BC_REQUIRED; // TICKET #2: Changed to REQUIRED
input ENUM_ZE_GATE_MODE  ZE_Gate        = ZE_REQUIRED; // TICKET #2: Changed to REQUIRED
input int        ZE_MinStrength       = 4; // This is now checked against raw ZE strength from SB

enum SMCMode { SMC_OFF=0, SMC_PREFERRED=1, SMC_REQUIRED=2 };
input SMCMode SMC_Mode = SMC_REQUIRED; // TICKET #2: Changed to REQUIRED
input int     SMC_MinConfidence = 7;

//--- Journaling Inputs ---
input group "Journaling"
input bool     EnableJournaling     = true;
input string   JournalFileName      = "AlfredAI_Journal.csv";
input bool     JournalUseCommonFiles = true;
input bool     EnableDecisionJournaling = false;
input string   DecisionJournalFileName = "AlfredAI_Decisions.csv";

//--- Globals
CTrade    trade;
string    symbolName;
double    point;
static ulong g_logged_positions[]; // For duplicate journal entry prevention
int       g_logged_positions_total = 0;
// --- T011: Over-extension State ---
static int g_overext_wait = 0;
// --- TICKET #3: Over-extension timing fix ---
static datetime g_last_overext_dec_sigbar = 0;

// --- TICKET #2: Simplified Persistent Indicator Handles ---
int sb_handle = INVALID_HANDLE;
int g_hATR = INVALID_HANDLE;
int g_hOverextMA = INVALID_HANDLE;

// --- State Management Globals ---
static datetime g_lastBarTime = 0;
static datetime g_last_suppress_log_time = 0;
static datetime g_last_telegram_alert_bar = 0;
static ulong    g_tickCount   = 0;
static datetime g_last_ea_warmup_log_time = 0;
static datetime g_last_per_bar_journal_time = 0;
bool g_bootstrap_done = false;
static datetime g_last_entry_bar_buy = 0, g_last_entry_bar_sell = 0;
static ulong    g_last_send_sig_hash = 0;
static ulong g_last_send_ms = 0;
static datetime g_cool_until_buy = 0, g_cool_until_sell = 0;

// --- T012: Summary Counters ---
static long g_entries      = 0;
static long g_wins         = 0;
static long g_losses       = 0;
static long g_blk_ze       = 0;
static long g_blk_bc       = 0;
static long g_blk_over     = 0;
static long g_blk_spread   = 0;
static long g_blk_smc      = 0; // TICKET #2: Added SMC block counter
static bool g_summary_printed = false;
// --- Once-per-bar stamps for block counters ---
datetime g_stamp_conf  = 0;
datetime g_stamp_ze    = 0;
datetime g_stamp_bc    = 0;
datetime g_stamp_over  = 0;
datetime g_stamp_sess  = 0;
datetime g_stamp_spd   = 0;
datetime g_stamp_atr   = 0;
datetime g_stamp_cool  = 0;
datetime g_stamp_bar   = 0;
datetime g_stamp_smc   = 0;
datetime g_stamp_none  = 0;
datetime g_stamp_approval = 0;

#ifndef AAI_HYBRID_STATE_DEFINED
#define AAI_HYBRID_STATE_DEFINED
bool g_auto_hour_mask[24];
datetime g_hyb_last_alert_bar = 0;
datetime g_hyb_last_alert_ts  = 0;
int g_blk_hyb = 0;            // count "alert-only" bars
datetime g_stamp_hyb = 0;     // once-per-bar stamp
#endif

//+------------------------------------------------------------------+
//| T012: Print Golden Summary                                       |
//+------------------------------------------------------------------+
void PrintSummary()
{
    if(g_summary_printed) return;
    PrintFormat("AAI_SUMMARY|entries=%d|wins=%d|losses=%d|ze_blk=%d|bc_blk=%d|smc_blk=%d|overext_blk=%d|spread_blk=%d",
                g_entries,
                g_wins,
                g_losses,
                g_blk_ze,
                g_blk_bc,
                g_blk_smc,
                g_blk_over,
                g_blk_spread);
    g_summary_printed = true;
}
// ====================== AAI JOURNAL HELPERS ======================
#ifndef AAI_EA_LOG_DEFINED
#define AAI_EA_LOG_DEFINED

// Append a line to the AlfredAI journal.
void AAI_AppendJournal(const string line)
{
   if (MQLInfoInteger(MQL_TESTER) || MQLInfoInteger(MQL_OPTIMIZATION))
   {
      Print(line);
      return;
   }

   // Live/demo: write to file (optional) and also mirror to Experts log
   string name       = JournalFileName;
   bool   use_common = JournalUseCommonFiles;

   if (name == NULL || name == "")
   {
      Print(line);
      return;
   }

   uint flags = FILE_READ | FILE_WRITE | FILE_TXT;
   if (use_common) flags |= FILE_COMMON;
   int fh = FileOpen(name, flags);
   if (fh == INVALID_HANDLE)
   {
      PrintFormat("[AAI_JOURNAL] open failed (%d) for '%s'", GetLastError(), name);
      Print(line);
      return;
   }

   FileSeek(fh, 0, SEEK_END);
   FileWriteString(fh, line + "\r\n");
   FileFlush(fh);
   FileClose(fh);
   // Mirror to Experts log in live/demo
   Print(line);
}

// Build & write an EXEC line (dir: +1 BUY, -1 SELL).
void AAI_LogExec(const int dir, double lots_hint = 0.0, const string run_id = "adhoc")
{
   double entry = 0.0, sl = 0.0, tp = 0.0, lots_eff = lots_hint;
   // Prefer immediate trade result (just sent order)
   double r_price  = trade.ResultPrice();
   double r_volume = trade.ResultVolume();
   if (r_price  > 0.0) entry    = r_price;
   if (r_volume > 0.0) lots_eff = r_volume;
   // Fallback: live position
   if (PositionSelect(_Symbol))
   {
      double pos_open = PositionGetDouble(POSITION_PRICE_OPEN);
      double pos_sl   = PositionGetDouble(POSITION_SL);
      double pos_tp   = PositionGetDouble(POSITION_TP);
      double pos_vol  = PositionGetDouble(POSITION_VOLUME);
      if (entry    <= 0.0 && pos_open > 0.0) entry    = pos_open;
      if (sl       <= 0.0 && pos_sl   > 0.0) sl       = pos_sl;
      if (tp       <= 0.0 && pos_tp   > 0.0) tp       = pos_tp;
      if (lots_eff <= 0.0 && pos_vol  > 0.0) lots_eff = pos_vol;
   }

   // Format to symbol precision so numbers look right
   int d = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   string execLine = StringFormat(
      "EXEC|t=%s|sym=%s|tf=%s|dir=%s|lots=%.2f|entry=%.*f|sl=%.*f|tp=%.*f|rr=%.2f|run=%s",
      TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS),
      _Symbol,
      CurrentTfLabel(),                 // your helper, e.g., "M15", "H1", ...
      (dir > 0 ? "BUY" : "SELL"),
      lots_eff,
      d, entry, d, sl, d, tp,
      Fixed_RR,
      run_id
   );
   // Tester path: print exactly once; no file I/O
   if (MQLInfoInteger(MQL_TESTER) || MQLInfoInteger(MQL_OPTIMIZATION))
   {
      Print(execLine);
      return;
   }

   // Live/demo: file (if configured) + Experts log
   AAI_AppendJournal(execLine);
}

#endif
// ==================== /AAI JOURNAL HELPERS ======================



//+------------------------------------------------------------------+
//| T006: Updates the on-chart HUD with the latest closed bar state. |
//+------------------------------------------------------------------+
void UpdateHUD(int sig, double conf, int reason, double ze, int bc)
{
    const int readShift = 1;
    datetime closedBarTime = iTime(_Symbol, (ENUM_TIMEFRAMES)SignalTimeframe, readShift);
    if (closedBarTime == 0) return;

    string hudText = StringFormat("HUD: t=%s sig=%d conf=%.0f reason=%d ze=%.1f bc=%d",
                                  TimeToString(closedBarTime, TIME_MINUTES),
                                  sig,
                                  conf,
                                  reason,
                                  ze,
                                  bc);

    ObjectSetString(0, HUD_OBJECT_NAME, OBJPROP_TEXT, hudText);
}

//+------------------------------------------------------------------+
//| T004: Logs a single line with the state of the last closed bar.  |
//| T005: Persists the log to a daily rotating CSV file.             |
//+------------------------------------------------------------------+
void LogPerBarStatus(int sig, double conf, int reason, double ze, int bc)
{
    const int readShift = 1;
    datetime closedBarTime = iTime(_Symbol, (ENUM_TIMEFRAMES)SignalTimeframe, readShift);
    if (closedBarTime == g_last_per_bar_journal_time || closedBarTime == 0)
       return;
    g_last_per_bar_journal_time = closedBarTime;
    
    string tfStr = CurrentTfLabel();

    // ------------------ T005: Daily CSV ------------------
    MqlDateTime __dt;
    TimeToStruct(closedBarTime, __dt);
    string ymd = StringFormat("%04d%02d%02d", __dt.year, __dt.mon, __dt.day);
    string filename = "AAI_Journal_" + ymd + ".csv";

    int handle = FileOpen(filename, FILE_READ | FILE_WRITE | FILE_CSV | FILE_SHARE_READ | FILE_ANSI, ',');
    if (handle != INVALID_HANDLE)
    {
       if (FileSize(handle) == 0)
          FileWriteString(handle, "t,sym,tf,sig,conf,reason,ze,bc,mode\n");
       FileSeek(handle, 0, SEEK_END);
       string csvRow = StringFormat(
          "%s,%s,%s,%d,%.0f,%d,%.1f,%d,%s\n",
          TimeToString(closedBarTime, TIME_DATE | TIME_SECONDS),
          _Symbol,
          tfStr,
          sig,
          conf,
          reason,
          ze,
          bc,
          EnumToString(ExecutionMode)
       );
       FileWriteString(handle, csvRow);
       FileClose(handle);
    }
    else
    {
       PrintFormat("[ERROR] T005: Could not open daily journal file %s", filename);
    }

    // ------------------ T004: Per-bar heartbeat ------------------
    string logLine = StringFormat(
       "AAI|t=%s|sym=%s|tf=%s|sig=%d|conf=%.0f|reason=%d|ze=%.1f|bc=%d|mode=%s",
       TimeToString(closedBarTime, TIME_DATE | TIME_SECONDS),
       _Symbol,
       tfStr,
       sig,
       conf,
       reason,
       ze,
       bc,
       EnumToString(ExecutionMode)
    );
    Print(logLine);
    AAI_AppendJournal(logLine);
}


//+------------------------------------------------------------------+
//| HYBRID Approval Helper Functions                                 |
//+------------------------------------------------------------------+
bool WriteText(const string path, const string text)
{
   int h = FileOpen(path, FILE_WRITE|FILE_TXT|FILE_ANSI);
   if(h==INVALID_HANDLE){ PrintFormat("[HYBRID] FileOpen write fail %s (%d)", path, GetLastError()); return false; }
   FileWriteString(h, text);
   FileClose(h);
   return true;
}

string ReadAll(const string path)
{
   int h = FileOpen(path, FILE_READ|FILE_TXT|FILE_ANSI);
   if(h==INVALID_HANDLE) return "";
   string s = FileReadString(h, (int)FileSize(h));
   FileClose(h);
   return s;
}

string JsonGetStr(const string json, const string key)
{
   string pat="\""+key+"\":\"";
   int p=StringFind(json, pat); if(p<0) return "";
   p+=StringLen(pat);
   int q=StringFind(json,"\"",p);
   if(q<0) return "";
   return StringSubstr(json, p, q-p);
}

#ifndef AAI_HYBRID_UTILS_DEFINED
#define AAI_HYBRID_UTILS_DEFINED
void AAI_ParseHourRanges(const string ranges, bool &mask[])
{
   ArrayInitialize(mask,false);
   string parts[];
   int n=StringSplit(ranges, ',', parts);
   for(int i=0;i<n;i++){
      string p = parts[i];
      AAI_Trim(p);
      if(StringLen(p)==0) continue;
      int dash=StringFind(p,"-");
      if(dash<0){ int h=(int)StringToInteger(p)%24; if(h>=0) mask[h]=true; continue; }
      int a=(int)StringToInteger(StringSubstr(p,0,dash));
      int b=(int)StringToInteger(StringSubstr(p,dash+1));
      a=(a%24+24)%24; b=(b%24+24)%24;
      if(a<=b){ for(int h=a;h<=b;h++) mask[h]=true; }
      else    { for(int h=a;h<24;h++) mask[h]=true;
      for(int h=0;h<=b;h++) mask[h]=true; }
   }
}
bool AAI_HourDayAutoOK()
{
   MqlDateTime dt; TimeToStruct(TimeTradeServer(), dt);
   bool day_ok = ( (dt.day_of_week==0 && AutoSun) || (dt.day_of_week==1 && AutoMon) || (dt.day_of_week==2 && AutoTue) ||
                   (dt.day_of_week==3 && AutoWed) || (dt.day_of_week==4 && AutoThu) || (dt.day_of_week==5 && AutoFri) ||
                   (dt.day_of_week==6 && AutoSat) );
   bool hour_ok = g_auto_hour_mask[dt.hour];
   return (day_ok && hour_ok);
}
void AAI_RaiseHybridAlert(const string side, const double conf_eff, const double ze_strength,
                          const double smc_conf, const int spread_pts,
                          const double atr_pips, const double entry, const double sl, const double tp)
{
   // once-per-bar throttle
   if(g_lastBarTime==g_hyb_last_alert_bar)
   {
    
      if((TimeCurrent() - g_hyb_last_alert_ts) < HybridAlertThrottleSec) return;
   }
   g_hyb_last_alert_bar = g_lastBarTime;
   g_hyb_last_alert_ts  = TimeCurrent();
   string msg = StringFormat("[HYBRID_ALERT] %s %s conf=%.1f ZE=%.1f SMC=%.1f spr=%d atr=%.1fp @%.5f SL=%.5f TP=%.5f",
                              _Symbol, side, conf_eff, ze_strength, smc_conf, spread_pts, atr_pips, entry, sl, tp);
   if(HybridAlertPopup) Alert(msg);
   if(HybridAlertPush)  SendNotification(msg);

   if(HybridAlertWriteIntent)
   {
      // write a simple intent file for your existing hybrid workflow
      string fn = StringFormat("%s\\%s_%s_%I64d.txt", g_dir_intent, _Symbol, side, (long)g_lastBarTime);
      int h = FileOpen(fn, FILE_WRITE|FILE_TXT|FILE_ANSI);
      if(h!=INVALID_HANDLE){
         FileWrite(h, msg);
         FileClose(h);
      }
   }
}
#endif

//+------------------------------------------------------------------+
//| Journal a decision to skip a trade                               |
//+------------------------------------------------------------------+
void JournalDecision(string reason)
{
    if(!EnableDecisionJournaling) return;

    int file_handle = FileOpen(DecisionJournalFileName, FILE_READ|FILE_WRITE|FILE_CSV|(JournalUseCommonFiles ? FILE_COMMON : 0), ';');
    if(file_handle == INVALID_HANDLE) return;

    if(FileSize(file_handle) == 0)
    {
        FileWriteString(file_handle, "TimeLocal;TimeServer;Symbol;TF;Reason\n");
    }
    FileSeek(file_handle, 0, SEEK_END);

    string line = StringFormat("%s;%s;%s;%s;%s\n",
        TimeToString(TimeLocal(), TIME_DATE|TIME_SECONDS),
        TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS),
        _Symbol,
        EnumToString(_Period),
        reason
    );
    FileWriteString(file_handle, line);
    FileClose(file_handle);
}

//+------------------------------------------------------------------+
//| Centralized block counting and logging                           |
//+------------------------------------------------------------------+
void AAI_Block(const string reason)
{
   JournalDecision(reason); // Log every block decision if enabled
   
   string r = reason;
   StringToLower(r);

   // choose target counter + stamp by reason
   if(StringFind(r, "overext") == 0)
   {
      if(g_stamp_over != g_lastBarTime){ g_blk_over++; g_stamp_over = g_lastBarTime; }
   }
   else if(r == "confidence")
   {
      if(g_stamp_conf != g_lastBarTime){ g_stamp_conf = g_lastBarTime; }
   }
   else if(r == "ze_required")
   {
      if(g_stamp_ze != g_lastBarTime){ g_blk_ze++; g_stamp_ze = g_lastBarTime; }
   }
   else if(r == "bc" || r == "bc_conflict" || r == "bc_required")
   {
      if(g_stamp_bc != g_lastBarTime){ g_blk_bc++; g_stamp_bc = g_lastBarTime; }
   }
   else if(r == "session")
   {
      if(g_stamp_sess != g_lastBarTime){ g_stamp_sess = g_lastBarTime; }
   }
   else if(r == "spread")
   {
      if(g_stamp_spd != g_lastBarTime){ g_blk_spread++; g_stamp_spd = g_lastBarTime; }
   }
   else if(r == "cooldown")
   {
      if(g_stamp_cool != g_lastBarTime){ g_stamp_cool = g_lastBarTime; }
   }
   else if(r == "same_bar")
   {
      if(g_stamp_bar != g_lastBarTime){ g_stamp_bar = g_lastBarTime; }
   }
   else if(r == "atr")
   {
      if(g_stamp_atr != g_lastBarTime){ g_stamp_atr = g_lastBarTime; }
   }
   else if(r == "smc" || r == "smc_required")
   {
      if(g_stamp_smc != g_lastBarTime){ g_blk_smc++; g_stamp_smc = g_lastBarTime; }
   }
   else if(r == "manual_approval")
   {
      if(g_stamp_approval != g_lastBarTime){ g_stamp_approval = g_lastBarTime; }
   }
   else if(r == "hybrid")
   {
      if(g_stamp_hyb != g_lastBarTime){ g_stamp_hyb = g_lastBarTime; }
   }
   else
   {
      if(g_stamp_none != g_lastBarTime){ g_stamp_none = g_lastBarTime; }
   }

   PrintFormat("%s reason=%s", AAI_BLOCK_LOG, reason);
}

//+------------------------------------------------------------------+
//| Pip Math Helpers                                                 |
//+------------------------------------------------------------------+
inline double PipSize()
{
   const int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   return (digits == 3 || digits == 5) ? 10 * _Point : _Point;
}

inline double PriceFromPips(double pips)
{
   return pips * PipSize();
}

//+------------------------------------------------------------------+
//| Simple string to ulong hash (for duplicate guard)                |
//+------------------------------------------------------------------+
ulong StringToULongHash(string s)
{
    ulong hash = 5381;
    int len = StringLen(s);
    for(int i = 0; i < len; i++)
    {
        hash = ((hash << 5) + hash) + (ulong)StringGetCharacter(s, i);
    }
    return hash;
}

//+------------------------------------------------------------------+
//| Calculate Lot Size                                               |
//+------------------------------------------------------------------+
double CalculateLotSize(int confidence, double sl_distance_price)
{
   if(sl_distance_price <= 0) return 0.0;
   double account_balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double risk_amount = account_balance * (RiskPct / 100.0);
   double tick_size = SymbolInfoDouble(symbolName, SYMBOL_TRADE_TICK_SIZE);
   double tick_value_loss = SymbolInfoDouble(symbolName, SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tick_size <= 0) return 0.0;
   double loss_per_lot = (sl_distance_price / tick_size) * tick_value_loss;
   if(loss_per_lot <= 0) return 0.0;
   double base_lot_size = risk_amount / loss_per_lot;
   // Confidence scaling (0-100 scale)
   double scale_min = 0.5;
   double scale_max = 1.0;
   double conf_range = 100.0 - MinConfidence;
   double conf_step = confidence - MinConfidence;
   double scaling_factor = scale_min;
   if(conf_range > 0)
     {
      scaling_factor = scale_min + ((scale_max - scale_min) * (conf_step / conf_range));
     }
   scaling_factor = fmax(scale_min, fmin(scale_max, scaling_factor));
   double final_lot_size = base_lot_size * scaling_factor;
   double lot_step = SymbolInfoDouble(symbolName, SYMBOL_VOLUME_STEP);
   final_lot_size = round(final_lot_size / lot_step) * lot_step;
   final_lot_size = fmax(MinLotSize, fmin(MaxLotSize, final_lot_size));
   return final_lot_size;
}

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   g_entries = 0;
   g_wins = 0;
   g_losses = 0;
   g_blk_ze = 0;
   g_blk_bc = 0;
   g_blk_smc = 0;
   g_blk_over = 0;
   g_blk_spread = 0;
   g_summary_printed = false;

// --- Initialize locals/state ---
symbolName = _Symbol;
point      = SymbolInfoDouble(symbolName, SYMBOL_POINT);
trade.SetExpertMagicNumber(MagicNumber);
g_overext_wait = 0;
g_last_entry_bar_buy  = 0;
g_last_entry_bar_sell = 0;
g_cool_until_buy  = 0;
g_cool_until_sell = 0;


// --- TICKET #2: Create the single, centralized SignalBrain handle ---
sb_handle = iCustom(_Symbol, (ENUM_TIMEFRAMES)SignalTimeframe, AAI_Ind("AAI_Indicator_SignalBrain"),
                    // Core SB Settings
                    SB_SafeTest, SB_UseZE, SB_UseBC, SB_UseSMC, SB_WarmupBars, SB_FastMA, SB_SlowMA,
                    SB_MinZoneStrength, SB_EnableDebug,
                    // SB Confidence Model
                    SB_Bonus_ZE, SB_Bonus_BC, SB_Bonus_SMC,
                    // BC Pass-Through
                    SB_BC_FastMA, SB_BC_SlowMA,
                    // ZE Pass-Through
                    SB_ZE_MinImpulseMovePips,
                    // SMC Pass-Through
                    SB_SMC_UseFVG, SB_SMC_UseOB, SB_SMC_UseBOS, SB_SMC_FVG_MinPips,
                    SB_SMC_OB_Lookback, SB_SMC_BOS_Lookback
                   );
                   
if(sb_handle == INVALID_HANDLE)
{
   PrintFormat("%s handle(SB) invalid", INIT_ERROR);
   return(INIT_FAILED);
}

               
   // --- T011: Update handles for Over-extension ---
   g_hATR = iATR(_Symbol, (ENUM_TIMEFRAMES)SignalTimeframe, OverExt_ATR_Period);
   if(g_hATR == INVALID_HANDLE){ PrintFormat("%s Failed to create ATR indicator handle", INIT_ERROR); return(INIT_FAILED); }

   g_hOverextMA = iMA(_Symbol, (ENUM_TIMEFRAMES)SignalTimeframe, OverExt_MA_Period, 0, MODE_EMA, PRICE_CLOSE);
   if(g_hOverextMA == INVALID_HANDLE){ PrintFormat("%s Failed to create Overextension MA handle", INIT_ERROR); return(INIT_FAILED); }
   
   if(Hybrid_RequireApproval)
   {
      FolderCreate(g_dir_base);
      FolderCreate(g_dir_intent);
      FolderCreate(g_dir_cmds);
      Print("[HYBRID] Approval mode active. Timer set to 2 seconds.");
      EventSetTimer(2);
   }

   AAI_ParseHourRanges(AutoHourRanges, g_auto_hour_mask);
   if(EnableLogging){
      string hrs="";
      int cnt=0;
      for(int h=0;h<24;++h){ if(g_auto_hour_mask[h]){ ++cnt; hrs += IntegerToString(h) + " "; } }
      PrintFormat("[HYBRID_INIT] AutoHourRanges='%s' hours_on=%d [%s]", AutoHourRanges, cnt, hrs);
   }

   // --- T006: Create HUD Object ---
   ObjectCreate(0, HUD_OBJECT_NAME, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, HUD_OBJECT_NAME, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, HUD_OBJECT_NAME, OBJPROP_XDISTANCE, 10);
   ObjectSetInteger(0, HUD_OBJECT_NAME, OBJPROP_YDISTANCE, 20);
   ObjectSetString(0, HUD_OBJECT_NAME, OBJPROP_FONT, "Arial");
   ObjectSetInteger(0, HUD_OBJECT_NAME, OBJPROP_FONTSIZE, 10);
   ObjectSetInteger(0, HUD_OBJECT_NAME, OBJPROP_COLOR, clrSilver);
   ObjectSetString(0, HUD_OBJECT_NAME, OBJPROP_TEXT, "HUD: Initializing...");

   return(INIT_SUCCEEDED);
}


void OnTesterDeinit() { PrintSummary(); }

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   
   // --- AAI END-OF-TEST SUMMARY (Journal) ---
   double PF = (AAI_gross_loss > 0.0 ? (AAI_gross_profit / AAI_gross_loss) : (AAI_gross_profit > 0.0 ? DBL_MAX : 0.0));
   double WR = (AAI_trades > 0 ? 100.0 * (double)AAI_wins / (double)AAI_trades : 0.0);
   double avg_win  = (AAI_win_count  > 0 ? AAI_sum_win      / (double)AAI_win_count  : 0.0);
   double avg_loss = (AAI_loss_count > 0 ? AAI_sum_loss_abs / (double)AAI_loss_count : 0.0);
   double avg_dur_sec = (AAI_dur_count > 0 ? AAI_dur_sum_sec / (double)AAI_dur_count : 0.0);
   // Format duration as H:MM:SS
   int    h = (int)(avg_dur_sec / 3600.0);
   int    m = (int)((avg_dur_sec - h*3600) / 60.0);
   int    s = (int)(avg_dur_sec - h*3600 - m*60);
   PrintFormat("AAI_METRICS|trades=%d|wins=%d|losses=%d|pf=%.2f|winrate=%.1f%%|avg_win=%.2f|avg_loss=%.2f|maxDD=%.2f|avg_dur=%02d:%02d:%02d",
               AAI_trades, AAI_wins, AAI_losses, PF, WR, avg_win, avg_loss, AAI_max_dd, h, m, s);
   if(Hybrid_RequireApproval)
      EventKillTimer();
   PrintFormat("%s Deinitialized. Reason=%d", EVT_INIT, reason);
   PrintSummary();
   
   // TICKET #2: Release simplified handles
   if(sb_handle != INVALID_HANDLE) IndicatorRelease(sb_handle);
   if(g_hATR != INVALID_HANDLE) IndicatorRelease(g_hATR);
   if(g_hOverextMA != INVALID_HANDLE) IndicatorRelease(g_hOverextMA);

   // --- T006: Clean up HUD Object ---
   ObjectDelete(0, HUD_OBJECT_NAME);
}


//+------------------------------------------------------------------+
//| HYBRID: Emit trade intent to file                                |
//+------------------------------------------------------------------+
bool EmitIntent(const string side, double entry, double sl, double tp, double volume,
                double rr_target, double conf_raw, double conf_eff, double ze_strength)
{
  g_pending_id = StringFormat("%s_%s_%I64d", _Symbol, EnumToString(_Period), (long)TimeCurrent());
  g_pending_ts = TimeCurrent();

  string fn_rel = g_dir_intent + "\\intent_" + g_pending_id + ".json";
  string json = StringFormat(
    "{\"id\":\"%s\",\"symbol\":\"%s\",\"timeframe\":\"%s\",\"side\":\"%s\","
    "\"entry\":%.5f,\"sl\":%.5f,\"tp\":%.5f,\"volume\":%.2f,"
    "\"rr_target\":%.2f,\"conf_raw\":%.2f,\"conf_eff\":%.2f,\"ze_strength\":%.2f,"
    "\"created_ts\":\"%s\"}",
    g_pending_id, _Symbol, EnumToString(_Period), side,
    entry, sl, tp, volume, rr_target, conf_raw, conf_eff, ze_strength,
    TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES)
  );
  if(WriteText(fn_rel, json))
  {
    string root = TerminalInfoString(TERMINAL_DATA_PATH) + "\\MQL5\\Files\\";
    PrintFormat("[HYBRID] intent written at: %s%s", root, fn_rel);
    string cmd_rel = g_dir_cmds + "\\cmd_" + g_pending_id + ".json";
    PrintFormat("[HYBRID] waiting for cmd at: %s%s", root, cmd_rel);
    return true;
  }
  return false;
}

//+------------------------------------------------------------------+
//| HYBRID: Execute order after approval                             |
//+------------------------------------------------------------------+
void PlaceOrderFromApproval()
{
    PrintFormat("[HYBRID] Executing approved trade. Side: %s, Vol: %.2f, Entry: Market, SL: %.5f, TP: %.5f",
                g_last_side, g_last_vol, g_last_sl, g_last_tp);
    trade.SetDeviationInPoints(MaxSlippagePoints);
    bool order_sent = false;

    if(g_last_side == "BUY")
    {
        order_sent = trade.Buy(g_last_vol, symbolName, 0, g_last_sl, g_last_tp, g_last_comment);
    }
    else if(g_last_side == "SELL")
    {
        order_sent = trade.Sell(g_last_vol, symbolName, 0, g_last_sl, g_last_tp, g_last_comment);
    }

if(order_sent && (trade.ResultRetcode() == TRADE_RETCODE_DONE || trade.ResultRetcode() == TRADE_RETCODE_DONE_PARTIAL))
{
    g_entries++;

    double rvol   = trade.ResultVolume();
    double rprice = trade.ResultPrice();

    PrintFormat("%s HYBRID Signal:%s → Executed %.2f lots @%.5f | SL:%.5f TP:%.5f",
                EVT_ENTRY, g_last_side,
                (rvol > 0 ? rvol : g_last_vol),
                (rprice > 0 ? rprice : 0.0),
                g_last_sl, g_last_tp);
    // >>> EXEC line to Journal (tester shows it)
    double exec_lots = (rvol > 0.0 ? rvol : g_last_vol);
    AAI_LogExec(g_last_side == "BUY" ? +1 : -1, exec_lots);  // optional 3rd arg: "Flow+"

    // Keep these after the log
    if(g_last_side == "BUY") g_last_entry_bar_buy = g_lastBarTime;
    else                     g_last_entry_bar_sell = g_lastBarTime;
}

    else
    {
        if(g_lastBarTime != g_last_suppress_log_time)
        {
            PrintFormat("%s reason=trade_send_failed details=retcode:%d", EVT_SUPPRESS, trade.ResultRetcode());
            g_last_suppress_log_time = g_lastBarTime;
        }
    }
}



//+------------------------------------------------------------------+
//| Timer function for HYBRID polling                                |
//+------------------------------------------------------------------+
void OnTimer()
{
  if(!Hybrid_RequireApproval || g_pending_id=="") return;

  if((TimeCurrent() - g_pending_ts) > Hybrid_TimeoutSec){
    Print("[HYBRID] intent timeout, discarding: ", g_pending_id);
    g_pending_id = "";
    return;
  }

  string cmd_rel = g_dir_cmds + "\\cmd_" + g_pending_id + ".json";
  static string last_id_printed = "";
  if(last_id_printed != g_pending_id){
    string root = TerminalInfoString(TERMINAL_DATA_PATH) + "\\MQL5\\Files\\";
    PrintFormat("[HYBRID] polling cmd: %s%s", root, cmd_rel);
    last_id_printed = g_pending_id;
  }

  if(!FileIsExist(cmd_rel)) return;

  string s = ReadAll(cmd_rel);
  if(s==""){ FileDelete(cmd_rel); return; }

  string id     = JsonGetStr(s, "id");
  string action = JsonGetStr(s, "action"); 
  StringToLower(action);
  if(id != g_pending_id) return;

  if(action=="approve"){
    Print("[HYBRID] APPROVED: ", id);
    PlaceOrderFromApproval();
  } else {
    Print("[HYBRID] REJECTED: ", id);
  }

  FileDelete(cmd_rel);
  g_pending_id = "";
}


//+------------------------------------------------------------------+
//| Trade Transaction Event Handler                                  |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
{
   
   // --- AAI METRICS + EXEC JOURNAL ---
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD && HistoryDealSelect(trans.deal))
   {
      // EXEC on entry (print once)
      if(HistoryDealGetInteger(trans.deal, DEAL_ENTRY) == DEAL_ENTRY_IN)
      {
         if(AAI_last_in_deal != trans.deal)
         {
            AAI_last_in_deal = trans.deal;
            int  dtyp = (int)HistoryDealGetInteger(trans.deal, DEAL_TYPE);
            int  dir  = (dtyp == DEAL_TYPE_BUY ? +1 : -1);
            double lots = HistoryDealGetDouble(trans.deal, DEAL_VOLUME);
            AAI_LogExec(dir, lots, "tx");

            // Remember last IN time (for duration calc)
            AAI_last_in_pos_id = (long)HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID);
            AAI_last_in_time   = (datetime)HistoryDealGetInteger(trans.deal, DEAL_TIME);
         }
      }
      // Metrics on exits (DEAL_ENTRY_OUT): accumulate closed-trade stats
      else if(HistoryDealGetInteger(trans.deal, DEAL_ENTRY) == DEAL_ENTRY_OUT)
      {
         if(AAI_last_out_deal != trans.deal)
         {
            AAI_last_out_deal = trans.deal;
            double net = AAI_NetDealPL(trans.deal);
            AAI_trades++;
            if(net > 0.0) { AAI_wins++; AAI_win_count++; AAI_gross_profit += net; AAI_sum_win += net; }
            else if(net < 0.0) { AAI_losses++; AAI_loss_count++;
            AAI_gross_loss += -net; AAI_sum_loss_abs += -net; }

            // Closed-trade curve & drawdown
            AAI_UpdateCurve(net);
            // Duration estimate (seconds) using last known IN time
            datetime out_time = (datetime)HistoryDealGetInteger(trans.deal, DEAL_TIME);
            if(AAI_last_in_time > 0 && out_time >= AAI_last_in_time)
            {
                AAI_dur_sum_sec += (double)(out_time - AAI_last_in_time);
                AAI_dur_count++;
            }

            // Optional: duration estimate using last IN time if position ids align
            long pos_id = (long)HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID);
            // We keep a simple heuristic: if position id changed since last IN, we try to back-scan one IN for same pos_id
            if(pos_id != AAI_last_in_pos_id)
            {
               // best-effort backscan for nearest IN of same position
               int total = HistoryDealsTotal();
               datetime nearest_in = 0;
               for(int i = total-1; i >= 0 && i >= total-200; --i) // scan recent deals window
               {
                  ulong tk = (ulong)HistoryDealGetTicket(i);
                  if(HistoryDealGetInteger(tk, DEAL_POSITION_ID) == pos_id &&
                     HistoryDealGetInteger(tk, DEAL_ENTRY) == DEAL_ENTRY_IN)
                  {
                     nearest_in = (datetime)HistoryDealGetInteger(tk, DEAL_TIME);
                     break;
                  }
               }
               if(nearest_in > 0) AAI_last_in_time = nearest_in;
            }
         }
      }
   }
if(trans.type == TRADE_TRANSACTION_DEAL_ADD && HistoryDealSelect(trans.deal))
   {
      if((ulong)HistoryDealGetInteger(trans.deal, DEAL_MAGIC) == MagicNumber && HistoryDealGetInteger(trans.deal, DEAL_ENTRY) == DEAL_ENTRY_OUT)
      {
         double profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT);
         if(profit > 0) g_wins++;
         else if(profit < 0) g_losses++;
      
         ulong pos_id = HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID);
         if(!PositionSelectByTicket(pos_id) && !IsPositionLogged(pos_id))
         {
            JournalClosedPosition(pos_id);
            AddToLoggedList(pos_id);
         }
      }
   }

   if (CooldownAfterSLBars > 0 && trans.type == TRADE_TRANSACTION_DEAL_ADD && HistoryDealSelect(trans.deal))
   {
       if ((ulong)HistoryDealGetInteger(trans.deal, DEAL_MAGIC) == MagicNumber &&
           HistoryDealGetInteger(trans.deal, DEAL_ENTRY) == DEAL_ENTRY_OUT &&
           HistoryDealGetInteger(trans.deal, DEAL_REASON) == DEAL_REASON_SL)
       {
           long closing_deal_type = HistoryDealGetInteger(trans.deal, DEAL_TYPE);
           datetime bar_time = iTime(_Symbol, (ENUM_TIMEFRAMES)SignalTimeframe, 0); // TICKET #3 Fix: Use SignalTimeframe
           datetime cooldown_end_time = bar_time + CooldownAfterSLBars * PeriodSeconds((ENUM_TIMEFRAMES)SignalTimeframe); // TICKET #3 Fix: Use SignalTimeframe
           if (closing_deal_type == DEAL_TYPE_SELL)
           {
               g_cool_until_buy = cooldown_end_time;
               PrintFormat("%s SL close side=BUY pause=%d bars until %s", EVT_COOLDOWN, CooldownAfterSLBars, TimeToString(g_cool_until_buy));
           }
           else if (closing_deal_type == DEAL_TYPE_BUY)
           {
               g_cool_until_sell = cooldown_end_time;
               PrintFormat("%s SL close side=SELL pause=%d bars until %s", EVT_COOLDOWN, CooldownAfterSLBars, TimeToString(g_cool_until_sell));
           }
       }
   }
}

//+------------------------------------------------------------------+
//| OnTick: Event-driven logic                                       |
//+------------------------------------------------------------------+
void OnTick()
{
   g_tickCount++;
   
   if(PositionSelect(_Symbol))
   {
      MqlDateTime dt;
      TimeToStruct(TimeCurrent(), dt);
      ManageOpenPositions(dt, false);
   }

datetime bar_time = iTime(_Symbol, (ENUM_TIMEFRAMES)SignalTimeframe, 0);
if(bar_time == 0 || bar_time == g_lastBarTime) return;
g_lastBarTime = bar_time;

   CheckForNewTrades();
}


//+------------------------------------------------------------------+
//| Check & execute new entries                                      |
//+------------------------------------------------------------------+
void CheckForNewTrades()
{
   // --- EA Warmup Gate (T003) ---
   long bars_avail = Bars(_Symbol, (ENUM_TIMEFRAMES)SignalTimeframe);
   if (bars_avail < WarmupBars)
   {
datetime barTime = iTime(_Symbol, (ENUM_TIMEFRAMES)SignalTimeframe, 0);
       if (g_last_ea_warmup_log_time != barTime)
       {
           PrintFormat("[WARMUP] t=%s sb_handle_ok=%d need=%d have=%d",
                       TimeToString(barTime), (sb_handle != INVALID_HANDLE), WarmupBars, (int)bars_avail);
           g_last_ea_warmup_log_time = barTime;
       }
       return;
   }
   
   // --- T010: Spread Gate ---
   int currentSpread = CurrentSpreadPoints();
   if (currentSpread > MaxSpreadPoints)
   {
       datetime barTime = iTime(_Symbol, (ENUM_TIMEFRAMES)SignalTimeframe, 1);
       static datetime last_spread_log_time = 0;
       if (barTime != last_spread_log_time)
       {
           PrintFormat("[SPREAD_BLK] t=%s spread=%d max=%d", TimeToString(barTime), currentSpread, MaxSpreadPoints);
           last_spread_log_time = barTime;
       }
       AAI_Block("spread");
       return;
   }
   
   const int readShift = MathMax(1, SB_ReadShift);
   
   // --- TICKET #2: Read all data from SignalBrain in one go ---
   double dSig=0,dConf=0,dReason=0,dZE=0,dSMC_S=0,dSMC_C=0,dBC=0;
   bool ok=true;
   ok&=Read1(sb_handle,SB_BUF_SIGNAL,  readShift,dSig,   "SB");
   ok&=Read1(sb_handle,SB_BUF_CONF,    readShift,dConf,  "SB");
   ok&=Read1(sb_handle,SB_BUF_REASON,  readShift,dReason,"SB");
   ok&=Read1(sb_handle,SB_BUF_ZE,      readShift,dZE,    "SB");
   ok&=Read1(sb_handle,SB_BUF_SMC_SIG, readShift,dSMC_S, "SB");
   ok&=Read1(sb_handle,SB_BUF_SMC_CONF,readShift,dSMC_C, "SB");
   ok&=Read1(sb_handle,SB_BUF_BC,      readShift,dBC,    "SB");
   if(!ok) return; // closed-bar discipline
   
   int    direction    =(int)MathRound(dSig);
   int    reason       =(int)MathRound(dReason);
   int    smc_sig      =(int)MathRound(dSMC_S);
   int    bc_bias      =(int)MathRound(dBC);
   double final_conf   = dConf;
   double ze_strength  = dZE;
   double smc_conf     = dSMC_C;

   // --- Update Visuals and Journaling with the new data ---
   LogPerBarStatus(direction, final_conf, reason, ze_strength, bc_bias);
   UpdateHUD(direction, final_conf, reason, ze_strength, bc_bias);

   // --- Signal Gate ---
   if(direction == 0) return;

   // --- Session Gate (Server Time) ---
   bool sess_ok = true;
   if(SessionEnable)
   {
      MqlDateTime dt;
      TimeToStruct(TimeTradeServer(), dt);
      const int hh = dt.hour;
      if(SessionStartHourServer == SessionEndHourServer) sess_ok = true;
      else sess_ok = (SessionStartHourServer <= SessionEndHourServer)
                 ? (hh >= SessionStartHourServer && hh < SessionEndHourServer)
                 : (hh >= SessionStartHourServer || hh < SessionEndHourServer);
   }
   if(!sess_ok) { AAI_Block("session"); return; }
   
   datetime signal_bar_time = iTime(_Symbol, (ENUM_TIMEFRAMES)SignalTimeframe, readShift);
   
   // --- T011 & TICKET #3: Over-extension Gate ---
   static datetime last_overext_log_time = 0;
   double mid = 0, atr = 0, px = 0;
double _tmp_ma_[1];
if (CopyBuffer(g_hOverextMA, 0, 1, 1, _tmp_ma_) == 1)  mid = _tmp_ma_[0]; else mid = 0.0;

double _tmp_atr_[1];
if (CopyBuffer(g_hATR, 0, 1, 1, _tmp_atr_) == 1)       atr = _tmp_atr_[0]; else atr = 0.0;

   px = iClose(_Symbol, (ENUM_TIMEFRAMES)SignalTimeframe, 1);
   
   if(mid > 0 && atr > 0 && px > 0)
   {
      double up = mid + OverExt_ATR_Mult * atr;
      double dn = mid - OverExt_ATR_Mult * atr;
      bool is_over_long = (direction > 0 && px > up);
      bool is_over_short = (direction < 0 && px < dn);
      if(OverExtMode == HardBlock)
      {
         if(is_over_long || is_over_short)
         {
            if(signal_bar_time != last_overext_log_time)
            {
               PrintFormat("[OVEREXT_BLK] t=%s dir=%d px=%.5f up=%.5f dn=%.5f", TimeToString(signal_bar_time), direction, px, up, dn);
               last_overext_log_time = signal_bar_time;
            }
            AAI_Block("overext");
            return;
         }
      }
      else // WaitForBand
      {
         if(is_over_long || is_over_short)
         {
            g_overext_wait = OverExt_WaitBars;
         }
         
         if(g_overext_wait > 0)
         {
            if(px >= dn && px <= up) // Price re-entered the band
            {
               g_overext_wait = 0;
            }
            else
            {
               // TICKET #3 FIX: Decrement only once per new signal bar
               if(signal_bar_time != g_last_overext_dec_sigbar)
               {
                  g_overext_wait--;
                  g_last_overext_dec_sigbar = signal_bar_time;
               }
               
               if(signal_bar_time != last_overext_log_time)
               {
                  PrintFormat("[OVEREXT_WAIT] t=%s left=%d dir=%d", TimeToString(signal_bar_time), g_overext_wait, direction);
                  last_overext_log_time = signal_bar_time;
               }
               AAI_Block("overext");
               return;
            }
         }
      }
   }

    // --- TICKET #2: Adapted Gating Logic ---
    // ZE Gate
    if(ZE_Gate == ZE_REQUIRED && ze_strength < ZE_MinStrength)
    {
        AAI_Block("ZE_REQUIRED");
        return;
    }

    // SMC Gate
    if(SMC_Mode == SMC_REQUIRED)
    {
        if(smc_sig != direction || smc_conf < SMC_MinConfidence)
        {
            AAI_Block("SMC_REQUIRED");
            return;
        }
    }
    
    // BC Gate
    if(BC_AlignMode == BC_REQUIRED)
    {
        if(bc_bias != direction)
        {
            AAI_Block("BC_REQUIRED");
            return;
        }
    }

   // --- Final Confidence Gate (uses confidence directly from SignalBrain) ---
   if(final_conf < MinConfidence) { AAI_Block("confidence"); return; }
   
   // --- TICKET #3 FIX: Cooldown Gate ---
   int secs = PeriodSeconds((ENUM_TIMEFRAMES)SignalTimeframe);
   datetime until = (direction > 0) ? g_cool_until_buy : g_cool_until_sell;
   int delta = (int)(until - signal_bar_time);
   int bars_left = (delta <= 0 || secs <= 0) ? 0 : ( (delta + secs - 1) / secs );
   if(bars_left > 0) { AAI_Block("cooldown"); return; }
   
   // --- TICKET #3 FIX: Per-Bar Debounce Gate ---
   if(PerBarDebounce && ((direction > 0) ? (g_last_entry_bar_buy == signal_bar_time) : (g_last_entry_bar_sell == signal_bar_time)))
   {
      AAI_Block("same_bar");
      return;
   }

   // --- Trigger Gate ---
   string trigger = "";
   double sbSig_prev=0;
   // We need to read the previous bar's signal from SB to detect an edge
   Read1(sb_handle, SB_BUF_SIGNAL, readShift + 1, sbSig_prev, "SB_Prev");

   bool is_edge = (direction != (int)sbSig_prev);
   if(EntryMode == FirstBarOrEdge && !g_bootstrap_done) trigger = "bootstrap";
   else if(is_edge) trigger = "edge";
   if(trigger == "") { AAI_Block("no_trigger"); return; }
   
   // --- Position Gate ---
   if(PositionSelect(_Symbol)) return;
   
   // --- All Gates Passed ---
   if(TryOpenPosition(direction, 0, final_conf, reason, ze_strength, smc_conf))
   {
      if(trigger == "bootstrap") g_bootstrap_done = true;
   }
}

//+------------------------------------------------------------------+
//| Helper function to get the string representation of a reason code|
//+------------------------------------------------------------------+
string ReasonCodeToString(int code)
{
    switch((ENUM_REASON_CODE)code)
    {
        case REASON_BUY_HTF_CONTINUATION:   return "Trend Continuation (Buy)";
        case REASON_SELL_HTF_CONTINUATION:  return "Trend Continuation (Sell)";
        case REASON_BUY_LIQ_GRAB_ALIGNED:   return "Liquidity Grab (Buy)";
        case REASON_SELL_LIQ_GRAB_ALIGNED:  return "Liquidity Grab (Sell)";
        case REASON_TEST_SCENARIO:          return "Test Scenario";
        default:                            return "Signal";
    }
}

//+------------------------------------------------------------------+
//| Sends a formatted alert to Telegram for an approval candidate    |
//+------------------------------------------------------------------+
void SendTelegramAlert(const string side, const double conf_eff, const double ze_strength,
                       const double entry, const double sl, const double tp, const double rr,
                       const int reason_code)
{
    if(!UseTelegramFromEA) return;
    string reason_text = ReasonCodeToString(reason_code);
    int sl_pips = (int)MathRound(MathAbs(entry - sl) / PipSize());
    int tp_pips = (tp > 0) ? (int)MathRound(MathAbs(entry - tp) / PipSize()) : 0;
    
    // Read HTF Bias directly from SignalBrain's output for the message
    double htf_bias_val = 0;
    Read1(sb_handle, SB_BUF_BC, MathMax(1, SB_ReadShift), htf_bias_val, "SB_BC_Alert");
    int htf_bias = (int)MathRound(htf_bias_val);


    string msg_p1 = StringFormat("[Alfred_AI] %s %s • %s • conf %d • ZE %.1f • bias %d",
                                 _Symbol, EnumToString(_Period), side, (int)conf_eff,
                                 ze_strength, htf_bias);
    string msg_p2 = StringFormat("Entry %.5f | SL %.5f (%dp) | TP %.5f (%dp) | R %.2f",
                                 entry, sl, sl_pips, tp, tp_pips, rr);
    string msg_p3 = StringFormat("Reason: %s (%d)", reason_text, reason_code);

    string full_message = msg_p1 + "\n" + msg_p2 + "\n" + msg_p3;
    if(AlertsDryRun || StringLen(TelegramToken) == 0 || StringLen(TelegramChatID) == 0)
    {
        Print(full_message);
        return;
    }

    // --- Send WebRequest ---
    string url_message = full_message;
    StringReplace(url_message, " ", "%20");
    StringReplace(url_message, "\n", "%0A");
    string url = "https://api.telegram.org/bot" + TelegramToken +
                 "/sendMessage?chat_id=" + TelegramChatID +
                 "&text=" + url_message;
    char post_data[];
    char result_data[];
    int res;
    string headers;
    ResetLastError();
    res = WebRequest("GET", url, NULL, NULL, 5000, post_data, 0, result_data, headers);
    if(res == 200)
    {
        Print(EVT_TG_OK);
    }
    else
    {
        PrintFormat("%s code=%d", EVT_TG_FAIL, res);
    }
}


//+------------------------------------------------------------------+
//| Attempts to open a trade and returns true on success             |
//+------------------------------------------------------------------+
bool TryOpenPosition(int signal, double conf_raw_unused, double conf_eff, int reason_code, double ze_strength, double smc_score)
{
   MqlTick t;
   if(!SymbolInfoTick(_Symbol, t) || t.time_msc == 0){ return false; }

   const int    digs = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   const double pip_size = PipSize();
const double min_stop_dist = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   
   double atr_val_raw = 0;
double _tmp_atr_entry_[1];
if (CopyBuffer(g_hATR, 0, 1, 1, _tmp_atr_entry_) == 1) atr_val_raw = _tmp_atr_entry_[0]; else atr_val_raw = 0.0;
   const double sl_dist = atr_val_raw + (SL_Buffer_Points * _Point);

   double entry = (signal > 0) ? t.ask : t.bid;
   double sl = 0, tp = 0;
   double rr = 0.0;
// Clamp SL distance
if(signal > 0){ // buy
   if((entry - sl) < min_stop_dist) sl = NormalizeDouble(entry - min_stop_dist, digs);
   if(tp > 0 && (tp - entry) < min_stop_dist) tp = NormalizeDouble(entry + min_stop_dist, digs);
}else if(signal < 0){ // sell
   if((sl - entry) < min_stop_dist) sl = NormalizeDouble(entry + min_stop_dist, digs);
   if(tp > 0 && (entry - tp) < min_stop_dist) tp = NormalizeDouble(entry - min_stop_dist, digs);
}
   
   // --- Duplicate Guard (MS) ---
   ulong now_ms = GetTickCount64();
   datetime current_bar_time = iTime(_Symbol, (ENUM_TIMEFRAMES)SignalTimeframe, 1); // TICKET #3 FIX
   string hash_str = StringFormat("%I64d|%d|%.*f", (long)current_bar_time, signal, digs, entry);
   ulong sig_h = StringToULongHash(hash_str);
   if(DuplicateGuardMs > 0 && g_last_send_sig_hash == sig_h && (now_ms - g_last_send_ms) < DuplicateGuardMs)
   { return false; }

   // --- Stop Level Validation ---
   bool ok_side = (signal > 0) ? (sl < entry) : (entry < sl);
   if (tp != 0) ok_side &= (signal > 0) ? (entry < tp) : (tp < entry);
   bool ok_dist = (MathAbs(entry - sl) >= min_stop_dist);
   if(tp != 0) ok_dist &= (MathAbs(tp - entry) >= min_stop_dist);
   if(!ok_side || !ok_dist){ return false; }

   double lots_to_trade = CalculateLotSize((int)conf_eff, MathAbs(entry - sl));
   if(lots_to_trade < MinLotSize) return false;
   
   string signal_str = (signal == 1) ? "BUY" : "SELL";
   string comment = StringFormat("AAI|%.1f|%d|%d|%.1f|%.5f|%.5f|%.1f",
                                 conf_eff, (int)conf_eff, reason_code, ze_strength, sl, tp, smc_score);
   // --- Log Trade Idea ---
   PrintFormat("%s dir=%s entry=%.5f sl=%.5f tp=%.5f R=%.2f conf=%.0f ze=%.1f", 
      EVT_IDEA, signal_str, entry, sl, tp, rr, conf_eff, ze_strength);
      
   // --- T007: Manual Approval Gate ---
   if(ExecutionMode == AutoExecute && ApprovalMode == Manual)
   {
       datetime barTime = iTime(_Symbol, (ENUM_TIMEFRAMES)SignalTimeframe, 1);
       string gv_key = StringFormat("AAI_APPROVE_%s_%d_%I64d", _Symbol, (int)SignalTimeframe, (long)barTime);
       
       double approval_value = GlobalVariableGet(gv_key);
       if(approval_value != 1.0)
       {
           static datetime last_approval_wait_log = 0;
           if(barTime != last_approval_wait_log)
           {
               PrintFormat("[WAIT_APPROVAL] key=%s", gv_key);
               last_approval_wait_log = barTime;
           }
           AAI_Block("manual_approval");
           return false;
       }
       g_entries++;
       GlobalVariableSet(gv_key, 0.0);
       PrintFormat("[CONSUMED_APPROVAL] %s reset to 0.0", gv_key);
   }

   // --- HYBRID HOURS SWITCH ---
   if(!AAI_HourDayAutoOK())
   {
      // Get SMC conf from SB data for the alert
      double smc_conf_val = 0;
      Read1(sb_handle, SB_BUF_SMC_CONF, MathMax(1, SB_ReadShift), smc_conf_val, "SB_SMC_Alert");

      int spread_pts = CurrentSpreadPoints();
      double atr_pips = atr_val_raw / pip_size;
      AAI_RaiseHybridAlert(signal_str, conf_eff, ze_strength, smc_conf_val, spread_pts, atr_pips, entry, sl, tp);
      AAI_Block("hybrid");
      return false;
   }
   
   if(ExecutionMode == AutoExecute){
      g_last_side      = signal_str;
      g_last_entry     = entry; g_last_sl = sl; g_last_tp = tp; g_last_vol = lots_to_trade;
      g_last_rr        = rr; g_last_conf_raw = conf_eff; g_last_conf_eff = conf_eff;
      g_last_ze        = ze_strength; g_last_comment = comment;
      
      if(Hybrid_RequireApproval)
      {
         if(g_lastBarTime != g_last_telegram_alert_bar)
         {
            SendTelegramAlert(signal_str, conf_eff, ze_strength, entry, sl, tp, rr, reason_code);
            g_last_telegram_alert_bar = g_lastBarTime;
         }
         
         if(EmitIntent(g_last_side, g_last_entry, g_last_sl, g_last_tp, g_last_vol, g_last_rr, conf_eff, conf_eff, g_last_ze)) 
            return false;
         else 
            return false;
      }
      
      g_last_send_sig_hash = sig_h;
      g_last_send_ms = now_ms;
      trade.SetDeviationInPoints(MaxSlippagePoints);
      bool order_sent = (signal > 0) ? trade.Buy(lots_to_trade, symbolName, 0, sl, tp, comment) : trade.Sell(lots_to_trade, symbolName, 0, sl, tp, comment);
      if(order_sent && (trade.ResultRetcode() == TRADE_RETCODE_DONE || trade.ResultRetcode() == TRADE_RETCODE_DONE_PARTIAL))
      {
         g_entries++;
         PrintFormat("%s Signal:%s → Executed %.2f lots @%.5f | SL:%.5f TP:%.5f",
                EVT_ENTRY, signal_str, trade.ResultVolume(), trade.ResultPrice(), sl, tp);
         double exec_lots = (trade.ResultVolume() > 0.0 ? trade.ResultVolume() : lots_to_trade);
         AAI_LogExec(signal > 0 ? +1 : -1, exec_lots);

         if(signal > 0) g_last_entry_bar_buy = current_bar_time;
         else           g_last_entry_bar_sell = current_bar_time;

         return true;
      }
      else
      {
         if(g_lastBarTime != g_last_suppress_log_time){
            PrintFormat("%s reason=trade_send_failed details=retcode:%d", EVT_SUPPRESS, trade.ResultRetcode());
            g_last_suppress_log_time = g_lastBarTime;
         }
         return false;
      }
   }
   return false;
}


//+------------------------------------------------------------------+
//| Manage open positions                                            |
//+------------------------------------------------------------------+
void ManageOpenPositions(const MqlDateTime &loc, bool overnight)
{
   if(!PositionSelect(_Symbol)) return;
   
   if(!Exit_FixedRR) { 
      HandlePartialProfits();
      if(!PositionSelect(_Symbol)) return;
   }
   
   ulong ticket = PositionGetInteger(POSITION_TICKET);
   if(loc.day_of_week==FRIDAY && loc.hour>=FridayCloseHour) { trade.PositionClose(ticket); return; }

   ENUM_POSITION_TYPE side = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double entry = PositionGetDouble(POSITION_PRICE_OPEN);
   double sl    = PositionGetDouble(POSITION_SL);
   double tp    = PositionGetDouble(POSITION_TP);

   if(AAI_ApplyBEAndTrail(side, entry, sl))
   {
      trade.PositionModify(_Symbol, sl, tp);
   }
}

//+------------------------------------------------------------------+
//| Helper to get pip size                                           |
//+------------------------------------------------------------------+
double AAI_Pip() { return (_Digits==3 || _Digits==5) ? 10*_Point : _Point; }

//+------------------------------------------------------------------+
//| Unified SL updater                                               |
//+------------------------------------------------------------------+
bool AAI_ApplyBEAndTrail(const ENUM_POSITION_TYPE side, const double entry_price, double &sl_io)
{
   if(Exit_FixedRR) return false;
   
   const double pip = AAI_Pip();
   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   const bool   is_long = (side==POSITION_TYPE_BUY);
   const double px     = is_long ? bid : ask;
   const double move_p = is_long ? (px - entry_price) : (entry_price - px);
   const double move_pips = move_p / pip;
   bool changed=false;
   
   double initial_risk_pips = 0;
   string comment = PositionGetString(POSITION_COMMENT);
   string parts[];
   if(StringSplit(comment, '|', parts) >= 8) { // Updated to handle new comment format
       double sl_price = StringToDouble(parts[5]);
       initial_risk_pips = MathAbs(entry_price - sl_price) / PipSize();
   }
   
   if(Partial_R_multiple > 0 && move_pips >= initial_risk_pips * Partial_R_multiple)
   {
      double be_target = entry_price + (is_long ? +1 : -1) * BE_Offset_Points * _Point;
      if( (is_long && (sl_io < be_target)) || (!is_long && (sl_io > be_target)) )
      {
         sl_io = be_target;
         changed = true;
      }
   }

   if(Trail_Start_Pips > 0 && move_pips >= Trail_Start_Pips && Trail_Stop_Pips > 0)
   {
      double trail_target = px - (is_long ? Trail_Stop_Pips : -Trail_Stop_Pips) * pip;
      if( (is_long && (trail_target > sl_io)) || (!is_long && (trail_target < sl_io)) )
      {
         sl_io = trail_target;
         changed = true;
      }
   }
   return changed;
}


//+------------------------------------------------------------------+
//| Handle Partial Profits                                           |
//+------------------------------------------------------------------+
void HandlePartialProfits()
{
   string comment = PositionGetString(POSITION_COMMENT);
   if(StringFind(comment, "|P1") != -1) return;

   string parts[];
   if(StringSplit(comment, '|', parts) < 8) return; // Updated for new comment format

   double sl_price = StringToDouble(parts[5]);
   double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
   if(sl_price == 0) return;
   
   double initial_risk_pips = MathAbs(open_price - sl_price) / PipSize();
   if(initial_risk_pips <= 0) return;
   long type = PositionGetInteger(POSITION_TYPE);
   double current_profit_pips = (type == POSITION_TYPE_BUY) ?
   (SymbolInfoDouble(symbolName, SYMBOL_BID) - open_price) / PipSize() : (open_price - SymbolInfoDouble(symbolName, SYMBOL_ASK)) / PipSize();
   if(current_profit_pips >= initial_risk_pips * Partial_R_multiple)
   {
      ulong ticket = PositionGetInteger(POSITION_TICKET);
      double volume = PositionGetDouble(POSITION_VOLUME);
      double close_volume = volume * (Partial_Pct / 100.0);
      double lot_step = SymbolInfoDouble(symbolName, SYMBOL_VOLUME_STEP);
      close_volume = round(close_volume / lot_step) * lot_step;
      if(close_volume < lot_step) return;
      if(trade.PositionClosePartial(ticket, close_volume))
      {
          double be_sl_price = open_price + ((type == POSITION_TYPE_BUY) ? BE_Offset_Points * _Point : -BE_Offset_Points * _Point);
          if(trade.PositionModify(ticket, be_sl_price, PositionGetDouble(POSITION_TP)))
          {
             MqlTradeRequest req;
             MqlTradeResult res; ZeroMemory(req);
             req.action = TRADE_ACTION_MODIFY; req.position = ticket;
             req.sl = be_sl_price; req.tp = PositionGetDouble(POSITION_TP);
             req.comment = comment + "|P1";
             if(!OrderSend(req, res)) PrintFormat("%s Failed to send position modify request. Error: %d", EVT_PARTIAL, GetLastError());
          }
      }
   }
}

//+------------------------------------------------------------------+
//| Journaling Functions                                             |
//+------------------------------------------------------------------+
void JournalClosedPosition(ulong position_id)
{
   if(!EnableJournaling || !HistorySelectByPosition(position_id)) return;

   // --- Variables to aggregate and find ---
   datetime time_close_server = 0;
   string   symbol = "";
   string   dir = "";
   double   entry_price = 0;
   double   sl_price_initial = 0;
   double   tp_price_initial = 0;
   double   exit_price = 0;
   double   total_profit = 0;
   double   conf_eff = 0;
   double   ze_strength = 0;
   double   smc_score = 0;
   int      reason_code = 0;
   string   comment_initial = "";
   ulong    magic = 0;
   
   ulong first_in_ticket = 0;
   ulong last_out_ticket = 0;

   // --- Find the first opening deal and last closing deal for the position ---
   for(int i=0; i < HistoryDealsTotal(); i++)
   {
      ulong deal_ticket = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(deal_ticket, DEAL_ENTRY) == DEAL_ENTRY_IN)
      {
         if(first_in_ticket == 0) first_in_ticket = deal_ticket;
      }
      else
      {
         last_out_ticket = deal_ticket;
         // This will be the last one at the end of the loop
      }
      total_profit += HistoryDealGetDouble(deal_ticket, DEAL_PROFIT) + HistoryDealGetDouble(deal_ticket, DEAL_COMMISSION) + HistoryDealGetDouble(deal_ticket, DEAL_SWAP);
   }

   if(first_in_ticket == 0) return; // No opening deal found, cannot journal

   // --- Populate data from the first opening deal ---
   symbol = HistoryDealGetString(first_in_ticket, DEAL_SYMBOL);
   dir = (HistoryDealGetInteger(first_in_ticket, DEAL_TYPE) == DEAL_TYPE_BUY) ? "BUY" : "SELL";
   entry_price = HistoryDealGetDouble(first_in_ticket, DEAL_PRICE);
   comment_initial = HistoryDealGetString(first_in_ticket, DEAL_COMMENT);
   magic = HistoryDealGetInteger(first_in_ticket, DEAL_MAGIC);
   
   // --- Parse the comment for original trade context ---
   string parts[];
   if(StringSplit(comment_initial, '|', parts) >= 8)
   {
       conf_eff    = StringToDouble(parts[2]);
       reason_code = (int)StringToInteger(parts[3]);
       ze_strength = StringToDouble(parts[4]);
       sl_price_initial = StringToDouble(parts[5]);
       tp_price_initial = StringToDouble(parts[6]);
       smc_score = StringToDouble(parts[7]);
   }

   // --- Populate data from the last closing deal ---
   if(last_out_ticket != 0)
   {
       exit_price = HistoryDealGetDouble(last_out_ticket, DEAL_PRICE);
       time_close_server = (datetime)HistoryDealGetInteger(last_out_ticket, DEAL_TIME);
   }

   // --- Calculate final fields ---
   double sl_pips = (sl_price_initial > 0) ? MathAbs(entry_price - sl_price_initial) / PipSize() : 0;
   double tp_pips = (tp_price_initial > 0) ? MathAbs(entry_price - tp_price_initial) / PipSize() : 0;
   double rr = (sl_pips > 0 && tp_pips > 0) ? tp_pips / sl_pips : 0;
   string reason_text = ReasonCodeToString(reason_code);
   
   // --- Write to file ---
   int file_handle = FileOpen(JournalFileName, FILE_READ|FILE_WRITE|FILE_CSV|(JournalUseCommonFiles ? FILE_COMMON : 0), ';');
   if(file_handle != INVALID_HANDLE)
   {
      if(FileSize(file_handle) == 0)
      {
         FileWriteString(file_handle, "TimeLocal;TimeServer;Symbol;TF;Dir;Entry;SL;TP;SL_pips;TP_pips;R;Confidence;ZE_Strength;SMC_Score;ReasonCode;ReasonText;Magic;Ticket;Comment\n");
      }
      FileSeek(file_handle, 0, SEEK_END);

      string line = StringFormat("%s;%s;%s;%s;%s;%.5f;%.5f;%.5f;%.1f;%.1f;%.2f;%.0f;%.0f;%.0f;%d;%s;%d;%I64u;%s\n",
                                 TimeToString(TimeLocal(), TIME_DATE|TIME_SECONDS),
                                 TimeToString(time_close_server, TIME_DATE|TIME_SECONDS),
                                 symbol,
                                 EnumToString(SignalTimeframe),
                                 dir,
                                 entry_price,
                                 sl_price_initial,
                                 tp_price_initial,
                                 sl_pips,
                                 tp_pips,
                                 rr,
                                 conf_eff,
                                 ze_strength,
                                 smc_score,
                                 reason_code,
                                 reason_text,
                                 (int)magic,
                                 position_id, // Using Position ID as the unique ticket/identifier for the trade
                                 comment_initial
                                );
      FileWriteString(file_handle, line);
      FileClose(file_handle);
   }
   else
   {
      PrintFormat("%s Failed to open journal file '%s'. Error: %d", EVT_JOURNAL, JournalFileName, GetLastError());
   }
}

bool IsPositionLogged(ulong position_id)
{
   for(int i=0; i<g_logged_positions_total; i++) if(g_logged_positions[i] == position_id) return true;
   return false;
}
void AddToLoggedList(ulong position_id)
{
   if(IsPositionLogged(position_id)) return;
   int new_size = g_logged_positions_total + 1;
   ArrayResize(g_logged_positions, new_size);
   g_logged_positions[new_size - 1] = position_id;
   g_logged_positions_total = new_size;
}
//+------------------------------------------------------------------+
