//+------------------------------------------------------------------+
//|                                                EMM_Indicator.mq5 |
//|                                     Copyright 2026, Antigravity  |
//+------------------------------------------------------------------+
#property copyright   "Copyright 2026, Antigravity"
#property link        ""
#property version     "1.00"

#property indicator_chart_window
#property indicator_buffers 4
#property indicator_plots   4

//--- plot EMM
#property indicator_label1  "EMM"
#property indicator_type1   DRAW_LINE
#property indicator_color1  clrYellow
#property indicator_style1  STYLE_SOLID
#property indicator_width1  2

//--- plot HTF EMM 
#property indicator_label2  "HTF EMM"
#property indicator_type2   DRAW_LINE
#property indicator_color2  clrMagenta
#property indicator_style2  STYLE_SOLID
#property indicator_width2  2

//--- plot Buy Arrow
#property indicator_label3  "Buy Signal"
#property indicator_type3   DRAW_ARROW
#property indicator_color3  clrLime
#property indicator_width3  2

//--- plot Sell Arrow
#property indicator_label4  "Sell Signal"
#property indicator_type4   DRAW_ARROW
#property indicator_color4  clrRed
#property indicator_width4  2

//--- input parameters
input int      InpEmmLength     = 20;            // Chiều dài EMM (Length)
input int      InpEmmWindow     = 100;           // Cửa sổ nến (Lookback)
input bool     InpUseHtfFilter  = true;          // Dùng bộ lọc Khung Thời Gian Lớn (HTF)
input ENUM_TIMEFRAMES InpHtfTimeframe = PERIOD_H4; // Khung thời gian lớn (HTF)
input int      InpHtfEmmLength  = 50;            // Chiều dài HTF EMM Length

//--- indicator buffers
double         EMMBuffer[];
double         HTFBuffer[];
double         BuyBuffer[];
double         SellBuffer[];

struct EMMData
  {
   double price;
   double weight;
  };

//+------------------------------------------------------------------+
//| Custom indicator initialization function                         |
//+------------------------------------------------------------------+
int OnInit()
  {
   SetIndexBuffer(0, EMMBuffer, INDICATOR_DATA);
   SetIndexBuffer(1, HTFBuffer, INDICATOR_DATA);
   SetIndexBuffer(2, BuyBuffer, INDICATOR_DATA);
   SetIndexBuffer(3, SellBuffer, INDICATOR_DATA);
   
   PlotIndexSetInteger(2, PLOT_ARROW, 233);
   PlotIndexSetInteger(3, PLOT_ARROW, 234);
   
   PlotIndexSetDouble(0, PLOT_EMPTY_VALUE, 0.0);
   PlotIndexSetDouble(1, PLOT_EMPTY_VALUE, 0.0);
   PlotIndexSetDouble(2, PLOT_EMPTY_VALUE, 0.0);
   PlotIndexSetDouble(3, PLOT_EMPTY_VALUE, 0.0);
   
   PlotIndexSetString(0, PLOT_LABEL, "EMM(" + IntegerToString(InpEmmLength) + ")");
   if(InpUseHtfFilter)
      PlotIndexSetString(1, PLOT_LABEL, "HTF_EMM(" + IntegerToString(InpHtfEmmLength) + ")");
   else
      PlotIndexSetInteger(1, PLOT_DRAW_TYPE, DRAW_NONE);
      
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Tính toán Exponential Moving Median (EMM)                        |
//+------------------------------------------------------------------+
double CalculateEMM(string symbol, ENUM_TIMEFRAMES timeframe, int length, int window, datetime bar_time)
  {
   if(length <= 0 || window <= 0) return 0.0;
   
   // Tìm shift tương ứng của thời gian này trên TF cần tính
   int shift = iBarShift(symbol, timeframe, bar_time, false);
   if(shift < 0) return 0.0;
   
   double close_prices[];
   ArraySetAsSeries(close_prices, true); 
   int copied = CopyClose(symbol, timeframe, shift, window, close_prices);
   if(copied <= 0) return 0.0; 
   
   int actual_window = copied;
   double alpha = 2.0 / (length + 1.0);
   
   EMMData data[];
   ArrayResize(data, actual_window);
   
   double total_w = 0.0;
   for(int i = 0; i < actual_window; i++)
     {
      data[i].price = close_prices[i];
      data[i].weight = MathPow(1.0 - alpha, i);
      total_w += data[i].weight;
     }
     
   for(int i = 1; i < actual_window; i++)
     {
      EMMData key = data[i];
      int j = i - 1;
      while(j >= 0 && data[j].price > key.price)
        {
         data[j + 1] = data[j];
         j--;
        }
      data[j + 1] = key;
     }
     
   double cum_w = 0.0;
   double target_w = total_w / 2.0;
   double median_val = data[actual_window - 1].price; 
   
   for(int i = 0; i < actual_window; i++)
     {
      cum_w += data[i].weight;
      if(cum_w >= target_w)
        {
         median_val = data[i].price;
         break;
        }
     }
     
   return median_val;
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
   if(rates_total < 1) return 0;
   
   ArraySetAsSeries(time, true);
   ArraySetAsSeries(close, true);
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   
   ArraySetAsSeries(EMMBuffer, true);
   ArraySetAsSeries(HTFBuffer, true);
   ArraySetAsSeries(BuyBuffer, true);
   ArraySetAsSeries(SellBuffer, true);
   
   int limit = rates_total - prev_calculated;
   if(limit <= 0) limit = 1; 
   if(prev_calculated == 0) limit = rates_total; 
   
   for(int i = limit - 1; i >= 0; i--)
     {
      datetime bar_time = time[i];
      
      EMMBuffer[i] = CalculateEMM(_Symbol, _Period, InpEmmLength, InpEmmWindow, bar_time);
      
      if(InpUseHtfFilter)
        {
         HTFBuffer[i] = CalculateEMM(_Symbol, InpHtfTimeframe, InpHtfEmmLength, InpEmmWindow, bar_time);
        }
      else
        {
         HTFBuffer[i] = 0.0;
        }
        
      BuyBuffer[i] = 0.0;
      SellBuffer[i] = 0.0;
      
      if(i + 1 < rates_total)
        {
         double prev_close = close[i+1];
         double prev_emm = EMMBuffer[i+1];
         double curr_close = close[i];
         double curr_emm = EMMBuffer[i];
         
         if(prev_emm != 0.0 && curr_emm != 0.0)
           {
            // Nới lỏng điều kiện Crossover: Cho phép bằng (<= hoặc >=) ở nến trước để bắt dính các nến có Close trùng khít Median
            bool cross_up = (prev_close <= prev_emm) && (curr_close > curr_emm);
            bool cross_down = (prev_close >= prev_emm) && (curr_close < curr_emm);
            
            // Nếu ngay tại nến này Close trúng khít EMM và nến trước đó đang ở đầu ngược lại thì cũng ghi nhận
            if(prev_close < prev_emm && curr_close == curr_emm) cross_up = true;
            if(prev_close > prev_emm && curr_close == curr_emm) cross_down = true;

            // Vẽ cách mức High/Low một khoảng an toàn (bằng ATR hoặc 10 pips, ở đây tính vo 15 points)
            double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
            if(cross_up) BuyBuffer[i] = low[i] - 15 * point;
            if(cross_down) SellBuffer[i] = high[i] + 15 * point;
           }
        }
     }
     
   return(rates_total);
  }
//+------------------------------------------------------------------+
