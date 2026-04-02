//+------------------------------------------------------------------+
//|                                        RangeBreakout_CVD_EA.mq5  |
//| Range Breakout + Detrended CVD Filter                            |
//+------------------------------------------------------------------+
#property copyright "Vu"
#property link      ""
#property version   "1.00"
#property description "Range Breakout EA with Detrended CVD Z-Score Filter"

#include <Trade\Trade.mqh>
CTrade trade;

//=== CÀI ĐẶT CƠ BẢN ===
input group "=== CÀI ĐẶT CƠ BẢN ==="
input double               InpLotSize           = 0.01;         // Khối lượng (Lot Size)
input ulong                InpMagicNumber       = 889900;       // Magic Number

//=== BỘ LỌC XU HƯỚNG (EMA D1) ===
input group "=== BỘ LỌC XU HƯỚNG ==="
input ENUM_TIMEFRAMES      InpFilterTimeframe   = PERIOD_D1;    // Khung thời gian Xu hướng (D1)
input int                  InpEMAPeriod         = 100;          // Chu kỳ EMA Filter

//=== LOGIC RANGE DETECTOR ===
input group "=== LOGIC RANGE DETECTOR ==="
input ENUM_TIMEFRAMES      InpRangeTimeframe    = PERIOD_H1;    // Khung thời gian Range (H1)
input int                  InpRangePeriod       = 20;           // Số nến để tính biên độ hộp
input int                  InpAvgPeriod         = 100;          // Số nến trung bình
input double               InpThreshold         = 0.85;         // Hệ số nén
input double               InpOverlapPct        = 0.60;         // Tỷ lệ overlap (%)
input int                  InpMinGap            = 5;            // Khoảng cách overlap tối thiểu

//=== BỘ LỌC CVD (DETRENDED Z-SCORE) ===
input group "=== BỘ LỌC CVD ==="
input int                  InpCVDLength         = 100;          // CVD Z-Score Window Size
input int                  InpCVDSignalEma      = 9;            // CVD Signal Line EMA Period
input bool                 InpCVDUseRealVol     = false;        // CVD: Dùng Real Volume (False = Tick Volume)

//=== STOP LOSS & TRAILING ===
input group "=== STOP LOSS & TRAILING ==="
input int                  InpATRPeriod         = 14;           // Chu kỳ ATR
input double               InpSLMultiplier      = 1.5;          // Hệ số SL theo ATR
input int                  InpTrailEMAPeriod    = 21;           // Chu kỳ EMA dùng để Trailing TP

//--- Indicator Handles
int h_ema_filter;
int h_atr;
int h_ema_trail;

//--- CVD Internal Buffers (tự tính, không cần indicator riêng)
double g_cvd_raw[];       // Raw CVD tích lũy
int    g_cvd_size;        // Kích thước buffer đã tính
datetime g_cvd_last_time; // Thời gian bar cuối đã tính CVD

//+------------------------------------------------------------------+
//| Helper: Range calculation                                         |
//+------------------------------------------------------------------+
double CalcBarRange(ENUM_TIMEFRAMES tf, int bar, int period)
{
   double high[], low[];
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   if(CopyHigh(_Symbol, tf, bar, period, high) < period) return 0;
   if(CopyLow(_Symbol, tf, bar, period, low) < period) return 0;
   
   int hi_idx = ArrayMaximum(high);
   int lo_idx = ArrayMinimum(low);
   return high[hi_idx] - low[lo_idx];
}

//+------------------------------------------------------------------+
//| Overlap check for Range Detection                                 |
//+------------------------------------------------------------------+
double CalcOverlapRatio(ENUM_TIMEFRAMES tf, int bar, int period, int min_gap)
{
   double high[], low[];
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   if(CopyHigh(_Symbol, tf, bar, period, high) < period) return 0;
   if(CopyLow(_Symbol, tf, bar, period, low) < period) return 0;
   
   int cnt = period;
   if(cnt <= min_gap) return 0.0;
   
   int revisited = 0;
   
   for(int j = 0; j < cnt; j++)
   {
      double h_j = high[j];
      double l_j = low[j];
      bool has_distant_overlap = false;
      
      for(int k = 0; k < cnt; k++)
      {
         if(MathAbs(k - j) < min_gap) continue;
         
         if(low[k] <= h_j && high[k] >= l_j)
         {
            has_distant_overlap = true;
            break;
         }
      }
      if(has_distant_overlap) revisited++;
   }
   
   return (double)revisited / cnt;
}

