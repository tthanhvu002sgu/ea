//+------------------------------------------------------------------+
//|                                              Volume Delta.mq5     |
//|                           Converted from Pine Script to MQL5      |
//+------------------------------------------------------------------+
#property copyright   "Vu - Converted by AI"
#property link        ""
#property version     "2.00"
#property description "Volume Delta v2 - Visual Intelligence Edition"
#property description "Highlights imbalance, absorption, divergence signals"

#property indicator_separate_window
#property indicator_buffers 8
#property indicator_plots   3

//--- Plot 0: Buy Volume histogram (color-coded by imbalance intensity)
#property indicator_label1  "Buy Volume"
#property indicator_type1   DRAW_COLOR_HISTOGRAM
#property indicator_color1  clrForestGreen, clrLimeGreen, clrSpringGreen
//                           weak=forest    medium=lime    strong=spring
#property indicator_width1  4
#property indicator_style1  STYLE_SOLID

//--- Plot 1: Sell Volume histogram (color-coded by imbalance intensity)
#property indicator_label2  "Sell Volume"
#property indicator_type2   DRAW_COLOR_HISTOGRAM
#property indicator_color2  clrFireBrick, clrCrimson, clrRed
//                           weak=firebrick  medium=crimson  strong=red
#property indicator_width2  4
#property indicator_style2  STYLE_SOLID

//--- Plot 2: Cumulative Delta (line)
#property indicator_label3  "Cum. Delta"
#property indicator_type3   DRAW_COLOR_LINE
#property indicator_color3  clrDodgerBlue, clrOrangeRed
#property indicator_width3  2
#property indicator_style3  STYLE_SOLID

//=== INPUTS ===
input group "=== CAI DAT CHINH ==="
input bool            InpUseTickData   = true;          // Dung Tick Data (Chinh xac 100%)
input int             InpMaxHistoryBars= 2000;          // So luong nen lich su toi da (Tranh dong MT5)
input ENUM_TIMEFRAMES InpSubTF         = PERIOD_M1;     // Sub-timeframe (Neu khong dung Tick)
input bool            InpUseRealVol    = false;         // Dung Real Volume
input bool            InpShowCumDelta  = true;          // Hien Cumulative Delta

input group "=== CUMULATIVE DELTA ==="
input bool            InpResetDaily    = true;          // Reset Cum. moi ngay
input bool            InpShowInfoPanel = true;          // Hien Info Panel

input group "=== VOLUME ASSUMPTION ==="
input bool            InpUseAssumption = false;         // Bat Volume Assumption (40/60)

input group "=== NGUONG CANH BAO (Imbalance) ==="
input double          InpWeakThresh    = 55.0;          // Nguong Yeu: Buy% >= X (default 55%)
input double          InpMedThresh     = 65.0;          // Nguong Trung binh: >= X (default 65%)
input double          InpStrongThresh  = 75.0;          // Nguong Manh: >= X (default 75%) -> Ve mui ten

input group "=== ABSORPTION DETECTION ==="
input bool            InpShowAbsorb    = true;          // Hien dau hieu Absorption
input double          InpAbsorbVolMult = 1.8;           // Volume phai >= X lan trung binh
input double          InpAbsorbBodyPct = 25.0;          // Body <= X% cua Range (bar nho)

input group "=== MAUSAC ==="
input color           ClrBuyWeak       = clrForestGreen;  // Buy yeu
input color           ClrBuyMed        = clrLimeGreen;    // Buy trung binh
input color           ClrBuyStrong     = clrSpringGreen;  // Buy manh
input color           ClrSellWeak      = clrFireBrick;    // Sell yeu
input color           ClrSellMed       = clrCrimson;      // Sell trung binh
input color           ClrSellStrong    = clrRed;          // Sell manh
input color           ClrCumUp         = clrDodgerBlue;   // Cum Delta+
input color           ClrCumDn         = clrOrangeRed;    // Cum Delta-
input color           ClrArrowBuy      = clrAqua;         // Mui ten Buy signal
input color           ClrArrowSell     = clrMagenta;      // Mui ten Sell signal
input color           ClrAbsorb        = clrGold;         // Dau hieu Absorption

input group "=== INFO PANEL ==="
input int             InpInfoX         = 15;           // Panel X offset
input int             InpInfoY         = 30;           // Panel Y offset

