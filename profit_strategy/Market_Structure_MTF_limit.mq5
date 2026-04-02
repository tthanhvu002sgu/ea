//+------------------------------------------------------------------+
//|                    Market Structure MTF Strategy.mq5             |
//|                                              Antigravity AI      |
//+------------------------------------------------------------------+
//  v3.0 — Limit Orders + Auto-Cancel Mechanism
//
//  Cơ chế hủy lệnh (Auto-Cancel):
//  1. Hủy Buy Limit nếu Trend D1 chuyển sang Bearish.
//  2. Hủy Sell Limit nếu Trend D1 chuyển sang Bullish.
//  3. Hủy lệnh chờ nếu giá thị trường phá qua SL của lệnh đó. (Pivot bị vỡ)
//  4. Hủy lệnh chờ nếu zone ID không còn nằm trong N vùng swing gần nhất.
//+------------------------------------------------------------------+
#property copyright "Antigravity AI"
#property link      ""
#property version   "3.00"
#property description "Market Structure MTF — Limit Orders & Auto-Cleanup"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

//====================================================================
// STRUCT
//====================================================================
struct ZoneInfo
  {
   double   pivotPrice;
   int      dir;          // 1 = Support (Buy), -1 = Resistance (Sell)
   double   entryLevel;
   double   slPrice;
   string   zoneID;       // "SUP@1.23456"
  };

//====================================================================
// INPUTS
//====================================================================
sinput string  gFilter           = "═══ BỘ LỌC XU HƯỚNG ═══";
input  int     InpEmaD1          = 30;      // Chu kỳ EMA D1
input  bool    InpUseFilter      = true;    // Bật bộ lọc EMA D1

sinput string  gSwing            = "═══ CẤU TRÚC THỊ TRƯỜNG ═══";
input  int     InpSwingLength    = 5;       // Pivot lookback
input  int     InpSwingLookback  = 150;     // Số nến quét tìm zones
input  int     InpMaxZones       = 3;       // Số vùng (lệnh chờ) tối đa mỗi loại

sinput string  gEntry            = "═══ VÙNG VÀO LỆNH ═══";
input  double  InpSupportPct     = 50.0;    // % Entry vùng hỗ trợ (từ đáy lên)
input  double  InpResistPct      = 50.0;    // % Entry vùng kháng cự (từ đỉnh xuống)

sinput string  gRisk             = "═══ QUẢN LÝ RỦI RO ═══";
input  double  InpBufferPips     = 10.0;    // Buffer SL ngoài pivot (pips)
input  double  InpRiskReward     = 2.0;     // R:R
input  double  InpFixedLot       = 0.01;    // Lot cố định

sinput string  gEA               = "═══ CÀI ĐẶT EA ═══";
input  int     InpMagicNumber    = 20260301;
input  bool    InpAllowBuy       = true;
input  bool    InpAllowSell      = true;

//====================================================================
// GLOBALS
//====================================================================
int      g_emaD1Handle = INVALID_HANDLE;
double   g_pip;
datetime g_lastBarTime = 0;

//====================================================================
// INIT / DEINIT
//====================================================================
int OnInit()
  {
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(20);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   g_pip = (_Digits == 5 || _Digits == 3) ? _Point * 10 : _Point;

   g_emaD1Handle = iMA(_Symbol, PERIOD_D1, InpEmaD1, 0, MODE_EMA, PRICE_CLOSE);
   if(g_emaD1Handle == INVALID_HANDLE) return INIT_FAILED;

   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   if(g_emaD1Handle != INVALID_HANDLE) IndicatorRelease(g_emaD1Handle);
  }

