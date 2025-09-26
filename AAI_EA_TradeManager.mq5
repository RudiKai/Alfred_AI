// ====================== AAI METRICS (PF/WR/Avg/MaxDD/AvgDur) ======================
#ifndef AAI_METRICS_DEFINED
#define AAI_METRICS_DEFINED
#ifndef AAI_RTP_DEFINED
#define AAI_RTP_DEFINED
// --- T046: Runtime Profiles -----------------------------------------------
const int RTP_Profile = 0;          // 0=Prod, 1=Diagnostics, 2=Research
#define RTP_IS_DIAG      (RTP_Profile==1)
#define RTP_IS_RESEARCH  (RTP_Profile==2)
// --------------------------------------------------------------------------
#endif

int      AAI_trades = 0;
int      AAI_wins = 0, AAI_losses = 0;
double   AAI_gross_profit = 0.0;
// sum of positive net P&L
double   AAI_gross_loss   = 0.0;
// sum of negative net P&L (stored as positive abs)
double   AAI_sum_win      = 0.0;
// for avg win
double   AAI_sum_loss_abs = 0.0;         // for avg loss (abs)
int      AAI_win_count = 0, AAI_loss_count = 0;
double   AAI_curve = 0.0;                // equity curve (closed-trade increments)
double   AAI_peak  = 0.0;                // peak of curve
double   AAI_max_dd = 0.0;
// max drawdown (abs) on closed-trade curve

long     AAI_last_in_pos_id = -1;
datetime AAI_last_in_time = 0;
ulong    AAI_last_out_deal = 0;  // dedupe out deals
ulong    AAI_last_in_deal  = 0;
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
//|                                       v5.12 - Telemetry v2       |
//|            HEDGING INPUTS ADDED                                  |
//| (Consumes all data from the refactored AAI_Indicator_SignalBrain)|
//|                                                                  |
//| Copyright 2025, AlfredAI Project                                 |
//+------------------------------------------------------------------+
#property strict
#property version   "5.12"
#property description "Manages trades based on signals from the central SignalBrain indicator."
#include <Trade\Trade.mqh>
#include <Arrays\ArrayObj.mqh>
#include <Arrays\ArrayLong.mqh>
#include <AAI/AAI_Include_News.mqh>

// === T49: Account-wide New-Position Throttle (default OFF) ===============
const bool T49_Enable     = false;             // leave OFF by default
const bool T49_LogVerbose = RTP_IS_DIAG;       // logs only in Diagnostics profile
static datetime g_t49_last_log = 0;

bool T49_MayOpenThisBar(const datetime bar_time)
{
   if(!T49_Enable) return true;

   const string k = "AAI/ACC/BARLOCK";
   double v = 0.0;

   if(GlobalVariableCheck(k))
   {
      v = GlobalVariableGet(k);
      if((datetime)v == bar_time)
      {
         if(T49_LogVerbose && bar_time != g_t49_last_log)
         {
            PrintFormat("[T49] throttle: position already opened @ %s",
                        TimeToString(bar_time, TIME_DATE|TIME_SECONDS));
            g_t49_last_log = bar_time;
         }
         return false;
      }
   }

   // Claim this bar for the account so other charts skip new entries this bar
   GlobalVariableSet(k, (double)bar_time);
   return true;
}

// === T50 prototypes (bodies are elsewhere in the file) ====================
// === T50: Failsafe / Self-check (default OFF) =============================
enum { T50_RING = 16 };
const bool T50_Enable           = false;    // default OFF
const int  T50_ErrorWindowBars  = 5;        // failures within this many bars…
const int  T50_SuspendBars      = 10;       // …suspend for N bars
const bool T50_LogVerbose       = RTP_IS_DIAG;

static datetime g_t50_err_ring[T50_RING];
static int      g_t50_err_head  = 0;
static int      g_t50_err_count = 0;
static datetime g_t50_suspend_until = 0;
static datetime g_t50_last_log = 0;

void T50_RecordSendFailure(const datetime bar_time)
{
   if(!T50_Enable) return;

   g_t50_err_ring[g_t50_err_head] = bar_time;
   g_t50_err_head = (g_t50_err_head + 1) % T50_RING;
   if(g_t50_err_count < T50_RING) g_t50_err_count++;

   int within = 0;
   const int ps = PeriodSeconds((ENUM_TIMEFRAMES)_Period);
   const datetime window_start = bar_time - (ps * (T50_ErrorWindowBars-1));

   for(int i=0;i<g_t50_err_count;i++)
   {
      int idx = (g_t50_err_head - 1 - i + T50_RING) % T50_RING;
      datetime bt_i = g_t50_err_ring[idx];
      if(bt_i >= window_start) within++;
      else break;
   }

   if(within >= T50_ErrorWindowBars)
   {
      g_t50_suspend_until = bar_time + (ps * T50_SuspendBars);
      if(T50_LogVerbose && bar_time != g_t50_last_log)
      {
         PrintFormat("[T50] suspend new entries for %d bars until %s (failures=%d)",
                     T50_SuspendBars,
                     TimeToString(g_t50_suspend_until, TIME_DATE|TIME_SECONDS),
                     within);
         g_t50_last_log = bar_time;
      }
   }
}

bool T50_AllowedNow(const datetime bar_time)
{
   if(!T50_Enable) return true;
   if(g_t50_suspend_until <= 0) return true;
   if(TimeCurrent() >= g_t50_suspend_until) return true;

   if(T50_LogVerbose && bar_time != g_t50_last_log)
   {
      PrintFormat("[T50] blocked until %s",
                  TimeToString(g_t50_suspend_until, TIME_DATE|TIME_SECONDS));
      g_t50_last_log = bar_time;
   }
   return false;
}



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

// --- T037: Position Health Watchdog (PHW) Constants ---
const bool   PHW_Enable            = true;
const int    PHW_FailBurstN          = 3;
const int    PHW_FailBurstWindowSec  = 15;
const int    PHW_SpreadSpikePoints   = 500;
const int    PHW_CooldownMinSec      = 60;
const int    PHW_CooldownMaxSec      = 900;
const double PHW_BackoffMultiplier   = 1.8;
const int    PHW_ResetHour           = 0;

// --- T038: Equity Curve Feedback (ECF) Constants ---
const bool   ECF_Enable           = true;
const int    ECF_MinTradesForBoost  = 10;
const int    ECF_EMA_Trades         = 10;
const double ECF_MaxUpMult          = 1.10;
const double ECF_MaxDnMult          = 0.85;
const double ECF_DD_SoftPct         = 5.0;
const double ECF_DD_HardPct         = 12.0;
const bool   ECF_HardBlock          = false;
const bool   ECF_LogVerbose         = false;

// --- T039: SL Cluster Micro-Cooldowns (SLC) Constants ---
const bool   SLC_Enable           = true;
const int    SLC_MinEvents          = 2;
const int    SLC_ClusterPoints      = 40;
const int    SLC_ClusterWindowSec   = 180;
const int    SLC_CooldownMinSec     = 120;
const int    SLC_CooldownMaxSec     = 900;
const double SLC_BackoffMultiplier  = 1.6;
const int    SLC_ResetHour          = 0;
const bool   SLC_DirSpecific        = true;
const int    SLC_History            = 12;
const bool   SLC_LogVerbose         = false;

// --- T040: Execution Analytics & Adaptive Slippage (EA+AS) ---
const bool   EA_Enable           = true;
const int    EA_EwmaTrades       = 12;
const int    EA_BaseDeviationPts = 8;
const int    EA_MinDeviationPts  = 4;
const int    EA_MaxDeviationPts  = 40;
const double EA_DevVsSlipMul     = 1.20;
const double EA_DevVsSpreadFrac  = 0.60;
const int    EA_RejBumpPts       = 4;
enum { EA_RejWindowTrades = 8 };
const int    EA_LatBumpMs        = 250;
const int    EA_LatBumpPts       = 2;
const bool   EA_LogVerbose       = false;

// --- T041: Market State Model (MSM) Constants ---
// Window sizes (compile-time)
enum {
   MSM_ATR_Period      = 14,
   MSM_ADX_Period      = 14,
   MSM_EMA_Fast        = 20,
   MSM_EMA_Slow        = 50,
   MSM_ATR_PctlWindow  = 200,    // ATR history for percentile
   MSM_Brk_Period      = 20      // Donchian breakout lookback (excl. current bar)
};
// Tunables
const bool   MSM_Enable          = true;
const double MSM_PctlVolatile    = 0.70;  // ATR percentile >= 70% -> volatile
const double MSM_PctlQuiet       = 0.30;  // ATR percentile <= 30% -> quiet
const double MSM_ADX_TrendThresh = 22.0;  // ADX >= 22 -> trending
const double MSM_ADX_RangeThresh = 18.0;  // ADX <= 18 -> ranging bias
const double MSM_MaxUpMult       = 1.08;  // cap boost
const double MSM_MaxDnMult       = 0.90;  // cap penalty
const double MSM_MisalignedTrend = 0.92;  // penalty when signal vs trend disagree
const double MSM_RangePenalty    = 0.96;  // small mean-reversion bias
const double MSM_VolatPenalty    = 0.93;  // higher noise -> caution
const double MSM_QuietPenalty    = 0.96;  // low ATR -> slip/fill risk
const bool   MSM_LogVerbose      = false; // throttle to <=1/bar

// --- T042: Telemetry v2 Constants ---
enum { TEL_STRLEN = 256 };
const bool   TEL_Enable    = true;
const int    TEL_EmitEveryN  = 0;
const bool   TEL_LogVerbose  = false;
const string TEL_Prefix      = "TEL";

// --- T043: Backtest/Live Parity Harness (PTH) Constants ---
enum { PTH_STRLEN = 256, PTH_RING = 64 };
const bool   PTH_Enable      = true;    // harness active internally; printing still gated by EveryN
const int    PTH_EmitEveryN  = 0;       // 0 = no PAR prints; N>0 => print every N closed bars
const bool   PTH_LogVerbose  = false;   // add a few extra fields when true
const string PTH_Prefix      = "PAR";   // log tag

// --- T044: State Persistence (SP v1) Constants ---
enum { SP_STRLEN = 384 };
const bool   SP_Enable         = true;
const bool   SP_LoadInTester   = false;
const bool   SP_OnDeinitWrite  = true;
const int    SP_WriteEveryN    = 0;
const string SP_FilePrefix     = "AAI_STATE";
const int    SP_Version        = 1;
const bool   SP_LogVerbose     = false;

// --- T045: Multi-Symbol Orchestration (MSO v1) Constants ---
enum { MSO_STRLEN = 128 };
const bool   MSO_Enable                  = true;   // module toggle
const int    MSO_LockTTLms               = 750;    // global lock TTL
const int    MSO_MaxSendsPerSec          = 4;      // global budget
const int    MSO_MinMsBetweenSymbolSends = 300;    // fairness gap per symbol
const bool   MSO_LogVerbose              = false;  // once/bar throttled logs

// --- EA Fixes (Part B): Indicator Path Helper ---
#define AAI_IND_PREFIX "AlfredAI\\"
inline string AAI_Ind(const string name)
{
   if(StringFind(name, AAI_IND_PREFIX) == 0) // already prefixed
      return name;
   return AAI_IND_PREFIX + name;
}

// --- TICKET T021: Bar-Change Cache ---
struct SBReadCache {
  datetime closed_bar_time;
  int      sig;      // SB_BUF_SIGNAL
  double   conf;     // SB_BUF_CONF
  int      reason;   // SB_BUF_REASON
  double   ze;       // SB_BUF_ZE
  int      smc_sig;  // SB_BUF_SMC_SIG
  double   smc_conf; // SB_BUF_SMC_CONF
  int      bc;       // SB_BUF_BC
  bool     valid;
};
static SBReadCache g_sb;
//////////////////////////// fixing sendfail errors
enum ENUM_OSR_FillMode { OSR_FILL_IOC, OSR_FILL_FOK, OSR_FILL_DEFAULT };
/////////////////////

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

// T043: FNV-1a 32-bit string hasher
inline uint FNV1a32(const string s)
{
   uint h = 2166136261;
   for(int i=0;i<StringLen(s);++i){ h ^= (uchar)s[i]; h *= 16777619; }
   return h;
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

// T042: More robust spread helper
int CurrentSpreadPoints()
{
   long spr = 0;
   if(SymbolInfoInteger(_Symbol, SYMBOL_SPREAD, spr) && spr > 0) return (int)spr;
   // Fallback for variable spread / during backtest
   double s = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID)) / _Point;
   return (int)MathMax(0, (int)MathRound(s));
}

