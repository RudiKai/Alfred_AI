//+------------------------------------------------------------------+
//|                    AAI_Script_DebugHelper.mq5                    |
//|                 v3.0 - SignalBrain v4 Refactor                   |
//|       Runs ONCE to print live data from the new SignalBrain.     |
//|                                                                  |
//| Copyright 2025, AlfredAI Project                                 |
//+------------------------------------------------------------------+
#property strict
#property script_show_inputs // Defines this file as a script
#property version "3.0"

// --- TICKET #4: Define SignalBrain buffer indices ---
#define SB_BUF_SIGNAL   0
#define SB_BUF_CONF     1
#define SB_BUF_REASON   2
#define SB_BUF_ZE       3
#define SB_BUF_SMC_SIG  4
#define SB_BUF_SMC_CONF 5
#define SB_BUF_BC       6

// --- TICKET #4: Matching EA Pass-Through Inputs ---
input group "--- SignalBrain Pass-Through Inputs ---";
input bool   SB_SafeTest        = false;
input bool   SB_UseZE           = true;
input bool   SB_UseBC           = true;
input bool   SB_UseSMC          = true;
input int    SB_WarmupBars      = 150;
input int    SB_FastMA          = 10;
input int    SB_SlowMA          = 30;
input int    SB_MinZoneStrength = 4;
input bool   SB_EnableDebug     = true;
input int    SB_Bonus_ZE        = 25;
input int    SB_Bonus_BC        = 25;
input int    SB_Bonus_SMC       = 25;
input int    SB_BC_FastMA       = 10;
input int    SB_BC_SlowMA       = 30;
input double SB_ZE_MinImpulseMovePips = 10.0;
input bool   SB_SMC_UseFVG      = true;
input bool   SB_SMC_UseOB       = true;
input bool   SB_SMC_UseBOS      = true;
input double SB_SMC_FVG_MinPips = 1.0;
input int    SB_SMC_OB_Lookback = 20;
input int    SB_SMC_BOS_Lookback= 50;

// --- Helper Enums (copied from SignalBrain for decoding)
enum ENUM_REASON_CODE
{
    REASON_NONE,
    REASON_BUY_HTF_CONTINUATION,
    REASON_SELL_HTF_CONTINUATION,
    REASON_BUY_LIQ_GRAB_ALIGNED,
    REASON_SELL_LIQ_GRAB_ALIGNED,
    REASON_NO_ZONE,
    REASON_LOW_ZONE_STRENGTH,
    REASON_BIAS_CONFLICT,
    REASON_TEST_SCENARIO
};

// --- Indicator Path Helper ---
#define AAI_IND_PREFIX "AlfredAI\\"
inline string AAI_Ind(const string name)
{
   if(StringFind(name, AAI_IND_PREFIX) == 0) return name;
   return AAI_IND_PREFIX + name;
}

