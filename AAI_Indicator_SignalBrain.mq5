//+------------------------------------------------------------------+
//|                  AAI_Indicator_SignalBrain.mq5                   |
//|               v3.5 - Closed-Bar Guarantees & Headless Plots      |
//|                                                                  |
//| Acts as the confluence and trade signal engine.                  |
//|                                                                  |
//| Copyright 2025, AlfredAI Project                    |
//+------------------------------------------------------------------+
#property strict
#property indicator_chart_window
#property version "3.5"

// --- Indicator Buffers ---
#property indicator_buffers 4
#property indicator_plots   4 // Must match buffer count for EA/iCustom access.
// --- Buffer 0: Signal ---
#property indicator_type1   DRAW_NONE
#property indicator_label1  "Signal"
double SignalBuffer[];
// --- Buffer 1: Confidence ---
#property indicator_type2   DRAW_NONE
#property indicator_label2  "Confidence"
double ConfidenceBuffer[];
// --- Buffer 2: ReasonCode ---
#property indicator_type3   DRAW_NONE
#property indicator_label3  "ReasonCode"
double ReasonCodeBuffer[];
// --- Buffer 3: ZoneTimeframe ---
#property indicator_type4   DRAW_NONE
#property indicator_label4  "ZoneTimeframe"
double ZoneTFBuffer[];
//--- Indicator Inputs (as per spec) ---
input bool SB_SafeTest        = false;
input bool SB_UseZE           = false;
input bool SB_UseBC           = false;
input int  SB_WarmupBars      = 150;
input int  SB_FastMA          = 10;
input int  SB_SlowMA          = 30;
input int  SB_MinZoneStrength = 4;
input bool EnableDebugLogging = true;
// --- Enums for Clarity
enum ENUM_REASON_CODE
{
    REASON_NONE,                  // 0
    REASON_BUY_HTF_CONTINUATION,  // 1
    REASON_SELL_HTF_CONTINUATION, // 2
    REASON_BUY_LIQ_GRAB_ALIGNED,  // 3
    REASON_SELL_LIQ_GRAB_ALIGNED, // 4
    REASON_NO_ZONE,               // 5
    REASON_LOW_ZONE_STRENGTH,     // 6
    REASON_BIAS_CONFLICT,         // 7
    REASON_TEST_SCENARIO          // 8
};
// --- Indicator Handles ---
int ZE_handle = INVALID_HANDLE;
int BC_handle = INVALID_HANDLE;
int fastMA_handle = INVALID_HANDLE;
int slowMA_handle = INVALID_HANDLE;
// --- Globals for one-time logging ---
static datetime g_last_log_time = 0;
static datetime g_last_ze_fail_log_time = 0;
static datetime g_last_bc_fail_log_time = 0;

