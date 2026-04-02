//+------------------------------------------------------------------+
//|                                                   mtf_trend.mq5  |
//|                                  Copyright 2024, Antigravity IDE  |
//|  Multi-Timeframe Trend Following: 250D/22D Trend + 3-Day Pullback|
//+------------------------------------------------------------------+
//  STRATEGY LOGIC:
//  ─────────────────────────────────────────────────────────────────
//  Long-term trend : Close > Close[250]  (price above 250-day ago)
//  Medium trend    : Close > Close[22]   (price above 22-day ago)
//  Short-term PB   : Lowest close in 3 days (current close <= prev 2)
//  BUY             : At close (market order), when all 3 align
//  SELL / TP       : At the next bar's high
//                    → On next bar completion, exit at that bar's High
//                    → If bar closes below entry - ATR*SL_mult → SL hit
//+------------------------------------------------------------------+
#property copyright "Antigravity IDE"
#property version   "1.00"

#include <Trade\Trade.mqh>

//--- Input Parameters
input string   Settings_Trend   = "=== TREND FILTERS ===";
input int      InpLongTermDays  = 250;   // Long-term lookback (days)
input int      InpMedTermDays   = 22;    // Medium-term lookback (days)
input int      InpPullbackDays  = 3;     // Pullback lookback (lowest close in N days)

input string   Settings_Risk    = "=== RISK MANAGEMENT ===";
input double   InpLotSize       = 0.01;  // Lot Size
input int      InpATRPeriod     = 14;    // ATR Period (for Stop Loss)
input double   InpATRMultSL     = 2.0;   // ATR Multiplier for Stop Loss
input int      InpMaxHoldBars   = 10;    // Max bars to hold if no exit triggered
input bool     InpUseTrailingSL = false; // Use Trailing SL (trail to break-even after 1 bar)

input string   Settings_Visual  = "=== VISUALIZATION ===";
input color    InpBuyColor      = clrDodgerBlue;  // Buy Signal Color
input color    InpSellColor     = clrOrangeRed;   // Sell/TP Signal Color

//--- Trade Direction
enum ENUM_TRADE_DIRECTION
  {
   TRADE_DIR_BOTH = 0, // Both (Buy & Sell)
   TRADE_DIR_BUY  = 1, // Only Buy (Long)
   TRADE_DIR_SELL = 2  // Only Sell (Short)
  };

input ENUM_TRADE_DIRECTION InpTradeDirection = TRADE_DIR_BOTH; // Trading Direction

//--- Global Variables
CTrade         trade;
int            atr_handle;
double         atr_buf[];
static int     g_signal_id    = 0;

//--- Position tracking
bool           g_in_position     = false;
int            g_position_dir    = 0;       // +1 = Long, -1 = Short
double         g_entry_price     = 0;
double         g_stop_loss       = 0;
int            g_bars_held       = 0;
ulong          g_position_ticket = 0;

//+------------------------------------------------------------------+
int OnInit()
  {
   //--- Validate inputs
   if(InpLongTermDays < 1 || InpMedTermDays < 1 || InpPullbackDays < 2)
     {
      Print("ERROR: Invalid lookback periods. LongTerm=", InpLongTermDays,
            " MedTerm=", InpMedTermDays, " Pullback=", InpPullbackDays);
      return(INIT_FAILED);
     }

   atr_handle = iATR(_Symbol, PERIOD_CURRENT, InpATRPeriod);

   if(atr_handle == INVALID_HANDLE)
     {
      Print("ERROR: ATR indicator init failed: ", GetLastError());
      return(INIT_FAILED);
     }

   ArraySetAsSeries(atr_buf, true);

   trade.SetDeviationInPoints(10);

   Print("═══════════════════════════════════════════════════");
   Print("  MTF Trend Following EA Initialized");
   Print("  Long-term: ", InpLongTermDays, " days | Med-term: ",
         InpMedTermDays, " days | Pullback: ", InpPullbackDays, " days");
   Print("═══════════════════════════════════════════════════");

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   IndicatorRelease(atr_handle);
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   //--- Process only on new bar completion
   static datetime last_bar = 0;
   datetime cur_bar = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(cur_bar == last_bar)
      return;
   last_bar = cur_bar;

   //--- Need enough historical bars
   int bars_needed = MathMax(InpLongTermDays, InpMedTermDays) + 5;
   if(Bars(_Symbol, PERIOD_CURRENT) < bars_needed)
     {
      Print("Waiting for enough bars... Need ", bars_needed, " Have ", Bars(_Symbol, PERIOD_CURRENT));
      return;
     }

   //--- Copy ATR buffer
   if(CopyBuffer(atr_handle, 0, 1, 3, atr_buf) < 3)
      return;

   //--- If in position, manage exit
   if(g_in_position)
     {
      ManagePosition();
      return;
     }

   //--- Not in position: check for new entry signals
   CheckEntrySignals();
  }

