//+------------------------------------------------------------------+
//|                   AAI_Indicator_ZoneEngine.mq5                   |
//|            v2.8 - Contract Lock: Strength on Plot 0              |
//|      (Detects zones and exports levels for EA consumption)       |
//|                                                                  |
//| Copyright 2025, AlfredAI Project                    |
//+------------------------------------------------------------------+
#property indicator_chart_window
#property strict
#property version "2.8" // As Coder, incremented version for this change

// === BEGIN Spec: Headless + single buffer for Strength ===
#property indicator_plots   1 // Canonical Strength at plot 0
#property indicator_buffers 1

#property indicator_type1   DRAW_NONE
#property indicator_label1  "ZE_Strength"
double ZE_StrengthBuf[];
// === END Spec ===


//--- Indicator Inputs ---
input double MinImpulseMovePips = 10.0;
input bool   ZE_TelemetryEnabled = true;

// --- Struct for analysis results ---
struct ZoneAnalysis
{
   bool     isValid;
   double   proximal;
   double   distal;
   int      baseCandles;
   double   impulseStrength;
   int      strengthScore;
   bool     isFresh;
   bool     hasVolume;
   bool     hasLiquidityGrab;
   datetime time;
};

// --- Forward declarations
ZoneAnalysis FindZone(ENUM_TIMEFRAMES tf, bool isDemand, int shift);
int CalculateZoneStrength(const ZoneAnalysis &zone, ENUM_TIMEFRAMES tf, int shift);
bool HasVolumeConfirmation(ENUM_TIMEFRAMES tf, int shift, int base_candle_index, int num_candles);
bool HasLiquidityGrab(ENUM_TIMEFRAMES tf, int shift, int base_candle_index, bool isDemandZone);

//+------------------------------------------------------------------+
//| Initialization                                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    // === BEGIN Spec: Bind as DATA + series ===
    if(!SetIndexBuffer(0, ZE_StrengthBuf, INDICATOR_DATA))
    {
        Print("ZE SetIndexBuffer failed");
        return(INIT_FAILED);
    }
    ArraySetAsSeries(ZE_StrengthBuf, true);
    // === END Spec ===

    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Deinitialization                                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   // Nothing to do for a headless indicator with no objects
}

//+------------------------------------------------------------------+
//| Main Calculation: Fills buffers for each bar.                    |
//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
{
    const int WARMUP = 100;
    if(rates_total <= WARMUP)
    {
        return(0);
    }

    // --- We only need to calculate for the last closed bar ---
    int closed_bar_shift = 1;
    int closed_bar_idx = rates_total - 1 - closed_bar_shift;

    // --- Determine active zone and strength ---
    ZoneAnalysis demandZone = FindZone(_Period, true, closed_bar_shift);
    ZoneAnalysis supplyZone = FindZone(_Period, false, closed_bar_shift);

    double strength = 0.0;
    double barClose = close[closed_bar_idx];

    bool isInDemand = demandZone.isValid && (barClose >= demandZone.distal && barClose <= demandZone.proximal);
    bool isInSupply = supplyZone.isValid && (barClose >= supplyZone.proximal && barClose <= supplyZone.distal);

    if(isInDemand)
    {
        strength = demandZone.strengthScore;
    }
    else if(isInSupply)
    {
        strength = supplyZone.strengthScore;
    }

    // --- Write to buffers ---
    ZE_StrengthBuf[1] = strength; // Write to closed bar
    ZE_StrengthBuf[0] = strength; // Mirror to current bar

    // --- Telemetry for the calculated bar ---
    if(ZE_TelemetryEnabled)
    {
        static datetime last_log_time = 0;
        if(time[closed_bar_idx] != last_log_time)
        {
            PrintFormat("[ZE_EMIT] t=%s strength=%.1f", TimeToString(time[closed_bar_idx]), strength);
            last_log_time = time[closed_bar_idx];
        }
    }

    return(rates_total);
}

