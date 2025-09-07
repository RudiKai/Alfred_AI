//+------------------------------------------------------------------+
//|                 AAI_Indicator_ZE_Visualizer.mq5                  |
//|                 v1.2 - Performance Throttling Update             |
//|      (Draws Supply/Demand zones for manual analysis only)        |
//|              Copyright 2025, AlfredAI Project                    |
//+------------------------------------------------------------------+
#property indicator_chart_window
#property strict
#property version "1.2"
#property description "A visual-only indicator for displaying Supply/Demand zones. Does not provide data to EAs."

// --- This is a visual-only indicator and does not export data buffers ---
#property indicator_buffers 0
#property indicator_plots   0

// --- Performance Settings (Ticket 16) ---
input group "--- Performance Settings ---"
input int    RefreshRateSeconds = 2;       // How often to check for redraws (in seconds)
input int    LookbackBars       = 1000;   // How many bars back to search for zones

// --- General Settings ---
input group "--- General Settings ---"
input double MinImpulseMovePips = 10.0;    // Minimum size of an impulse move to form a zone

// --- Zone Detection Logic ---
input group "--- Zone Detection Logic ---"
input int  ZoneDurationBars     = 100;    // How long a zone should extend into the future
input bool EnableBreakoutRemoval= true;   // Should zones be removed once price breaks through them?
input bool RequireBodyClose     = true;   // (If above is true) Does body need to close beyond zone to break it?

// --- Feature Toggles ---
input group "--- Feature Toggles ---"
input bool EnableTimeDecay      = true;   // Should zones fade over time?
input int  TimeDecayBars        = 20;     // How many bars until a zone is considered 'old'
input bool EnableMagnetForecast = true;   // Draw a line at the most likely price magnet?

// --- Zone Display Settings ---
input group "--- Zone Display Settings ---"
input color DemandColorHTF      = clrLightGreen;
input color DemandColorLTF      = clrGreen;
input color SupplyColorHTF      = clrHotPink;
input color SupplyColorLTF      = clrRed;
input bool  BorderOnlyHTF       = true;  // Only draw the border for HTF zones?

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

// --- Mitigated zones tracker ---
string g_mitigated_zones[];
int    g_mitigated_zones_count = 0;

// --- Global dirty flag for throttled redraw ---
bool g_dirty = true;


//+------------------------------------------------------------------+
//| Initialization                                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   ArrayResize(g_mitigated_zones, 0);
   EventSetTimer(RefreshRateSeconds);
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Deinitialization                                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   // --- Clean up all objects created by this indicator ---
   ObjectsDeleteAll(0, "DZone_");
   ObjectsDeleteAll(0, "SZone_");
   ObjectsDeleteAll(0, "MagnetLine_");
   ChartRedraw();
}

//+------------------------------------------------------------------+
//| OnCalculate: Sets dirty flag on new bars.                        |
//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &t[],
                const double   &o[],
                const double   &h[],
                const double   &l[],
                const double   &c[],
                const long     &tick_volume[],
                const long     &volume[],
                const int      &sp[])
{
   // --- If a new bar has formed, mark the chart as dirty for a redraw ---
   if(rates_total != prev_calculated)
   {
      g_dirty = true;
   }
   
   // --- Mitigation check still runs once per bar ---
   static datetime lastBarTime = 0;
   if(rates_total > 0 && t[rates_total-1] != lastBarTime)
   {
      if(EnableBreakoutRemoval)
      {
         CheckForMitigations(rates_total, l, h, c);
      }
      lastBarTime = t[rates_total-1];
   }
   return(rates_total);
}

//+------------------------------------------------------------------+
//| Timer: Redraws all visual objects if chart is dirty.             |
//+------------------------------------------------------------------+
void OnTimer()
{
   if(!g_dirty)
   {
      return; // Nothing to do
   }

   DrawAllZones();
   if(EnableMagnetForecast)
   {
      DrawMagnetLine();
   }
      
   ChartRedraw();
   g_dirty = false; // Reset the flag
}

