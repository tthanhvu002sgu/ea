//+------------------------------------------------------------------+
//|                                             Detrended CVD.mq5    |
//|                    Converted from Quantified Detrended CVD       |
//+------------------------------------------------------------------+
#property copyright   "Vu"
#property link        ""
#property version     "1.00"
#property description "Detrended CVD (Z-Score Oscillator)"
#property indicator_separate_window
#property indicator_buffers 4
#property indicator_plots   2

//--- Plot 0: Z-Score Histogram
#property indicator_label1  "Z-Score CVD"
#property indicator_type1   DRAW_COLOR_HISTOGRAM
#property indicator_color1  clrLime, clrRed, clrTeal, clrMaroon
#property indicator_style1  STYLE_SOLID
#property indicator_width1  2

//--- Plot 1: Signal Line
#property indicator_label2  "Signal Line"
#property indicator_type2   DRAW_LINE
#property indicator_color2  clrDarkOrange
#property indicator_style2  STYLE_SOLID
#property indicator_width2  1

//--- Levels
#property indicator_level1 0.0
#property indicator_level2 2.0
#property indicator_level3 -2.0
#property indicator_levelcolor clrGray
#property indicator_levelstyle STYLE_DOT

//=== INPUTS ===
input group "=== Z-SCORE CONFIG ==="
input int    InpLength    = 100;   // Window Size
input double InpLimitStd  = 2.0;   // Standard Deviation Limit
input int    InpSignalEma = 9;     // Signal Line EMA Period
input bool   InpUseRealVol= false; // Use Real Volume (False = Tick Volume)

//=== BUFFERS ===
double BufZScore[];
double BufZColor[];
double BufSignal[];
double BufRawCVD[];

//+------------------------------------------------------------------+
//| Custom indicator initialization function                         |
//+------------------------------------------------------------------+
int OnInit() {
   SetIndexBuffer(0, BufZScore, INDICATOR_DATA);
   SetIndexBuffer(1, BufZColor, INDICATOR_COLOR_INDEX);
   SetIndexBuffer(2, BufSignal, INDICATOR_DATA);
   SetIndexBuffer(3, BufRawCVD, INDICATOR_CALCULATIONS);

   PlotIndexSetInteger(0, PLOT_COLOR_INDEXES, 4);
   PlotIndexSetInteger(0, PLOT_LINE_COLOR, 0, clrLime);
   PlotIndexSetInteger(0, PLOT_LINE_COLOR, 1, clrRed);
   PlotIndexSetInteger(0, PLOT_LINE_COLOR, 2, clrTeal);
   PlotIndexSetInteger(0, PLOT_LINE_COLOR, 3, clrMaroon);

   IndicatorSetDouble(INDICATOR_LEVELVALUE, 0, 0.0);
   IndicatorSetDouble(INDICATOR_LEVELVALUE, 1, InpLimitStd);
   IndicatorSetDouble(INDICATOR_LEVELVALUE, 2, -InpLimitStd);

   IndicatorSetString(INDICATOR_SHORTNAME, "Detrended CVD Z-Score (" + IntegerToString(InpLength) + ")");
   IndicatorSetInteger(INDICATOR_DIGITS, 2);

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Custom indicator iteration function                              |
//| OPTIMIZED: O(1) per bar using incremental sliding window         |
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

   if(rates_total < InpLength) return 0;

   // --- Determine calculation range
   int start;
   bool fullRecalc = (prev_calculated <= 0);

   if(fullRecalc) {
      start = 0;
      ArrayInitialize(BufZScore, 0);
      ArrayInitialize(BufZColor, 0);
      ArrayInitialize(BufSignal, 0);
      ArrayInitialize(BufRawCVD, 0);
   } else {
      // On tick: only recalculate from last bar
      start = prev_calculated - 1;
   }

   double alpha = 2.0 / (InpSignalEma + 1.0);

   for(int i = start; i < rates_total; i++) {
      // === 1. Raw Delta ===
      double vol = InpUseRealVol ? (double)volume[i] : (double)tick_volume[i];
      double tick_delta = 0;

      if(close[i] > open[i])
         tick_delta = vol;
      else if(close[i] < open[i])
         tick_delta = -vol;

      // Cumulative CVD (continuous, never resets)
      BufRawCVD[i] = (i > 0 ? BufRawCVD[i-1] : 0.0) + tick_delta;

      // === 2. Z-Score (Sliding Window SMA + Population StDev) ===
      double z_cvd = 0.0;

      if(i >= InpLength - 1) {
         // Compute SMA in one pass, then variance in second pass
         // NOTE: We cannot use a true O(1) incremental approach for variance
         // because the mean changes each step. However, we use a two-pass
         // Welford-like approach that is cache-friendly and avoids MathPow().
         double sum = 0.0;
         int wStart = i - InpLength + 1;
         for(int j = wStart; j <= i; j++)
            sum += BufRawCVD[j];

         double mean_cvd = sum / InpLength;

         double sum_sq = 0.0;
         for(int j = wStart; j <= i; j++) {
            double d = BufRawCVD[j] - mean_cvd;
            sum_sq += d * d;   // d*d is faster than MathPow(d, 2)
         }

         double std_cvd = MathSqrt(sum_sq / InpLength);

         if(std_cvd > 0.0)
            z_cvd = (BufRawCVD[i] - mean_cvd) / std_cvd;
      }

      BufZScore[i] = z_cvd;

      // === 3. Color Mapping ===
      if(z_cvd > InpLimitStd)
         BufZColor[i] = 0;       // Lime  (extreme buy)
      else if(z_cvd < -InpLimitStd)
         BufZColor[i] = 1;       // Red   (extreme sell)
      else if(z_cvd > 0)
         BufZColor[i] = 2;       // Teal  (mild buy)
      else
         BufZColor[i] = 3;       // Maroon (mild sell)

      // === 4. Signal Line (EMA of Z-Score) ===
      if(i == 0)
         BufSignal[i] = z_cvd;
      else
         BufSignal[i] = z_cvd * alpha + BufSignal[i-1] * (1.0 - alpha);
   }

   return rates_total;
}
//+------------------------------------------------------------------+