//=== BUFFERS ===
double BufBuyVol[];       // Buy volume per bar
double BufBuyClr[];       // Buy color index (0=weak,1=med,2=strong)
double BufSellVol[];      // Sell volume (negative)
double BufSellClr[];      // Sell color index
double BufCumDelta[];     // Cumulative delta
double BufCumDeltaClr[];  // Cum color index
double BufDelta[];        // Net delta (calc only)
double BufTotalVol[];     // Total vol (calc only)

//=== GLOBALS ===
string g_prefix  = "VD2_";
int    g_lookback = 50;   // Bars used for rolling stats

//+------------------------------------------------------------------+
int OnInit() {
   SetIndexBuffer(0, BufBuyVol,      INDICATOR_DATA);
   SetIndexBuffer(1, BufBuyClr,      INDICATOR_COLOR_INDEX);
   SetIndexBuffer(2, BufSellVol,     INDICATOR_DATA);
   SetIndexBuffer(3, BufSellClr,     INDICATOR_COLOR_INDEX);
   SetIndexBuffer(4, BufCumDelta,    INDICATOR_DATA);
   SetIndexBuffer(5, BufCumDeltaClr, INDICATOR_COLOR_INDEX);
   SetIndexBuffer(6, BufDelta,       INDICATOR_CALCULATIONS);
   SetIndexBuffer(7, BufTotalVol,    INDICATOR_CALCULATIONS);

   //--- Buy colors: 0=weak 1=mid 2=strong
   PlotIndexSetInteger(0, PLOT_COLOR_INDEXES, 3);
   PlotIndexSetInteger(0, PLOT_LINE_COLOR, 0, ClrBuyWeak);
   PlotIndexSetInteger(0, PLOT_LINE_COLOR, 1, ClrBuyMed);
   PlotIndexSetInteger(0, PLOT_LINE_COLOR, 2, ClrBuyStrong);

   //--- Sell colors: 0=weak 1=mid 2=strong
   PlotIndexSetInteger(2, PLOT_COLOR_INDEXES, 3);
   PlotIndexSetInteger(2, PLOT_LINE_COLOR, 0, ClrSellWeak);
   PlotIndexSetInteger(2, PLOT_LINE_COLOR, 1, ClrSellMed);
   PlotIndexSetInteger(2, PLOT_LINE_COLOR, 2, ClrSellStrong);

   //--- Cum Delta colors: 0=up 1=down
   PlotIndexSetInteger(4, PLOT_COLOR_INDEXES, 2);
   PlotIndexSetInteger(4, PLOT_LINE_COLOR, 0, ClrCumUp);
   PlotIndexSetInteger(4, PLOT_LINE_COLOR, 1, ClrCumDn);

   if(!InpShowCumDelta)
      PlotIndexSetInteger(4, PLOT_DRAW_TYPE, DRAW_NONE);

   IndicatorSetString(INDICATOR_SHORTNAME, "Vol Delta v2 | " + Symbol());
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
   ObjectsDeleteAll(0, g_prefix);
   Comment("");
}

//+------------------------------------------------------------------+
//| Get buy/sell volume breakdown for a bar                          |
//+------------------------------------------------------------------+
void CalcBarDelta(datetime bar_start, datetime bar_end,
                  double &buy_vol, double &sell_vol) {
   buy_vol = 0;
   sell_vol = 0;
   bool use_fallback = true;

   if(InpUseTickData) {
      MqlTick ticks[];
      ulong start_msc = (ulong)bar_start * 1000;
      ulong end_msc   = (ulong)bar_end * 1000 - 1;
      
      int count = CopyTicksRange(Symbol(), ticks, COPY_TICKS_ALL, start_msc, end_msc);
      if(count > 0) {
         use_fallback = false;
         for(int i = 0; i < count; i++) {
            double vol = InpUseRealVol ? (double)ticks[i].volume_real : 1.0;
            if(vol <= 0 && InpUseRealVol) vol = (double)ticks[i].volume; // Fallback
            if(vol <= 0 && !InpUseRealVol) vol = 1.0;                    // Fallback tick vol
            
            bool is_buy = false, is_sell = false;
            if((ticks[i].flags & TICK_FLAG_BUY) == TICK_FLAG_BUY) {
               is_buy = true;
            }
            else if((ticks[i].flags & TICK_FLAG_SELL) == TICK_FLAG_SELL) {
               is_sell = true;
            }
            else {
               // Fallback phan tich bid/ask
               if(i > 0) {
                  if(ticks[i].bid > ticks[i-1].bid || ticks[i].ask > ticks[i-1].ask)
                     is_buy = true;
                  else if(ticks[i].bid < ticks[i-1].bid || ticks[i].ask < ticks[i-1].ask)
                     is_sell = true;
               }
            }
            
            if(is_buy) buy_vol += vol;
            else if(is_sell) sell_vol += vol;
         }
      }
   }
   
   if(use_fallback) {
      MqlRates m1[];
      ArraySetAsSeries(m1, false);
      int count = CopyRates(Symbol(), InpSubTF, bar_start, bar_end, m1);
      if(count > 0) {
         for(int i = 0; i < count; i++) {
            if(m1[i].time < bar_start) continue;
            if(m1[i].time >= bar_end)  break;
            double vol = InpUseRealVol ? (double)m1[i].real_volume
                                       : (double)m1[i].tick_volume;
            if(m1[i].close >= m1[i].open)
               buy_vol += vol;
            else
               sell_vol += vol;
         }
      }
   }

   if(InpUseAssumption) {
      if(buy_vol > 0 && sell_vol == 0) { sell_vol = buy_vol*0.4; buy_vol *= 0.6; }
      else if(sell_vol > 0 && buy_vol == 0) { buy_vol = sell_vol*0.4; sell_vol *= 0.6; }
   }
}

