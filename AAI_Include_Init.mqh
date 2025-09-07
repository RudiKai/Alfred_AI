//+------------------------------------------------------------------+
//|                       AAI_Include_Init.mqh                       |
//|                v2.0 - Defaults & Init Function                   |
//|              Copyright 2025, AlfredAI Project                    |
//+------------------------------------------------------------------+
#ifndef __AAI_INCLUDE_INIT__
#define __AAI_INCLUDE_INIT__

#include <AAI_Include_Settings.mqh>

// Call this once from your OnInit()
void InitAlfredSettings()
{
   // Display
   Alfred.fontSize                   = 12;
   Alfred.corner                     = CORNER_LEFT_UPPER;
   Alfred.xOffset                    = 10;
   Alfred.yOffset                    = 10;

   // Behavior
   Alfred.showZoneWarning            = true;
   Alfred.enableAlerts               = true;
   Alfred.enablePane                 = true;
   Alfred.enableHUD                  = true;
   Alfred.enableCompass              = true;

   // AlertCenter
   Alfred.enableAlertCenter          = false;
   Alfred.alertStrongBiasAligned     = true;
   Alfred.alertDivergence            = true;
   Alfred.alertZoneEntry             = true;
   Alfred.alertBiasFlip              = true;
   Alfred.alertConfidenceThreshold   = 50;

   // Risk & SL/TP
   Alfred.atrMultiplierSL            = 1.5;
   Alfred.atrMultiplierTP            = 2.0;

   // Notifications
   Alfred.sendTelegram               = false;
   Alfred.sendWhatsApp               = false;

   // Expansion
   Alfred.alertSensitivity           = 5;
   Alfred.zoneProximityThreshold     = 2;

   // HUD Layout
   Alfred.enableHUDDiagnostics       = false;
   Alfred.hudCorner                  = CORNER_LEFT_LOWER;
   Alfred.hudXOffset                 = 10;
   Alfred.hudYOffset                 = 10;

   // ZoneEngine (formerly SupDemCore)
   Alfred.supdemZoneLookback         = 50;
   Alfred.supdemZoneDurationBars     = 100;
   Alfred.supdemMinImpulseMovePips   = 20.0;
   Alfred.supdemDemandColorHTF       = clrLightGreen;
   Alfred.supdemDemandColorLTF       = clrGreen;
   Alfred.supdemSupplyColorHTF       = clrHotPink;
   Alfred.supdemSupplyColorLTF       = clrRed;
   Alfred.supdemRefreshRateSeconds   = 30;
   Alfred.supdemEnableBreakoutRemoval= true;
   Alfred.supdemRequireBodyClose     = true;
   Alfred.supdemEnableTimeDecay      = true;
   Alfred.supdemTimeDecayBars        = 20;
   Alfred.supdemEnableMagnetForecast = true;

   // Compass Layout
   Alfred.compassYOffset             = 20;

   // Logging
   Alfred.logToFile                  = false;
   Alfred.logFilename                = "AlfredLog.csv";
   Alfred.logIncludeATR              = true;
   Alfred.logIncludeSession          = true;
   Alfred.logEnableScreenshots       = false;
   Alfred.screenshotFolder           = "Screenshots";
   Alfred.screenshotWidth            = 800;
   Alfred.screenshotHeight           = 600;

   // Pane TFBias toggle
   Alfred.enablePaneTFBias           = true;
}

#endif // __AAI_INCLUDE_INIT__
