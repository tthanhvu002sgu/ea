//+------------------------------------------------------------------+
//|                                            EMM_Strategy_Pine.mq5 |
//|                                     Copyright 2026, Antigravity  |
//+------------------------------------------------------------------+
#property copyright   "Copyright 2026, Antigravity"
#property version     "1.00"

#include <Trade\Trade.mqh>
CTrade m_trade;

enum ENUM_TRADE_DIR
  {
   DIR_BOTH = 0,
   DIR_BUY  = 1,
   DIR_SELL = 2
  };

enum ENUM_MM_MODE
  {
   MM_FIXED = 0,   // Lot cố định
   MM_RISK_PCT = 1 // Quản lý vốn theo % (Giá trị tài sản về 0)
  };

input ENUM_TRADE_DIR  InpTradeDir      = DIR_BOTH;
input ENUM_MM_MODE    InpMmMode        = MM_FIXED;  // Chế độ Quản lý vốn
input double          InpRiskPercent   = 1.0;       // % Rủi ro (nếu giá giảm về 0)
input double          InpLotSize       = 0.1;       // Khối lượng cố định (Lots)
input int             InpEmmLength     = 20;
input int             InpEmmWindow     = 100;
input bool            InpUseHtfFilter  = true;
input ENUM_TIMEFRAMES InpHtfTimeframe  = PERIOD_H4;
input int             InpHtfEmmLength  = 50;
input ulong           InpMagicNumber   = 888998;

struct EMMData { double price; double weight; };

//+------------------------------------------------------------------+
//| Tính EMM — nhận shift trực tiếp (dùng cho EA)                    |
//+------------------------------------------------------------------+
double CalculateEMM(string symbol, ENUM_TIMEFRAMES tf, int length, int window, int shift)
  {
   if(length <= 0 || window <= 0) return 0.0;
   double closes[];
   ArraySetAsSeries(closes, true);
   int copied = CopyClose(symbol, tf, shift, window, closes);
   if(copied <= 0) return 0.0;

   double alpha   = 2.0 / (length + 1.0);
   double total_w = 0.0;
   EMMData data[];
   ArrayResize(data, copied);

   for(int i = 0; i < copied; i++)
     {
      data[i].price  = closes[i];
      data[i].weight = MathPow(1.0 - alpha, i);
      total_w += data[i].weight;
     }

   // Insertion sort theo giá tăng dần
   for(int i = 1; i < copied; i++)
     {
      EMMData key = data[i];
      int j = i - 1;
      while(j >= 0 && data[j].price > key.price) { data[j+1] = data[j]; j--; }
      data[j+1] = key;
     }

   double cum_w = 0.0, target_w = total_w / 2.0;
   double result = data[copied - 1].price;
   for(int i = 0; i < copied; i++)
     {
      cum_w += data[i].weight;
      if(cum_w >= target_w) { result = data[i].price; break; }
     }
   return result;
  }

//+------------------------------------------------------------------+
//| Crossover — dùng đúng logic của Indicator                        |
//+------------------------------------------------------------------+
void GetCrossSignals(double prev_close, double prev_emm,
                     double curr_close, double curr_emm,
                     bool &cross_up, bool &cross_down)
  {
   cross_up   = (prev_close <= prev_emm) && (curr_close > curr_emm);
   cross_down = (prev_close >= prev_emm) && (curr_close < curr_emm);

   // Trường hợp close trúng khít EMM
   if(prev_close < prev_emm && curr_close == curr_emm) cross_up   = true;
   if(prev_close > prev_emm && curr_close == curr_emm) cross_down = true;
  }

//+------------------------------------------------------------------+
//| Lấy trạng thái lệnh đang mở                                      |
//+------------------------------------------------------------------+
void GetOpenPositions(bool &has_long,  ulong &long_ticket,
                      bool &has_short, ulong &short_ticket)
  {
   has_long = false; has_short = false;
   long_ticket = 0;  short_ticket = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket))                          continue;
      if(PositionGetString(POSITION_SYMBOL)  != _Symbol)          continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;

      if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
        { has_long  = true; long_ticket  = ticket; }
      else
        { has_short = true; short_ticket = ticket; }
     }
  }

