//+------------------------------------------------------------------+
//|                    AlfredAI_Strategy.mqh                         |
//|                   Copyright 2025, AlfredAI Project               |
//|                 https://github.com/rudikai/alfredai              |
//+------------------------------------------------------------------+
// --- New Code for AlfredAI_Strategy.mqh ---
#ifndef ALFREDAI_STRATEGY_MQH
#define ALFREDAI_STRATEGY_MQH

#property strict

#include <AAI/AlfredAI_Config.mqh>
#include <AAI/AlfredAI_Utils.mqh>
#include <AAI/AlfredAI_Journal.mqh>
#include <AAI/AlfredAI_RiskManager.mqh>
#include <AAI/AlfredAI_Signal_IF.mqh>
#include <AAI/AlfredAI_Alerts.mqh>
#include <Trade\Trade.mqh>

//--- A dummy signal provider for testing purposes
class AAI_Signal_TestDummy : public AAI_Signal_IF
{
public:
   virtual bool Init(AAI_Config &cfg)
   {
      // Parameter is unused in this dummy implementation
      return true;
   }

   virtual AAI_Signal GetSignal(const string symbol, ENUM_TIMEFRAMES tf)
   {
      // Parameters are unused in this dummy implementation
      AAI_Signal signal;
      signal.hasSignal = false; // Set to true to test trade execution
      signal.direction = 1;     // 1 for buy, -1 for sell
      signal.sl = 0;
      signal.tp = 0;
      signal.reason = "TestSignal";
      return signal;
   }
};

//+------------------------------------------------------------------+
//| CAlfredStrategy Class                                            |
//| Encapsulates the core trading logic and state.                   |
//+------------------------------------------------------------------+
class CAlfredStrategy
{
private:
   //--- Modules
   AAI_Config        m_config;
   AAI_Journal       m_journal;
   AAI_RiskManager   m_risk_manager;
   AAI_Alerts        m_alerts;
   AAI_Signal_IF    *m_signal_provider;
   CTrade            m_trade;

   //--- State
   bool              m_is_initialized;
   string            m_session;
   string            m_symbol;
   ENUM_TIMEFRAMES   m_timeframe;
   double            m_lot_size;
   int               m_sl_pips;
   int               m_tp_pips;
   
   //--- Backtest State
   string            m_backtest_tag;
   bool              m_bt_log_orders;


public:
   //--- Constructor
   CAlfredStrategy() : m_is_initialized(false), m_signal_provider(NULL) {}

   //--- Destructor
   ~CAlfredStrategy()
   {
      if(m_signal_provider != NULL)
      {
         delete m_signal_provider;
         m_signal_provider = NULL;
      }
   }

   //--- Initialization
   bool Init(string session, string symbol, ENUM_TIMEFRAMES tf, double lot, int sl, int tp, int seed, string backtest_tag, bool bt_log_orders)
   {
      m_session = session;
      m_symbol = symbol;
      m_timeframe = tf;
      m_lot_size = lot;
      m_sl_pips = sl;
      m_tp_pips = tp;
      m_backtest_tag = backtest_tag;
      m_bt_log_orders = bt_log_orders;
      
      m_config.Load("AlfredAI_Config.ini");
      m_journal.Init(m_session);
      m_risk_manager.Init(m_config);
      m_alerts.Init(m_config);
      
      //--- In a real system, you might choose the signal provider based on config
      m_signal_provider = new AAI_Signal_TestDummy();
      if(!m_signal_provider.Init(m_config))
      {
         m_journal.Write("Strategy", "Error", m_symbol, m_timeframe, 0, 0, "", 0.0, 0.0, 0.0, 0.0, "SignalProviderInitFail", "", 0.0, 0.0, "Failed to initialize signal provider.");
         return false;
      }

      m_trade.SetExpertMagicNumber(m_config.GetI("MagicNumber", 1337));
      m_trade.SetDeviationInPoints(m_config.GetI("Slippage", 10));

      //--- Backtest-specific Initialization
      if(MQLInfoInteger(MQL_TESTER))
      {
         //--- 1. Seed the random number generator for deterministic tests
         MathSrand(seed);
         
         //--- 2. Log the start of the backtest run
         string comment = "seed=" + (string)seed;
         m_journal.Write("Strategy", "BacktestStart", m_symbol, m_timeframe, 0, 0, "", 0.0, 0.0, 0.0, 0.0, "Tester", m_backtest_tag, 0.0, AccountInfoDouble(ACCOUNT_BALANCE), comment);
      }
      
      m_is_initialized = true;
      return true;
   }

