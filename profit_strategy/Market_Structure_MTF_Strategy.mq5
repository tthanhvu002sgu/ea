//+------------------------------------------------------------------+
//|                    Market Structure MTF Strategy.mq5             |
//|                                              Antigravity AI      |
//+------------------------------------------------------------------+
//  v2.0 — DCA per Zone (Fixed Lot, R:R SL/TP)
//
//  FLOW:
//  ┌─ Filter  : EMA 30 D1 — chỉ mua khi trend D1 tăng,
//  │            chỉ bán khi trend D1 giảm
//  ├─ Zones   : Quét N pivot Low (support) + N pivot High (resistance)
//  │            mỗi pivot tạo ra 1 vùng độc lập
//  ├─ Buy     : Khi giá hồi về vùng hỗ trợ (mặc định 50% từ đáy pivot)
//  │            entryLevel = pivotLow + SupportPct% × refRange
//  ├─ Sell    : Khi giá hồi về vùng kháng cự (mặc định 50% từ đỉnh pivot)
//  │            entryLevel = pivotHigh − ResistPct% × refRange
//  ├─ DCA     : Mỗi vùng được mở TỐI ĐA 1 lệnh (theo dõi qua comment)
//  ├─ SL Buy  : Dưới pivotLow − buffer
//  ├─ SL Sell : Trên pivotHigh + buffer
//  └─ TP      : Theo R:R (mặc định 1:2)
//+------------------------------------------------------------------+
#property copyright "Antigravity AI"
#property link      ""
#property version   "2.00"
#property description "Market Structure MTF Strategy v2 — DCA per Zone, Fixed Lot, R:R"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

//====================================================================
// STRUCT
//====================================================================
struct ZoneInfo
  {
   double   pivotPrice;   // Giá pivot (Pivot Low hoặc Pivot High)
   int      dir;          // 1 = Support (Buy), -1 = Resistance (Sell)
   double   entryLevel;   // Ngưỡng kích hoạt (giá chạm → vào lệnh)
   double   slPrice;      // Stop Loss price
   string   zoneID;       // ID duy nhất để track lệnh: "SUP@1.23456"
  };

//====================================================================
// INPUTS
//====================================================================

// ─── Bộ lọc xu hướng ──────────────────────────────────────────────
sinput string  gFilter           = "═══ BỘ LỌC XU HƯỚNG ═══";
input  int     InpEmaD1          = 30;      // Chu kỳ EMA D1
input  bool    InpUseFilter      = true;    // Bật bộ lọc EMA D1

// ─── Cấu trúc thị trường ─────────────────────────────────────────
sinput string  gSwing            = "═══ CẤU TRÚC THỊ TRƯỜNG ═══";
input  int     InpSwingLength    = 5;       // Pivot lookback (số nến mỗi bên)
input  int     InpSwingLookback  = 150;     // Số nến quét để tìm zones
input  int     InpMaxZones       = 3;       // Số vùng tối đa mỗi loại (H/L)

// ─── Vùng vào lệnh ───────────────────────────────────────────────
sinput string  gEntry            = "═══ VÙNG VÀO LỆNH ═══";
input  double  InpSupportPct     = 50.0;    // % Entry vùng hỗ trợ (0–100, từ đáy pivot lên)
input  double  InpResistPct      = 50.0;    // % Entry vùng kháng cự (0–100, từ đỉnh pivot xuống)

// ─── Quản lý rủi ro ──────────────────────────────────────────────
sinput string  gRisk             = "═══ QUẢN LÝ RỦI RO ═══";
input  double  InpBufferPips     = 10.0;    // Buffer SL ngoài pivot (pips)
input  double  InpRiskReward     = 1.25;     // R:R — Risk : Reward
input  double  InpFixedLot       = 0.01;    // Lot cố định mỗi lệnh

