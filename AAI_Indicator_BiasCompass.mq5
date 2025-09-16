//+------------------------------------------------------------------+
//|                  AAI_Indicator_BiasCompass.mq5                   |
//|                    v3.1 - iCustom Handle Fix                     |
//|        (Determines multi-timeframe directional bias)             |
//|                                                                  |
//| Copyright 2025, AlfredAI Project                                 |
//+------------------------------------------------------------------+
#property indicator_chart_window
#property strict
#property version "3.1" // Version incremented for the fix

// --- Headless, single-buffer output ---
#property indicator_plots   1
#property indicator_buffers 1
#property indicator_type1   DRAW_NONE
#property indicator_label1  "Bias"
double BiasBuffer[];

//--- Indicator Inputs ---
input int    BC_FastMA     = 10;
input int    BC_SlowMA     = 30;
input ENUM_MA_METHOD BC_MAMethod   = MODE_SMA;
input ENUM_APPLIED_PRICE BC_Price  = PRICE_CLOSE;
input int    BC_WarmupBars = 150;
input bool   EnableDebugLogging = true;

// --- Indicator Handles ---
int g_fastMA_handle = INVALID_HANDLE;
int g_slowMA_handle = INVALID_HANDLE;

// --- Globals ---
static datetime g_last_log_time = 0;
static datetime g_last_warmup_ind_log_time = 0;


//+------------------------------------------------------------------+
//| Initialization                                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    // --- Bind the output buffer ---
    SetIndexBuffer(0, BiasBuffer, INDICATOR_DATA);
    ArraySetAsSeries(BiasBuffer, true);
    PlotIndexSetDouble(0, PLOT_EMPTY_VALUE, 0.0);

    // --- TICKET FIX: Create MA handles using explicit iCustom to prevent [4002] error ---
    // The iCustom function for the built-in Moving Average takes these parameters:
    // ma_period, ma_shift, ma_method, applied_price
    g_fastMA_handle = iCustom(_Symbol, _Period, "Examples\\Custom Moving Average", BC_FastMA, 0, BC_MAMethod, BC_Price);
    g_slowMA_handle = iCustom(_Symbol, _Period, "Examples\\Custom Moving Average", BC_SlowMA, 0, BC_MAMethod, BC_Price);
    
    // --- Validate handles ---
    if(g_fastMA_handle < 0 || g_slowMA_handle < 0)
    {
        Print("[INIT_ERROR] BiasCompass iCustom handle failed");
        return(INIT_FAILED);
    }

    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Deinitialization                                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    // --- Release indicator handles ---
    if(g_fastMA_handle != INVALID_HANDLE) IndicatorRelease(g_fastMA_handle);
    if(g_slowMA_handle != INVALID_HANDLE) IndicatorRelease(g_slowMA_handle);
}

//+------------------------------------------------------------------+
//| Main calculation loop (closed-bar semantics)                     |
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
    // --- Warmup Guard (T003) ---
    if(rates_total < BC_WarmupBars)
    {
        datetime barTime = time[rates_total-1];
        if(g_last_warmup_ind_log_time != barTime)
        {
            PrintFormat("[WARMUP_IND] name=BiasCompass t=%s needed=%d have=%d", TimeToString(barTime), BC_WarmupBars, rates_total);
            g_last_warmup_ind_log_time = barTime;
        }
        for(int i = 0; i < rates_total; i++) BiasBuffer[i] = 0.0;
        return(rates_total);
    }

    // --- Determine start bar for calculation ---
    int start_bar = (prev_calculated == 0 ? rates_total - 1 : rates_total - prev_calculated);
    start_bar = MathMax(1, start_bar);

    // --- Loop backwards to calculate bias for new bars ---
    for(int i = start_bar; i >= 1; i--)
    {
        // --- Data Availability Guard ---
        if(BarsCalculated(g_fastMA_handle) <= i || BarsCalculated(g_slowMA_handle) <= i)
        {
            continue; // Not enough data for this bar yet
        }

        double f[1], s[1];
        if(CopyBuffer(g_fastMA_handle, 0, i, 1, f) != 1 || CopyBuffer(g_slowMA_handle, 0, i, 1, s) != 1)
        {
           if(EnableDebugLogging && time[i] != g_last_log_time)
              PrintFormat("[EVT_WARN] BiasCompass CopyBuffer failed on bar %s", TimeToString(time[i]));
           BiasBuffer[i] = 0; // Publish neutral on failure
           continue;
        }

        // --- Compute and write bias ---
        double bias = (f[0] > s[0]) ? 1.0 : (f[0] < s[0] ? -1.0 : 0.0);
        BiasBuffer[i] = bias;
        
        // --- Log the state of the last fully closed bar (shift=1) ---
        if(i == 1 && EnableDebugLogging && time[rates_total - 1] != g_last_log_time)
        {
            PrintFormat("[DBG_BC] shift=1 fast=%.5f slow=%.5f bias=%d", f[0], s[0], (int)bias);
            g_last_log_time = time[rates_total - 1];
        }
    }

    // --- Mirror closed bar value to current (forming) bar for EA access ---
    if(rates_total > 1)
    {
        BiasBuffer[0] = BiasBuffer[1];
    }
    
    return(rates_total);
}
//+------------------------------------------------------------------+
