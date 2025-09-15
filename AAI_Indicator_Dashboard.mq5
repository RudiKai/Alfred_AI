//+------------------------------------------------------------------+
//|                   AAI_Indicator_Dashboard.mq5                    |
//|                    v4.1 - EA Parity Refactor                     |
//|        (Displays all data from the AAI indicator suite)          |
//|                                                                  |
//| Copyright 2025, AlfredAI Project                                 |
//+------------------------------------------------------------------+
#property strict
#property indicator_chart_window
#property indicator_plots 0
#property version "4.1"

// --- UI Constants ---
#define PANE_PREFIX "AAI_Dashboard_v4_"
#define PANE_X_POS 15
#define PANE_Y_POS 15
#define PANE_WIDTH 250

// --- Font Sizes ---
#define FONT_SIZE_TITLE 14
#define FONT_SIZE_HEADER 12
#define FONT_SIZE_NORMAL 10

// --- Colors ---
#define COLOR_BG         (color)C'34,34,34'
#define COLOR_HEADER     C'135,206,250' // LightSkyBlue
#define COLOR_LABEL      C'211,211,211' // LightGray
#define COLOR_BULL       C'34,139,34'   // ForestGreen
#define COLOR_BEAR       C'220,20,60'   // Crimson
#define COLOR_NEUTRAL    C'255,215,0'   // Gold
#define COLOR_AMBER      C'255,193,7'    // Amber
#define COLOR_WHITE      C'255,255,255'
#define COLOR_SEPARATOR  C'70,70,70'

// --- TICKET #4: Define SignalBrain buffer indices ---
#define SB_BUF_SIGNAL   0
#define SB_BUF_CONF     1
#define SB_BUF_REASON   2
#define SB_BUF_ZE       3
#define SB_BUF_SMC_SIG  4
#define SB_BUF_SMC_CONF 5
#define SB_BUF_BC       6

// --- TICKET: Add SB Inputs for EA Parity ---
input group "--- SignalBrain Configuration ---";
input ENUM_TIMEFRAMES SB_Timeframe = PERIOD_M15;     // Set to EA's SignalTimeframe
// Core SB toggles / base logic
input bool   SB_SafeTest        = false;
input bool   SB_UseZE           = true;
input bool   SB_UseBC           = true;
input bool   SB_UseSMC          = true;
input int    SB_WarmupBars      = 150;
input int    SB_FastMA          = 10;
input int    SB_SlowMA          = 30;
input int    SB_MinZoneStrength = 4;
input bool   SB_EnableDebug     = false;
// Temporary additive bonuses inside SB
input int    SB_Bonus_ZE        = 25;
input int    SB_Bonus_BC        = 25;
input int    SB_Bonus_SMC       = 25;
// BiasCompass pass-through
input int    SB_BC_FastMA       = 10;
input int    SB_BC_SlowMA       = 30;
// ZoneEngine pass-through
input double SB_ZE_MinImpulseMovePips = 10.0;
// SMC pass-through
input bool   SB_SMC_UseFVG         = true;
input bool   SB_SMC_UseOB          = true;
input bool   SB_SMC_UseBOS         = true;
input double SB_SMC_FVG_MinPips    = 1.0;
input int    SB_SMC_OB_Lookback    = 20;
input int    SB_SMC_BOS_Lookback   = 50;

// --- Indicator Handle (Single Source of Truth) ---
int g_sb_handle = INVALID_HANDLE;

// --- State Variables ---
struct DashboardState
{
    // Final SB Data
    int      signal;
    double   confidence;
    
    // Raw Features
    double   ze_strength;
    int      bc_bias;
    double   smc_confidence;
    
    // Terminal Data
    int      spread;
    string   session_status;
    
    // Internal State
    datetime last_update_time;
};

DashboardState g_state;

// --- Indicator Path Helper ---
#define AAI_IND_PREFIX "AlfredAI\\"
inline string AAI_Ind(const string name)
{
   if(StringFind(name, AAI_IND_PREFIX) == 0) return name;
   return AAI_IND_PREFIX + name;
}

// --- Forward Declarations ---
void DrawDashboard();
void DrawCard(int x, int &y, int width, string title, const string &rows[], const color &row_colors[]);
void DrawLabel(string name, string text, int x, int y, int size, color clr, string font = "Arial", ENUM_ANCHOR_POINT anchor = ANCHOR_LEFT);
void DrawRect(string name, int x, int y, int w, int h, color bg_color);
void UpdateState();
string GetSessionStatus();