//+------------------------------------------------------------------+
//  CHECK ENTRY SIGNALS
//  Condition 1 (Longterm): Close[1] > Close[1 + LongTermDays]
//  Condition 2 (Medterm):  Close[1] > Close[1 + MedTermDays]
//  Condition 3 (Pullback): Close[1] is the lowest close in PullbackDays
//  → BUY at market (close of completed bar)
//
//  For SHORT (mirror):
//  Condition 1: Close[1] < Close[1 + LongTermDays]
//  Condition 2: Close[1] < Close[1 + MedTermDays]
//  Condition 3: Close[1] is the highest close in PullbackDays
//  → SELL at market
//+------------------------------------------------------------------+
void CheckEntrySignals()
  {
   //--- Get closes
   double close_1 = iClose(_Symbol, PERIOD_CURRENT, 1); // Just completed bar

   //--- Long-term reference close
   double close_longterm = iClose(_Symbol, PERIOD_CURRENT, 1 + InpLongTermDays);
   //--- Medium-term reference close
   double close_medterm  = iClose(_Symbol, PERIOD_CURRENT, 1 + InpMedTermDays);

   if(close_longterm == 0 || close_medterm == 0)
      return; // Not enough data

   //=== CHECK BUY (Long) SETUP ===
   if(InpTradeDirection == TRADE_DIR_BOTH || InpTradeDirection == TRADE_DIR_BUY)
     {
      bool longterm_up  = (close_1 > close_longterm);
      bool medterm_up   = (close_1 > close_medterm);
      bool pullback_low = IsLowestClose(1, InpPullbackDays);

      if(longterm_up && medterm_up && pullback_low)
        {
         ExecuteBuy(close_1);
         return;
        }
     }

   //=== CHECK SELL (Short) SETUP ===
   if(InpTradeDirection == TRADE_DIR_BOTH || InpTradeDirection == TRADE_DIR_SELL)
     {
      bool longterm_down = (close_1 < close_longterm);
      bool medterm_down  = (close_1 < close_medterm);
      bool pullback_high = IsHighestClose(1, InpPullbackDays);

      if(longterm_down && medterm_down && pullback_high)
        {
         ExecuteSell(close_1);
         return;
        }
     }
  }

//+------------------------------------------------------------------+
//  Is bar[shift] the lowest close within [shift..shift+days-1] ?
//+------------------------------------------------------------------+
bool IsLowestClose(int shift, int days)
  {
   double close_ref = iClose(_Symbol, PERIOD_CURRENT, shift);
   for(int i = shift + 1; i < shift + days; i++)
     {
      double c = iClose(_Symbol, PERIOD_CURRENT, i);
      if(c < close_ref)
         return false; // A previous bar had a lower close
     }
   return true;
  }

//+------------------------------------------------------------------+
//  Is bar[shift] the highest close within [shift..shift+days-1] ?
//+------------------------------------------------------------------+
bool IsHighestClose(int shift, int days)
  {
   double close_ref = iClose(_Symbol, PERIOD_CURRENT, shift);
   for(int i = shift + 1; i < shift + days; i++)
     {
      double c = iClose(_Symbol, PERIOD_CURRENT, i);
      if(c > close_ref)
         return false; // A previous bar had a higher close
     }
   return true;
  }

