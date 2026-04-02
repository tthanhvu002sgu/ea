//+------------------------------------------------------------------+
//|                                                ema_pullback.mq5  |
//|                                  Copyright 2024, Antigravity IDE |
//|  4-Component System: Baseline → Pullback → Trailing Trap → ATR  |
//+------------------------------------------------------------------+
#property copyright "Antigravity IDE"
#property version   "1.00"

#include <Trade\Trade.mqh>

//--- Input Parameters
input int    InpEMAPeriod       = 50;    // EMA Period (Baseline)
input int    InpTrendBars       = 3;     // Minimum bars above/below EMA for trend confirmation
input int    InpHTFEMAPeriod    = 100;   // Higher Timeframe (D1) EMA filter
input int    InpATRPeriod       = 14;    // ATR Period
input double InpATRMultSL       = 1.5;   // ATR Multiplier for Stop Loss
enum ENUM_EXIT_MODE
  {
   EXIT_FIXED_TP_SL = 0, // 1. Fixed TP / SL (Default)
   EXIT_TRAILING_EMA = 1 // 2. Trailing SL via EMA
  };

input string Settings_Exit      = "=== EXIT STRATEGY ===";
input ENUM_EXIT_MODE InpExitMode = EXIT_FIXED_TP_SL; // Exit Strategy Mode
input int    InpTrailEMAPeriod  = 9;     // Trailing EMA Period (Mode 2)
input double InpRRMultTP        = 2.0;   // Risk:Reward ratio for Fixed TP (Mode 1)

input double InpLotSize         = 0.01;  // Lot Size
input int    InpMaxTrailBars    = 20;    // Max bars to trail before cancelling trap
input color  InpBuyColor        = clrDodgerBlue;  // Buy Signal Color
input color  InpSellColor       = clrOrangeRed;   // Sell Signal Color

//--- Enums for trade direction
enum ENUM_TRADE_DIRECTION
  {
   TRADE_DIR_BOTH = 0, // Both (Buy & Sell)
   TRADE_DIR_BUY  = 1, // Only Buy
   TRADE_DIR_SELL = 2  // Only Sell
  };

input ENUM_TRADE_DIRECTION InpTradeDirection = TRADE_DIR_BOTH; // Trading Mode

//--- Enums for state machine
enum ENUM_EA_STATE
  {
   STATE_IDLE      = 0, // Waiting for setup
   STATE_STALKING  = 1, // Pullback detected, placing initial trap
   STATE_TRAILING  = 2  // Trap placed, trailing pending order
  };

//--- Global Variables
CTrade         trade;
int            ema_handle, atr_handle, ema_d1_handle, ema_trail_handle;
double         ema_buf[], atr_buf[], ema_d1_buf[], ema_trail_buf[];

ENUM_EA_STATE  g_state        = STATE_IDLE;
int            g_direction    = 0;       // +1 = Buy setup, -1 = Sell setup
ulong          g_pending_ticket = 0;     // Ticket of pending Buy/Sell Stop
int            g_trail_count  = 0;       // Number of bars trailing
double         g_last_trap_price = 0;    // Current trap price for tracking
static int     g_signal_id    = 0;       // For unique object names