// --- Timeframe label helpers ---
inline string TfLabel(ENUM_TIMEFRAMES tf) {
   string s = EnumToString(tf);
   // e.g., "PERIOD_M15"
   int p = StringFind(s, "PERIOD_");
   return (p == 0 ? StringSubstr(s, 7) : s);
   // -> "M15"
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
#ifdef REASON_NONE
  #undef REASON_NONE
#endif
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
// T032: Confidence-to-Risk Curve Mode
enum ENUM_CRC_Mode { CRC_OFF=0, CRC_LINEAR=1, CRC_QUADRATIC=2, CRC_LOGISTIC=3, CRC_PIECEWISE=4 };
// T033: SL/TP Auto-Adjust Mode
enum ENUM_SLTA_Mode {
  SLTA_OFF=0,
  SLTA_ADJUST_TP_KEEP_RR=1,
  SLTA_ADJUST_SL_ONLY=2,
  SLTA_SCALE_BOTH=3
};
// T034: Post-Fill Harmonizer Mode
enum ENUM_HM_Mode { HM_OFF=0, HM_ONESHOT_IMMEDIATE=1, HM_DELAYED_RETRY=2 };
// T035: Trailing/BE Mode
enum ENUM_TRL_Mode { TRL_OFF=0, TRL_BE_ONLY=1, TRL_ATR=2, TRL_CHANDELIER=3, TRL_SWING=4 };
// T036: Partial Take-Profit SL Adjustment Mode
enum ENUM_PT_SLA { PT_SLA_NONE=0, PT_SLA_TO_BE=1, PT_SLA_LOCK_OFFSET=2 };


//--- EA Inputs
input ENUM_EXECUTION_MODE ExecutionMode = AutoExecute;
input ENUM_APPROVAL_MODE  ApprovalMode  = None;
input ENUM_ENTRY_MODE     EntryMode     = FirstBarOrEdge;
input ulong  MagicNumber         = 1337;
input ENUM_TIMEFRAMES SignalTimeframe = PERIOD_CURRENT;
input int SB_ReadShift = 1;
input int WarmupBars = 200;

// --- TICKET T023: Inputs to control SignalBrain's confluence model ---
input group "--- SignalBrain Confluence Model ---";
enum ENUM_SB_ConfModel { SB_CONF_ADDITIVE=0, SB_CONF_GEOMETRIC=1 };
input ENUM_SB_ConfModel InpSB_ConfModel = SB_CONF_ADDITIVE;
input double InpSB_W_BASE = 1.0;
input double InpSB_W_BC   = 1.0;
input double InpSB_W_ZE   = 1.0;
input double InpSB_W_SMC  = 1.0;
input double InpSB_ConflictPenalty = 0.80;


// --- All Pass-Through Inputs for the new SignalBrain ---
input group "--- SignalBrain Pass-Through Inputs ---";
// Core SB Settings
input bool   SB_SafeTest         = false;
input bool   SB_UseZE            = true;
input bool   SB_UseBC            = true;
input bool   SB_UseSMC           = true;
input int    SB_WarmupBars       = 150;
input int    SB_FastMA           = 5;
input int    SB_SlowMA           = 12;
input int    SB_MinZoneStrength  = 4;
input bool   SB_EnableDebug      = true;
// SB Confidence Model (Additive Path)
input int    SB_Bonus_ZE         = 4;
input int    SB_Bonus_BC         = 4;
input int    SB_Bonus_SMC        = 4;
input int    SB_BaseConf         = 4;
// BC Pass-Through
input int    SB_BC_FastMA        = 5;
input int    SB_BC_SlowMA        = 12;
// ZE Pass-Through
input double SB_ZE_MinImpulseMovePips = 10.0;
// SMC Pass-Through
input bool   SB_SMC_UseFVG       = true;
input bool   SB_SMC_UseOB        = true;
input bool   SB_SMC_UseBOS       = true;
input double SB_SMC_FVG_MinPips  = 1.0;
input int    SB_SMC_OB_Lookback  = 20;
input int    SB_SMC_BOS_Lookback = 50;


//--- Risk Management Inputs ---
input group "Risk Management"
input int    SL_Buffer_Points  = 10;

// --- Confidence -> Risk Curve (T032) ---
input group "Confidence -> Risk Curve"
input bool          InpCRC_Enable        = true;
input ENUM_CRC_Mode InpCRC_Mode          = CRC_LINEAR;
input double        InpCRC_MinRiskPct    = 0.50;
input double        InpCRC_MaxRiskPct    = 1.00;
input double        InpCRC_MinLots       = 0.01;
input double        InpCRC_MaxLots       = 10.0;
input double        InpCRC_MaxRiskMoney  = 0.00;
input int           InpCRC_MinConfidence = 50;
input double        InpCRC_QuadAlpha     = 1.00;
input double        InpCRC_LogisticMid   = 70.0;
input double        InpCRC_LogisticSlope = 0.15;
input int           InpCRC_PW_C1         = 60;
input double        InpCRC_PW_R1         = 0.70;
input int           InpCRC_PW_C2         = 75;
input double        InpCRC_PW_R2         = 0.85;
input int           InpCRC_PW_C3         = 90;
input double        InpCRC_PW_R3         = 0.95;

//--- Trade Management Inputs ---
input group "Trade Management"
input bool   PerBarDebounce      = true;
input uint   DuplicateGuardMs    = 300;
input int    CooldownAfterSLBars = 2;
input int    MaxSpreadPoints     = 30;
input int    MaxSlippagePoints   = 20;
input int    FridayCloseHour     = 22;
input bool   EnableLogging       = true;
//--- Telegram Alerts ---
// --- Hedging & Pyramiding ---
input group "--- Hedging & Pyramiding ---"
input bool   InpHEDGE_AllowMultiple        = true;    // allow many positions per symbol (hedging)
input bool   InpHEDGE_AllowOpposite        = true;    // allow long+short at same time
input int    InpHEDGE_MaxPerSymbol         = 5;       // cap all positions on symbol (this EA's magic)
input int    InpHEDGE_MaxLongPerSymbol     = 5;       // cap longs
input int    InpHEDGE_MaxShortPerSymbol    = 5;       // cap shorts
input int    InpHEDGE_MinStepPips          = 50;      // min distance between entries on same side
input bool   InpHEDGE_SplitRiskAcrossPyr   = true;    // divide risk across the pyramid
input double InpHEDGE_MaxAggregateRiskPct  = 3.0;     // cap total risk % on this symbol (optional)


input group "Telegram Alerts"
input bool   UseTelegramFromEA = false;
input string TelegramToken       = "";
input string TelegramChatID      = "";
input bool   AlertsDryRun      = true;
//--- Session Inputs (idempotent) ---
#ifndef AAI_SESSION_INPUTS_DEFINED
#define AAI_SESSION_INPUTS_DEFINED
input bool SessionEnable = false;
input int  SessionStartHourServer = 8; // server time
input int  SessionEndHourServer   = 23;  // server time
#endif

#ifndef AAI_HYBRID_INPUTS_DEFINED
#define AAI_HYBRID_INPUTS_DEFINED
// Auto-trading window (server time). Outside -> alerts only.
input string AutoHourRanges = "8-14,17-23";   // comma-separated hour ranges
// Day mask for auto-trading (server time): Sun=0..Sat=6
input bool AutoSun=false, AutoMon=true, AutoTue=true, AutoWed=true, AutoThu=true, AutoFri=true, AutoSat=false;
// Alert channels + throttle
input bool   HybridAlertPopup       = true;
input bool   HybridAlertPush        = true; // requires terminal Push enabled
input bool   HybridAlertWriteIntent = true; // write intent file under g_dir_intent
input int    HybridAlertThrottleSec = 60; // min seconds between alerts for the same bar
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
input bool   Exit_FixedRR        = true;
input double Fixed_RR            = 1.6;
input double Partial_Pct         = 50.0;
input double Partial_R_multiple  = 1.0;
input int    BE_Offset_Points    = 1;

// --- Trailing / Break-Even (T035) ---
input group "Trailing / Break-Even"
input bool          InpTRL_Enable            = true;
input ENUM_TRL_Mode InpTRL_Mode              = TRL_ATR;
input bool          InpTRL_OnBarClose        = true;
input int           InpTRL_MinSecondsBetween = 15;
input bool          InpTRL_BE_Enable         = true;
input double        InpTRL_BE_TriggerRR      = 1.0;
input int           InpTRL_BE_TriggerPts     = 0;
input int           InpTRL_BE_OffsetPts      = 2;
input ENUM_TIMEFRAMES InpTRL_ATR_Timeframe   = PERIOD_CURRENT;
input int           InpTRL_ATR_Period        = 14;
input double        InpTRL_ATR_Mult          = 2.0;
input int           InpTRL_AtrLookbackBars   = 22;
input int           InpTRL_SwingLookbackBars = 50;
input int           InpTRL_SwingLeg          = 2;
input int           InpTRL_SwingBufferPts    = 5;
input int           InpTRL_MinBumpPts        = 2;
input int           InpTRL_MaxDailyMoves     = 10;
input bool          InpTRL_LogVerbose        = false;

// --- Partial Take-Profit Ladder (T036) ---
input group "Partial Take-Profit Ladder"
input bool        InpPT_Enable          = true;
input bool        InpPT_OnBarClose      = true;      // evaluate on closed bars when true
input int         InpPT_MinSecondsBetween = 10;        // throttle per-symbol between actions
// Step 1
input bool        InpPT1_Enable         = true;
input double      InpPT1_TriggerRR      = 1.00;      // trigger when RR >= this (uses initial SL distance)
input int         InpPT1_TriggerPts     = 0;         // OR when raw profit >= this (points); 0=off
input double      InpPT1_ClosePct       = 33.0;      // % of ORIGINAL entry lots to close
input ENUM_PT_SLA InpPT1_SLA            = PT_SLA_TO_BE;
input int         InpPT1_SLA_OffsetPts  = 2;         // used for TO_BE / LOCK_OFFSET
// Step 2
input bool        InpPT2_Enable         = true;
input double      InpPT2_TriggerRR      = 1.50;
input int         InpPT2_TriggerPts     = 0;
input double      InpPT2_ClosePct       = 33.0;
input ENUM_PT_SLA InpPT2_SLA            = PT_SLA_LOCK_OFFSET;
input int         InpPT2_SLA_OffsetPts  = 10;
// Step 3
input bool        InpPT3_Enable         = true;
input double      InpPT3_TriggerRR      = 2.00;
input int         InpPT3_TriggerPts     = 0;
input double      InpPT3_ClosePct       = 34.0;
input ENUM_PT_SLA InpPT3_SLA            = PT_SLA_LOCK_OFFSET;
input int         InpPT3_SLA_OffsetPts  = 20;
// Logging
input bool        InpPT_LogVerbose      = false;


//--- Entry Filter Inputs (M15 Baseline) ---
input group "Entry Filters"
input int               MinConfidence        = 4; 
// --- T011: Over-extension Inputs ---
input group "Over-extension Guard"
input ENUM_OVEREXT_MODE OverExtMode = WaitForBand;
input int    OverExt_MA_Period  = 20;
input int    OverExt_ATR_Period = 14;
input double OverExt_ATR_Mult   = 2.0;
input int    OverExt_WaitBars   = 3;

//--- T022: Volatility Regime Inputs ---
input group "Volatility Regime"
input bool           InpVR_Enable      = true;
input int            InpVR_ATR_Period  = 14;
input int            InpVR_MinBps      = 8;   // 0.08%
input int            InpVR_MaxBps      = 60;  // 0.60%
enum ENUM_VR_Mode { VR_OFF=0, VR_REQUIRED=1, VR_PREFERRED=2 };
input ENUM_VR_Mode InpVR_Mode = VR_PREFERRED;
input int            InpVR_PrefPenalty = 4;  

//--- News/Event Gate Inputs (T024) ---
input group "News/Event Gate"
input bool           InpNews_Enable      = false;
input string         InpNews_CsvName     = "AAI_News.csv";   // From Common Files
input ENUM_NEWS_Mode InpNews_Mode = NEWS_REQUIRED;
input bool           InpNews_TimesAreUTC = true;
input bool           InpNews_FilterHigh  = true;
input bool           InpNews_FilterMedium= true;
input bool           InpNews_FilterLow   = false;
input int            InpNews_PrefPenalty = 5;

//--- Structure Proximity Gate Inputs (T027) ---
input group "Structure Proximity"
enum ENUM_SP_Mode { SP_OFF=0, SP_REQUIRED=1, SP_PREFERRED=2 };
input ENUM_SP_Mode InpSP_Mode              = SP_REQUIRED;
input bool         InpSP_Enable              = true;
input bool         InpSP_UseATR              = true;
input int          InpSP_ATR_Period          = 14;
input double       InpSP_ATR_Mult            = 0.5;
input int          InpSP_AbsPtsThreshold     = 150;
input bool         InpSP_CheckRoundNumbers   = true;
input int          InpSP_RoundGridPts        = 500;
input int          InpSP_RoundOffsetPts      = 0;
input bool         InpSP_CheckYesterdayHighLow = true;
input int          InpSP_YHYL_BufferPts      = 0;
input bool         InpSP_CheckWeeklyOpen     = true;
input int          InpSP_WOpen_BufferPts     = 0;
input bool         InpSP_CheckSwings         = true;
input int          InpSP_SwingLookbackBars   = 50;
input int          InpSP_SwingLeg            = 2;
input int          InpSP_PrefPenalty         = 5;

// --- Adaptive Spread (T028) ---
input group "Adaptive Spread"
enum ENUM_AS_Mode { AS_OFF=0, AS_REQUIRED=1, AS_PREFERRED=2 };
input bool         InpAS_Enable          = true;
input ENUM_AS_Mode InpAS_Mode            = AS_REQUIRED;
input int          InpAS_SampleEveryNTicks = 5;
input int          InpAS_SamplesPerBarMax  = 400;
input int          InpAS_WindowBars      = 20;
input double       InpAS_SafetyPct       = 0.10;
input int          InpAS_SafetyPts       = 2;
input bool         InpAS_ClampToFixedMax = true;
input int          InpAS_PrefPenalty     = 2;

// --- Inter-Market Confirmation (T029) ---
input group "Inter-Market Confirmation"
enum ENUM_IMC_Mode  { IMC_OFF=0, IMC_REQUIRED=1, IMC_PREFERRED=2 };
enum ENUM_IMC_Rel   { IMC_ALIGN=1, IMC_CONTRA=-1 };
enum ENUM_IMC_Method { IMC_ROC=0 };
input bool          InpIMC_Enable         = true;
input ENUM_IMC_Mode InpIMC_Mode           = IMC_REQUIRED;
input string        InpIMC1_Symbol        = "";
input ENUM_TIMEFRAMES InpIMC1_Timeframe   = PERIOD_H1;
input ENUM_IMC_Rel  InpIMC1_Relation      = IMC_CONTRA;
input ENUM_IMC_Method InpIMC1_Method      = IMC_ROC;
input int           InpIMC1_LookbackBars  = 10;
input double        InpIMC1_MinAbsRocBps  = 0.0;
input string        InpIMC2_Symbol        = "";
input ENUM_TIMEFRAMES InpIMC2_Timeframe   = PERIOD_H1;
input ENUM_IMC_Rel  InpIMC2_Relation      = IMC_ALIGN;
input ENUM_IMC_Method InpIMC2_Method      = IMC_ROC;
input int           InpIMC2_LookbackBars  = 10;
input double        InpIMC2_MinAbsRocBps  = 0.0;
input double        InpIMC1_Weight        = 1.0;
input double        InpIMC2_Weight        = 1.0;
input double        InpIMC_MinSupport     = 0.50;
input int           InpIMC_PrefPenalty    = 4;

// --- Global Risk Guard (T030) ---
input group "Global Risk Guard"
enum ENUM_RG_Mode { RG_OFF=0, RG_REQUIRED=1, RG_PREFERRED=2 };
input bool         InpRG_Enable            = true;
input ENUM_RG_Mode InpRG_Mode              = RG_REQUIRED;
input int          InpRG_ResetHourServer   = 0;
input double       InpRG_MaxDailyLossPct   = 2.0;
input double       InpRG_MaxDailyLossMoney = 0.0;
input int          InpRG_MaxSLHits         = 0;
input int          InpRG_MaxConsecLosses   = 3;
enum ENUM_RG_BlockUntil { RG_BLOCK_TIL_END_OF_DAY=0, RG_BLOCK_FOR_HOURS=1 };
input ENUM_RG_BlockUntil InpRG_BlockUntil    = RG_BLOCK_TIL_END_OF_DAY;
input int          InpRG_BlockHours        = 4;
input int          InpRG_PrefPenalty       = 5;

// --- Order Send Robustness & Retry (T031) ---
input group "Order Send Robustness & Retry"
input bool                 InpOSR_Enable         = true;
input int                  InpOSR_MaxRetries     = 2;
input int                  InpOSR_RetryDelayMs   = 250;
input bool                 InpOSR_RepriceOnRetry = true;
input int                  InpOSR_SlipPtsInitial = 5;
input int                  InpOSR_SlipPtsStep    = 5;
input int                  InpOSR_SlipPtsMax     = 25;
enum ENUM_OSR_PriceMode { OSR_USE_LAST=0, OSR_USE_CURRENT=1 };
input ENUM_OSR_PriceMode InpOSR_PriceMode = OSR_USE_CURRENT;
input ENUM_OSR_FillMode  InpOSR_FillMode       = OSR_FILL_DEFAULT; 
input bool                 InpOSR_LogVerbose     = false;

// --- SL/TP Safety & MinStops Auto-Adjust (T033) ---
input group "SL/TP Safety & MinStops Auto-Adjust"
input bool           InpSLTA_Enable        = true;
input ENUM_SLTA_Mode InpSLTA_Mode          = SLTA_ADJUST_TP_KEEP_RR;
input double         InpSLTA_TargetRR      = 1.50;
input double         InpSLTA_MinRR         = 1.20;
input int            InpSLTA_ExtraBufferPts = 2;
input double         InpSLTA_MaxWidenFrac  = 0.50;
input int            InpSLTA_MaxTPPts      = 0;
input bool           InpSLTA_StrictCancel  = true;
input bool           InpSLTA_LogVerbose    = false;

// --- Post-Fill Harmonizer (T034) ---
input group "Post-Fill Harmonizer"
input bool         InpHM_Enable        = true;
input ENUM_HM_Mode InpHM_Mode          = HM_DELAYED_RETRY;
input int          InpHM_DelayMs       = 300;
input int          InpHM_MaxRetries    = 3;
input int          InpHM_BackoffMs     = 400;
input int          InpHM_MinChangePts  = 2;
input bool         InpHM_RespectFreeze = true;
input bool         InpHM_LogVerbose    = false;


//--- Confluence Module Inputs (M15 Baseline) ---
input group "Confluence Modules"
input ENUM_BC_ALIGN_MODE BC_AlignMode      = BC_REQUIRED;
input ENUM_ZE_GATE_MODE  ZE_Gate           = ZE_REQUIRED;
input int                ZE_MinStrength    = 4;

enum SMCMode { SMC_OFF=0, SMC_PREFERRED=1, SMC_REQUIRED=2 };
input SMCMode SMC_Mode = SMC_REQUIRED;
input int   SMC_MinConfidence = 7;

//--- Journaling Inputs ---
input group "Journaling"
input bool   EnableJournaling      = false;        
input string JournalFileName       = "AlfredAI_Journal.csv";
input bool   JournalUseCommonFiles = false;        

// --- Decision Journaling (T026) ---
input group "Decision Journaling"
input bool   InpDJ_Enable      = false;
input string InpDJ_FileName    = "AAI_Decisions.csv";
input bool   InpDJ_Append      = true;

// ... after your other input groups ...

// --- Anti-Zombie Controls (AZ) ---
input group "--- Anti-Zombie Controls (AZ) ---"
input bool   InpAZ_TTL_Enable        = true;     // Enable max trade lifetime (Time-To-Live)
input int    InpAZ_TTL_Hours         = 8;        // Max age of any position in hours
input bool   InpAZ_SessionForceFlat  = true;     // Force-close all positions outside the session window
input int    InpAZ_PrefExitMins      = 10;       // Minutes before session end to start closing

//--- Globals
CTrade   trade;
string   symbolName;
double   point;
static ulong g_logged_positions[]; // For duplicate journal entry prevention
int      g_logged_positions_total = 0;
AAI_NewsGate g_newsGate;
// --- T011: Over-extension State ---
static int g_overext_wait = 0;
// --- TICKET #3: Over-extension timing fix ---
static datetime g_last_overext_dec_sigbar = 0;
// --- Simplified Persistent Indicator Handles ---
int sb_handle = INVALID_HANDLE;
int g_hATR = INVALID_HANDLE;
int g_hOverextMA = INVALID_HANDLE;
int g_hATR_VR = INVALID_HANDLE; // T022: New handle for Volatility Regime
int g_hATR_SP = INVALID_HANDLE; // T027: New handle for Structure Proximity
int g_hATR_TRL = INVALID_HANDLE; // T035
// T041
int g_hMSM_ATR = INVALID_HANDLE;
int g_hMSM_ADX = INVALID_HANDLE;
int g_hMSM_EMA_Fast = INVALID_HANDLE;
int g_hMSM_EMA_Slow = INVALID_HANDLE;


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

// --- T042: Telemetry State ---
static int      g_tel_barcount = 0;
static datetime g_tel_lastbar  = 0;

// --- T043: Parity Harness State ---
static bool     g_pth_is_tester = false;
static bool     g_pth_is_opt    = false;
static bool     g_pth_init      = false;
static datetime g_pth_stamp     = 0;
static int      g_pth_barcount  = 0;

// --- T044: State Persistence State ---
static int      g_sp_barcount = 0;
static datetime g_sp_lastbar  = 0;

// --- T026/T027/T029: Per-bar flags for decision journaling ---
static int    g_vr_flag_for_bar   = 0;
static int    g_news_flag_for_bar = 0;
static bool   g_sp_hit_for_bar    = false;
static bool   g_imc_flag_for_bar  = false;
static double g_imc_support       = 0.0;
static bool   g_rg_flag_for_bar   = false;


// --- T028: Adaptive Spread State ---
int      g_as_tick_ctr         = 0;
double   g_as_samples[];
datetime g_as_forming_bar_time = 0;
double   g_as_bar_medians[];
int      g_as_hist_count       = 0;
int      g_as_hist_pos         = 0;
bool     g_as_exceeded_for_bar = false;
double   g_as_cap_pts_last     = 0.0;

// --- T030: Global Risk Guard State ---
datetime g_rg_day_anchor_time   = 0;
double   g_rg_day_start_balance = 0.0;
double   g_rg_day_realized_pl   = 0.0;
int      g_rg_day_sl_hits       = 0;
int      g_rg_consec_losses     = 0;
bool     g_rg_block_active      = false;
datetime g_rg_block_until       = 0;

// --- T034: Harmonizer State ---
class HM_Task : public CObject {
public:
  string   symbol;
  long     pos_ticket;
  double   sl_target;
  double   tp_target;
  int      retries_left;
  datetime next_try_time;
  HM_Task(): pos_ticket(0), sl_target(0), tp_target(0), retries_left(0), next_try_time(0) {}
};
CArrayObj g_hm_tasks;
datetime  g_hm_last_tick_ts = 0;

// --- T035 & T036: Trailing and Partial TP State ---
class TRL_State : public CObject {
public:
  string   symbol;
  int      direction;
  double   entry_price;
  double   entry_sl_pts;
  // T036 fields
  double   entry_lots;
  double   pt_closed_lots;
  bool     pt1_done, pt2_done, pt3_done;
  // T035 fields
  bool     be_done;
  int      moves_today;
  datetime last_mod_time;
  datetime day_anchor;
  TRL_State(): direction(0), entry_price(0), entry_sl_pts(0),
               entry_lots(0.0), pt_closed_lots(0.0),
               pt1_done(false), pt2_done(false), pt3_done(false),
               be_done(false),
               moves_today(0), last_mod_time(0), day_anchor(0) {}
};
CArrayObj g_trl_states;

// --- T037: Position Health Watchdog State ---
static datetime g_phw_fail_timestamps[];
static int      g_phw_fail_count = 0;
static datetime g_phw_day_anchor = 0;
static int      g_phw_repeats_today = 0;
static datetime g_phw_cool_until = 0;
static datetime g_phw_last_trigger_ts = 0;

// --- T038: Equity Curve Feedback State ---
static double   g_ecf_ewma = 0.0;
static datetime g_stamp_ecf = 0;

// --- T039: SL Cluster State ---
struct SLC_Event {
    double   price;
    datetime time;
};
static SLC_Event  g_slc_history_buy[];
static SLC_Event  g_slc_history_sell[];
static int        g_slc_head_buy = 0;
static int        g_slc_head_sell = 0;
static int        g_slc_count_buy = 0;
static int        g_slc_count_sell = 0;
static datetime   g_slc_cool_until_buy = 0;
static datetime   g_slc_cool_until_sell = 0;
static int        g_slc_repeats_buy = 0;
static int        g_slc_repeats_sell = 0;
static datetime   g_slc_day_anchor = 0;

// --- T040: Execution Analytics State ---
struct EA_State {
    double   ewma_slip_pts;
    double   ewma_latency_ms;
    int      rej_history[EA_RejWindowTrades]; // Ring buffer: 1=reject, 0=ok
    int      rej_head;
    int      rej_count;   // Total valid entries in history
    ulong    last_send_ticks;
    double   last_req_price;  // Requested price for slippage calc
};
static EA_State g_ea_state;
static int      g_last_dev_pts = 0; // T042: store last deviation for telemetry

// --- T041: Market State Model State ---
static datetime g_stamp_msm = 0;
// ATR history for percentile
static double   g_msm_atr_hist[MSM_ATR_PctlWindow];
static int      g_msm_atr_head = 0;
static int      g_msm_atr_count = 0;
// Last computed features (for optional logs/debug)
static double   g_msm_atr         = 0.0;
static double   g_msm_adx         = 0.0;
static double   g_msm_pctl        = 0.0;   // 0..1 percentile
static int      g_msm_state       = 0;     // 0=unknown,1=TREND_UP,2=TREND_DN,3=RANGE,4=BREAKOUT_UP,5=BREAKOUT_DN,6=VOLAT,7=QUIET
static double   g_msm_mult        = 1.0;


// --- T012: Summary Counters ---
static long g_entries     = 0;
static long g_wins        = 0;
static long g_losses      = 0;
static long g_blk_ze      = 0;
static long g_blk_bc      = 0;
static long g_blk_imc     = 0; // T029
static long g_blk_risk    = 0; // T030
static long g_blk_over    = 0;
static long g_blk_spread  = 0;
static long g_blk_aspread = 0; // T028
static long g_blk_smc     = 0;
static long g_blk_vr      = 0;
static long g_blk_news    = 0;
static long g_blk_sp      = 0; // T027
static long g_blk_phw     = 0; // T037
static long g_blk_slc     = 0; // T039
static bool g_summary_printed = false;
// --- Once-per-bar stamps for block counters ---
datetime g_stamp_conf  = 0;
datetime g_stamp_ze    = 0;
datetime g_stamp_bc    = 0;
datetime g_stamp_imc   = 0; // T029
datetime g_stamp_risk  = 0; // T030
datetime g_stamp_over  = 0;
datetime g_stamp_sess  = 0;
datetime g_stamp_spd   = 0;
datetime g_stamp_aspd  = 0; // T028
datetime g_stamp_atr   = 0;
datetime g_stamp_cool  = 0;
datetime g_stamp_bar   = 0;
datetime g_stamp_smc   = 0;
datetime g_stamp_vr    = 0;
datetime g_stamp_news  = 0;
datetime g_stamp_sp    = 0; // T027
datetime g_stamp_phw   = 0; // T037
datetime g_stamp_slc   = 0; // T039
datetime g_stamp_mso   = 0; // T045
datetime g_stamp_none  = 0;
datetime g_stamp_approval = 0;

// ... after g_stamp_approval or similar globals ...

// --- T_AZ: Auto-Zone Globals ---
static int g_ttl_secs;
static int g_pref_exit_secs;

#ifndef AAI_HYBRID_STATE_DEFINED
#define AAI_HYBRID_STATE_DEFINED
bool g_auto_hour_mask[24];
datetime g_hyb_last_alert_bar = 0;
datetime g_hyb_last_alert_ts  = 0;
int g_blk_hyb = 0;        // count "alert-only" bars
datetime g_stamp_hyb = 0;     // once-per-bar stamp
#endif

//+------------------------------------------------------------------+
//| T012: Print Golden Summary                                       |
//+------------------------------------------------------------------+
void PrintSummary()
{
    if(g_summary_printed) return;
    PrintFormat("AAI_SUMMARY|entries=%d|wins=%d|losses=%d|ze_blk=%d|bc_blk=%d|smc_blk=%d|overext_blk=%d|spread_blk=%d|aspread_blk=%d|vr_blk=%d|news_blk=%d|sp_blk=%d|imc_blk=%d|risk_blk=%d|phw_blk=%d|slc_blk=%d",
                g_entries,
                g_wins,
                g_losses,
                g_blk_ze,
                g_blk_bc,
                g_blk_smc,
                g_blk_over,
                g_blk_spread,
                g_blk_aspread,
                g_blk_vr,
                g_blk_news,
                g_blk_sp,
                g_blk_imc,
                g_blk_risk,
                g_blk_phw,
                g_blk_slc);
    g_summary_printed = true;
}

//--- TICKET T021: New Caching Helper ---
bool UpdateSBCacheIfNewBar()
{
  datetime t = iTime(_Symbol, (ENUM_TIMEFRAMES)SignalTimeframe, 1);
  if(t == 0) return false;       // no history yet
// new: same bar → nothing to do; only return true on a NEW bar
if(g_sb.valid && g_sb.closed_bar_time == t)
    return false;

  // Read all 7 buffers for shift=1 in one shot
  double v;
  // Signal
  if(!Read1(sb_handle, 0, 1, v, "SB")) { g_sb.valid=false; return false; }
  g_sb.sig = (int)MathRound(v);
  // Confidence
  if(!Read1(sb_handle, 1, 1, v, "SB")) { g_sb.valid=false; return false; }
  g_sb.conf = v;
  // Reason
  if(!Read1(sb_handle, 2, 1, v, "SB")) { g_sb.valid=false; return false; }
  g_sb.reason = (int)MathRound(v);
  // ZE
  if(!Read1(sb_handle, 3, 1, v, "SB")) { g_sb.valid=false; return false; }
  g_sb.ze = v;
  // SMC signal
  if(!Read1(sb_handle, 4, 1, v, "SB")) { g_sb.valid=false; return false; }
  g_sb.smc_sig = (int)MathRound(v);
  // SMC conf
  if(!Read1(sb_handle, 5, 1, v, "SB")) { g_sb.valid=false; return false; }
  g_sb.smc_conf = v;
  // BC
  if(!Read1(sb_handle, 6, 1, v, "SB")) { g_sb.valid=false; return false; }
  g_sb.bc = (int)MathRound(v);

  g_sb.closed_bar_time = t;
  g_sb.valid = true;
  return true;
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
    CurrentTfLabel(),       // your helper, e.g., "M15", "H1", ...
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
//| T042: Telemetry v2 Emitter                                       |
//+------------------------------------------------------------------+
void Telemetry_OnBar()
{
    if(!TEL_Enable) return;
    if(g_sb.valid && g_sb.closed_bar_time == g_tel_lastbar) return;
    if(g_sb.valid) g_tel_lastbar = g_sb.closed_bar_time;
    g_tel_barcount++;

    if(TEL_EmitEveryN <= 0) return;
    if((g_tel_barcount % TEL_EmitEveryN) != 0) return;

    // --- Assemble a compact line
    const int    spr    = CurrentSpreadPoints();
    const double dd_abs = AAI_peak - AAI_curve;
    const double denom  = (AAI_peak != 0.0 ? MathAbs(AAI_peak) : 1.0);
    const double dd_pct = (denom > 0.0 ? 100.0 * (dd_abs / denom) : 0.0);
    const double rejr   = EA_RecentRejectRate();
    const int    devpts = g_last_dev_pts;

    // ECF multiplier calculation (mirrored from GateECF)
    double ecf_mult = 1.0;
    if(ECF_Enable) {
        if(dd_pct >= ECF_DD_SoftPct) {
            double t = MathMin(1.0, (dd_pct - ECF_DD_SoftPct) / MathMax(1e-9, (ECF_DD_HardPct - ECF_DD_SoftPct)));
            ecf_mult = 1.0 - t * (1.0 - ECF_MaxDnMult);
        } else if(AAI_trades >= ECF_MinTradesForBoost && g_ecf_ewma > 0.0) {
            double boost = (1.0 - MathMin(1.0, dd_pct / ECF_DD_SoftPct)) * (ECF_MaxUpMult - 1.0);
            ecf_mult = 1.0 + boost;
        }
    }

    string s = StringFormat("%s|t=%s|sym=%s|tf=%s|spr=%d|dev=%d|rej=%.2f|slip=%.1f|lat=%.0f|dd=%.2f|msm=%d:%.2f|ecf=%.2f",
                            TEL_Prefix,
                            TimeToString(g_sb.closed_bar_time, TIME_DATE|TIME_SECONDS),
                            _Symbol,
                            CurrentTfLabel(),
                            spr,
                            devpts,
                            rejr,
                            g_ea_state.ewma_slip_pts,
                            g_ea_state.ewma_latency_ms,
                            dd_pct,
                            g_msm_state, g_msm_mult,
                            ecf_mult
                           );

    if(TEL_LogVerbose) {
        int rem_phw = (int)MathMax(0, (long)g_phw_cool_until - TimeCurrent());
        int rem_slc = (int)MathMax(0, (long)MathMax(g_slc_cool_until_buy, g_slc_cool_until_sell) - TimeCurrent());
        s = StringFormat("%s|phw=%d|slc=%d|atrp=%.2f|adx=%.1f",
                         s, rem_phw, rem_slc, g_msm_pctl, g_msm_adx);
    }
    Print(s);
}

//+------------------------------------------------------------------+
//| T043: Parity Harness Emitter                                     |
//+------------------------------------------------------------------+
void ParityHarness_OnBar(const int direction,
                         const double conf_pre_gate,
                         const bool   allowed,
                         const string reason_id,
                         const int    dev_pts)
{
    if(!PTH_Enable) return;
    if(g_sb.closed_bar_time == g_pth_stamp) return; // once/bar
    g_pth_stamp = g_sb.closed_bar_time;
    g_pth_barcount++;

    if(PTH_EmitEveryN <= 0) return;
    if((g_pth_barcount % PTH_EmitEveryN) != 0) return;

    if(!g_pth_init) {
        g_pth_is_tester = (bool)MQLInfoInteger(MQL_TESTER);
        g_pth_is_opt    = (bool)MQLInfoInteger(MQL_OPTIMIZATION);
        g_pth_init = true;
    }

    // Stable, shift=1 data from MQL5 arrays
    double c1[1], h1[1], l1[1];
    CopyClose(_Symbol, _Period, 1, 1, c1);
    CopyHigh(_Symbol, _Period, 1, 1, h1);
    CopyLow(_Symbol, _Period, 1, 1, l1);
   
    const int spr = CurrentSpreadPoints();
    const string env = g_pth_is_tester ? (g_pth_is_opt ? "TEST_OPT" : "TEST") : "LIVE";

    // Pull existing module signals (already stored globally by prior tickets)
    const int    msm_state = g_msm_state;
    const double msm_mult  = g_msm_mult;
    const double dd_abs = AAI_peak - AAI_curve;
    const double denom  = (AAI_peak!=0.0 ? MathAbs(AAI_peak) : 1.0);
    const double dd_pct = (denom>0.0 ? 100.0*(dd_abs/denom) : 0.0);

    // One-line core (keep order stable)
    string core = StringFormat("t=%s|env=%s|sym=%s|tf=%s|c1=%.5f|h1=%.5f|l1=%.5f|spr=%d|pt=%.5f|dir=%d|conf=%.1f|msm=%d:%.3f|dd=%.2f|dev=%d|allow=%d|rsn=%s",
      TimeToString(g_sb.closed_bar_time, TIME_DATE|TIME_SECONDS),
      env, _Symbol, EnumToString((ENUM_TIMEFRAMES)_Period),
      c1[0], h1[0], l1[0], spr, _Point, direction, conf_pre_gate, msm_state, msm_mult, dd_pct, dev_pts, (int)allowed, reason_id);

    uint hash = FNV1a32(core);
   
    string final_log_string;
    if(PTH_LogVerbose) {
        final_log_string = StringFormat("%s|%s|hash=0x%08X", PTH_Prefix, core, hash);
    } else {
        // Short version as requested
        string short_core = StringFormat("t=%s|env=%s|c1=%.5f|spr=%d|dir=%d|conf=%.1f|msm=%d:%.3f|dd=%.2f|dev=%d|alw=%d|rsn=%s",
            TimeToString(g_sb.closed_bar_time, TIME_SECONDS),
            env, c1[0], spr, direction, conf_pre_gate, msm_state, msm_mult, dd_pct, dev_pts, (int)allowed, reason_id);
        final_log_string = StringFormat("%s|%s|h=0x%08X", PTH_Prefix, short_core, hash);
    }
    Print(final_log_string);
}


//+------------------------------------------------------------------+
//| T026: Decision Journaling CSV Helper                             |
//+------------------------------------------------------------------+
void DJ_Write(const int direction,
              const double conf_eff,
              const int sb_reason,
              const double ze_strength,
              const int bc_bias,
              const int smc_sig,
              const double smc_conf,
              const int vr_flag,
              const int news_flag,
              const int sp_flag,
              const int as_flag,
              const double as_cap_pts,
              const int as_hist_n,
              const int imc_flag,
              const double imc_support,
              const int rg_flag,
              const double rg_dd_pct,
              const double rg_dd_abs,
              const int rg_sls,
              const int rg_seq,
              const double spread_pts,
              const double lots,
              const double sl_pts,
              const double tp_pts,
              const double rr,
              const string entry_mode)
{
  if(!InpDJ_Enable) return;

  int flags = FILE_WRITE|FILE_READ|FILE_CSV|FILE_ANSI|FILE_COMMON;
  int h = FileOpen(InpDJ_FileName, flags);
  if(h == INVALID_HANDLE) return;

  // Write header if file is empty or we’re not appending
  if(FileSize(h) == 0 || !InpDJ_Append){
    FileSeek(h, 0, SEEK_SET);
    string header = "time,symbol,tf,dir,conf,sb_reason,ze_strength,bc_bias,smc_sig,smc_conf,vr_flag,news_flag,sp_flag,as_flag,as_cap_pts,as_histN,imc_flag,imc_support,rg_flag,rg_dd_pct,rg_dd_abs,rg_sls,rg_seq,spread_pts,lots,sl_pts,tp_pts,rr,entry_mode\r\n";
    FileWriteString(h, header);
  }

  // Always append a row at end
  FileSeek(h, 0, SEEK_END);

  datetime t = iTime(_Symbol, (ENUM_TIMEFRAMES)SignalTimeframe, 1); // closed bar time
  string tf  = TfLabel((ENUM_TIMEFRAMES)SignalTimeframe);

  string row = StringFormat("%s,%s,%s,%d,%.0f,%d,%.1f,%d,%d,%.1f,%d,%d,%d,%d,%.0f,%d,%d,%.2f,%d,%.2f,%.2f,%d,%d,%.0f,%.2f,%.0f,%.0f,%.2f,%s\r\n",
    TimeToString(t, TIME_DATE|TIME_SECONDS),
    _Symbol,
    tf,
    direction,
    conf_eff,
    sb_reason,
    ze_strength,
    bc_bias,
    smc_sig,
    smc_conf,
    vr_flag,
    news_flag,
    sp_flag,
    as_flag,
    as_cap_pts,
    as_hist_n,
    imc_flag,
    imc_support,
    rg_flag,
    rg_dd_pct,
    rg_dd_abs,
    rg_sls,
    rg_seq,
    spread_pts,
    lots,
    sl_pts,
    tp_pts,
    rr,
    entry_mode
  );

  FileWriteString(h, row);
  FileClose(h);
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
  else     { for(int h=a;h<24;h++) mask[h]=true;
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
    // Deprecated by AAI_Block which now handles its own journaling logic.
    // This function is kept for backward compatibility if called elsewhere, but should be empty.
}

//+------------------------------------------------------------------+
//| Centralized block counting and logging                           |
//+------------------------------------------------------------------+
void AAI_Block(const string reason)
{
    // Deprecated by new Gate functions which handle their own logging/counting
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
//| >>> T032: Confidence-to-Risk Curve Helpers <<<                   |
//+------------------------------------------------------------------+
double LotsFromRiskAndSL(const double risk_pct, const double sl_pts)
{
  // Guard
  if(sl_pts <= 0.0 || risk_pct <= 0.0) return 0.0;

  const double bal       = AccountInfoDouble(ACCOUNT_BALANCE);
  const double risk_money= bal * (risk_pct/100.0);

  const double tick_val  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
  const double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

  double point_value = 0.0;
  if(tick_val>0.0 && tick_size>0.0)
    point_value = tick_val * (point / tick_size);
  else
    point_value = tick_val; // fallback; many FX have tick_size==_Point

  if(point_value <= 0.0) return 0.0;

  const double risk_per_lot = sl_pts * point_value;
  if(risk_per_lot <= 0.0) return 0.0;

  double lots = risk_money / risk_per_lot;

  // Apply lot clamps if set
  if(InpCRC_MinLots > 0.0) lots = MathMax(lots, InpCRC_MinLots);
  if(InpCRC_MaxLots > 0.0) lots = MathMin(lots, InpCRC_MaxLots);

  return NormalizeLots(lots);
}

double CRC_MapConfToRisk(const int conf)
{
  const double c = (double)MathMax(0, MathMin(100, conf));
  const double rmin = MathMax(0.0, InpCRC_MinRiskPct);
  const double rmax = MathMax(rmin, InpCRC_MaxRiskPct);

  if(!InpCRC_Enable || InpCRC_Mode==CRC_OFF)
    return rmax;

  const double t = c/100.0;
  double r = rmin;

  switch(InpCRC_Mode)
  {
    case CRC_LINEAR:
    {
      const double c0 = (double)MathMax(0, MathMin(100, InpCRC_MinConfidence));
      if(c <= c0) r = rmin;
      else{
        const double frac = (c - c0) / (100.0 - c0);
        r = rmin + (rmax - rmin) * MathMax(0.0, MathMin(1.0, frac));
      }
      break;
    }
    case CRC_QUADRATIC:
    {
      const double a = MathMax(0.2, MathMin(2.0, InpCRC_QuadAlpha));
      r = rmin + (rmax - rmin) * MathPow(t, a);
      break;
    }
    case CRC_LOGISTIC:
    {
      const double k   = MathMax(0.01, InpCRC_LogisticSlope);
      const double mid = MathMax(0.0, MathMin(100.0, InpCRC_LogisticMid));
      const double x   = c - mid;
      const double s   = 1.0 / (1.0 + MathExp(-k * x));
      r = rmin + (rmax - rmin) * s;
      break;
    }
    case CRC_PIECEWISE:
    {
      int    C1 = MathMax(0,   MathMin(100, InpCRC_PW_C1));
      int    C2 = MathMax(C1,  MathMin(100, InpCRC_PW_C2));
      int    C3 = MathMax(C2,  MathMin(100, InpCRC_PW_C3));
      double R1 = MathMax(rmin, MathMin(rmax, InpCRC_PW_R1));
      double R2 = MathMax(rmin, MathMin(rmax, InpCRC_PW_R2));
      double R3 = MathMax(rmin, MathMin(rmax, InpCRC_PW_R3));

      if(c <= C1){
        double frac = (C1>0 ? c/(double)C1 : 1.0);
        r = rmin + (R1 - rmin) * frac;
      }else if(c <= C2){
        double frac = (C2>C1 ? (c - C1)/(double)(C2 - C1) : 1.0);
        r = R1 + (R2 - R1) * frac;
      }else if(c <= C3){
        double frac = (C3>C2 ? (c - C2)/(double)(C3 - C2) : 1.0);
        r = R2 + (R3 - R2) * frac;
      }else{
        double frac = (100>C3 ? (c - C3)/(double)(100 - C3) : 1.0);
        r = R3 + (rmax - R3) * frac;
      }
      break;
    }
  }

  if(InpCRC_MaxRiskMoney > 0.0)
  {
    const double bal = AccountInfoDouble(ACCOUNT_BALANCE);
    const double risk_money = bal * (r/100.0);
    if(risk_money > InpCRC_MaxRiskMoney)
      r = (InpCRC_MaxRiskMoney / MathMax(1e-9, bal)) * 100.0;
  }
  return r;
}

//+------------------------------------------------------------------+
//| Calculate Lot Size                                               |
//+------------------------------------------------------------------+

double CalculateLotSize(const int confidence, const double sl_distance_price)
{
  const double sl_pts = sl_distance_price / point;
  double risk_pct = CRC_MapConfToRisk(confidence);

  if(InpHEDGE_AllowMultiple && InpHEDGE_SplitRiskAcrossPyr && g_sb.sig!=0)
  {
     int L=0,S=0; CountMyPositions(_Symbol, (long)MagicNumber, L, S);
     const int sideCount = (g_sb.sig>0 ? L : S);
     if(sideCount>0) risk_pct = risk_pct / (1.0 + sideCount);
  }
  return LotsFromRiskAndSL(risk_pct, sl_pts);
}


//+------------------------------------------------------------------+
//| >>> T030: Risk Guard Helpers <<<                                 |
//+------------------------------------------------------------------+
void RG_ResetDay()
{
    MqlDateTime now;
    TimeToStruct(TimeCurrent(), now);

    // Calculate the most recent reset time
    MqlDateTime anchor_dt = now;
    anchor_dt.hour = InpRG_ResetHourServer;
    anchor_dt.min = 0;
    anchor_dt.sec = 0;

    datetime candidate_anchor = StructToTime(anchor_dt);
    if(candidate_anchor > TimeCurrent())
    {
        candidate_anchor -= 86400; // It's tomorrow's anchor, use yesterday's
    }

    g_rg_day_anchor_time = candidate_anchor;
    g_rg_day_start_balance = AccountInfoDouble(ACCOUNT_BALANCE);
    g_rg_day_realized_pl = 0.0;
    g_rg_day_sl_hits = 0;
    // g_rg_consec_losses persists across days unless reset by a win

    g_rg_block_active = false;
    g_rg_block_until = 0;
    PrintFormat("[RISK_GUARD] Day rolled over. Anchor: %s, Start Balance: %.2f", TimeToString(g_rg_day_anchor_time), g_rg_day_start_balance);
   
    // --- T041: Optional Daily Reset for MSM ---
    g_msm_atr_head = 0;
    g_msm_atr_count = 0;
    ArrayInitialize(g_msm_atr_hist, 0.0);
   
    // --- T042: Reset Telemetry Counter ---
    g_tel_barcount = 0;
   
    // --- T043: Reset Parity Harness Counter ---
    g_pth_barcount = 0;
}


//+------------------------------------------------------------------+
//| >>> T040: Execution Analytics Helpers <<<                        |
//+------------------------------------------------------------------+
void EA_ResetDay()
{
    // Reset rolling counters, keep EWMAs as they represent a longer-term profile.
    ArrayInitialize(g_ea_state.rej_history, 0);
    g_ea_state.rej_head = 0;
    g_ea_state.rej_count = 0;
}

double EA_RecentRejectRate()
{
    if(g_ea_state.rej_count == 0) return 0.0;
    int sum_rej = 0;
    for(int i = 0; i < g_ea_state.rej_count; i++)
    {
        sum_rej += g_ea_state.rej_history[i];
    }
    return (double)sum_rej / (double)g_ea_state.rej_count;
}

bool OSR_IsRejectRetcode(const uint retcode)
{
    switch(retcode)
    {
        case TRADE_RETCODE_REQUOTE:
        case TRADE_RETCODE_PRICE_OFF:
        case TRADE_RETCODE_PRICE_CHANGED: // Not in OSR_IsRetryable, but is a form of reject
        case TRADE_RETCODE_REJECT:
        case 10025: // TRADE_RETCODE_NO_CONNECTION
        case 10026: // TRADE_RETCODE_TRADE_CONTEXT_BUSY
            return true;
    }
    return false;
}

void EA_LogSendResult(const uint retcode)
{
    if(!EA_Enable) return;
    // Log 1 for a reject, 0 for a successful send.
    int result = OSR_IsRejectRetcode(retcode) ? 1 : 0;
    g_ea_state.rej_history[g_ea_state.rej_head] = result;
    g_ea_state.rej_head = (g_ea_state.rej_head + 1) % EA_RejWindowTrades;
    if(g_ea_state.rej_count < EA_RejWindowTrades)
    {
        g_ea_state.rej_count++;
    }
}

int EA_GetAdaptiveDeviation()
{
    if(!EA_Enable) return InpOSR_SlipPtsInitial;

    double dev_from_slip   = MathCeil(g_ea_state.ewma_slip_pts * EA_DevVsSlipMul);
    double dev_from_spread = MathCeil(CurrentSpreadPoints() * EA_DevVsSpreadFrac);
    double dev = MathMax(EA_BaseDeviationPts, MathMax(dev_from_slip, dev_from_spread));

    if(EA_RecentRejectRate() > 0.20) // Threshold for "elevated" rejects
    {
        dev += EA_RejBumpPts;
    }
    if(g_ea_state.ewma_latency_ms > EA_LatBumpMs)
    {
        dev += EA_LatBumpPts;
    }

    int final_dev = (int)MathMax(EA_MinDeviationPts, MathMin(EA_MaxDeviationPts, dev));

    if(EA_LogVerbose)
    {
        static datetime last_log_time = 0;
        if(g_sb.valid && g_sb.closed_bar_time != last_log_time)
        {
            PrintFormat("[EA] dev=%dpts slipEWMA=%.1f latEWMA=%.0fms rejRate=%.2f spread=%d",
                        final_dev, g_ea_state.ewma_slip_pts, g_ea_state.ewma_latency_ms,
                        EA_RecentRejectRate(), CurrentSpreadPoints());
            last_log_time = g_sb.closed_bar_time;
        }
    }
   
    g_last_dev_pts = final_dev; // T042: Store for telemetry
    return final_dev;
}
//+------------------------------------------------------------------+
//| T_AZ: Helper to check if we are inside the session window        |
//+------------------------------------------------------------------+
bool AZ_IsInsideSession(int &seconds_to_end)
{
    seconds_to_end = 2147483647; // Max int value
    if(!SessionEnable) return true; // If sessions aren't used, it's always "inside"

    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    long now_secs_of_day = dt.hour * 3600 + dt.min * 60 + dt.sec;
    
    long start_secs = (long)SessionStartHourServer * 3600;
    long end_secs   = (long)SessionEndHourServer * 3600;

    // Check if the current day is an active trading day
    bool day_on = ((dt.day_of_week==0 && AutoSun) || (dt.day_of_week==1 && AutoMon) || (dt.day_of_week==2 && AutoTue) ||
                   (dt.day_of_week==3 && AutoWed) || (dt.day_of_week==4 && AutoThu) || (dt.day_of_week==5 && AutoFri) ||
                   (dt.day_of_week==6 && AutoSat));
    if(!day_on) return false;
    
    // Handle normal vs. overnight sessions
    if (start_secs <= end_secs) // Normal session (e.g., 8:00 - 23:00)
    {
        if (now_secs_of_day >= start_secs && now_secs_of_day < end_secs)
        {
            seconds_to_end = (int)(end_secs - now_secs_of_day);
            return true;
        }
    }
    else // Overnight session (e.g., 22:00 - 05:00)
    {
        if (now_secs_of_day >= start_secs || now_secs_of_day < end_secs)
        {
            if (now_secs_of_day >= start_secs)
                seconds_to_end = (int)((end_secs + 86400) - now_secs_of_day);
            else
                seconds_to_end = (int)(end_secs - now_secs_of_day);
            return true;
        }
    }
    return false;
}


//+------------------------------------------------------------------+
//| Failsafe Exit Logic to catch orphaned trades                     |
//+------------------------------------------------------------------+
void FailsafeExitChecks()
{
    // Initialize CTrade object for this function's scope
    trade.SetExpertMagicNumber(MagicNumber);
    
    // Check session status once per call
    int seconds_to_end;
    bool is_inside_session = AZ_IsInsideSession(seconds_to_end);

    // Loop through all open positions to apply hard-exit rules
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i); // Safe way to get ticket
        if(PositionSelectByTicket(ticket))   // Safe way to select position
        {
            // Only manage positions for this symbol and magic number
            if(PositionGetString(POSITION_SYMBOL) == _Symbol && (long)PositionGetInteger(POSITION_MAGIC) == MagicNumber)
            {
                // --- AZ Failsafe 1: Time-To-Live (Max Duration) ---
                if(InpAZ_TTL_Enable && g_ttl_secs > 0)
                {
                    long open_time = PositionGetInteger(POSITION_TIME);
                    if((TimeCurrent() - open_time) >= g_ttl_secs)
                    {
                         PrintFormat("[AZ_TTL] Closing position #%d. Exceeded max duration of %d hours.", ticket, InpAZ_TTL_Hours);
                         if(!trade.PositionClose(ticket)) { PHW_LogFailure(trade.ResultRetcode()); }
                         continue; // Position is closed, move to the next one
                    }
                }

                // --- AZ Failsafe 2: Session Force-Flat ---
                if(InpAZ_SessionForceFlat)
                {
                    // Close if we are completely outside the session OR if we are inside but near the end
                    if(!is_inside_session || (is_inside_session && seconds_to_end <= g_pref_exit_secs))
                    {
                        PrintFormat("[AZ_SESSION] Closing position #%d. Outside session or within pre-exit window.", ticket);
                        if(!trade.PositionClose(ticket)) { PHW_LogFailure(trade.ResultRetcode()); }
                        continue; // Position is closed, move to the next one
                    }
                }
            }
        }
    }
}

//+------------------------------------------------------------------+
//| >>> T031: Order Send Robustness Helpers <<<                      |
//+------------------------------------------------------------------+
double NormalizeLots(double lots)
{
  double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
  double minv = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
  double maxv = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
  if(step > 0)
    lots = MathRound(lots/step) * step;
  lots = MathMax(minv, MathMin(maxv, lots));
  return lots;
}

double NormalizePriceByTick(double price)
{
  double tick = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
  if(tick <= 0.0) return NormalizeDouble(price, _Digits);
  // Snap to tick grid
  double n = MathRound(price / tick);
  return n * tick;
}

// Ensure SL/TP meet min stop & freeze constraints; push them away if needed.
// Returns true if OK; false if cannot satisfy constraints.
bool EnsureStopsDistance(const int direction, double &price, double &sl, double &tp)
{
  // Min stop distance in points
  int stops_level_pts = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
  double min_stop_dist = (double)stops_level_pts * _Point;

  // For market orders, compare to current bid/ask
  if(direction > 0) // BUY
  {
    if(sl > 0 && (price - sl) < min_stop_dist) sl = price - min_stop_dist;
    if(tp > 0 && (tp - price) < min_stop_dist) tp = price + min_stop_dist;
  }
  else // SELL
  {
    if(sl > 0 && (sl - price) < min_stop_dist) sl = price + min_stop_dist;
    if(tp > 0 && (price - tp) < min_stop_dist) tp = price - min_stop_dist;
  }

  // Normalize to tick grid
  if(sl > 0) sl = NormalizePriceByTick(sl);
  if(tp > 0) tp = NormalizePriceByTick(tp);
  price = NormalizePriceByTick(price);

  // Basic sanity
  if(direction > 0 && sl > 0 && sl >= price) return false;
  if(direction > 0 && tp > 0 && tp <= price) return false;
  if(direction < 0 && sl > 0 && sl <= price) return false;
  if(direction < 0 && tp > 0 && tp >= price) return false;

  return true;
}

// Retryable retcodes set (MT5). We retry only on transient price/flow issues.
bool OSR_IsRetryable(const uint retcode)
{
  switch(retcode)
  {
    case TRADE_RETCODE_REQUOTE:
    case TRADE_RETCODE_PRICE_OFF:
    case TRADE_RETCODE_REJECT:
    case TRADE_RETCODE_INVALID_FILL:     // allow adapting and retrying on fill-policy errors
    case 10025: // TRADE_RETCODE_NO_CONNECTION
    case 10026: // TRADE_RETCODE_TRADE_CONTEXT_BUSY
      return true;
  }
  return false;
}


//+------------------------------------------------------------------+
//| >>> T045: Multi-Symbol Orchestration Helpers <<<                 |
//+------------------------------------------------------------------+
ulong NowMs() { return (ulong)GetMicrosecondCount() / 1000ULL; }

bool GV_Get(const string key, double &val)
{
   if(!GlobalVariableCheck(key)) return false;
   val = GlobalVariableGet(key);
   return true;
}
void GV_Set(const string key, double val) { GlobalVariableSet(key,val); }

// Non-blocking attempt to acquire global lock
bool MSO_TryLock(const ulong now_ms)
{
   const string k = "AAI/MS/LOCK";
   double v=0.0;
   if(GV_Get(k,v))
   {
      if((ulong)v > now_ms) return false; // somebody holds it
   }
   GV_Set(k, (double)(now_ms + (ulong)MSO_LockTTLms));
   return true;
}

// Per-second bucket
bool MSO_BudgetOK(const ulong now_ms)
{
   datetime sec = (datetime)(now_ms/1000ULL);
   string k = StringFormat("AAI/MS/BKT_%I64d", (long)sec);
   double v=0.0;
   if(!GV_Get(k,v)) { GV_Set(k,1.0); return true; }
   if((int)v >= MSO_MaxSendsPerSec) return false;
   GV_Set(k, v+1.0);
   return true;
}

// Per-symbol spacing
bool MSO_SymbolGapOK(const string sym, const ulong now_ms)
{
   string k = "AAI/MS/LAST_" + sym;
   double v=0.0;
   if(GV_Get(k,v))
   {
      if(now_ms < (ulong)v + (ulong)MSO_MinMsBetweenSymbolSends) return false;
   }
   GV_Set(k, (double)now_ms);
   return true;
}

// Main guard: one-shot, non-blocking
bool MSO_MaySend(const string sym)
{
   if(!MSO_Enable) return true;
   const ulong now_ms = NowMs();

   if(!MSO_TryLock(now_ms))                      return false;
   if(!MSO_BudgetOK(now_ms))                     return false;
   if(!MSO_SymbolGapOK(sym, now_ms))             return false;

   return true;
}

//+------------------------------------------------------------------+
                ////             |
//+------------------------------------------------------------------+
// --- OSR helper: resolve a valid market fill mode for this symbol (IOC/FOK/RETURN)
ENUM_ORDER_TYPE_FILLING ResolveMarketFill(const int user_mode)
{
   // Some servers return a bitmask of allowed fills; some return a single enum value (0/1/2).
   const long fm = (long)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);

   // Treat both forms: bitmask (1<<ORDER_FILLING_*) OR exact equality.
   const bool ioc_ok = ((fm & (1 << ORDER_FILLING_IOC))    != 0) || (fm == ORDER_FILLING_IOC);
   const bool fok_ok = ((fm & (1 << ORDER_FILLING_FOK))    != 0) || (fm == ORDER_FILLING_FOK);
   const bool ret_ok = ((fm & (1 << ORDER_FILLING_RETURN)) != 0) || (fm == ORDER_FILLING_RETURN);

   // Respect user's choice when supported
   if(user_mode == OSR_FILL_IOC && ioc_ok) return ORDER_FILLING_IOC;
   if(user_mode == OSR_FILL_FOK && fok_ok) return ORDER_FILLING_FOK;

   // DEFAULT: use server’s declared policy first when it’s a single value
   if(user_mode == OSR_FILL_DEFAULT) {
      if(fm == ORDER_FILLING_IOC)    return ORDER_FILLING_IOC;
      if(fm == ORDER_FILLING_FOK)    return ORDER_FILLING_FOK;
      if(fm == ORDER_FILLING_RETURN) return ORDER_FILLING_RETURN;
      // Or pick a sensible preference when fm looked like a mask
      if(ioc_ok) return ORDER_FILLING_IOC;
      if(fok_ok) return ORDER_FILLING_FOK;
      if(ret_ok) return ORDER_FILLING_RETURN;
   }

   // Fallback preference: IOC -> FOK -> RETURN
   if(ioc_ok) return ORDER_FILLING_IOC;
   if(fok_ok) return ORDER_FILLING_FOK;
   if(ret_ok) return ORDER_FILLING_RETURN;

   // Ultimate fallback (rare)
   return ORDER_FILLING_FOK;
}

//+------------------------------------------------------------------+ 
//| >>> T031: Core OSR Sender (fail-open) <<<                        |
//+------------------------------------------------------------------+
bool OSR_SendMarket(const int direction,
                    double lots,
                    double &price_io,
                    double &sl_io,
                    double &tp_io,
                    MqlTradeResult &lastRes)
{
  ZeroMemory(lastRes);

  const datetime bt = iTime(_Symbol, (ENUM_TIMEFRAMES)_Period, 1);

  // --- SOFT guards (do not block sending)
  if(!MSO_MaySend(_Symbol))
  {
      if(MSO_LogVerbose && bt != g_stamp_mso)
      {
          PrintFormat("[MSO] guard (soft) sym=%s", _Symbol);
          g_stamp_mso = bt;
      }
      // continue
  }
  if(!T49_MayOpenThisBar(bt))
  {
      if(InpOSR_LogVerbose) Print("[T49] throttle (soft)");
      // continue
  }
  if(!T50_AllowedNow(bt))
  {
      if(InpOSR_LogVerbose) Print("[T50] window/off-hours (soft)");
      // continue
  }

  if(!InpOSR_Enable)
  {
    trade.SetTypeFillingBySymbol(_Symbol);
    trade.SetDeviationInPoints(EA_GetAdaptiveDeviation());
    const bool order_sent = (direction > 0)
                            ? trade.Buy(lots, _Symbol, 0.0, sl_io, tp_io, g_last_comment)
                            : trade.Sell(lots, _Symbol, 0.0, sl_io, tp_io, g_last_comment);
    trade.Result(lastRes);
    return order_sent;
  }

  int retries   = MathMax(0, InpOSR_MaxRetries);
  int deviation = EA_GetAdaptiveDeviation();

  for(int attempt=0; attempt<=retries; ++attempt)
  {
    if(InpOSR_RepriceOnRetry || attempt==0 || InpOSR_PriceMode==OSR_USE_CURRENT)
      price_io = (direction>0 ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                              : SymbolInfoDouble(_Symbol, SYMBOL_BID));

    const int dev_use = MathMin(deviation, InpOSR_SlipPtsMax);

    MqlTradeRequest req; ZeroMemory(req);
    ZeroMemory(lastRes);

    req.action        = TRADE_ACTION_DEAL;
    req.symbol        = _Symbol;
    req.volume        = NormalizeLots(lots);
    req.type          = (direction>0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
    req.type_filling  = ResolveMarketFill((int)InpOSR_FillMode);
    req.deviation     = (ulong)dev_use;
    req.magic         = MagicNumber;
    req.comment       = g_last_comment;

    double p = price_io, sl = sl_io, tp = tp_io;
    if(!EnsureStopsDistance(direction, p, sl, tp))
    {
      if(InpOSR_LogVerbose) Print("[OSR] stops violate constraints; giving up.");
      T50_RecordSendFailure(bt);
      return false;
    }
    req.price = p; req.sl = sl; req.tp = tp;

    // --- Preflight & fallback for fill policy
    MqlTradeCheckResult chk; ZeroMemory(chk);
    bool ok_check = OrderCheck(req, chk);

    if(!ok_check || chk.retcode != TRADE_RETCODE_DONE)
    {
       if(chk.retcode == TRADE_RETCODE_INVALID_FILL || !ok_check)
       {
          ENUM_ORDER_TYPE_FILLING broker_fill =
            (ENUM_ORDER_TYPE_FILLING)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
          if(broker_fill != req.type_filling)
          {
             req.type_filling = broker_fill;
             ZeroMemory(chk);
             ok_check = OrderCheck(req, chk);
          }

          if(!ok_check || chk.retcode != TRADE_RETCODE_DONE)
          {
             ENUM_ORDER_TYPE_FILLING alt =
               (req.type_filling == ORDER_FILLING_IOC ? ORDER_FILLING_FOK : ORDER_FILLING_IOC);
             req.type_filling = alt;
             ZeroMemory(chk);
             ok_check = OrderCheck(req, chk);
          }

          if(!ok_check || chk.retcode != TRADE_RETCODE_DONE)
          {
             if(InpOSR_LogVerbose)
                PrintFormat("[OSR] preflight fail: INVALID_FILL after fallbacks (mask=%ld)", 
                            (long)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE));
             T50_RecordSendFailure(bt);
             return false;
          }
       }
       // else: other precheck errors fall through to send
    }

    // --- Send
    if(InpOSR_LogVerbose)
      PrintFormat("[OSR] send dir=%d lots=%.2f price=%.5f fill=%d dev=%d",
                  direction, req.volume, req.price, (int)req.type_filling, (int)req.deviation);

    if(OrderSend(req, lastRes) &&
       (lastRes.retcode==TRADE_RETCODE_DONE || lastRes.retcode==TRADE_RETCODE_DONE_PARTIAL))
    {
      price_io = p; sl_io = sl; tp_io = tp;
      return true;
    }

    if(InpOSR_LogVerbose)
      PrintFormat("[OSR] OrderSend fail (attempt %d): ret=%u, dev=%d, price=%.5f",
                  attempt, lastRes.retcode, dev_use, p);

    if(!OSR_IsRetryable(lastRes.retcode))
    {
      T50_RecordSendFailure(bt);
      return false;
    }

    deviation += InpOSR_SlipPtsStep;
    if(InpOSR_RetryDelayMs > 0) Sleep(InpOSR_RetryDelayMs);
  }

  return false;
}


//+------------------------------------------------------------------+
//| >>> T033: SL/TP Safety Helpers <<<                               |
//+------------------------------------------------------------------+
int BrokerMinStopsPts()
{
  int s = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
  return MathMax(0, s);
}

bool SLTA_AdjustAndRescale(const int direction,
                           const double entry_price,
                           double &sl_price_io,
                           double &tp_price_io,
                           double &lots_io,
                           const int conf_for_sizing)
{
  if(!InpSLTA_Enable || InpSLTA_Mode==SLTA_OFF) return true;

  const int minStopsPts = BrokerMinStopsPts() + MathMax(0, InpSLTA_ExtraBufferPts);
  const double minStopsPx = minStopsPts * point;

  double sl_pts0 = (sl_price_io>0.0 ? MathAbs(entry_price - sl_price_io)/point : 0.0);
  double tp_pts0 = (tp_price_io>0.0 ? MathAbs(tp_price_io - entry_price)/point : 0.0);

  if(sl_pts0 <= 0.0){
    if(InpSLTA_LogVerbose) Print("[SLTA] No SL provided; cannot control risk - cancel.");
    return !InpSLTA_StrictCancel;
  }

  if(direction > 0){ // BUY: SL below entry
    double min_sl = entry_price - minStopsPx;
    if(sl_price_io <= 0.0 || sl_price_io >= min_sl)
      sl_price_io = min_sl;
  }else{           // SELL: SL above entry
    double min_sl = entry_price + minStopsPx;
    if(sl_price_io <= 0.0 || sl_price_io <= min_sl)
      sl_price_io = min_sl;
  }
  sl_price_io = NormalizePriceByTick(sl_price_io);
  double sl_pts1 = MathAbs(entry_price - sl_price_io)/point;

  if(sl_pts0 > 0.0 && InpSLTA_MaxWidenFrac > 0.0){
    double allowed = sl_pts0 * (1.0 + InpSLTA_MaxWidenFrac);
    if(sl_pts1 > allowed){
      if(InpSLTA_LogVerbose) PrintFormat("[SLTA] SL widening %.0f->%.0f pts exceeds limit (max %.0f).",
                                       sl_pts0, sl_pts1, allowed);
      return !InpSLTA_StrictCancel;
    }
  }

  double tp_pts1 = tp_pts0;
  if(tp_pts0 > 0.0){
    if(InpSLTA_Mode == SLTA_ADJUST_TP_KEEP_RR || InpSLTA_Mode == SLTA_SCALE_BOTH){
      double rr_target = MathMax(InpSLTA_MinRR, InpSLTA_TargetRR);
      double tp_needed = sl_pts1 * rr_target;
      tp_pts1 = MathMax(tp_pts0, tp_needed);
    }
    if(InpSLTA_MaxTPPts > 0 && tp_pts1 > InpSLTA_MaxTPPts) tp_pts1 = InpSLTA_MaxTPPts;

    double tp_px = (direction>0 ? entry_price + tp_pts1*point : entry_price - tp_pts1*point);
    tp_price_io = NormalizePriceByTick(tp_px);
    tp_pts1 = MathAbs(tp_price_io - entry_price)/point;
  }else{
    if(InpSLTA_Mode == SLTA_ADJUST_TP_KEEP_RR || InpSLTA_Mode == SLTA_SCALE_BOTH){
      double rr = MathMax(InpSLTA_MinRR, InpSLTA_TargetRR);
      tp_pts1 = sl_pts1 * rr;
      if(InpSLTA_MaxTPPts > 0 && tp_pts1 > InpSLTA_MaxTPPts) tp_pts1 = InpSLTA_MaxTPPts;
      double tp_px = (direction>0 ? entry_price + tp_pts1*point : entry_price - tp_pts1*point);
      tp_price_io = NormalizePriceByTick(tp_px);
      tp_pts1 = MathAbs(tp_price_io - entry_price)/point;
    }
  }

  if((InpSLTA_Mode == SLTA_ADJUST_TP_KEEP_RR || InpSLTA_Mode == SLTA_SCALE_BOTH) && InpSLTA_MinRR > 0.0 && tp_pts1 > 0.0){
    double rr_eff = (sl_pts1 > 0) ? tp_pts1 / sl_pts1 : 0;
    if(rr_eff + 1e-9 < InpSLTA_MinRR){
      if(InpSLTA_LogVerbose) PrintFormat("[SLTA] RR %.2f below MinRR %.2f after adjust - cancel.", rr_eff, InpSLTA_MinRR);
      return !InpSLTA_StrictCancel;
    }
  }

  double lots_new = CalculateLotSize(conf_for_sizing, sl_pts1 * point);
  if(lots_new <= 0.0){
    if(InpSLTA_LogVerbose) Print("[SLTA] Lot sizing failed after SL adjust - cancel.");
    return !InpSLTA_StrictCancel;
  }
  lots_io = lots_new;

  return true;
}


//+------------------------------------------------------------------+
//| >>> T034: Post-Fill Harmonizer Helpers <<<                       |
//+------------------------------------------------------------------+
bool HM_InsideFreezeBand(const string sym, const int direction, const double target_sl, const double target_tp)
{
  if(!InpHM_RespectFreeze) return false;
  int freeze_pts = (int)SymbolInfoInteger(sym, SYMBOL_TRADE_FREEZE_LEVEL);
  if(freeze_pts <= 0) return false;

  double bid = 0, ask = 0;
  SymbolInfoDouble(sym, SYMBOL_BID, bid);
  SymbolInfoDouble(sym, SYMBOL_ASK, ask);

  double freeze_px = freeze_pts * _Point;

  if(direction > 0){ // BUY
    if(target_sl>0 && (ask - target_sl) < freeze_px) return true;
    if(target_tp>0 && (target_tp - bid) < freeze_px) return true;
  }else{ // SELL
    if(target_sl>0 && (target_sl - bid) < freeze_px) return true;
    if(target_tp>0 && (ask - target_tp) < freeze_px) return true;
  }
  return false;
}

bool HM_SanitizeTargets(const string sym, const int direction, double &sl_io, double &tp_io)
{
  int minStopsPts = BrokerMinStopsPts();
  double minStopsPx = minStopsPts * _Point;
  double bid=0, ask=0; SymbolInfoDouble(sym, SYMBOL_BID, bid); SymbolInfoDouble(sym, SYMBOL_ASK, ask);

  // Ensure on correct side and outside min-stops from current quote
  if(direction > 0){ // BUY
    if(sl_io > 0) sl_io = MathMin(sl_io, ask - minStopsPx);
    if(tp_io > 0) tp_io = MathMax(tp_io, bid + minStopsPx);
  }else{ // SELL
    if(sl_io > 0) sl_io = MathMax(sl_io, bid + minStopsPx);
    if(tp_io > 0) tp_io = MathMin(tp_io, ask - minStopsPx);
  }

  if(sl_io > 0) sl_io = NormalizePriceByTick(sl_io);
  if(tp_io > 0) tp_io = NormalizePriceByTick(tp_io);

  // Sanity: SL/TP must still be on the correct side
  if(direction > 0){
    if(sl_io>0 && sl_io >= ask) return false;
    if(tp_io>0 && tp_io <= bid) return false;
  }else{
    if(sl_io>0 && sl_io <= bid) return false;
    if(tp_io>0 && tp_io >= ask) return false;
  }
  return true;
}

bool HM_ShouldModify(const double cur_sl, const double cur_tp,
                     const double tgt_sl, const double tgt_tp,
                     const int minChangePts)
{
  double dsl = ( (cur_sl<=0 || tgt_sl<=0) ? (cur_sl==tgt_sl ? 0.0 : DBL_MAX)
                                          : MathAbs(cur_sl - tgt_sl)/_Point );
  double dtp = ( (cur_tp<=0 || tgt_tp<=0) ? (cur_tp==tgt_tp ? 0.0 : DBL_MAX)
                                          : MathAbs(cur_tp - tgt_tp)/_Point );
  if(dsl==DBL_MAX && dtp==DBL_MAX) return true; // add/remove stops
  return (dsl >= minChangePts) || (dtp >= minChangePts);
}

void HM_Enqueue(const string sym, const long pos_ticket, const double sl_target, const double tp_target)
{
  if(!InpHM_Enable || InpHM_Mode==HM_OFF) return;
  HM_Task *t = new HM_Task;
  t.symbol = sym;
  t.pos_ticket = pos_ticket;
  t.sl_target = (sl_target>0 ? NormalizePriceByTick(sl_target) : 0.0);
  t.tp_target = (tp_target>0 ? NormalizePriceByTick(tp_target) : 0.0);
  t.retries_left = (InpHM_Mode==HM_ONESHOT_IMMEDIATE ? 0 : MathMax(0, InpHM_MaxRetries));
  int delay = (InpHM_Mode==HM_ONESHOT_IMMEDIATE ? 0 : MathMax(0, InpHM_DelayMs));
  t.next_try_time = TimeCurrent() + (delay/1000); // coarse to seconds for server time
  g_hm_tasks.Add(t);
}

void HM_OnTick()
{
  if(!InpHM_Enable || InpHM_Mode==HM_OFF) return;
  if(g_hm_tasks.Total()==0) return;

  int processed = 0;
  for(int i = g_hm_tasks.Total()-1; i >= 0 && processed < 3; --i)
  {
    HM_Task *t = (HM_Task*)g_hm_tasks.At(i);
    if(!t) { g_hm_tasks.Delete(i); continue; }
    if(TimeCurrent() < t.next_try_time) continue;

    bool have = PositionSelect(t.symbol);
    if(!have && t.pos_ticket>0) have = PositionSelectByTicket(t.pos_ticket);
    if(!have){ g_hm_tasks.Delete(i); delete t; continue; }

    int ptype = (int)PositionGetInteger(POSITION_TYPE);
    int direction = (ptype==POSITION_TYPE_BUY ? +1 : -1);
    double cur_sl = PositionGetDouble(POSITION_SL);
    double cur_tp = PositionGetDouble(POSITION_TP);

    if(!HM_ShouldModify(cur_sl, cur_tp, t.sl_target, t.tp_target, InpHM_MinChangePts)){
      g_hm_tasks.Delete(i); delete t; continue;
    }

    if(HM_InsideFreezeBand(t.symbol, direction, t.sl_target, t.tp_target)){
      t.next_try_time = TimeCurrent() + (MathMax(1, InpHM_BackoffMs)/1000);
      continue;
    }

    double sl = t.sl_target, tp = t.tp_target;
    if(!HM_SanitizeTargets(t.symbol, direction, sl, tp)){
      if(t.retries_left > 0){
        t.retries_left--;
        t.next_try_time = TimeCurrent() + (MathMax(1, InpHM_BackoffMs)/1000);
        continue;
      }else{
        if(InpHM_LogVerbose) Print("[HM] sanitize failed; giving up.");
        g_hm_tasks.Delete(i); delete t; continue;
      }
    }

    CTrade tr;
    tr.SetExpertMagicNumber(MagicNumber);
    
    if(!MSO_MaySend(t.symbol))
    {
       if(MSO_LogVerbose && g_sb.valid && g_sb.closed_bar_time != g_stamp_mso)
       {
          PrintFormat("[MSO] defer HM sym=%s reason=guard", t.symbol);
          g_stamp_mso = g_sb.closed_bar_time;
       }
       continue;
    }
    
    bool ok = tr.PositionModify(_Symbol, sl, tp);
    uint rc = tr.ResultRetcode();
    if(ok && (rc==TRADE_RETCODE_DONE)){
      if(InpHM_LogVerbose) Print("[HM] modify done.");
      g_hm_tasks.Delete(i); delete t; processed++; continue;
    }

    if(InpHM_LogVerbose) PrintFormat("[HM] modify fail ret=%u, retries_left=%d", rc, t.retries_left);
    // T037: Log failure for watchdog
    PHW_LogFailure(rc);

    bool retryable = OSR_IsRetryable(rc)
                     || (rc==TRADE_RETCODE_INVALID || rc==TRADE_RETCODE_INVALID_STOPS);

    if(t.retries_left > 0 && retryable){
      t.retries_left--;
      t.next_try_time = TimeCurrent() + (MathMax(1, InpHM_BackoffMs)/1000);
      processed++;
      continue;
    }else{
      g_hm_tasks.Delete(i); delete t; processed++; continue;
    }
  }
}//+------------------------------------------------------------------+
//| >>> T035: Trailing/BE Helpers <<<                                |
//+------------------------------------------------------------------+
TRL_State* TRL_GetState(const string sym, const bool create_if_missing = false)
{
  for(int i=0;i<g_trl_states.Total();++i){
    TRL_State *s = (TRL_State*)g_trl_states.At(i);
    if(s && s.symbol==sym) return s;
  }
  if(!create_if_missing) return NULL;
  TRL_State *ns = new TRL_State; ns.symbol = sym; g_trl_states.Add(ns); return ns;
}

void TRL_MaybeRollover(TRL_State &st)
{
  datetime now = TimeCurrent();
  if(st.day_anchor==0 || (now - st.day_anchor) >= 24*3600){
    st.day_anchor = now;
    st.moves_today = 0;
  }
}

double TRL_TightenSL(const int dir, const double cur_sl, const double candidate)
{
  if(candidate<=0.0) return 0.0;
  if(cur_sl<=0.0) return candidate;
  if(dir>0 && candidate > cur_sl + InpTRL_MinBumpPts*_Point) return candidate;
  if(dir<0 && candidate < cur_sl - InpTRL_MinBumpPts*_Point) return candidate;
  return 0.0;
}

bool TRL_GetATR(const string sym, const ENUM_TIMEFRAMES tf, const int period, double &atr_out)
{
  atr_out = 0.0;
  int handle = (tf==PERIOD_CURRENT) ? g_hATR_TRL : iATR(sym, tf, period);
  if(handle == INVALID_HANDLE) return false;

  double a[1];
  if(CopyBuffer(handle, 0, (InpTRL_OnBarClose?1:0), 1, a) != 1) return false;
  atr_out = a[0];

  if(tf != PERIOD_CURRENT) IndicatorRelease(handle);
  return (atr_out>0.0);
}

bool TRL_HHLL(const string sym, const ENUM_TIMEFRAMES tf, const int lookback, double &hh, double &ll)
{
  hh=0.0; ll=0.0;
  double H[], L[]; ArraySetAsSeries(H,true); ArraySetAsSeries(L,true);
  if(CopyHigh(sym, tf, (InpTRL_OnBarClose?1:0), lookback, H) != lookback) return false;
  if(CopyLow (sym, tf, (InpTRL_OnBarClose?1:0), lookback, L) != lookback) return false;

  int ih = ArrayMaximum(H, 0, WHOLE_ARRAY);
  int il = ArrayMinimum(L, 0, WHOLE_ARRAY);
  if(ih<0 || il<0) return false;
  hh = H[ih];
  ll = L[il];
  return true;
}

//+------------------------------------------------------------------+
//| >>> T035: Trailing/BE Worker <<<                                 |
//+------------------------------------------------------------------+
void TRL_OnTick()
{
  if(!InpTRL_Enable || InpTRL_Mode==TRL_OFF) return;
  if(!PositionSelect(_Symbol)) return;

  int    dir   = (int)PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY ? +1 : -1;
  double cur_sl= PositionGetDouble(POSITION_SL);
  double cur_tp= PositionGetDouble(POSITION_TP);
  double px_op = PositionGetDouble(POSITION_PRICE_OPEN);
  double px_c  = (InpTRL_OnBarClose ? iClose(_Symbol, (ENUM_TIMEFRAMES)SignalTimeframe, 1)
                                    : (dir>0 ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                                             : SymbolInfoDouble(_Symbol, SYMBOL_ASK)));

  TRL_State *st = TRL_GetState(_Symbol, true);
  st.direction    = dir;
  if(st.entry_price <= 0.0) st.entry_price = px_op;
  if(st.entry_sl_pts <= 0.0 && cur_sl>0.0) st.entry_sl_pts = MathAbs(px_op - cur_sl)/_Point;

  TRL_MaybeRollover(*st);
  if(InpTRL_MinSecondsBetween > 0 && (TimeCurrent() - st.last_mod_time) < InpTRL_MinSecondsBetween) return;
  if(InpTRL_MaxDailyMoves > 0 && st.moves_today >= InpTRL_MaxDailyMoves) return;

  // --- 1) Break-even?
  if(InpTRL_BE_Enable && !st.be_done){
    bool trigger = false;
    if(InpTRL_BE_TriggerRR > 0.0 && st.entry_sl_pts > 0.0){
      double rr = MathAbs(px_c - st.entry_price)/_Point / st.entry_sl_pts;
      if(rr >= InpTRL_BE_TriggerRR) trigger = true;
    }
    if(!trigger && InpTRL_BE_TriggerPts > 0){
      double prof_pts = (dir>0 ? (px_c - st.entry_price) : (st.entry_price - px_c))/_Point;
      if(prof_pts >= InpTRL_BE_TriggerPts) trigger = true;
    }

    if(trigger){
      double be_px = st.entry_price + (dir>0 ? +InpTRL_BE_OffsetPts*_Point : -InpTRL_BE_OffsetPts*_Point);
      double cand  = TRL_TightenSL(dir, cur_sl, be_px);
      if(cand > 0.0){
        HM_Enqueue(_Symbol, (long)PositionGetInteger(POSITION_TICKET), cand, cur_tp);
        st.be_done = true;
        st.last_mod_time = TimeCurrent();
        st.moves_today++;
        if(InpTRL_LogVerbose) Print("[TRL] BE move enqueued.");
        return;
      }else{
        st.be_done = true;
      }
    }
  }

  if(InpTRL_Mode==TRL_BE_ONLY) return;

  // --- 2) Trailing mode
  double target_sl = 0.0;

  if(InpTRL_Mode==TRL_ATR || InpTRL_Mode==TRL_CHANDELIER)
  {
    double atr;
    ENUM_TIMEFRAMES tf = (InpTRL_ATR_Timeframe==PERIOD_CURRENT ? (ENUM_TIMEFRAMES)SignalTimeframe : InpTRL_ATR_Timeframe);
    if(!TRL_GetATR(_Symbol, tf, InpTRL_ATR_Period, atr)) return;

    if(InpTRL_Mode==TRL_ATR){
      double off = InpTRL_ATR_Mult * atr;
      target_sl = (dir>0 ? px_c - off : px_c + off);
    }else{ // CHANDELIER
      double hh, ll;
      if(!TRL_HHLL(_Symbol, (ENUM_TIMEFRAMES)SignalTimeframe, InpTRL_AtrLookbackBars, hh, ll)) return;
      double off = InpTRL_ATR_Mult * atr;
      target_sl  = (dir>0 ? hh - off : ll + off);
    }
  }
  else if(InpTRL_Mode==TRL_SWING)
  {
    double sw_hi = FindRecentSwingHigh(InpTRL_SwingLookbackBars, InpTRL_SwingLeg);
    double sw_lo = FindRecentSwingLow(InpTRL_SwingLookbackBars, InpTRL_SwingLeg);
    if(dir>0 && sw_lo>0) target_sl = sw_lo - InpTRL_SwingBufferPts*_Point;
    if(dir<0 && sw_hi>0) target_sl = sw_hi + InpTRL_SwingBufferPts*_Point;
  }

  if(target_sl <= 0.0) return;

  double cand = TRL_TightenSL(dir, cur_sl, target_sl);
  if(cand <= 0.0) return;

  HM_Enqueue(_Symbol, (long)PositionGetInteger(POSITION_TICKET), cand, cur_tp);
  st.last_mod_time = TimeCurrent();
  st.moves_today++;
  if(InpTRL_LogVerbose) PrintFormat("[TRL] Trail enqueued: SL->%.5f", cand);
}


//+------------------------------------------------------------------+
//| >>> T036: Partial Take-Profit Helpers <<<                        |
//+------------------------------------------------------------------+
bool PT_Progress(const TRL_State &st, const int dir, const double cur_price, double &rr_out, double &profit_pts_out)
{
  rr_out = 0.0; profit_pts_out = 0.0;
  if(st.entry_sl_pts <= 0.0 || st.entry_price <= 0.0) return false;
  double move_pts = (dir>0 ? (cur_price - st.entry_price) : (st.entry_price - cur_price))/_Point;
  profit_pts_out = move_pts;
  rr_out = (st.entry_sl_pts>0.0 ? (move_pts / st.entry_sl_pts) : 0.0);
  return true;
}

bool PT_StepTriggered(const double rr, const double prof_pts, const double rr_thr, const int pts_thr)
{
  if(rr_thr > 0.0 && rr >= rr_thr) return true;
  if(pts_thr > 0   && prof_pts >= pts_thr) return true;
  return false;
}

double PT_LotsToClose(const TRL_State &st, const double step_pct, const double cur_pos_lots)
{
  if(st.entry_lots <= 0.0 || step_pct <= 0.0) return 0.0;
  double intended_close_for_step = st.entry_lots * (step_pct/100.0);
  // This logic seems incorrect in the ticket, it should be based on total original lots, not what's left.
  // Correcting based on "portion of ORIGINAL entry lots"
  double already_closed_by_pt = st.pt_closed_lots;
  double total_to_be_closed_at_this_step = st.entry_lots * (step_pct/100.0);

  // The logic in the ticket `intended_total_for_step - st.pt_closed_lots` is incorrect.
  // It should be based on the cumulative percentage.
  // Let's re-read: "% of ORIGINAL entry lots to close".
  // Let's assume the percentages are additive. So step 2's 33% is on top of step 1.
  // This means the ticket's logic might be right after all if we consider step_pct is *the amount to close for this specific step*.
  // Let's stick to the ticket's provided logic.
  double lots_for_this_step = st.entry_lots * (step_pct / 100.0);
  return MathMin(lots_for_this_step, cur_pos_lots);
}

void PT_ApplySLA(const int dir, const ENUM_PT_SLA sla_mode, const int offset_pts,
                 const double entry_price, const double cur_tp)
{
  if(sla_mode == PT_SLA_NONE) return;
  double new_sl = entry_price + (dir>0 ? +offset_pts*_Point : -offset_pts*_Point);
  // HM_Enqueue can take 0 for ticket to select by symbol
  HM_Enqueue(_Symbol, 0, new_sl, cur_tp);
}

//+------------------------------------------------------------------+
//| >>> T036: Partial Take-Profit Worker <<<                         |
//+------------------------------------------------------------------+
void PT_OnTick()
{
  if(!InpPT_Enable) return;
  if(!PositionSelect(_Symbol)) return;

  int dir = (int)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? +1 : -1;
  double cur_sl = PositionGetDouble(POSITION_SL);
  double cur_tp = PositionGetDouble(POSITION_TP);
  double cur_vol= PositionGetDouble(POSITION_VOLUME);

  // Price source discipline
  double px = (InpPT_OnBarClose ? iClose(_Symbol, (ENUM_TIMEFRAMES)SignalTimeframe, 1)
                                : (dir>0 ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                                         : SymbolInfoDouble(_Symbol, SYMBOL_ASK)));

  TRL_State *st = TRL_GetState(_Symbol, true);
  if(st.entry_price  <= 0.0) st.entry_price  = PositionGetDouble(POSITION_PRICE_OPEN);
  if(st.entry_lots   <= 0.0) st.entry_lots   = cur_vol + st.pt_closed_lots; // Reconstruct original lots if needed
  if(st.entry_sl_pts <= 0.0 && cur_sl>0.0) st.entry_sl_pts = MathAbs(st.entry_price - cur_sl)/_Point;

  // Throttle per symbol
  if(InpPT_MinSecondsBetween > 0 && (TimeCurrent() - st.last_mod_time) < InpPT_MinSecondsBetween) return;

  double rr=0.0, prof_pts=0.0;
  if(!PT_Progress(*st, dir, px, rr, prof_pts)) return;

  struct StepCfg { bool en; double rr; int pts; double pct; ENUM_PT_SLA sla; int off; int id; };
  StepCfg steps[3] = {
    { InpPT1_Enable, InpPT1_TriggerRR, InpPT1_TriggerPts, InpPT1_ClosePct, InpPT1_SLA, InpPT1_SLA_OffsetPts, 1 },
    { InpPT2_Enable, InpPT2_TriggerRR, InpPT2_TriggerPts, InpPT2_ClosePct, InpPT2_SLA, InpPT2_SLA_OffsetPts, 2 },
    { InpPT3_Enable, InpPT3_TriggerRR, InpPT3_TriggerPts, InpPT3_ClosePct, InpPT3_SLA, InpPT3_SLA_OffsetPts, 3 }
  };

  for(int i=0;i<3;i++)
  {
    bool step_done = (steps[i].id==1 ? st.pt1_done : (steps[i].id==2 ? st.pt2_done : st.pt3_done));
    if(!steps[i].en || step_done) continue;
    if(!PT_StepTriggered(rr, prof_pts, steps[i].rr, steps[i].pts)) continue;

    // The logic for lots to close in the ticket is tricky.
    // It says "% of ORIGINAL entry lots".
    // If PT1 closes 33% and PT2 closes 33%, the total closed is 66% of original.
    // Let's implement it to be cumulative friendly.
    double total_lots_to_close_so_far = st.entry_lots * (steps[i].pct/100.0);
    double lots_to_close_now = total_lots_to_close_so_far - st.pt_closed_lots;
   
    // The ticket provided a specific helper `PT_LotsToClose`.
    // I will use that helper instead of my re-interpretation to stick to the spec.
    double lots_to_close = PT_LotsToClose(*st, steps[i].pct, cur_vol);
    lots_to_close = NormalizeLots(lots_to_close);

    if(lots_to_close <= 0.0)
    {
        // This can happen if a previous step already closed more than this step's cumulative %,
        // or if remaining volume is zero. Mark as done and continue.
        if(steps[i].id==1) st.pt1_done = true; else if(steps[i].id==2) st.pt2_done = true; else st.pt3_done = true;
        continue;
    }

    // Reduce net position with opposite-side market (OSR manages retries/slippage)
    MqlTradeResult tRes;
    double p=0.0, sl=0.0, tp=0.0; // no SL/TP on the reducing deal
    int opp_dir = -dir;
    g_last_comment = "PT Step " + IntegerToString(i+1); // Add a comment for clarity
    bool ok = OSR_SendMarket(opp_dir, lots_to_close, p, sl, tp, tRes);
    if(!ok){
      if(InpPT_LogVerbose) PrintFormat("[PT] step %d send fail ret=%u lots=%.2f", i+1, tRes.retcode, lots_to_close);
      // T037: Log failure for watchdog
      PHW_LogFailure(tRes.retcode);
      // T040: Log execution result
      EA_LogSendResult(tRes.retcode);
      return; // keep conditions; try again next eligible tick
    }
    // T040: Log execution result
    EA_LogSendResult(tRes.retcode);

    // Update state
    double filled = (tRes.volume > 0.0 ? tRes.volume : lots_to_close);
    st.pt_closed_lots += filled;
    if(steps[i].id==1) st.pt1_done = true; else if(steps[i].id==2) st.pt2_done = true; else st.pt3_done = true;

    // Optional SL bump
    PT_ApplySLA(dir, steps[i].sla, steps[i].off, st.entry_price, cur_tp);

    st.last_mod_time = TimeCurrent();
    if(InpPT_LogVerbose)
      PrintFormat("[PT] step %d done: rr=%.2f pts=%.0f closed=%.2f (cum=%.2f/%.2f)",
                  i+1, rr, prof_pts, filled, st.pt_closed_lots, st.entry_lots);
    return; // one action per tick
  }
}
//... (rest of the file is identical) ...

//+------------------------------------------------------------------+
//| >>> T044: State Persistence (SP v1) Helpers <<<                  |
//+------------------------------------------------------------------+
string SP_FileName()
{
    string prog = MQLInfoString(MQL_PROGRAM_NAME);
    StringReplace(prog, ".ex5", ""); // Clean up name
    return StringFormat("%s_%s_%d_%s_%s.spv",
                        SP_FilePrefix,
                        prog,
                        (int)AccountInfoInteger(ACCOUNT_LOGIN),
                        _Symbol,
                        TfLabel((ENUM_TIMEFRAMES)_Period));
}

string EA_RejectHistoryToString()
{
    string s = "";
    if (g_ea_state.rej_count > 0) {
        for (int i = 0; i < g_ea_state.rej_count; i++) {
            s += IntegerToString(g_ea_state.rej_history[i]);
        }
    }
    return s;
}

void EA_RejectHistoryFromString(const string s)
{
    ArrayInitialize(g_ea_state.rej_history, 0);
    int len = StringLen(s);

    // Do NOT set rej_count here. The caller (SP_Load) does it.

    for(int i = 0; i < len && i < EA_RejWindowTrades; i++) {
        g_ea_state.rej_history[i] = (int)StringToInteger(StringSubstr(s, i, 1));
    }
}

bool SP_Save(bool force)
{
    if(!SP_Enable) return false;
    if(!force && (SP_WriteEveryN <= 0 || (g_sp_barcount % SP_WriteEveryN) != 0)) return false;

    string rej_hist_str = EA_RejectHistoryToString();
    string core = StringFormat("ST|ver=%d|t=%s|sym=%s|tf=%s|"
                               "phw_until=%I64d|phw_rep=%d|"
                               "slc_b_until=%I64d|slc_s_until=%I64d|slc_b_rep=%d|slc_s_rep=%d|"
                               "ea_slip=%.4f|ea_lat=%.2f|ea_dev=%d|rej_head=%d|rej_cnt=%d|rej=%s|"
                               "ecf_ewma=%.4f|curve=%.2f|peak=%.2f|day=%I64d",
                               SP_Version, TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS), _Symbol, TfLabel((ENUM_TIMEFRAMES)_Period),
                               (long)g_phw_cool_until, g_phw_repeats_today,
                               (long)g_slc_cool_until_buy, (long)g_slc_cool_until_sell, g_slc_repeats_buy, g_slc_repeats_sell,
                               g_ea_state.ewma_slip_pts, g_ea_state.ewma_latency_ms, g_last_dev_pts, g_ea_state.rej_head, g_ea_state.rej_count, rej_hist_str,
                               g_ecf_ewma, AAI_curve, AAI_peak, (long)g_rg_day_anchor_time);

    uint hash = FNV1a32(core);
    string final_line = StringFormat("%s|h=0x%08X", core, hash);

    string fn = SP_FileName();
    int h = FileOpen(fn, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
    if (h == INVALID_HANDLE) {
        if(SP_LogVerbose) PrintFormat("[SP] Save failed to open %s", fn);
        return false;
    }
    FileWriteString(h, final_line + "\r\n");
    FileClose(h);
    if(SP_LogVerbose) PrintFormat("[SP] State saved to %s", fn);
    return true;
}

bool SP_Load()
{
    if(!SP_Enable) return false;
    if(MQLInfoInteger(MQL_TESTER) && !SP_LoadInTester) return false;

    string fn = SP_FileName();
    if(!FileIsExist(fn, FILE_COMMON)) {
        if(SP_LogVerbose) PrintFormat("[SP] No state file found at %s", fn);
        return false;
    }

    int h = FileOpen(fn, FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON);
    if (h == INVALID_HANDLE) {
        if(SP_LogVerbose) PrintFormat("[SP] Load failed to open %s", fn);
        return false;
    }
    string line = FileReadString(h);
    FileClose(h);
    StringTrimRight(line);

    int p_hash = StringFind(line, "|h=0x", 0);
    if(p_hash < 0) return false;
    string core = StringSubstr(line, 0, p_hash);
    string hash_str = StringSubstr(line, p_hash + 4);
    uint file_hash = (uint)StringToInteger("0x"+hash_str);
    uint calc_hash = FNV1a32(core);

    if(file_hash != calc_hash) {
        if(SP_LogVerbose) PrintFormat("[SP] Hash mismatch. File: 0x%08X, Calc: 0x%08X", file_hash, calc_hash);
        return false;
    }

    datetime loaded_day_anchor = 0;

    string parts[];
    int n = StringSplit(core, '|', parts);
    for(int i=0; i<n; i++) {
        string kv[];
        if(StringSplit(parts[i], '=', kv) != 2) continue;
        string k = kv[0];
        string v = kv[1];

        if(k=="ver" && (int)StringToInteger(v) != SP_Version) { if(SP_LogVerbose) Print("[SP] Version mismatch"); return false; }
        if(k=="sym" && v != _Symbol) { if(SP_LogVerbose) Print("[SP] Symbol mismatch"); return false; }
        if(k=="tf" && v != TfLabel((ENUM_TIMEFRAMES)_Period)) { if(SP_LogVerbose) Print("[SP] Timeframe mismatch"); return false; }

        if(k=="phw_until")   g_phw_cool_until = (datetime)StringToInteger(v);
        if(k=="phw_rep")     g_phw_repeats_today = (int)StringToInteger(v);
        if(k=="slc_b_until") g_slc_cool_until_buy = (datetime)StringToInteger(v);
        if(k=="slc_s_until") g_slc_cool_until_sell = (datetime)StringToInteger(v);
        if(k=="slc_b_rep")   g_slc_repeats_buy = (int)StringToInteger(v);
        if(k=="slc_s_rep")   g_slc_repeats_sell = (int)StringToInteger(v);
        if(k=="ea_slip")     g_ea_state.ewma_slip_pts = StringToDouble(v);
        if(k=="ea_lat")      g_ea_state.ewma_latency_ms = StringToDouble(v);
        if(k=="ea_dev")      g_last_dev_pts = (int)StringToInteger(v);
        if(k=="rej_head")    g_ea_state.rej_head = (int)StringToInteger(v);
        if(k=="rej_cnt")     g_ea_state.rej_count = (int)StringToInteger(v);
        if(k=="rej")         EA_RejectHistoryFromString(v);
        if(k=="ecf_ewma")    g_ecf_ewma = StringToDouble(v);
        if(k=="curve")       AAI_curve = StringToDouble(v);
        if(k=="peak")        AAI_peak = StringToDouble(v);
        if(k=="day")         loaded_day_anchor = (datetime)StringToInteger(v);
    }
   
    datetime now = TimeCurrent();
    if(g_phw_cool_until < now) g_phw_cool_until = 0;
    if(g_slc_cool_until_buy < now) g_slc_cool_until_buy = 0;
    if(g_slc_cool_until_sell < now) g_slc_cool_until_sell = 0;
   
    // Check if the loaded day anchor corresponds to a different day than now.
    MqlDateTime dt_now; TimeToStruct(now, dt_now);
    MqlDateTime dt_anchor; TimeToStruct(loaded_day_anchor, dt_anchor);
    if(dt_now.year != dt_anchor.year || dt_now.mon != dt_anchor.mon || dt_now.day != dt_anchor.day) {
        g_phw_repeats_today = 0;
        g_slc_repeats_buy = 0;
        g_slc_repeats_sell = 0;
        if(SP_LogVerbose) Print("[SP] Day changed since last state, backoff counters reset.");
    }

    if(SP_LogVerbose) PrintFormat("[SP] State loaded successfully from %s", fn);
    return true;
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
   g_blk_aspread = 0;
   g_blk_news = 0;
   g_blk_vr = 0;
   g_blk_sp = 0;
   g_blk_imc = 0;
   g_blk_risk = 0;
   g_blk_phw = 0; // T037
   g_blk_slc = 0; // T039
   g_summary_printed = false;
   g_sb.valid = false; // Initialize cache as invalid
   
   // ... inside OnInit() ...
// --- T_AZ: Initialize Auto-Zone cached variables ---
g_ttl_secs = InpAZ_TTL_Hours * 3600;
g_pref_exit_secs = InpAZ_PrefExitMins * 60;

// --- Initialize locals/state ---
symbolName = _Symbol;
point      = SymbolInfoDouble(symbolName, SYMBOL_POINT);
trade.SetExpertMagicNumber(MagicNumber);
g_overext_wait = 0;
g_last_entry_bar_buy  = 0;
g_last_entry_bar_sell = 0;
g_cool_until_buy  = 0;
g_cool_until_sell = 0;

// --- T028: Init Adaptive Spread state ---
ArrayResize(g_as_bar_medians, MathMax(1, InpAS_WindowBars));
g_as_hist_count = 0; g_as_hist_pos = 0;
ArrayResize(g_as_samples, 0);
g_as_tick_ctr = 0;
g_as_forming_bar_time = iTime(_Symbol, (ENUM_TIMEFRAMES)SignalTimeframe, 0);

// --- T030: Init Risk Guard state ---
RG_ResetDay();
g_rg_consec_losses = 0; // Full reset on init

// --- T034: Init Harmonizer state ---
g_hm_tasks.Clear();

// --- T035: Init Trailing State ---
g_trl_states.Clear();

// --- T037: Init Position Health Watchdog state ---
g_phw_day_anchor = 0;
g_phw_cool_until = 0;
g_phw_repeats_today = 0;
ArrayResize(g_phw_fail_timestamps, 0);
g_phw_fail_count = 0;

// --- T038: Init Equity Curve Feedback state ---
g_ecf_ewma = 0.0;
g_stamp_ecf = 0;

// --- T039: Init SL Cluster state ---
ArrayResize(g_slc_history_buy, SLC_History);
ArrayResize(g_slc_history_sell, SLC_History);
g_slc_head_buy = 0; g_slc_head_sell = 0;
g_slc_count_buy = 0; g_slc_count_sell = 0;
g_slc_cool_until_buy = 0; g_slc_cool_until_sell = 0;
g_slc_repeats_buy = 0; g_slc_repeats_sell = 0;
g_slc_day_anchor = 0;

// --- T040: Init Execution Analytics state ---
g_ea_state.ewma_slip_pts = 0.0;
g_ea_state.ewma_latency_ms = 0.0;
ArrayInitialize(g_ea_state.rej_history, 0);
g_ea_state.rej_head = 0;
g_ea_state.rej_count = 0;
g_ea_state.last_send_ticks = 0;
g_ea_state.last_req_price = 0.0;

// --- T041: Init Market State Model ---
g_stamp_msm = 0;
g_msm_atr_head = 0;
g_msm_atr_count = 0;
ArrayInitialize(g_msm_atr_hist, 0.0);

// --- T044: Load persisted state ---
SP_Load();

// --- TICKET #2: Create the single, centralized SignalBrain handle ---
sb_handle = iCustom(_Symbol, (ENUM_TIMEFRAMES)SignalTimeframe, AAI_Ind("AAI_Indicator_SignalBrain"),
                  // Core SB Settings
                  SB_SafeTest, SB_UseZE, SB_UseBC, SB_UseSMC,
                  SB_WarmupBars, SB_FastMA, SB_SlowMA,
                  SB_MinZoneStrength, SB_EnableDebug,
                  // SB Confidence Model
                  SB_Bonus_ZE, SB_Bonus_BC, SB_Bonus_SMC,
                  SB_BaseConf,
                  // BC Pass-Through
                  SB_BC_FastMA, SB_BC_SlowMA,
                  // ZE Pass-Through
                  SB_ZE_MinImpulseMovePips,
                  // SMC Pass-Through
                  SB_SMC_UseFVG, SB_SMC_UseOB, SB_SMC_UseBOS,
                  SB_SMC_FVG_MinPips, SB_SMC_OB_Lookback, SB_SMC_BOS_Lookback
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

    // --- T022: Initialize Volatility Regime handle ---
    g_hATR_VR = iATR(_Symbol, (ENUM_TIMEFRAMES)SignalTimeframe, InpVR_ATR_Period);
    if(g_hATR_VR == INVALID_HANDLE) { PrintFormat("%s Failed to create Volatility Regime ATR handle", INIT_ERROR); return(INIT_FAILED); }

    // --- T027: Initialize Structure Proximity handle ---
    if(InpSP_Enable && InpSP_UseATR)
    {
      g_hATR_SP = iATR(_Symbol, (ENUM_TIMEFRAMES)SignalTimeframe, InpSP_ATR_Period);
      if(g_hATR_SP == INVALID_HANDLE) { PrintFormat("%s Failed to create Structure Proximity ATR handle", INIT_ERROR); return(INIT_FAILED); }
    }

    // --- T035: Initialize Trailing ATR Handle ---
    if((InpTRL_Mode == TRL_ATR || InpTRL_Mode == TRL_CHANDELIER) && InpTRL_ATR_Timeframe == PERIOD_CURRENT)
    {
      g_hATR_TRL = iATR(_Symbol, (ENUM_TIMEFRAMES)SignalTimeframe, InpTRL_ATR_Period);
      if(g_hATR_TRL == INVALID_HANDLE) { PrintFormat("%s Failed to create Trailing ATR handle", INIT_ERROR); return(INIT_FAILED); }
    }
   
    // --- T041: Initialize MSM handles ---
    g_hMSM_ATR = iATR(_Symbol, (ENUM_TIMEFRAMES)SignalTimeframe, MSM_ATR_Period);
    if(g_hMSM_ATR == INVALID_HANDLE) { PrintFormat("%s Failed to create MSM ATR handle", INIT_ERROR); return(INIT_FAILED); }

    g_hMSM_ADX = iADX(_Symbol, (ENUM_TIMEFRAMES)SignalTimeframe, MSM_ADX_Period);
    if(g_hMSM_ADX == INVALID_HANDLE) { PrintFormat("%s Failed to create MSM ADX handle", INIT_ERROR); return(INIT_FAILED); }

    g_hMSM_EMA_Fast = iMA(_Symbol, (ENUM_TIMEFRAMES)SignalTimeframe, MSM_EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
    if(g_hMSM_EMA_Fast == INVALID_HANDLE) { PrintFormat("%s Failed to create MSM Fast EMA handle", INIT_ERROR); return(INIT_FAILED); }

    g_hMSM_EMA_Slow = iMA(_Symbol, (ENUM_TIMEFRAMES)SignalTimeframe, MSM_EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
    if(g_hMSM_EMA_Slow == INVALID_HANDLE) { PrintFormat("%s Failed to create MSM Slow EMA handle", INIT_ERROR); return(INIT_FAILED); }

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

    // --- Initialize News Gate ---
    g_newsGate.Init(InpNews_Enable, InpNews_CsvName, InpNews_Mode, InpNews_TimesAreUTC,
                    InpNews_FilterHigh, InpNews_FilterMedium, InpNews_FilterLow, InpNews_PrefPenalty);

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
SP_Save(true); // T044: Save state on deinit

for(int i = g_hm_tasks.Total()-1; i >= 0; --i){ delete (HM_Task*)g_hm_tasks.At(i); }
g_hm_tasks.Clear();

for(int i = g_trl_states.Total()-1; i >= 0; --i){ delete (TRL_State*)g_trl_states.At(i); }
g_trl_states.Clear();


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

    // --- Release all handles ---
    if(sb_handle != INVALID_HANDLE) IndicatorRelease(sb_handle);
    if(g_hATR != INVALID_HANDLE) IndicatorRelease(g_hATR);
    if(g_hOverextMA != INVALID_HANDLE) IndicatorRelease(g_hOverextMA);
    if(g_hATR_VR != INVALID_HANDLE) IndicatorRelease(g_hATR_VR);
    if(g_hATR_SP != INVALID_HANDLE) IndicatorRelease(g_hATR_SP);
    if(g_hATR_TRL != INVALID_HANDLE) IndicatorRelease(g_hATR_TRL);
    // T041
    if(g_hMSM_ATR != INVALID_HANDLE) IndicatorRelease(g_hMSM_ATR);
    if(g_hMSM_ADX != INVALID_HANDLE) IndicatorRelease(g_hMSM_ADX);
    if(g_hMSM_EMA_Fast != INVALID_HANDLE) IndicatorRelease(g_hMSM_EMA_Fast);
    if(g_hMSM_EMA_Slow != INVALID_HANDLE) IndicatorRelease(g_hMSM_EMA_Slow);

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
    if(!MSO_MaySend(_Symbol))
    {
       if(MSO_LogVerbose && g_sb.valid && g_sb.closed_bar_time != g_stamp_mso)
       {
          PrintFormat("[MSO] defer Hybrid sym=%s reason=guard", _Symbol);
          g_stamp_mso = g_sb.closed_bar_time;
       }
       return;
    }

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
//| >>> T039: SL Cluster Event Processor <<<                         |
//+------------------------------------------------------------------+
void SLC_ProcessEvent(int original_direction, double sl_price, datetime sl_time)
{
    if(!SLC_Enable) return;

    // --- Select direction-specific buffers and state ---
    if(original_direction > 0) // Buy trade was stopped out
    {
        // Push to ring buffer
        g_slc_history_buy[g_slc_head_buy].price = sl_price;
        g_slc_history_buy[g_slc_head_buy].time = sl_time;
        g_slc_head_buy = (g_slc_head_buy + 1) % SLC_History;
        if(g_slc_count_buy < SLC_History) g_slc_count_buy++;

        // Check for cluster
        int cluster_size = 0;
        for(int i = 0; i < g_slc_count_buy; i++)
        {
            if(MathAbs(g_slc_history_buy[i].price - sl_price) <= SLC_ClusterPoints * _Point &&
               (sl_time - g_slc_history_buy[i].time) <= SLC_ClusterWindowSec)
            {
                cluster_size++;
            }
        }

        // Trigger cooldown if cluster detected
        if(cluster_size >= SLC_MinEvents)
        {
            g_slc_repeats_buy++;
            double cool_sec = MathMin(SLC_CooldownMaxSec, SLC_CooldownMinSec * MathPow(SLC_BackoffMultiplier, g_slc_repeats_buy - 1));
g_slc_cool_until_buy  = (datetime)(sl_time + (long)MathRound(cool_sec));
            if(SLC_LogVerbose) PrintFormat("[SLC_EVENT] BUY cluster detected (size=%d), cool until %s", cluster_size, TimeToString(g_slc_cool_until_buy));
        }
    }
    else // Sell trade was stopped out
    {
        // Push to ring buffer
        g_slc_history_sell[g_slc_head_sell].price = sl_price;
        g_slc_history_sell[g_slc_head_sell].time = sl_time;
        g_slc_head_sell = (g_slc_head_sell + 1) % SLC_History;
        if(g_slc_count_sell < SLC_History) g_slc_count_sell++;

        // Check for cluster
        int cluster_size = 0;
        for(int i = 0; i < g_slc_count_sell; i++)
        {
            if(MathAbs(g_slc_history_sell[i].price - sl_price) <= SLC_ClusterPoints * _Point &&
               (sl_time - g_slc_history_sell[i].time) <= SLC_ClusterWindowSec)
            {
                cluster_size++;
            }
        }
       
        // Trigger cooldown if cluster detected
        if(cluster_size >= SLC_MinEvents)
        {
            g_slc_repeats_sell++;
            double cool_sec = MathMin(SLC_CooldownMaxSec, SLC_CooldownMinSec * MathPow(SLC_BackoffMultiplier, g_slc_repeats_sell - 1));
g_slc_cool_until_sell = (datetime)(sl_time + (long)MathRound(cool_sec));
            if(SLC_LogVerbose) PrintFormat("[SLC_EVENT] SELL cluster detected (size=%d), cool until %s", cluster_size, TimeToString(g_slc_cool_until_sell));
        }
    }
}

//+------------------------------------------------------------------+
//| Trade Transaction Event Handler                                  |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
{
    // --- T039: SL Cluster Event Capture ---
    if(SLC_Enable && trans.type == TRADE_TRANSACTION_DEAL_ADD && HistoryDealSelect(trans.deal))
    {
        if((ulong)HistoryDealGetInteger(trans.deal, DEAL_MAGIC) == MagicNumber &&
           HistoryDealGetInteger(trans.deal, DEAL_ENTRY) == DEAL_ENTRY_OUT &&
           (ENUM_DEAL_REASON)HistoryDealGetInteger(trans.deal, DEAL_REASON) == DEAL_REASON_SL)
        {
            long closing_deal_type = HistoryDealGetInteger(trans.deal, DEAL_TYPE);
            int original_direction = (closing_deal_type == DEAL_TYPE_SELL) ? 1 : -1; // A sell deal closes a buy position
            double sl_price = HistoryDealGetDouble(trans.deal, DEAL_PRICE);
            datetime sl_time = (datetime)HistoryDealGetInteger(trans.deal, DEAL_TIME);
            SLC_ProcessEvent(original_direction, sl_price, sl_time);
        }
    }
   
    // --- AAI METRICS + EXEC JOURNAL ---
    if(trans.type == TRADE_TRANSACTION_DEAL_ADD && HistoryDealSelect(trans.deal))
    {
      // --- T030: Update Risk Guard state on closed deals ---
      if((ulong)HistoryDealGetInteger(trans.deal, DEAL_MAGIC) == MagicNumber &&
         HistoryDealGetInteger(trans.deal, DEAL_ENTRY) == DEAL_ENTRY_OUT)
      {
        datetime deal_time = (datetime)HistoryDealGetInteger(trans.deal, DEAL_TIME);
        if(deal_time >= g_rg_day_anchor_time)
        {
        double profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT) +
                        HistoryDealGetDouble(trans.deal, DEAL_SWAP) +
                        HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);

        g_rg_day_realized_pl += profit;
        if(profit < 0) g_rg_consec_losses++; else g_rg_consec_losses = 0;

        if((ENUM_DEAL_REASON)HistoryDealGetInteger(trans.deal, DEAL_REASON) == DEAL_REASON_SL)
        {
          g_rg_day_sl_hits++;
        }
        }
        // T035: Delete Trailing State on close
        for(int i = g_trl_states.Total() - 1; i >= 0; i--)
        {
        TRL_State *s = (TRL_State*)g_trl_states.At(i);
        if(s && s.symbol == HistoryDealGetString(trans.deal, DEAL_SYMBOL))
        {
          g_trl_states.Delete(i);
          delete s;
        }
        }
      }

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

        // T040: Update execution analytics on fill
        if(EA_Enable && trans.symbol == _Symbol)
        {
            ulong lat = (g_ea_state.last_send_ticks > 0) ? GetTickCount64() - g_ea_state.last_send_ticks : 0;
            double deal_price = HistoryDealGetDouble(trans.deal, DEAL_PRICE);
            double slip_pts = (g_ea_state.last_req_price > 0) ? MathAbs((deal_price - g_ea_state.last_req_price) / _Point) : 0;

            const double alpha = 2.0 / (EA_EwmaTrades + 1.0);
            g_ea_state.ewma_slip_pts = (1.0 - alpha) * g_ea_state.ewma_slip_pts + alpha * slip_pts;
            g_ea_state.ewma_latency_ms = (1.0 - alpha) * g_ea_state.ewma_latency_ms + alpha * lat;

            // Reset trackers for next send
            g_ea_state.last_send_ticks = 0;
            g_ea_state.last_req_price = 0.0;
        }

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
       
        // --- T038: Update ECF EWMA ---
        const double alpha = 2.0 / (ECF_EMA_Trades + 1.0);
        g_ecf_ewma = (1.0 - alpha) * g_ecf_ewma + alpha * net;
       
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
//| >>> T028: Adaptive Spread Tick Sampler <<<                       |
//+------------------------------------------------------------------+
// Sample current spread (in POINTS) and append to the adaptive-spread buffer.
// Works on variable-spread brokers (no reliance on SYMBOL_SPREAD).
// Sample current spread (in POINTS) and append to the adaptive-spread buffer.
// Bounded & cadence-aware: respects InpAS_SampleEveryNTicks and InpAS_SamplesPerBarMax,
// and rolls bar medians into a fixed-size ring buffer (g_as_bar_medians) to avoid growth.
void AS_OnTickSample()
{
   if(!InpAS_Enable || InpAS_Mode==AS_OFF) return;

   // 1) Detect new bar on the configured SignalTimeframe and finalize the previous bar's median
   datetime cur_bar_time = iTime(_Symbol, (ENUM_TIMEFRAMES)SignalTimeframe, 0);
   if(g_as_forming_bar_time != 0 && cur_bar_time != g_as_forming_bar_time)
   {
      const int n = ArraySize(g_as_samples);
      if(n > 0)
      {
         // Compute median of samples for the just-closed bar
         double tmp[]; ArrayResize(tmp, n);
         for(int i=0;i<n;i++) tmp[i]=g_as_samples[i];
         ArraySort(tmp);
         const double med = (n%2!=0 ? tmp[n/2] : 0.5*(tmp[n/2-1] + tmp[n/2]));

         // Push into ring buffer g_as_bar_medians
         int cap = ArraySize(g_as_bar_medians);
         if(cap <= 0){ ArrayResize(g_as_bar_medians, 1); cap = 1; }
         g_as_bar_medians[g_as_hist_pos] = med;
         g_as_hist_pos = (g_as_hist_pos + 1) % cap;
         if(g_as_hist_count < cap) g_as_hist_count++;
      }

      // Reset per-bar state
      ArrayResize(g_as_samples, 0);
      g_as_tick_ctr = 0;
      g_as_exceeded_for_bar = false;
      g_as_forming_bar_time = cur_bar_time;
   }

   // 2) Tick-cadence gating
   g_as_tick_ctr++;
   if(InpAS_SampleEveryNTicks > 1 && (g_as_tick_ctr % InpAS_SampleEveryNTicks) != 0)
      return;

   // 3) Per-bar cap on samples
   if(InpAS_SamplesPerBarMax > 0 && ArraySize(g_as_samples) >= InpAS_SamplesPerBarMax)
      return;

   // 4) Fetch spread in points (robust on variable-spread brokers)
   double spr_pts = CurrentSpreadPoints();
   if(spr_pts <= 0.0)
   {
      const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      if(ask > 0.0 && bid > 0.0)
         spr_pts = (ask - bid) / _Point;
   }
   if(spr_pts <= 0.0) return;

   // 5) Append to this bar's sample buffer (bounded by step 3)
   int sz = ArraySize(g_as_samples);
   ArrayResize(g_as_samples, sz + 1);
   g_as_samples[sz] = spr_pts;
}



//+------------------------------------------------------------------+
//| OnTick: Event-driven logic                                       |
//+------------------------------------------------------------------+
void OnTick()
{
FailsafeExitChecks();
   AS_OnTickSample();    // T028 sampler
   HM_OnTick();          // T034 harmonizer worker
   PT_OnTick();          // T036 partial profit worker
   TRL_OnTick();         // T035 trailing worker
   g_tickCount++;

   if(PositionSelect(_Symbol))
   {
// [DISABLED LEGACY TM]    MqlDateTime dt;
// [DISABLED LEGACY TM]    TimeToStruct(TimeCurrent(), dt);
// [DISABLED LEGACY TM]    ManageOpenPositions(dt, false);
   }

   // TICKET T021: Use the cache helper
   if(!UpdateSBCacheIfNewBar() && MQLInfoInteger(MQL_TESTER))
   {
       // During warmup or on a read fail, we might still need to log a neutral line for the journal
       if(g_sb.closed_bar_time != g_last_per_bar_journal_time)
       {
           LogPerBarStatus(0, 0, 0, 0, 0);
           UpdateHUD(0, 0, 0, 0, 0);
       }
       return;
   }

   EvaluateClosedBar();
}

//+------------------------------------------------------------------+
//| >>> T027 Structure Proximity Helpers <<<                         |
//+------------------------------------------------------------------+
// Returns last swing high within lookback using a simple fractal test (leg L on both sides)
double FindRecentSwingHigh(const int lookback, const int L)
{
  if(lookback < 2*L+1) return 0.0;
  const int n = lookback;
  MqlRates rates[]; ArraySetAsSeries(rates,true);
  if(CopyRates(_Symbol, (ENUM_TIMEFRAMES)SignalTimeframe, 1, n, rates) != n) return 0.0; // closed bars only

  for(int i=L; i<n-L; ++i){
    bool ok = true;
    double h = rates[i].high;
    for(int k=1;k<=L && ok;k++){ if(rates[i-k].high >= h || rates[i+k].high >= h) ok=false; }
    if(ok) return h;
  }
  return 0.0;
}

double FindRecentSwingLow(const int lookback, const int L)
{
  if(lookback < 2*L+1) return 0.0;
  const int n = lookback;
  MqlRates rates[]; ArraySetAsSeries(rates,true);
  if(CopyRates(_Symbol, (ENUM_TIMEFRAMES)SignalTimeframe, 1, n, rates) != n) return 0.0; // closed bars only

  for(int i=L; i<n-L; ++i){
    bool ok = true;
    double lo = rates[i].low;
    for(int k=1;k<=L && ok;k++){ if(rates[i-k].low <= lo || rates[i+k].low <= lo) ok=false; }
    if(ok) return lo;
  }
  return 0.0;
}

//+------------------------------------------------------------------+
//| >>> T028 Adaptive Spread Helpers <<<                             |
//+------------------------------------------------------------------+
// Median of last 'count' elements from ring buffer
double AS_MedianOfHistory()
{
  const int N = g_as_hist_count;
  if(N <= 0) return 0.0;

  // Unroll ring into a linear temp
  double tmp[]; ArrayResize(tmp, N);
  int idx = (g_as_hist_pos - N + ArraySize(g_as_bar_medians)) % ArraySize(g_as_bar_medians);
  for(int i=0;i<N;i++){
    tmp[i] = g_as_bar_medians[(idx + i) % ArraySize(g_as_bar_medians)];
  }
  ArraySort(tmp);
  return (N%2!=0 ? tmp[N/2] : 0.5*(tmp[N/2-1] + tmp[N/2]));
}

//+------------------------------------------------------------------+
//| >>> T029 Inter-Market Confirmation Helpers <<<                   |
//+------------------------------------------------------------------+
bool IMC_RocBps(const string sym, const ENUM_TIMEFRAMES tf, const int lookback, double &roc_bps_out)
{
  roc_bps_out = 0.0;
  if(sym=="" || lookback < 1) return false;
  if(!SymbolSelect(sym, true)) return false;

  double c_new[1], c_old[1];
  if(CopyClose(sym, tf, 1, 1, c_new) != 1) return false;
  if(CopyClose(sym, tf, 1+lookback, 1, c_old) != 1) return false;
  if(c_old[0] == 0.0) return false;

  double roc = (c_new[0] - c_old[0]) / c_old[0];
  roc_bps_out = roc * 10000.0;
  return true;
}

double IMC_PerConfSupport_ROC(const int our_direction, const string sym, ENUM_TIMEFRAMES tf,
                              ENUM_IMC_Rel rel, int lookback, double minAbsBps)
{
  double roc_bps;
  if(!IMC_RocBps(sym, tf, lookback, roc_bps)) return 0.5; // neutral if unavailable

  if(MathAbs(roc_bps) < MathMax(0.0, minAbsBps)) return 0.5;

  int conf_dir = (roc_bps > 0.0 ? +1 : -1);
  conf_dir = (rel==IMC_CONTRA ? -conf_dir : conf_dir);

  if(conf_dir == our_direction) return 1.0;
  return 0.0; // opposing
}

double IMC_WeightedSupport(const int our_direction)
{
  double wsum = 0.0, accum = 0.0;

  if(InpIMC1_Symbol != "")
  {
    double s1 = IMC_PerConfSupport_ROC(our_direction, InpIMC1_Symbol, InpIMC1_Timeframe,
                                       InpIMC1_Relation, InpIMC1_LookbackBars, InpIMC1_MinAbsRocBps);
    accum += InpIMC1_Weight * s1;
    wsum  += MathMax(0.0, InpIMC1_Weight);
  }

  if(InpIMC2_Symbol != "")
  {
    double s2 = IMC_PerConfSupport_ROC(our_direction, InpIMC2_Symbol, InpIMC2_Timeframe,
                                       InpIMC2_Relation, InpIMC2_LookbackBars, InpIMC2_MinAbsRocBps);
    accum += InpIMC2_Weight * s2;
    wsum  += MathMax(0.0, InpIMC2_Weight);
  }

  if(wsum <= 0.0) return 1.0; // no active confirmers → fully permissive
  return accum / wsum;
}


//+------------------------------------------------------------------+
//| >>> T037: Position Health Watchdog (PHW) Helpers <<<             |
//+------------------------------------------------------------------+
bool PHW_IsQualifyingFailure(const uint retcode)
{
    switch(retcode)
    {
        case TRADE_RETCODE_REQUOTE:
        case TRADE_RETCODE_PRICE_OFF:
        case TRADE_RETCODE_REJECT:
        case 10025: // TRADE_RETCODE_NO_CONNECTION
        case 10026: // TRADE_RETCODE_TRADE_CONTEXT_BUSY
            return true;
    }
    return false;
}

void PHW_LogFailure(const uint retcode)
{
    if(!PHW_Enable || !PHW_IsQualifyingFailure(retcode)) return;

    datetime now = TimeCurrent();
    // Prune old timestamps from the circular buffer
    int new_size = 0;
    for(int i = 0; i < g_phw_fail_count; i++)
    {
        if(now - g_phw_fail_timestamps[i] <= PHW_FailBurstWindowSec)
        {
            if (new_size != i) g_phw_fail_timestamps[new_size] = g_phw_fail_timestamps[i];
            new_size++;
        }
    }
    g_phw_fail_count = new_size;

    // Add the new failure
    ArrayResize(g_phw_fail_timestamps, g_phw_fail_count + 1);
    g_phw_fail_timestamps[g_phw_fail_count] = now;
    g_phw_fail_count++;
}


//+------------------------------------------------------------------+
//| >>> T025 GATE REFACTOR: Gate Functions <<<                       |
//+------------------------------------------------------------------+

// --- Gate 1: Warmup ---
bool GateWarmup(string &reason_id)
{
    long bars_avail = Bars(_Symbol, (ENUM_TIMEFRAMES)SignalTimeframe);
    if(bars_avail < WarmupBars)
    {
        datetime barTime = iTime(_Symbol, (ENUM_TIMEFRAMES)SignalTimeframe, 0);
        if(g_last_ea_warmup_log_time != barTime)
        {
            PrintFormat("[WARMUP] t=%s sb_handle_ok=%d need=%d have=%d",
                        TimeToString(barTime), (sb_handle != INVALID_HANDLE), WarmupBars, (int)bars_avail);
            g_last_ea_warmup_log_time = barTime;
        }
        reason_id = "warmup";
        return false;
    }
    return true;
}

// --- Gate 2: Fixed Spread ---
bool GateSpread(string &reason_id)
{
    int currentSpread = CurrentSpreadPoints();
    if(currentSpread > MaxSpreadPoints)
    {
        static datetime last_spread_log_time = 0;
        datetime barTime = iTime(_Symbol, (ENUM_TIMEFRAMES)SignalTimeframe, 1);
        if(barTime != last_spread_log_time)
        {
            PrintFormat("[SPREAD_BLK] t=%s spread=%d max=%d", TimeToString(barTime), currentSpread, MaxSpreadPoints);
            last_spread_log_time = barTime;
        }
        reason_id = "spread";
        if(g_stamp_spd != g_sb.closed_bar_time) { g_blk_spread++; g_stamp_spd = g_sb.closed_bar_time; }
        return false;
    }
    return true;
}

// --- Gate 3: News ---
bool GateNews(double &conf_io, string &reason_id)
{
    datetime server_now = TimeCurrent();
    // CheckGate will modify conf_io if mode is PREFERRED and set flag for journaling
    if(!g_newsGate.CheckGate(server_now, conf_io, g_news_flag_for_bar))
    {
        reason_id = "news";
        if(g_stamp_news != g_sb.closed_bar_time){ g_blk_news++; g_stamp_news = g_sb.closed_bar_time; }
        return false; // Blocked
    }
    return true; // Passed (confidence may have been penalized)
}

// --- Gate 4: Risk Guard (T030) ---
bool GateRiskGuard(double &conf_io, string &reason_id)
{
  g_rg_flag_for_bar = false;
  if(!InpRG_Enable || InpRG_Mode==RG_OFF) return true;

  // Rollover check
  MqlDateTime now;
  TimeToStruct(TimeCurrent(), now);
  MqlDateTime anchor_dt = now;
  anchor_dt.hour = InpRG_ResetHourServer;
  anchor_dt.min = 0;
  anchor_dt.sec = 0;
  datetime current_anchor = StructToTime(anchor_dt);
  if(current_anchor > TimeCurrent()) current_anchor -= 86400;
  if(current_anchor != g_rg_day_anchor_time)
  {
      RG_ResetDay();
      EA_ResetDay(); // T040: Also reset execution analytics counters
  }


  // If currently blocked and block time not expired, block
  if(g_rg_block_active && (InpRG_BlockUntil==RG_BLOCK_TIL_END_OF_DAY || TimeCurrent() < g_rg_block_until))
  {
    g_rg_flag_for_bar = true;
    reason_id = "risk";
    if(g_stamp_risk != g_sb.closed_bar_time) { g_blk_risk++; g_stamp_risk = g_sb.closed_bar_time; }
    return false;
  }

  // If a temporary block expired, unblock
  if(g_rg_block_active && InpRG_BlockUntil==RG_BLOCK_FOR_HOURS && TimeCurrent() >= g_rg_block_until)
  {
    g_rg_block_active = false;
  }

  // Compute running % drawdown vs start-of-day balance
  double startBal = (g_rg_day_start_balance>0.0 ? g_rg_day_start_balance : AccountInfoDouble(ACCOUNT_BALANCE));
  double dd_pct   = (startBal>0.0 ? (-g_rg_day_realized_pl / startBal) * 100.0 : 0.0);
  double dd_abs   = -g_rg_day_realized_pl; // positive when loss

  bool hit_pct  = (InpRG_MaxDailyLossPct   > 0.0 && dd_pct >= InpRG_MaxDailyLossPct);
  bool hit_abs  = (InpRG_MaxDailyLossMoney > 0.0 && dd_abs >= InpRG_MaxDailyLossMoney);
  bool hit_sls  = (InpRG_MaxSLHits         > 0   && g_rg_day_sl_hits >= InpRG_MaxSLHits);
  bool hit_seq  = (InpRG_MaxConsecLosses   > 0   && g_rg_consec_losses >= InpRG_MaxConsecLosses);

  bool tripped = (hit_pct || hit_abs || hit_sls || hit_seq);

  if(tripped)
  {
    g_rg_flag_for_bar = true;
    if(InpRG_Mode == RG_REQUIRED){
      reason_id = "risk";
      g_rg_block_active = true;
      if(InpRG_BlockUntil==RG_BLOCK_FOR_HOURS) g_rg_block_until = TimeCurrent() + InpRG_BlockHours*3600;
      if(g_stamp_risk != g_sb.closed_bar_time) { g_blk_risk++; g_stamp_risk = g_sb.closed_bar_time; }
      return false; // hard block
    } else {
      conf_io = MathMax(0.0, conf_io - (double)InpRG_PrefPenalty); // soft penalty
      return true;
    }
  }

  return true;
}

// --- Gate 5: Position Health Watchdog (T037) ---
bool GatePHW(string &reason_id)
{
    if(!PHW_Enable) return true;

    // --- Daily Reset Logic ---
    MqlDateTime now_dt; TimeToStruct(TimeCurrent(), now_dt);
    MqlDateTime anchor_dt = now_dt;
    anchor_dt.hour = PHW_ResetHour; anchor_dt.min = 0; anchor_dt.sec = 0;
    datetime current_anchor = StructToTime(anchor_dt);
    if(current_anchor > TimeCurrent()) current_anchor -= 86400;
    if(current_anchor != g_phw_day_anchor)
    {
        g_phw_day_anchor = current_anchor;
        g_phw_repeats_today = 0;
    }

    // --- Check if currently in cooldown ---
    if(TimeCurrent() < g_phw_cool_until)
    {
        reason_id = "phw_cooldown";
        if(g_stamp_phw != g_sb.closed_bar_time) { g_blk_phw++; g_stamp_phw = g_sb.closed_bar_time; }
        return false;
    }

    // --- Check for new triggers on this bar ---
    bool trigger = false;
    string trigger_reason = "";
    string trigger_details = "";

    // Trigger 1: Spread Spike
    if(CurrentSpreadPoints() >= PHW_SpreadSpikePoints)
    {
        trigger = true;
        trigger_reason = "SPREAD_SPIKE";
        trigger_details = StringFormat("spread=%dpts", CurrentSpreadPoints());
    }

    // Trigger 2: Failure Burst
    if(!trigger && g_phw_fail_count >= PHW_FailBurstN)
    {
        trigger = true;
        trigger_reason = "FAIL_BURST";
        trigger_details = StringFormat("n=%d/%ds", g_phw_fail_count, PHW_FailBurstWindowSec);
    }

    // --- Take action if triggered ---
    if(trigger)
    {
        g_phw_repeats_today++;
        double cool_sec = MathMin(PHW_CooldownMaxSec, PHW_CooldownMinSec * MathPow(PHW_BackoffMultiplier, g_phw_repeats_today - 1));
        g_phw_cool_until = TimeCurrent() + (datetime)cool_sec;
        g_phw_last_trigger_ts = TimeCurrent();

        static datetime last_log_time = 0;
        if(g_sb.closed_bar_time != last_log_time)
        {
            PrintFormat("[WDG] sym=%s reason=%s %s backoff=%.1fx cooldown=%.0fs until=%s",
                        _Symbol,
                        trigger_reason,
                        trigger_details,
                        MathPow(PHW_BackoffMultiplier, g_phw_repeats_today - 1),
                        cool_sec,
                        TimeToString(g_phw_cool_until, TIME_MINUTES|TIME_SECONDS));
            last_log_time = g_sb.closed_bar_time;
        }
       
        if(StringFind(trigger_reason, "FAIL")!=-1) {
          ArrayResize(g_phw_fail_timestamps,0);
          g_phw_fail_count = 0;
        }

        reason_id = "phw_trigger";
        if(g_stamp_phw != g_sb.closed_bar_time) { g_blk_phw++; g_stamp_phw = g_sb.closed_bar_time; }
        return false;
    }

    return true;
}

// --- Gate 6: Session ---
bool GateSession(string &reason_id)
{
    if(SessionEnable)
    {
        MqlDateTime dt;
        TimeToStruct(TimeTradeServer(), dt);
        const int hh = dt.hour;
        bool sess_ok = (SessionStartHourServer == SessionEndHourServer)
                         ? true
                         : (SessionStartHourServer <= SessionEndHourServer)
                           ? (hh >= SessionStartHourServer && hh < SessionEndHourServer)
                           : (hh >= SessionStartHourServer || hh < SessionEndHourServer);
        if(!sess_ok)
        {
            reason_id = "session";
            if(g_stamp_sess != g_sb.closed_bar_time){ g_stamp_sess = g_sb.closed_bar_time; }
            return false;
        }
    }
    return true;
}

// --- Gate 7: Over-extension ---
bool GateOverExtension(string &reason_id)
{
    static datetime last_overext_log_time = 0;
    double mid = 0, atr = 0, px = 0;

    double _tmp_ma_[1];
    if(CopyBuffer(g_hOverextMA, 0, 1, 1, _tmp_ma_) == 1) mid = _tmp_ma_[0];

    double _tmp_atr_[1];
    if(CopyBuffer(g_hATR, 0, 1, 1, _tmp_atr_) == 1) atr = _tmp_atr_[0];

    px = iClose(_Symbol, (ENUM_TIMEFRAMES)SignalTimeframe, 1);

    if(mid > 0 && atr > 0 && px > 0)
    {
        double up = mid + OverExt_ATR_Mult * atr;
        double dn = mid - OverExt_ATR_Mult * atr;
        const int direction = g_sb.sig;

        bool is_over_long = (direction > 0 && px > up);
        bool is_over_short = (direction < 0 && px < dn);

        if(OverExtMode == HardBlock)
        {
            if(is_over_long || is_over_short)
            {
                if(g_sb.closed_bar_time != last_overext_log_time)
                {
                    PrintFormat("[OVEREXT_BLK] t=%s dir=%d px=%.5f up=%.5f dn=%.5f", TimeToString(g_sb.closed_bar_time), direction, px, up, dn);
                    last_overext_log_time = g_sb.closed_bar_time;
                }
                reason_id = "overext";
                if(g_stamp_over != g_sb.closed_bar_time){ g_blk_over++; g_stamp_over = g_sb.closed_bar_time; }
                return false;
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
// ... inside GateOverExtension() ...
if(g_sb.closed_bar_time != g_last_overext_dec_sigbar)
{
    if(g_overext_wait > 0) // Only decrement if we are actively waiting
    {
        g_overext_wait--; 
    }
    g_last_overext_dec_sigbar = g_sb.closed_bar_time;
}

if(g_overext_wait > 0)
{
    // ... logging ...
    reason_id = "overext";
    if(g_stamp_over != g_sb.closed_bar_time){ g_blk_over++; g_stamp_over = g_sb.closed_bar_time; }
    return false;
}

                    if(g_sb.closed_bar_time != last_overext_log_time)
                    {
                        PrintFormat("[OVEREXT_WAIT] t=%s left=%d dir=%d", TimeToString(g_sb.closed_bar_time), g_overext_wait, direction);
                        last_overext_log_time = g_sb.closed_bar_time;
                    }
                    reason_id = "overext";
                    if(g_stamp_over != g_sb.closed_bar_time){ g_blk_over++; g_stamp_over = g_sb.closed_bar_time; }
                    return false;
                }
            }
        }
    }
    return true;
}

// --- Gate 8: Volatility Regime ---
bool GateVolatility(double &conf_io, string &reason_id)
{
    if(!InpVR_Enable || InpVR_Mode == VR_OFF) return true;

    double atrv[1];
    if(g_hATR_VR == INVALID_HANDLE || CopyBuffer(g_hATR_VR, 0, 1, 1, atrv) != 1) return true; // Fail open

    MqlRates rates[];
    if(CopyRates(_Symbol, (ENUM_TIMEFRAMES)SignalTimeframe, 1, 1, rates) != 1 || rates[0].close == 0) return true; // Fail open

    double atr_bps = (atrv[0] / rates[0].close) * 10000.0;
    bool out_of_band = (atr_bps < InpVR_MinBps || atr_bps > InpVR_MaxBps);

    if(out_of_band) g_vr_flag_for_bar = 1;

    if(!out_of_band) return true;

    if(InpVR_Mode == VR_REQUIRED) {
        reason_id = "vr";
        if(g_stamp_vr != g_sb.closed_bar_time){ g_blk_vr++; g_stamp_vr = g_sb.closed_bar_time; }
        return false;
    }

    // Mode is PREFERRED
    conf_io = MathMax(0.0, conf_io - InpVR_PrefPenalty);
    return true;
}

// --- Gate 9: Adaptive Spread (T028) ---
bool GateAdaptiveSpread(double &conf_io, string &reason_id)
{
  g_as_exceeded_for_bar = false;
  g_as_cap_pts_last = 0.0;

  if(!InpAS_Enable || InpAS_Mode==AS_OFF) return true;
  if(g_as_hist_count == 0) return true; // no history yet → permissive

  // Build adaptive cap
  double med = AS_MedianOfHistory();       // points
  double cap = med * (1.0 + MathMax(0.0, InpAS_SafetyPct)) + (double)MathMax(0, InpAS_SafetyPts);

  if(InpAS_ClampToFixedMax){
    cap = (MaxSpreadPoints > 0 ? MathMin(cap, (double)MaxSpreadPoints) : cap);
  }

  g_as_cap_pts_last = cap;

  double spread_pts = (double)CurrentSpreadPoints();

  if(spread_pts > cap){
    g_as_exceeded_for_bar = true;
    if(InpAS_Mode == AS_REQUIRED){
      reason_id = "aspread";
      if(g_stamp_aspd != g_sb.closed_bar_time) { g_blk_aspread++; g_stamp_aspd = g_sb.closed_bar_time; }
      return false;
    }else{ // PREFERRED
      conf_io = MathMax(0.0, conf_io - (double)InpAS_PrefPenalty);
      return true;
    }
  }
  return true;
}


// --- Gate 10: Structure Proximity (T027) ---
bool GateStructureProximity(const int direction, double &conf_io, string &reason_id)
{
  g_sp_hit_for_bar = false;
  if(!InpSP_Enable || InpSP_Mode==SP_OFF) return true;

  // 1) Get threshold in POINTS
  double thr_pts = (double)InpSP_AbsPtsThreshold;
  if(InpSP_UseATR){
    double atrv[1];
    if(g_hATR_SP != INVALID_HANDLE && CopyBuffer(g_hATR_SP, 0, 1, 1, atrv)==1){
      thr_pts = (atrv[0] / _Point) * InpSP_ATR_Mult;
    }
  }
  if(thr_pts <= 0) return true; // be permissive

  // 2) Reference price: last closed bar close
  double c[1]; if(CopyClose(_Symbol, (ENUM_TIMEFRAMES)SignalTimeframe, 1, 1, c) != 1) return true;
  double px = c[0];

  // 3) Collect nearest distances (in POINTS) to enabled structures
  double min_dist_pts = DBL_MAX;

  // 3a) Round numbers (grid)
  if(InpSP_CheckRoundNumbers && InpSP_RoundGridPts > 0){
    const double grid_price = InpSP_RoundGridPts * _Point;
    double aligned = (MathFloor((px - InpSP_RoundOffsetPts*_Point)/grid_price) * grid_price) + InpSP_RoundOffsetPts*_Point;
    double rn_down = aligned;
    double rn_up   = aligned + grid_price;
    double d1 = MathAbs(px - rn_down) / _Point;
    double d2 = MathAbs(rn_up - px)   / _Point;
    min_dist_pts = MathMin(min_dist_pts, MathMin(d1, d2));
  }

  // 3b) Yesterday High/Low (D1, shift=1)
  if(InpSP_CheckYesterdayHighLow){
    double yh[1], yl[1];
    if(CopyHigh(_Symbol, PERIOD_D1, 1, 1, yh)==1 && CopyLow(_Symbol, PERIOD_D1, 1, 1, yl)==1){
      double d_yh = MathAbs(px - (yh[0] - InpSP_YHYL_BufferPts*_Point))/_Point;
      double d_yl = MathAbs(px - (yl[0] + InpSP_YHYL_BufferPts*_Point))/_Point;
      min_dist_pts = MathMin(min_dist_pts, MathMin(d_yh, d_yl));
    }
  }

  // 3c) Weekly Open (W1 open of current week; value is fixed after week start)
  if(InpSP_CheckWeeklyOpen){
    double wo[1];
    if(CopyOpen(_Symbol, PERIOD_W1, 0, 1, wo)==1){ // W1 shift=0 open is stable through week
      double d_wo = MathAbs(px - (wo[0] - InpSP_WOpen_BufferPts*_Point))/_Point;
      min_dist_pts = MathMin(min_dist_pts, d_wo);
    }
  }

  // 3d) Recent swing points on SignalTimeframe
  if(InpSP_CheckSwings){
    double sw_hi = FindRecentSwingHigh(InpSP_SwingLookbackBars, InpSP_SwingLeg);
    double sw_lo = FindRecentSwingLow (InpSP_SwingLookbackBars, InpSP_SwingLeg);
    if(sw_hi>0) min_dist_pts = MathMin(min_dist_pts, MathAbs(px - sw_hi)/_Point);
    if(sw_lo>0) min_dist_pts = MathMin(min_dist_pts, MathAbs(px - sw_lo)/_Point);
  }

  // 4) Decide
  if(min_dist_pts <= thr_pts){
    g_sp_hit_for_bar = true;
    if(InpSP_Mode == SP_REQUIRED){
      reason_id = "struct";
      if(g_stamp_sp != g_sb.closed_bar_time){ g_blk_sp++; g_stamp_sp = g_sb.closed_bar_time; }
      return false; // BLOCK
    }else{ // PREFERRED
      conf_io = MathMax(0.0, conf_io - (double)InpSP_PrefPenalty);
      return true; // allow with penalty
    }
  }

  return true; // far enough from structure
}


// --- Gate 11: ZoneEngine ---
bool GateZE(const int direction, const double ze_strength, string &reason_id)
{
    if(ZE_Gate == ZE_REQUIRED && ze_strength < ZE_MinStrength)
    {
        reason_id = "ZE_REQUIRED";
        if(g_stamp_ze != g_sb.closed_bar_time){ g_blk_ze++; g_stamp_ze = g_sb.closed_bar_time; }
        return false;
    }
    return true;
}

// --- Gate 12: SMC ---
bool GateSMC(const int direction, const int smc_sig, const double smc_conf, string &reason_id)
{
    if(SMC_Mode == SMC_REQUIRED)
    {
        if(smc_sig != direction || smc_conf < SMC_MinConfidence)
        {
            reason_id = "SMC_REQUIRED";
            if(g_stamp_smc != g_sb.closed_bar_time){ g_blk_smc++; g_stamp_smc = g_sb.closed_bar_time; }
            return false;
        }
    }
    return true;
}

// --- Gate 13: BiasCompass ---
bool GateBC(const int direction, const int bc_bias, string &reason_id)
{
    if(BC_AlignMode == BC_REQUIRED)
    {
        if(bc_bias != direction)
        {
            reason_id = "BC_REQUIRED";
            if(g_stamp_bc != g_sb.closed_bar_time){ g_blk_bc++; g_stamp_bc = g_sb.closed_bar_time; }
            return false;
        }
    }
    return true;
}

// --- Gate 14: Inter-Market Confirmation (T029) ---
bool GateInterMarket(const int direction, double &conf_io, string &reason_id)
{
  g_imc_flag_for_bar = false;
  g_imc_support = 1.0;

  if(!InpIMC_Enable || InpIMC_Mode==IMC_OFF) return true;

  // Compute weighted support [0..1] from configured confirmers
  g_imc_support = IMC_WeightedSupport(direction);

  if(g_imc_support < MathMin(1.0, MathMax(0.0, InpIMC_MinSupport)))
  {
    g_imc_flag_for_bar = true;
    if(InpIMC_Mode == IMC_REQUIRED){
      reason_id = "imc";         // inter-market confirmation
      if(g_stamp_imc != g_sb.closed_bar_time) { g_blk_imc++; g_stamp_imc = g_sb.closed_bar_time; }
      return false;              // BLOCK
    } else {
      conf_io = MathMax(0.0, conf_io - (double)InpIMC_PrefPenalty);
      return true;               // allow with penalty
    }
  }

  return true; // passed
}

// --- Gate 15: Equity Curve Feedback (T038) ---
bool GateECF(double &conf_io, string &reason_id)
{
    if(!ECF_Enable) return true;

    // --- Drawdown on closed-trade equity curve ---
    double dd_abs = AAI_peak - AAI_curve;
    double denom  = (AAI_peak != 0.0 ? MathAbs(AAI_peak) : 1.0);
    double dd_pct = 100.0 * (dd_abs / denom);

    // --- Determine multiplier from regime ---
    double mult = 1.0;

    // Penalty region (soft→hard)
    if(dd_pct >= ECF_DD_SoftPct)
    {
        // Map [Soft .. Hard] linearly to [1.0 .. MaxDnMult]
        double t = MathMin(1.0, (dd_pct - ECF_DD_SoftPct) / MathMax(1e-9, (ECF_DD_HardPct - ECF_DD_SoftPct)));
        mult = 1.0 - t * (1.0 - ECF_MaxDnMult);

        if(ECF_HardBlock && dd_pct >= ECF_DD_HardPct)
        {
            reason_id = "ecf";
            if(g_sb.closed_bar_time != g_stamp_ecf)
            {
                PrintFormat("[ECF] HARD_BLOCK dd=%.2f%% curve=%.2f peak=%.2f", dd_pct, AAI_curve, AAI_peak);
                g_stamp_ecf = g_sb.closed_bar_time;
            }
            return false;
        }
    }
    // Boost region (recent strength & near highs)
    else if(AAI_trades >= ECF_MinTradesForBoost && g_ecf_ewma > 0.0)
    {
        double boost = (1.0 - MathMin(1.0, dd_pct / ECF_DD_SoftPct)) * (ECF_MaxUpMult - 1.0);
        mult = 1.0 + boost;
    }

    // Apply and clamp confidence [0..100]
    if(mult != 1.0)
    {
        conf_io = MathMax(0.0, MathMin(100.0, conf_io * mult));
        if(g_sb.closed_bar_time != g_stamp_ecf && ECF_LogVerbose)
        {
            PrintFormat("[ECF] dd=%.2f%% ewma=%.2f mult=%.3f conf=%.1f", dd_pct, g_ecf_ewma, mult, conf_io);
            g_stamp_ecf = g_sb.closed_bar_time;
        }
    }
    return true;
}

// --- Gate 16: SL Cluster Cooldown (T039) ---
bool GateSLC(const int direction, string &reason_id)
{
    if(!SLC_Enable) return true;

    // --- Daily Reset Logic ---
    MqlDateTime now_dt; TimeToStruct(TimeCurrent(), now_dt);
    MqlDateTime anchor_dt = now_dt;
    anchor_dt.hour = SLC_ResetHour; anchor_dt.min = 0; anchor_dt.sec = 0;
    datetime current_anchor = StructToTime(anchor_dt);
    if(current_anchor > TimeCurrent()) current_anchor -= 86400;
    if(current_anchor != g_slc_day_anchor)
    {
        g_slc_day_anchor = current_anchor;
        g_slc_repeats_buy = 0;
        g_slc_repeats_sell = 0;
        g_slc_count_buy = 0;
        g_slc_count_sell = 0;
    }

    // --- Check Cooldown ---
    datetime cool_until = (direction > 0) ? g_slc_cool_until_buy : g_slc_cool_until_sell;
    if(TimeCurrent() < cool_until)
    {
        reason_id = "slc";
        if(g_stamp_slc != g_sb.closed_bar_time) { g_blk_slc++; g_stamp_slc = g_sb.closed_bar_time; }
        if(SLC_LogVerbose && g_stamp_slc == g_sb.closed_bar_time)
        {
            long remaining = cool_until - TimeCurrent();
            PrintFormat("[SLC] sym=%s dir=%d cool=%ds until=%s", _Symbol, direction, (int)remaining, TimeToString(cool_until));
        }
        return false;
    }

    return true;
}

// --- Gate 17: Confidence ---
bool GateConfidence(const double conf_eff, string &reason_id)
{
    if(conf_eff < MinConfidence)
    {
        reason_id = "confidence";
        if(g_stamp_conf != g_sb.closed_bar_time){ g_stamp_conf = g_sb.closed_bar_time; }
        return false;
    }
    return true;
}

// --- Gate 18: Cooldown ---
bool GateCooldown(const int direction, string &reason_id)
{
    int secs = PeriodSeconds((ENUM_TIMEFRAMES)SignalTimeframe);
    datetime until = (direction > 0) ? g_cool_until_buy : g_cool_until_sell;
    int delta = (int)(until - g_sb.closed_bar_time);
    int bars_left = (delta <= 0 || secs <= 0) ? 0 : ((delta + secs - 1) / secs);
    if(bars_left > 0)
    {
        reason_id = "cooldown";
        if(g_stamp_cool != g_sb.closed_bar_time){ g_stamp_cool = g_sb.closed_bar_time; }
        return false;
    }
    return true;
}

// --- Gate 19: Debounce ---
bool GateDebounce(const int direction, string &reason_id)
{
    if(PerBarDebounce)
    {
        bool is_duplicate = (direction > 0)
                              ? (g_last_entry_bar_buy == g_sb.closed_bar_time)
                              : (g_last_entry_bar_sell == g_sb.closed_bar_time);
        if(is_duplicate)
        {
            reason_id = "same_bar";
            if(g_stamp_bar != g_sb.closed_bar_time){ g_stamp_bar = g_sb.closed_bar_time; }
            return false;
        }
    }
    return true;
}


// --- Hedging utilities ---
int CountMyPositions(const string sym, const long magic, int &longCnt, int &shortCnt)
{
   longCnt = 0; shortCnt = 0; int total = 0;
   for(int i = PositionsTotal()-1; i >= 0; --i)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != sym) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != magic) continue;
      int t = (int)PositionGetInteger(POSITION_TYPE);
      if(t == POSITION_TYPE_BUY)  ++longCnt;
      if(t == POSITION_TYPE_SELL) ++shortCnt;
      ++total;
   }
   return total;
}

double LastEntryPriceOnSide(const string sym, const long magic, const bool isLong)
{
   datetime lastTime = 0; double px = 0.0;
   uint total = HistoryDealsTotal();
   for(int i = (int)total-1; i >= 0; --i)
   {
      ulong deal = HistoryDealGetTicket(i);
      if(HistoryDealGetString(deal, DEAL_SYMBOL) != sym) continue;
      if((long)HistoryDealGetInteger(deal, DEAL_MAGIC) != magic) continue;
      int tp = (int)HistoryDealGetInteger(deal, DEAL_TYPE);
      if( (isLong && tp == DEAL_TYPE_BUY) || (!isLong && tp == DEAL_TYPE_SELL) )
      {
         datetime when = (datetime)HistoryDealGetInteger(deal, DEAL_TIME);
         if(when > lastTime){ lastTime = when; px = HistoryDealGetDouble(deal, DEAL_PRICE); }
      }
   }
   return px;
}

double ComputePositionRiskPct(const ulong ticket)
{
   if(!PositionSelectByTicket(ticket)) return 0.0;
   const string sym = PositionGetString(POSITION_SYMBOL);
   const double vol = PositionGetDouble(POSITION_VOLUME);
   const double sl  = PositionGetDouble(POSITION_SL);
   const double op  = PositionGetDouble(POSITION_PRICE_OPEN);
   const int    typ = (int)PositionGetInteger(POSITION_TYPE);
   if(sl <= 0.0 || vol <= 0.0) return 0.0;

   const double dist_pts = MathAbs( (typ==POSITION_TYPE_BUY ? op-sl : sl-op) ) / _Point;
   const double tick_val = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
   const double tick_sz  = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   const double money_per_point = (tick_sz > 0.0 ? (tick_val/tick_sz) : tick_val) * vol;
   const double money_risk = dist_pts * money_per_point;
   const double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   return (eq > 0.0 ? 100.0 * money_risk / eq : 0.0);
}

double ComputeAggregateRiskPct(const string sym, const long magic)
{
   double acc = 0.0;
   for(int i = PositionsTotal()-1; i >= 0; --i)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != sym) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != magic) continue;
      acc += ComputePositionRiskPct(ticket);
   }
   return acc;
}


