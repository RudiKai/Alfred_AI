Alfred AI — Operator Quickstart Guide (TradeManager)
This guide provides the essential steps to compile, configure, and run the AAI_EA_TradeManager.mq5 Expert Advisor in MetaTrader 5.

1. File Structure & Compilation
Ensure your file structure matches the following before compiling.

A. Required File Paths
The EA uses a subfolder to keep indicators organized. All indicator files must be placed in MQL5\Indicators\AlfredAI\.

EA: MQL5\Experts\AlfredAI\AAI_EA_TradeManager.mq5

Indicators:

MQL5\Indicators\AlfredAI\AAI_Indicator_SignalBrain.mq5

MQL5\Indicators\AlfredAI\AAI_Indicator_ZoneEngine.mq5

MQL5\Indicators\AlfredAI\AAI_Indicator_BiasCompass.mq5

MQL5\Indicators\AlfredAI\AAI_Indicator_SMC.mq5

B. Compile
In MetaEditor, right-click the MQL5 folder in the Navigator and select Compile. The build should complete with 0 errors and 0 warnings.

2. Key EA Inputs
When attaching AAI_EA_TradeManager.mq5 to a chart, review these core settings:

WarmupBars: Number of historical bars required before the EA starts evaluating signals.

ExecutionMode:

SignalsOnly: The EA will log per-bar status (AAI|k=v...) and HUD data but will not place trades.

AutoExecute: The EA will automatically place trades when all conditions are met.

ApprovalMode:

None: Trades are placed automatically (if ExecutionMode is AutoExecute).

Manual: A trade idea is generated, but it requires manual approval via a Global Variable before execution.

ZoneGate:

ZE_OFF: ZoneEngine strength is ignored.

ZE_PREFERRED: Trades are allowed even in weak zones, but signals in strong zones may be prioritized.

ZE_REQUIRED: Trades are blocked if zone strength is below InpZE_MinStrength.

MaxSpreadPoints: Hard limit for the allowable spread in points. Entries are blocked if the current spread exceeds this value.

MaxSlippagePoints: The maximum slippage in points allowed when sending a trade order.

OverExtMode:

HardBlock: Immediately blocks trades if the price is over-extended beyond the MA/ATR bands.

WaitForBand: Waits for the price to return inside the bands before executing a trade.

3. Running QA and Self-Tests
Use the provided scripts to verify the system is functioning correctly.

AAI_Script_QA_Smoke.mq5:

Action: Run this script to generate an up-to-date manual test plan.

Output: Creates MQL5/Files/AAI_QA_Checklist.md with step-by-step verification instructions.

AAI_Script_SelfTest_BC_ZE.mq5:

Action: Run this script on a chart to validate indicator contracts.

Output: Prints the last 10 closed-bar values for BiasCompass (bias) and ZoneEngine (strength) to the Experts log.

4. Logs & Data Files
The EA generates several outputs for analysis:

Per-Bar Status (Experts Log):

A single line is printed to the Experts log for every closed bar.

Format: AAI|t=...|sym=...|tf=...|sig=...|conf=...|reason=...|ze=...|bc=...|mode=...

Daily Trade Journal (CSV):

Location: MQL5/Files/AAI_Journal_YYYYMMDD.csv

Content: Contains a detailed, one-line entry for every closed trade, including entry/exit details, signal confidence, and reason codes. The file starts with a header row.

Deinitialization Summary (Experts Log):

A final summary line is printed when the EA is shut down or a backtest ends.

Format: AAI_SUMMARY|entries=...|wins=...|losses=...|ze_blk=...|bc_blk=...|overext_blk=...|spread_blk=...

5. Manual Approval Workflow
To manually approve a trade when ApprovalMode is set to Manual:

Wait for the EA to identify a trade opportunity on a closed bar. The log will show an [EVT_IDEA] line.

Run the AAI_Script_ApproveTrade.mq5 script on the same chart.

This script creates a specific Global Variable that the EA is listening for:

Key Format: AAI_APPROVE_<symbol>_<tfInt>_<barTime>

Example: AAI_APPROVE_EURUSD_15_1672531200

The EA will detect the variable, execute the trade, and immediately reset the variable to 0.0 to prevent duplicate entries.
