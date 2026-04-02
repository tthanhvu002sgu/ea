//--- indicator settings
#property indicator_chart_window
#property indicator_buffers 0
#property indicator_plots   0

//+------------------------------------------------------------------+
//|                                     Market Structure MTF.mq5     |
//|                                              Antigravity AI      |
//+------------------------------------------------------------------+
#property copyright "Antigravity AI"
#property link      ""
#property version   "1.00"
#property description "Market Structure Dashboard with H1, H4, D1 MTF support"

//====================================================================
// ENUMS & CONSTANTS
//====================================================================
enum ENUM_LINE_STYLE_CUSTOM
  {
   STYLE_SOLID_  = 0, // Solid
   STYLE_DASH_   = 1, // Dashed
   STYLE_DOT_    = 2  // Dotted
  };

enum ENUM_DASHBOARD_POS
  {
   POS_TOP_LEFT     = 0,
   POS_TOP_CENTER   = 1,
   POS_TOP_RIGHT    = 2,
   POS_MIDDLE_LEFT  = 3,
   POS_MIDDLE_CENTER= 4,
   POS_MIDDLE_RIGHT = 5,
   POS_BOTTOM_LEFT  = 6,
   POS_BOTTOM_CENTER= 7,
   POS_BOTTOM_RIGHT = 8
  };

enum ENUM_DASHBOARD_THEME
  {
   THEME_DARK  = 0, // Dark Mode
   THEME_LIGHT = 1  // Light Mode
  };

// Colors (Defaults)
#define COLOR_GRAY         clrGray
#define COLOR_ORANGE       C'249,115,22'
#define COLOR_YELLOW       C'251,191,36'
#define COLOR_BULL         C'8,153,129'
#define COLOR_BEAR         C'242,54,69'
#define COLOR_NEUT         C'184,184,184'

#define COLOR_SESS_ASIAN   C'59,130,246'
#define COLOR_SESS_LONDON  C'34,197,94'
#define COLOR_SESS_NY      C'249,115,22'

#define BG_DARK_DARK       C'30,30,30'
#define BG_DARK_LIGHT      C'245,245,245'
#define BG_HEADER_DARK     C'30,30,40'
#define BG_HEADER_LIGHT    C'230,230,240'
#define TEXT_DARK          clrWhite
#define TEXT_LIGHT         C'30,30,30'

//====================================================================
// INPUTS
//====================================================================
sinput string  gSettings           = "--- Settings ---";
input int      InpEmaLength        = 9;              // EMA Length
input int      InpSwingLength      = 5;              // Swing Length
sinput string  gDashboard          = "--- Dashboard & Colors ---";
input bool     InpShowDashboard    = true;           // Show Dashboard
input ENUM_DASHBOARD_POS   InpDashPos    = POS_TOP_RIGHT; // Dashboard Position
input ENUM_DASHBOARD_THEME InpDashTheme  = THEME_DARK;    // Dashboard Theme
input color    InpBullColor        = COLOR_BULL;     // Bull Color
input color    InpBearColor        = COLOR_BEAR;     // Bear Color
input color    InpNeutColor        = COLOR_NEUT;     // Neutral Color

sinput string  gTfH1               = "--- H1 Dashboard ---";
input bool     InpUseH1            = true;           // Enable H1
input int      InpH1Weight         = 1;              // H1 Weight

sinput string  gTfH4               = "--- H4 Dashboard ---";
input bool     InpUseH4            = true;           // Enable H4
input int      InpH4Weight         = 2;              // H4 Weight

sinput string  gTfD1               = "--- D1 Dashboard ---";
input bool     InpUseD1            = true;           // Enable D1
input int      InpD1Weight         = 3;              // D1 Weight

sinput string  gVisuals            = "--- Visual Overlays (Current TF) ---";
input bool     InpShowOB           = true;           // Show OBs
input int      InpObLookback       = 6;              // Max OBs
input bool     InpShowFVG          = true;           // Show FVGs
input int      InpFvgLookback      = 6;              // Max FVGs
input bool     InpShowSwingLabels  = true;           // Show Swing Labels
input bool     InpShowSwingLines   = true;           // Show Swing Lines
input bool     InpShowEMA          = false;          // Show EMA
input ENUM_LINE_STYLE_CUSTOM InpSwingLineStyle = STYLE_DASH_; // Swing Line Style

//====================================================================
// DATA STRUCTURES
//====================================================================
struct ZoneBlock
  {
   int      dir;      // 1 = Bull, -1 = Bear
   double   top;
   double   bottom;
   datetime time;
   bool     isActive;
  };

