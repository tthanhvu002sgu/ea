//+------------------------------------------------------------------+
//|                                              Overbuysell_EA.mq5  |
//|                                                                  |
//+------------------------------------------------------------------+
#property copyright "AI"
#property link      ""
#property version   "1.00"

#include <Trade\Trade.mqh>

CTrade trade;

input double LotSize = 0.01;         // Fixed Lot Size
input ulong  MagicNumber = 123456;   // Magic Number

sinput string _separator1 = "--- RSI Settings ---";
input int    RSI_Period = 14;        // RSI Length
input double RSI_Oversold = 33;      // RSI Oversold Level
input double RSI_Overbought = 67;    // RSI Overbought Level

sinput string _separator2 = "--- Bollinger Bands Settings ---";
input int    BB_Period = 20;         // BB Length
input double BB_Deviation = 2.0;     // BB Deviation

sinput string _separator3 = "--- ATR Settings ---";
input int    ATR_Period = 14;        // ATR Length
input double ATR_Multiplier = 0.9;   // ATR Multiplier

sinput string _separator4 = "--- Body Confirmation Setting ---";
input int    Body_Lookback = 10;     // Average Body Length
input double Body_Multiplier = 1.5;  // Body Multiplier

int handle_bb;
int handle_rsi;
int handle_atr;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetExpertMagicNumber(MagicNumber);
   
   handle_bb = iBands(_Symbol, _Period, BB_Period, 0, BB_Deviation, PRICE_CLOSE);
   handle_rsi = iRSI(_Symbol, _Period, RSI_Period, PRICE_CLOSE);
   handle_atr = iATR(_Symbol, _Period, ATR_Period);
   
   if(handle_bb == INVALID_HANDLE || handle_rsi == INVALID_HANDLE || handle_atr == INVALID_HANDLE)
     {
      Print("Error creating indicator handles");
      return(INIT_FAILED);
     }
     
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   IndicatorRelease(handle_bb);
   IndicatorRelease(handle_rsi);
   IndicatorRelease(handle_atr);
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   if(!IsNewBar()) return;
   
   double bbu[], bbl[], rsi[], atr[];
   ArraySetAsSeries(bbu, true);
   ArraySetAsSeries(bbl, true);
   ArraySetAsSeries(rsi, true);
   ArraySetAsSeries(atr, true);
   
   if(CopyBuffer(handle_bb, 1, 1, 1, bbu) <= 0) return; // Upper Band
   if(CopyBuffer(handle_bb, 2, 1, 1, bbl) <= 0) return; // Lower Band
   if(CopyBuffer(handle_rsi, 0, 1, 1, rsi) <= 0) return;
   if(CopyBuffer(handle_atr, 0, 1, 1, atr) <= 0) return;
   
   // Shift 1 values
   double close1 = iClose(_Symbol, _Period, 1);
   double open1 = iOpen(_Symbol, _Period, 1);
   double body1 = MathAbs(close1 - open1);
   
   // Calculate Average Body Size
   double sum_bodies = 0;
   int copied_bodies = 0;
   for(int i = 1; i <= Body_Lookback; i++)
     {
      double c = iClose(_Symbol, _Period, i);
      double o = iOpen(_Symbol, _Period, i);
      if(c == 0 && o == 0) continue; 
      sum_bodies += MathAbs(c - o);
      copied_bodies++;
     }
     
   if(copied_bodies == 0) return;
   
   double avg_body_size = sum_bodies / copied_bodies;
   bool body_confirmation = body1 > (avg_body_size * Body_Multiplier);
   
   // Trading Logic Conditions
   bool isBuySignal = (close1 < bbl[0]) && (rsi[0] < RSI_Oversold) && body_confirmation;
   bool isSellSignal = (close1 > bbu[0]) && (rsi[0] > RSI_Overbought) && body_confirmation;
   
   // Check current positions
   bool hasBuy = false;
   bool hasSell = false;
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
        {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
           {
            if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) hasBuy = true;
            if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL) hasSell = true;
           }
        }
     }
   
   // Execute Trading Actions
   if(isBuySignal)
     {
       // Close opposite positions before opening a new direction (optional, but standard for Stop and Reverse)
       if(hasSell)
         {
          ClosePositions(POSITION_TYPE_SELL);
          hasSell = false;
         }
       
       if(!hasBuy) // Only allow 1 order per direction
         {
          double atr_dist = atr[0] * ATR_Multiplier;
          // SL = nến xác nhận - ATR, TP = nến xác nhận + ATR
          double sl = NormalizeDouble(close1 - atr_dist, _Digits);
          double tp = NormalizeDouble(close1 + atr_dist, _Digits);
          
          double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
          trade.Buy(LotSize, _Symbol, ask, sl, tp, "Overbuysell Long EA");
         }
     }
     
   if(isSellSignal)
     {
       if(hasBuy)
         {
          ClosePositions(POSITION_TYPE_BUY);
          hasBuy = false;
         }
       
       if(!hasSell)
         {
          double atr_dist = atr[0] * ATR_Multiplier;
          // SL = nến xác nhận + ATR, TP = nến xác nhận - ATR
          double sl = NormalizeDouble(close1 + atr_dist, _Digits);
          double tp = NormalizeDouble(close1 - atr_dist, _Digits);
          
          double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
          trade.Sell(LotSize, _Symbol, bid, sl, tp, "Overbuysell Short EA");
         }
     }
  }

//+------------------------------------------------------------------+
//| Check if New Bar                                                 |
//+------------------------------------------------------------------+
bool IsNewBar()
  {
   static datetime lastBarTime = 0;
   datetime currentTime = iTime(_Symbol, _Period, 0);
   if(currentTime != lastBarTime)
     {
      lastBarTime = currentTime;
      return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Close all positions for specific direction                       |
//+------------------------------------------------------------------+
void ClosePositions(ENUM_POSITION_TYPE pos_type)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
        {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
           {
            if(PositionGetInteger(POSITION_TYPE) == pos_type)
              {
               trade.PositionClose(ticket);
              }
           }
        }
     }
  }
//+------------------------------------------------------------------+
