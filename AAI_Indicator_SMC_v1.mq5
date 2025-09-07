//+------------------------------------------------------------------+
//|                       AAI_Indicator_SMC_v1.mq5                   |
//|                 v1.1 - Performance Throttling Update             |
//|  (Detects SMC patterns like FVG, OB, BOS for visual analysis)    |
//|              Copyright 2025, AlfredAI Project                    |
//+------------------------------------------------------------------+
#property strict
#property indicator_chart_window
#property version "1.1"

#include <Object.mqh> // For SYMBOL_ARROWUP/DOWN

// Guards in case the environment doesn’t expose these constants
#ifndef SYMBOL_ARROWUP
#define SYMBOL_ARROWUP 233
#endif
#ifndef SYMBOL_ARROWDOWN
#define SYMBOL_ARROWDOWN 234
#endif

// --- Indicator Properties ---
#property indicator_plots 0 // Visual-only indicator

// --- Constants ---
const string SMC_PREFIX = "AAI_SMC_";

// --- Inputs ---
input group "--- Performance Settings ---"
input int  RefreshSeconds     = 2;    // How often to redraw
input int  LookbackBars       = 1000; // How many bars to analyze

input group "--- Display Settings ---"
input bool DrawFVG            = true; // Toggle Fair Value Gaps
input bool DrawOrderBlocks    = true; // Toggle Order Blocks
input bool DrawBOS            = true; // Toggle Break of Structure

// --- Globals ---
bool g_dirty = true; // Dirty flag to trigger redraws

//+------------------------------------------------------------------+
//| Indicator Initialization                                         |
//+------------------------------------------------------------------+
int OnInit()
{
   EventSetTimer(RefreshSeconds);
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Indicator Deinitialization                                       |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   ObjectsDeleteAll(0, SMC_PREFIX);
   ChartRedraw();
}

//+------------------------------------------------------------------+
//| Chart Event Handler                                              |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   // If the user changes settings or the chart, mark for redraw
   if(id == CHARTEVENT_CHART_CHANGE)
   {
      g_dirty = true;
   }
}

//+------------------------------------------------------------------+
//| Indicator Calculation Event                                      |
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
   // If a new bar has appeared, mark for redraw
   if(rates_total != prev_calculated)
   {
      g_dirty = true;
   }
   return(rates_total);
}

//+------------------------------------------------------------------+
//| Timer Event for Throttled Redrawing                              |
//+------------------------------------------------------------------+
void OnTimer()
{
   if(!g_dirty)
   {
      return; // Skip if no changes
   }
      
   MqlRates rates[];
   int bars_to_copy = MathMin(LookbackBars, Bars(_Symbol, _Period));
   if(CopyRates(_Symbol, _Period, 0, bars_to_copy, rates) <= 0)
   {
      return;
   }
   
   // --- Efficient Redraw: Manage a list of required objects ---
   string required_objects[];
   int required_count = 0;

   // --- Loop through bars to find patterns and add required objects to our list ---
   for(int i = 0; i < bars_to_copy - 2; i++)
   {
      // --- FVG Detection ---
      if(DrawFVG)
      {
         // Bullish FVG
         if(rates[i+2].low > rates[i].high)
         {
             ArrayResize(required_objects, required_count + 1);
             required_objects[required_count++] = SMC_PREFIX + "FVG_UP_" + (string)rates[i].time;
         }
         // Bearish FVG
         if(rates[i+2].high < rates[i].low)
         {
             ArrayResize(required_objects, required_count + 1);
             required_objects[required_count++] = SMC_PREFIX + "FVG_DN_" + (string)rates[i].time;
         }
      }

      // --- Order Block Detection ---
      if(DrawOrderBlocks)
      {
         // Bullish OB (last down candle before strong up move)
         if(rates[i+1].close < rates[i+1].open && rates[i].close > rates[i].open && rates[i].high > rates[i+1].high)
         {
            ArrayResize(required_objects, required_count + 1);
            required_objects[required_count++] = SMC_PREFIX + "OB_UP_" + (string)rates[i+1].time;
         }
         // Bearish OB (last up candle before strong down move)
         if(rates[i+1].close > rates[i+1].open && rates[i].close < rates[i].open && rates[i].low < rates[i+1].low)
         {
            ArrayResize(required_objects, required_count + 1);
            required_objects[required_count++] = SMC_PREFIX + "OB_DN_" + (string)rates[i+1].time;
         }
      }

      // --- Break of Structure Detection ---
      if(DrawBOS && i > 10) // Need some lookback for swing points
      {
          int swing_high_idx = iHighest(_Symbol, _Period, MODE_HIGH, 10, i + 1);
          if(swing_high_idx != -1 && rates[i].high > rates[swing_high_idx].high)
          {
              ArrayResize(required_objects, required_count + 1);
              required_objects[required_count++] = SMC_PREFIX + "BOS_UP_" + (string)rates[i].time;
          }

          int swing_low_idx = iLowest(_Symbol, _Period, MODE_LOW, 10, i + 1);
          if(swing_low_idx != -1 && rates[i].low < rates[swing_low_idx].low)
          {
             ArrayResize(required_objects, required_count + 1);
             required_objects[required_count++] = SMC_PREFIX + "BOS_DN_" + (string)rates[i].time;
          }
      }
   }
   
   // --- Cleanup stale objects that are no longer required ---
   for(int i = ObjectsTotal(0, -1, -1) - 1; i >= 0; i--)
   {
      string obj_name = ObjectName(0, i, -1, -1);
      if(StringFind(obj_name, SMC_PREFIX) == 0) // Is it one of our objects?
      {
         bool is_required = false;
         for(int j = 0; j < required_count; j++)
         {
            if(obj_name == required_objects[j])
            {
               is_required = true;
               break;
            }
         }
         if(!is_required)
         {
            ObjectDelete(0, obj_name);
         }
      }
   }
   
   // --- Now, draw all the required objects (update if exists, create if not) ---
   for(int i = 0; i < bars_to_copy - 2; i++)
   {
      // --- Draw FVG ---
      if(DrawFVG)
      {
         // Bullish FVG
         if(rates[i+2].low > rates[i].high)
         {
             DrawFVGObject(SMC_PREFIX + "FVG_UP_" + (string)rates[i].time, rates[i].time, rates[i].high, rates[i+2].low, clrAquamarine);
         }
         // Bearish FVG
         if(rates[i+2].high < rates[i].low)
         {
             DrawFVGObject(SMC_PREFIX + "FVG_DN_" + (string)rates[i].time, rates[i].time, rates[i].low, rates[i+2].high, clrHotPink);
         }
      }

      // --- Draw Order Blocks ---
      if(DrawOrderBlocks)
      {
         // Bullish OB
         if(rates[i+1].close < rates[i+1].open && rates[i].close > rates[i].open && rates[i].high > rates[i+1].high)
         {
            DrawOBObject(SMC_PREFIX + "OB_UP_" + (string)rates[i+1].time, rates[i+1].time, rates[i+1].open, rates[i+1].close, clrDodgerBlue);
         }
         // Bearish OB
         if(rates[i+1].close > rates[i+1].open && rates[i].close < rates[i].open && rates[i].low < rates[i+1].low)
         {
            DrawOBObject(SMC_PREFIX + "OB_DN_" + (string)rates[i+1].time, rates[i+1].time, rates[i+1].open, rates[i+1].close, clrOrangeRed);
         }
      }

      // --- Draw Break of Structure ---
      if(DrawBOS && i > 10)
      {
          int swing_high_idx = iHighest(_Symbol, _Period, MODE_HIGH, 10, i + 1);
          if(swing_high_idx != -1 && rates[i].high > rates[swing_high_idx].high)
          {
              DrawBOSObject(SMC_PREFIX + "BOS_UP_" + (string)rates[i].time, rates[swing_high_idx].time, rates[swing_high_idx].high, rates[i].time, rates[i].high, true);
          }
          int swing_low_idx = iLowest(_Symbol, _Period, MODE_LOW, 10, i + 1);
          if(swing_low_idx != -1 && rates[i].low < rates[swing_low_idx].low)
          {
             DrawBOSObject(SMC_PREFIX + "BOS_DN_" + (string)rates[i].time, rates[swing_low_idx].time, rates[swing_low_idx].low, rates[i].time, rates[i].low, false);
          }
      }
   }
   
   ChartRedraw();
   g_dirty = false; // Reset flag after redraw
}

