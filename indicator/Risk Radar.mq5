//+------------------------------------------------------------------+
//|                                                   Risk Radar.mq5 |
//|                                        Risk Assessment Indicator  |
//|  Bảng quy đổi Hệ số k sang Số Sao:                               |
//|  - Bình thường (k ≈ 1): 0 Sao                                    |
//|  - Rủi ro (k = 2): 3 Sao                                         |
//|  - Rủi ro (k ≥ 4): 5 Sao                                         |
//+------------------------------------------------------------------+
#property copyright "Risk Radar Indicator"
#property link      ""
#property version   "3.00"
#property strict
#property indicator_chart_window
#property indicator_buffers 0
#property indicator_plots   0

//+------------------------------------------------------------------+
//| Input Parameters                                                  |
//+------------------------------------------------------------------+
input int   InpPeriod       = 20;    // SMA Period (Average Range)
input bool  InpAlertOn5Star = true;  // Alert on 5-Star Risk

//+------------------------------------------------------------------+
//| Global Variables                                                  |
//+------------------------------------------------------------------+
int    g_period;
string Prefix = "RR_";

//+------------------------------------------------------------------+
//| Calculate Risk Score for a specific timeframe                     |
//+------------------------------------------------------------------+
double CalcRiskScoreTF(ENUM_TIMEFRAMES tf)
{
   double highs[], lows[];
   int needed = g_period + 1;
   if(CopyHigh(Symbol(), tf, 0, needed, highs) < needed) return 0;
   if(CopyLow(Symbol(), tf, 0, needed, lows) < needed) return 0;
   double currentRange = highs[needed - 1] - lows[needed - 1];
   double sum = 0;
   for(int i = 0; i < g_period; i++)
      sum += (highs[needed - 1 - i] - lows[needed - 1 - i]);
   double smaRange = sum / g_period;
   if(smaRange > 0) return currentRange / smaRange;
   return 1.0;
}

//+------------------------------------------------------------------+
//| Get Star Rating from Risk Score                                   |
//+------------------------------------------------------------------+
int GetStarRating(double riskScore)
{
   if(riskScore < 1.5)       return 0;
   else if(riskScore < 2.0)  return 1;
   else if(riskScore < 2.5)  return 2;
   else if(riskScore < 3.0)  return 3;
   else if(riskScore < 4.0)  return 4;
   else                      return 5;
}

//+------------------------------------------------------------------+
//| Get Color by Star Rating                                          |
//+------------------------------------------------------------------+
color GetStarColor(int starRating)
{
   switch(starRating)
   {
      case 0: return clrLimeGreen;
      case 1: return clrYellow;
      case 2: return clrOrange;
      case 3: return clrOrangeRed;
      case 4: return clrRed;
      case 5: return clrCrimson;
      default: return clrGray;
   }
}

//+------------------------------------------------------------------+
//| Get Star String                                                   |
//+------------------------------------------------------------------+
string GetStarString(int starRating)
{
   string stars = "";
   for(int i = 0; i < starRating; i++)  stars += "★";
   for(int i = starRating; i < 5; i++)  stars += "☆";
   return stars;
}

//+------------------------------------------------------------------+
//| Get Risk Level Text                                               |
//+------------------------------------------------------------------+
string GetRiskText(int starRating)
{
   switch(starRating)
   {
      case 0: return "Normal";
      case 1: return "Low";
      case 2: return "Low+";
      case 3: return "Medium";
      case 4: return "High";
      case 5: return "EXTREME ⚠";
      default: return "---";
   }
}

//+------------------------------------------------------------------+
//| Create a label helper                                             |
//+------------------------------------------------------------------+
void CreateLabel(string name, int xDist, int yDist, string text, color clr, int fontSize, ENUM_ANCHOR_POINT anchor)
{
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_RIGHT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, xDist);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, yDist);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, anchor);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontSize);
   ObjectSetString(0, name, OBJPROP_FONT, "Consolas");
}

