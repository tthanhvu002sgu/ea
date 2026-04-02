//+------------------------------------------------------------------+
//|                                         Anti-Overtrading.mq5     |
//|                                              SmartManager Pro    |
//+------------------------------------------------------------------+
#property copyright "SmartManager Pro"
#property version   "1.00"
#property description "Anti-Overtrading Visual Shield Indicator"
#property strict

#property indicator_chart_window
#property indicator_plots 0

//====================================================================
// INPUTS
//====================================================================
input group "=== Anti-Overtrading ==="
input color    InpOnColor     = C'220,50,50';     // Button Active Color
input color    InpOffColor    = C'60,60,65';      // Button Inactive Color
input int      InpBtnX        = 20;               // Toggle Button X
input int      InpBtnY        = 120;              // Toggle Button Y (from Top Left)
input int      InpShieldWidth = 300;              // Shield Width (to cover One Click Trade)
input int      InpShieldHeight= 140;              // Shield Height (to cover One Click Trade)

//====================================================================
// GLOBALS
//====================================================================
string Prefix = "AOT_";

// Object names
string ObjBtnToggle  = Prefix + "Toggle";
string ObjLblStatus  = Prefix + "Status";
string ObjLblInfo    = Prefix + "Info";

// Shield Objects (Top Left)
string ObjShieldBg   = Prefix + "ShieldBg";
string ObjShieldTxt  = Prefix + "ShieldTxt";

// Popup objects
string ObjPopBg      = Prefix + "PopBg";
string ObjPopTitle   = Prefix + "PopTitle";
string ObjPopMsg     = Prefix + "PopMsg";
string ObjPopBtnYes  = Prefix + "PopYes";
string ObjPopBtnNo   = Prefix + "PopNo";
string ObjPopCounter = Prefix + "PopCnt";

// State
bool   g_ShieldActive = false;
int    g_PopupStage   = 0;        // 0=none, 1/2/3=popup stage
bool   g_ShowPopup    = false;
datetime g_ActivationDate = 0;    // Date when shield was activated

// Popup messages
string g_PopupTitles[3];
string g_PopupMsgs[3];

//====================================================================
// INITIALIZATION
//====================================================================
int OnInit()
{
   // Setup warning messages (escalating intensity)
   g_PopupTitles[0] = "WAIT - ARE YOU SURE?";
   g_PopupTitles[1] = "THINK AGAIN!";
   g_PopupTitles[2] = "LAST CHANCE TO STAY SAFE!";
   
   g_PopupMsgs[0] = "Turning off the shield means you can overtrade again.";
   g_PopupMsgs[1] = "Most losses come from revenge trading. Take a breath.";
   g_PopupMsgs[2] = "If you turn this off now, you are choosing emotion over discipline.";
   
   // Restore state
   string gvShield = "AOT_Shield_" + _Symbol;
   string gvDate   = "AOT_Date_" + _Symbol;
   
   if(GlobalVariableCheck(gvShield))
   {
      g_ShieldActive = (GlobalVariableGet(gvShield) > 0);
      g_ActivationDate = (datetime)GlobalVariableGet(gvDate);
      
      // Auto-reset if it's a new day
      if(g_ShieldActive && !IsSameDay(g_ActivationDate, TimeCurrent()))
      {
         g_ShieldActive = false;
         SaveState();
      }
   }
   
   CreateGUI();
   UpdateGUI();
   EventSetMillisecondTimer(500);
   
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   ObjectsDeleteAll(0, Prefix);
   ChartRedraw();
}

int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
{
   return(rates_total);
}

//====================================================================
// TIMER
//====================================================================
void OnTimer()
{
   // Auto-reset check (new day)
   if(g_ShieldActive && !IsSameDay(g_ActivationDate, TimeCurrent()))
   {
      g_ShieldActive = false;
      g_PopupStage = 0;
      g_ShowPopup = false;
      HidePopup();
      SaveState();
      UpdateGUI();
   }
}

