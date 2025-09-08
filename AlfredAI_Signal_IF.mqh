//+------------------------------------------------------------------+
//|                   AlfredAI_Signal_IF.mqh                         |
//|               Abstract interface for signal providers            |
//|                   Copyright 2025, AlfredAI Project               |
//|                 https://github.com/rudikai/alfredai              |
//+------------------------------------------------------------------+
#ifndef ALFREDAI_SIGNAL_IF_MQH
#define ALFREDAI_SIGNAL_IF_MQH

// --- New Code for AlfredAI_Signal_IF.mqh ---
#property strict

#include <AAI/AlfredAI_Config.mqh>
#include <AAI/AlfredAI_Utils.mqh>

//+------------------------------------------------------------------+
//| Structure to hold a trading signal                               |
//+------------------------------------------------------------------+
struct AAI_Signal
  {
   bool   hasSignal;
   int    direction; // 1 for buy, -1 for sell, 0 for none
   double sl;
   double tp;
   string reason;
  };

//+------------------------------------------------------------------+
//| Abstract base class for all signal providers                     |
//+------------------------------------------------------------------+
class AAI_Signal_IF
  {
public:
   virtual bool         Init(AAI_Config &cfg)                = 0;
   virtual AAI_Signal   GetSignal(const string symbol, ENUM_TIMEFRAMES tf) = 0;
   virtual             ~AAI_Signal_IF() {}
  };

//+------------------------------------------------------------------+
//| A no-op signal provider that never generates a signal            |
//+------------------------------------------------------------------+
class AAI_Signal_NoOp : public AAI_Signal_IF
  {
public:
   virtual bool Init(AAI_Config &cfg)
     {
      return true;
     }

   virtual AAI_Signal GetSignal(const string symbol, ENUM_TIMEFRAMES tf)
     {
      AAI_Signal s;
      s.hasSignal = false;
      s.direction = 0;
      s.sl = 0.0;
      s.tp = 0.0;
      s.reason = "NoOp";
      return s;
     }
  };

#endif // ALFREDAI_SIGNAL_IF_MQH

