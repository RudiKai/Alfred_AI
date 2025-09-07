//+------------------------------------------------------------------+
//|                   AlfredAI_BiasCompass.mqh                       |
//|           Computes multi-timeframe directional bias              |
//|                   Copyright 2025, AlfredAI Project               |
//|                 https://github.com/rudikai/alfredai              |
//+------------------------------------------------------------------+
#ifndef ALFREDAI_BIASCOMPASS_MQH
#define ALFREDAI_BIASCOMPASS_MQH

#property strict

#include "AlfredAI_Utils.mqh"

//+------------------------------------------------------------------+
//| Calculates market bias based on moving averages.                 |
//+------------------------------------------------------------------+
class AAI_BiasCompass
  {
private:
   struct MA_Handles
     {
      int fast_ma;
      int slow_ma;
     };

   // Using a simple array as a map from timeframe to handles
   MA_Handles m_handles[10]; // Support up to 10 TFs
   ENUM_TIMEFRAMES m_timeframes[10];
   int        m_count;

public:
   //+------------------------------------------------------------------+
   //| Constructor                                                      |
   //+------------------------------------------------------------------+
              AAI_BiasCompass() : m_count(0)
     {
      ArrayInitialize(m_timeframes, 0);
     }

   //+------------------------------------------------------------------+
   //| Destructor                                                       |
   //+------------------------------------------------------------------+
             ~AAI_BiasCompass()
     {
      for(int i = 0; i < m_count; i++)
        {
         if(m_handles[i].fast_ma != INVALID_HANDLE) IndicatorRelease(m_handles[i].fast_ma);
         if(m_handles[i].slow_ma != INVALID_HANDLE) IndicatorRelease(m_handles[i].slow_ma);
        }
     }

   //+------------------------------------------------------------------+
   //| Initialize (can be called multiple times for different TFs)      |
   //+------------------------------------------------------------------+
   bool     Init(const string symbol, ENUM_TIMEFRAMES tf)
     {
      if(m_count >= 10) return false; // Max TFs reached

      for(int i = 0; i < m_count; i++)
        {
         if(m_timeframes[i] == tf) return true; // Already initialized
        }

      m_handles[m_count].fast_ma = iMA(symbol, tf, 10, 0, MODE_EMA, PRICE_CLOSE);
      m_handles[m_count].slow_ma = iMA(symbol, tf, 20, 0, MODE_EMA, PRICE_CLOSE);

      if(m_handles[m_count].fast_ma == INVALID_HANDLE || m_handles[m_count].slow_ma == INVALID_HANDLE)
        {
         PrintFormat("BiasCompass: Could not create MA handles for %s on %s.", symbol, AAI::TFToString(tf));
         return false;
        }

      m_timeframes[m_count] = tf;
      m_count++;
      return true;
     }

   //+------------------------------------------------------------------+
   //| Get bias for a specific timeframe (-1, 0, 1)                     |
   //+------------------------------------------------------------------+
   int      BiasFor(ENUM_TIMEFRAMES tf)
     {
      int idx = -1;
      for(int i = 0; i < m_count; i++)
        {
         if(m_timeframes[i] == tf)
           {
            idx = i;
            break;
           }
        }
      if(idx == -1) return 0; // Not initialized for this TF

      double fast_ma_val[1];
      double slow_ma_val[1];

      if(CopyBuffer(m_handles[idx].fast_ma, 0, 1, 1, fast_ma_val) != 1 ||
         CopyBuffer(m_handles[idx].slow_ma, 0, 1, 1, slow_ma_val) != 1)
        {
         return 0; // Not enough data
        }

      if(fast_ma_val[0] > slow_ma_val[0]) return 1;  // Bullish
      if(fast_ma_val[0] < slow_ma_val[0]) return -1; // Bearish
      return 0; // Neutral
     }
  };

#endif // ALFREDAI_BIASCOMPASS_MQH

