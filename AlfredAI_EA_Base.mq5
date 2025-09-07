//+------------------------------------------------------------------+
//|                     AlfredAI_EA_Base.mq5                         |
//|                   Copyright 2025, AlfredAI Project               |
//|                 https://github.com/rudikai/alfredai              |
//+------------------------------------------------------------------+
#property strict
#property version   "1.10" // Corrected version format
#property description "Core trading Expert Advisor for the AlfredAI project."

#include "AlfredAI_Utils.mqh"
#include "AlfredAI_Journal.mqh"

//--- Global variables
AAI_Journal g_journal;
string      g_last_event = "Initializing...";
string      g_session_name = "RUDI-001";

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   if(!g_journal.Init(g_session_name))
   {
      Print("Journal initialization failed!");
      return(INIT_FAILED);
   }

   g_last_event = "EA Initialized";
   g_journal.Write("EA_Base", "Init", _Symbol, _Period, 0, 0, "", 0, 0, 0, 0, "", "Ticket004", 0, 0, g_last_event);

   AAI::EnsureTimer(1);

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   g_last_event = "EA Deinitialized. Reason: " + (string)reason;
   g_journal.Write("EA_Base", "Deinit", _Symbol, _Period, 0, 0, "", 0, 0, 0, 0, "", "Ticket004", 0, 0, g_last_event);

   g_journal.Close();
   ObjectsDeleteAll(0, "AAI_HUD_");
   AAI::EnsureTimer(0);
}

//+------------------------------------------------------------------+
//| Expert timer function (for HUD)                                  |
//+------------------------------------------------------------------+
void OnTimer()
{
   string session_text = "Session: " + g_session_name;
   string symbol_text  = "Symbol: " + _Symbol + " (" + AAI::TFToString(_Period) + ")";
   string event_text   = "Last Event: " + g_last_event;

   if(ObjectFind(0, "AAI_HUD_Session") < 0) ObjectCreate(0, "AAI_HUD_Session", OBJ_LABEL, 0, 10, 50);
   ObjectSetString(0, "AAI_HUD_Session", OBJPROP_TEXT, session_text);

   if(ObjectFind(0, "AAI_HUD_Symbol") < 0) ObjectCreate(0, "AAI_HUD_Symbol", OBJ_LABEL, 0, 10, 35);
   ObjectSetString(0, "AAI_HUD_Symbol", OBJPROP_TEXT, symbol_text);

   if(ObjectFind(0, "AAI_HUD_LastEvent") < 0) ObjectCreate(0, "AAI_HUD_LastEvent", OBJ_LABEL, 0, 10, 20);
   ObjectSetString(0, "AAI_HUD_LastEvent", OBJPROP_TEXT, event_text);

   ChartRedraw();
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- Placeholder
}

//+------------------------------------------------------------------+
//| Trade transaction function                                       |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   string event_name = EnumToString(trans.type);
   string action = "";
   long   position_id = 0;
   long   order_id = 0;
   double price = 0, qty = 0, sl = 0, tp = 0, pnl = 0;

   switch(trans.type)
   {
      case TRADE_TRANSACTION_REQUEST:
         action = EnumToString(request.action);
         position_id = (long)request.position;
         order_id = (long)request.order;
         price = request.price;
         qty = request.volume;
         sl = request.sl;
         tp = request.tp;
         break;

      case TRADE_TRANSACTION_DEAL_ADD:
         if(HistoryDealSelect(trans.deal))
         {
            position_id = HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID);
            order_id = HistoryDealGetInteger(trans.deal, DEAL_ORDER);
            price = HistoryDealGetDouble(trans.deal, DEAL_PRICE);
            qty = HistoryDealGetDouble(trans.deal, DEAL_VOLUME);
            sl = HistoryDealGetDouble(trans.deal, DEAL_SL);
            tp = HistoryDealGetDouble(trans.deal, DEAL_TP);
            pnl = HistoryDealGetDouble(trans.deal, DEAL_PROFIT) + HistoryDealGetDouble(trans.deal, DEAL_SWAP) + HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);

            ENUM_DEAL_TYPE deal_type = (ENUM_DEAL_TYPE)HistoryDealGetInteger(trans.deal, DEAL_TYPE);
            ENUM_DEAL_ENTRY deal_entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal, DEAL_ENTRY);

            if(deal_entry == DEAL_ENTRY_IN)
               action = (deal_type == DEAL_TYPE_BUY) ? "BUY" : "SELL";
            else if(deal_entry == DEAL_ENTRY_OUT)
               action = "CLOSE";
            else if(deal_entry == DEAL_ENTRY_INOUT)
               action = "IN/OUT";
         }
         break;

      case TRADE_TRANSACTION_ORDER_ADD:
      case TRADE_TRANSACTION_ORDER_UPDATE:
      case TRADE_TRANSACTION_ORDER_DELETE:
         if(HistoryOrderSelect(trans.order))
         {
            position_id = HistoryOrderGetInteger(trans.order, ORDER_POSITION_ID);
            order_id = (long)trans.order;
            price = HistoryOrderGetDouble(trans.order, ORDER_PRICE_OPEN);
            qty = HistoryOrderGetDouble(trans.order, ORDER_VOLUME_CURRENT);
            sl = HistoryOrderGetDouble(trans.order, ORDER_SL);
            tp = HistoryOrderGetDouble(trans.order, ORDER_TP);
            action = (trans.type == TRADE_TRANSACTION_ORDER_UPDATE) ? "MODIFY" : EnumToString((ENUM_ORDER_TYPE)HistoryOrderGetInteger(trans.order, ORDER_TYPE));
         }
         break;

      case TRADE_TRANSACTION_HISTORY_ADD:
         order_id = (long)trans.order;
         action = "HISTORY_ADD";
         break;

      default:
         position_id = (long)trans.position;
         order_id = (long)trans.order;
         break;
   }

   string comment = "Result: " + AAI::TradeRetcodeToString(result.retcode);
   g_last_event = event_name + " (" + action + ")";
   g_journal.Write("TradeHook", event_name, _Symbol, _Period, position_id, order_id, action, price, qty, sl, tp, "", "Ticket004", pnl, 0, comment);
}