// ─── Cài đặt EA ──────────────────────────────────────────────────
sinput string  gEA               = "═══ CÀI ĐẶT EA ═══";
input  int     InpMagicNumber    = 20260301; // Magic Number
input  int     InpMaxPositions   = 2;        // Tổng số lệnh tối đa (cap toàn bộ)
input  bool    InpAllowBuy       = true;     // Cho phép lệnh Buy
input  bool    InpAllowSell      = true;     // Cho phép lệnh Sell

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

   // Pip size
   g_pip = (_Digits == 5 || _Digits == 3) ? _Point * 10 : _Point;

   // EMA D1 handle
   g_emaD1Handle = iMA(_Symbol, PERIOD_D1, InpEmaD1, 0, MODE_EMA, PRICE_CLOSE);
   if(g_emaD1Handle == INVALID_HANDLE)
     {
      Print("Lỗi: Không tạo được EMA D1 handle! Code=", GetLastError());
      return INIT_FAILED;
     }

   // Validate inputs
   if(InpSupportPct <= 0 || InpSupportPct > 100)
     { Alert("InpSupportPct phải từ 1–100!"); return INIT_PARAMETERS_INCORRECT; }
   if(InpResistPct  <= 0 || InpResistPct  > 100)
     { Alert("InpResistPct phải từ 1–100!"); return INIT_PARAMETERS_INCORRECT; }
   if(InpMaxZones < 1 || InpMaxZones > 10)
     { Alert("InpMaxZones phải từ 1–10!"); return INIT_PARAMETERS_INCORRECT; }

   PrintFormat("MS MTF Strategy v2 | EMA D1=%d | Support=%.0f%% | Resist=%.0f%% | "
               "RR=1:%.1f | MaxZones=%d | Lot=%.2f",
               InpEmaD1, InpSupportPct, InpResistPct, InpRiskReward,
               InpMaxZones, InpFixedLot);
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   if(g_emaD1Handle != INVALID_HANDLE)
      IndicatorRelease(g_emaD1Handle);
  }