struct PivotData
  {
   double   lastPH;
   datetime lastPHTime;
   double   lastPL;
   datetime lastPLTime;
  };

struct SwingData
  {
   double   swingH;
   double   swingL;
   double   prevH;
   double   prevL;
   datetime lastHTime;
   datetime lastLTime;
   bool     newH;
   bool     newL;
   bool     bearBreak; // swing L broken
   bool     bullBreak; // swing H broken
   string   struct1;   // HH, HL, LH, LL
   string   struct2;
   string   struct3;
   int      structBias; // 1 = Bullish, -1 = Bearish, 0 = Neutral
  };

struct TfState
  {
   ENUM_TIMEFRAMES timeframe;
   string          tfName;
   bool            enabled;
   int             weight;
   
   // Moving Average
   int             emaHandle;
   double          emaDist;
   int             trendDir; // 1 = Bull, -1 = Bear
   
   // Pivots & Structures
   PivotData       pivot;
   SwingData       swing;
   
   // Arrays
   ZoneBlock       obs[];
   ZoneBlock       fvgs[];
   
   // Dashboard results
   string          obStr;
   string          fvgStr;
   color           obColor;
   color           fvgColor;
   
   string          swingStr;
   color           swingColor;
   
   string          structStr;
   color           structColor;
   
   string          emaStr;
   color           emaColor;
   
   int             biasScore; // Used for context
  };

TfState tf[4]; // 0=Current, 1=H1, 2=H4, 3=D1

color bgColor, headerColor, rowColor, textColor;
string prefix = "MSD_";
//====================================================================
// INITIALIZATION
//====================================================================
int OnInit()
  {
   // Set UI Colors
   if(InpDashTheme == THEME_DARK)
     {
      bgColor     = BG_DARK_DARK;
      headerColor = BG_HEADER_DARK;
      rowColor    = C'26,35,50';
      textColor   = TEXT_DARK;
     }
   else
     {
      bgColor     = BG_DARK_LIGHT;
      headerColor = BG_HEADER_LIGHT;
      rowColor    = C'232,237,245';
      textColor   = TEXT_LIGHT;
     }
     
   // Init Timeframes
   InitTfState(0, PERIOD_CURRENT, "CURRENT", true, 0);
   InitTfState(1, PERIOD_H1, "1H", InpUseH1, InpH1Weight);
   InitTfState(2, PERIOD_H4, "4H", InpUseH4, InpH4Weight);
   InitTfState(3, PERIOD_D1, "1D", InpUseD1, InpD1Weight);

   EventSetTimer(1); // Timer for dashboard drawing efficiency

   Comment(""); // Clear previous lingering table if any
   return(INIT_SUCCEEDED);
  }

void InitTfState(int idx, ENUM_TIMEFRAMES timeframe, string name, bool enabled, int weight)
  {
   tf[idx].timeframe  = timeframe;
   tf[idx].tfName     = name;
   tf[idx].enabled    = enabled;
   tf[idx].weight     = weight;
   
   if(enabled)
     {
      tf[idx].emaHandle = iMA(_Symbol, timeframe, InpEmaLength, 0, MODE_EMA, PRICE_CLOSE);
      if(tf[idx].emaHandle == INVALID_HANDLE) Print("Failed to init EMA handle for ", name);
     }
     
   tf[idx].swing.struct1 = "--";
   tf[idx].swing.struct2 = "--";
   tf[idx].swing.struct3 = "--";
   
   ArrayResize(tf[idx].obs, 0, 100);
   ArrayResize(tf[idx].fvgs, 0, 100);
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   ObjectsDeleteAll(0, prefix);
   Comment("");
   for(int i=0; i<4; i++)
     {
      if(tf[i].emaHandle != INVALID_HANDLE) IndicatorRelease(tf[i].emaHandle);
     }
  }

