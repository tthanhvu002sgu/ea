//+------------------------------------------------------------------+
//|                                                   RegimeScore.mq5 |
//|                                     Based on Composite Regime Score |
//+------------------------------------------------------------------+
#property copyright "Mean Reversion Regime"
#property version   "1.00"
#property indicator_separate_window
#property indicator_buffers 2
#property indicator_plots   1

// Plot settings
#property indicator_label1  "Composite Regime Score"
#property indicator_type1   DRAW_COLOR_HISTOGRAM
#property indicator_color1  clrGray,clrGreen,clrLime,clrRed,clrMaroon
#property indicator_style1  STYLE_SOLID
#property indicator_width1  2

// Levels
#property indicator_level1 2.0
#property indicator_level2 0.5
#property indicator_level3 0.0
#property indicator_level4 -0.5
#property indicator_level5 -2.0

//+------------------------------------------------------------------+
//| Input Parameters                                                 |
//+------------------------------------------------------------------+
input group "=== SAMPLING SETTINGS ==="
input int    Sampling_Period = 4;  // Recalculate Every N Bars (Sample & Hold)

input group "=== WEIGHTS ==="
input double W_Trend    = 0.6; // Weight for Trend Z-Score
input double W_Mom      = 0.4; // Weight for Momentum Z-Score

input group "=== COMPONENT 1: TREND (Z-Score) ==="
input int    T_EMA_Per  = 50;  // Trend EMA Period
input int    T_ATR_Per  = 20;  // Trend ATR Period

input group "=== COMPONENT 2: MOMENTUM (R-Score) ==="
input int    M_Lookback = 10;  // Momentum Lookback (Close - Close[N])
input int    M_ATR_Per  = 10;  // Momentum ATR Period

input group "=== COMPONENT 3: VOLATILITY (Multiplier) ==="
input int    V_Fast_Per = 5;   // Volatility Fast ATR
input int    V_Slow_Per = 20;  // Volatility Slow ATR
input double V_Exp_Thresh = 1.0; // Expansion Threshold (> this -> Mult 1.2)
input double V_Comp_Thresh = 0.8;// Compression Threshold (< this -> Mult 0.8)
input double V_Exp_Mult   = 1.2; // Expansion Multiplier
input double V_Comp_Mult  = 0.8; // Compression Multiplier

//+------------------------------------------------------------------+
//| Global Variables & Handles                                       |
//+------------------------------------------------------------------+
double ResultBuffer[];
double ColorBuffer[];

int hEMA_Trend;
int hATR_Trend;
int hATR_Mom;
int hATR_VolFast;
int hATR_VolSlow;