//====================================================================
// CHART EVENTS
//====================================================================
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   if(id != CHARTEVENT_OBJECT_CLICK) return;
   
   // --- TOGGLE BUTTON ---
   if(sparam == ObjBtnToggle)
   {
      ObjectSetInteger(0, ObjBtnToggle, OBJPROP_STATE, false);
      
      if(!g_ShieldActive)
      {
         // Easy ON: Activate immediately
         g_ShieldActive = true;
         g_ActivationDate = TimeCurrent();
         g_PopupStage = 0;
         SaveState();
         UpdateGUI();
      }
      else
      {
         // Hard OFF: Start popup gauntlet
         g_PopupStage = 1;
         g_ShowPopup = true;
         ShowPopup();
      }
      ChartRedraw();
   }
   
   // --- POPUP YES (User insists on turning off) ---
   else if(sparam == ObjPopBtnYes)
   {
      ObjectSetInteger(0, ObjPopBtnYes, OBJPROP_STATE, false);
      
      if(g_PopupStage < 3)
      {
         // Show next warning
         g_PopupStage++;
         ShowPopup();
      }
      else
      {
         // All 3 warnings cleared - finally turn off
         g_ShieldActive = false;
         g_PopupStage = 0;
         g_ShowPopup = false;
         HidePopup();
         SaveState();
         UpdateGUI();
      }
      ChartRedraw();
   }
   
   // --- POPUP NO (User cancels - good decision!) ---
   else if(sparam == ObjPopBtnNo)
   {
      ObjectSetInteger(0, ObjPopBtnNo, OBJPROP_STATE, false);
      g_PopupStage = 0;
      g_ShowPopup = false;
      HidePopup();
      ChartRedraw();
   }
}

//====================================================================
// HELPER FUNCTIONS
//====================================================================
bool IsSameDay(datetime d1, datetime d2)
{
   MqlDateTime t1, t2;
   TimeToStruct(d1, t1);
   TimeToStruct(d2, t2);
   return (t1.year == t2.year && t1.day_of_year == t2.day_of_year);
}

void SaveState()
{
   GlobalVariableSet("AOT_Shield_" + _Symbol, g_ShieldActive ? 1.0 : 0.0);
   GlobalVariableSet("AOT_Date_" + _Symbol, (double)g_ActivationDate);
}

//====================================================================
// GUI: MAIN TOGGLE
//====================================================================
void CreateGUI()
{
   int btnW = 150;
   int btnH = 35;
   
   // Toggle Button
   if(ObjectFind(0, ObjBtnToggle) < 0) ObjectCreate(0, ObjBtnToggle, OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, ObjBtnToggle, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, ObjBtnToggle, OBJPROP_XDISTANCE, InpBtnX);
   ObjectSetInteger(0, ObjBtnToggle, OBJPROP_YDISTANCE, InpBtnY);
   ObjectSetInteger(0, ObjBtnToggle, OBJPROP_XSIZE, btnW);
   ObjectSetInteger(0, ObjBtnToggle, OBJPROP_YSIZE, btnH);
   ObjectSetInteger(0, ObjBtnToggle, OBJPROP_FONTSIZE, 10);
   ObjectSetString(0, ObjBtnToggle, OBJPROP_FONT, "Segoe UI Semibold");
   ObjectSetInteger(0, ObjBtnToggle, OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, ObjBtnToggle, OBJPROP_ZORDER, 20);
   
   // Status Label (below button)
   CreateLabel(ObjLblStatus, InpBtnX + btnW/2, InpBtnY + btnH + 5, "", clrGray, 8, ANCHOR_UPPER);
   
   // Info Label (blocked count)
   CreateLabel(ObjLblInfo, InpBtnX + btnW/2, InpBtnY + btnH + 20, "", clrGray, 7, ANCHOR_UPPER);
}