//====================================================================
// ON CALCULATE / ON TIMER
//====================================================================
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
   // Only process when new bars form (simplification for indicators that do MTF HTF logic)
   // We process TF0 (Current) first, then TF1, TF2, TF3 if a new bar formed on those TFs
   static datetime lastTime[4] = {0,0,0,0};
   
   ArraySetAsSeries(time, true);
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   ArraySetAsSeries(close, true);

   // Process each TF
   for(int i=0; i<4; i++)
     {
      if(!tf[i].enabled) continue;
      
      datetime currBarTime = iTime(_Symbol, tf[i].timeframe, 0);
      if(currBarTime != lastTime[i])
        {
         // Process historical bars if this is the first run, else just the newest closed bars
         int barsToProcess = (lastTime[i] == 0) ? 1000 : iBarShift(_Symbol, tf[i].timeframe, lastTime[i]);
         if(barsToProcess > 1000) barsToProcess = 1000;
         if(barsToProcess <= 0 && lastTime[i] != 0) continue; // Nothing to do
         
         double tfHigh[], tfLow[], tfClose[], tfOpen[];
         int requiredBars = barsToProcess + InpSwingLength * 2 + 10;
         if(CopyHigh(_Symbol, tf[i].timeframe, 1, requiredBars, tfHigh) <= 0) continue;
         if(CopyLow(_Symbol, tf[i].timeframe, 1, requiredBars, tfLow) <= 0) continue;
         if(CopyClose(_Symbol, tf[i].timeframe, 1, requiredBars, tfClose) <= 0) continue;
         if(CopyOpen(_Symbol, tf[i].timeframe, 1, requiredBars, tfOpen) <= 0) continue;
         datetime tfTime[];
         if(CopyTime(_Symbol, tf[i].timeframe, 1, requiredBars, tfTime) <= 0) continue;
         
         ArraySetAsSeries(tfHigh, true);
         ArraySetAsSeries(tfLow, true);
         ArraySetAsSeries(tfClose, true);
         ArraySetAsSeries(tfOpen, true);
         ArraySetAsSeries(tfTime, true);

         // We iterate backwards from oldest to newest to build history
         for(int b = barsToProcess-1; b >= 0; b--)
           {
            ProcessSwingAndStructure(tf[i], b, tfHigh, tfLow, tfClose, tfTime);
            ProcessFVGs(tf[i], b, tfHigh, tfLow, tfClose, tfOpen, tfTime);
            ProcessOBs(tf[i], b, tfHigh, tfLow, tfClose, tfTime);
            MitigateZones(tf[i], tfClose[b], tfHigh[b], tfLow[b]);
           }
           
         lastTime[i] = currBarTime;
        }
        
      // Real-time update for EMA and current nearest zones (dynamic on tick)
      UpdateRealtimeData(tf[i]);
     }
     
   // Draw Visuals (Only on TF0)
   DrawVisuals(tf[0]);
   
   return(rates_total);
  }

void OnTimer()
  {
   DrawDashboard();
  }

//====================================================================
// CORE LOGIC COMPUTATION
//====================================================================
void ProcessSwingAndStructure(TfState &s, int shift, const double &h[], const double &l[], const double &c[], const datetime &t[])
  {
   s.swing.newH = false;
   s.swing.newL = false;

   // Pivot High
   bool isPH = true;
   int phIndex = shift + InpSwingLength;
   for(int j=1; j<=InpSwingLength; j++)
     {
      if(h[phIndex] <= h[phIndex-j] || h[phIndex] <= h[phIndex+j]) { isPH = false; break; }
     }
   
   if(isPH)
     {
      s.swing.prevH = s.swing.swingH;
      s.swing.swingH = h[phIndex];
      s.swing.lastHTime = t[phIndex];
      s.swing.newH = true;
      s.swing.bullBreak = false; // Reset
      
      s.pivot.lastPH = h[phIndex];
      s.pivot.lastPHTime = t[phIndex];
      
      // Structure logic
      if(s.swing.prevH != 0)
        {
         int highType = (s.swing.swingH > s.swing.prevH) ? 1 : -1;
         s.swing.struct3 = s.swing.struct2;
         s.swing.struct2 = s.swing.struct1;
         s.swing.struct1 = (highType > 0) ? "HH" : "LH";
        }
     }

   // Pivot Low
   bool isPL = true;
   int plIndex = shift + InpSwingLength;
   for(int j=1; j<=InpSwingLength; j++)
     {
      if(l[plIndex] >= l[plIndex-j] || l[plIndex] >= l[plIndex+j]) { isPL = false; break; }
     }
     
   if(isPL)
     {
      s.swing.prevL = s.swing.swingL;
      s.swing.swingL = l[plIndex];
      s.swing.lastLTime = t[plIndex];
      s.swing.newL = true;
      s.swing.bearBreak = false; // Reset
      
      s.pivot.lastPL = l[plIndex];
      s.pivot.lastPLTime = t[plIndex];
      
      // Structure logic
      if(s.swing.prevL != 0)
        {
         int lowType = (s.swing.swingL > s.swing.prevL) ? 1 : -1;
         s.swing.struct3 = s.swing.struct2;
         s.swing.struct2 = s.swing.struct1;
         s.swing.struct1 = (lowType > 0) ? "HL" : "LL";
        }
     }
     
   // Check Breaks
   if(c[shift] < s.swing.swingL && s.swing.swingL != 0) s.swing.bearBreak = true;
   if(c[shift] > s.swing.swingH && s.swing.swingH != 0) s.swing.bullBreak = true;
   
   // Realtime Structure Bias
   int rtHighType = 0, rtLowType = 0;
   if(s.swing.struct1 == "HH") rtHighType = 1; else if(s.swing.struct1 == "LH") rtHighType = -1;
   if(s.swing.struct1 == "HL") rtLowType = 1; else if(s.swing.struct1 == "LL") rtLowType = -1;
   
   if(s.swing.bearBreak) rtLowType = -1; // Force Bear structure if Low broken
   if(s.swing.bullBreak) rtHighType = 1; // Force Bull structure if High broken
   
   s.swing.structBias = 0;
   if(rtHighType == 1 && rtLowType == 1) s.swing.structBias = 1;
   else if(rtHighType == -1 && rtLowType == -1) s.swing.structBias = -1;
  }