//+------------------------------------------------------------------+
//| Tính toán khối lượng giao dịch dựa trên rủi ro nếu giá về 0      |
//+------------------------------------------------------------------+
double CalculateVolume(string symbol, double price)
  {
   if(InpMmMode == MM_FIXED) return InpLotSize;
   
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double risk_amount = balance * (InpRiskPercent / 100.0);
   
   double tick_size  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   double tick_value = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   
   if(tick_size == 0.0 || tick_value == 0.0 || price == 0.0) return InpLotSize;
   
   // Tổng số tiền thua lỗ của 1 Lot nếu giá rơi từ "price" xuống 0
   double loss_per_lot = (price / tick_size) * tick_value;
   if(loss_per_lot == 0.0) return InpLotSize;
   
   double volume = risk_amount / loss_per_lot;
   
   // Chuẩn hoá khối lượng
   double step = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   double min_vol = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double max_vol = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   
   if(step > 0)
      volume = MathFloor(volume / step) * step;
      
   if(volume < min_vol) volume = min_vol;
   if(volume > max_vol) volume = max_vol;
   
   return volume;
  }

//+------------------------------------------------------------------+
bool IsNewBar()
  {
   static datetime last_time = 0;
   datetime t = iTime(_Symbol, _Period, 0);
   if(t != last_time) { last_time = t; return true; }
   return false;
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED)) return;
   if(!IsNewBar()) return;

   // --- 1. Tính EMM nến vừa đóng (shift=1) và nến trước đó (shift=2) ---
   double curr_emm = CalculateEMM(_Symbol, _Period, InpEmmLength, InpEmmWindow, 1);
   double prev_emm = CalculateEMM(_Symbol, _Period, InpEmmLength, InpEmmWindow, 2);
   if(curr_emm == 0.0 || prev_emm == 0.0) return;

   // --- 2. HTF Filter ---
   double htf_emm = 0.0;
   if(InpUseHtfFilter)
     {
      htf_emm = CalculateEMM(_Symbol, InpHtfTimeframe, InpHtfEmmLength, InpEmmWindow, 1);
      if(htf_emm == 0.0) return;
     }

   // --- 3. Crossover (đồng bộ với Indicator) ---
   double curr_close = iClose(_Symbol, _Period, 1);
   double prev_close = iClose(_Symbol, _Period, 2);

   bool cross_up, cross_down;
   GetCrossSignals(prev_close, prev_emm, curr_close, curr_emm, cross_up, cross_down);

   // --- 4. Áp HTF filter vào tín hiệu entry ---
   bool long_ok  = !InpUseHtfFilter || (curr_close > htf_emm);
   bool short_ok = !InpUseHtfFilter || (curr_close < htf_emm);

   bool buy_signal  = cross_up   && long_ok;
   bool sell_signal = cross_down && short_ok;

   // --- 5. Trạng thái lệnh hiện tại ---
   bool  has_long,  has_short;
   ulong long_ticket, short_ticket;
   GetOpenPositions(has_long, long_ticket, has_short, short_ticket);

   // --- 6. Đóng lệnh khi cross ngược ---
   if(has_long && cross_down)
     {
      if(m_trade.PositionClose(long_ticket))
        { Print("Close Buy: cross_down"); has_long = false; }
     }

   if(has_short && cross_up)
     {
      if(m_trade.PositionClose(short_ticket))
        { Print("Close Sell: cross_up"); has_short = false; }
     }

   // --- 7. Mở lệnh mới ---
   // Chú ý: cross_up và cross_down không thể cùng true
   // nên buy_signal và sell_signal cũng không thể cùng true
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(buy_signal && !has_long && (InpTradeDir == DIR_BOTH || InpTradeDir == DIR_BUY))
     {
      double vol = CalculateVolume(_Symbol, ask);
      m_trade.Buy(vol, _Symbol, ask, 0, 0, "EMM Long");
      PrintFormat("Mở Long tại %.5f | Vol: %.2f | EMM=%.5f | HTF=%.5f", ask, vol, curr_emm, htf_emm);
     }
   else if(sell_signal && !has_short && (InpTradeDir == DIR_BOTH || InpTradeDir == DIR_SELL))
     {
      double vol = CalculateVolume(_Symbol, bid);
      m_trade.Sell(vol, _Symbol, bid, 0, 0, "EMM Short");
      PrintFormat("Mở Short tại %.5f | Vol: %.2f | EMM=%.5f | HTF=%.5f", bid, vol, curr_emm, htf_emm);
     }
  }

int OnInit()
  {
   m_trade.SetExpertMagicNumber(InpMagicNumber);
   Print("EMM Strategy khởi tạo thành công.");
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   Print("EMM Strategy tắt.");
  }