void UpdateGUI()
{
   if(g_ShieldActive)
   {
      ObjectSetString(0, ObjBtnToggle, OBJPROP_TEXT, "SHIELD ON");
      ObjectSetInteger(0, ObjBtnToggle, OBJPROP_BGCOLOR, InpOnColor);
      ObjectSetString(0, ObjLblStatus, OBJPROP_TEXT, "One-Click PANEL HIDDEN");
      ObjectSetInteger(0, ObjLblStatus, OBJPROP_COLOR, InpOnColor);
      
      string info = "Protection active since " + TimeToString(g_ActivationDate, TIME_MINUTES);
      ObjectSetString(0, ObjLblInfo, OBJPROP_TEXT, info);
      ObjectSetInteger(0, ObjLblInfo, OBJPROP_COLOR, C'180,180,180');
      
      DrawCoverShield(true);
      ChartSetInteger(0, CHART_SHOW_ONE_CLICK, false); // Tắt hiển thị bảng One-Click của MT5
   }
   else
   {
      ObjectSetString(0, ObjBtnToggle, OBJPROP_TEXT, "SHIELD OFF");
      ObjectSetInteger(0, ObjBtnToggle, OBJPROP_BGCOLOR, InpOffColor);
      ObjectSetString(0, ObjLblStatus, OBJPROP_TEXT, "Trading allowed");
      ObjectSetInteger(0, ObjLblStatus, OBJPROP_COLOR, clrGray);
      ObjectSetString(0, ObjLblInfo, OBJPROP_TEXT, "Click to hide One-Click Panel");
      ObjectSetInteger(0, ObjLblInfo, OBJPROP_COLOR, C'120,120,120');
      
      DrawCoverShield(false);
      ChartSetInteger(0, CHART_SHOW_ONE_CLICK, true); // Bật lại bảng One-Click của MT5
   }
   
   // Update popup text if visible
   if(g_ShowPopup) UpdatePopupText();
   
   ChartRedraw();
}

void DrawCoverShield(bool show)
{
   if(show)
   {
      if(ObjectFind(0, ObjShieldBg) < 0) ObjectCreate(0, ObjShieldBg, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, ObjShieldBg, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, ObjShieldBg, OBJPROP_XDISTANCE, -5);
      ObjectSetInteger(0, ObjShieldBg, OBJPROP_YDISTANCE, -5);
      ObjectSetInteger(0, ObjShieldBg, OBJPROP_XSIZE, InpShieldWidth);
      ObjectSetInteger(0, ObjShieldBg, OBJPROP_YSIZE, InpShieldHeight);
      ObjectSetInteger(0, ObjShieldBg, OBJPROP_BGCOLOR, C'20,20,25'); 
      ObjectSetInteger(0, ObjShieldBg, OBJPROP_BACK, false); // Foreground to block clicks
      ObjectSetInteger(0, ObjShieldBg, OBJPROP_ZORDER, 150);
      
      if(ObjectFind(0, ObjShieldTxt) < 0) ObjectCreate(0, ObjShieldTxt, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, ObjShieldTxt, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, ObjShieldTxt, OBJPROP_XDISTANCE, InpShieldWidth/2);
      ObjectSetInteger(0, ObjShieldTxt, OBJPROP_YDISTANCE, InpShieldHeight/2);
      ObjectSetInteger(0, ObjShieldTxt, OBJPROP_ANCHOR, ANCHOR_CENTER);
      ObjectSetString(0, ObjShieldTxt, OBJPROP_TEXT, "SHIELD ACTIVE\nNo Trading");
      ObjectSetInteger(0, ObjShieldTxt, OBJPROP_COLOR, InpOnColor);
      ObjectSetInteger(0, ObjShieldTxt, OBJPROP_FONTSIZE, 12);
      ObjectSetString(0, ObjShieldTxt, OBJPROP_FONT, "Segoe UI Semibold");
      ObjectSetInteger(0, ObjShieldTxt, OBJPROP_ZORDER, 151);
   }
   else
   {
      ObjectDelete(0, ObjShieldBg);
      ObjectDelete(0, ObjShieldTxt);
   }
}