void ProcessFVGs(TfState &s, int shift, const double &h[], const double &l[], const double &c[], const double &o[], const datetime &t[])
  {
   if(shift+3 >= ArraySize(h)) return;
   
   bool green2 = c[shift+2] > o[shift+2] || c[shift+2] > c[shift+3];
   bool red2   = c[shift+2] < o[shift+2] || c[shift+2] < c[shift+3];
   
   // Bull FVG
   if(l[shift+1] > h[shift+3] && green2 && l[shift+1] < h[shift+2] && l[shift+2] < h[shift+3])
     {
      ZoneBlock z;
      z.dir = 1;
      z.top = l[shift+1];
      z.bottom = h[shift+3];
      z.time = t[shift+3];
      z.isActive = true;
      AddZone(s.fvgs, z, InpFvgLookback);
     }
     
   // Bear FVG
   if(h[shift+1] < l[shift+3] && red2 && h[shift+1] > l[shift+2] && h[shift+2] > l[shift+3])
     {
      ZoneBlock z;
      z.dir = -1;
      z.top = l[shift+3];
      z.bottom = h[shift+1];
      z.time = t[shift+3];
      z.isActive = true;
      AddZone(s.fvgs, z, InpFvgLookback);
     }
  }

void ProcessOBs(TfState &s, int shift, const double &h[], const double &l[], const double &c[], const datetime &t[])
  {
   // Basic Break of Structure Detection for OBs
   bool brokeBull = false;
   bool brokeBear = false;
   
   if(s.pivot.lastPH != 0 && c[shift] > s.pivot.lastPH && c[shift+1] <= s.pivot.lastPH)
     {
      brokeBull = true;
      s.pivot.lastPH = 0; // consumed
     }
   if(s.pivot.lastPL != 0 && c[shift] < s.pivot.lastPL && c[shift+1] >= s.pivot.lastPL)
     {
      brokeBear = true;
      s.pivot.lastPL = 0; // consumed
     }
     
   if(brokeBull)
     {
      // Find lowest candle in recent history (simplified)
      int back = 6;
      double lowP = 100000;
      double topP = 0;
      datetime timeP = 0;
      for(int k=0; k<back && (shift+k) < ArraySize(l); k++)
        {
         if(l[shift+k] < lowP)
           {
            lowP = l[shift+k];
            topP = h[shift+k];
            timeP = t[shift+k];
           }
        }
      ZoneBlock z; z.dir = 1; z.top = topP; z.bottom = lowP; z.time = timeP; z.isActive=true;
      AddZone(s.obs, z, InpObLookback);
     }
     
   if(brokeBear)
     {
      // Find highest candle
      int back = 6;
      double highP = 0;
      double botP = 100000;
      datetime timeP = 0;
      for(int k=0; k<back && (shift+k) < ArraySize(h); k++)
        {
         if(h[shift+k] > highP)
           {
            highP = h[shift+k];
            botP = l[shift+k];
            timeP = t[shift+k];
           }
        }
      ZoneBlock z; z.dir = -1; z.top = highP; z.bottom = botP; z.time = timeP; z.isActive=true;
      AddZone(s.obs, z, InpObLookback);
     }
  }