//+------------------------------------------------------------------+
bool IsNewDay(const datetime &time[], int i) {
   if(i <= 0) return true;
   MqlDateTime a, b;
   TimeToStruct(time[i],   a);
   TimeToStruct(time[i-1], b);
   return (a.day != b.day || a.mon != b.mon || a.year != b.year);
}

//+------------------------------------------------------------------+
//| Get color index based on dominant side %                         |
//+------------------------------------------------------------------+
int GetColorIndex(double dominant_pct) {
   if(dominant_pct >= InpStrongThresh) return 2;  // Strong
   if(dominant_pct >= InpMedThresh)    return 1;  // Medium
   return 0;                                       // Weak
}

//+------------------------------------------------------------------+
//| Rolling average volume over last N bars                          |
//+------------------------------------------------------------------+
double RollingAvgVol(int current_bar, int lookback) {
   double sum = 0;
   int cnt = 0;
   for(int i = MathMax(0, current_bar - lookback); i < current_bar; i++) {
      sum += BufTotalVol[i];
      cnt++;
   }
   return cnt > 0 ? sum / cnt : 0;
}

//+------------------------------------------------------------------+
//| Draw imbalance arrow on main chart (window 0)                    |
//+------------------------------------------------------------------+
void DrawImbalanceArrow(int bar_idx, datetime t, double price,
                        bool is_buy, double pct) {
   string name = g_prefix + "ARR_" + IntegerToString(bar_idx);
   
   ENUM_OBJECT arrow_type = is_buy ? OBJ_ARROW_UP : OBJ_ARROW_DOWN;
   color       arrow_clr  = is_buy ? ClrArrowBuy   : ClrArrowSell;
   
   if(ObjectFind(0, name) >= 0) ObjectDelete(0, name);
   ObjectCreate(0, name, arrow_type, 0, t, price);
   ObjectSetInteger(0, name, OBJPROP_COLOR, arrow_clr);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR,
                    is_buy ? ANCHOR_TOP : ANCHOR_BOTTOM);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   
   // Tooltip
   string side = is_buy ? "BUY" : "SELL";
   ObjectSetString(0, name, OBJPROP_TOOLTIP,
      side + " IMBALANCE " + DoubleToString(pct, 1) + "%\n" +
      "Time: " + TimeToString(t, TIME_DATE|TIME_MINUTES));
}

//+------------------------------------------------------------------+
//| Draw absorption marker (high vol + small body = absorption)      |
//+------------------------------------------------------------------+
void DrawAbsorptionMark(int bar_idx, datetime t, double price_high,
                        double price_low, double open, double close) {
   string name = g_prefix + "ABS_" + IntegerToString(bar_idx);

   if(ObjectFind(0, name) >= 0) ObjectDelete(0, name);
   ObjectCreate(0, name, OBJ_ARROW, 0, t, (price_high + price_low) / 2.0);
   ObjectSetInteger(0, name, OBJPROP_ARROWCODE, 168); // Diamond shape
   ObjectSetInteger(0, name, OBJPROP_COLOR, ClrAbsorb);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_CENTER);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectSetString(0, name, OBJPROP_TOOLTIP,
      "ABSORPTION - High Vol, Small Body\n" +
      "Watch for reversal or continuation\n" +
      "Time: " + TimeToString(t, TIME_DATE|TIME_MINUTES));
}