//+------------------------------------------------------------------+
//| Script program start function                                    |
//+------------------------------------------------------------------+
void OnStart()
{
    Print("✅ AAI DebugHelper Script Running (v3.0)...");

    // TICKET #4: Create a single handle to SignalBrain with all pass-throughs
    int sb_handle = iCustom(_Symbol, _Period, AAI_Ind("AAI_Indicator_SignalBrain"),
                            SB_SafeTest, SB_UseZE, SB_UseBC, SB_UseSMC, SB_WarmupBars, SB_FastMA, SB_SlowMA,
                            SB_MinZoneStrength, SB_EnableDebug,
                            SB_Bonus_ZE, SB_Bonus_BC, SB_Bonus_SMC,
                            SB_BC_FastMA, SB_BC_SlowMA,
                            SB_ZE_MinImpulseMovePips,
                            SB_SMC_UseFVG, SB_SMC_UseOB, SB_SMC_UseBOS, SB_SMC_FVG_MinPips,
                            SB_SMC_OB_Lookback, SB_SMC_BOS_Lookback);

    if(sb_handle == INVALID_HANDLE)
    {
        Print("❌ ERROR: Could not get a handle to AAI_Indicator_SignalBrain. Is it compiled?");
        return;
    }

    // TICKET #4: Defensive read pattern for all 7 buffers on the last closed bar (shift=1)
    double v0[1],v1[1],v2[1],v3[1],v4[1],v5[1],v6[1];
    if(CopyBuffer(sb_handle,SB_BUF_SIGNAL,   1,1,v0)!=1 ||
       CopyBuffer(sb_handle,SB_BUF_CONF,     1,1,v1)!=1 ||
       CopyBuffer(sb_handle,SB_BUF_REASON,   1,1,v2)!=1 ||
       CopyBuffer(sb_handle,SB_BUF_ZE,       1,1,v3)!=1 ||
       CopyBuffer(sb_handle,SB_BUF_SMC_SIG,  1,1,v4)!=1 ||
       CopyBuffer(sb_handle,SB_BUF_SMC_CONF, 1,1,v5)!=1 ||
       CopyBuffer(sb_handle,SB_BUF_BC,       1,1,v6)!=1)
    {
       Print("❌ ERROR: Failed to copy buffer data from SignalBrain. Indicator may be warming up.");
       IndicatorRelease(sb_handle);
       return;
    }
    
    // Extract and typecast the data
    int    sig   = (int)MathRound(v0[0]);
    double conf  = v1[0];
    int    rsn   = (int)MathRound(v2[0]);
    double ze    = v3[0];
    int    smc_s = (int)MathRound(v4[0]);
    double smc_c = v5[0];
    int    bc    = (int)MathRound(v6[0]);

    // --- Format and Print All Data ---
    Print("-------------------[ AAI DEBUG REPORT ]-------------------");
PrintFormat("Bar Time: %s", TimeToString(iTime(_Symbol, _Period, 1), TIME_DATE|TIME_SECONDS));
    Print("---");
    PrintFormat("🧠 SignalBrain Output:");
    PrintFormat("   - Final Signal: %s (%d)", SignalToString(sig), sig);
    PrintFormat("   - Final Confidence: %.1f / 100", conf);
    PrintFormat("   - Reason Code: \"%s\" (%d)", ReasonCodeToString(rsn), rsn);
    Print("---");
    PrintFormat("🧱 Raw Features (for Gating):");
    PrintFormat("   - ZE Strength: %.2f", ze);
    PrintFormat("   - BC Bias: %s (%d)", BiasToString(bc), bc);
    PrintFormat("   - SMC Signal: %s (%d)", SignalToString(smc_s), smc_s);
    PrintFormat("   - SMC Confidence: %.1f / 10", smc_c);
    Print("----------------------------------------------------------");

    IndicatorRelease(sb_handle);
}

//+------------------------------------------------------------------+
//| HELPER FUNCTIONS                                                 |
//+------------------------------------------------------------------+

string BiasToString(int bias_value)
{
    if(bias_value > 0) return "BULL";
    if(bias_value < 0) return "BEAR";
    return "NEUTRAL";
}

string SignalToString(int signal_value)
{
    if(signal_value > 0) return "BUY";
    if(signal_value < 0) return "SELL";
    return "NONE";
}

string ReasonCodeToString(int reason_code)
{
    ENUM_REASON_CODE code = (ENUM_REASON_CODE)reason_code;
    switch(code)
    {
        case REASON_BUY_HTF_CONTINUATION:   return "Buy HTF Continuation";
        case REASON_SELL_HTF_CONTINUATION:  return "Sell HTF Continuation";
        case REASON_BUY_LIQ_GRAB_ALIGNED:   return "Buy Liq. Grab Aligned";
        case REASON_SELL_LIQ_GRAB_ALIGNED:  return "Sell Liq. Grab Aligned";
        case REASON_NO_ZONE:                return "No Zone";
        case REASON_LOW_ZONE_STRENGTH:      return "Low Zone Strength";
        case REASON_BIAS_CONFLICT:          return "Bias Conflict";
        case REASON_TEST_SCENARIO:          return "Test Scenario";
        case REASON_NONE:
        default:
            return "None";
    }
}
//+------------------------------------------------------------------+
