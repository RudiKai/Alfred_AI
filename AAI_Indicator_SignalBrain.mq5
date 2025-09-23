//+------------------------------------------------------------------+
//|                  AAI_Indicator_SignalBrain.mq5                   |
//|                    v4.3 - Geometric Confluence                   |
//|                                                                  |
//| Acts as the confluence and trade signal engine.                  |
//| Now aggregates all foundational indicators internally.           |
//| Copyright 2025, AlfredAI Project                                 |
//+------------------------------------------------------------------+
#property strict
#property indicator_chart_window
#property version "4.3"

#define SB_BUILD_TAG  "SB 4.3.0"

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
input bool SB_UseZE           = true;
input bool SB_UseBC           = true;
input bool SB_UseSMC          = true;
input int  SB_WarmupBars      = 150;
input int  SB_FastMA          = 10;
input int  SB_SlowMA          = 30;
input int  SB_MinZoneStrength = 4;
input bool EnableDebugLogging = true;

//--- Confluence Bonuses (for Additive model) ---
input group "--- Additive Model Bonuses ---"
input int  SB_Bonus_ZE        = 25;
input int  SB_Bonus_BC        = 15;
input int  SB_Bonus_SMC       = 25;
input int  SB_BaseConf        = 40;

//--- Pass-through to BiasCompass ---
input group "--- BiasCompass Pass-Through ---"
input int  SB_BC_FastMA       = 10;
input int  SB_BC_SlowMA       = 30;

//--- Pass-through to ZoneEngine ---
input group "--- ZoneEngine Pass-Through ---"
input double SB_ZE_MinImpulseMovePips = 10.0;

//--- Pass-through to SMC ---
input group "--- SMC Pass-Through ---"
input bool   SB_SMC_UseFVG      = true;
input bool   SB_SMC_UseOB       = true;
input bool   SB_SMC_UseBOS      = true;
input double SB_SMC_FVG_MinPips = 1.0;
input int    SB_SMC_OB_Lookback = 20;
input int    SB_SMC_BOS_Lookback= 50;


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

// --- Indicator Path Helper ---
#define AAI_IND_PREFIX "AlfredAI\\"
inline string AAI_Ind(const string name)
{
   if(StringFind(name, AAI_IND_PREFIX) == 0) return name;
   return AAI_IND_PREFIX + name;
}

// --- TICKET T023: Helper for Global Variables ---
double GlobalOrDefault(const string name, double def_value)
{
    if(GlobalVariableCheck(name))
    {
        return GlobalVariableGet(name);
    }
    return def_value;
}


// --- Indicator Handles ---
int ZE_handle     = INVALID_HANDLE;
int BC_handle     = INVALID_HANDLE;
int SMC_handle    = INVALID_HANDLE;
int fastMA_handle = INVALID_HANDLE;
int slowMA_handle = INVALID_HANDLE;

// --- Globals for one-time logging ---
static datetime g_last_log_time = 0;
static datetime g_last_ze_fail_log_time = 0;
static datetime g_last_bc_fail_log_time = 0;
static datetime g_last_smc_fail_log_time = 0;