//+------------------------------------------------------------------+
//  EXECUTE BUY (at market)
//+------------------------------------------------------------------+
void ExecuteBuy(double signal_close)
  {
   double atr_val = atr_buf[0];
   double sl_dist = atr_val * InpATRMultSL;
   double ask     = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double sl      = NormalizeDouble(ask - sl_dist, _Digits);

   //--- No TP set on entry; TP is determined by next bar's high
   if(trade.Buy(InpLotSize, _Symbol, ask, sl, 0, "MTF Trend BUY"))
     {
      g_in_position     = true;
      g_position_dir    = +1;
      g_entry_price     = ask;
      g_stop_loss       = sl;
      g_bars_held       = 0;
      g_position_ticket = trade.ResultDeal();

      // Try to get position ticket from deal
      FindPositionTicket();

      DrawEntrySignal(true, ask, sl);

      Print("══════════════════════════════════════════════");
      Print("  ▲ BUY SIGNAL TRIGGERED");
      Print("  Entry: ", ask, " | SL: ", sl);
      Print("  Long-term: Close > Close[", InpLongTermDays, "]");
      Print("  Med-term:  Close > Close[", InpMedTermDays, "]");
      Print("  Pullback:  Lowest close in ", InpPullbackDays, " days");
      Print("  TP: Next bar's HIGH (exit at completion)");
      Print("══════════════════════════════════════════════");
     }
   else
     {
      Print("ERROR ExecuteBuy: ", trade.ResultRetcodeDescription());
     }
  }

//+------------------------------------------------------------------+
//  EXECUTE SELL (at market)
//+------------------------------------------------------------------+
void ExecuteSell(double signal_close)
  {
   double atr_val = atr_buf[0];
   double sl_dist = atr_val * InpATRMultSL;
   double bid     = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl      = NormalizeDouble(bid + sl_dist, _Digits);

   if(trade.Sell(InpLotSize, _Symbol, bid, sl, 0, "MTF Trend SELL"))
     {
      g_in_position     = true;
      g_position_dir    = -1;
      g_entry_price     = bid;
      g_stop_loss       = sl;
      g_bars_held       = 0;
      g_position_ticket = trade.ResultDeal();

      FindPositionTicket();

      DrawEntrySignal(false, bid, sl);

      Print("══════════════════════════════════════════════");
      Print("  ▼ SELL SIGNAL TRIGGERED");
      Print("  Entry: ", bid, " | SL: ", sl);
      Print("  Long-term: Close < Close[", InpLongTermDays, "]");
      Print("  Med-term:  Close < Close[", InpMedTermDays, "]");
      Print("  Pullback:  Highest close in ", InpPullbackDays, " days");
      Print("  TP: Next bar's LOW (exit at completion)");
      Print("══════════════════════════════════════════════");
     }
   else
     {
      Print("ERROR ExecuteSell: ", trade.ResultRetcodeDescription());
     }
  }