//+------------------------------------------------------------------+
int OnInit()
  {
   ema_handle = iMA(_Symbol, PERIOD_CURRENT, InpEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   atr_handle = iATR(_Symbol, PERIOD_CURRENT, InpATRPeriod);
   ema_d1_handle = iMA(_Symbol, PERIOD_D1, InpHTFEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   ema_trail_handle = iMA(_Symbol, PERIOD_CURRENT, InpTrailEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   
   if(ema_handle == INVALID_HANDLE || atr_handle == INVALID_HANDLE || ema_d1_handle == INVALID_HANDLE || ema_trail_handle == INVALID_HANDLE)
     {
      Print("ERROR: Indicator init failed: ", GetLastError());
      return(INIT_FAILED);
     }
   
   ArraySetAsSeries(ema_buf, true);
   ArraySetAsSeries(atr_buf, true);
   ArraySetAsSeries(ema_d1_buf, true);
   ArraySetAsSeries(ema_trail_buf, true);
   
   trade.SetDeviationInPoints(10);
   
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   IndicatorRelease(ema_handle);
   IndicatorRelease(atr_handle);
   IndicatorRelease(ema_d1_handle);
   IndicatorRelease(ema_trail_handle);
   
   // Clean up pending order if EA removed
   if(g_pending_ticket > 0)
      trade.OrderDelete(g_pending_ticket);
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   // Manage trailing continuously on every tick (if mode Trailing EMA)
   if(InpExitMode == EXIT_TRAILING_EMA)
      ManageTrailingStop();

   // Process only on new bar completion
   static datetime last_bar = 0;
   datetime cur_bar = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(cur_bar == last_bar) return;
   last_bar = cur_bar;
   
   // Copy indicator buffers (need enough bars for trend check)
   int bars_needed = InpTrendBars + 3;
   if(CopyBuffer(ema_handle, 0, 1, bars_needed, ema_buf) < bars_needed) return;
   if(CopyBuffer(atr_handle, 0, 1, 3, atr_buf) < 3) return;
   if(CopyBuffer(ema_d1_handle, 0, 0, 1, ema_d1_buf) <= 0) return;
   
   // Check if pending order was filled (transition to position)
   CheckPendingFilled();
   
   // If already in a position, do nothing (SL/TP handles exit)
   if(HasOpenPosition()) return;
   
   //--- State Machine ---
   switch(g_state)
     {
      case STATE_IDLE:
         ProcessIdle();
         break;
         
      case STATE_STALKING:
         ProcessStalking();
         break;
         
      case STATE_TRAILING:
         ProcessTrailing();
         break;
     }
  }

//+------------------------------------------------------------------+
// STATE_IDLE: Look for Component 1 (Baseline) + Component 2 (Pullback)
//+------------------------------------------------------------------+
void ProcessIdle()
  {
   // HTF (D1) EMA Filter
   double cur_ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double cur_bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ema_d1 = ema_d1_buf[0];
   
   bool allow_buy = (cur_ask > ema_d1) && (InpTradeDirection == TRADE_DIR_BOTH || InpTradeDirection == TRADE_DIR_BUY);
   bool allow_sell = (cur_bid < ema_d1) && (InpTradeDirection == TRADE_DIR_BOTH || InpTradeDirection == TRADE_DIR_SELL);

   //--- Check BUY setup: Uptrend baseline + Pullback cross below
   if(allow_buy && CheckBaselineBuy() && CheckPullbackBuy())
     {
      g_state     = STATE_STALKING;
      g_direction = +1;
      g_trail_count = 0;
      
      DrawPullbackMarker(true);
      Print("▶ BUY STALKING activated: Pullback detected below EMA (D1 Trend Filter OK)");
      ProcessStalking(); // Immediately place first trap
      return;
     }
   
   //--- Check SELL setup: Downtrend baseline + Pullback cross above
   if(allow_sell && CheckBaselineSell() && CheckPullbackSell())
     {
      g_state     = STATE_STALKING;
      g_direction = -1;
      g_trail_count = 0;
      
      DrawPullbackMarker(false);
      Print("▶ SELL STALKING activated: Pullback detected above EMA");
      ProcessStalking();
      return;
     }
  }

//+------------------------------------------------------------------+
// Component 1: Baseline Bias - BUY (at least N bars above EMA)
//+------------------------------------------------------------------+
bool CheckBaselineBuy()
  {
   // Bars [2..2+InpTrendBars-1] must all close above EMA
   // (bar[1] is the pullback bar, bar[0] is current forming)
   for(int i = 2; i < 2 + InpTrendBars; i++)
     {
      double close_i = iClose(_Symbol, PERIOD_CURRENT, i);
      if(close_i <= ema_buf[i - 1]) // ema_buf[0] = bar[1], ema_buf[1] = bar[2], etc.
         return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
// Component 1: Baseline Bias - SELL (at least N bars below EMA)
//+------------------------------------------------------------------+
bool CheckBaselineSell()
  {
   for(int i = 2; i < 2 + InpTrendBars; i++)
     {
      double close_i = iClose(_Symbol, PERIOD_CURRENT, i);
      if(close_i >= ema_buf[i - 1])
         return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
// Component 2: Pullback Detection - BUY (cross below EMA)
//+------------------------------------------------------------------+
bool CheckPullbackBuy()
  {
   double close_1 = iClose(_Symbol, PERIOD_CURRENT, 1); // Just completed bar
   double close_2 = iClose(_Symbol, PERIOD_CURRENT, 2); // Bar before that
   double ema_1   = ema_buf[0]; // EMA at bar[1]
   double ema_2   = ema_buf[1]; // EMA at bar[2]
   
   // Bar[1] closed below EMA AND bar[2] closed above EMA
   return (close_1 < ema_1 && close_2 > ema_2);
  }

//+------------------------------------------------------------------+
// Component 2: Pullback Detection - SELL (cross above EMA)
//+------------------------------------------------------------------+
bool CheckPullbackSell()
  {
   double close_1 = iClose(_Symbol, PERIOD_CURRENT, 1);
   double close_2 = iClose(_Symbol, PERIOD_CURRENT, 2);
   double ema_1   = ema_buf[0];
   double ema_2   = ema_buf[1];
   
   // Bar[1] closed above EMA AND bar[2] closed below EMA
   return (close_1 > ema_1 && close_2 < ema_2);
  }

//+------------------------------------------------------------------+
// STATE_STALKING: Place initial trap (Component 3)
//+------------------------------------------------------------------+
void ProcessStalking()
  {
   double spread = SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   if(g_direction == +1)
     {
      // Buy Stop at High of pullback bar + Spread
      double high_1 = iHigh(_Symbol, PERIOD_CURRENT, 1);
      double trap_price = NormalizeDouble(high_1 + spread, _Digits);
      
      if(PlaceBuyStop(trap_price))
        {
         g_state = STATE_TRAILING;
         g_last_trap_price = trap_price;
         g_trail_count = 1;
         DrawTrapLevel(trap_price, true);
         Print("🪤 Buy Stop trap set at: ", trap_price);
        }
     }
   else if(g_direction == -1)
     {
      // Sell Stop at Low of pullback bar - Spread
      double low_1 = iLow(_Symbol, PERIOD_CURRENT, 1);
      double trap_price = NormalizeDouble(low_1 - spread, _Digits);
      
      if(PlaceSellStop(trap_price))
        {
         g_state = STATE_TRAILING;
         g_last_trap_price = trap_price;
         g_trail_count = 1;
         DrawTrapLevel(trap_price, false);
         Print("🪤 Sell Stop trap set at: ", trap_price);
        }
     }
  }

//+------------------------------------------------------------------+
// STATE_TRAILING: Trail the trap (Component 3 - Trailing Logic)
//+------------------------------------------------------------------+
void ProcessTrailing()
  {
   g_trail_count++;
   
   // Safety: Cancel if trailing too long
   if(g_trail_count > InpMaxTrailBars)
     {
      CancelPendingOrder();
      ResetState();
      Print("⏰ Trap expired after ", InpMaxTrailBars, " bars. Reset to IDLE.");
      return;
     }
   
   // Check if pending order still exists
   if(!OrderExists(g_pending_ticket))
     {
      // Order was filled or deleted externally
      ResetState();
      return;
     }

   // --- TÍNH NĂNG MỚI: HỦY BẪY NẾU TREND ĐẢO CHIỀU CỨNG ---
   // Nếu giá nằm lỳ dưới/trên EMA đủ số nến xác nhận trend thì hủy bẫy hiện tại
   if(g_direction == +1)
     {
      bool trend_reversed = true;
      for(int i = 1; i <= InpTrendBars; i++)
        {
         if(iClose(_Symbol, PERIOD_CURRENT, i) >= ema_buf[i-1]) // ema_buf[0] is bar[1]
           {
            trend_reversed = false;
            break;
           }
        }
      if(trend_reversed)
        {
         CancelPendingOrder();
         ResetState();
         Print("🔄 Trend reversed to DOWN (", InpTrendBars, " bars below EMA). Cancelled Buy Stop trap.");
         ProcessIdle(); // Quét lại xem có bắt được lệnh SELL STALKING không
         return;
        }
     }
   else if(g_direction == -1)
     {
      bool trend_reversed = true;
      for(int i = 1; i <= InpTrendBars; i++)
        {
         if(iClose(_Symbol, PERIOD_CURRENT, i) <= ema_buf[i-1])
           {
            trend_reversed = false;
            break;
           }
        }
      if(trend_reversed)
        {
         CancelPendingOrder();
         ResetState();
         Print("🔄 Trend reversed to UP (", InpTrendBars, " bars above EMA). Cancelled Sell Stop trap.");
         ProcessIdle(); // Quét lại xem có bắt được lệnh BUY STALKING không
         return;
        }
     }
   
   double spread = SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   if(g_direction == +1)
     {
      // BUY: Trail Buy Stop DOWN if new high is lower
      // Bổ sung điều kiện KHÔNG dời quá gần hoặc vượt EMA hiện tại để tránh trap sát vạch.
      double high_1 = iHigh(_Symbol, PERIOD_CURRENT, 1);
      double new_trap = NormalizeDouble(high_1 + spread, _Digits);
      double current_ema = ema_buf[0];
      
      if(new_trap < g_last_trap_price && new_trap < current_ema)
        {
         // Cancel old and place new lower Buy Stop
         CancelPendingOrder();
         if(PlaceBuyStop(new_trap))
           {
            g_last_trap_price = new_trap;
            DrawTrapLevel(new_trap, true);
            Print("⬇ Buy Stop trailed down to: ", new_trap);
           }
         else
           {
            ResetState();
            Print("ERROR: Failed to re-place Buy Stop");
           }
        }
     }
   else if(g_direction == -1)
     {
      // SELL: Trail Sell Stop UP if new low is higher
      // Bổ sung điều kiện KHÔNG dời quá gần hoặc vượt EMA hiện tại
      double low_1 = iLow(_Symbol, PERIOD_CURRENT, 1);
      double new_trap = NormalizeDouble(low_1 - spread, _Digits);
      double current_ema = ema_buf[0];
      
      if(new_trap > g_last_trap_price && new_trap > current_ema)
        {
         CancelPendingOrder();
         if(PlaceSellStop(new_trap))
           {
            g_last_trap_price = new_trap;
            DrawTrapLevel(new_trap, false);
            Print("⬆ Sell Stop trailed up to: ", new_trap);
           }
         else
           {
            ResetState();
            Print("ERROR: Failed to re-place Sell Stop");
           }
        }
     }
  }

//+------------------------------------------------------------------+
// Check if pending order was filled → Apply SL/TP (Component 4)
//+------------------------------------------------------------------+
void CheckPendingFilled()
  {
   if(g_pending_ticket == 0) return;
   
   // If order no longer exists as pending, check if it became a position
   if(!OrderExists(g_pending_ticket))
     {
      // Look for the position that was just opened
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong pos_ticket = PositionGetTicket(i);
         if(!PositionSelectByTicket(pos_ticket)) continue;
         if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
         
         // Found our position
         double entry = PositionGetDouble(POSITION_PRICE_OPEN);
         double sl = PositionGetDouble(POSITION_SL);
         double tp = PositionGetDouble(POSITION_TP);
         long pos_type = PositionGetInteger(POSITION_TYPE);
         
         // Draw entry visualization
         DrawEntrySignal(pos_type == POSITION_TYPE_BUY, entry, sl, tp);
         
         Print("✅ Order filled at ", entry, " | SL: ", sl, " | TP: ", tp);
         
         ResetState();
         return;
        }
      
      // If no position found, order was deleted, expired, or closed instantly
      ResetState();
     }
  }

//+------------------------------------------------------------------+
// Place Buy Stop order
//+------------------------------------------------------------------+
bool PlaceBuyStop(double price)
  {
   // Validate price is above current Ask
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double min_dist = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   
   if(price <= ask + min_dist)
      price = NormalizeDouble(ask + min_dist + _Point, _Digits);
      
   double atr_val = atr_buf[0];
   double sl_dist = atr_val * InpATRMultSL;
   
   double sl = NormalizeDouble(price - sl_dist, _Digits);
   double tp = 0;
   
   if(InpExitMode == EXIT_FIXED_TP_SL)
     {
      double tp_dist = sl_dist * InpRRMultTP;
      tp = NormalizeDouble(price + tp_dist, _Digits);
     }
   
   if(trade.BuyStop(InpLotSize, price, _Symbol, sl, tp, ORDER_TIME_GTC, 0, "EMA Pullback BUY"))
     {
      g_pending_ticket = trade.ResultOrder();
      return true;
     }
   
   Print("ERROR PlaceBuyStop: ", trade.ResultRetcodeDescription());
   return false;
  }

//+------------------------------------------------------------------+
// Place Sell Stop order
//+------------------------------------------------------------------+
bool PlaceSellStop(double price)
  {
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double min_dist = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   
   if(price >= bid - min_dist)
      price = NormalizeDouble(bid - min_dist - _Point, _Digits);
      
   double atr_val = atr_buf[0];
   double sl_dist = atr_val * InpATRMultSL;
   
   double sl = NormalizeDouble(price + sl_dist, _Digits);
   double tp = 0;
   
   if(InpExitMode == EXIT_FIXED_TP_SL)
     {
      double tp_dist = sl_dist * InpRRMultTP;
      tp = NormalizeDouble(price - tp_dist, _Digits);
     }
   
   if(trade.SellStop(InpLotSize, price, _Symbol, sl, tp, ORDER_TIME_GTC, 0, "EMA Pullback SELL"))
     {
      g_pending_ticket = trade.ResultOrder();
      return true;
     }
   
   Print("ERROR PlaceSellStop: ", trade.ResultRetcodeDescription());
   return false;
  }

//+------------------------------------------------------------------+
// Manage Trailing Stop (EMA 9)
//+------------------------------------------------------------------+
void ManageTrailingStop()
  {
   if(!HasOpenPosition()) return;
   
   double ema_val[];
   // Get completion bar EMA
   if(CopyBuffer(ema_trail_handle, 0, 1, 1, ema_val) <= 0) return;
   double curr_trail = ema_val[0];
   
   double stoplevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   if(stoplevel == 0) stoplevel = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * _Point * 2;
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      
      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double current_sl = PositionGetDouble(POSITION_SL);
      
      if(type == POSITION_TYPE_BUY)
        {
         double new_sl = NormalizeDouble(curr_trail, _Digits);
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
         double new_sl = NormalizeDouble(curr_trail, _Digits);
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

//+------------------------------------------------------------------+
// Cancel pending order
//+------------------------------------------------------------------+
void CancelPendingOrder()
  {
   if(g_pending_ticket > 0 && OrderExists(g_pending_ticket))
     {
      trade.OrderDelete(g_pending_ticket);
     }
   g_pending_ticket = 0;
  }

//+------------------------------------------------------------------+
// Check if order exists as pending
//+------------------------------------------------------------------+
bool OrderExists(ulong ticket)
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      if(OrderGetTicket(i) == ticket)
         return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
// Check if we already have an open position on this symbol
//+------------------------------------------------------------------+
bool HasOpenPosition()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
        {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol)
            return true;
        }
     }
   return false;
  }

//+------------------------------------------------------------------+
// Reset state machine
//+------------------------------------------------------------------+
void ResetState()
  {
   g_state = STATE_IDLE;
   g_direction = 0;
   g_pending_ticket = 0;
   g_trail_count = 0;
   g_last_trap_price = 0;
  }

//+------------------------------------------------------------------+
//  ██  VISUALIZATION  ██
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
// Draw pullback detection marker (Component 2 trigger)
//+------------------------------------------------------------------+
void DrawPullbackMarker(bool is_buy)
  {
   g_signal_id++;
   string name = "PB_" + IntegerToString(g_signal_id) + "_CROSS";
   datetime time = iTime(_Symbol, PERIOD_CURRENT, 1);
   
   if(is_buy)
     {
      // Diamond below bar marking pullback below EMA
      double low = iLow(_Symbol, PERIOD_CURRENT, 1);
      ObjectCreate(0, name, OBJ_ARROW, 0, time, low - 5 * _Point);
      ObjectSetInteger(0, name, OBJPROP_ARROWCODE, 159); // Diamond
      ObjectSetInteger(0, name, OBJPROP_COLOR, clrGold);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
     }
   else
     {
      double high = iHigh(_Symbol, PERIOD_CURRENT, 1);
      ObjectCreate(0, name, OBJ_ARROW, 0, time, high + 5 * _Point);
      ObjectSetInteger(0, name, OBJPROP_ARROWCODE, 159);
      ObjectSetInteger(0, name, OBJPROP_COLOR, clrMagenta);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
     }
  }

//+------------------------------------------------------------------+
// Draw trap level marker (Component 3 pending order)
//+------------------------------------------------------------------+
void DrawTrapLevel(double price, bool is_buy)
  {
   g_signal_id++;
   string name = "PB_" + IntegerToString(g_signal_id) + "_TRAP";
   datetime t0 = iTime(_Symbol, PERIOD_CURRENT, 1);
   datetime t1 = iTime(_Symbol, PERIOD_CURRENT, 0);
   
   ObjectCreate(0, name, OBJ_TREND, 0, t0, price, t1, price);
   ObjectSetInteger(0, name, OBJPROP_COLOR, is_buy ? clrCyan : clrMagenta);
   ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DASHDOTDOT);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
  }

//+------------------------------------------------------------------+
// Draw entry signal with SL/TP visualization (Component 4)
//+------------------------------------------------------------------+
void DrawEntrySignal(bool is_buy, double entry, double sl, double tp)
  {
   g_signal_id++;
   string prefix = "PB_" + IntegerToString(g_signal_id);
   datetime time = iTime(_Symbol, PERIOD_CURRENT, 0);
   datetime t_end = time + PeriodSeconds() * 30;
   
   //--- Entry Arrow
   string arrow_name = prefix + "_ENTRY";
   if(is_buy)
     {
      ObjectCreate(0, arrow_name, OBJ_ARROW_BUY, 0, time, entry);
      ObjectSetInteger(0, arrow_name, OBJPROP_COLOR, InpBuyColor);
     }
   else
     {
      ObjectCreate(0, arrow_name, OBJ_ARROW_SELL, 0, time, entry);
      ObjectSetInteger(0, arrow_name, OBJPROP_COLOR, InpSellColor);
     }
   ObjectSetInteger(0, arrow_name, OBJPROP_WIDTH, 3);
   
   //--- TP Level (green)
   string tp_name = prefix + "_TP";
   ObjectCreate(0, tp_name, OBJ_TREND, 0, time, tp, t_end, tp);
   ObjectSetInteger(0, tp_name, OBJPROP_COLOR, clrLime);
   ObjectSetInteger(0, tp_name, OBJPROP_STYLE, STYLE_DOT);
   ObjectSetInteger(0, tp_name, OBJPROP_WIDTH, 2);
   ObjectSetInteger(0, tp_name, OBJPROP_RAY_RIGHT, false);
   
   //--- SL Level (red)
   string sl_name = prefix + "_SL";
   ObjectCreate(0, sl_name, OBJ_TREND, 0, time, sl, t_end, sl);
   ObjectSetInteger(0, sl_name, OBJPROP_COLOR, clrRed);
   ObjectSetInteger(0, sl_name, OBJPROP_STYLE, STYLE_DOT);
   ObjectSetInteger(0, sl_name, OBJPROP_WIDTH, 2);
   ObjectSetInteger(0, sl_name, OBJPROP_RAY_RIGHT, false);
   
   //--- Entry Level (white)
   string entry_name = prefix + "_LVL";
   ObjectCreate(0, entry_name, OBJ_TREND, 0, time, entry, t_end, entry);
   ObjectSetInteger(0, entry_name, OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, entry_name, OBJPROP_STYLE, STYLE_DASH);
   ObjectSetInteger(0, entry_name, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, entry_name, OBJPROP_RAY_RIGHT, false);
   
   //--- Text label BUY/SELL
   string txt_name = prefix + "_TXT";
   string label = is_buy ? "▲ BUY" : "▼ SELL";
   double txt_price = is_buy ? entry - 15 * _Point : entry + 15 * _Point;
   ObjectCreate(0, txt_name, OBJ_TEXT, 0, time, txt_price);
   ObjectSetString(0, txt_name, OBJPROP_TEXT, label);
   ObjectSetInteger(0, txt_name, OBJPROP_COLOR, is_buy ? InpBuyColor : InpSellColor);
   ObjectSetInteger(0, txt_name, OBJPROP_FONTSIZE, 9);
   ObjectSetString(0, txt_name, OBJPROP_FONT, "Arial Bold");
   
   //--- RR Info text
   string rr_name = prefix + "_RR";
   double rr_price = is_buy ? tp + 10 * _Point : tp - 10 * _Point;
   string rr_text = "RR 1:" + DoubleToString(InpRRMultTP, 1) +
                    " | SL:" + DoubleToString(MathAbs(entry - sl) / _Point, 0) + "p" +
                    " | TP:" + DoubleToString(MathAbs(tp - entry) / _Point, 0) + "p";
   ObjectCreate(0, rr_name, OBJ_TEXT, 0, time, rr_price);
   ObjectSetString(0, rr_name, OBJPROP_TEXT, rr_text);
   ObjectSetInteger(0, rr_name, OBJPROP_COLOR, clrYellow);
   ObjectSetInteger(0, rr_name, OBJPROP_FONTSIZE, 7);
  }
//+------------------------------------------------------------------+