//====================================================================
// GUI: POPUP (3-Stage Warning)
//====================================================================
void ShowPopup()
{
   int cx = (int)ChartGetInteger(0, CHART_WIDTH_IN_PIXELS) / 2;
   int cy = (int)ChartGetInteger(0, CHART_HEIGHT_IN_PIXELS) / 2;
   int w = 420, h = 200;
   int padding = 25;
   
   // Escalating colors (mild -> intense)
   color bgColors[3];
   bgColors[0] = C'255,250,235';  // Warm cream
   bgColors[1] = C'255,240,220';  // Soft orange tint
   bgColors[2] = C'255,230,230';  // Danger red tint
   
   color titleColors[3];
   titleColors[0] = C'200,150,0';   // Amber
   titleColors[1] = C'220,100,0';   // Orange
   titleColors[2] = C'200,30,30';   // Red
   
   int stageIdx = g_PopupStage - 1;
   if(stageIdx < 0) stageIdx = 0;
   if(stageIdx > 2) stageIdx = 2;
   
   // Background
   if(ObjectFind(0, ObjPopBg) < 0) ObjectCreate(0, ObjPopBg, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, ObjPopBg, OBJPROP_XDISTANCE, cx - w/2);
   ObjectSetInteger(0, ObjPopBg, OBJPROP_YDISTANCE, cy - h/2);
   ObjectSetInteger(0, ObjPopBg, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, ObjPopBg, OBJPROP_YSIZE, h);
   ObjectSetInteger(0, ObjPopBg, OBJPROP_BGCOLOR, bgColors[stageIdx]);
   ObjectSetInteger(0, ObjPopBg, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, ObjPopBg, OBJPROP_ZORDER, 200);
   
   // Stage counter (top right)
   if(ObjectFind(0, ObjPopCounter) < 0) ObjectCreate(0, ObjPopCounter, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, ObjPopCounter, OBJPROP_XDISTANCE, cx + w/2 - 15);
   ObjectSetInteger(0, ObjPopCounter, OBJPROP_YDISTANCE, cy - h/2 + 10);
   ObjectSetInteger(0, ObjPopCounter, OBJPROP_ANCHOR, ANCHOR_RIGHT_UPPER);
   ObjectSetString(0, ObjPopCounter, OBJPROP_TEXT, IntegerToString(g_PopupStage) + "/3");
   ObjectSetInteger(0, ObjPopCounter, OBJPROP_COLOR, C'160,160,160');
   ObjectSetInteger(0, ObjPopCounter, OBJPROP_FONTSIZE, 9);
   ObjectSetString(0, ObjPopCounter, OBJPROP_FONT, "Segoe UI");
   ObjectSetInteger(0, ObjPopCounter, OBJPROP_ZORDER, 201);
   
   // Title
   if(ObjectFind(0, ObjPopTitle) < 0) ObjectCreate(0, ObjPopTitle, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, ObjPopTitle, OBJPROP_XDISTANCE, cx);
   ObjectSetInteger(0, ObjPopTitle, OBJPROP_YDISTANCE, cy - 55);
   ObjectSetInteger(0, ObjPopTitle, OBJPROP_ANCHOR, ANCHOR_CENTER);
   ObjectSetString(0, ObjPopTitle, OBJPROP_TEXT, g_PopupTitles[stageIdx]);
   ObjectSetInteger(0, ObjPopTitle, OBJPROP_COLOR, titleColors[stageIdx]);
   ObjectSetInteger(0, ObjPopTitle, OBJPROP_FONTSIZE, 14);
   ObjectSetString(0, ObjPopTitle, OBJPROP_FONT, "Segoe UI Semibold");
   ObjectSetInteger(0, ObjPopTitle, OBJPROP_ZORDER, 201);
   
   // Message
   if(ObjectFind(0, ObjPopMsg) < 0) ObjectCreate(0, ObjPopMsg, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, ObjPopMsg, OBJPROP_XDISTANCE, cx);
   ObjectSetInteger(0, ObjPopMsg, OBJPROP_YDISTANCE, cy - 15);
   ObjectSetInteger(0, ObjPopMsg, OBJPROP_ANCHOR, ANCHOR_CENTER);
   ObjectSetString(0, ObjPopMsg, OBJPROP_TEXT, g_PopupMsgs[stageIdx]);
   ObjectSetInteger(0, ObjPopMsg, OBJPROP_COLOR, C'60,60,60');
   ObjectSetInteger(0, ObjPopMsg, OBJPROP_FONTSIZE, 10);
   ObjectSetString(0, ObjPopMsg, OBJPROP_FONT, "Segoe UI");
   ObjectSetInteger(0, ObjPopMsg, OBJPROP_ZORDER, 201);
   
   // Button labels
   string yesLabel = (g_PopupStage < 3) ? "I INSIST (" + IntegerToString(3 - g_PopupStage) + " left)" : "TURN OFF SHIELD";
   string noLabel  = "KEEP SHIELD ON";
   
   // Btn YES (destructive action - muted style to discourage)
   if(ObjectFind(0, ObjPopBtnYes) < 0) ObjectCreate(0, ObjPopBtnYes, OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, ObjPopBtnYes, OBJPROP_XDISTANCE, cx - w/2 + padding);
   ObjectSetInteger(0, ObjPopBtnYes, OBJPROP_YDISTANCE, cy + 45);
   ObjectSetInteger(0, ObjPopBtnYes, OBJPROP_XSIZE, 170);
   ObjectSetInteger(0, ObjPopBtnYes, OBJPROP_YSIZE, 35);
   ObjectSetString(0, ObjPopBtnYes, OBJPROP_TEXT, yesLabel);
   ObjectSetInteger(0, ObjPopBtnYes, OBJPROP_BGCOLOR, C'200,200,205');   // Muted gray (discourage)
   ObjectSetInteger(0, ObjPopBtnYes, OBJPROP_COLOR, C'100,100,100');     // Dim text
   ObjectSetString(0, ObjPopBtnYes, OBJPROP_FONT, "Segoe UI");
   ObjectSetInteger(0, ObjPopBtnYes, OBJPROP_FONTSIZE, 9);
   ObjectSetInteger(0, ObjPopBtnYes, OBJPROP_ZORDER, 201);
   
   // Btn NO (safe action - prominent style to encourage)
   if(ObjectFind(0, ObjPopBtnNo) < 0) ObjectCreate(0, ObjPopBtnNo, OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, ObjPopBtnNo, OBJPROP_XDISTANCE, cx + w/2 - padding - 170);
   ObjectSetInteger(0, ObjPopBtnNo, OBJPROP_YDISTANCE, cy + 45);
   ObjectSetInteger(0, ObjPopBtnNo, OBJPROP_XSIZE, 170);
   ObjectSetInteger(0, ObjPopBtnNo, OBJPROP_YSIZE, 35);
   ObjectSetString(0, ObjPopBtnNo, OBJPROP_TEXT, noLabel);
   ObjectSetInteger(0, ObjPopBtnNo, OBJPROP_BGCOLOR, C'46,139,87');      // Green (encourage)
   ObjectSetInteger(0, ObjPopBtnNo, OBJPROP_COLOR, clrWhite);
   ObjectSetString(0, ObjPopBtnNo, OBJPROP_FONT, "Segoe UI Semibold");
   ObjectSetInteger(0, ObjPopBtnNo, OBJPROP_FONTSIZE, 10);
   ObjectSetInteger(0, ObjPopBtnNo, OBJPROP_ZORDER, 201);
   
   ChartRedraw();
}