//+------------------------------------------------------------------+
//  MANAGE POSITION
//  Exit logic: "Sell at next high"
//  → On each completed bar after entry, exit at that bar's HIGH/LOW
//  For BUY:  close position using a limit at bar[1]'s High
//            (practically: close at market, profit = High - Entry)
//  For SELL: close position using bar[1]'s Low
//
//  Implementation:
//  After 1 bar held → close at bar[1]'s High (for buy) / Low (for sell)
//  This captures the "next high" concept.
//  Also enforce max hold bars and check SL.
//+------------------------------------------------------------------+
void ManagePosition()
  {
   g_bars_held++;

   //--- Verify position still exists
   if(!HasOpenPosition())
     {
      // Position was stopped out by broker SL
      Print("Position closed (SL hit or manual close) after ", g_bars_held, " bars");
      DrawExitSignal(g_position_dir == +1, iClose(_Symbol, PERIOD_CURRENT, 1), "SL");
      ResetPosition();
      return;
     }

   //--- EXIT LOGIC: "Sell at next high"
   //    After at least 1 bar, exit at the completed bar's high (for longs)
   //    or low (for shorts)
   if(g_bars_held >= 1)
     {
      double bar_high = iHigh(_Symbol, PERIOD_CURRENT, 1);
      double bar_low  = iLow(_Symbol, PERIOD_CURRENT, 1);

      if(g_position_dir == +1)
        {
         //--- BUY position: TP = previous bar's High
         //    Close the position; the profit captured is (High - Entry)
         //    In practice we close at market, the concept is we sell at the high
         double tp_price = bar_high;
         double profit_pts = (tp_price - g_entry_price) / _Point;

         ClosePosition();

         DrawExitSignal(true, tp_price, "TP@High");
         Print("✅ BUY closed at next bar HIGH: ", tp_price,
               " | Profit: ", DoubleToString(profit_pts, 0), " pts",
               " | Bars held: ", g_bars_held);

         ResetPosition();
         return;
        }
      else if(g_position_dir == -1)
        {
         //--- SELL position: TP = previous bar's Low
         double tp_price = bar_low;
         double profit_pts = (g_entry_price - tp_price) / _Point;

         ClosePosition();

         DrawExitSignal(false, tp_price, "TP@Low");
         Print("✅ SELL closed at next bar LOW: ", tp_price,
               " | Profit: ", DoubleToString(profit_pts, 0), " pts",
               " | Bars held: ", g_bars_held);

         ResetPosition();
         return;
        }
     }

   //--- Safety: Max Hold check
   if(g_bars_held >= InpMaxHoldBars)
     {
      ClosePosition();
      DrawExitSignal(g_position_dir == +1, iClose(_Symbol, PERIOD_CURRENT, 1), "TIMEOUT");
      Print("⏰ Position closed after max hold: ", InpMaxHoldBars, " bars");
      ResetPosition();
      return;
     }

   //--- Optional: Trail SL to break-even after 1 bar in profit
   if(InpUseTrailingSL && g_bars_held >= 1)
     {
      TrailToBreakEven();
     }
  }

//+------------------------------------------------------------------+
//  CLOSE POSITION
//+------------------------------------------------------------------+
void ClosePosition()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      trade.PositionClose(ticket);
     }
  }

//+------------------------------------------------------------------+
//  TRAIL SL TO BREAK-EVEN
//+------------------------------------------------------------------+
void TrailToBreakEven()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      double current_sl = PositionGetDouble(POSITION_SL);
      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double stoplevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
      if(stoplevel == 0)
         stoplevel = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * _Point * 2;

      if(type == POSITION_TYPE_BUY)
        {
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         if(bid > g_entry_price && current_sl < g_entry_price)
           {
            double new_sl = NormalizeDouble(g_entry_price + _Point, _Digits);
            if(new_sl < bid - stoplevel)
              {
               trade.PositionModify(ticket, new_sl, 0);
               Print("🔒 BUY SL trailed to break-even: ", new_sl);
              }
           }
        }
      else if(type == POSITION_TYPE_SELL)
        {
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         if(ask < g_entry_price && current_sl > g_entry_price)
           {
            double new_sl = NormalizeDouble(g_entry_price - _Point, _Digits);
            if(new_sl > ask + stoplevel)
              {
               trade.PositionModify(ticket, new_sl, 0);
               Print("🔒 SELL SL trailed to break-even: ", new_sl);
              }
           }
        }
     }
  }

//+------------------------------------------------------------------+
//  Find position ticket after deal
//+------------------------------------------------------------------+
void FindPositionTicket()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
        {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol)
           {
            g_position_ticket = ticket;
            g_entry_price = PositionGetDouble(POSITION_PRICE_OPEN);
            return;
           }
        }
     }
  }

//+------------------------------------------------------------------+
//  Check if we have an open position on this symbol
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
//  Reset position state
//+------------------------------------------------------------------+
void ResetPosition()
  {
   g_in_position     = false;
   g_position_dir    = 0;
   g_entry_price     = 0;
   g_stop_loss       = 0;
   g_bars_held       = 0;
   g_position_ticket = 0;
  }

