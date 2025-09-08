//+------------------------------------------------------------------+
//|                     AlfredAI_RiskManager.mqh                     |
//|                   Copyright 2025, AlfredAI Project               |
//|                 https://github.com/rudikai/alfredai              |
//+------------------------------------------------------------------+
#ifndef ALFREDAI_RISKMANAGER_MQH
#define ALFREDAI_RISKMANAGER_MQH

// --- New Code for AlfredAI_RiskManager.mqh ---
#include <AAI/AlfredAI_Config.mqh>

//+------------------------------------------------------------------+
//| AAI_RiskManager Class                                            |
//| Enforces trading limits like daily loss, max trades, and         |
//| equity floor.                                                    |
//+------------------------------------------------------------------+
class AAI_RiskManager
{
private:
   //--- Configuration settings
   double m_daily_loss_limit;
   int    m_max_trades_per_day;
   double m_equity_floor;

   //--- Daily tracking variables
   double m_daily_pnl;
   int    m_daily_trade_count;
   int    m_last_trade_day;

   //--- Checks if it's a new day and resets daily counters
   void CheckForNewDay()
   {
      MqlDateTime dt;
      TimeToStruct(TimeCurrent(), dt);
      int current_day = dt.day_of_year;

      if(m_last_trade_day != current_day)
      {
         ResetDaily();
         m_last_trade_day = current_day;
      }
   }

public:
   //--- Constructor
   AAI_RiskManager() : m_daily_loss_limit(0),
                       m_max_trades_per_day(0),
                       m_equity_floor(0),
                       m_daily_pnl(0),
                       m_daily_trade_count(0),
                       m_last_trade_day(-1)
   {
   }

   //--- Initializes the risk manager with values from the config
   bool Init(AAI_Config &cfg)
   {
      m_daily_loss_limit   = cfg.GetD("DailyLossLimit", 0.0);
      m_max_trades_per_day = cfg.GetI("MaxTradesPerDay", 0);
      m_equity_floor       = cfg.GetD("EquityFloor", 0.0);
      
      // Initialize the day counter
      CheckForNewDay();
      
      PrintFormat("RiskManager Initialized: DailyLossLimit=%.2f, MaxTradesPerDay=%d, EquityFloor=%.2f",
                  m_daily_loss_limit, m_max_trades_per_day, m_equity_floor);
                  
      return true;
   }

   //--- Checks if a new trade is allowed based on the rules
   bool CanTrade(string &reason_out)
   {
      CheckForNewDay(); // Ensure daily stats are current

      // Check Equity Floor
      if(m_equity_floor > 0 && AccountInfoDouble(ACCOUNT_EQUITY) < m_equity_floor)
      {
         reason_out = "Risk:EquityFloor";
         return false;
      }

      // Check Daily Loss Limit (limit is negative, so we check if PnL is more negative)
      if(m_daily_loss_limit < 0 && m_daily_pnl <= m_daily_loss_limit)
      {
         reason_out = "Risk:DailyLoss";
         return false;
      }

      // Check Max Trades Per Day
      if(m_max_trades_per_day > 0 && m_daily_trade_count >= m_max_trades_per_day)
      {
         reason_out = "Risk:MaxTrades";
         return false;
      }

      reason_out = "OK";
      return true;
   }

   //--- Updates daily statistics with the result of a closed trade
   void NoteTradeResult(double pnl)
   {
      CheckForNewDay(); // Ensure we are noting the result for the correct day
      m_daily_pnl += pnl;
      m_daily_trade_count++;
      
      PrintFormat("RiskManager Noted Trade: PnL=%.2f, DailyPnL=%.2f, DailyTrades=%d", 
                  pnl, m_daily_pnl, m_daily_trade_count);
   }

   //--- Resets the daily counters
   void ResetDaily()
   {
      m_daily_pnl = 0.0;
      m_daily_trade_count = 0;
      Print("RiskManager: Daily statistics have been reset.");
   }
};

#endif // ALFREDAI_RISKMANAGER_MQH

