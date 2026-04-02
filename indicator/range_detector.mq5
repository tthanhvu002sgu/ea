//+------------------------------------------------------------------+
//|                                              RangeDetector.mq5   |
//|  Sideways detection: squeeze + overlap/revisit filter             |
//+------------------------------------------------------------------+
#property indicator_chart_window
#property indicator_buffers 3
#property indicator_plots   1

#property indicator_label1  "EMA"
#property indicator_type1   DRAW_LINE
#property indicator_color1  clrRed
#property indicator_style1  STYLE_SOLID
#property indicator_width1  1

//--- Inputs
input int      InpRangePeriod  = 20;   // Số nến để tính biên độ
input int      InpAvgPeriod    = 100;  // Số nến để tính trung bình biên độ
input double   InpThreshold    = 0.85; // Hệ số nén biên độ (Dưới 1.0 là nén)
input double   InpOverlapPct   = 0.60; // Tỷ lệ nến phải được revisit (0.6 = 60%)
input int      InpMinGap       = 5;    // Khoảng cách tối thiểu giữa 2 nến để tính revisit
input color    InpBoxColor     = clrDodgerBlue; // Màu của hộp range
input int      InpBoxWidth     = 1;    // Độ dày viền hộp
input int      InpEmaPeriod    = 25;   // EMA Period

//--- Buffers
double         EmaBuffer[];
double         RangeBuffer[];     // 0.0 = not range, 1.0 = range
double         AvgRangeBuffer[];  // Cache average range
int            ema_handle;

//--- Global tracking for merge optimization
int            g_current_box_start = -1;