//+------------------------------------------------------------------+
//| Custom indicator initialization function                         |
//+------------------------------------------------------------------+
int OnInit()
{
    PrintFormat("[SB_INIT] %s file=%s now=%s",
               SB_BUILD_TAG,
               MQL5InfoString(MQL5_PROGRAM_NAME),
               TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS));

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
    fastMA_handle = iMA(_Symbol, _Period, SB_FastMA, 0, MODE_SMA, PRICE_CLOSE);
    slowMA_handle = iMA(_Symbol, _Period, SB_SlowMA, 0, MODE_SMA, PRICE_CLOSE);
    if(fastMA_handle == INVALID_HANDLE || slowMA_handle == INVALID_HANDLE)
    {
        Print("[SB_ERR] Failed to create one or more MA handles.");
        return(INIT_FAILED);
    }

    if(SB_UseZE)
    {
        ZE_handle = iCustom(_Symbol, _Period, AAI_Ind("AAI_Indicator_ZoneEngine"), SB_ZE_MinImpulseMovePips, true);
        if(ZE_handle == INVALID_HANDLE) Print("[SB_WARN] Failed to create ZoneEngine handle.");
    }
    if(SB_UseBC)
    {
        BC_handle = iCustom(_Symbol, _Period, AAI_Ind("AAI_Indicator_BiasCompass"), SB_BC_FastMA, SB_BC_SlowMA);
        if(BC_handle == INVALID_HANDLE) Print("[SB_WARN] Failed to create BiasCompass handle.");
    }
    if(SB_UseSMC)
    {
        SMC_handle = iCustom(_Symbol, _Period, AAI_Ind("AAI_Indicator_SMC"), SB_SMC_UseFVG, SB_SMC_UseOB, SB_SMC_UseBOS, SB_SMC_FVG_MinPips, SB_SMC_OB_Lookback, SB_SMC_BOS_Lookback);
        if(SMC_handle == INVALID_HANDLE) Print("[SB_WARN] Failed to create SMC handle.");
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
            FinalSignalBuffer[i] = 0; FinalConfidenceBuffer[i] = 0; ReasonCodeBuffer[i] = REASON_NONE;
            RawZEStrengthBuffer[i] = 0; RawSMCSignalBuffer[i] = 0; RawSMCConfidenceBuffer[i] = 0; RawBCBiasBuffer[i] = 0;
        }
        return(0);
    }
    
    int start_bar = rates_total - 2;
    if(prev_calculated > 0)
    {
        start_bar = rates_total - prev_calculated;
    }
    start_bar = MathMax(1, start_bar);

    // --- TICKET T023: Read Global Variables for model selection ---
    int model = (int)GlobalOrDefault("AAI/SB/ConfModel", 0);

    for(int i = start_bar; i >= 1; i--)
    {
        double finalSignal = 0.0;
        double finalConfidence = 0.0;
        ENUM_REASON_CODE reasonCode = REASON_NONE;
        double rawZEStrength=0, rawSMCConfidence=0, rawBCBias=0;
        double rawSMCSignal=0;

        // --- 1. Base Signal: MA Cross ---
        double fast_arr[1], slow_arr[1];
        if (CopyBuffer(fastMA_handle, 0, i, 1, fast_arr) > 0 && CopyBuffer(slowMA_handle, 0, i, 1, slow_arr) > 0)
        {
            if(fast_arr[0] != 0.0 && slow_arr[0] != 0.0)
            {
               if(fast_arr[0] > slow_arr[0]) { finalSignal = 1.0; reasonCode = REASON_BUY_HTF_CONTINUATION; }
               else if(fast_arr[0] < slow_arr[0]) { finalSignal = -1.0; reasonCode = REASON_SELL_HTF_CONTINUATION; }
            }
        }

        // --- 2. Read Raw Data from Foundational Indicators ---
        if(SB_UseZE && ZE_handle != INVALID_HANDLE) { double v[1]; if(CopyBuffer(ZE_handle, 0, i, 1, v)>0) rawZEStrength=v[0]; }
        if(SB_UseBC && BC_handle != INVALID_HANDLE) { double v[1]; if(CopyBuffer(BC_handle, 0, i, 1, v)>0) rawBCBias=v[0]; }
        if(SB_UseSMC && SMC_handle != INVALID_HANDLE) { double v[1]; if(CopyBuffer(SMC_handle, 0, i, 1, v)>0) rawSMCSignal=v[0]; if(CopyBuffer(SMC_handle, 1, i, 1, v)>0) rawSMCConfidence=v[0]; }

        // --- 3. Calculate Final Confidence based on selected model ---
        if (finalSignal != 0.0)
        {
            if(model == 1) // Geometric Model
            {
                double wb   = GlobalOrDefault("AAI/SB/W_BASE", 1.0);
                double wbc  = GlobalOrDefault("AAI/SB/W_BC", 1.0);
                double wze  = GlobalOrDefault("AAI/SB/W_ZE", 1.0);
                double wsmc = GlobalOrDefault("AAI/SB/W_SMC", 1.0);
                double cpen = fmax(0.2, fmin(1.0, GlobalOrDefault("AAI/SB/ConflictPenalty", 0.80)));
                
                // Normalize components to [0,1]
                double p_base = fmax(0.0, fmin(1.0, SB_BaseConf / 100.0));
                double p_bc   = (rawBCBias * finalSignal > 0.5) ? 1.0 : 0.0;
                double p_ze   = fmax(0.0, fmin(1.0, rawZEStrength / 10.0));
                double p_smc  = (rawSMCSignal * finalSignal > 0) ? fmax(0.0, fmin(1.0, rawSMCConfidence / 10.0)) : 0.0;
                
                // Weighted Geometric Mean
                double eps = 1e-9;
                double wsum = wb + wbc + wze + wsmc;
                double logsum = wb * log(p_base + eps) + wbc * log(p_bc + eps) + wze * log(p_ze + eps) + wsmc * log(p_smc + eps);
                double p_geom = exp(logsum / fmax(eps, wsum));
                
                // Conflict Penalty
                if (rawBCBias * finalSignal < -0.5) p_geom *= cpen;
                if (rawSMCSignal * finalSignal < 0 && rawSMCConfidence >= 7) p_geom *= cpen;
                
                finalConfidence = fmax(0.0, fmin(100.0, p_geom * 100.0));
            }
            else // Default to Additive Model
            {
                finalConfidence = SB_BaseConf;
                if(SB_UseZE && rawZEStrength >= SB_MinZoneStrength) finalConfidence += SB_Bonus_ZE;
                if(SB_UseBC && (rawBCBias * finalSignal > 0.5)) finalConfidence += SB_Bonus_BC;
                if(SB_UseSMC && (rawSMCSignal * finalSignal > 0)) finalConfidence += SB_Bonus_SMC;
            }
        }

        // --- 4. Write ALL buffers ---
        FinalSignalBuffer[i]      = finalSignal;
        FinalConfidenceBuffer[i]  = fmax(0.0, fmin(100.0, finalConfidence));
        ReasonCodeBuffer[i]       = (finalSignal != 0.0) ? (double)reasonCode : (double)REASON_NONE;
        RawZEStrengthBuffer[i]    = rawZEStrength;
        RawSMCSignalBuffer[i]     = rawSMCSignal;
        RawSMCConfidenceBuffer[i] = rawSMCConfidence;
        RawBCBiasBuffer[i]        = rawBCBias;
    }

    // --- Mirror last closed bar to current bar ---
    if (rates_total > 1)
    {
        FinalSignalBuffer[0] = FinalSignalBuffer[1]; FinalConfidenceBuffer[0] = FinalConfidenceBuffer[1]; ReasonCodeBuffer[0] = ReasonCodeBuffer[1];
        RawZEStrengthBuffer[0] = RawZEStrengthBuffer[1]; RawSMCSignalBuffer[0] = RawSMCSignalBuffer[1]; RawSMCConfidenceBuffer[0] = RawSMCConfidenceBuffer[1]; RawBCBiasBuffer[0] = RawBCBiasBuffer[1];
    }
    
    // --- Optional Debug Logging ---
    if(EnableDebugLogging && time[rates_total-1] != g_last_log_time && rates_total > 1)
    {
        PrintFormat("[DBG_SB_FINAL] t=%s sig=%.0f conf=%.0f ze=%.1f smc_s=%.0f smc_c=%.1f bc=%.1f",
                    TimeToString(time[1]), FinalSignalBuffer[1], FinalConfidenceBuffer[1], RawZEStrengthBuffer[1],
                    RawSMCSignalBuffer[1], RawSMCConfidenceBuffer[1], RawBCBiasBuffer[1]);
        g_last_log_time = time[rates_total-1];
    }

    return(rates_total);
}
//+------------------------------------------------------------------+
