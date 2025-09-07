//+------------------------------------------------------------------+
//|                       AAI_Indicator_SMC.mq5                      |
//|                 v1.0 - Initial Headless Framework                |
//|  (Detects SMC patterns like FVG, OB, BOS for EA consumption)     |
//|                                                                  |
//| Copyright 2025, AlfredAI Project                                 |
//+------------------------------------------------------------------+
#property strict
#property indicator_chart_window
#property version "1.0"

// --- Indicator Buffers & Plots (Headless Export) ---
#property indicator_buffers 3
#property indicator_plots   3

// --- Buffer 0: SMC Signal ---
#property indicator_type1   DRAW_NONE
#property indicator_label1  "SMC_Signal"
double SignalBuffer[];

// --- Buffer 1: SMC Confidence ---
#property indicator_type2   DRAW_NONE
#property indicator_label2  "SMC_Confidence"
double ConfidenceBuffer[];

// --- Buffer 2: SMC Reason Code ---
#property indicator_type3   DRAW_NONE
#property indicator_label3  "SMC_Reason"
double ReasonBuffer[];

// --- Indicator Inputs ---
input group "SMC Detection Settings"
input bool UseFVG = true;                // Enable Fair Value Gap detection
input bool UseOB  = true;                // Enable Order Block detection
input bool UseBOS = true;                // Enable Break of Structure detection
input int  WarmupBars = 100;             // Bars to allow for stabilization

input group "Thresholds"
input double FVG_MinPips = 1.0;          // Minimum FVG size in pips to be considered valid
input int    OB_Lookback = 20;           // How far back to look for a valid Order Block
input int    BOS_Lookback = 50;          // How far back to look for a swing high/low for BOS

// --- Enums for Clarity ---
enum ENUM_SMC_REASON
{
    REASON_NONE,
    REASON_BULL_FVG,
    REASON_BEAR_FVG,
    REASON_BULL_OB,
    REASON_BEAR_OB,
    REASON_BULL_BOS,
    REASON_BEAR_BOS,
    REASON_BULL_CONFLUENCE, // Multiple bullish reasons
    REASON_BEAR_CONFLUENCE  // Multiple bearish reasons
};

// --- Globals for one-time logging ---
static datetime g_last_log_time = 0;

//+------------------------------------------------------------------+
//| Custom indicator initialization function                         |
//+------------------------------------------------------------------+
int OnInit()
{
    // --- Bind all 3 data buffers ---
    SetIndexBuffer(0, SignalBuffer,   INDICATOR_DATA);
    SetIndexBuffer(1, ConfidenceBuffer, INDICATOR_DATA);
    SetIndexBuffer(2, ReasonBuffer,   INDICATOR_DATA);

    // --- Set buffers as series arrays ---
    ArraySetAsSeries(SignalBuffer,   true);
    ArraySetAsSeries(ConfidenceBuffer, true);
    ArraySetAsSeries(ReasonBuffer,   true);

    // --- Set empty values for buffers ---
    PlotIndexSetDouble(0, PLOT_EMPTY_VALUE, 0.0);
    PlotIndexSetDouble(1, PLOT_EMPTY_VALUE, 0.0);
    PlotIndexSetDouble(2, PLOT_EMPTY_VALUE, 0.0);
    IndicatorSetInteger(INDICATOR_DIGITS, 0);

    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Deinitialization                                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    // No objects to clean up in a headless indicator
}