// --- Gate 20: Position (hedging-aware) ---
bool GatePosition(string &reason_id)
{
    if(!InpHEDGE_AllowMultiple)
    {
        if(PositionSelect(_Symbol)) { reason_id = "position_exists"; return false; }
        return true;
    }

    int dir = g_sb.sig; // -1 sell, +1 buy (from SB cache)
    int longCnt, shortCnt;
    const int total = CountMyPositions(_Symbol, (long)MagicNumber, longCnt, shortCnt);

    if(total >= InpHEDGE_MaxPerSymbol)                  { reason_id="hedge_cap_total";  return false; }
    if(dir>0 && longCnt  >= InpHEDGE_MaxLongPerSymbol)  { reason_id="hedge_cap_long";   return false; }
    if(dir<0 && shortCnt >= InpHEDGE_MaxShortPerSymbol) { reason_id="hedge_cap_short";  return false; }

    if(!InpHEDGE_AllowOpposite)
    {
        if( (dir>0 && shortCnt>0) || (dir<0 && longCnt>0) ) { reason_id="hedge_no_opposite"; return false; }
    }

    if(InpHEDGE_MinStepPips>0 && dir!=0)
    {
        const bool isLong = (dir>0);
        const double lastPx = LastEntryPriceOnSide(_Symbol, (long)MagicNumber, isLong);
        if(lastPx>0.0)
        {
            const double pxNow = (isLong ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                                         : SymbolInfoDouble(_Symbol, SYMBOL_ASK));
            const double stepPips = MathAbs(pxNow-lastPx)/(_Point*10.0); // 10 points = 1 pip on 5-digit
            if(stepPips < InpHEDGE_MinStepPips) { reason_id="hedge_step_too_small"; return false; }
        }
    }

    if(InpHEDGE_MaxAggregateRiskPct>0.0)
    {
        const double agg = ComputeAggregateRiskPct(_Symbol, (long)MagicNumber);
        if(agg >= InpHEDGE_MaxAggregateRiskPct) { reason_id="hedge_agg_risk_cap"; return false; }
    }
    return true;
}


