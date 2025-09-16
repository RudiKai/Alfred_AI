//+------------------------------------------------------------------+
//|                  AAI_Indicator_SignalBrain.mq5                   |
//|               v4.0 - Central Aggregator Refactor                 |
//|                                                                  |
//| Acts as the confluence and trade signal engine.                  |
//| Now aggregates all foundational indicators internally.           |
//| Copyright 2025, AlfredAI Project                                 |
//+------------------------------------------------------------------+
#property strict
#property indicator_chart_window
#property version "4.0"

#property version   "4.2"
#define SB_BUILD_TAG  "SB 4.2.0"

// --- Indicator Buffers (Expanded to 7) ---
#property indicator_buffers 7
#property indicator_plots   7 // Must match buffer count for EA/iCustom access.

// --- Buffer 0: Final Signal ---
#property indicator_type1   DRAW_NONE
#property indicator_label1  "FinalSignal"
double FinalSignalBuffer[];

// --- Buffer 1: Final Confidence ---
#property indicator_type2   DRAW_NONE
#property indicator_label2  "FinalConfidence"
double FinalConfidenceBuffer[];

// --- Buffer 2: ReasonCode ---
#property indicator_type3   DRAW_NONE
#property indicator_label3  "ReasonCode"
double ReasonCodeBuffer[];

// --- Buffer 3: Raw ZE Strength ---
#property indicator_type4   DRAW_NONE
#property indicator_label4  "RawZEStrength"
double RawZEStrengthBuffer[];

// --- Buffer 4: Raw SMC Signal ---
#property indicator_type5   DRAW_NONE
#property indicator_label5  "RawSMCSignal"
double RawSMCSignalBuffer[];

// --- Buffer 5: Raw SMC Confidence ---
#property indicator_type6   DRAW_NONE
#property indicator_label6  "RawSMCConfidence"
double RawSMCConfidenceBuffer[];

// --- Buffer 6: Raw BC Bias ---
#property indicator_type7   DRAW_NONE
#property indicator_label7  "RawBCBias"
double RawBCBiasBuffer[];


//--- Indicator Inputs ---
input group "--- Core Settings ---"
input bool SB_SafeTest        = false;
input bool SB_UseZE           = true;  // Now controls internal ZE confluence
input bool SB_UseBC           = true;  // Now controls internal BC confluence
input bool SB_UseSMC          = true;  // TICKET #1: Added control for SMC
input int  SB_WarmupBars      = 150;
input int  SB_FastMA          = 10;
input int  SB_SlowMA          = 30;
input int  SB_MinZoneStrength = 4;
input bool EnableDebugLogging = true;

//--- TICKET #1: Confidence Model Knobs ---
input group "--- Confluence Bonuses ---"
input int  SB_Bonus_ZE        = 25; // Bonus for ZE alignment
input int  SB_Bonus_BC        = 25; // Bonus for BC alignment
input int  SB_Bonus_SMC       = 25; // Bonus for SMC alignment

//--- TICKET #1: Pass-through to BiasCompass ---
input group "--- BiasCompass Pass-Through ---"
input int  SB_BC_FastMA       = 10;
input int  SB_BC_SlowMA       = 30;

//--- TICKET #1: Pass-through to ZoneEngine ---
input group "--- ZoneEngine Pass-Through ---"
input double SB_ZE_MinImpulseMovePips = 10.0;

//--- TICKET #1: Pass-through to SMC ---
input group "--- SMC Pass-Through ---"
input bool   SB_SMC_UseFVG      = true;
input bool   SB_SMC_UseOB       = true;
input bool   SB_SMC_UseBOS      = true;
input double SB_SMC_FVG_MinPips = 1.0;
input int    SB_SMC_OB_Lookback = 20;
input int    SB_SMC_BOS_Lookback= 50;

input group "--- Confidence Model ---"
input int SB_BaseConf = 40;   // base confidence when a direction exists

input group "--- Diagnostics ---"
input bool SB_EnableDebug = true;   // toggle extra SignalBrain logging


// --- Enums for Clarity ---
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

// --- TICKET #1: Indicator Path Helper ---
#define AAI_IND_PREFIX "AlfredAI\\"
inline string AAI_Ind(const string name)
{
   if(StringFind(name, AAI_IND_PREFIX) == 0) return name;
   return AAI_IND_PREFIX + name;
}