//+------------------------------------------------------------------+
//| Main calculation                                                  |
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

   if(rates_total < 3) return 0;

   int start;
   if(prev_calculated <= 0) {
      start = rates_total - InpMaxHistoryBars;
      if (start < 0) start = 0;
      ObjectsDeleteAll(0, g_prefix);  // Clear all objects on full recalc
      ArrayInitialize(BufBuyVol,      0);
      ArrayInitialize(BufBuyClr,      0);
      ArrayInitialize(BufSellVol,     0);
      ArrayInitialize(BufSellClr,     0);
      ArrayInitialize(BufCumDelta,    0);
      ArrayInitialize(BufCumDeltaClr, 0);
      ArrayInitialize(BufDelta,       0);
      ArrayInitialize(BufTotalVol,    0);
   } else {
      start = MathMax(prev_calculated - 3, 0);
   }

   for(int i = start; i < rates_total; i++) {
      datetime bar_start = time[i];
      datetime bar_end   = (i < rates_total-1) ? time[i+1]
                                                : bar_start + PeriodSeconds(Period());

      //--- 1. Tinh Buy/Sell volume
      double buy_vol = 0, sell_vol = 0;
      CalcBarDelta(bar_start, bar_end, buy_vol, sell_vol);

      BufBuyVol[i]   = buy_vol;
      BufSellVol[i]  = -sell_vol;
      BufDelta[i]    = buy_vol - sell_vol;
      BufTotalVol[i] = buy_vol + sell_vol;

      //--- 2. Color index dua tren imbalance %
      double total = BufTotalVol[i];
      double buy_pct  = total > 0 ? (buy_vol / total) * 100.0 : 50.0;
      double sell_pct = total > 0 ? (sell_vol / total) * 100.0 : 50.0;
      double dom_pct  = MathMax(buy_pct, sell_pct);

      BufBuyClr[i]  = GetColorIndex(buy_pct);
      BufSellClr[i] = GetColorIndex(sell_pct);

      //--- 3. Cumulative Delta
      double prev_cum = (i > 0) ? BufCumDelta[i-1] : 0;
      if(InpResetDaily && IsNewDay(time, i)) prev_cum = 0;
      BufCumDelta[i]    = prev_cum + BufDelta[i];
      BufCumDeltaClr[i] = BufCumDelta[i] >= 0 ? 0 : 1;

      //--- 4. Strong imbalance arrow (chi ve cho bar da dong, khong ve bar dang hinh thanh)
      if(i < rates_total - 1 && dom_pct >= InpStrongThresh && total > 0) {
         bool buy_dominant = (buy_pct >= InpStrongThresh);
         double arrow_price = buy_dominant ? low[i] - 2*_Point*10
                                           : high[i] + 2*_Point*10;
         DrawImbalanceArrow(i, bar_start, arrow_price, buy_dominant, dom_pct);
      }

      //--- 5. Absorption detection
      if(InpShowAbsorb && i < rates_total - 1 && total > 0) {
         double avg_vol = RollingAvgVol(i, g_lookback);
         if(avg_vol > 0 && total >= avg_vol * InpAbsorbVolMult) {
            double range = high[i] - low[i];
            double body  = MathAbs(close[i] - open[i]);
            double body_pct = (range > 0) ? (body / range) * 100.0 : 100.0;
            if(body_pct <= InpAbsorbBodyPct && range > 0) {
               DrawAbsorptionMark(i, bar_start, high[i], low[i], open[i], close[i]);
            }
         }
      }
   }

   //--- Info Panel
   if(InpShowInfoPanel && rates_total > 0)
      DrawInfoPanel(rates_total - 1, rates_total);

   return rates_total;
}

//+------------------------------------------------------------------+
//| Build ASCII progress bar                                         |
//+------------------------------------------------------------------+
string ProgressBar(double pct, int width = 12) {
   int filled = (int)MathRound(pct / 100.0 * width);
   filled = MathMax(0, MathMin(width, filled));
   string bar = "[";
   for(int i = 0; i < width; i++)
      bar += (i < filled) ? "|" : " ";
   bar += "]";
   return bar;
}