// --- Gate 21: Trigger ---
bool GateTrigger(const int direction, const int prev_sb_sig, string &reason_id)
{
    bool is_edge = (direction != prev_sb_sig);
    if(EntryMode == FirstBarOrEdge && !g_bootstrap_done)
    {
        return true; // Bootstrap trigger
    }
    if(is_edge)
    {
        return true; // Edge trigger
    }

    reason_id = "no_trigger";
    return false;
}

//+------------------------------------------------------------------+
//| >>> T025 REFACTOR: Main evaluation flow for a closed bar <<<     |
//+------------------------------------------------------------------+
void EvaluateClosedBar()
{
    // --- 0. Get cached data from SignalBrain for this bar ---
    int    direction   = g_sb.sig;
    double       conf_eff    = g_sb.conf; // This can be modified by gates
    const int    reason_sb   = g_sb.reason;
    const double ze_strength = g_sb.ze;
    const int    smc_sig     = g_sb.smc_sig;
    const double smc_conf    = g_sb.smc_conf;
    const int    bc_bias     = g_sb.bc;

    // --- Log and Update HUD with the raw state for this bar ---
    LogPerBarStatus(direction, conf_eff, reason_sb, ze_strength, bc_bias);
    UpdateHUD(direction, conf_eff, reason_sb, ze_strength, bc_bias);

    // --- T044: Handle periodic state saving ---
    if(g_sb.valid && g_sb.closed_bar_time != g_sp_lastbar)
    {
        g_sp_lastbar = g_sb.closed_bar_time;
        g_sp_barcount++;
        SP_Save(false);
    }
   
    // --- Reset per-bar flags ---
    g_vr_flag_for_bar = 0;
    g_news_flag_for_bar = 0;
    g_sp_hit_for_bar = false;
    g_as_exceeded_for_bar = false;
    g_imc_flag_for_bar = false;
    g_rg_flag_for_bar = false;

    // --- Signal Gate: If no signal, we're done for this bar. ---
    if(direction == 0)
    {
        return;
    }

    string reason_id; // To be populated by a failing gate

    // --- Execute Gate Chain ---
    if(!GateWarmup(reason_id))                                   { PrintFormat("%s reason=%s", AAI_BLOCK_LOG, reason_id); return; }
    if(!GateSpread(reason_id))                                   { PrintFormat("%s reason=%s", AAI_BLOCK_LOG, reason_id); return; }
    if(!GateNews(conf_eff, reason_id))                           { PrintFormat("%s reason=%s", AAI_BLOCK_LOG, reason_id); return; }
    if(!GateRiskGuard(conf_eff, reason_id))                      { PrintFormat("%s reason=%s", AAI_BLOCK_LOG, reason_id); return; }
    if(!GatePHW(reason_id))                                      { PrintFormat("%s reason=%s", AAI_BLOCK_LOG, reason_id); return; } // T037
    if(!GateSession(reason_id))                                  { PrintFormat("%s reason=%s", AAI_BLOCK_LOG, reason_id); return; }
    if(!GateOverExtension(reason_id))                            { PrintFormat("%s reason=%s", AAI_BLOCK_LOG, reason_id); return; }
    if(!GateVolatility(conf_eff, reason_id))                     { PrintFormat("%s reason=%s", AAI_BLOCK_LOG, reason_id); return; }
    if(!GateAdaptiveSpread(conf_eff, reason_id))                 { PrintFormat("%s reason=%s", AAI_BLOCK_LOG, reason_id); return; }
    if(!GateStructureProximity(direction, conf_eff, reason_id)) { PrintFormat("%s reason=%s", AAI_BLOCK_LOG, reason_id); return; }
    if(!GateZE(direction, ze_strength, reason_id))               { PrintFormat("%s reason=%s", AAI_BLOCK_LOG, reason_id); return; }
    if(!GateSMC(direction, smc_sig, smc_conf, reason_id))         { PrintFormat("%s reason=%s", AAI_BLOCK_LOG, reason_id); return; }
    if(!GateBC(direction, bc_bias, reason_id))                   { PrintFormat("%s reason=%s", AAI_BLOCK_LOG, reason_id); return; }
    if(!GateInterMarket(direction, conf_eff, reason_id))         { PrintFormat("%s reason=%s", AAI_BLOCK_LOG, reason_id); return; }
    if(!GateECF(conf_eff, reason_id))                            { PrintFormat("%s reason=%s", AAI_BLOCK_LOG, reason_id); return; } // T038
    if(!GateSLC(direction, reason_id))                           { PrintFormat("%s reason=%s", AAI_BLOCK_LOG, reason_id); return; } // T039
    if(!GateConfidence(conf_eff, reason_id))                     { PrintFormat("%s reason=%s", AAI_BLOCK_LOG, reason_id); return; }
    if(!GateCooldown(direction, reason_id))                      { PrintFormat("%s reason=%s", AAI_BLOCK_LOG, reason_id); return; }
    if(!GateDebounce(direction, reason_id))                      { PrintFormat("%s reason=%s", AAI_BLOCK_LOG, reason_id); return; }
    if(!GatePosition(reason_id))                                 { /* No block log needed */ return; }

    // GateTrigger requires the previous bar's signal
    double prev_sig_raw = 0;
    Read1(sb_handle, SB_BUF_SIGNAL, SB_ReadShift + 1, prev_sig_raw, "SB_Prev");
    if(!GateTrigger(direction, (int)prev_sig_raw, reason_id)) { /* No block log needed */ return; }

    // --- Determine Entry Mode for Journaling ---
    string entry_mode = "";
    bool is_bootstrap_trigger = (EntryMode == FirstBarOrEdge && !g_bootstrap_done);
    if(is_bootstrap_trigger) entry_mode = "bootstrap";
    else entry_mode = "edge";

    // --- All Gates Passed ---
    if(TryOpenPosition(direction, conf_eff, reason_sb, ze_strength, bc_bias, smc_sig, smc_conf, entry_mode))
    {
        if(is_bootstrap_trigger)
        {
            g_bootstrap_done = true;
        }
    }
}
//... (rest of the file is identical) ...
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
bool TryOpenPosition(int signal, double conf_eff, int reason_code, double ze_strength, int bc_bias, int smc_sig, double smc_conf, string entry_mode)
{
   // ----- ATR for SL distance (closed bar), with defensive read -----
   double atr_val_raw = 0.0;
   double _tmp_atr_entry_[1];
   if(CopyBuffer(g_hATR, 0, 1, 1, _tmp_atr_entry_) == 1) atr_val_raw = _tmp_atr_entry_[0];

   double sl_dist_raw = atr_val_raw + (SL_Buffer_Points * point);
   double sl_dist = MathMax(sl_dist_raw, (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * point);

   // ----- lot sizing based on actual risk distance -----
   double lots_to_trade = CalculateLotSize((int)conf_eff, sl_dist);

   // --- Provisional Entry/SL/TP from signal, before adjustment ---
   double entryPrice = (signal > 0) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double slPrice, tpPrice;
   if (signal > 0) {
     slPrice = entryPrice - sl_dist;
     tpPrice = (Exit_FixedRR) ? entryPrice + Fixed_RR * sl_dist : 0;
   } else {
     slPrice = entryPrice + sl_dist;
     tpPrice = (Exit_FixedRR) ? entryPrice - Fixed_RR * sl_dist : 0;
   }

   // --- T033: Auto-adjust SL/TP to satisfy broker min-stops & RR; re-scale lots ---
   if(!SLTA_AdjustAndRescale(signal, entryPrice, slPrice, tpPrice, lots_to_trade, (int)conf_eff))
   {
   if(InpSLTA_LogVerbose) Print("[SLTA_CANCEL] Could not meet broker min-stops / RR constraints within bounds.");
   return false; // Cancel this attempt cleanly
   }

   g_last_comment = StringFormat("AAI|%.1f|%d|%d|%.1f|%.5f|%.5f|%.1f",
                                 conf_eff, (int)conf_eff, reason_code, ze_strength, slPrice, tpPrice, smc_conf);

   double rr_calc = (sl_dist > 0 && tpPrice > 0) ? (MathAbs(tpPrice-entryPrice)/sl_dist) : 0.0;

   DJ_Write(signal, conf_eff, reason_code, ze_strength, bc_bias, smc_sig, smc_conf,
            g_vr_flag_for_bar, g_news_flag_for_bar, g_sp_hit_for_bar ? 1 : 0,
            g_as_exceeded_for_bar ? 1 : 0, g_as_cap_pts_last, g_as_hist_count,
            g_imc_flag_for_bar ? 1 : 0, g_imc_support,
            g_rg_flag_for_bar ? 1:0,
            (g_rg_day_start_balance > 0 ? (-g_rg_day_realized_pl / g_rg_day_start_balance) * 100.0 : 0.0),
            -g_rg_day_realized_pl, g_rg_day_sl_hits, g_rg_consec_losses,
            (double)CurrentSpreadPoints(),
            lots_to_trade, sl_dist / point, (tpPrice>0?MathAbs(tpPrice-entryPrice)/point:0), rr_calc, entry_mode);

   // T040: Capture pre-send state
   if(EA_Enable)
   {
       g_ea_state.last_send_ticks = GetTickCount64();
       g_ea_state.last_req_price = entryPrice;
   }

   MqlTradeResult tRes;
   bool sent = OSR_SendMarket(signal, lots_to_trade, entryPrice, slPrice, tpPrice, tRes);

   // T040: Log execution result
   EA_LogSendResult(tRes.retcode);

   if(!sent){
     PrintFormat("[AAI_SENDFAIL] retcode=%u lots=%.2f dir=%d", tRes.retcode, lots_to_trade, signal);
     // T037: Log failure for watchdog
     PHW_LogFailure(tRes.retcode);
     return false;
   }

   // --- Post-open bookkeeping ---
   if(tRes.deal > 0 && PositionSelect(_Symbol)) {
     long pos_ticket = (long)PositionGetInteger(POSITION_TICKET);
     if(pos_ticket > 0)
     {
       HM_Enqueue(_Symbol, pos_ticket, slPrice, tpPrice);

// T035 & T036: Create/Update Trailing and PT State
       TRL_State *st = TRL_GetState(_Symbol, true);
       st.symbol       = _Symbol;
       st.direction    = signal;
       st.entry_price  = PositionGetDouble(POSITION_PRICE_OPEN);
       st.entry_lots   = PositionGetDouble(POSITION_VOLUME);
       st.entry_sl_pts = MathAbs(st.entry_price - slPrice)/_Point; // use actual SL on position
       st.pt_closed_lots= 0.0;
       st.pt1_done = st.pt2_done = st.pt3_done = false;
       st.be_done = false;
       st.moves_today = 0;
       st.last_mod_time = 0;
       st.day_anchor = g_rg_day_anchor_time;
     }
   }

   g_entries++;
   PrintFormat("%s Signal:%s → Executed %.2f lots @%.5f | SL:%.5f TP:%.5f",
               EVT_ENTRY, (signal > 0 ? "BUY":"SELL"), tRes.volume, tRes.price, slPrice, tpPrice);

   AAI_LogExec(signal, tRes.volume > 0 ? tRes.volume : lots_to_trade);

   datetime current_bar_time = iTime(_Symbol, (ENUM_TIMEFRAMES)SignalTimeframe, 1);
   if(signal > 0) g_last_entry_bar_buy = current_bar_time;
   else           g_last_entry_bar_sell = current_bar_time;

   return true;
}
//+------------------------------------------------------------------+


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
   if(loc.day_of_week==FRIDAY && loc.hour>=FridayCloseHour) {
      if(!MSO_MaySend(_Symbol))
      {
         if(MSO_LogVerbose && g_sb.valid && g_sb.closed_bar_time != g_stamp_mso)
         {
            PrintFormat("[MSO] defer Close sym=%s reason=guard", _Symbol);
            g_stamp_mso = g_sb.closed_bar_time;
         }
         return; // Defer action
      }
     if(!trade.PositionClose(ticket)) PHW_LogFailure(trade.ResultRetcode()); // T037
     return;
   }

   ENUM_POSITION_TYPE side = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double entry = PositionGetDouble(POSITION_PRICE_OPEN);
   double sl    = PositionGetDouble(POSITION_SL);
   double tp    = PositionGetDouble(POSITION_TP);

   if(AAI_ApplyBEAndTrail(side, entry, sl))
   {
      if(!MSO_MaySend(_Symbol))
      {
         if(MSO_LogVerbose && g_sb.valid && g_sb.closed_bar_time != g_stamp_mso)
         {
            PrintFormat("[MSO] defer Modify sym=%s reason=guard", _Symbol);
            g_stamp_mso = g_sb.closed_bar_time;
         }
         return; // Defer action
      }
     if(!trade.PositionModify(_Symbol, sl, tp)) PHW_LogFailure(trade.ResultRetcode()); // T037
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
   const double px      = is_long ? bid : ask;
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

   if(InpTRL_Enable && InpTRL_Mode != TRL_OFF) // Defer trailing to TRL_OnTick
   {
     // old trailing logic is now handled by TRL_OnTick
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

   if(!MSO_MaySend(_Symbol))
   {
      if(MSO_LogVerbose && g_sb.valid && g_sb.closed_bar_time != g_stamp_mso)
      {
         PrintFormat("[MSO] defer PartialClose sym=%s reason=guard", _Symbol);
         g_stamp_mso = g_sb.closed_bar_time;
      }
      return;
   }
   if(trade.PositionClosePartial(ticket, close_volume))
   {
     double be_sl_price = open_price + ((type == POSITION_TYPE_BUY) ? BE_Offset_Points * _Point : -BE_Offset_Points * _Point);
     
     if(!MSO_MaySend(_Symbol))
     {
        if(MSO_LogVerbose && g_sb.valid && g_sb.closed_bar_time != g_stamp_mso)
        {
           PrintFormat("[MSO] defer PartialModify sym=%s reason=guard", _Symbol);
           g_stamp_mso = g_sb.closed_bar_time;
        }
        return; 
     }
     if(trade.PositionModify(ticket, be_sl_price, PositionGetDouble(POSITION_TP)))
     {
       MqlTradeRequest req;
       MqlTradeResult res; ZeroMemory(req);
       req.action = TRADE_ACTION_MODIFY; req.position = ticket;
       req.sl = be_sl_price; req.tp = PositionGetDouble(POSITION_TP);
       req.comment = comment + "|P1";
       if(!OrderSend(req, res)) PrintFormat("%s Failed to send position modify request. Error: %d", EVT_PARTIAL, GetLastError());
     }
     else { PHW_LogFailure(trade.ResultRetcode()); } // T037
   }
   else { PHW_LogFailure(trade.ResultRetcode()); } // T037
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
   if(HistoryDealGetInteger(deal_ticket, DEAL_POSITION_ID) == position_id)
   {
       if(HistoryDealGetInteger(deal_ticket, DEAL_ENTRY) == DEAL_ENTRY_IN)
       {
           if(first_in_ticket == 0) first_in_ticket = deal_ticket;
       }
       else
       {
           last_out_ticket = deal_ticket;
       }
       total_profit += HistoryDealGetDouble(deal_ticket, DEAL_PROFIT) + HistoryDealGetDouble(deal_ticket, DEAL_COMMISSION) + HistoryDealGetDouble(deal_ticket, DEAL_SWAP);
   }
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
       conf_eff   = StringToDouble(parts[2]);
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
