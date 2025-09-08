Awesome—here’s a **drop-in README block** for your repo root. It’s short, practical, and matches what you’ve got running now.

---

# Alfred\_AI — Quick Start (MT5)

A minimal, compile-clean baseline for the Alfred\_AI Expert Advisor on **MetaTrader 5**.

## Repo layout (key files)

```
MQL5/
  Experts/
    AlfredAI/
      AlfredAI_Strategy.mq5        # Runner EA (compiles clean)
  Include/
    AAI/
      AAI_ConfigINI.mqh            # v0.3 – tiny INI loader
      AAI_SignalProvider_SignalBrain.mqh  # v0.3 – signal provider stub (RSI demo optional)
  Files/
    AAI/
      config.ini                   # sample config (optional but recommended)
```

## Requirements

* MetaTrader 5 + MetaEditor (Windows; build ≥ 5260 recommended)
* Place this repo under your terminal’s **MQL5** directory (or symlink it)

Typical Windows path:

```
C:\Users\<you>\AppData\Roaming\MetaQuotes\Terminal\<ID>\MQL5\
```

## Install

1. Copy or clone the repo so the **MQL5** folder in this repo merges with your terminal’s **MQL5**.
2. Ensure these folders exist (create if missing):

```
MQL5\Files\AAI\
MQL5\Files\AAI\logs\
MQL5\Files\AAI\data\
```

## Build

### From MetaEditor

* Open **MetaEditor** → **Navigator** → right-click **MQL5 → Experts → Compile**.
  You should see: **43 files total (0 failed), 0 errors, 0 warnings**.

### From CLI (optional)

```bat
"C:\Program Files\MetaTrader 5\metaeditor64.exe" ^
  /compile:"MQL5\Experts\AlfredAI\AlfredAI_Strategy.mq5" ^
  /log:"build.log"
```

## Configure (optional but recommended)

Create `MQL5\Files\AAI\config.ini`:

```ini
[Risk]
enabled  = yes
max_risk = 0.75

[Session]
name = RUDI-001
```

On EA init you’ll see:

```
[AAI][INIT] Session=RUDI-001 | Risk.enabled=true | Risk.max_risk=0.7500
```

## Run a smoke test (Strategy Tester)

* Symbol/TF: **EURUSD, M15**
* Dates: e.g. **2025-01-01 → 2025-03-01**
* Model: **Every tick based on real ticks**
* Expert: `Experts\AlfredAI\AlfredAI_Strategy.ex5`

You should see init logs and RiskManager day-reset logs. By default the signal provider returns **no trades** (safe baseline).

### Want trades immediately?

Enable a tiny **RSI cross** demo rule:

**Option A (recommended):** define the flag in the EA *before* the include:

```cpp
#define AAI_SB_ENABLE_RSI 1
#include <AAI/AAI_SignalProvider_SignalBrain.mqh>
```

**Option B:** open the header and uncomment the same define.

This creates occasional BUY/SELL signals when RSI crosses 30/70.

## What’s included

* **Config loader** (`AAI_ConfigINI.mqh v0.3`): case-insensitive `[Section] key=value` with defaults.
* **Signal provider** (`AAI_SignalProvider_SignalBrain.mqh v0.3`): returns “no signal” by default; optional RSI demo behind `AAI_SB_ENABLE_RSI`. Uses your project’s `AAI_Signal` (camelCase fields) from `AlfredAI_Signal_IF.mqh`.
* **Strategy runner** (`AlfredAI_Strategy.mq5`): loads config, prints session/risk on init, sets 1s timer.

## Troubleshooting

* **“Config not found”**
  Create `MQL5\Files\AAI\config.ini` (see sample) or ignore—the EA uses defaults.
* **No trades in tester**
  That’s expected unless you enable the RSI demo or wire a real provider into `CAlfredStrategy`.
* **Folder errors / missing paths**
  Ensure `MQL5\Files\AAI\`, `logs\`, `data\` exist. In code, call a helper like:

  ```cpp
  bool EnsureFolder(const string rel){ if(FileIsExist(rel)) return true; return FolderCreate(rel); }
  ```
* **Duplicate `AAI_Signal` type**
  Only define `struct AAI_Signal` once (in `AlfredAI_Signal_IF.mqh`). The provider includes that file; it should not redeclare the struct.
* **Weird `[` parser errors**
  Remove any stray AI citation tags like `[cite_start]` / `[cite: 27]` from headers.

## Contributing

* Keep headers free of `#property`/`#pragma once`.
* Use includes as `<AAI/...>`.
* Preserve **0 errors, 0 warnings**.
* Prefer adding small smoke-tests to Strategy Tester for any new module.

## License

TBD.

---

If you want, I can also add a tiny “Getting Trades” section in the README that shows how to inject the provider into `CAlfredStrategy` (one setter call) so future you doesn’t have to remember.
