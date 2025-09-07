//+------------------------------------------------------------------+
//|               AAI_Script_SelfTest_BC_ZE.mq5                      |
//|                      v1.0 (Initial)                              |
//|   Runs ONCE to print last 5 closed-bar values for BC and ZE.     |
//|              Copyright 2025, AlfredAI Project                    |
//+------------------------------------------------------------------+
#property strict
#property script_show_inputs
#property version "1.0"

//--- Script Inputs ---
input string          ST_Symbol = "";             // Symbol to test (current chart if empty)
input ENUM_TIMEFRAMES ST_TF     = PERIOD_CURRENT; // Timeframe to test
input int             ST_Bars   = 5;              // Number of closed bars to print

//+------------------------------------------------------------------+
//| Script program start function                                    |
//+------------------------------------------------------------------+
void OnStart()
{
    // --- Determine symbol and timeframe ---
    string symbol = (ST_Symbol == "") ? _Symbol : ST_Symbol;
    ENUM_TIMEFRAMES timeframe = (ST_TF == PERIOD_CURRENT) ? _Period : ST_TF;
    
    PrintFormat("[SELFTEST] Running for %s on %s...", symbol, EnumToString(timeframe));

    // --- 1. Create iCustom handles ---
    int bc_handle = iCustom(symbol, timeframe, "AAI_Indicator_BiasCompass");
    int ze_handle = iCustom(symbol, timeframe, "AAI_Indicator_ZoneEngine");

    if(bc_handle == INVALID_HANDLE || ze_handle == INVALID_HANDLE)
    {
        PrintFormat("[SELFTEST_ERROR] Failed to get handles. BC=%d, ZE=%d", bc_handle, ze_handle);
        return;
    }

    // --- Wait for a moment to ensure indicators have calculated ---
    Sleep(500);

    // --- 2. Prepare buffers to receive data ---
    int bars_to_copy = MathMax(1, ST_Bars);
    double bc_data[];
    double ze_data[];
    ArrayResize(bc_data, bars_to_copy);
    ArrayResize(ze_data, bars_to_copy);
    ArraySetAsSeries(bc_data, true);
    ArraySetAsSeries(ze_data, true);

    // --- 3. Copy the data window (shift=1 for closed bars) ---
    // Bias is on buffer 0 for BiasCompass
    int bc_copied = CopyBuffer(bc_handle, 0, 1, bars_to_copy, bc_data);
    // Strength is on buffer 0 for ZoneEngine
    int ze_copied = CopyBuffer(ze_handle, 0, 1, bars_to_copy, ze_data);

    if(bc_copied < bars_to_copy || ze_copied < bars_to_copy)
    {
        PrintFormat("[SELFTEST_WARN] Could not copy all requested bars. BC=%d, ZE=%d. Indicators might still be warming up.", bc_copied, ze_copied);
    }
    
    Print("--- [SELFTEST] START ---");
    // --- 4. Print the results in a loop ---
    // We loop from oldest (bars_to_copy - 1) to newest (0)
    for(int i = MathMin(bc_copied, ze_copied) - 1; i >= 0; i--)
    {
        int bar_shift = i + 1; // The actual bar shift (e.g., i=0 is shift=1)
        int bias = (int)bc_data[i];
        int strength = (int)ze_data[i];
        
        PrintFormat("[SELFTEST] bar_shift=%d bias=%d ze_strength=%d", bar_shift, bias, strength);
    }
    Print("--- [SELFTEST] END ---");

    // --- 5. Release handles ---
    IndicatorRelease(bc_handle);
    IndicatorRelease(ze_handle);
}
//+------------------------------------------------------------------+