//+------------------------------------------------------------------+
//| Core Zone Finding and Scoring Logic                              |
//+------------------------------------------------------------------+
ZoneAnalysis FindZone(ENUM_TIMEFRAMES tf, bool isDemand, int shift)
{
   ZoneAnalysis analysis;
   analysis.isValid = false;

   MqlRates rates[];
   int lookback = 50;
   int barsToCopy = lookback + 10;

   if(CopyRates(_Symbol, tf, shift, barsToCopy, rates) < barsToCopy)
      return analysis;
   ArraySetAsSeries(rates, true);

   for(int i = 1; i < lookback; i++)
   {
      double impulseStart = isDemand ? rates[i].low : rates[i].high;
      double impulseEnd = isDemand ? rates[i-1].high : rates[i-1].low;
      double impulseMove = MathAbs(impulseEnd - impulseStart);
      if(impulseMove / _Point < MinImpulseMovePips) continue;

      analysis.proximal = isDemand ? rates[i].high : rates[i].low;
      analysis.distal = isDemand ? rates[i].low : rates[i].high;
      analysis.time = rates[i].time;
      analysis.baseCandles = 1;
      analysis.isValid = true;
      analysis.impulseStrength = MathAbs(rates[i-1].close - rates[i].open);
      analysis.isFresh = true;
      // Historical freshness check is complex, default to true
      analysis.hasVolume = HasVolumeConfirmation(tf, shift, i, analysis.baseCandles);
      analysis.hasLiquidityGrab = HasLiquidityGrab(tf, shift, i, isDemand);
      analysis.strengthScore = CalculateZoneStrength(analysis, tf, shift);

      return analysis;
   }

   return analysis;
}

//+------------------------------------------------------------------+
//| Calculates a zone's strength score                               |
//+------------------------------------------------------------------+
int CalculateZoneStrength(const ZoneAnalysis &zone, ENUM_TIMEFRAMES tf, int shift)
{
    if(!zone.isValid) return 0;

    double atr_buffer[1];
    double atr = 0.0;
    int atr_handle = iATR(_Symbol, tf, 14);
    if(atr_handle != INVALID_HANDLE)
    {
      if(CopyBuffer(atr_handle, 0, shift, 1, atr_buffer) > 0)
        atr = atr_buffer[0];
      IndicatorRelease(atr_handle);
    }
    if(atr == 0.0) atr = _Point * 10;

    int explosiveScore = 0;
    if(zone.impulseStrength > atr * 2.0) explosiveScore = 5;
    else if(zone.impulseStrength > atr * 1.5) explosiveScore = 4;
    else if(zone.impulseStrength > atr * 1.0) explosiveScore = 3;
    else explosiveScore = 2;

    int consolidationScore = (zone.baseCandles == 1) ? 5 : (zone.baseCandles <= 3) ? 3 : 1;
    int freshnessBonus = zone.isFresh ? 2 : 0;
    int volumeBonus = zone.hasVolume ? 2 : 0;
    int liquidityBonus = zone.hasLiquidityGrab ? 3 : 0;
    return(MathMin(10, explosiveScore + consolidationScore + freshnessBonus + volumeBonus + liquidityBonus));
}

//+------------------------------------------------------------------+
//| Checks for volume confirmation at the zone's base.               |
//+------------------------------------------------------------------+
bool HasVolumeConfirmation(ENUM_TIMEFRAMES tf, int shift, int base_candle_index, int num_candles)
{
   MqlRates rates[];
   int lookback = 20;
   if(CopyRates(_Symbol, tf, shift + base_candle_index, lookback + num_candles, rates) < lookback)
     return false;
   ArraySetAsSeries(rates, true);
   long total_volume = 0;
   for(int i = 0; i < num_candles; i++) { total_volume += rates[i].tick_volume; }

   long avg_volume_base = 0;
   for(int i = num_candles; i < lookback + num_candles; i++) { avg_volume_base += rates[i].tick_volume; }

   if(lookback == 0) return false;
   double avg_volume = (double)avg_volume_base / lookback;
   return (total_volume > avg_volume * 1.5);
}

//+------------------------------------------------------------------+
//| Detects if the zone was formed by a liquidity grab.              |
//+------------------------------------------------------------------+
bool HasLiquidityGrab(ENUM_TIMEFRAMES tf, int shift, int base_candle_index, bool isDemandZone)
{
   MqlRates rates[];
   int lookback = 10;
   int grab_candle_shift = shift + base_candle_index;

   if(CopyRates(_Symbol, tf, grab_candle_shift, lookback + 1, rates) < lookback + 1)
     return false;
   ArraySetAsSeries(rates, true);

   double grab_candle_wick = isDemandZone ? rates[0].low : rates[0].high;

   double target_liquidity_level = isDemandZone ? rates[1].low : rates[1].high;
   for(int i = 2; i < lookback + 1; i++)
   {
      if(isDemandZone)
         target_liquidity_level = MathMin(target_liquidity_level, rates[i].low);
      else
         target_liquidity_level = MathMax(target_liquidity_level, rates[i].high);
   }

   return (isDemandZone ? (grab_candle_wick < target_liquidity_level) : (grab_candle_wick > target_liquidity_level));
}
//+------------------------------------------------------------------+
