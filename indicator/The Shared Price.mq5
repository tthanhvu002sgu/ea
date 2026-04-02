//+------------------------------------------------------------------+
//|                                           The Shared Price.mq5    |
//|           Tight Range Detection via Body Overlap + Breakout       |
//+------------------------------------------------------------------+
#property copyright   "Vu"
#property version     "1.00"
#property description "Phat hien vung nen chat (Shared Price / Tight Range)"
#property description "Ve hop consolidation + danh dau breakout"

#property indicator_chart_window
#property indicator_buffers 3
#property indicator_plots   2

#property indicator_label1  "Breakout Up"
#property indicator_type1   DRAW_ARROW
#property indicator_color1  clrLime
#property indicator_width1  3

#property indicator_label2  "Breakout Down"
#property indicator_type2   DRAW_ARROW
#property indicator_color2  clrRed
#property indicator_width2  3

//=== INPUTS ===
input group "=== SHARED PRICE ==="
input int    InpMinStreak    = 4;              // So nen toi thieu tao range
input int    InpMaxLookback  = 100;            // Lookback toi da
input int    InpMaxBoxes     = 10;             // So hop toi da

input group "=== HIEN THI ==="
input color  ClrBox          = C'50,100,150';  // Mau hop
input color  ClrBoxActive    = C'150,120,30';  // Mau hop dang active
input color  ClrBreakUp      = clrLime;        // Mui ten breakout tang
input color  ClrBreakDn      = clrRed;         // Mui ten breakout giam

//=== BUFFERS ===
double BufArrowUp[];
double BufArrowDn[];
double BufStreak[];    // internal: streak count

//=== GLOBALS ===
string g_prefix = "SP_";
datetime g_lastBarTime = 0;

struct RangeZone {
   int      bar_start;
   int      bar_end;
   int      breakout_bar;
   double   box_high;
   double   box_low;
   bool     is_active;
   bool     is_bull;
};

RangeZone g_ranges[];
int       g_rangeCount = 0;

//+------------------------------------------------------------------+
int OnInit() {
   SetIndexBuffer(0, BufArrowUp, INDICATOR_DATA);
   SetIndexBuffer(1, BufArrowDn, INDICATOR_DATA);
   SetIndexBuffer(2, BufStreak,  INDICATOR_CALCULATIONS);

   PlotIndexSetInteger(0, PLOT_ARROW, 233);
   PlotIndexSetInteger(1, PLOT_ARROW, 234);
   PlotIndexSetInteger(0, PLOT_LINE_COLOR, ClrBreakUp);
   PlotIndexSetInteger(1, PLOT_LINE_COLOR, ClrBreakDn);
   PlotIndexSetDouble(0, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetDouble(1, PLOT_EMPTY_VALUE, EMPTY_VALUE);

   IndicatorSetString(INDICATOR_SHORTNAME,
      "SharedPrice(" + IntegerToString(InpMinStreak) + ")");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
   ObjectsDeleteAll(0, g_prefix);
}

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
                const int &spread[]) {

   if(rates_total < InpMinStreak + 2) return 0;

   // Detect new bar
   bool newBar = (prev_calculated <= 0 || time[rates_total-1] != g_lastBarTime);
   g_lastBarTime = time[rates_total - 1];

   if(!newBar && prev_calculated > 0) return rates_total;

   // === Full recalc ===
   ArrayInitialize(BufArrowUp, EMPTY_VALUE);
   ArrayInitialize(BufArrowDn, EMPTY_VALUE);
   ArrayInitialize(BufStreak, 0);

   // --- Step 1: Streak per bar ---
   // streak[i] = so nen lien tiep truoc bar i co body chua mid_price cua bar i
   for(int i = 1; i < rates_total; i++) {
      double mid = (open[i] + close[i]) / 2.0;
      int cnt = 0;
      int j_min = MathMax(0, i - InpMaxLookback);
      for(int j = i - 1; j >= j_min; j--) {
         double blo = MathMin(open[j], close[j]);
         double bhi = MathMax(open[j], close[j]);
         // Tolerance cho doji
         if(bhi - blo < _Point) { bhi += _Point; blo -= _Point; }
         if(mid >= blo && mid <= bhi)
            cnt++;
         else
            break;
      }
      BufStreak[i] = (double)cnt;
   }

   // --- Step 2: Group into range zones ---
   ArrayResize(g_ranges, 0);
   g_rangeCount = 0;

   bool in_zone = false;
   int zone_start = 0, zone_end = 0;

   for(int i = 1; i < rates_total; i++) {
      if(BufStreak[i] >= InpMinStreak) {
         if(!in_zone) {
            in_zone = true;
            zone_start = i - (int)BufStreak[i]; // backward reach
            zone_end = i;
         } else {
            zone_end = i;
            int ps = i - (int)BufStreak[i];
            if(ps < zone_start) zone_start = ps;
         }
      } else {
         if(in_zone) {
            AddRange(zone_start, zone_end, i, open, high, low, close);
            in_zone = false;
         }
      }
   }
   if(in_zone)
      AddRange(zone_start, zone_end, -1, open, high, low, close);

   // --- Step 3: Trim to max boxes ---
   if(g_rangeCount > InpMaxBoxes) {
      int remove = g_rangeCount - InpMaxBoxes;
      for(int i = 0; i < InpMaxBoxes; i++)
         g_ranges[i] = g_ranges[i + remove];
      g_rangeCount = InpMaxBoxes;
      ArrayResize(g_ranges, InpMaxBoxes);
   }

   // --- Step 4: Set breakout arrows ---
   for(int r = 0; r < g_rangeCount; r++) {
      int bo = g_ranges[r].breakout_bar;
      if(bo < 0 || bo >= rates_total) continue;

      double offset = (high[bo] - low[bo]) * 0.4;
      if(offset < _Point * 10) offset = _Point * 10;

      if(close[bo] > g_ranges[r].box_high) {
         BufArrowUp[bo] = low[bo] - offset;
         g_ranges[r].is_bull = true;
      }
      else if(close[bo] < g_ranges[r].box_low) {
         BufArrowDn[bo] = high[bo] + offset;
         g_ranges[r].is_bull = false;
      }
   }

   // --- Step 5: Draw boxes ---
   DrawBoxes(time, rates_total);

   return rates_total;
}