// --- Indicator Handles ---
int ZE_handle     = INVALID_HANDLE;
int BC_handle     = INVALID_HANDLE;
int SMC_handle    = INVALID_HANDLE; // TICKET #1: Added SMC handle
int fastMA_handle = INVALID_HANDLE;
int slowMA_handle = INVALID_HANDLE;

// --- Globals for one-time logging ---
static datetime g_last_log_time = 0;
static datetime g_last_ze_fail_log_time = 0;
static datetime g_last_bc_fail_log_time = 0;
static datetime g_last_smc_fail_log_time = 0; // TICKET #1: Added for SMC

//+------------------------------------------------------------------+
//| Custom indicator initialization function                         |
//+------------------------------------------------------------------+
int OnInit()
{
{
   PrintFormat("[SB_INIT] %s file=%s now=%s",
               SB_BUILD_TAG,
               __FILE__,
               TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS));
}
    // --- Bind all 7 data buffers ---
    SetIndexBuffer(0, FinalSignalBuffer,      INDICATOR_DATA);
    SetIndexBuffer(1, FinalConfidenceBuffer,  INDICATOR_DATA);
    SetIndexBuffer(2, ReasonCodeBuffer,       INDICATOR_DATA);
    SetIndexBuffer(3, RawZEStrengthBuffer,    INDICATOR_DATA);
    SetIndexBuffer(4, RawSMCSignalBuffer,     INDICATOR_DATA);
    SetIndexBuffer(5, RawSMCConfidenceBuffer, INDICATOR_DATA);
    SetIndexBuffer(6, RawBCBiasBuffer,        INDICATOR_DATA);

    // --- Set buffers as series arrays ---
    ArraySetAsSeries(FinalSignalBuffer,      true);
    ArraySetAsSeries(FinalConfidenceBuffer,  true);
    ArraySetAsSeries(ReasonCodeBuffer,       true);
    ArraySetAsSeries(RawZEStrengthBuffer,    true);
    ArraySetAsSeries(RawSMCSignalBuffer,     true);
    ArraySetAsSeries(RawSMCConfidenceBuffer, true);
    ArraySetAsSeries(RawBCBiasBuffer,        true);

    // --- Set empty values for buffers ---
    for(int i = 0; i < 7; i++)
    {
        PlotIndexSetDouble(i, PLOT_EMPTY_VALUE, 0.0);
    }
    IndicatorSetInteger(INDICATOR_DIGITS,0);

    // --- Create dependent indicator handles ---
    // Base MA Cross Signal
    fastMA_handle = iMA(_Symbol, _Period, SB_FastMA, 0, MODE_SMA, PRICE_CLOSE);
    slowMA_handle = iMA(_Symbol, _Period, SB_SlowMA, 0, MODE_SMA, PRICE_CLOSE);
    if(fastMA_handle == INVALID_HANDLE || slowMA_handle == INVALID_HANDLE)
    {
        Print("[SB_ERR] Failed to create one or more MA handles. Indicator cannot function.");
        return(INIT_FAILED);
    }

    // TICKET #1: Create internal handles to foundational indicators
    if(SB_UseZE)
    {
        ZE_handle = iCustom(_Symbol, _Period, AAI_Ind("AAI_Indicator_ZoneEngine"), SB_ZE_MinImpulseMovePips, true);
        if(ZE_handle == INVALID_HANDLE)
            Print("[SB_WARN] Failed to create ZoneEngine handle. It will be ignored.");
    }

    if(SB_UseBC)
    {
        BC_handle = iCustom(_Symbol, _Period, AAI_Ind("AAI_Indicator_BiasCompass"), SB_BC_FastMA, SB_BC_SlowMA);
        if(BC_handle == INVALID_HANDLE)
            Print("[SB_WARN] Failed to create BiasCompass handle. It will be ignored.");
    }

    if(SB_UseSMC)
    {
        SMC_handle = iCustom(_Symbol, _Period, AAI_Ind("AAI_Indicator_SMC"), SB_SMC_UseFVG, SB_SMC_UseOB, SB_SMC_UseBOS, 100, SB_SMC_FVG_MinPips, SB_SMC_OB_Lookback, SB_SMC_BOS_Lookback);
        if(SMC_handle == INVALID_HANDLE)
            Print("[SB_WARN] Failed to create SMC handle. It will be ignored.");
    }


    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Deinitialization                                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    // TICKET #1: Release all handles
    if(ZE_handle != INVALID_HANDLE) IndicatorRelease(ZE_handle);
    if(BC_handle != INVALID_HANDLE) IndicatorRelease(BC_handle);
    if(SMC_handle != INVALID_HANDLE) IndicatorRelease(SMC_handle);
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
        for(int i = 0; i < rates_total; i++)
        {
            FinalSignalBuffer[i] = 0;
            FinalConfidenceBuffer[i] = 0;
            ReasonCodeBuffer[i] = REASON_NONE;
            RawZEStrengthBuffer[i] = 0;
            RawSMCSignalBuffer[i] = 0;
            RawSMCConfidenceBuffer[i] = 0;
            RawBCBiasBuffer[i] = 0;
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
            
            FinalSignalBuffer[i]     = signal;
            FinalConfidenceBuffer[i] = (signal != 0.0) ? 100.0 : 0.0;
            ReasonCodeBuffer[i]      = (signal != 0.0) ? (double)REASON_TEST_SCENARIO : (double)REASON_NONE;
            // Fill raw buffers with neutrals in test mode
            RawZEStrengthBuffer[i] = 0;
            RawSMCSignalBuffer[i] = 0;
            RawSMCConfidenceBuffer[i] = 0;
            RawBCBiasBuffer[i] = 0;
        }
    }
