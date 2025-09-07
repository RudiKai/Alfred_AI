//+------------------------------------------------------------------+
//|                AAI_TestHarness_CreateTrades.mq5                  |
//|      Programmatically opens/modifies/closes trades for testing   |
//|                   Copyright 2025, AlfredAI Project               |
//|                 https://github.com/rudikai/alfredai              |
//+------------------------------------------------------------------+
#property strict
#property script_show_inputs

#include <Trade\Trade.mqh>

//--- Script Inputs
input ulong  InpMagicNumber = 1337;
input double InpLotSize     = 0.01;
input int    InpSL_TP_Pips  = 15;

//--- Global CTrade object
CTrade g_trade;

//+------------------------------------------------------------------+
//| Script program start function                                    |
//+------------------------------------------------------------------+
void OnStart()
  {
   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(10); // 10 points slippage

   //--- 1. Open a Buy Position
   Print("Step 1: Opening BUY position...");
   double price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double sl = price - InpSL_TP_Pips * point;
   double tp = price + InpSL_TP_Pips * point;

   if(!g_trade.Buy(InpLotSize, _Symbol, price, sl, tp, "TestHarness:Open"))
     {
      PrintFormat("Failed to open BUY position. Error: %d", GetLastError());
      return;
     }

   if(g_trade.ResultDeal() == 0)
     {
      Print("No deal was executed for the buy order.");
      return;
     }

   ulong position_ticket = HistoryDealGetInteger(g_trade.ResultDeal(), DEAL_POSITION_ID);
   PrintFormat("BUY position opened successfully. Position ticket: %I64u", position_ticket);
   Sleep(2000); // Wait 2 seconds

   //--- 2. Modify the Position
   Print("Step 2: Modifying position...");
   sl = price - (InpSL_TP_Pips + 10) * point;
   tp = price + (InpSL_TP_Pips + 10) * point;

   if(!g_trade.PositionModify(position_ticket, sl, tp))
     {
      PrintFormat("Failed to modify position. Error: %d", GetLastError());
      // Continue to closing step anyway
     }
   else
     {
      Print("Position modified successfully.");
     }
   Sleep(2000); // Wait 2 seconds

   //--- 3. Close the Position
   Print("Step 3: Closing position...");
   if(!g_trade.PositionClose(position_ticket))
     {
      PrintFormat("Failed to close position. Error: %d", GetLastError());
     }
   else
     {
      Print("Position closed successfully.");
     }

   Print("Test Harness script finished.");
  }
//+------------------------------------------------------------------+