void AddZone(ZoneBlock &arr[], const ZoneBlock &zone, int maxSize)
  {
   int size = ArraySize(arr);
   
   // Don't add if overlaps same direction
   for(int i=0; i<size; i++)
     {
      if(arr[i].isActive && arr[i].dir == zone.dir && zone.top >= arr[i].bottom && zone.bottom <= arr[i].top)
         return; // overlaps
     }
     
   ArrayResize(arr, size + 1);
   for(int i=size; i>0; i--) arr[i] = arr[i-1]; // unshift
   arr[0] = zone;
   
   if(ArraySize(arr) > maxSize) ArrayResize(arr, maxSize);
  }

void MitigateZones(TfState &s, double closePrice, double hPrice, double lPrice)
  {
   // Mitigate OBs
   for(int i=0; i<ArraySize(s.obs); i++)
     {
      if(!s.obs[i].isActive) continue;
      if(s.obs[i].dir == 1 && closePrice < s.obs[i].bottom) s.obs[i].isActive = false;
      else if(s.obs[i].dir == -1 && closePrice > s.obs[i].top) s.obs[i].isActive = false;
     }
     
   // Mitigate FVGs
   for(int i=0; i<ArraySize(s.fvgs); i++)
     {
      if(!s.fvgs[i].isActive) continue;
      if(s.fvgs[i].dir == 1 && lPrice < s.fvgs[i].bottom) s.fvgs[i].isActive = false;
      else if(s.fvgs[i].dir == -1 && hPrice > s.fvgs[i].top) s.fvgs[i].isActive = false;
     }
  }

void UpdateRealtimeData(TfState &s)
  {
   if(!s.enabled) return;
   
   double curClose = iClose(_Symbol, PERIOD_CURRENT, 0); // Always use TF0 current close for realtime distance
   
   // EMA calculation
   double emaVal[1];
   if(CopyBuffer(s.emaHandle, 0, 0, 1, emaVal) > 0)
     {
      s.emaDist = ((curClose - emaVal[0]) / curClose) * 100.0;
      s.trendDir = (curClose > emaVal[0]) ? 1 : -1;
     }
     
   // Find nearest unmitigated OB
   int nObDir = 0; double nObDist = 100000;
   FindNearest(s.obs, curClose, nObDir, nObDist);
   FormatZoneStr("OB", nObDir, nObDist, s.obStr, s.obColor);
   
   // Find nearest unmitigated FVG
   int nFvgDir = 0; double nFvgDist = 100000;
   FindNearest(s.fvgs, curClose, nFvgDir, nFvgDist);
   FormatZoneStr("FVG", nFvgDir, nFvgDist, s.fvgStr, s.fvgColor);
   
   // Format Structure
   string arrow = (s.swing.structBias == 1) ? " ^" : (s.swing.structBias == -1) ? " v" : " -";
   s.structStr = s.swing.struct3 + "-" + s.swing.struct2 + "-" + s.swing.struct1 + arrow;
   s.structColor = (s.swing.structBias == 1) ? InpBullColor : (s.swing.structBias == -1) ? InpBearColor : InpNeutColor;
   
   // Format Swing State
   double sRange = MathMax(s.swing.swingH - s.swing.swingL, _Point);
   double pct = ((curClose - s.swing.swingL) / sRange) * 100.0;
   
   if(s.swing.bullBreak) { s.swingStr = "BRK HIGH ^"; s.swingColor = InpBullColor; }
   else if(s.swing.bearBreak) { s.swingStr = "BRK LOW v"; s.swingColor = InpBearColor; }
   else if(pct > 70) { s.swingStr = "NEAR HIGH ^"; s.swingColor = InpBullColor; }
   else if(pct < 30) { s.swingStr = "NEAR LOW v"; s.swingColor = InpBearColor; }
   else { s.swingStr = "MID RANGE -"; s.swingColor = InpNeutColor; }
   
   // Format EMA
   string eArrow = (s.trendDir > 0) ? " ^" : " v";
   s.emaStr = DoubleToString(MathAbs(s.emaDist), 2) + "%" + eArrow;
   s.emaColor = (s.trendDir > 0) ? InpBullColor : InpBearColor;
  }