//+------------------------------------------------------------------+
//| Custom indicator initialization function                         |
//+------------------------------------------------------------------+
int OnInit()
{
   SetIndexBuffer(0, EmaBuffer, INDICATOR_DATA);
   SetIndexBuffer(1, RangeBuffer, INDICATOR_CALCULATIONS);
   SetIndexBuffer(2, AvgRangeBuffer, INDICATOR_CALCULATIONS);
   
   PlotIndexSetDouble(0, PLOT_EMPTY_VALUE, 0.0);
   PlotIndexSetString(0, PLOT_LABEL, "EMA");
   
   ArraySetAsSeries(EmaBuffer, false);
   ArraySetAsSeries(RangeBuffer, false);
   ArraySetAsSeries(AvgRangeBuffer, false);
   
   IndicatorSetString(INDICATOR_SHORTNAME, "Range Detector");
   
   ema_handle = iMA(NULL, 0, InpEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if(ema_handle == INVALID_HANDLE)
   {
      Print("Failed to create EMA handle");
      return(INIT_FAILED);
   }
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Custom indicator deinitialization function                       |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   ObjectsDeleteAll(0, "RangeBox_");
   IndicatorRelease(ema_handle);
}

//+------------------------------------------------------------------+
//| Calculate range (high-low) for a window ending at 'bar'          |
//+------------------------------------------------------------------+
double CalcBarRange(const double &high[], const double &low[], int bar, int period)
{
   int from = bar - period + 1;
   if(from < 0) from = 0;
   int cnt = bar - from + 1;
   
   int hi = ArrayMaximum(high, from, cnt);
   int lo = ArrayMinimum(low, from, cnt);
   return high[hi] - low[lo];
}

//+------------------------------------------------------------------+
//| Overlap/Revisit test                                             |
//| For each candle j in the window, check if at least one candle k  |
//| that is far enough away (|k-j| >= min_gap) has overlapping       |
//| high-low range with candle j.                                    |
//|                                                                  |
//| In a TREND: early candles and late candles DON'T overlap          |
//|   (price moved away) -> low overlap ratio                        |
//| In a RANGE: candles revisit each other's zone -> high overlap    |
//+------------------------------------------------------------------+
double CalcOverlapRatio(const double &high[], const double &low[],
                        int bar, int period, int min_gap)
{
   int from = bar - period + 1;
   if(from < 0) from = 0;
   int cnt = bar - from + 1;
   if(cnt <= min_gap) return 0.0;
   
   int revisited = 0;
   
   for(int j = from; j <= bar; j++)
   {
      double h_j = high[j];
      double l_j = low[j];
      bool has_distant_overlap = false;
      
      for(int k = from; k <= bar; k++)
      {
         // Only check candles that are far enough apart
         if(MathAbs(k - j) < min_gap) continue;
         
         // Two candle ranges overlap if:
         // candle k's low <= candle j's high AND candle k's high >= candle j's low
         if(low[k] <= h_j && high[k] >= l_j)
         {
            has_distant_overlap = true;
            break; // One distant overlap is enough
         }
      }
      
      if(has_distant_overlap) revisited++;
   }
   
   return (double)revisited / cnt;
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
   int min_bars = MathMax(InpRangePeriod + InpAvgPeriod, InpEmaPeriod);
   if(rates_total < min_bars) return(0);
   
   // Copy EMA data
   if(CopyBuffer(ema_handle, 0, 0, rates_total, EmaBuffer) <= 0) return(0);

   int start = prev_calculated - 1;
   if(start < min_bars) start = min_bars;
   
   // Reset box tracking if recalculating from scratch
   if(prev_calculated == 0)
      g_current_box_start = -1;

   for(int i = start; i < rates_total; i++)
   {
      //=== 1. Current range ===
      double current_range = CalcBarRange(high, low, i, InpRangePeriod);

      //=== 2. Average range (incremental when possible) ===
      double avg_range;
      if(i > start && AvgRangeBuffer[i-1] > 0)
      {
         double old_val = CalcBarRange(high, low, i - InpAvgPeriod, InpRangePeriod);
         double new_val = current_range;
         avg_range = AvgRangeBuffer[i-1] + (new_val - old_val) / InpAvgPeriod;
      }
      else
      {
         double total = 0;
         for(int j = 0; j < InpAvgPeriod; j++)
            total += CalcBarRange(high, low, i - j, InpRangePeriod);
         avg_range = total / InpAvgPeriod;
      }
      AvgRangeBuffer[i] = avg_range;

      //=== 3. Range detection: squeeze + overlap ===
      bool cond_squeeze = (current_range < avg_range * InpThreshold);
      
      // Overlap test: check if candles revisit each other's zones
      double overlap = CalcOverlapRatio(high, low, i, InpRangePeriod, InpMinGap);
      bool cond_overlap = (overlap >= InpOverlapPct);
      
      // Must pass BOTH conditions:
      // 1) Biên độ nén (squeeze) -> giá không di chuyển nhiều
      // 2) Giá đi qua lại (overlap) -> không phải trend nhỏ
      bool is_range = cond_squeeze && cond_overlap;
         
      RangeBuffer[i] = is_range ? 1.0 : 0.0;

      //=== 4. Box management ===
      if(is_range)
      {
         if(i > 0 && RangeBuffer[i-1] != 0.0 && g_current_box_start >= 0)
         {
            // --- Extend existing box ---
            string obj_name = "RangeBox_" + IntegerToString(time[g_current_box_start]);
            
            if(ObjectFind(0, obj_name) >= 0)
            {
               ObjectSetInteger(0, obj_name, OBJPROP_TIME, 1, time[i]);
               
               double cur_h = ObjectGetDouble(0, obj_name, OBJPROP_PRICE, 0);
               double cur_l = ObjectGetDouble(0, obj_name, OBJPROP_PRICE, 1);
               if(high[i] > cur_h) ObjectSetDouble(0, obj_name, OBJPROP_PRICE, 0, high[i]);
               if(low[i]  < cur_l) ObjectSetDouble(0, obj_name, OBJPROP_PRICE, 1, low[i]);
            }
            else
            {
               int box_from = MathMax(0, g_current_box_start - InpRangePeriod + 1);
               int hi = ArrayMaximum(high, box_from, i - box_from + 1);
               int lo = ArrayMinimum(low, box_from, i - box_from + 1);
               CreateBox(obj_name, time[box_from], high[hi], time[i], low[lo]);
            }
         }
         else
         {
            // --- New box ---
            g_current_box_start = i;
            string obj_name = "RangeBox_" + IntegerToString(time[i]);
            
            int hi_idx = ArrayMaximum(high, i - InpRangePeriod + 1, InpRangePeriod);
            int lo_idx = ArrayMinimum(low, i - InpRangePeriod + 1, InpRangePeriod);
            
            if(ObjectFind(0, obj_name) < 0)
               CreateBox(obj_name, time[i - InpRangePeriod + 1], high[hi_idx], time[i], low[lo_idx]);
            else
            {
               ObjectSetDouble(0, obj_name, OBJPROP_PRICE, 0, high[hi_idx]);
               ObjectSetDouble(0, obj_name, OBJPROP_PRICE, 1, low[lo_idx]);
               ObjectSetInteger(0, obj_name, OBJPROP_TIME, 0, time[i - InpRangePeriod + 1]);
               ObjectSetInteger(0, obj_name, OBJPROP_TIME, 1, time[i]);
            }
         }
      }
      else
      {
         g_current_box_start = -1;
      }
   }
   
   CleanupOldBoxes();

   return(rates_total);
}

//+------------------------------------------------------------------+
//| Create a range box with standard properties                      |
//+------------------------------------------------------------------+
void CreateBox(string name, datetime t1, double price1, datetime t2, double price2)
{
   ObjectCreate(0, name, OBJ_RECTANGLE, 0, t1, price1, t2, price2);
   ObjectSetInteger(0, name, OBJPROP_COLOR, InpBoxColor);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, InpBoxWidth);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetInteger(0, name, OBJPROP_FILL, false);
}

//+------------------------------------------------------------------+
//| Keep only the latest N boxes                                     |
//+------------------------------------------------------------------+
void CleanupOldBoxes()
{
   int max_boxes = 50;
   int total = ObjectsTotal(0, -1, -1);
   string names[];
   int count = 0;
   
   ArrayResize(names, total);
   
   for(int i = 0; i < total; i++)
   {
      string name = ObjectName(0, i, -1, -1);
      if(StringFind(name, "RangeBox_") == 0)
      {
         names[count] = name;
         count++;
      }
   }
   
   if(count > max_boxes)
   {
      ArrayResize(names, count);
      ArraySort(names);
      int delete_count = count - max_boxes;
      for(int i = 0; i < delete_count; i++)
         ObjectDelete(0, names[i]);
   }
}