//+------------------------------------------------------------------+
//| Custom indicator initialization function                         |
//+------------------------------------------------------------------+
int OnInit()
{
    // --- Bind all 4 data buffers ---
    SetIndexBuffer(0, SignalBuffer,     INDICATOR_DATA);
    SetIndexBuffer(1, ConfidenceBuffer, INDICATOR_DATA);
    SetIndexBuffer(2, ReasonCodeBuffer, INDICATOR_DATA);
    SetIndexBuffer(3, ZoneTFBuffer,     INDICATOR_DATA);
    // --- Set buffers as series arrays ---
    ArraySetAsSeries(SignalBuffer,     true);
    ArraySetAsSeries(ConfidenceBuffer, true);
    ArraySetAsSeries(ReasonCodeBuffer, true);
    ArraySetAsSeries(ZoneTFBuffer,     true);

    // --- Set empty values for buffers ---
    PlotIndexSetDouble(0, PLOT_EMPTY_VALUE, 0.0);
    PlotIndexSetDouble(1, PLOT_EMPTY_VALUE, 0.0);
    PlotIndexSetDouble(2, PLOT_EMPTY_VALUE, 0.0);
    PlotIndexSetDouble(3, PLOT_EMPTY_VALUE, 0.0);
    IndicatorSetInteger(INDICATOR_DIGITS,0);
    // --- Create dependent indicator handles ---
    fastMA_handle = iMA(_Symbol, _Period, SB_FastMA, 0, MODE_SMA, PRICE_CLOSE);
    slowMA_handle = iMA(_Symbol, _Period, SB_SlowMA, 0, MODE_SMA, PRICE_CLOSE);
    if(fastMA_handle == INVALID_HANDLE || slowMA_handle == INVALID_HANDLE)
    {
        Print("[SB_ERR] Failed to create one or more MA handles. Indicator cannot function.");
        return(INIT_FAILED);
    }

    if(SB_UseZE)
    {
        ZE_handle = iCustom(_Symbol, _Period, "AAI_Indicator_ZoneEngine");
        if(ZE_handle == INVALID_HANDLE)
            Print("[SB_WARN] Failed to create ZoneEngine handle. It will be ignored.");
    }

    if(SB_UseBC)
    {
        BC_handle = iCustom(_Symbol, _Period, "AAI_Indicator_BiasCompass");
        if(BC_handle == INVALID_HANDLE)
            Print("[SB_WARN] Failed to create BiasCompass handle. It will be ignored.");
    }

    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Deinitialization                                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    if(ZE_handle != INVALID_HANDLE) IndicatorRelease(ZE_handle);
    if(BC_handle != INVALID_HANDLE) IndicatorRelease(BC_handle);
    if(fastMA_handle != INVALID_HANDLE) IndicatorRelease(fastMA_handle);
    if(slowMA_handle != INVALID_HANDLE) IndicatorRelease(slowMA_handle);
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
    if(rates_total < SB_WarmupBars)
    {
        // During warmup, write neutral values to all available bars to prevent stale data
        for(int i = 0; i < rates_total; i++)
        {
            SignalBuffer[i] = 0;
            ConfidenceBuffer[i] = 0;
            ReasonCodeBuffer[i] = REASON_NONE;
            ZoneTFBuffer[i] = 0;
        }
        return(0);
    }
    
    int start_bar = rates_total - 2;
    if(prev_calculated > 0)
    {
        start_bar = rates_total - prev_calculated;
    }
    start_bar = MathMax(1, start_bar); // Ensure we process at least the last closed bar

    // Handle SafeTest mode separately for simple MA cross test signals
    if(SB_SafeTest)
    {
        static double fastArr[], slowArr[];
        ArraySetAsSeries(fastArr, true);
        ArraySetAsSeries(slowArr, true);

        if(CopyBuffer(fastMA_handle, 0, 0, rates_total, fastArr) <= 0 ||
           CopyBuffer(slowMA_handle, 0, 0, rates_total, slowArr) <= 0)
        {
            return(prev_calculated); // Wait for data
        }

        for(int i = start_bar; i >= 1; i--)
        {
            double signal = 0.0;
            double fast_val = fastArr[i];
            double slow_val = slowArr[i];

            if(fast_val > slow_val && fast_val != 0 && slow_val != 0) signal = 1.0;
            else if(fast_val < slow_val && fast_val != 0 && slow_val != 0) signal = -1.0;
            SignalBuffer[i]     = signal;
            ConfidenceBuffer[i] = (signal != 0.0) ? 100.0 : 0.0;
            ReasonCodeBuffer[i] = (signal != 0.0) ? (double)REASON_TEST_SCENARIO : (double)REASON_NONE;
            ZoneTFBuffer[i]     = (double)PeriodSeconds(_Period);
        }
    }
    else // Live Logic: MA Cross + Optional Confluence
    {
        for(int i = start_bar; i >= 1; i--)
        {
            // --- Initialize outputs for this bar ---
            double signal = 0.0;
            double conf = 0.0;
            ENUM_REASON_CODE reasonCode = REASON_NONE;

            // --- 1. Base Signal: MA Cross ---
            double fast_arr[1], slow_arr[1];
            if (CopyBuffer(fastMA_handle, 0, i, 1, fast_arr) > 0 && CopyBuffer(slowMA_handle, 0, i, 1, slow_arr) > 0)
            {
                if(fast_arr[0] > slow_arr[0] && fast_arr[0] != 0 && slow_arr[0] != 0) signal = 1.0;
                else if(fast_arr[0] < slow_arr[0] && fast_arr[0] != 0 && slow_arr[0] != 0) signal = -1.0;
            }

            // --- 2. Base Confidence & Reason ---
            if (signal != 0.0)
            {
                conf = 50.0; // Base confidence for a clean cross is 50/100
                reasonCode = (signal > 0) ? REASON_BUY_HTF_CONTINUATION : REASON_SELL_HTF_CONTINUATION;
            }

            // --- 3. Confluence: ZoneEngine ---
            if(SB_UseZE)
            {
                if(ZE_handle != INVALID_HANDLE)
                {
                    double zeStrength_arr[1];
                    // Per contract, ZE strength is on buffer 0
                    if(CopyBuffer(ZE_handle, 0, i, 1, zeStrength_arr) > 0)
                    {
                        double zoneStrength = zeStrength_arr[0];
                        if (zoneStrength >= SB_MinZoneStrength)
                        {
                            conf += 25.0; // Add ZE bonus
                        }
                    }
                    else
                    {
                         if(time[i] != g_last_ze_fail_log_time)
                         {
                            PrintFormat("[DBG_ZE] read failed on bar %s, treating as neutral.", TimeToString(time[i]));
                            g_last_ze_fail_log_time = time[i];
                         }
                    }
                }
            }

            // --- 4. Confluence: BiasCompass ---
            if(SB_UseBC)
            {
                if(BC_handle != INVALID_HANDLE)
                {
                    double htfBias_arr[1];
                    // Per contract, HTF bias is on buffer 0
                    if(CopyBuffer(BC_handle, 0, i, 1, htfBias_arr) > 0)
                    {
                        double htfBias = htfBias_arr[0];
                        bool isBullBias = htfBias > 0.5;
                        bool isBearBias = htfBias < -0.5;
                        // Add confidence if bias aligns with the MA signal
                        if ((isBullBias && signal > 0) || (isBearBias && signal < 0))
                        {
                            conf += 25.0; // Add BC bonus
                        }
                    }
                    else
                    {
                         if(time[i] != g_last_bc_fail_log_time)
                         {
                            PrintFormat("[DBG_BC] read failed on bar %s, treating as neutral.", TimeToString(time[i]));
                            g_last_bc_fail_log_time = time[i];
                         }
                    }
                }
            }

            // --- 5. Finalize and Write Buffers for the closed bar ---
            SignalBuffer[i]     = signal;
            ConfidenceBuffer[i] = fmin(100.0, conf); // Clamp confidence to [0, 100]
            ReasonCodeBuffer[i] = (double)reasonCode;
            ZoneTFBuffer[i]     = (double)PeriodSeconds(_Period);
        }
    }

    // --- Mirror the last closed bar (shift=1) to the current bar (shift=0) for EA access ---
    if (rates_total > 1)
    {
        SignalBuffer[0]     = SignalBuffer[1];
        ConfidenceBuffer[0] = ConfidenceBuffer[1];
        ReasonCodeBuffer[0] = ReasonCodeBuffer[1];
        ZoneTFBuffer[0]     = ZoneTFBuffer[1];
    }
    
    // --- Optional Debug Logging for the last closed bar ---
    if(EnableDebugLogging && time[rates_total-1] != g_last_log_time)
    {
        PrintFormat("[DBG_SB] shift=1 sig=%d conf=%.0f reason=%d ztf=%d",
                    (int)SignalBuffer[1],
                    ConfidenceBuffer[1],
                    (int)ReasonCodeBuffer[1],
                    (int)ZoneTFBuffer[1]);
        g_last_log_time = time[rates_total-1];
    }

    return(rates_total);
}
//+------------------------------------------------------------------+