else // Live Logic: MA Cross + Full Confluence Calculation
{
    for(int i = start_bar; i >= 1; --i)
    {
        // --- Initialize outputs for this bar ---
        double finalSignal       = 0.0;
        double finalConfidence   = 0.0;
        ENUM_REASON_CODE reasonCode = REASON_NONE;

        double rawZEStrength     = 0.0;
        double rawSMCSignal      = 0.0;
        double rawSMCConfidence  = 0.0;
        double rawBCBias         = 0.0;

        // --- 1) Base Signal: MA Cross (closed bar) ---
        double fast_arr[1], slow_arr[1];
        if (CopyBuffer(fastMA_handle, 0, i, 1, fast_arr) > 0 &&
            CopyBuffer(slowMA_handle, 0, i, 1, slow_arr) > 0)
        {
            if(fast_arr[0] != 0.0 && slow_arr[0] != 0.0)
            {
                if(fast_arr[0] > slow_arr[0]) { finalSignal = +1.0; reasonCode = REASON_BUY_HTF_CONTINUATION; }
                else if(fast_arr[0] < slow_arr[0]) { finalSignal = -1.0; reasonCode = REASON_SELL_HTF_CONTINUATION; }
            }
        }

        // --- 2) Read Raw Data from Foundational Indicators (closed bar) ---

        // ZoneEngine (strength)
        if(SB_UseZE && ZE_handle != INVALID_HANDLE)
        {
            double ze_arr[1];
            if(CopyBuffer(ZE_handle, 0, i, 1, ze_arr) > 0)
                rawZEStrength = ze_arr[0];
            else if(time[i] != g_last_ze_fail_log_time)
            {
                PrintFormat("[DBG_SB_ZE] read failed on bar %s", TimeToString(time[i]));
                g_last_ze_fail_log_time = time[i];
            }
        }

        // BiasCompass (bias as -1..+1 style value)
        if(SB_UseBC && BC_handle != INVALID_HANDLE)
        {
            double bc_arr[1];
            if(CopyBuffer(BC_handle, 0, i, 1, bc_arr) > 0)
                rawBCBias = bc_arr[0];
            else if(time[i] != g_last_bc_fail_log_time)
            {
                PrintFormat("[DBG_SB_BC] read failed on bar %s", TimeToString(time[i]));
                g_last_bc_fail_log_time = time[i];
            }
        }

        // SMC (signal & confidence 0..10)
        if(SB_UseSMC && SMC_handle != INVALID_HANDLE)
        {
            double smc_sig_arr[1], smc_conf_arr[1];
            if(CopyBuffer(SMC_handle, 0, i, 1, smc_sig_arr) > 0)
                rawSMCSignal = smc_sig_arr[0];
            if(CopyBuffer(SMC_handle, 1, i, 1, smc_conf_arr) > 0)
                rawSMCConfidence = smc_conf_arr[0];
        }

        // --- 3) Final Confidence: base + explicit bonuses (clamped 0..100) ---
        double base_conf = 0.0, bc_bonus = 0.0, ze_bonus = 0.0, smc_bonus = 0.0;

        if(finalSignal != 0.0)
        {
            // base
            base_conf = (double)SB_BaseConf;

            // BC bonus (boolean alignment)
            bool isBullishBias = (rawBCBias >  0.5);
            bool isBearishBias = (rawBCBias < -0.5);
            if(SB_UseBC && ((finalSignal > 0 && isBullishBias) || (finalSignal < 0 && isBearishBias)))
                bc_bonus = (double)SB_Bonus_BC;

            // ZE bonus (scaled by strength above threshold up to 10)
            if(SB_UseZE && rawZEStrength >= SB_MinZoneStrength)
            {
                double denom   = MathMax(1.0, 10.0 - (double)SB_MinZoneStrength);
                double zescale = MathMin(1.0, MathMax(0.0, (rawZEStrength - SB_MinZoneStrength) / denom));
                ze_bonus = (double)SB_Bonus_ZE * zescale;
            }

            // SMC bonus (alignment × confidence 0..10)
            if(SB_UseSMC && rawSMCSignal != 0.0 && (finalSignal * rawSMCSignal) > 0.0)
            {
                double smcScale = MathMin(1.0, MathMax(0.0, rawSMCConfidence / 10.0));
                smc_bonus = (double)SB_Bonus_SMC * smcScale;
            }

            finalConfidence = base_conf + bc_bonus + ze_bonus + smc_bonus;

            // ---- SANITY: if no bonuses applied but conf somehow != base, force it & report ----
            if(MathAbs(bc_bonus) < 1e-9 && MathAbs(ze_bonus) < 1e-9 && MathAbs(smc_bonus) < 1e-9)
            {
                if(MathAbs(finalConfidence - base_conf) > 1e-9)
                {
                    PrintFormat("[SB_SANITY] bonuses=0 but conf=%.1f, forcing to base=%.1f at %s",
                                finalConfidence, base_conf, TimeToString(time[i]));
                    finalConfidence = base_conf;
                }
            }
        }
        else
        {
            finalConfidence = 0.0;
            reasonCode = REASON_NONE;
        }

        // --- DEBUG: one-line breakdown (only if SB_EnableDebug) ---
        if(SB_EnableDebug)
        {
            PrintFormat("[SB_CONF] t=%s sig=%+.0f base=%.1f bc+=%.1f ze+=%.1f smc+=%.1f -> conf=%.1f | raw: ze=%.1f bc=%.1f smc_s=%.1f smc_c=%.1f",
                        TimeToString(time[i]),
                        finalSignal, base_conf, bc_bonus, ze_bonus, smc_bonus, finalConfidence,
                        rawZEStrength, rawBCBias, rawSMCSignal, rawSMCConfidence);
        }

        // --- 4) Finalize and write ALL buffers for the closed bar ---
        FinalSignalBuffer[i]      = finalSignal;
        FinalConfidenceBuffer[i]  = MathMin(100.0, MathMax(0.0, finalConfidence));
        ReasonCodeBuffer[i]       = (double)reasonCode;
        RawZEStrengthBuffer[i]    = rawZEStrength;
        RawSMCSignalBuffer[i]     = rawSMCSignal;
        RawSMCConfidenceBuffer[i] = rawSMCConfidence;
        RawBCBiasBuffer[i]        = rawBCBias;
    }
}


    // --- Mirror the last closed bar (shift=1) to the current bar (shift=0) for EA access ---
    if (rates_total > 1)
    {
        FinalSignalBuffer[0]      = FinalSignalBuffer[1];
        FinalConfidenceBuffer[0]  = FinalConfidenceBuffer[1];
        ReasonCodeBuffer[0]       = ReasonCodeBuffer[1];
        RawZEStrengthBuffer[0]    = RawZEStrengthBuffer[1];
        RawSMCSignalBuffer[0]     = RawSMCSignalBuffer[1];
        RawSMCConfidenceBuffer[0] = RawSMCConfidenceBuffer[1];
        RawBCBiasBuffer[0]        = RawBCBiasBuffer[1];
    }
    
    // --- Optional Debug Logging for the last closed bar ---
    if(EnableDebugLogging && time[rates_total-1] != g_last_log_time && rates_total > 1)
    {
        PrintFormat("[DBG_SB_FINAL] t=%s sig=%.0f conf=%.0f ze=%.1f smc_s=%.0f smc_c=%.1f bc=%.1f",
                    TimeToString(time[1]),
                    FinalSignalBuffer[1],
                    FinalConfidenceBuffer[1],
                    RawZEStrengthBuffer[1],
                    RawSMCSignalBuffer[1],
                    RawSMCConfidenceBuffer[1],
                    RawBCBiasBuffer[1]);
        g_last_log_time = time[rates_total-1];
    }

    return(rates_total);
}
//+------------------------------------------------------------------+