//+------------------------------------------------------------------+
void AddRange(int bstart, int bend, int breakout,
              const double &open[], const double &high[],
              const double &low[], const double &close[]) {
   if(bstart < 0) bstart = 0;

   g_rangeCount++;
   ArrayResize(g_ranges, g_rangeCount);
   int idx = g_rangeCount - 1;
   g_ranges[idx].bar_start = bstart;
   g_ranges[idx].bar_end = bend;
   g_ranges[idx].breakout_bar = breakout;
   g_ranges[idx].is_active = (breakout < 0);
   g_ranges[idx].is_bull = false;

   // Box = full High-Low range of all candles
   g_ranges[idx].box_high = -DBL_MAX;
   g_ranges[idx].box_low  = DBL_MAX;
   for(int i = bstart; i <= bend; i++) {
      if(high[i] > g_ranges[idx].box_high) g_ranges[idx].box_high = high[i];
      if(low[i]  < g_ranges[idx].box_low)  g_ranges[idx].box_low  = low[i];
   }
}

//+------------------------------------------------------------------+
void DrawBoxes(const datetime &time[], int rates_total) {
   ObjectsDeleteAll(0, g_prefix + "BOX_");
   ObjectsDeleteAll(0, g_prefix + "LBL_");

   for(int r = 0; r < g_rangeCount; r++) {
      string id = IntegerToString(r);

      datetime t1 = time[g_ranges[r].bar_start];
      datetime t2;
      if(g_ranges[r].bar_end < rates_total - 1)
         t2 = time[g_ranges[r].bar_end + 1];
      else
         t2 = time[g_ranges[r].bar_end] + PeriodSeconds(Period());

      // Rectangle
      string box_name = g_prefix + "BOX_" + id;
      ObjectCreate(0, box_name, OBJ_RECTANGLE, 0, t1, g_ranges[r].box_high, t2, g_ranges[r].box_low);

      color clr = g_ranges[r].is_active ? ClrBoxActive : ClrBox;
      ObjectSetInteger(0, box_name, OBJPROP_COLOR, clr);
      ObjectSetInteger(0, box_name, OBJPROP_FILL, true);
      ObjectSetInteger(0, box_name, OBJPROP_BACK, true);
      ObjectSetInteger(0, box_name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, box_name, OBJPROP_HIDDEN, true);

      int bar_count = g_ranges[r].bar_end - g_ranges[r].bar_start + 1;
      double range_pts = (g_ranges[r].box_high - g_ranges[r].box_low) / _Point;
      string status = g_ranges[r].is_active ? " [ACTIVE]" : "";
      ObjectSetString(0, box_name, OBJPROP_TOOLTIP,
         "TIGHT RANGE" + status + "\n" +
         "Bars: " + IntegerToString(bar_count) + "\n" +
         "Range: " + DoubleToString(range_pts, 0) + " pts\n" +
         "High: " + DoubleToString(g_ranges[r].box_high, _Digits) + "\n" +
         "Low: "  + DoubleToString(g_ranges[r].box_low, _Digits));

      // Label
      string lbl_name = g_prefix + "LBL_" + id;
      datetime t_mid = t1 + (t2 - t1) / 2;
      ObjectCreate(0, lbl_name, OBJ_TEXT, 0, t_mid, g_ranges[r].box_high);

      string label = "R" + IntegerToString(bar_count) + status;
      ObjectSetString(0, lbl_name, OBJPROP_TEXT, label);
      ObjectSetString(0, lbl_name, OBJPROP_FONT, "Consolas");
      ObjectSetInteger(0, lbl_name, OBJPROP_FONTSIZE, 7);
      ObjectSetInteger(0, lbl_name, OBJPROP_COLOR, g_ranges[r].is_active ? ClrBoxActive : clrWhite);
      ObjectSetInteger(0, lbl_name, OBJPROP_ANCHOR, ANCHOR_LOWER);
      ObjectSetInteger(0, lbl_name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, lbl_name, OBJPROP_HIDDEN, true);
   }

   ChartRedraw(0);
}
//+------------------------------------------------------------------+
