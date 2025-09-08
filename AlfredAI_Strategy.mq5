//+------------------------------------------------------------------+
//|                    AlfredAI_Strategy.mq5                         |
//|               Runner EA for the CAlfredStrategy Class            |
//|                   Copyright 2025, AlfredAI Project               |
//|                 https://github.com/rudikai/alfredai              |
//+------------------------------------------------------------------+
#property strict
#property version   "1.1"
#property description "Executor for the AlfredAI strategy module."


#include <AAI/AAI_ConfigINI.mqh>                  // if you actually use it
#include <AAI/AAI_SignalProvider_SignalBrain.mqh> // if you actually use it
#include <AAI/AlfredAI_Strategy.mqh>              // moved header: use <AAI/...>


//--- EA Inputs
input string InpSession   = "RUDI-001";
input string InpSymbol    = ""; // Default to chart symbol
input ENUM_TIMEFRAMES InpTimeframe = PERIOD_CURRENT;
input double InpLotSize   = 0.01;
input int    InpSL_Pips   = 20;
input int    InpTP_Pips   = 40;

//--- Backtest Inputs
input string InpBacktestTag = "DefaultRun";
input int    InpSeed        = 42;
input bool   InpBT_LogOrders= true;

// --- AAI config wiring (globals) /////////Startup added
static CAAI_ConfigINI g_cfg;
static string G_SESSION      = "DEFAULT";
static double G_MAX_RISK     = 0.50;   // fallback if INI missing
static bool   G_RISK_ENABLED = true;   // fallback if INI missing


//--- Global strategy object
CAlfredStrategy g_strategy;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   // --- Config: load early so we always see it even on failures
   const string ini = "AAI\\config.ini"; // under MQL5\\Files
   bool cfg_ok = g_cfg.Load(ini);
   if(!cfg_ok)
      PrintFormat("[AAI][INIT] Config '%s' not found -> using defaults", ini);

   // Pull defaults from INI (fall back to existing globals / inputs)
   G_SESSION      = g_cfg.GetString("Session","name",        (InpSession=="" ? G_SESSION : InpSession));
   G_MAX_RISK     = g_cfg.GetDouble("Risk","max_risk",       G_MAX_RISK);
   G_RISK_ENABLED = g_cfg.GetBool  ("Risk","enabled",        G_RISK_ENABLED);

   // --- Resolve inputs
   string sym = (InpSymbol=="" ? _Symbol : InpSymbol);
   ENUM_TIMEFRAMES tf = (InpTimeframe==PERIOD_CURRENT ? _Period : InpTimeframe);

   PrintFormat("[AAI][INIT] Session=%s | Risk.enabled=%s | Risk.max_risk=%.4f",
               G_SESSION, (G_RISK_ENABLED ? "true":"false"), G_MAX_RISK);

   PrintFormat("[AAI][INIT] Calling Strategy.Init(session=%s, sym=%s, tf=%s, lot=%.2f, sl=%d, tp=%d, seed=%d, tag=%s, logOrders=%s)",
               G_SESSION, sym, EnumToString(tf), InpLotSize, InpSL_Pips, InpTP_Pips, InpSeed, InpBacktestTag, (InpBT_LogOrders?"true":"false"));

   // --- Call into strategy with diagnostics
   ResetLastError();
   bool ok = g_strategy.Init(G_SESSION, sym, tf, InpLotSize, InpSL_Pips, InpTP_Pips, InpSeed, InpBacktestTag, InpBT_LogOrders);
   int err = GetLastError();
   if(!ok)
     {
      PrintFormat("[AAI][INIT] Strategy.Init FAILED (GetLastError=%d). Returning INIT_FAILED.", err);
      return(INIT_FAILED);
     }

   // --- Good to go
   AAI::EnsureTimer(1);
   Print("[AAI][INIT] Strategy.Init OK, timer=1s");
   return(INIT_SUCCEEDED);
  }


//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
    PrintFormat("[AAI] Deinit: Session=%s | reason=%d", G_SESSION, reason);
   g_strategy.Deinit();
  }

//+------------------------------------------------------------------+
//| OnTester function for backtest results                           |
//+------------------------------------------------------------------+
double OnTester()
  {
   // This function can be used to return a custom value for optimization
   return(0.0);
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   g_strategy.OnTick();
  }

//+------------------------------------------------------------------+
//| Expert timer function                                            |
//+------------------------------------------------------------------+
void OnTimer()
  {
   g_strategy.OnTimer();
  }

//+------------------------------------------------------------------+
//| Trade transaction function                                       |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   g_strategy.OnTradeTransaction(trans, request, result);
  }
//+------------------------------------------------------------------+
