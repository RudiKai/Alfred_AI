//+------------------------------------------------------------------+
//|                      AAI_QA_Smoke.mq5                            |
//|        Generates a checklist and prints a manual test plan       |
//|                   Copyright 2025, AlfredAI Project               |
//|                 https://github.com/rudikai/alfredai              |
//+------------------------------------------------------------------+
#property strict
#property script_show_inputs
#property version "2.0"

//--- Global constants for the script
const string CHECKLIST_FILENAME = "AAI_QA_Checklist.md";

//+------------------------------------------------------------------+
//| Generates the content for the QA checklist file.                 |
//+------------------------------------------------------------------+
string GetChecklistContent()
  {
   string content = "";
   content += "# AlfredAI QA Checklist (TradeManager)\n\n";
   content += "This is a manual smoke test plan to ensure core functionality is working after a code change.\n\n";

   content += "## 1. Build & Setup\n";
   content += "- [ ] **Compile All:** Recompile the entire `AlfredAI` project in MetaEditor.\n";
   content += "  - **Expected:** The build completes with 0 errors and 0 warnings.\n";
   content += "- [ ] **Attach EA:** Attach `AAI_EA_TradeManager.mq5` to a chart (e.g., EURUSD M15).\n";
   content += "  - **Expected:** EA initializes without errors. HUD appears on chart.\n\n";

   content += "## 2. Core EA Behavior (Strategy Tester)\n";
   content += "Run a short backtest on `AAI_EA_TradeManager.mq5`.\n\n";
   content += "- [ ] **Per-Bar Journaling (AAI|k=v):** Check the Tester 'Journal' tab.\n";
   content += "  - **Expected:** Exactly one `AAI|t=...` line is printed for each closed bar. The timestamp should match the bar's open time.\n";
   content += "- [ ] **Daily CSV Logs:** Check the `MQL5/Files/` directory.\n";
   content += "  - **Expected:** `AAI_Journal_YYYYMMDD.csv` files are created. Each new day's file starts with a correct header line (`t,sym,tf,...`).\n";
   content += "- [ ] **HUD Display:** Observe the on-chart HUD.\n";
   content += "  - **Expected:** The HUD text updates once per closed bar with the correct state (sig, conf, etc.).\n";
   content += "- [ ] **Warmup Gate:** Run a test with `WarmupBars` set higher than available history.\n";
   content += "  - **Expected:** The journal shows `[WARMUP]` messages once per bar. No trades are attempted. Neutral values (0) are logged in the `AAI|...` line.\n";
   content += "- [ ] **Deinit Summary:** Finish the backtest.\n";
   content += "  - **Expected:** Exactly one `AAI_SUMMARY|...` line is printed at the end with final counters.\n\n";

   content += "## 3. Entry Gates (Strategy Tester)\n";
   content += "Set `ExecutionMode = AutoExecute` for these tests.\n\n";
   content += "- [ ] **Manual Approval Gate:** Set `ApprovalMode = Manual`.\n";
   content += "  - **Expected:** The EA identifies trade ideas but does **not** enter. After running `AAI_Script_ApproveTrade.mq5` (or setting the GV manually), exactly one trade is executed for that bar, and the GV is reset to 0.\n";
   content += "- [ ] **ZoneEngine Gate:** Set `InpZE_Gate = ZE_REQUIRED` and `InpZE_MinStrength` to a very high value (e.g., 100).\n";
   content += "  - **Expected:** No trades are entered. The journal shows `[AAI_BLOCK] reason=ZE_REQUIRED` once per bar where a signal existed. The `ze_blk` counter in the final summary should be > 0.\n";
   content += "- [ ] **BiasCompass Gate:** Set `InpBC_AlignMode = BC_REQUIRED` and find a bar with a clear signal/bias conflict.\n";
   content += "  - **Expected:** The conflicting trade is blocked. The journal logs `[AAI_BLOCK] reason=BC_CONFLICT`. The `bc_blk` counter in the summary should be > 0.\n";
   content += "- [ ] **Spread Guard:** Set `MaxSpreadPoints` to a low value (e.g., 1).\n";
   content += "  - **Expected:** No trades are entered. The journal logs `[SPREAD_BLK]` messages. The `spread_blk` counter in the summary should be > 0.\n";
   content += "- [ ] **Over-extension Guard:** Find a strong trend. Test with `OverExtMode = HardBlock`.\n";
   content += "  - **Expected:** Entries are blocked when price is far from the mean. The journal logs `[OVEREXT_BLK]`. The `overext_blk` counter in the summary should be > 0.\n\n";

   content += "## 4. Indicator Self-Tests\n";
   content += "- [ ] **Run Self-Test Script:** Execute `AAI_Script_SelfTest_BC_ZE.mq5` on a chart.\n";
   content += "  - **Expected:** The script runs without errors and prints the last 10 closed-bar values for Bias and ZE Strength. Values should be sane (e.g., bias is -1, 0, or 1; ZE strength is >= 0).\n";

   return content;
  }

//+------------------------------------------------------------------+
//| Prints a formatted test item to the log.                         |
//+------------------------------------------------------------------+
void PrintTestItem(string category, string test, string status, string comment = "")
  {
   PrintFormat("%-12s | %-40s | %s %s", category, test, status, comment);
  }

//+------------------------------------------------------------------+
//| Script program start function                                    |
//+------------------------------------------------------------------+
void OnStart()
  {
   Print("--- Starting AlfredAI Smoke Test ---");
   PrintFormat("%-12s | %-40s | %s", "Category", "Test Item", "Status");
   Print("--------------------------------------------------------------------");

   // --- Test 1: Generate the QA Checklist File ---
   string test_item = "Generate QA_Checklist.md";
   int handle = FileOpen(CHECKLIST_FILENAME, FILE_WRITE|FILE_TXT|FILE_COMMON, ';', CP_UTF8);
   if(handle != INVALID_HANDLE)
     {
      FileWriteString(handle, GetChecklistContent());
      FileClose(handle);
      PrintTestItem("Setup", test_item, "[PASS]", "(File created/updated)");
     }
   else
     {
      PrintTestItem("Setup", test_item, "[FAIL]", "(Could not write file, error: " + (string)GetLastError() + ")");
     }

   // --- The rest of the items are manual checks printed for the user to follow ---
   Print("--------------------------------------------------------------------");
   Print("The following are MANUAL checks. Please verify them against the system.");
   Print("The QA Checklist has been updated in MQL5/Files/AAI_QA_Checklist.md");
   Print("--------------------------------------------------------------------");

   Print("--- AlfredAI Smoke Test Complete ---");
  }
//+------------------------------------------------------------------+
