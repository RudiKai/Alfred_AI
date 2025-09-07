//+------------------------------------------------------------------+
//|                     AlfredAI_Journal.mqh                         |
//|      Handles structured, key=value logging with rotation         |
//|                   Copyright 2025, AlfredAI Project               |
//|                 https://github.com/rudikai/alfredai              |
//+------------------------------------------------------------------+
#ifndef ALFREDAI_JOURNAL_MQH
#define ALFREDAI_JOURNAL_MQH

#property strict

#include "AlfredAI_Utils.mqh"
#include "AlfredAI_FileRotator.mqh"

//+------------------------------------------------------------------+
//| Manages the structured logging for the AlfredAI system.          |
//+------------------------------------------------------------------+
class AAI_Journal
  {
private:
   string          m_session;
   AAI_FileRotator m_file;

public:
   //+------------------------------------------------------------------+
   //| Initialize the journal with a session name.                      |
   //+------------------------------------------------------------------+
   bool     Init(const string session)
     {
      m_session = session;
      string file_path = "AAI_Journal_" + m_session + ".log";
      long max_bytes = 10 * 1024 * 1024; // 10 MB
      int max_backups = 5;

      return m_file.Open(file_path, max_bytes, max_backups);
     }

   //+------------------------------------------------------------------+
   //| Write a structured log entry.                                    |
   //+------------------------------------------------------------------+
   bool     Write(const string module,
                  const string event,
                  const string symbol,
                  const ENUM_TIMEFRAMES tf,
                  long         position_id,
                  long         order_id,
                  const string action,
                  double       price,
                  double       qty,
                  double       sl,
                  double       tp,
                  const string reason,
                  const string tag,
                  double       pnl,
                  double       balance,
                  const string comment)
     {
      string keys[] = {
         "ts", "session", "module", "event", "symbol", "tf", "position_id", "order_id",
         "action", "price", "qty", "sl", "tp", "reason", "tag", "pnl", "balance", "comment"
      };

      string vals[];
      ArrayResize(vals, ArraySize(keys));

      vals[0] = AAI::NowIsoUtc();
      vals[1] = m_session;
      vals[2] = module;
      vals[3] = event;
      vals[4] = symbol;
      vals[5] = AAI::TFToString(tf);
      vals[6] = (string)position_id;
      vals[7] = (string)order_id;
      vals[8] = action;
      vals[9] = AAI::DoubleToStrFix(price, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS));
      vals[10] = AAI::DoubleToStrFix(qty, 2);
      vals[11] = AAI::DoubleToStrFix(sl, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS));
      vals[12] = AAI::DoubleToStrFix(tp, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS));
      vals[13] = reason;
      vals[14] = tag;
      vals[15] = AAI::DoubleToStrFix(pnl, 2);
      vals[16] = AAI::DoubleToStrFix(balance, 2);
      vals[17] = comment;

      string log_entry = "AAI|" + AAI::JoinKV(keys, vals, "|");
      return m_file.WriteLine(log_entry);
     }

   //+------------------------------------------------------------------+
   //| Close the journal file.                                          |
   //+------------------------------------------------------------------+
   void     Close()
     {
      m_file.Close();
     }
  };

#endif // ALFREDAI_JOURNAL_MQH