void UpdatePopupText()
{
   int stageIdx = g_PopupStage - 1;
   if(stageIdx < 0 || stageIdx > 2) return;
   
   color titleColors[3];
   titleColors[0] = C'200,150,0';
   titleColors[1] = C'220,100,0';
   titleColors[2] = C'200,30,30';
   
   ObjectSetString(0, ObjPopTitle, OBJPROP_TEXT, g_PopupTitles[stageIdx]);
   ObjectSetInteger(0, ObjPopTitle, OBJPROP_COLOR, titleColors[stageIdx]);
   ObjectSetString(0, ObjPopMsg, OBJPROP_TEXT, g_PopupMsgs[stageIdx]);
   ObjectSetString(0, ObjPopCounter, OBJPROP_TEXT, IntegerToString(g_PopupStage) + "/3");
   
   string yesLabel = (g_PopupStage < 3) ? "I INSIST (" + IntegerToString(3 - g_PopupStage) + " left)" : "TURN OFF SHIELD";
   ObjectSetString(0, ObjPopBtnYes, OBJPROP_TEXT, yesLabel);
}

void HidePopup()
{
   ObjectDelete(0, ObjPopBg);
   ObjectDelete(0, ObjPopTitle);
   ObjectDelete(0, ObjPopMsg);
   ObjectDelete(0, ObjPopBtnYes);
   ObjectDelete(0, ObjPopBtnNo);
   ObjectDelete(0, ObjPopCounter);
   ChartRedraw();
}

//====================================================================
// UTILITY: CreateLabel
//====================================================================
void CreateLabel(string name, int x, int y, string text, color clr, int fontSize, ENUM_ANCHOR_POINT anchor)
{
   if(ObjectFind(0, name) < 0) ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, anchor);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontSize);
   ObjectSetString(0, name, OBJPROP_FONT, "Segoe UI");
   ObjectSetInteger(0, name, OBJPROP_ZORDER, 20);
}
//+------------------------------------------------------------------+