//+------------------------------------------------------------------+
//| Initialization                                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    // --- TICKET: Create single SignalBrain handle with all inputs ---
    g_sb_handle = iCustom(_Symbol, SB_Timeframe, AAI_Ind("AAI_Indicator_SignalBrain"),
                          // Keep order EXACTLY as SignalBrain's inputs
                          SB_SafeTest, SB_UseZE, SB_UseBC, SB_UseSMC,
                          SB_WarmupBars, SB_FastMA, SB_SlowMA,
                          SB_MinZoneStrength, SB_EnableDebug,
                          SB_Bonus_ZE, SB_Bonus_BC, SB_Bonus_SMC,
                          SB_BC_FastMA, SB_BC_SlowMA,
                          SB_ZE_MinImpulseMovePips,
                          SB_SMC_UseFVG, SB_SMC_UseOB, SB_SMC_UseBOS, SB_SMC_FVG_MinPips,
                          SB_SMC_OB_Lookback, SB_SMC_BOS_Lookback);
                          
    if(g_sb_handle == INVALID_HANDLE)
    {
        Print("Dashboard: failed to create SB handle");
        return INIT_FAILED;
    }
    
    // --- Initialize State ---
    ZeroMemory(g_state);
    
    // --- Set Timer for updates ---
    EventSetTimer(2); 
    
    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Deinitialization                                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    // TICKET: Clean deinit
    if(g_sb_handle != INVALID_HANDLE)
    {
        IndicatorRelease(g_sb_handle);
        g_sb_handle = INVALID_HANDLE;
    }
    EventKillTimer();
    ObjectsDeleteAll(0, PANE_PREFIX);
    ChartRedraw();
}

//+------------------------------------------------------------------+
//| OnCalculate - Required, but logic is in OnTimer.                 |
//+------------------------------------------------------------------+
int OnCalculate(const int,const int,const datetime&[],const double&[],const double&[],const double&[],const double&[],const long&[],const long&[],const int&[])
{
    return 0; // Returning 0 as rates_total is not used, preventing unnecessary chart redraws from this event
}

//+------------------------------------------------------------------+
//| OnTimer - Main update and drawing loop                           |
//+------------------------------------------------------------------+
void OnTimer()
{
    UpdateState();
    DrawDashboard();
    ChartRedraw();
}

//+------------------------------------------------------------------+
//| Fetches all data and updates the global state struct             |
//+------------------------------------------------------------------+
void UpdateState()
{
    // TICKET: Defensive read with 1-element arrays
    double v0[1],v1[1],v2[1],v3[1],v4[1],v5[1],v6[1];
    if(CopyBuffer(g_sb_handle,0,1,1,v0)!=1) return;
    if(CopyBuffer(g_sb_handle,1,1,1,v1)!=1) return;
    if(CopyBuffer(g_sb_handle,2,1,1,v2)!=1) return;
    if(CopyBuffer(g_sb_handle,3,1,1,v3)!=1) return;
    if(CopyBuffer(g_sb_handle,4,1,1,v4)!=1) return;
    if(CopyBuffer(g_sb_handle,5,1,1,v5)!=1) return;
    if(CopyBuffer(g_sb_handle,6,1,1,v6)!=1) return;

    g_state.signal         = (int)MathRound(v0[0]);
    g_state.confidence     = v1[0];
    g_state.ze_strength    = v3[0];
    g_state.smc_confidence = v5[0];
    g_state.bc_bias        = (int)MathRound(v6[0]);

    // --- Fetch Terminal Data ---
    g_state.spread = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
    g_state.session_status = GetSessionStatus();
    g_state.last_update_time = TimeCurrent();
}


//+------------------------------------------------------------------+
//| Main function to draw the entire dashboard UI                    |
//+------------------------------------------------------------------+
void DrawDashboard()
{
    int x = PANE_X_POS;
    int y = PANE_Y_POS;
    int y_start = y;
    
    // --- Draw Title ---
    DrawLabel("Title", "AlfredAI Dashboard v4.1", x + 5, y, FONT_SIZE_TITLE, COLOR_HEADER, "Calibri Bold");
    y += 30;

    // --- Card 1: Core Signal ---
    string signal_text;
    color signal_color;
    if(g_state.signal > 0) { signal_text = "BUY"; signal_color = COLOR_BULL; }
    else if(g_state.signal < 0) { signal_text = "SELL"; signal_color = COLOR_BEAR; }
    else { signal_text = "NEUTRAL"; signal_color = COLOR_NEUTRAL; }
    
    string card1_rows[] = {
        "Signal: " + signal_text,
        "Confidence: " + StringFormat("%.0f / 100", g_state.confidence)
    };
    color card1_colors[] = { signal_color, COLOR_WHITE };
    DrawCard(x, y, PANE_WIDTH, "CORE SIGNAL", card1_rows, card1_colors);
    
    // --- Card 2: Market Context ---
    string bias_text;
    color bias_color;
    if(g_state.bc_bias > 0) { bias_text = "BULLISH"; bias_color = COLOR_BULL; }
    else if(g_state.bc_bias < 0) { bias_text = "BEARISH"; bias_color = COLOR_BEAR; }
    else { bias_text = "NEUTRAL"; bias_color = COLOR_NEUTRAL; }
    
    string card2_rows[] = {
        "HTF Bias: " + bias_text,
        "ZE Strength: " + StringFormat("%.1f / 10", g_state.ze_strength),
        "SMC Conf: " + StringFormat("%.1f / 10", g_state.smc_confidence),
        "Spread: " + (string)g_state.spread + " pts"
    };
    color card2_colors[] = { bias_color, COLOR_WHITE, COLOR_WHITE, (g_state.spread > 20 ? COLOR_AMBER : COLOR_WHITE) };
    DrawCard(x, y, PANE_WIDTH, "MARKET CONTEXT", card2_rows, card2_colors);

    // --- Card 3: System Status ---
    string last_update_str = (g_state.last_update_time == 0) ? "..." : TimeToString(g_state.last_update_time, TIME_SECONDS);
    string card3_rows[] = {
        "Session: " + g_state.session_status,
        "Last Update: " + last_update_str
    };
    color card3_colors[] = { COLOR_WHITE, COLOR_WHITE };
    DrawCard(x, y, PANE_WIDTH, "SYSTEM STATUS", card3_rows, card3_colors);
    
    // --- Draw Background for all cards ---
    DrawRect("Background", x, y_start, PANE_WIDTH, y - y_start, COLOR_BG);
}