//+------------------------------------------------------------------+
//| Drawing Helper Functions                                         |
//+------------------------------------------------------------------+
void DrawFVGObject(string name, datetime time, double level1, double level2, color clr)
{
   datetime time2 = time + PeriodSeconds() * 10; // Extend 10 bars into the future
   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_RECTANGLE, 0, time, level1, time2, level2);
      ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
      ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_SOLID);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, name, OBJPROP_BACK, true);
      ObjectSetInteger(0, name, OBJPROP_FILL, true);
   }
   else // Reuse existing object
   {
      ObjectMove(0, name, 0, time, level1);
      ObjectMove(0, name, 1, time2, level2);
   }
}

void DrawOBObject(string name, datetime time, double level1, double level2, color clr)
{
    datetime time2 = time + PeriodSeconds() * 20; // Extend 20 bars
    if(ObjectFind(0, name) < 0)
    {
        ObjectCreate(0, name, OBJ_RECTANGLE, 0, time, level1, time2, level2);
        ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
        ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DOT);
        ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
        ObjectSetInteger(0, name, OBJPROP_BACK, true);
    }
    else
    {
       ObjectMove(0, name, 0, time, level1);
       ObjectMove(0, name, 1, time2, level2);
    }
}

void DrawBOSObject(string name, datetime time1, double price1, datetime time2, double price2, bool is_up)
{
    if(ObjectFind(0, name) < 0)
    {
        ObjectCreate(0, name, OBJ_TREND, 0, time1, price1, time2, price2);
        ObjectSetInteger(0, name, OBJPROP_COLOR, is_up ? clrLime : clrTomato);
        ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DASH);
        ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
        ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);

        // Add an arrow to signify direction
        string arrow_name = name + "_arrow";
        ObjectCreate(0, arrow_name, OBJ_ARROW, 0, time2, price2);
        ObjectSetInteger(0, arrow_name, OBJPROP_ARROWCODE, is_up ? SYMBOL_ARROWUP : SYMBOL_ARROWDOWN);
        ObjectSetInteger(0, arrow_name, OBJPROP_COLOR, is_up ? clrLime : clrTomato);
    }
    else
    {
        ObjectMove(0, name, 0, time1, price1);
        ObjectMove(0, name, 1, time2, price2);
        ObjectMove(0, name + "_arrow", 0, time2, price2);
    }
}