   //--- Deinitialization
   void Deinit()
   {
      if(!m_is_initialized) return;
      
      //--- Backtest Logging: Log end of test
      if(MQLInfoInteger(MQL_TESTER))
      {
         m_journal.Write("Strategy", "BacktestEnd", m_symbol, m_timeframe, 0, 0, "", 0.0, 0.0, 0.0, 0.0, "Tester", m_backtest_tag, 0.0, AccountInfoDouble(ACCOUNT_BALANCE), "done");
      }
      
      m_journal.Close();
   }

   //--- OnTimer Logic
   void OnTimer()
   {
      if(!m_is_initialized || m_signal_provider == NULL) return;
      
      //--- In tester mode, logic runs on every tick via OnTick, not OnTimer
      if(MQLInfoInteger(MQL_TESTER)) return;

      string reason = "";
      if(!m_risk_manager.CanTrade(reason))
      {
         // Journaling for risk block is handled inside CanTrade
         return;
      }
      
      AAI_Signal signal = m_signal_provider.GetSignal(m_symbol, m_timeframe);
      if(signal.hasSignal)
      {
         ExecuteTrade(signal);
      }
   }
   
   //--- OnTick Logic (for backtesting and live)
   void OnTick()
   {
      if(!m_is_initialized || m_signal_provider == NULL) return;

      //--- In live mode, OnTimer is used.
      if(!MQLInfoInteger(MQL_TESTER)) return;
      
      //--- This block will execute on every tick during a backtest
      string reason = "";
      if(!m_risk_manager.CanTrade(reason))
      {
         return;
      }
      
      AAI_Signal signal = m_signal_provider.GetSignal(m_symbol, m_timeframe);
      if(signal.hasSignal)
      {
         ExecuteTrade(signal);
      }
   }
   
   //--- Trade Transaction Handler
   void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
   {
      //--- Backtest Logging for Transactions
      if(MQLInfoInteger(MQL_TESTER) && m_bt_log_orders)
      {
         string comment = StringFormat("type=%s | pos=%d | ord=%d", 
            EnumToString(trans.type), (long)trans.position, (long)trans.order);
            
         m_journal.Write("Strategy", "Transaction", m_symbol, m_timeframe, 
            (long)trans.position, (long)trans.order, EnumToString(trans.type), 
            trans.price, trans.volume, 0.0, 0.0, 
            "BT:Txn", m_backtest_tag, 0.0, AccountInfoDouble(ACCOUNT_BALANCE), comment);
      }
   }

private:
   //--- Trade Execution Logic
   void ExecuteTrade(AAI_Signal &signal)
   {
      double price = SymbolInfoDouble(m_symbol, signal.direction == 1 ? SYMBOL_ASK : SYMBOL_BID);
      double sl = signal.sl;
      double tp = signal.tp;
      
      if(m_sl_pips > 0)
         sl = price + (signal.direction == 1 ? -(double)m_sl_pips * _Point : (double)m_sl_pips * _Point);
      
      if(m_tp_pips > 0)
         tp = price + (signal.direction == 1 ? (double)m_tp_pips * _Point : -(double)m_tp_pips * _Point);
         
      if(signal.direction == 1)
         m_trade.Buy(m_lot_size, m_symbol, price, sl, tp, signal.reason);
      else if(signal.direction == -1)
         m_trade.Sell(m_lot_size, m_symbol, price, sl, tp, signal.reason);
   }
};

#endif // ALFREDAI_STRATEGY_MQH