//====================================================================
// ON TICK — chỉ xử lý tại nến mới
//====================================================================
void OnTick()
  {
   // Chỉ chạy khi mở nến mới
   datetime currentBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(currentBarTime == g_lastBarTime) return;
   g_lastBarTime = currentBarTime;

   // Kiểm tra tổng số lệnh
   if(CountOpenPositions() >= InpMaxPositions) return;

   // ── 1. EMA D1 — Bộ lọc xu hướng ────────────────────────────────
   double emaD1[1];
   if(CopyBuffer(g_emaD1Handle, 0, 0, 1, emaD1) <= 0)
     { Print("Lỗi CopyBuffer EMA D1: ", GetLastError()); return; }

   double closeD1[1];
   if(CopyClose(_Symbol, PERIOD_D1, 1, 1, closeD1) <= 0) return;

   bool isBullTrend = (closeD1[0] > emaD1[0]);
   bool isBearTrend = (closeD1[0] < emaD1[0]);

   // ── 2. Lấy giá tham chiếu (nến đã đóng, tránh repaint) ─────────
   double curClose = iClose(_Symbol, PERIOD_CURRENT, 1);
   double buffer   = InpBufferPips * g_pip;

   // ── 3. Build tất cả zones từ pivot H/L gần nhất ─────────────────
   ZoneInfo zones[];
   if(!BuildZones(zones)) return;

   int totalZones = ArraySize(zones);
   if(totalZones == 0) return;

   // ── 4. Duyệt từng zone, check và vào lệnh ───────────────────────
   for(int z = 0; z < totalZones; z++)
     {
      if(CountOpenPositions() >= InpMaxPositions) break;

      ZoneInfo  zone = zones[z];
      bool      isBuy  = (zone.dir == 1);
      bool      isSell = (zone.dir == -1);

      // Kiểm tra bộ lọc xu hướng
      if(InpUseFilter)
        {
         if(isBuy  && !isBullTrend) continue;
         if(isSell && !isBearTrend) continue;
        }

      // Kiểm tra allow
      if(isBuy  && !InpAllowBuy)  continue;
      if(isSell && !InpAllowSell) continue;

      // Kiểm tra giá có trong vùng không
      bool priceInZone = isBuy  ? (curClose <= zone.entryLevel) :
                                  (curClose >= zone.entryLevel);
      if(!priceInZone) continue;

      // Kiểm tra zone này đã có lệnh chưa (DCA — 1 lệnh/zone)
      if(ZoneHasPosition(zone.zoneID)) continue;

      // ── Vào lệnh ──────────────────────────────────────────────────
      if(isBuy)
        {
         double entryPrice = NormalizeDouble(SymbolInfoDouble(_Symbol, SYMBOL_ASK), _Digits);
         double slPrice    = NormalizeDouble(zone.slPrice, _Digits);
         double slDist     = entryPrice - slPrice;
         if(slDist <= 0) continue;
         double tpPrice    = NormalizeDouble(entryPrice + InpRiskReward * slDist, _Digits);
         double lot        = NormalizeLot(InpFixedLot);

         bool ok = trade.Buy(lot, _Symbol, entryPrice, slPrice, tpPrice, zone.zoneID);
         if(ok)
            PrintFormat("✅ BUY  [%s] | Entry=%.5f | SL=%.5f (%.1fpips) | TP=%.5f | Lot=%.2f",
                        zone.zoneID, entryPrice, slPrice, slDist / g_pip, tpPrice, lot);
         else
            PrintFormat("❌ BUY failed [%s] | Error=%d | Ret=%s",
                        zone.zoneID, GetLastError(), trade.ResultRetcodeDescription());
        }
      else // isSell
        {
         double entryPrice = NormalizeDouble(SymbolInfoDouble(_Symbol, SYMBOL_BID), _Digits);
         double slPrice    = NormalizeDouble(zone.slPrice, _Digits);
         double slDist     = slPrice - entryPrice;
         if(slDist <= 0) continue;
         double tpPrice    = NormalizeDouble(entryPrice - InpRiskReward * slDist, _Digits);
         double lot        = NormalizeLot(InpFixedLot);

         bool ok = trade.Sell(lot, _Symbol, entryPrice, slPrice, tpPrice, zone.zoneID);
         if(ok)
            PrintFormat("✅ SELL [%s] | Entry=%.5f | SL=%.5f (%.1fpips) | TP=%.5f | Lot=%.2f",
                        zone.zoneID, entryPrice, slPrice, slDist / g_pip, tpPrice, lot);
         else
            PrintFormat("❌ SELL failed [%s] | Error=%d | Ret=%s",
                        zone.zoneID, GetLastError(), trade.ResultRetcodeDescription());
        }
     }
  }