//+------------------------------------------------------------------+
//| Chart Event: Sets dirty flag on manual changes.                  |
//+------------------------------------------------------------------+
void OnChartEvent(const int id,const long &l,const double &d,const string &s)
{
   if(id==CHARTEVENT_CHART_CHANGE || id == CHARTEVENT_OBJECT_CHANGE)
   {
      g_dirty = true;
   }
}

//+------------------------------------------------------------------+
//| Draw all zones for each timeframe                                |
//+------------------------------------------------------------------+
void DrawAllZones()
{
   DrawZones(_Period,    "LTF", DemandColorLTF, SupplyColorLTF, false);
   DrawZones(PERIOD_M15, "M15", DemandColorLTF, SupplyColorLTF, false);
   DrawZones(PERIOD_M30, "M30", DemandColorLTF, SupplyColorLTF, false);
   DrawZones(PERIOD_H1,  "H1",  DemandColorHTF, SupplyColorHTF, BorderOnlyHTF);
   DrawZones(PERIOD_H2,  "H2",  DemandColorHTF, SupplyColorHTF, BorderOnlyHTF);
   DrawZones(PERIOD_H4,  "H4",  DemandColorHTF, SupplyColorHTF, BorderOnlyHTF);
   DrawZones(PERIOD_D1,  "D1",  DemandColorHTF, SupplyColorHTF, BorderOnlyHTF);
}

//+------------------------------------------------------------------+
//| Find and Draw one supply/demand rectangle                        |
//+------------------------------------------------------------------+
void DrawZones(ENUM_TIMEFRAMES tf, string suffix, color clrD, color clrS, bool isBorderOnly)
{
   ZoneAnalysis demandZone = FindZone(tf, true);
   if(demandZone.isValid)
   {
      datetime extT = demandZone.time + PeriodSeconds(tf) * ZoneDurationBars;
      DrawRect("DZone_" + suffix, demandZone.time, demandZone.proximal, extT, demandZone.distal, clrD, isBorderOnly, demandZone);
   }
   else { ObjectDelete(0, "DZone_" + suffix); }

   ZoneAnalysis supplyZone = FindZone(tf, false);
   if(supplyZone.isValid)
   {
      datetime extT = supplyZone.time + PeriodSeconds(tf) * ZoneDurationBars;
      DrawRect("SZone_" + suffix, supplyZone.time, supplyZone.proximal, extT, supplyZone.distal, clrS, isBorderOnly, supplyZone);
   }
   else { ObjectDelete(0, "SZone_" + suffix); }
}

//+------------------------------------------------------------------+
//| Core Zone Finding and Scoring Logic                              |
//+------------------------------------------------------------------+
ZoneAnalysis FindZone(ENUM_TIMEFRAMES tf, bool isDemand)
{
   ZoneAnalysis analysis;
   analysis.isValid = false;
   
   MqlRates rates[];
   // Use the lesser of LookbackBars or available bars
   int bars_available = Bars(_Symbol, tf);
   int bars_to_scan = MathMin(LookbackBars, bars_available);
   
   if(CopyRates(_Symbol, tf, 0, bars_to_scan, rates) < bars_to_scan) return analysis;
   ArraySetAsSeries(rates, true);

   for(int i = 1; i < bars_to_scan -1; i++) // -1 to ensure we can look at i-1
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
      analysis.isFresh = IsZoneFresh(GetZoneID(isDemand ? "DZone_" : "SZone_", tf, analysis.time));
      analysis.hasVolume = HasVolumeConfirmation(tf, i, 1);
      analysis.hasLiquidityGrab = HasLiquidityGrab(tf, i + analysis.baseCandles, isDemand);
      analysis.strengthScore = CalculateZoneStrength(analysis, tf);
      
      return analysis; // Return the first valid zone found
   }
   
   return analysis;
}

