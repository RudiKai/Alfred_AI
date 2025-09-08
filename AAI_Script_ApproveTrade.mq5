//+------------------------------------------------------------------+
//|               AAI_Script_ApproveTrade.mq5                        |
//|                                                                  |
//|  Sets the GlobalVariable to approve a trade for the last         |
//|  closed bar when the EA is in Manual Approval mode.              |
//|              Copyright 2025, AlfredAI Project                    |
//+------------------------------------------------------------------+
#property strict
#property script_show_inputs
#property version "1.0"

//+------------------------------------------------------------------+
//| Script program start function                                    |
//+------------------------------------------------------------------+
void OnStart()
{
  string sym = _Symbol;
  ENUM_TIMEFRAMES tf = (ENUM_TIMEFRAMES)Period();
  
  // Ensure we are approving the last fully closed bar
  datetime barTime = iTime(sym, tf, 1); 
  
  if(barTime == 0)
  {
      Print("Could not get the time of the last closed bar. No approval set.");
      return;
  }

  string key = StringFormat("AAI_APPROVE_%s_%d_%I64d", sym, (int)tf, (long)barTime);
  
  if(GlobalVariableSet(key, 1.0))
  {
    PrintFormat("[MANUAL_APPROVE] Set approval for bar %s. Key: %s = 1.0", TimeToString(barTime), key);
  }
  else
  {
    PrintFormat("[ERROR] Failed to set GlobalVariable. Key: %s", key);
  }
}
//+------------------------------------------------------------------+