//+------------------------------------------------------------------+
//| Get highest/lowest of current range period                        |
//+------------------------------------------------------------------+
void GetRangeExtremes(ENUM_TIMEFRAMES tf, int bar, int period, double &range_high, double &range_low)
{
   range_high = 0; range_low = 0;
   double high[], low[];
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   if(CopyHigh(_Symbol, tf, bar, period, high) < period) return;
   if(CopyLow(_Symbol, tf, bar, period, low) < period) return;
   
   int hi_idx = ArrayMaximum(high);
   int lo_idx = ArrayMinimum(low);
   
   range_high = high[hi_idx];
   range_low = low[lo_idx];
}

//+------------------------------------------------------------------+
//| Tính CVD Z-Score trực tiếp từ dữ liệu giá                       |
//| Trả về z_score của CVD, dùng làm bộ lọc                          |
//+------------------------------------------------------------------+
double GetCVDZScore()
{
   // Cần ít nhất InpCVDLength + 1 nến trên khung Range
   int bars_needed = InpCVDLength + 10;
   
   double open_arr[], close_arr[], high_arr[], low_arr[];
   long   tick_vol[], real_vol[];
   
   ArraySetAsSeries(open_arr, true);
   ArraySetAsSeries(close_arr, true);
   ArraySetAsSeries(high_arr, true);
   ArraySetAsSeries(low_arr, true);
   ArraySetAsSeries(tick_vol, true);
   ArraySetAsSeries(real_vol, true);
   
   if(CopyOpen(_Symbol, InpRangeTimeframe, 0, bars_needed, open_arr) < bars_needed) return 0.0;
   if(CopyClose(_Symbol, InpRangeTimeframe, 0, bars_needed, close_arr) < bars_needed) return 0.0;
   if(CopyTickVolume(_Symbol, InpRangeTimeframe, 0, bars_needed, tick_vol) < bars_needed) return 0.0;
   
   if(InpCVDUseRealVol)
   {
      if(CopyRealVolume(_Symbol, InpRangeTimeframe, 0, bars_needed, real_vol) < bars_needed)
      {
         // Fallback to tick volume
         ArrayResize(real_vol, bars_needed);
         for(int i = 0; i < bars_needed; i++) real_vol[i] = tick_vol[i];
      }
   }
   
   // === 1. Tính Raw CVD (tích lũy từ cũ đến mới) ===
   // Dữ liệu AsSeries: index 0 = bar hiện tại, index bars_needed-1 = bar cũ nhất
   // Tính từ cũ → mới
   double cvd_buffer[];
   ArrayResize(cvd_buffer, bars_needed);
   
   double cumulative = 0.0;
   for(int i = bars_needed - 1; i >= 0; i--)
   {
      double vol = InpCVDUseRealVol ? (double)real_vol[i] : (double)tick_vol[i];
      double tick_delta = 0.0;
      
      if(close_arr[i] > open_arr[i])
         tick_delta = vol;
      else if(close_arr[i] < open_arr[i])
         tick_delta = -vol;
      
      cumulative += tick_delta;
      cvd_buffer[i] = cumulative;  // index 0 = mới nhất
   }
   
   // === 2. Tính Z-Score trên bar[1] (bar đã đóng) ===
   // Cần window từ bar[1] đến bar[InpCVDLength]
   if(bars_needed < InpCVDLength + 1) return 0.0;
   
   // Tính mean và std của CVD trong window [1 .. InpCVDLength]
   double sum = 0.0;
   for(int j = 1; j <= InpCVDLength; j++)
      sum += cvd_buffer[j];
   
   double mean_cvd = sum / InpCVDLength;
   
   double sum_sq = 0.0;
   for(int j = 1; j <= InpCVDLength; j++)
   {
      double d = cvd_buffer[j] - mean_cvd;
      sum_sq += d * d;
   }
   
   double std_cvd = MathSqrt(sum_sq / InpCVDLength);
   
   if(std_cvd <= 0.0) return 0.0;
   
   double z_score = (cvd_buffer[1] - mean_cvd) / std_cvd;
   
   return z_score;
}