void FindNearest(ZoneBlock &arr[], double curClose, int &nearestDir, double &nearestDist)
  {
   double nearestBullDist = 100000;
   double nearestBearDist = 100000;
   
   for(int i=0; i<ArraySize(arr); i++)
     {
      if(!arr[i].isActive) continue;
      
      if(arr[i].dir == 1)
        {
         double dist = arr[i].top - curClose;
         if(MathAbs(dist) < MathAbs(nearestBullDist)) nearestBullDist = dist;
        }
      else
        {
         double dist = arr[i].bottom - curClose;
         if(MathAbs(dist) < MathAbs(nearestBearDist)) nearestBearDist = dist;
        }
     }
     
   if(MathAbs(nearestBullDist) < MathAbs(nearestBearDist) && MathAbs(nearestBullDist) < 100000)
     {
      nearestDir = 1; nearestDist = nearestBullDist;
     }
   else if(MathAbs(nearestBearDist) < 100000)
     {
      nearestDir = -1; nearestDist = nearestBearDist;
     }
  }

void FormatZoneStr(string type, int dir, double dist, string &outStr, color &outColor)
  {
   if(dir == 0)
     {
      outStr = "NONE";
      outColor = InpNeutColor;
     }
   else if(dir == 1)
     {
      if(dist >= 0) outStr = "IN BULL " + type;
      else outStr = "BULL " + type + " (" + DoubleToString(MathAbs(dist/_Point)*10, 1) + "pip)";
      outColor = InpBullColor;
     }
   else
     {
      if(dist <= 0) outStr = "IN BEAR " + type;
      else outStr = "BEAR " + type + " (" + DoubleToString(MathAbs(dist/_Point)*10, 1) + "pip)";
      outColor = InpBearColor;
     }
  }

//====================================================================
// VISUAL DRAWING (Objects on TF0)
//====================================================================
void DrawVisuals(TfState &s)
  {
   ObjectsDeleteAll(0, prefix + "VO_");
   
   // Draw OBs
   if(InpShowOB)
     {
      int count = 0;
      for(int i=0; i<ArraySize(s.obs); i++)
        {
         if(!s.obs[i].isActive) continue;
         if(count >= InpObLookback) break;
         
         string name = prefix + "VO_OB_" + IntegerToString(i);
         color clr = (s.obs[i].dir == 1) ? InpBullColor : InpBearColor;
         DrawRect(name, s.obs[i].time, s.obs[i].top, TimeCurrent() + PeriodSeconds()*20, s.obs[i].bottom, clr, false);
         count++;
        }
     }
     
   // Draw FVGs
   if(InpShowFVG)
     {
      int count = 0;
      for(int i=0; i<ArraySize(s.fvgs); i++)
        {
         if(!s.fvgs[i].isActive) continue;
         if(count >= InpFvgLookback) break;
         
         string name = prefix + "VO_FVG_" + IntegerToString(i);
         color clr = (s.fvgs[i].dir == 1) ? InpBullColor : InpBearColor;
         DrawRect(name, s.fvgs[i].time, s.fvgs[i].top, TimeCurrent() + PeriodSeconds()*20, s.fvgs[i].bottom, clr, true);
         count++;
        }
     }
  }

void DrawRect(string name, datetime t1, double p1, datetime t2, double p2, color bg, bool borderOnly)
  {
   ObjectCreate(0, name, OBJ_RECTANGLE, 0, t1, p1, t2, p2);
   ObjectSetInteger(0, name, OBJPROP_COLOR, bg);
   ObjectSetInteger(0, name, OBJPROP_BACK, !borderOnly);
   if(borderOnly) ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DASH);
  }

void DrawLine(string name, datetime t1, double p1, datetime t2, color clr)
  {
   ObjectCreate(0, name, OBJ_TREND, 0, t1, p1, t2, p1);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, name, OBJPROP_STYLE, (ENUM_LINE_STYLE)InpSwingLineStyle);
  }

//====================================================================
// DASHBOARD UI (Graphical Labels)
//====================================================================
void CreateLabel(string name, int x, int y, string text, color clr, int fontsize, string fontname="Trebuchet MS", ENUM_ANCHOR_POINT anchor=ANCHOR_LEFT_UPPER, ENUM_BASE_CORNER corner=CORNER_RIGHT_UPPER)
  {
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
      
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_CORNER, corner);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontsize);
   ObjectSetString(0, name, OBJPROP_FONT, fontname);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, anchor);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
  }

void DrawDashboard()
  {}
   
  

string GetSessionStr()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int hr = dt.hour;
   
   if(hr >= 19 || hr < 3) return "ASIAN";
   if(hr >= 8 && hr < 17) return "NEW YORK";
   if(hr >= 3 && hr < 8) return "LONDON";
   return "OFF HOURS";
  }
//+------------------------------------------------------------------+
