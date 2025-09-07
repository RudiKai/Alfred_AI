//+------------------------------------------------------------------+
//|                    AAI_Script_DebugHelper.mq5                    |
//|                        v2.0 (Corrected)                          |
//|       Runs ONCE to print live data from Alfred modules.          |
//|              Copyright 2025, AlfredAI Project                    |
//+------------------------------------------------------------------+
#property strict
#property script_show_inputs // Defines this file as a script
#property version "2.0"

// --- Constants for Analysis (should match SignalBrain)
const ENUM_TIMEFRAMES HTF = PERIOD_H4;
const ENUM_TIMEFRAMES LTF = PERIOD_M15;

// --- Helper Enums (copied from SignalBrain for decoding)
enum ENUM_REASON_CODE
{
    REASON_NONE,
    REASON_BUY_LIQ_GRAB_ALIGNED,
    REASON_SELL_LIQ_GRAB_ALIGNED,
    REASON_NO_ZONE,
    REASON_LOW_ZONE_STRENGTH,
    REASON_BIAS_CONFLICT
};

//+------------------------------------------------------------------+
//| Script program start function                                    |
//+------------------------------------------------------------------+
void OnStart()
{
    Print("✅ AAI DebugHelper Script Running...");

    //--- 1. Fetch BiasCompass Data ---
    double htf_bias_arr[1], ltf_bias_arr[1];
    CopyBuffer(iCustom(_Symbol, HTF, "AAI_Indicator_BiasCompass.ex5"), 0, 1, 1, htf_bias_arr); // Use index 1 for closed bar data
    CopyBuffer(iCustom(_Symbol, LTF, "AAI_Indicator_BiasCompass.ex5"), 0, 1, 1, ltf_bias_arr);
    string htf_bias_str = BiasToString(htf_bias_arr[0]);
    string ltf_bias_str = BiasToString(ltf_bias_arr[0]);

    //--- 2. Fetch ZoneEngine Data (from current chart timeframe) ---
    double zone_engine_data[6]; // 0:Status, 1:Magnet, 2:Strength, 3:Fresh, 4:Vol, 5:Liq
    CopyBuffer(iCustom(_Symbol, _Period, "AAI_Indicator_ZoneEngine.ex5"), 0, 1, 6, zone_engine_data);
    string zone_type_str = ZoneTypeToString(zone_engine_data[0]);
    double zone_score = zone_engine_data[2];
    string liq_grab_str = (zone_engine_data[5] > 0.5) ? "true" : "false";
    
    //--- 3. Fetch SignalBrain Data ---
    double brain_data[4]; // 0:Signal, 1:Confidence, 2:ReasonCode, 3:ZoneTF
    CopyBuffer(iCustom(_Symbol, _Period, "AAI_Indicator_SignalBrain.ex5"), 0, 1, 4, brain_data);
    string signal_str = SignalToString(brain_data[0]);
    double confidence_score = brain_data[1];
    string reason_str = ReasonCodeToString(brain_data[2]);
    string zone_tf_str = PeriodSecondsToTFString((int)brain_data[3] * 60);
    
    //--- 4. Format and Print All Data ---
    Print("-------------------[ AAI DEBUG REPORT ]-------------------");
    PrintFormat("🧭 Compass — HTF Bias: %s, LTF Bias: %s", htf_bias_str, ltf_bias_str);
    PrintFormat("🧱 ZoneEngine — Zone: %s %s | Score: %.0f | LiquidityGrab: %s", zone_tf_str, zone_type_str, zone_score, liq_grab_str);
    PrintFormat("🧠 SignalBrain — Signal: %s | Confidence: %.0f | Reason: \"%s\"", signal_str, confidence_score, reason_str);
    Print("----------------------------------------------------------");

}

//+------------------------------------------------------------------+
//|                      HELPER FUNCTIONS                          |
//+------------------------------------------------------------------+

//--- Converts bias buffer value to a readable string
string BiasToString(double bias_value)
{
    if(bias_value > 0.5) return "BULL";
    if(bias_value < -0.5) return "BEAR";
    return "NEUTRAL";
}

//--- Converts zone status buffer value to a readable string
string ZoneTypeToString(double zone_status)
{
    if(zone_status > 0.5) return "Demand";
    if(zone_status < -0.5) return "Supply";
    return "None";
}

//--- Converts signal buffer value to a readable string
string SignalToString(double signal_value)
{
    if(signal_value > 0.5) return "BUY";
    if(signal_value < -0.5) return "SELL";
    return "NONE";
}

//--- Converts timeframe (in seconds) to a short string like "H1"
string PeriodSecondsToTFString(int seconds)
{
    switch(seconds)
    {
        case 900:    return "M15";
        case 1800:   return "M30";
        case 3600:   return "H1";
        case 7200:   return "H2";
        case 14400:  return "H4";
        case 86400:  return "D1";
        default:     return "Chart"; // Fallback for current chart period if not matched
    }
}


//--- Converts reason code buffer value to a readable string
string ReasonCodeToString(double reason_code)
{
    ENUM_REASON_CODE code = (ENUM_REASON_CODE)reason_code;
    switch(code)
    {
        case REASON_BUY_LIQ_GRAB_ALIGNED:
            return "Buy signal due to Liquidity Grab in Demand Zone with Bias Alignment.";
        case REASON_SELL_LIQ_GRAB_ALIGNED:
            return "Sell signal due to Liquidity Grab in Supply Zone with Bias Alignment.";
        case REASON_NO_ZONE:
            return "No signal: Price is not inside an active Supply/Demand zone.";
        case REASON_LOW_ZONE_STRENGTH:
            return "No signal: Active zone strength is below threshold.";
        case REASON_BIAS_CONFLICT:
            return "No signal: HTF and LTF biases are in conflict.";
        case REASON_NONE:
        default:
            return "No signal: Conditions not met.";
    }
}
//+------------------------------------------------------------------+