//+------------------------------------------------------------------+
//| Build / Rebuild full table                                        |
//+------------------------------------------------------------------+
void BuildTable()
{
   // Layout settings (anchored to CORNER_RIGHT_UPPER)
   int tableW = 305;   // total table pixel width
   int padX   = 10;    // right margin
   int startY = 25;
   int rowH   = 20;

   // Column right-edges (from right margin): TF | Score | Stars | Level | k
   int colX[] = {tableW, tableW - 40, tableW - 85, tableW - 200, tableW - 265};
   // colX[c] = XDISTANCE from right edge for each column

   // ---- Header ----
   string hdr[] = {"TF", "x", "Level", "Rating", "Score"};
   color hdrClr = C'160,160,160';
   for(int c = 0; c < 5; c++)
      CreateLabel(Prefix + "H" + IntegerToString(c), padX + tableW - colX[c], startY, hdr[c], hdrClr, 8, ANCHOR_RIGHT_UPPER);

   // ---- Divider ----
   CreateLabel(Prefix + "Sep", padX, startY + rowH - 4,
               "---  ------  ------------------  -----  ------",
               C'60,60,70', 8, ANCHOR_RIGHT_UPPER);

   // ---- Data rows: H1, H4, D1 ----
   string tfLabels[] = {"H1", "H4", "D1"};
   for(int r = 0; r < 3; r++)
   {
      int yPos = startY + rowH * (r + 1) + 6;
      string rowBase = Prefix + "R" + IntegerToString(r);

      // Placeholder text (updated by UpdateTable)
      CreateLabel(rowBase + "_tf",    padX + tableW - colX[0], yPos, tfLabels[r],  clrSilver,   9, ANCHOR_RIGHT_UPPER);
      CreateLabel(rowBase + "_k",     padX + tableW - colX[1], yPos, "---",         clrGray,     9, ANCHOR_RIGHT_UPPER);
      CreateLabel(rowBase + "_level", padX + tableW - colX[2], yPos, "---",         clrGray,     9, ANCHOR_RIGHT_UPPER);
      CreateLabel(rowBase + "_stars", padX + tableW - colX[3], yPos, "---",         clrGray,     9, ANCHOR_RIGHT_UPPER);
      CreateLabel(rowBase + "_score", padX + tableW - colX[4], yPos, "---",         clrGray,     9, ANCHOR_RIGHT_UPPER);
   }
}

//+------------------------------------------------------------------+
//| Update Table Data                                                 |
//+------------------------------------------------------------------+
void UpdateTable()
{
   ENUM_TIMEFRAMES tfs[] = {PERIOD_H1, PERIOD_H4, PERIOD_D1};

   for(int r = 0; r < 3; r++)
   {
      double score = CalcRiskScoreTF(tfs[r]);
      int    stars = GetStarRating(score);
      color  clr   = GetStarColor(stars);

      string rowBase = Prefix + "R" + IntegerToString(r);
      ObjectSetString(0,  rowBase + "_score", OBJPROP_TEXT, DoubleToString(score, 2));
      ObjectSetInteger(0, rowBase + "_score", OBJPROP_COLOR, clr);

      ObjectSetString(0,  rowBase + "_stars", OBJPROP_TEXT, GetStarString(stars));
      ObjectSetInteger(0, rowBase + "_stars", OBJPROP_COLOR, clr);

      ObjectSetString(0,  rowBase + "_level", OBJPROP_TEXT, GetRiskText(stars));
      ObjectSetInteger(0, rowBase + "_level", OBJPROP_COLOR, clr);

      ObjectSetString(0,  rowBase + "_k",     OBJPROP_TEXT, "x" + DoubleToString(score, 1));
      ObjectSetInteger(0, rowBase + "_k",     OBJPROP_COLOR, clr);

      ObjectSetInteger(0, rowBase + "_tf",    OBJPROP_COLOR, (stars >= 4) ? clr : clrSilver);
   }
}

//+------------------------------------------------------------------+
//| OnInit                                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   g_period = (InpPeriod < 2) ? 20 : InpPeriod;
   IndicatorSetString(INDICATOR_SHORTNAME, "Risk Radar");
   BuildTable();
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| OnDeinit                                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   ObjectsDeleteAll(0, Prefix);
   ChartRedraw();
}

//+------------------------------------------------------------------+
//| OnCalculate                                                       |
//+------------------------------------------------------------------+
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
   if(rates_total < g_period) return 0;

   UpdateTable();
   ChartRedraw();

   // Alert on 5-star risk for current chart TF
   if(InpAlertOn5Star)
   {
      double currentRange = high[rates_total - 1] - low[rates_total - 1];
      double sum = 0;
      int needed = MathMin(g_period, rates_total);
      for(int i = 0; i < needed; i++)
         sum += (high[rates_total - 1 - i] - low[rates_total - 1 - i]);
      double smaR = sum / needed;
      double score = (smaR > 0) ? currentRange / smaR : 1.0;

      static datetime lastAlertTime = 0;
      if(GetStarRating(score) >= 5 && time[rates_total-1] != lastAlertTime)
      {
         lastAlertTime = time[rates_total-1];
         Alert("⚠️ RISK RADAR: 5-Star Risk! Score=", DoubleToString(score, 2), " | ", Symbol());
      }
   }

   return(rates_total);
}
//+------------------------------------------------------------------+