//====================================================================
// BUILD ZONES — tìm N pivot Low (support) + N pivot High (resistance)
//====================================================================
//
//  Zone ID format : "SUP@1.23456"  /  "RES@1.23456"
//
//  Entry logic per zone:
//    Support : entryLevel = pivotLow  + SupportPct% × refRange
//              (giá hồi lên chạm đỉnh vùng hỗ trợ → bật lên)
//    Resist  : entryLevel = pivotHigh − ResistPct%  × refRange
//              (giá hồi xuống chạm đáy vùng kháng cự → bật xuống)
//
//  refRange = overall (swingH − swingL) của lookback — để tất cả
//  zones dùng cùng 1 reference scale.
//
//====================================================================
bool BuildZones(ZoneInfo &zones[])
  {
   ArrayResize(zones, 0);

   int requiredBars = InpSwingLookback + InpSwingLength * 2 + 5;

   double h[], l[];
   if(CopyHigh(_Symbol, PERIOD_CURRENT, 1, requiredBars, h) <= 0) return false;
   if(CopyLow (_Symbol, PERIOD_CURRENT, 1, requiredBars, l) <= 0) return false;

   ArraySetAsSeries(h, true);
   ArraySetAsSeries(l, true);

   int limit = ArraySize(h) - InpSwingLength - 1;

   // Tính refRange (overall H/L trong lookback)
   double overallH = h[ArrayMaximum(h, 0, limit)];
   double overallL = l[ArrayMinimum(l, 0, limit)];
   double refRange = overallH - overallL;
   if(refRange <= _Point * 5) return false;

   double buffer  = InpBufferPips * g_pip;
   int    countH  = 0; // pivot highs tìm được
   int    countL  = 0; // pivot lows tìm được

   // Quét từ gần nhất → cũ hơn
   for(int b = 0; b < limit && (countH < InpMaxZones || countL < InpMaxZones); b++)
     {
      int pivot = b + InpSwingLength;
      if(pivot + InpSwingLength >= ArraySize(h)) break;

      // ── Pivot Low → Support zone ──────────────────────────────────
      if(countL < InpMaxZones)
        {
         bool isPL = true;
         for(int j = 1; j <= InpSwingLength; j++)
            if(l[pivot] >= l[pivot - j] || l[pivot] >= l[pivot + j])
              { isPL = false; break; }

         if(isPL)
           {
            ZoneInfo z;
            z.dir        = 1;
            z.pivotPrice = l[pivot];
            z.entryLevel = NormalizeDouble(l[pivot] + (InpSupportPct / 100.0) * refRange, _Digits);
            z.slPrice    = NormalizeDouble(l[pivot] - buffer, _Digits);
            z.zoneID     = StringFormat("SUP@%.5f", l[pivot]);

            int n = ArraySize(zones);
            ArrayResize(zones, n + 1);
            zones[n] = z;
            countL++;
           }
        }

      // ── Pivot High → Resistance zone ─────────────────────────────
      if(countH < InpMaxZones)
        {
         bool isPH = true;
         for(int j = 1; j <= InpSwingLength; j++)
            if(h[pivot] <= h[pivot - j] || h[pivot] <= h[pivot + j])
              { isPH = false; break; }

         if(isPH)
           {
            ZoneInfo z;
            z.dir        = -1;
            z.pivotPrice = h[pivot];
            z.entryLevel = NormalizeDouble(h[pivot] - (InpResistPct / 100.0) * refRange, _Digits);
            z.slPrice    = NormalizeDouble(h[pivot] + buffer, _Digits);
            z.zoneID     = StringFormat("RES@%.5f", h[pivot]);

            int n = ArraySize(zones);
            ArrayResize(zones, n + 1);
            zones[n] = z;
            countH++;
           }
        }
     }

   return (ArraySize(zones) > 0);
  }

//====================================================================
// ZONE HAS POSITION — kiểm tra zone này đã có lệnh đang mở chưa
// Dùng POSITION_COMMENT chứa zoneID để nhận dạng
//====================================================================
bool ZoneHasPosition(const string &zoneID)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)  != _Symbol)       continue;
      if(PositionGetInteger(POSITION_MAGIC)  != InpMagicNumber) continue;
      if(PositionGetString(POSITION_COMMENT) == zoneID) return true;
     }
   return false;
  }

//====================================================================
// LOT NORMALIZATION
//====================================================================
double NormalizeLot(double lot)
  {
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(stepLot <= 0) stepLot = 0.01;
   lot = MathFloor(lot / stepLot) * stepLot;
   lot = MathMax(lot, minLot);
   lot = MathMin(lot, maxLot);
   return NormalizeDouble(lot, 2);
  }

//====================================================================
// COUNT OPEN POSITIONS (theo magic + symbol)
//====================================================================
int CountOpenPositions()
  {
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!PositionSelectByTicket(PositionGetTicket(i))) continue;
      if(PositionGetString(POSITION_SYMBOL)  == _Symbol &&
         PositionGetInteger(POSITION_MAGIC)  == InpMagicNumber)
         count++;
     }
   return count;
  }
//+------------------------------------------------------------------+