//+------------------------------------------------------------------+
//| Custom indicator initialization function                         |
//+------------------------------------------------------------------+
int OnInit()
{
   // Indicator Buffers
   SetIndexBuffer(0, ResultBuffer, INDICATOR_DATA);
   SetIndexBuffer(1, ColorBuffer, INDICATOR_COLOR_INDEX);
   
   PlotIndexSetDouble(0, PLOT_EMPTY_VALUE, 0.0);
   
   // Initialize Handles
   hEMA_Trend   = iMA(_Symbol, PERIOD_CURRENT, T_EMA_Per, 0, MODE_EMA, PRICE_CLOSE);
   hATR_Trend   = iATR(_Symbol, PERIOD_CURRENT, T_ATR_Per);
   hATR_Mom     = iATR(_Symbol, PERIOD_CURRENT, M_ATR_Per);
   hATR_VolFast = iATR(_Symbol, PERIOD_CURRENT, V_Fast_Per);
   hATR_VolSlow = iATR(_Symbol, PERIOD_CURRENT, V_Slow_Per);
   
   if(hEMA_Trend == INVALID_HANDLE || hATR_Trend == INVALID_HANDLE || 
      hATR_Mom == INVALID_HANDLE || hATR_VolFast == INVALID_HANDLE || hATR_VolSlow == INVALID_HANDLE)
   {
      Print("Error creating indicator handles");
      return(INIT_FAILED);
   }
   
   IndicatorSetInteger(INDICATOR_DIGITS, 2);
   IndicatorSetString(INDICATOR_SHORTNAME, "CRS (" + IntegerToString(T_EMA_Per) + ")");
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Custom indicator iteration function                              |
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
   if(rates_total < T_EMA_Per + 1) return 0;
   
   // Define start index
   int start = prev_calculated - 1;
   if(start < 0) start = 0;
   if(start < T_EMA_Per) start = T_EMA_Per;
   
   // Buffers for accessing indicators
   // We need to copy one by one or blocks. 
   // For efficiency, we can assume 'close' array is available (access via close[i] if NOT series, but OnCalculate arrays are usually SERIES if configured... wait, default is NOT series)
   // Let's set arrays as series for easier handling
   ArraySetAsSeries(close, true);
   ArraySetAsSeries(ResultBuffer, true);
   ArraySetAsSeries(ColorBuffer, true);
   
   // Note: If ArraySetAsSeries is true, index 0 is newest.
   // But standard OnCalculate Loop usually goes 0..total. 
   // Let's stick to standard loop logic but map indexes correctly.
   // Actually, using CopyBuffer inside loop suggests getting data by index.
   
   // Let's iterate forward from 'start' to 'rates_total-1'
   // This means we need to access items with shift = rates_total - 1 - i
   // But handle buffers are accessed by CopyBuffer with shift.
   
   for(int i = start; i < rates_total; i++)
   {
      // Index mapping for Handle Copying (Reverse logic)
      // i = 0 is oldest bar in standard array. i = rates_total-1 is newest.
      // Shift 0 = Newest.
      int shift = rates_total - 1 - i;
      
      // SAMPLE & HOLD LOGIC
      // Check if this bar is a "Check Point"
      // We use 'i' (absolute index from start) or 'shift'? 
      // Using 'i' ensures the grid is fixed relative to history start.
      // Using 'shift' ensures the grid is fixed relative to NOW.
      // Usually, consistent sampling history requires fixing to absolute time/index.
      // But MQL5 indexing changes as new bars arrive (Index 0 is always new). 
      // If we use 'shift % Period == 0', then at every new bar, the grid SHIFTS. This causes repainting!
      // CRITICAL: We must use a fixed reference. 'time[shift]' is absolute.
      // But Sample & Hold usually implies "Every N bars".
      // If we use 'rates_total - 1 - shift' (which is 'i'), the index 'i' grows.
      // Let's use 'i' (absolute count from beginning of array).
      // Wait, 'rates_total' grows. 'i' shifts?
      // Standard: Period calculation should be stable.
      // If we simply use `i % Sampling_Period == 0`, then on new bar (total varies), the modulus might shift?
      // If rates_total=100, i=0..99.
      // Next tick, rates_total=101. i=0..100.
      // i=0 is always the oldest loaded bar.
      // So `i % Sampling_Period` is STABLE relative to history start.
      
      bool is_check_point = (i % Sampling_Period == 0);
      
      // Exception: Always calculate the very first bar initialized to avoid accessing junk
      if (i == 0) is_check_point = true;
      
      double crs = 0.0;
      double final_color = 0.0;
      
      if (!is_check_point)
      {
         // HOLD STATE: Copy from previous (which is 'shift + 1' in Series array)
         // Since we iterate 'i' from start upwards (old to new), 'shift+1' is the "older" bar we just processed?
         // No.
         // 'i' goes 0 -> 100.
         // 'i=0' (Oldest) calculated first. 
         // 'i=1' (Next Oldest). shift+1 is 'i=0'. Correct.
         // So if we are at 'i', we look at 'i-1' (which corresponds to shift+1).
         
         if(shift + 1 < rates_total)
         {
             crs = ResultBuffer[shift + 1];
             final_color = ColorBuffer[shift + 1];
         }
      }
      else
      {
         // CALCULATE STATE (Sampling)
         
         // 1. Get Indicator Data
         double ema_trend[1], atr_trend[1], atr_mom[1], atr_vfast[1], atr_vslow[1];
         
         if(CopyBuffer(hEMA_Trend, 0, shift, 1, ema_trend) <= 0) continue;
         if(CopyBuffer(hATR_Trend, 0, shift, 1, atr_trend) <= 0) continue;
         if(CopyBuffer(hATR_Mom, 0, shift, 1, atr_mom) <= 0) continue;
         if(CopyBuffer(hATR_VolFast, 0, shift, 1, atr_vfast) <= 0) continue;
         if(CopyBuffer(hATR_VolSlow, 0, shift, 1, atr_vslow) <= 0) continue;
         
         double c_price = close[shift]; // Using series array
         double c_prev  = close[shift + M_Lookback]; // Logic: Close - Close[N]
         // Check bound
         if(shift + M_Lookback >= rates_total) continue;
         
         // ==========================================
         // A. TREND Z-SCORE
         // Trend_Z = (Close - EMA50) / (ATR20 * sqrt(50))
         // ==========================================
         double denom_t = atr_trend[0] * MathSqrt(T_EMA_Per);
         double trend_z = (denom_t > 0) ? (c_price - ema_trend[0]) / denom_t : 0.0;
         
         // ==========================================
         // B. MOMENTUM Z-SCORE
         // Mom_Z = (Close - Keep_N) / (ATR_N * sqrt(N))
         // ==========================================
         double denom_m = atr_mom[0] * MathSqrt(M_Lookback);
         double mom_z   = (denom_m > 0) ? (c_price - c_prev) / denom_m : 0.0;
         
         // ==========================================
         // C. VOLATILITY FACTOR
         // Ratio = ATR5 / ATR20
         // ==========================================
         double vol_ratio = (atr_vslow[0] > 0) ? atr_vfast[0] / atr_vslow[0] : 1.0;
         double vol_mult  = 1.0;
         
         if(vol_ratio > V_Exp_Thresh) vol_mult = V_Exp_Mult;
         else if(vol_ratio < V_Comp_Thresh) vol_mult = V_Comp_Mult;
         
         // ==========================================
         // MASTER FORMULA
         // CRS = (Trend * W + Mom * W) * VolFactor
         // ==========================================
         double raw_score = (trend_z * W_Trend) + (mom_z * W_Mom);
         crs = raw_score * vol_mult;
         
         // ==========================================
         // COLOR CLASSIFICATION
         // ==========================================
         if(crs > 2.0) final_color = 2;        // Turbo Bull
         else if(crs > 0.5) final_color = 1;   // Grinding Bull
         else if(crs > -0.5) final_color = 0;  // Choppy
         else if(crs > -2.0) final_color = 3;  // Grinding Bear
         else final_color = 4;                 // Panic Bear
      }
      
      ResultBuffer[shift] = crs;
      ColorBuffer[shift] = final_color;
   }
   
   return rates_total;
}