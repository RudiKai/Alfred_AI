//+------------------------------------------------------------------+
//|                    AlfredAI_Strategy.mq5                         |
//|               Runner EA for the CAlfredStrategy Class            |
//|                   Copyright 2025, AlfredAI Project               |
//|                 https://github.com/rudikai/alfredai              |
//+------------------------------------------------------------------+
#property strict
#property version   "1.0"
#property description "Executor for the AlfredAI strategy module."

#include "AlfredAI_Strategy.mqh"

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

//--- Global strategy object
CAlfredStrategy g_strategy;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   string sym = (InpSymbol == "") ? _Symbol : InpSymbol;
   ENUM_TIMEFRAMES tf = (InpTimeframe == PERIOD_CURRENT) ? _Period : InpTimeframe;
   if(!g_strategy.Init(InpSession, sym, tf, InpLotSize, InpSL_Pips, InpTP_Pips, InpSeed, InpBacktestTag, InpBT_LogOrders))
     {
      return(INIT_FAILED);
     }
   AAI::EnsureTimer(1);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
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