//+------------------------------------------------------------------+
//| Draws a card with a title and rows of text                       |
//+------------------------------------------------------------------+
void DrawCard(int x, int &y, int width, string title, const string &rows[], const color &row_colors[])
{
    int x_padding = 10;
    int y_padding = 10;
    int line_height = 20;

    DrawLabel("CardTitle_" + title, title, x + x_padding, y, FONT_SIZE_HEADER, COLOR_HEADER, "Calibri");
    y += line_height + 5;
    
    for(int i = 0; i < ArraySize(rows); i++)
    {
        string label_text = StringSubstr(rows[i], 0, StringFind(rows[i], ":") + 1);
        string value_text = StringSubstr(rows[i], StringFind(rows[i], ":") + 2);
        
        DrawLabel("CardRow_Label_" + title + (string)i, label_text, x + x_padding, y, FONT_SIZE_NORMAL, COLOR_LABEL, "Calibri");
        DrawLabel("CardRow_Value_" + title + (string)i, value_text, x + 120, y, FONT_SIZE_NORMAL, row_colors[i], "Calibri Bold");
        y += line_height;
    }
    
    y += y_padding;
    DrawLabel("CardSeparator_" + title, "------------------------------------", x + x_padding, y - 15, FONT_SIZE_NORMAL, COLOR_SEPARATOR);
}


//+------------------------------------------------------------------+
//| Creates or updates a text label on the chart                     |
//+------------------------------------------------------------------+
void DrawLabel(string name, string text, int x, int y, int size, color clr, string font="Arial", ENUM_ANCHOR_POINT anchor=ANCHOR_LEFT)
{
    string obj_name = PANE_PREFIX + name;
    if(ObjectFind(0, obj_name) < 0)
    {
        ObjectCreate(0, obj_name, OBJ_LABEL, 0, 0, 0);
        ObjectSetInteger(0, obj_name, OBJPROP_XDISTANCE, x);
        ObjectSetInteger(0, obj_name, OBJPROP_YDISTANCE, y);
        ObjectSetInteger(0, obj_name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
        ObjectSetString(0, obj_name, OBJPROP_FONT, font);
        ObjectSetInteger(0, obj_name, OBJPROP_ANCHOR, anchor);
        ObjectSetInteger(0, obj_name, OBJPROP_BACK, false);
    }
    ObjectSetString(0, obj_name, OBJPROP_TEXT, text);
    ObjectSetInteger(0, obj_name, OBJPROP_FONTSIZE, size);
    ObjectSetInteger(0, obj_name, OBJPROP_COLOR, clr);
}

//+------------------------------------------------------------------+
//| Creates or updates a rectangle label on the chart                |
//+------------------------------------------------------------------+
void DrawRect(string name, int x, int y, int w, int h, color bg_color)
{
    string obj_name = PANE_PREFIX + name;
    if(ObjectFind(0, obj_name) < 0)
    {
        ObjectCreate(0, obj_name, OBJ_RECTANGLE_LABEL, 0, 0, 0);
        ObjectSetInteger(0, obj_name, OBJPROP_XDISTANCE, x);
        ObjectSetInteger(0, obj_name, OBJPROP_YDISTANCE, y);
        ObjectSetInteger(0, obj_name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
        ObjectSetInteger(0, obj_name, OBJPROP_BACK, true);
        ObjectSetInteger(0, obj_name, OBJPROP_BORDER_TYPE, BORDER_FLAT);
    }
    ObjectSetInteger(0, obj_name, OBJPROP_XSIZE, w);
    ObjectSetInteger(0, obj_name, OBJPROP_YSIZE, h);
    ObjectSetInteger(0, obj_name, OBJPROP_BGCOLOR, bg_color);
    ObjectSetInteger(0, obj_name, OBJPROP_COLOR, bg_color);
}

//+------------------------------------------------------------------+
//| Determines the current trading session status                    |
//+------------------------------------------------------------------+
string GetSessionStatus()
{
   MqlDateTime dt;
   TimeCurrent(dt);
   int hour = dt.hour;
   // Using server time
   if(hour >= 1 && hour < 9) return "Asian";
   if(hour >= 9 && hour < 17) return "London";
   if(hour >= 14 && hour < 22) return "New York";
   if(hour >= 9 && hour < 12) return "London/Asian Overlap";
   if(hour >= 14 && hour < 17) return "London/NY Overlap";
   return "Inter-Session";
}