//====================================================================
// ON TICK
//====================================================================
void OnTick()
  {
   // ── 1. Cập nhật xu hướng D1 ────────────────────────────────────
   double emaD1[1], closeD1[1];
   if(CopyBuffer(g_emaD1Handle, 0, 0, 1, emaD1) <= 0 || CopyClose(_Symbol, PERIOD_D1, 1, 1, closeD1) <= 0) return;

   bool isBullTrend = (closeD1[0] > emaD1[0]);
   bool isBearTrend = (closeD1[0] < emaD1[0]);

   // ── 2. Bộ lọc xu hướng: Hủy lệnh chờ trái chiều ─────────────────
   if(InpUseFilter)
     {
      if(isBearTrend) CancelPendingOrders(ORDER_TYPE_BUY_LIMIT);  // Hủy Buy Limit nếu trend giảm
      if(isBullTrend) CancelPendingOrders(ORDER_TYPE_SELL_LIMIT); // Hủy Sell Limit nếu trend tăng
     }

   // ── 3. Hủy các lệnh chờ đã vi phạm SL (Pivot bị phá) ─────────────
   CleanupInvalidOrders();

   // ── 4. Place Limit Orders (Chỉ chạy khi có nến mới hoặc định kỳ) ──
   datetime currentBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(currentBarTime != g_lastBarTime)
     {
      g_lastBarTime = currentBarTime;
      ManageZoneOrders(isBullTrend, isBearTrend);
     }
  }

//====================================================================
// MANAGE ZONE ORDERS — Quét zones và đặt Limit
//====================================================================
void ManageZoneOrders(bool isBull, bool isBear)
  {
   ZoneInfo zones[];
   if(!BuildZones(zones)) return;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   for(int i = 0; i < ArraySize(zones); i++)
     {
      ZoneInfo zone = zones[i];
      
      // Kiểm tra filter/allow
      if(InpUseFilter && zone.dir == 1 && !isBull)  continue;
      if(InpUseFilter && zone.dir == -1 && !isBear) continue;
      if(zone.dir == 1 && !InpAllowBuy)  continue;
      if(zone.dir == -1 && !InpAllowSell) continue;

      // Nếu đã có Position hoặc Pending Order cho vùng này thì bỏ qua
      if(ZoneHasPosition(zone.zoneID) || ZoneHasPending(zone.zoneID)) continue;

      // Đặt lệnh
      if(zone.dir == 1) // SUPPORT -> BUY
        {
         // Nếu giá hiện tại đã xuyên qua Entry nhưng chưa tới SL -> Vào Market luôn
         if(ask <= zone.entryLevel && ask > zone.slPrice)
           {
            double entry = ask;
            double sl    = NormalizeDouble(zone.slPrice, _Digits);
            double tp    = NormalizeDouble(entry + InpRiskReward * (entry - sl), _Digits);
            trade.Buy(InpFixedLot, _Symbol, entry, sl, tp, zone.zoneID);
           }
         // Nếu giá hiện tại vẫn ở trên -> Đặt Buy Limit
         else if(ask > zone.entryLevel)
           {
            double limitPrice = NormalizeDouble(zone.entryLevel, _Digits);
            double sl         = NormalizeDouble(zone.slPrice, _Digits);
            double tp         = NormalizeDouble(limitPrice + InpRiskReward * (limitPrice - sl), _Digits);
            trade.BuyLimit(InpFixedLot, limitPrice, _Symbol, sl, tp, ORDER_TIME_GTC, 0, zone.zoneID);
           }
        }
      else // RESISTANCE -> SELL
        {
         if(bid >= zone.entryLevel && bid < zone.slPrice)
           {
            double entry = bid;
            double sl    = NormalizeDouble(zone.slPrice, _Digits);
            double tp    = NormalizeDouble(entry - InpRiskReward * (sl - entry), _Digits);
            trade.Sell(InpFixedLot, _Symbol, entry, sl, tp, zone.zoneID);
           }
         else if(bid < zone.entryLevel)
           {
            double limitPrice = NormalizeDouble(zone.entryLevel, _Digits);
            double sl         = NormalizeDouble(zone.slPrice, _Digits);
            double tp         = NormalizeDouble(limitPrice - InpRiskReward * (sl - limitPrice), _Digits);
            trade.SellLimit(InpFixedLot, limitPrice, _Symbol, sl, tp, ORDER_TIME_GTC, 0, zone.zoneID);
           }
        }
     }
  }