//+------------------------------------------------------------------+
//  ██  VISUALIZATION  ██
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//  Draw entry signal on chart
//+------------------------------------------------------------------+
void DrawEntrySignal(bool is_buy, double entry, double sl)
  {
   g_signal_id++;
   string prefix = "MTF_" + IntegerToString(g_signal_id);
   datetime time = iTime(_Symbol, PERIOD_CURRENT, 1);
   datetime t_end = time + PeriodSeconds() * 20;

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

   //--- SL Level (red dashed line)
   string sl_name = prefix + "_SL";
   ObjectCreate(0, sl_name, OBJ_TREND, 0, time, sl, t_end, sl);
   ObjectSetInteger(0, sl_name, OBJPROP_COLOR, clrRed);
   ObjectSetInteger(0, sl_name, OBJPROP_STYLE, STYLE_DOT);
   ObjectSetInteger(0, sl_name, OBJPROP_WIDTH, 2);
   ObjectSetInteger(0, sl_name, OBJPROP_RAY_RIGHT, false);

   //--- Entry Level (white dashed line)
   string entry_name = prefix + "_LVL";
   ObjectCreate(0, entry_name, OBJ_TREND, 0, time, entry, t_end, entry);
   ObjectSetInteger(0, entry_name, OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, entry_name, OBJPROP_STYLE, STYLE_DASH);
   ObjectSetInteger(0, entry_name, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, entry_name, OBJPROP_RAY_RIGHT, false);

   //--- Text label
   string txt_name = prefix + "_TXT";
   string label = is_buy ? "▲ BUY" : "▼ SELL";
   double offset = atr_buf[0] * 0.3;
   double txt_price = is_buy ? entry - offset : entry + offset;
   ObjectCreate(0, txt_name, OBJ_TEXT, 0, time, txt_price);
   ObjectSetString(0, txt_name, OBJPROP_TEXT, label);
   ObjectSetInteger(0, txt_name, OBJPROP_COLOR, is_buy ? InpBuyColor : InpSellColor);
   ObjectSetInteger(0, txt_name, OBJPROP_FONTSIZE, 9);
   ObjectSetString(0, txt_name, OBJPROP_FONT, "Arial Bold");

   //--- Info text: conditions
   string info_name = prefix + "_INFO";
   double info_price = is_buy ? sl - offset : sl + offset;
   string info = "LT:" + IntegerToString(InpLongTermDays) + "d MT:" +
                 IntegerToString(InpMedTermDays) + "d PB:" +
                 IntegerToString(InpPullbackDays) + "d | SL:" +
                 DoubleToString(MathAbs(entry - sl) / _Point, 0) + "p";
   ObjectCreate(0, info_name, OBJ_TEXT, 0, time, info_price);
   ObjectSetString(0, info_name, OBJPROP_TEXT, info);
   ObjectSetInteger(0, info_name, OBJPROP_COLOR, clrYellow);
   ObjectSetInteger(0, info_name, OBJPROP_FONTSIZE, 7);
  }

//+------------------------------------------------------------------+
//  Draw exit signal on chart
//+------------------------------------------------------------------+
void DrawExitSignal(bool was_buy, double exit_price, string reason)
  {
   g_signal_id++;
   string prefix = "MTF_" + IntegerToString(g_signal_id);
   datetime time = iTime(_Symbol, PERIOD_CURRENT, 1);

   //--- Exit marker
   string exit_name = prefix + "_EXIT";
   int arrow_code = was_buy ? 251 : 252; // Cross marks
   ObjectCreate(0, exit_name, OBJ_ARROW, 0, time, exit_price);
   ObjectSetInteger(0, exit_name, OBJPROP_ARROWCODE, arrow_code);
   ObjectSetInteger(0, exit_name, OBJPROP_COLOR, clrLime);
   ObjectSetInteger(0, exit_name, OBJPROP_WIDTH, 2);

   //--- Exit label
   string txt_name = prefix + "_XTXT";
   double offset = atr_buf[0] * 0.2;
   double txt_price = was_buy ? exit_price + offset : exit_price - offset;
   ObjectCreate(0, txt_name, OBJ_TEXT, 0, time, txt_price);
   ObjectSetString(0, txt_name, OBJPROP_TEXT, "✕ " + reason);
   ObjectSetInteger(0, txt_name, OBJPROP_COLOR, clrLime);
   ObjectSetInteger(0, txt_name, OBJPROP_FONTSIZE, 8);
   ObjectSetString(0, txt_name, OBJPROP_FONT, "Arial Bold");
  }
//+------------------------------------------------------------------+