//+------------------------------------------------------------------+
//| Custom indicator iteration function                              |
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
    if(rates_total < WarmupBars)
    {
        return(0);
    }

    int start_bar;
    if(prev_calculated == 0)
    {
       start_bar = rates_total - 2; // Calculate all historical data except the current bar
    }
    else
    {
       start_bar = rates_total - prev_calculated;
       // On new bars, calculate one extra previous bar to handle potential repaints
       if(start_bar < rates_total - 1)
       {
          start_bar++;
       }
    }


    for(int i = start_bar; i >= 1; i--) // Process from oldest new bar to the last closed bar
    {
        // --- Initialize outputs for this bar ---
        int signal = 0;
        double confidence = 0.0;
        ENUM_SMC_REASON reason = REASON_NONE;
        int pattern_count = 0;

        // --- 1. Placeholder FVG Detection ---
        if(UseFVG && i < rates_total - 2)
        {
            // Bullish FVG: low of bar i is higher than high of bar i+2
            if(low[i] > high[i+2] && (low[i] - high[i+2]) / _Point >= FVG_MinPips)
            {
                signal += 1;
                confidence += 4.0;
                reason = REASON_BULL_FVG;
                pattern_count++;
            }
            // Bearish FVG: high of bar i is lower than low of bar i+2
            else if(high[i] < low[i+2] && (low[i+2] - high[i]) / _Point >= FVG_MinPips)
            {
                signal -= 1;
                confidence += 4.0;
                reason = REASON_BEAR_FVG;
                pattern_count++;
            }
        }
        
        // --- 2. Placeholder Order Block (OB) Detection ---
        if(UseOB && i < rates_total - 1)
        {
             // Bullish OB: Last down candle before a strong up move
             if(close[i+1] < open[i+1] && close[i] > open[i] && high[i] > high[i+1])
             {
                signal += 1;
                confidence += 3.0;
                reason = REASON_BULL_OB;
                pattern_count++;
             }
             // Bearish OB: Last up candle before a strong down move
             else if(close[i+1] > open[i+1] && close[i] < open[i] && low[i] < low[i+1])
             {
                signal -= 1;
                confidence += 3.0;
                reason = REASON_BEAR_OB;
                pattern_count++;
             }
        }

        // --- 3. Placeholder Break of Structure (BOS) Detection ---
        if(UseBOS && i < rates_total - BOS_Lookback)
        {
            // Find highest high in lookback period
            int hh_idx = iHighest(_Symbol, _Period, MODE_HIGH, BOS_Lookback, i + 1);
            if(hh_idx != -1)
            {
               double swing_high = high[hh_idx];
               if(high[i] > swing_high)
               {
                   signal += 1;
                   confidence += 5.0;
                   reason = REASON_BULL_BOS;
                   pattern_count++;
               }
            }
            
            // Find lowest low in lookback period
            int ll_idx = iLowest(_Symbol, _Period, MODE_LOW, BOS_Lookback, i + 1);
            if(ll_idx != -1)
            {
               double swing_low = low[ll_idx];
               if(low[i] < swing_low)
               {
                   signal -= 1;
                   confidence += 5.0;
                   reason = REASON_BEAR_BOS;
                   pattern_count++;
               }
            }
        }

        // --- 4. Finalize Signal and Confidence ---
        double final_signal = 0;
        if(signal > 0) final_signal = 1;
        if(signal < 0) final_signal = -1;
        
        if(pattern_count > 1) // If more than one pattern agrees
        {
           confidence += 2.0; // Confluence bonus
           if(final_signal > 0) reason = REASON_BULL_CONFLUENCE;
           if(final_signal < 0) reason = REASON_BEAR_CONFLUENCE;
        }

        // --- 5. Write to Buffers ---
        SignalBuffer[i]     = final_signal;
        ConfidenceBuffer[i] = MathMin(10.0, confidence); // Clamp confidence to 0-10
        ReasonBuffer[i]     = (final_signal != 0) ? (double)reason : (double)REASON_NONE;
    }
    
    // --- Mirror the last closed bar (shift=1) to the current bar (shift=0) for EA access ---
    if(rates_total > 1)
    {
        SignalBuffer[0]     = SignalBuffer[1];
        ConfidenceBuffer[0] = ConfidenceBuffer[1];
        ReasonBuffer[0]     = ReasonBuffer[1];
    }

    // --- Optional Debug Logging for the last closed bar ---
    if(time[rates_total - 1] != g_last_log_time && rates_total > 1)
    {
        PrintFormat("[SMC_OUT] t=%s sig=%.0f conf=%.1f reason=%.0f",
                    TimeToString(time[1]),
                    SignalBuffer[1],
                    ConfidenceBuffer[1],
                    ReasonBuffer[1]);
        g_last_log_time = time[rates_total - 1];
    }

    return(rates_total);
}
//+------------------------------------------------------------------+