//+------------------------------------------------------------------+
//| Calculates a zone's strength score                               |
//+------------------------------------------------------------------+
int CalculateZoneStrength(const ZoneAnalysis &zone, ENUM_TIMEFRAMES tf)
{
    if(!zone.isValid) return 0;

    double atr_buffer[1];
    double atr = 0.0;
    int atr_handle_tf = iATR(_Symbol, tf, 14);
    if(atr_handle_tf != INVALID_HANDLE)
    {
      if(CopyBuffer(atr_handle_tf, 0, 1, 1, atr_buffer) > 0) atr = atr_buffer[0];
      IndicatorRelease(atr_handle_tf);
    }
    if(atr == 0.0) return 1;

    int explosiveScore = 0;
    if(zone.impulseStrength > atr * 2.0) explosiveScore = 5;
    else if(zone.impulseStrength > atr * 1.5) explosiveScore = 4;
    else if(zone.impulseStrength > atr * 1.0) explosiveScore = 3;
    else explosiveScore = 2;

    int consolidationScore = 0;
    if(zone.baseCandles == 1) consolidationScore = 5;
    else if(zone.baseCandles <= 3) consolidationScore = 3;
    else consolidationScore = 1;
    
    int freshnessBonus = 0;
    if(EnableTimeDecay && zone.isFresh) freshnessBonus = 2;

    int volumeBonus = zone.hasVolume ? 2 : 0;
    int liquidityBonus = zone.hasLiquidityGrab ? 3 : 0;

    return(MathMin(10, explosiveScore + consolidationScore + freshnessBonus + volumeBonus + liquidityBonus));
}

//+------------------------------------------------------------------+
//| Rectangle drawer (stores data in tooltip for debugging)          |
//+------------------------------------------------------------------+
void DrawRect(string name, datetime t1, double p1, datetime t2, double p2, color clr, bool borderOnly, const ZoneAnalysis &analysis)
{
   if(ObjectFind(0,name) < 0) ObjectCreate(0,name,OBJ_RECTANGLE,0,t1,p1,t2,p2);
   else { ObjectMove(0,name,0,t1,p1); ObjectMove(0,name,1,t2,p2); }
   
   ObjectSetInteger(0,name,OBJPROP_COLOR,   clr);
   ObjectSetInteger(0,name,OBJPROP_BGCOLOR, ColorToARGB(clr, 30));
   ObjectSetInteger(0,name,OBJPROP_FILL,    !borderOnly);
   ObjectSetInteger(0,name,OBJPROP_WIDTH,   borderOnly ? 3 : 1);
   ObjectSetInteger(0,name,OBJPROP_BACK,    true);
   
   string tooltip = (string)analysis.strengthScore + ";" + (string)(analysis.isFresh ? 1 : 0) + ";" + (string)(analysis.hasVolume ? 1 : 0) + ";" + (string)(analysis.hasLiquidityGrab ? 1 : 0);
   ObjectSetString(0, name, OBJPROP_TOOLTIP, tooltip);
   
   string fresh_prefix = (EnableTimeDecay && analysis.isFresh) ? "★ " : "";
   string liq_prefix = analysis.hasLiquidityGrab ? "$ " : "";
   string volume_suffix = analysis.hasVolume ? " (V)" : "";
   ObjectSetString(0, name, OBJPROP_TEXT, liq_prefix + fresh_prefix + "Strength: " + (string)analysis.strengthScore + "/10" + volume_suffix);
}

//+------------------------------------------------------------------+
//| Draws a magnet line at the strongest zone's proximal line        |
//+------------------------------------------------------------------+
void DrawMagnetLine()
{
    string zoneNames[] = { "DZone_LTF","SZone_LTF", "DZone_M15","SZone_M15", "DZone_M30","SZone_M30", "DZone_H1","SZone_H1", "DZone_H2","SZone_H2", "DZone_H4","SZone_H4", "DZone_D1","SZone_D1"};
    double best_score = -1;
    double magnet_price = 0;
    string magnet_name = "MagnetLine_Global";

    for(int i = 0; i < ArraySize(zoneNames); i++)
    {
        string zName = zoneNames[i];
        if(ObjectFind(0, zName) >= 0)
        {
            string tooltip = ObjectGetString(0, zName, OBJPROP_TOOLTIP);
            string parts[];
            if(StringSplit(tooltip, ';', parts) > 0)
            {
                int score = (int)StringToInteger(parts[0]);
                if(score > best_score)
                {
                    best_score = score;
                    magnet_price = ObjectGetDouble(0, zName, OBJPROP_PRICE, 0); // Proximal line
                }
            }
        }
    }

    if(magnet_price > 0)
    {
        if(ObjectFind(0, magnet_name) < 0) ObjectCreate(0, magnet_name, OBJ_HLINE, 0, 0, magnet_price);
        else ObjectMove(0, magnet_name, 0, 0, magnet_price);
        ObjectSetInteger(0, magnet_name, OBJPROP_COLOR, clrGold);
        ObjectSetInteger(0, magnet_name, OBJPROP_STYLE, STYLE_DOT);
        ObjectSetInteger(0, magnet_name, OBJPROP_WIDTH, 2);
    }
    else
    {
        ObjectDelete(0, magnet_name);
    }
}

