//+------------------------------------------------------------------+
//|               AAI_Script_SelfTest_BC_ZE.mq5                      |
//|                      v2.0 (TradeManager)                         |
//|   Runs ONCE to print last 10 closed-bar values for BC and ZE.    |
//|              Copyright 2025, AlfredAI Project                    |
//+------------------------------------------------------------------+
#property strict
#property script_show_inputs
#property version "2.0"

//--- Script Inputs ---
input string          ST_Symbol = "";             // Symbol to test (current chart if empty)
input ENUM_TIMEFRAMES ST_TF     = PERIOD_CURRENT; // Timeframe to test
input int             ST_Bars   = 10;             // Number of closed bars to print

//+------------------------------------------------------------------+
//| Script program start function                                    |
//+------------------------------------------------------------------+
void OnStart()
{
    // --- Determine symbol and timeframe ---
    string symbol = (ST_Symbol == "") ? _Symbol : ST_Symbol;
    ENUM_TIMEFRAMES timeframe = (ST_TF == PERIOD_CURRENT) ? (ENUM_TIMEFRAMES)_Period : ST_TF;
    
    PrintFormat("[SELFTEST] Running for %s on %s...", symbol, EnumToString(timeframe));

    // --- 1. Create iCustom handles with correct subfolder path ---
    int bc_handle = iCustom(symbol, timeframe, "AlfredAI\\AAI_Indicator_BiasCompass");
    int ze_handle = iCustom(symbol, timeframe, "AlfredAI\\AAI_Indicator_ZoneEngine");

    if(bc_handle == INVALID_HANDLE || ze_handle == INVALID_HANDLE)
    {
        PrintFormat("[SELFTEST_ERROR] Failed to get handles. BC=%d, ZE=%d", bc_handle, ze_handle);
        return;
    }

    // --- Wait for a moment to ensure indicators have calculated ---
    Sleep(1000);

    // --- 2. Prepare buffers to receive data ---
    int bars_to_copy = MathMax(1, ST_Bars);
    double bc_data[];
    double ze_data[];
    MqlRates rates[];
    ArrayResize(bc_data, bars_to_copy);
    ArrayResize(ze_data, bars_to_copy);
    ArrayResize(rates, bars_to_copy);
    
    // Set as series to read from newest to oldest
    ArraySetAsSeries(bc_data, true);
    ArraySetAsSeries(ze_data, true);
    ArraySetAsSeries(rates, true);

    // --- 3. Copy the data window (shift=1 for closed bars) ---
    int bc_copied = CopyBuffer(bc_handle, 0, 1, bars_to_copy, bc_data);
    int ze_copied = CopyBuffer(ze_handle, 0, 1, bars_to_copy, ze_data);
    int rates_copied = CopyRates(symbol, timeframe, 1, bars_to_copy, rates);

    if(bc_copied < bars_to_copy || ze_copied < bars_to_copy || rates_copied < bars_to_copy)
    {
        PrintFormat("[SELFTEST_WARN] Could not copy all requested bars. BC=%d, ZE=%d, Rates=%d. Indicators might still be warming up.", bc_copied, ze_copied, rates_copied);
    }
    
    Print("--- [SELFTEST] START ---");
    // --- 4. Print the results in a loop (from oldest to newest) ---
    int print_count = MathMin(MathMin(bc_copied, ze_copied), rates_copied);
    for(int i = print_count - 1; i >= 0; i--)
    {
        datetime bar_time = rates[i].time;
        int bias = (int)bc_data[i];
        double strength = ze_data[i];
        
        PrintFormat("[SELFTEST] t=%s bc=%d ze=%.1f", TimeToString(bar_time), bias, strength);
    }
    Print("--- [SELFTEST] END ---");

    // --- 5. Release handles ---
    IndicatorRelease(bc_handle);
    IndicatorRelease(ze_handle);
}
//+------------------------------------------------------------------+
