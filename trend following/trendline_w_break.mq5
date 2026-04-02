//+------------------------------------------------------------------+
//|                                         trendline_w_break.mq5    |
//|                    Based on LuxAlgo Trendlines with Breaks       |
//|                                  Copyright 2024, Antigravity IDE |
//+------------------------------------------------------------------+
#property copyright "Antigravity IDE"
#property version   "1.00"

#include <Trade\Trade.mqh>

//--- Input Parameters
input int    InpSwingLength   = 14;   // Swing Detection Lookback
input double InpSlopeMult     = 1.0;  // Slope Multiplier
input int    InpEMAPeriod     = 21;   // EMA Filter Period
input int    InpATRPeriod     = 14;   // ATR Period
input double InpATRMult       = 1.5;  // ATR Multiplier for SL
input double InpLotSize       = 0.01; // Lot Size

//--- Global Variables
CTrade trade;
int    ema_handle, atr_handle;
double ema_buf[], atr_buf[];

// Trendline state
double upper_tl, lower_tl;
double slope_ph, slope_pl;
int    upos_prev, dnos_prev;
bool   tl_initialized;

// Pivot history buffers
double high_buf[], low_buf[], close_buf[];
double atr_slope_buf[];

//+------------------------------------------------------------------+
int OnInit()
  {
   ema_handle = iMA(_Symbol, PERIOD_CURRENT, InpEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   atr_handle = iATR(_Symbol, PERIOD_CURRENT, InpATRPeriod);
   if(ema_handle == INVALID_HANDLE || atr_handle == INVALID_HANDLE)
     {
      Print("ERROR: Indicator init failed");
      return(INIT_FAILED);
     }
   ArraySetAsSeries(ema_buf, true);
   ArraySetAsSeries(atr_buf, true);
   
   upper_tl = 0; lower_tl = 0;
   slope_ph = 0; slope_pl = 0;
   upos_prev = 0; dnos_prev = 0;
   tl_initialized = false;
   
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   IndicatorRelease(ema_handle);
   IndicatorRelease(atr_handle);
  }

//+------------------------------------------------------------------+
// Detect Pivot High at shift = InpSwingLength (confirmed pivot)
//+------------------------------------------------------------------+
double DetectPivotHigh(int lookback)
  {
   int center = lookback; // The bar we're checking
   double center_high = iHigh(_Symbol, PERIOD_CURRENT, center);
   
   for(int i = center - lookback; i <= center + lookback; i++)
     {
      if(i == center || i < 0) continue;
      if(iHigh(_Symbol, PERIOD_CURRENT, i) > center_high)
         return 0; // Not a pivot
     }
   return center_high;
  }

//+------------------------------------------------------------------+
// Detect Pivot Low at shift = InpSwingLength (confirmed pivot)
//+------------------------------------------------------------------+
double DetectPivotLow(int lookback)
  {
   int center = lookback;
   double center_low = iLow(_Symbol, PERIOD_CURRENT, center);
   
   for(int i = center - lookback; i <= center + lookback; i++)
     {
      if(i == center || i < 0) continue;
      if(iLow(_Symbol, PERIOD_CURRENT, i) < center_low)
         return 0; // Not a pivot
     }
   return center_low;
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   // Only process on new bar
   static datetime last_bar = 0;
   datetime cur_bar = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(cur_bar == last_bar) return;
   last_bar = cur_bar;
   
   // Get indicator values
   if(CopyBuffer(ema_handle, 0, 0, 3, ema_buf) < 3) return;
   if(CopyBuffer(atr_handle, 0, 0, 3, atr_buf) < 3) return;
   
   double ema_val = ema_buf[1]; // Completed bar
   double atr_val = atr_buf[1];
   double cur_close = iClose(_Symbol, PERIOD_CURRENT, 1);
   
   //--- Calculate slope using ATR method (same as Pine)
   double slope = atr_val / InpSwingLength * InpSlopeMult;
   
   //--- Detect pivots
   double ph = DetectPivotHigh(InpSwingLength);
   double pl = DetectPivotLow(InpSwingLength);
   
   //--- Update trendline slopes and values
   if(ph > 0)
     {
      slope_ph = slope;
      upper_tl = ph;
      tl_initialized = true;
     }
   else
      upper_tl = upper_tl - slope_ph;
      
   if(pl > 0)
     {
      slope_pl = slope;
      lower_tl = pl;
      tl_initialized = true;
     }
   else
      lower_tl = lower_tl + slope_pl;
   
   if(!tl_initialized) return;
   
   //--- Breakout detection (real-time, no backpaint)
   double upper_rt = upper_tl - slope_ph * InpSwingLength;
   double lower_rt = lower_tl + slope_pl * InpSwingLength;
   
   int upos_cur = (ph > 0) ? 0 : (cur_close > upper_rt ? 1 : upos_prev);
   int dnos_cur = (pl > 0) ? 0 : (cur_close < lower_rt ? 1 : dnos_prev);
   
   bool upward_break   = (upos_cur > upos_prev); // Price broke down-trendline upward => BUY
   bool downward_break  = (dnos_cur > dnos_prev); // Price broke up-trendline downward => SELL
   
   //--- Draw trendlines on chart
   DrawTrendlines(upper_rt, lower_rt);
   
   //--- EMA filter
   bool above_ema = (cur_close > ema_val);
   bool below_ema = (cur_close < ema_val);
   
   //--- Only 1 position at a time
   bool has_position = (PositionsTotal() > 0);
   
   //--- BUY Signal: Upward breakout + Price > EMA
   if(upward_break && above_ema && !has_position)
     {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double sl_dist = atr_val * InpATRMult;
      double tp_dist = sl_dist * 2.0; // RR 2:1
      double sl = NormalizeDouble(ask - sl_dist, _Digits);
      double tp = NormalizeDouble(ask + tp_dist, _Digits);
      
      if(trade.Buy(InpLotSize, _Symbol, ask, sl, tp, "TL Break BUY"))
         DrawSignal(iTime(_Symbol, PERIOD_CURRENT, 1), iLow(_Symbol, PERIOD_CURRENT, 1),
                    true, ask, sl, tp);
     }
   
   //--- SELL Signal: Downward breakout + Price < EMA
   if(downward_break && below_ema && !has_position)
     {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double sl_dist = atr_val * InpATRMult;
      double tp_dist = sl_dist * 2.0; // RR 2:1
      double sl = NormalizeDouble(bid + sl_dist, _Digits);
      double tp = NormalizeDouble(bid - tp_dist, _Digits);
      
      if(trade.Sell(InpLotSize, _Symbol, bid, sl, tp, "TL Break SELL"))
         DrawSignal(iTime(_Symbol, PERIOD_CURRENT, 1), iHigh(_Symbol, PERIOD_CURRENT, 1),
                    false, bid, sl, tp);
     }
   
   //--- Save state for next bar
   upos_prev = upos_cur;
   dnos_prev = dnos_cur;
  }

//+------------------------------------------------------------------+
// Draw visual signal markers on chart
//+------------------------------------------------------------------+
void DrawSignal(datetime time, double price, bool is_buy, 
                double entry, double sl, double tp)
  {
   static int signal_id = 0;
   signal_id++;
   
   string prefix = "TLB_" + IntegerToString(signal_id);
   
   // Entry arrow
   string arrow_name = prefix + "_ENTRY";
   if(is_buy)
     {
      ObjectCreate(0, arrow_name, OBJ_ARROW_BUY, 0, time, price);
      ObjectSetInteger(0, arrow_name, OBJPROP_COLOR, clrDodgerBlue);
     }
   else
     {
      ObjectCreate(0, arrow_name, OBJ_ARROW_SELL, 0, time, price);
      ObjectSetInteger(0, arrow_name, OBJPROP_COLOR, clrOrangeRed);
     }
   ObjectSetInteger(0, arrow_name, OBJPROP_WIDTH, 2);
   
   // TP line (green dashed)
   string tp_name = prefix + "_TP";
   datetime tp_end = time + PeriodSeconds() * 20;
   ObjectCreate(0, tp_name, OBJ_TREND, 0, time, tp, tp_end, tp);
   ObjectSetInteger(0, tp_name, OBJPROP_COLOR, clrLime);
   ObjectSetInteger(0, tp_name, OBJPROP_STYLE, STYLE_DOT);
   ObjectSetInteger(0, tp_name, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, tp_name, OBJPROP_RAY_RIGHT, false);
   
   // SL line (red dashed)
   string sl_name = prefix + "_SL";
   ObjectCreate(0, sl_name, OBJ_TREND, 0, time, sl, tp_end, sl);
   ObjectSetInteger(0, sl_name, OBJPROP_COLOR, clrRed);
   ObjectSetInteger(0, sl_name, OBJPROP_STYLE, STYLE_DOT);
   ObjectSetInteger(0, sl_name, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, sl_name, OBJPROP_RAY_RIGHT, false);
   
   // Entry line (white)
   string entry_name = prefix + "_LVL";
   ObjectCreate(0, entry_name, OBJ_TREND, 0, time, entry, tp_end, entry);
   ObjectSetInteger(0, entry_name, OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, entry_name, OBJPROP_STYLE, STYLE_DASH);
   ObjectSetInteger(0, entry_name, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, entry_name, OBJPROP_RAY_RIGHT, false);
   
   // Text label
   string txt_name = prefix + "_TXT";
   string label = is_buy ? "BUY" : "SELL";
   ObjectCreate(0, txt_name, OBJ_TEXT, 0, time, is_buy ? price - 10*_Point : price + 10*_Point);
   ObjectSetString(0, txt_name, OBJPROP_TEXT, label);
   ObjectSetInteger(0, txt_name, OBJPROP_COLOR, is_buy ? clrDodgerBlue : clrOrangeRed);
   ObjectSetInteger(0, txt_name, OBJPROP_FONTSIZE, 8);
  }

//+------------------------------------------------------------------+
// Draw trendlines on chart
//+------------------------------------------------------------------+
void DrawTrendlines(double upper_rt, double lower_rt)
  {
   datetime t0 = iTime(_Symbol, PERIOD_CURRENT, 1);
   datetime t1 = iTime(_Symbol, PERIOD_CURRENT, 0);
   
   // Upper trendline (down-trend = resistance)
   string up_name = "TLB_UPPER";
   ObjectDelete(0, up_name);
   ObjectCreate(0, up_name, OBJ_TREND, 0, t0, upper_rt + slope_ph, t1, upper_rt);
   ObjectSetInteger(0, up_name, OBJPROP_COLOR, clrOrangeRed);
   ObjectSetInteger(0, up_name, OBJPROP_STYLE, STYLE_SOLID);
   ObjectSetInteger(0, up_name, OBJPROP_WIDTH, 2);
   ObjectSetInteger(0, up_name, OBJPROP_RAY_RIGHT, true);
   
   // Lower trendline (up-trend = support)
   string dn_name = "TLB_LOWER";
   ObjectDelete(0, dn_name);
   ObjectCreate(0, dn_name, OBJ_TREND, 0, t0, lower_rt - slope_pl, t1, lower_rt);
   ObjectSetInteger(0, dn_name, OBJPROP_COLOR, clrTeal);
   ObjectSetInteger(0, dn_name, OBJPROP_STYLE, STYLE_SOLID);
   ObjectSetInteger(0, dn_name, OBJPROP_WIDTH, 2);
   ObjectSetInteger(0, dn_name, OBJPROP_RAY_RIGHT, true);
  }
//+------------------------------------------------------------------+