// --- FUNCTIONS FOR FRESHNESS TRACKING ---
string GetZoneID(string prefix, ENUM_TIMEFRAMES tf, datetime time){ return prefix + EnumToString(tf) + "_" + (string)time; }
bool IsZoneFresh(string zone_id){ for(int i=0;i<g_mitigated_zones_count;i++){if(g_mitigated_zones[i]==zone_id)return false;} return true; }
void AddToMitigatedList(string zone_id){ if(IsZoneFresh(zone_id)){int s=g_mitigated_zones_count+1;ArrayResize(g_mitigated_zones,s);g_mitigated_zones[s-1]=zone_id;g_mitigated_zones_count=s;}}

void CheckForMitigations(int rates_total, const double &low[], const double &high[], const double &close[])
{
   if(rates_total < 2) return;
   
   double price_point = RequireBodyClose ? close[rates_total-2] : (low[rates_total-2] + high[rates_total-2]) / 2;
   
   string z_types[]={"DZone_","SZone_"}, tf_s[]={"LTF","M15","M30","H1","H2","H4","D1"};
   for(int i=0;i<ArraySize(z_types);i++){for(int j=0;j<ArraySize(tf_s);j++){string n=z_types[i]+tf_s[j];if(ObjectFind(0,n)>=0){datetime t=(datetime)ObjectGetInteger(0,n,OBJPROP_TIME,0);double p1=ObjectGetDouble(0,n,OBJPROP_PRICE,0),p2=ObjectGetDouble(0,n,OBJPROP_PRICE,1);bool isD=(z_types[i]=="DZone_");double prox=isD?MathMax(p1,p2):MathMin(p1,p2);if((isD&&price_point<=prox)||(!isD&&price_point>=prox)){AddToMitigatedList(GetZoneID(z_types[i],_Period,t));}}}}
}

// --- FUNCTION FOR VOLUME CONFIRMATION ---
bool HasVolumeConfirmation(ENUM_TIMEFRAMES tf, int bar_index, int num_candles)
{
   MqlRates rates[];
   int lookback = 20;
   if(CopyRates(_Symbol, tf, bar_index - num_candles, lookback + num_candles, rates) < lookback) return false;
   ArraySetAsSeries(rates, true);
   
   long total_volume = 0;
   for(int i = 0; i < num_candles; i++) { total_volume += rates[i].tick_volume; }
   
   long avg_volume_base = 0;
   for(int i = num_candles; i < lookback + num_candles; i++) { avg_volume_base += rates[i].tick_volume; }
   
   if(lookback == 0) return false;
   double avg_volume = (double)avg_volume_base / lookback;
   return (total_volume > avg_volume * 1.5);
}

// --- FUNCTION FOR LIQUIDITY GRAB DETECTION ---
bool HasLiquidityGrab(ENUM_TIMEFRAMES tf, int bar_index, bool isDemandZone)
{
   MqlRates rates[];
   int lookback = 10;
   if(CopyRates(_Symbol, tf, bar_index, lookback, rates) < lookback) return false;
   ArraySetAsSeries(rates, true);
   
   double grab_candle_wick = isDemandZone ? rates[0].low : rates[0].high;
   
   double target_liquidity_level = isDemandZone ? rates[1].low : rates[1].high;
   for(int i = 2; i < lookback; i++)
   {
      if(isDemandZone)
         target_liquidity_level = MathMin(target_liquidity_level, rates[i].low);
      else
         target_liquidity_level = MathMax(target_liquidity_level, rates[i].high);
   }
   
   return (isDemandZone ? (grab_candle_wick < target_liquidity_level) : (grab_candle_wick > target_liquidity_level));
}