//+------------------------------------------------------------------+
//| Expert initialization function                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   
   h_ema_filter = iMA(_Symbol, InpFilterTimeframe, InpEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   h_atr        = iATR(_Symbol, InpRangeTimeframe, InpATRPeriod);
   h_ema_trail  = iMA(_Symbol, InpRangeTimeframe, InpTrailEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   
   if(h_ema_filter == INVALID_HANDLE || h_atr == INVALID_HANDLE || h_ema_trail == INVALID_HANDLE)
   {
      Print("Failed to initialize indicators");
      return INIT_FAILED;
   }
   
   Print("RangeBreakout + CVD Filter EA initialized successfully");
   Print("CVD Filter: Buy khi Z-Score > 0 (CVD dương), Sell khi Z-Score < 0 (CVD âm)");
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(h_ema_filter != INVALID_HANDLE) IndicatorRelease(h_ema_filter);
   if(h_atr != INVALID_HANDLE)        IndicatorRelease(h_atr);
   if(h_ema_trail != INVALID_HANDLE)  IndicatorRelease(h_ema_trail);
}

//+------------------------------------------------------------------+
//| New Bar check                                                      |
//+------------------------------------------------------------------+
bool IsNewBar(ENUM_TIMEFRAMES tf)
{
   static datetime last_time = 0;
   datetime current_time = iTime(_Symbol, tf, 0);
   if(current_time != last_time)
   {
      if(last_time == 0)
      {
         last_time = current_time;
         return false;
      }
      last_time = current_time;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Main logic tick                                                    |
//+------------------------------------------------------------------+
void OnTick()
{
   // Manage Trailing stop via EMA 21 every tick for precision
   ManageEMATrailingStop();
   
   // Create signals and pending orders only on new candle
   if(!IsNewBar(InpRangeTimeframe)) return;
   
   double ema_filter_arr[], atr_arr[];
   if(CopyBuffer(h_ema_filter, 0, 1, 1, ema_filter_arr) <= 0) return;
   if(CopyBuffer(h_atr, 0, 1, 1, atr_arr) <= 0) return;
   
   double ema_filter = ema_filter_arr[0];
   double current_atr = atr_arr[0];
   
   // --- Component 1: Bộ lọc Xu hướng (EMA D1) ---
   double close_current = iClose(_Symbol, InpFilterTimeframe, 1);
   bool is_bullish = close_current > ema_filter;
   bool is_bearish = close_current < ema_filter;
   
   // --- Component 2: CVD Z-Score Filter ---
   double cvd_zscore = GetCVDZScore();
   bool cvd_bullish = (cvd_zscore > 0.0);   // CVD dương → cho phép Buy
   bool cvd_bearish = (cvd_zscore < 0.0);   // CVD âm    → cho phép Sell
   
   // Log CVD status
   static datetime last_log_time = 0;
   datetime now = TimeCurrent();
   if(now - last_log_time >= 3600) // Log mỗi giờ
   {
      Print(StringFormat("CVD Z-Score: %.2f | Bullish Filter: %s | Bearish Filter: %s",
            cvd_zscore, 
            cvd_bullish ? "ON" : "OFF", 
            cvd_bearish ? "ON" : "OFF"));
      last_log_time = now;
   }
   
   // --- Component 3: Range Detection Logic ---
   double current_range = CalcBarRange(InpRangeTimeframe, 1, InpRangePeriod);
   
   double sum_range = 0;
   for(int i = 0; i < InpAvgPeriod; i++)
   {
      sum_range += CalcBarRange(InpRangeTimeframe, 1 + i, InpRangePeriod);
   }
   double avg_range = sum_range / InpAvgPeriod;
   
   bool cond_squeeze = false;
   if(avg_range > 0) cond_squeeze = (current_range < avg_range * InpThreshold);
   
   double overlap = CalcOverlapRatio(InpRangeTimeframe, 1, InpRangePeriod, InpMinGap);
   bool cond_overlap = (overlap >= InpOverlapPct);
   
   bool is_ranging = cond_squeeze && cond_overlap;
   
   int pos_count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber) pos_count++;
   }

   // --- Placing Pending Orders ---
   if(pos_count == 0)
   {
      // Remove stale orders first
      for(int i = OrdersTotal() - 1; i >= 0; i--)
      {
         ulong pkt = OrderGetTicket(i);
         if(OrderGetString(ORDER_SYMBOL) == _Symbol && OrderGetInteger(ORDER_MAGIC) == InpMagicNumber)
         {
             trade.OrderDelete(pkt);
         }
      }
       
      if(is_ranging)
      {
         double r_high, r_low;
         GetRangeExtremes(InpRangeTimeframe, 1, InpRangePeriod, r_high, r_low);
         
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double stoplevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
         if(stoplevel == 0) stoplevel = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * _Point * 2;
         
         // === BUY: EMA Bullish + CVD Dương ===
         if(is_bullish && cvd_bullish && r_high > 0)
         {
            double entry_price = NormalizeDouble(r_high, _Digits);
            double stop_loss = NormalizeDouble(entry_price - (InpSLMultiplier * current_atr), _Digits);
            
            if(ask < entry_price - stoplevel)
            {
               trade.BuyStop(InpLotSize, entry_price, _Symbol, stop_loss, 0, ORDER_TIME_GTC, 0, 
                             StringFormat("RB+CVD Buy|Z:%.2f", cvd_zscore));
            }
         }
         // === SELL: EMA Bearish + CVD Âm ===
         else if(is_bearish && cvd_bearish && r_low > 0)
         {
            double entry_price = NormalizeDouble(r_low, _Digits);
            double stop_loss = NormalizeDouble(entry_price + (InpSLMultiplier * current_atr), _Digits);
            
            if(bid > entry_price + stoplevel)
            {
               trade.SellStop(InpLotSize, entry_price, _Symbol, stop_loss, 0, ORDER_TIME_GTC, 0, 
                              StringFormat("RB+CVD Sell|Z:%.2f", cvd_zscore));
            }
         }
      }
   }
   else
   {
       // If we have an open position, delete any remaining pending orders
      for(int i = OrdersTotal() - 1; i >= 0; i--)
      {
         ulong pkt = OrderGetTicket(i);
         if(OrderGetString(ORDER_SYMBOL) == _Symbol && OrderGetInteger(ORDER_MAGIC) == InpMagicNumber)
         {
             trade.OrderDelete(pkt);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Manage EMA Trailing Stop                                          |
//+------------------------------------------------------------------+
void ManageEMATrailingStop()
{
   double ema_trail_arr[];
   if(CopyBuffer(h_ema_trail, 0, 1, 1, ema_trail_arr) <= 0) return;
   double ema_trail = ema_trail_arr[0];
   
   double stoplevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   if(stoplevel == 0) stoplevel = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * _Point * 2;
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
      {
         ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         double current_sl = PositionGetDouble(POSITION_SL);
         
         if(type == POSITION_TYPE_BUY)
         {
            double new_sl = NormalizeDouble(ema_trail, _Digits);
            if(current_sl == 0 || new_sl > current_sl + _Point)
            {
               double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
               if(new_sl <= bid - stoplevel)
               {
                  trade.PositionModify(ticket, new_sl, 0);
               }
               else if(new_sl >= bid)
               {
                  trade.PositionClose(ticket);
               }
            }
         }
         else if(type == POSITION_TYPE_SELL)
         {
            double new_sl = NormalizeDouble(ema_trail, _Digits);
            if(current_sl == 0 || new_sl < current_sl - _Point)
            {
               double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
               if(new_sl >= ask + stoplevel)
               {
                  trade.PositionModify(ticket, new_sl, 0);
               }
               else if(new_sl <= ask)
               {
                  trade.PositionClose(ticket);
               }
            }
         }
      }
   }
}
//+------------------------------------------------------------------+