//====================================================================
// CLEANUP INVALID ORDERS — Hủy lệnh nếu giá phá SL (vùng hết hiệu lực)
//====================================================================
void CleanupInvalidOrders()
  {
   double lastBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double lastAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(!OrderSelect(ticket)) continue;
      if(OrderGetInteger(ORDER_MAGIC) != InpMagicNumber) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;

      double sl = OrderGetDouble(ORDER_SL);
      ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);

      // Nếu là Buy Limit mà giá Ask đã rớt dưới SL -> pivot vỡ
      if(type == ORDER_TYPE_BUY_LIMIT && lastAsk <= sl)
        {
         trade.OrderDelete(ticket);
         PrintFormat("🗑️ Hủy Buy Limit [%s] - Giá đã phá SL trước khi khớp.", OrderGetString(ORDER_COMMENT));
        }
      // Nếu là Sell Limit mà giá Bid đã vượt trên SL -> pivot vỡ
      else if(type == ORDER_TYPE_SELL_LIMIT && lastBid >= sl)
        {
         trade.OrderDelete(ticket);
         PrintFormat("🗑️ Hủy Sell Limit [%s] - Giá đã phá SL trước khi khớp.", OrderGetString(ORDER_COMMENT));
        }
     }
  }

//====================================================================
// RE-USE LOGIC FROM v2.0
//====================================================================
bool BuildZones(ZoneInfo &zones[])
  {
   ArrayResize(zones, 0);
   int requiredBars = InpSwingLookback + InpSwingLength * 2 + 5;
   double h[], l[];
   if(CopyHigh(_Symbol, PERIOD_CURRENT, 1, requiredBars, h) <= 0 || CopyLow(_Symbol, PERIOD_CURRENT, 1, requiredBars, l) <= 0) return false;
   ArraySetAsSeries(h, true); ArraySetAsSeries(l, true);
   int limit = ArraySize(h) - InpSwingLength - 1;
   double overallH = h[ArrayMaximum(h, 0, limit)];
   double overallL = l[ArrayMinimum(l, 0, limit)];
   double refRange = overallH - overallL;
   if(refRange <= _Point * 5) return false;
   double buffer = InpBufferPips * g_pip;
   int cL = 0, cH = 0;
   for(int b = 0; b < limit && (cL < InpMaxZones || cH < InpMaxZones); b++)
     {
      int pivot = b + InpSwingLength;
      if(pivot + InpSwingLength >= ArraySize(h)) break;
      // Support
      bool isPL = true;
      for(int j = 1; j <= InpSwingLength; j++) if(l[pivot] >= l[pivot-j] || l[pivot] >= l[pivot+j]) { isPL = false; break; }
      if(isPL && cL < InpMaxZones)
        {
         ZoneInfo z; z.dir = 1; z.pivotPrice = l[pivot];
         z.entryLevel = l[pivot] + (InpSupportPct/100.0)*refRange;
         z.slPrice = l[pivot] - buffer; z.zoneID = StringFormat("SUP@%.5f", l[pivot]);
         int n = ArraySize(zones); ArrayResize(zones, n+1); zones[n] = z; cL++;
        }
      // Resist
      bool isPH = true;
      for(int j = 1; j <= InpSwingLength; j++) if(h[pivot] <= h[pivot-j] || h[pivot] <= h[pivot+j]) { isPH = false; break; }
      if(isPH && cH < InpMaxZones)
        {
         ZoneInfo z; z.dir = -1; z.pivotPrice = h[pivot];
         z.entryLevel = h[pivot] - (InpResistPct/100.0)*refRange;
         z.slPrice = h[pivot] + buffer; z.zoneID = StringFormat("RES@%.5f", h[pivot]);
         int n = ArraySize(zones); ArrayResize(zones, n+1); zones[n] = z; cH++;
        }
     }
   return true;
  }

void CancelPendingOrders(ENUM_ORDER_TYPE type)
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(!OrderSelect(ticket)) continue;
      if(OrderGetInteger(ORDER_MAGIC) != InpMagicNumber) continue;
      if(OrderGetInteger(ORDER_TYPE) == type) trade.OrderDelete(ticket);
     }
  }

bool ZoneHasPosition(string id)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!PositionSelectByTicket(PositionGetTicket(i))) continue;
      if(PositionGetInteger(POSITION_MAGIC) == InpMagicNumber && PositionGetString(POSITION_COMMENT) == id) return true;
     }
   return false;
  }

bool ZoneHasPending(string id)
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      if(!OrderSelect(OrderGetTicket(i))) continue;
      if(OrderGetInteger(ORDER_MAGIC) == InpMagicNumber && OrderGetString(ORDER_SYMBOL) == _Symbol && OrderGetString(ORDER_COMMENT) == id) return true;
     }
   return false;
  }
//+------------------------------------------------------------------+