//+------------------------------------------------------------------+
//| Draw enhanced info panel                                         |
//+------------------------------------------------------------------+
void DrawInfoPanel(int last, int rates_total) {
   string name = g_prefix + "Panel";

   double buy   = BufBuyVol[last];
   double sell  = MathAbs(BufSellVol[last]);
   double delta = BufDelta[last];
   double cum   = BufCumDelta[last];
   double total = BufTotalVol[last];
   double buy_pct  = total > 0 ? (buy / total) * 100.0 : 50.0;
   double sell_pct = total > 0 ? (sell / total) * 100.0 : 50.0;

   //--- Dominant side label
   string dom_label;
   if(buy_pct >= InpStrongThresh)       dom_label = ">>> STRONG BUY <<<";
   else if(buy_pct >= InpMedThresh)     dom_label = ">> BUY <<";
   else if(buy_pct >= InpWeakThresh)    dom_label = "> Buy <";
   else if(sell_pct >= InpStrongThresh) dom_label = ">>> STRONG SELL <<<";
   else if(sell_pct >= InpMedThresh)    dom_label = ">> SELL <<";
   else if(sell_pct >= InpWeakThresh)   dom_label = "> Sell <";
   else                                 dom_label  = "- NEUTRAL -";

   //--- Rolling stats (last 20 bars for context)
   double max_abs_delta = 0, sum_delta = 0;
   int stat_bars = MathMin(last+1, 20);
   for(int i = last - stat_bars + 1; i <= last; i++) {
      if(i < 0) continue;
      double d = MathAbs(BufDelta[i]);
      if(d > max_abs_delta) max_abs_delta = d;
      sum_delta += BufDelta[i];
   }
   double avg_delta = (stat_bars > 0) ? sum_delta / stat_bars : 0;
   double delta_strength = (max_abs_delta > 0)
                           ? (MathAbs(delta) / max_abs_delta) * 100.0
                           : 0;

   //--- Build panel text
   string sep = "________________________\n";
   string txt = "";
   txt += " VOLUME  DELTA  v2\n";
   txt += sep;
   txt += " " + dom_label + "\n";
   txt += sep;
   txt += " Buy:  " + ProgressBar(buy_pct) + " " + DoubleToString(buy_pct,1) + "%\n";
   txt += " Sell: " + ProgressBar(sell_pct) + " " + DoubleToString(sell_pct,1) + "%\n";
   txt += sep;
   txt += " Vol:   " + FormatVol(total) + "\n";
   txt += " Delta: " + (delta >= 0 ? "+" : "") + FormatVol(delta) + "\n";
   txt += " Str:   " + ProgressBar(delta_strength) + " " + DoubleToString(delta_strength,0) + "%\n";
   txt += sep;
   txt += " Cum:   " + (cum >= 0 ? "+" : "") + FormatVol(cum) + "\n";
   txt += " Bias:  " + (avg_delta > 0 ? "BUY" : avg_delta < 0 ? "SELL" : "FLAT")
          + " (" + DoubleToString(MathAbs(avg_delta/MathMax(1,max_abs_delta))*100,0) + "% 20-bar)\n";
   txt += sep;
   txt += " [ARR]=Strong Imbalance\n";
   txt += " [DIA]=Absorption\n";

   //--- Create or update label
   if(ObjectFind(0, name) < 0) {
      ObjectCreate(0, name, OBJ_LABEL, ChartWindowFind(), 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
      ObjectSetString(0, name, OBJPROP_FONT, "Consolas");
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 8);
      ObjectSetInteger(0, name, OBJPROP_BACK, false);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   }

   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, InpInfoX);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, InpInfoY);
   ObjectSetString(0, name, OBJPROP_TEXT, txt);

   //--- Color the panel by dominant direction
   color panel_clr;
   if(buy_pct >= InpStrongThresh)       panel_clr = ClrBuyStrong;
   else if(buy_pct >= InpMedThresh)     panel_clr = ClrBuyMed;
   else if(buy_pct >= InpWeakThresh)    panel_clr = ClrBuyWeak;
   else if(sell_pct >= InpStrongThresh) panel_clr = ClrSellStrong;
   else if(sell_pct >= InpMedThresh)    panel_clr = ClrSellMed;
   else if(sell_pct >= InpWeakThresh)   panel_clr = ClrSellWeak;
   else                                 panel_clr = clrGray;

   ObjectSetInteger(0, name, OBJPROP_COLOR, panel_clr);
}

//+------------------------------------------------------------------+
//| Format volume                                                    |
//+------------------------------------------------------------------+
string FormatVol(double vol) {
   if(MathAbs(vol) >= 1000000) return DoubleToString(vol/1000000, 2) + "M";
   if(MathAbs(vol) >= 1000)    return DoubleToString(vol/1000, 1) + "K";
   return DoubleToString(vol, 0);
}
//+------------------------------------------------------------------+
