//+------------------------------------------------------------------+
//|                      AAI_QA_Smoke.mq5                            |
//|        Generates a checklist and prints a manual test plan       |
//|                   Copyright 2025, AlfredAI Project               |
//|                 https://github.com/rudikai/alfredai              |
//+------------------------------------------------------------------+
#property strict
#property script_show_inputs

//--- Global constants for the script
const string CHECKLIST_FILENAME = "AAI_QA_Checklist.md";

//+------------------------------------------------------------------+
//| Generates the content for the QA checklist file.                 |
//+------------------------------------------------------------------+
string GetChecklistContent()
  {
   string content = "";
   content += "# AlfredAI QA Checklist\n\n";
   content += "This is a manual smoke test plan to ensure core functionality is working after a code change.\n\n";

   content += "## 1. Build Verification\n";
   content += "- [ ] **Compile All:** Recompile the entire `AlfredAI` project in MetaEditor.\n";
   content += "  - **Expected:** The build completes with 0 errors and 0 warnings.\n\n";

   content += "## 2. Journaling System\n";
   content += "- [ ] **EA Heartbeat:** Attach `AAI_EA_TradeManager.mq5` to a chart.\n";
   content += "  - **Expected:** The `AAI_Journal_<session>.log` file is created and an `Init` line is written.\n";
   content += "- [ ] **Backtest Logs:** Run a short backtest on `AAI_EA_TradeManager.mq5`.\n";
   content += "  - **Expected:** The journal contains exactly one `BacktestStart` and one `BacktestEnd` event for the run.\n\n";

   content += "## 3. Risk Management\n";
   content += "- [ ] **Limit Enforcement:** Set a low `DailyLossLimit` in the config (e.g., -1.0) and run the test harness to create a losing trade.\n";
   content += "  - **Expected:** The journal logs a `Risk:DailyLoss` event, and no new trades are opened.\n\n";

   content += "## 4. Alerts & Notifications\n";
   content += "- [ ] **Push/Telegram Test:** Trigger a test alert from a script or by modifying the Strategy EA.\n";
   content += "  - **Expected:** A push notification arrives on the configured mobile device and/or a message appears in the configured Telegram chat. The journal logs an `Alert` event.\n\n";

   content += "## 5. Visual Indicators\n";
   content += "- [ ] **Drawing:** Attach `AAI_Indicator_ZE_Visualizer.mq5` and `AAI_Indicator_SMC_v1.mq5` to a chart.\n";
   content += "  - **Expected:** Both indicators draw their respective objects (zones, FVG, etc.) on the chart without errors.\n";
   content += "- [ ] **Cleanup:** Remove both indicators from the chart.\n";
   content += "  - **Expected:** All graphical objects created by the indicators are properly removed from the chart.\n\n";

   content += "## 6. Log Aggregator\n";
   content += "- [ ] **CSV Generation:** Run the `AAI_Log_Aggregator.mq5` script after generating some trade history.\n";
   content += "  - **Expected:** The `AAI_Summary.csv` file is created or updated in the `MQL5/Files` directory with correct daily statistics.\n";

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
   if(!FileIsExist(CHECKLIST_FILENAME, FILE_COMMON))
     {
      int handle = FileOpen(CHECKLIST_FILENAME, FILE_WRITE|FILE_TXT|FILE_COMMON, ';', CP_UTF8);
      if(handle != INVALID_HANDLE)
        {
         FileWriteString(handle, GetChecklistContent());
         FileClose(handle);
         PrintTestItem("Setup", test_item, "[PASS]", "(File created)");
        }
      else
        {
         PrintTestItem("Setup", test_item, "[FAIL]", "(Could not write file, error: " + (string)GetLastError() + ")");
        }
     }
   else
     {
      PrintTestItem("Setup", test_item, "[PASS]", "(File already exists)");
     }

   // --- The rest of the items are manual checks printed for the user to follow ---
   Print("--------------------------------------------------------------------");
   Print("The following are MANUAL checks. Please verify them against the system.");
   Print("--------------------------------------------------------------------");

   PrintTestItem("Build", "Compile all files with 0 warnings", "[MANUAL]");
   PrintTestItem("Journal", "EA writes heartbeats and backtest logs", "[MANUAL]");
   PrintTestItem("Risk", "RiskManager blocks trades and journals", "[MANUAL]");
   PrintTestItem("Alerts", "Push and/or Telegram alerts are sent", "[MANUAL]");
   PrintTestItem("Indicators", "Visual indicators draw and clean up", "[MANUAL]");
   PrintTestItem("Aggregator", "Log aggregator updates summary CSV", "[MANUAL]");

   Print("--------------------------------------------------------------------");
   Print("--- AlfredAI Smoke Test Complete ---");
  }
//+------------------------------------------------------------------+

