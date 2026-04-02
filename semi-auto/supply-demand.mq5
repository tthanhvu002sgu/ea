//+------------------------------------------------------------------+
//|                                            Supply-Demand.mq5     |
//|                                                                  |
//|  SEMI-AUTO EA - Supply & Demand Zone Trading                     |
//|                                                                  |
//|  Cách hoạt động:                                                 |
//|  1. Trader vẽ Rectangle tại vùng S/R                            |
//|  2. Click vào box để EA nhận diện (đổi màu)                     |
//|  3. EA tự động đánh Sideway khi giá chạm biên                   |
//|  4. Nếu phá vỡ → EA đánh Breakout                               |
//|  5. Box tự xóa sau khi breakout                                  |
//+------------------------------------------------------------------+
#property copyright "Semi-Auto Supply Demand EA"
#property link      ""
#property version   "1.00"
#property strict

//--- Include Trade library
#include <Trade\Trade.mqh>
CTrade trade;

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                  |
//+------------------------------------------------------------------+
input group "══════════ 1. QUẢN LÝ VỐN (Money Management) ══════════"
input int      MagicNumber      = 2025;        // Magic Number
input double   LotSize          = 0.01;        // Khối lượng giao dịch
input bool     UseRiskPercent   = false;       // Sử dụng % rủi ro?
input double   RiskPercent      = 1.0;         // Rủi ro % (nếu bật)

input group "══════════ 2. SL & TP (Points) ══════════"
input int      StopLoss_Points  = 200;         // Stop Loss (Points)
input int      TakeProfit_Points = 400;        // Take Profit (Points)
input int      BreakoutBuffer   = 100;         // Khoảng cách Breakout (Points)

input group "══════════ 3. GIAO DIỆN (Visual) ══════════"
input color    ResistanceColor  = clrCrimson;      // Màu vùng Kháng cự (Resistance)
input color    SupportColor     = clrMediumSeaGreen; // Màu vùng Hỗ trợ (Support)
input color    ActiveZoneColor  = clrGold;         // Màu khi zone được kích hoạt
input color    BreakoutColor    = clrDodgerBlue;   // Màu khi breakout

input group "══════════ 4. CÀI ĐẶT KHÁC (Settings) ══════════"
input string   BoxPrefix        = "SD_";       // Tiền tố tên Box (SD_ = auto detect)
input bool     DeleteAfterBreakout = true;     // Xóa box sau breakout?
input bool     AllowMultipleTrades = false;    // Cho phép nhiều lệnh cùng zone?
input int      MaxTradesPerZone = 1;           // Số lệnh tối đa mỗi zone

//+------------------------------------------------------------------+
//| ZONE STRUCTURE                                                    |
//+------------------------------------------------------------------+
enum ZONE_TYPE
{
   ZONE_NONE = 0,
   ZONE_RESISTANCE = 1,    // Vùng kháng cự - Sell khi chạm, Buy khi breakout
   ZONE_SUPPORT = 2        // Vùng hỗ trợ - Buy khi chạm, Sell khi breakout
};

enum ZONE_STATE
{
   STATE_WAITING = 0,      // Chờ giá chạm
   STATE_SIDEWAY_ACTIVE = 1,  // Đã vào lệnh Sideway
   STATE_BREAKOUT = 2,     // Đã breakout
   STATE_COMPLETED = 3     // Hoàn thành (chờ xóa)
};

struct ZoneInfo
{
   string   objectName;
   ZONE_TYPE zoneType;
   ZONE_STATE state;
   double   priceTop;
   double   priceBottom;
   int      sidewayTicket;
   int      breakoutTicket;
   int      tradesCount;
   datetime lastTradeTime;
};

//+------------------------------------------------------------------+
//| GLOBAL VARIABLES                                                  |
//+------------------------------------------------------------------+
ZoneInfo zones[];
int zonesCount = 0;
string selectedObject = "";

//+------------------------------------------------------------------+
//| Expert initialization function                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- Initialize trade object
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(10);
   trade.SetTypeFilling(ORDER_FILLING_IOC);
   
   //--- Enable chart events
   ChartSetInteger(0, CHART_EVENT_OBJECT_CREATE, true);
   ChartSetInteger(0, CHART_EVENT_OBJECT_DELETE, true);
   ChartSetInteger(0, CHART_EVENT_MOUSE_MOVE, true);
   
   //--- Scan existing boxes
   ScanExistingBoxes();
   
   Print("✅ Semi-Auto Supply Demand EA đã khởi động!");
   Print("📌 Hướng dẫn: Vẽ Rectangle tại vùng S/R, sau đó click vào box để kích hoạt");
   Print("🟢 Click 1 lần = Support (Buy khi chạm)");
   Print("🔴 Click 2 lần = Resistance (Sell khi chạm)");
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Comment("");
   Print("👋 Semi-Auto Supply Demand EA đã dừng.");
}

//+------------------------------------------------------------------+
//| Expert tick function                                              |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- Scan and process all zones
   ProcessAllZones();
   
   //--- Update display
   UpdateDisplay();
}

//+------------------------------------------------------------------+
//| Chart event handler                                               |
//+------------------------------------------------------------------+
void OnChartEvent(const int id,
                  const long &lparam,
                  const double &dparam,
                  const string &sparam)
{
   //=================================================================
   // Xử lý click vào object (Rectangle)
   //=================================================================
   if(id == CHARTEVENT_OBJECT_CLICK)
   {
      string objName = sparam;
      
      //--- Kiểm tra xem có phải Rectangle không
      if(ObjectGetInteger(0, objName, OBJPROP_TYPE) == OBJ_RECTANGLE)
      {
         ProcessBoxClick(objName);
      }
   }
   
   //=================================================================
   // Xử lý tạo object mới
   //=================================================================
   if(id == CHARTEVENT_OBJECT_CREATE)
   {
      string objName = sparam;
      
      if(ObjectGetInteger(0, objName, OBJPROP_TYPE) == OBJ_RECTANGLE)
      {
         //--- Đổi tên nếu cần
         if(StringFind(objName, BoxPrefix) < 0)
         {
            string newName = BoxPrefix + IntegerToString((int)TimeCurrent());
            ObjectSetString(0, objName, OBJPROP_NAME, newName);
            Print("📦 Box mới được tạo: ", newName);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Process box click - Toggle zone type                              |
//+------------------------------------------------------------------+
void ProcessBoxClick(string objName)
{
   //--- Tìm zone trong mảng
   int zoneIndex = FindZoneByName(objName);
   
   if(zoneIndex < 0)
   {
      //--- Zone mới - thêm vào mảng là Support trước
      AddNewZone(objName, ZONE_SUPPORT);
      Print("🟢 Zone mới: ", objName, " = SUPPORT (Buy khi chạm biên dưới)");
   }
   else
   {
      //--- Toggle giữa Support và Resistance
      if(zones[zoneIndex].zoneType == ZONE_SUPPORT)
      {
         zones[zoneIndex].zoneType = ZONE_RESISTANCE;
         ObjectSetInteger(0, objName, OBJPROP_COLOR, ResistanceColor);
         Print("🔴 Zone đổi thành: RESISTANCE (Sell khi chạm biên trên)");
      }
      else if(zones[zoneIndex].zoneType == ZONE_RESISTANCE)
      {
         //--- Click lần 3 = xóa zone
         RemoveZone(zoneIndex);
         ObjectDelete(0, objName);
         Print("🗑️ Zone đã xóa: ", objName);
         return;
      }
   }
   
   //--- Cập nhật giá top/bottom
   UpdateZonePrices(FindZoneByName(objName));
}

//+------------------------------------------------------------------+
//| Add new zone to array                                             |
//+------------------------------------------------------------------+
void AddNewZone(string objName, ZONE_TYPE type)
{
   int size = ArraySize(zones);
   ArrayResize(zones, size + 1);
   
   zones[size].objectName = objName;
   zones[size].zoneType = type;
   zones[size].state = STATE_WAITING;
   zones[size].sidewayTicket = 0;
   zones[size].breakoutTicket = 0;
   zones[size].tradesCount = 0;
   zones[size].lastTradeTime = 0;
   
   //--- Set color
   color zoneColor = (type == ZONE_SUPPORT) ? SupportColor : ResistanceColor;
   ObjectSetInteger(0, objName, OBJPROP_COLOR, zoneColor);
   ObjectSetInteger(0, objName, OBJPROP_FILL, true);
   ObjectSetInteger(0, objName, OBJPROP_BACK, true);
   
   //--- Cập nhật giá
   UpdateZonePrices(size);
   
   zonesCount = size + 1;
}

//+------------------------------------------------------------------+
//| Update zone prices from rectangle                                 |
//+------------------------------------------------------------------+
void UpdateZonePrices(int zoneIndex)
{
   if(zoneIndex < 0 || zoneIndex >= ArraySize(zones))
      return;
   
   string objName = zones[zoneIndex].objectName;
   
   double price1 = ObjectGetDouble(0, objName, OBJPROP_PRICE, 0);
   double price2 = ObjectGetDouble(0, objName, OBJPROP_PRICE, 1);
   
   zones[zoneIndex].priceTop = MathMax(price1, price2);
   zones[zoneIndex].priceBottom = MathMin(price1, price2);
}

//+------------------------------------------------------------------+
//| Find zone by object name                                          |
//+------------------------------------------------------------------+
int FindZoneByName(string objName)
{
   for(int i = 0; i < ArraySize(zones); i++)
   {
      if(zones[i].objectName == objName)
         return i;
   }
   return -1;
}

//+------------------------------------------------------------------+
//| Remove zone from array                                            |
//+------------------------------------------------------------------+
void RemoveZone(int index)
{
   if(index < 0 || index >= ArraySize(zones))
      return;
   
   //--- Shift elements
   for(int i = index; i < ArraySize(zones) - 1; i++)
   {
      zones[i] = zones[i + 1];
   }
   
   ArrayResize(zones, ArraySize(zones) - 1);
   zonesCount = ArraySize(zones);
}

//+------------------------------------------------------------------+
//| Scan existing boxes on chart                                      |
//+------------------------------------------------------------------+
void ScanExistingBoxes()
{
   int total = ObjectsTotal(0, 0, OBJ_RECTANGLE);
   
   for(int i = 0; i < total; i++)
   {
      string objName = ObjectName(0, i, 0, OBJ_RECTANGLE);
      
      //--- Kiểm tra prefix
      if(StringFind(objName, BoxPrefix) >= 0)
      {
         //--- Xác định loại zone dựa trên màu
         color objColor = (color)ObjectGetInteger(0, objName, OBJPROP_COLOR);
         
         ZONE_TYPE type = ZONE_SUPPORT;
         if(objColor == ResistanceColor)
            type = ZONE_RESISTANCE;
         
         AddNewZone(objName, type);
         Print("📦 Phát hiện box cũ: ", objName, " | Type: ", EnumToString(type));
      }
   }
}

//+------------------------------------------------------------------+
//| Process all zones - Main logic                                    |
//+------------------------------------------------------------------+
void ProcessAllZones()
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bufferPoints = BreakoutBuffer * _Point;
   
   for(int i = ArraySize(zones) - 1; i >= 0; i--)
   {
      //--- Cập nhật giá zone (có thể trader đã dịch chuyển box)
      UpdateZonePrices(i);
      
      string objName = zones[i].objectName;
      
      //--- Kiểm tra box còn tồn tại không
      if(ObjectFind(0, objName) < 0)
      {
         RemoveZone(i);
         continue;
      }
      
      //--- Xử lý theo state
      switch(zones[i].state)
      {
         case STATE_WAITING:
            ProcessWaitingZone(i, bid, ask);
            break;
            
         case STATE_SIDEWAY_ACTIVE:
            ProcessSidewayZone(i, bid, ask, bufferPoints);
            break;
            
         case STATE_BREAKOUT:
            ProcessBreakoutZone(i);
            break;
            
         case STATE_COMPLETED:
            //--- Xóa zone nếu cần
            if(DeleteAfterBreakout)
            {
               ObjectDelete(0, zones[i].objectName);
               RemoveZone(i);
            }
            break;
      }
   }
}

//+------------------------------------------------------------------+
//| Process zone in WAITING state                                     |
//+------------------------------------------------------------------+
void ProcessWaitingZone(int zoneIndex, double bid, double ask)
{
   ZoneInfo zone = zones[zoneIndex];
   
   //--- Kiểm tra số lệnh tối đa
   if(!AllowMultipleTrades && zone.tradesCount >= MaxTradesPerZone)
      return;
   
   //=================================================================
   // SUPPORT ZONE: Buy khi giá chạm biên dưới
   //=================================================================
   if(zone.zoneType == ZONE_SUPPORT)
   {
      //--- Giá chạm vào zone từ trên xuống
      if(bid <= zone.priceTop && bid >= zone.priceBottom)
      {
         //--- Vào lệnh BUY (Sideway)
         if(OpenSidewayTrade(zoneIndex, ORDER_TYPE_BUY))
         {
            zones[zoneIndex].state = STATE_SIDEWAY_ACTIVE;
            ObjectSetInteger(0, zone.objectName, OBJPROP_COLOR, ActiveZoneColor);
            Print("🟢 SIDEWAY BUY tại Support Zone: ", zone.objectName);
         }
      }
   }
   
   //=================================================================
   // RESISTANCE ZONE: Sell khi giá chạm biên trên
   //=================================================================
   else if(zone.zoneType == ZONE_RESISTANCE)
   {
      //--- Giá chạm vào zone từ dưới lên
      if(ask >= zone.priceBottom && ask <= zone.priceTop)
      {
         //--- Vào lệnh SELL (Sideway)
         if(OpenSidewayTrade(zoneIndex, ORDER_TYPE_SELL))
         {
            zones[zoneIndex].state = STATE_SIDEWAY_ACTIVE;
            ObjectSetInteger(0, zone.objectName, OBJPROP_COLOR, ActiveZoneColor);
            Print("🔴 SIDEWAY SELL tại Resistance Zone: ", zone.objectName);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Process zone in SIDEWAY_ACTIVE state                              |
//+------------------------------------------------------------------+
void ProcessSidewayZone(int zoneIndex, double bid, double ask, double buffer)
{
   ZoneInfo zone = zones[zoneIndex];
   
   //=================================================================
   // SUPPORT ZONE: Kiểm tra breakout xuống
   //=================================================================
   if(zone.zoneType == ZONE_SUPPORT)
   {
      //--- Giá phá xuống dưới zone + buffer
      if(bid < zone.priceBottom - buffer)
      {
         //--- Breakout SELL
         if(OpenBreakoutTrade(zoneIndex, ORDER_TYPE_SELL))
         {
            zones[zoneIndex].state = STATE_BREAKOUT;
            ObjectSetInteger(0, zone.objectName, OBJPROP_COLOR, BreakoutColor);
            Print("💥 BREAKOUT SELL - Support Zone bị phá: ", zone.objectName);
         }
      }
   }
   
   //=================================================================
   // RESISTANCE ZONE: Kiểm tra breakout lên
   //=================================================================
   else if(zone.zoneType == ZONE_RESISTANCE)
   {
      //--- Giá phá lên trên zone + buffer
      if(ask > zone.priceTop + buffer)
      {
         //--- Breakout BUY
         if(OpenBreakoutTrade(zoneIndex, ORDER_TYPE_BUY))
         {
            zones[zoneIndex].state = STATE_BREAKOUT;
            ObjectSetInteger(0, zone.objectName, OBJPROP_COLOR, BreakoutColor);
            Print("💥 BREAKOUT BUY - Resistance Zone bị phá: ", zone.objectName);
         }
      }
   }
   
   //--- Kiểm tra xem lệnh sideway còn tồn tại không
   if(!IsPositionOpen(zone.sidewayTicket))
   {
      //--- Lệnh sideway đã đóng (TP/SL), reset zone về waiting
      zones[zoneIndex].state = STATE_WAITING;
      
      //--- Khôi phục màu gốc
      color originalColor = (zone.zoneType == ZONE_SUPPORT) ? SupportColor : ResistanceColor;
      ObjectSetInteger(0, zone.objectName, OBJPROP_COLOR, originalColor);
   }
}

//+------------------------------------------------------------------+
//| Process zone in BREAKOUT state                                    |
//+------------------------------------------------------------------+
void ProcessBreakoutZone(int zoneIndex)
{
   ZoneInfo zone = zones[zoneIndex];
   
   //--- Kiểm tra xem lệnh breakout còn tồn tại không
   if(!IsPositionOpen(zone.breakoutTicket))
   {
      //--- Hoàn thành chu kỳ
      zones[zoneIndex].state = STATE_COMPLETED;
      Print("✅ Zone hoàn thành chu kỳ: ", zone.objectName);
   }
}

//+------------------------------------------------------------------+
//| Open Sideway Trade                                                |
//+------------------------------------------------------------------+
bool OpenSidewayTrade(int zoneIndex, ENUM_ORDER_TYPE orderType)
{
   double price, sl, tp;
   double lot = CalculateLotSize();
   
   double slPoints = StopLoss_Points * _Point;
   double tpPoints = TakeProfit_Points * _Point;
   
   if(orderType == ORDER_TYPE_BUY)
   {
      price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      sl = price - slPoints;
      tp = price + tpPoints;
   }
   else
   {
      price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      sl = price + slPoints;
      tp = price - tpPoints;
   }
   
   //--- Chuẩn hóa giá
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   sl = NormalizeDouble(sl, digits);
   tp = NormalizeDouble(tp, digits);
   
   //--- Thực hiện lệnh
   string comment = "SD_Sideway_" + zones[zoneIndex].objectName;
   bool result = false;
   
   if(orderType == ORDER_TYPE_BUY)
      result = trade.Buy(lot, _Symbol, 0, sl, tp, comment);
   else
      result = trade.Sell(lot, _Symbol, 0, sl, tp, comment);
   
   if(result)
   {
      zones[zoneIndex].sidewayTicket = (int)trade.ResultOrder();
      zones[zoneIndex].tradesCount++;
      zones[zoneIndex].lastTradeTime = TimeCurrent();
      return true;
   }
   
   Print("❌ Lỗi mở lệnh Sideway: ", GetLastError());
   return false;
}

//+------------------------------------------------------------------+
//| Open Breakout Trade                                               |
//+------------------------------------------------------------------+
bool OpenBreakoutTrade(int zoneIndex, ENUM_ORDER_TYPE orderType)
{
   double price, sl, tp;
   double lot = CalculateLotSize();
   
   double slPoints = StopLoss_Points * _Point;
   double tpPoints = TakeProfit_Points * _Point;
   
   if(orderType == ORDER_TYPE_BUY)
   {
      price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      sl = price - slPoints;
      tp = price + tpPoints;
   }
   else
   {
      price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      sl = price + slPoints;
      tp = price - tpPoints;
   }
   
   //--- Chuẩn hóa giá
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   sl = NormalizeDouble(sl, digits);
   tp = NormalizeDouble(tp, digits);
   
   //--- Thực hiện lệnh
   string comment = "SD_Breakout_" + zones[zoneIndex].objectName;
   bool result = false;
   
   if(orderType == ORDER_TYPE_BUY)
      result = trade.Buy(lot, _Symbol, 0, sl, tp, comment);
   else
      result = trade.Sell(lot, _Symbol, 0, sl, tp, comment);
   
   if(result)
   {
      zones[zoneIndex].breakoutTicket = (int)trade.ResultOrder();
      zones[zoneIndex].tradesCount++;
      return true;
   }
   
   Print("❌ Lỗi mở lệnh Breakout: ", GetLastError());
   return false;
}

//+------------------------------------------------------------------+
//| Calculate lot size based on risk                                  |
//+------------------------------------------------------------------+
double CalculateLotSize()
{
   if(!UseRiskPercent)
      return LotSize;
   
   double accountBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount = accountBalance * (RiskPercent / 100.0);
   
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   
   if(tickValue == 0 || tickSize == 0)
      return LotSize;
   
   double slPips = StopLoss_Points * _Point / tickSize;
   double lot = riskAmount / (slPips * tickValue);
   
   lot = MathFloor(lot / lotStep) * lotStep;
   lot = MathMax(lot, minLot);
   
   return NormalizeDouble(lot, 2);
}

//+------------------------------------------------------------------+
//| Check if position is still open                                   |
//+------------------------------------------------------------------+
bool IsPositionOpen(int ticket)
{
   if(ticket <= 0)
      return false;
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong posTicket = PositionGetTicket(i);
      if(posTicket == (ulong)ticket)
         return true;
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Update display                                                    |
//+------------------------------------------------------------------+
void UpdateDisplay()
{
   string info = "";
   info += "══════════════════════════════════════\n";
   info += "   📊 SEMI-AUTO SUPPLY & DEMAND EA\n";
   info += "══════════════════════════════════════\n";
   info += "🎯 Active Zones: " + IntegerToString(ArraySize(zones)) + "\n";
   info += "──────────────────────────────────────\n";
   
   for(int i = 0; i < ArraySize(zones); i++)
   {
      string typeStr = (zones[i].zoneType == ZONE_SUPPORT) ? "🟢 SUPPORT" : "🔴 RESISTANCE";
      string stateStr = "";
      
      switch(zones[i].state)
      {
         case STATE_WAITING:        stateStr = "⏳ Waiting";    break;
         case STATE_SIDEWAY_ACTIVE: stateStr = "🔄 Sideway";    break;
         case STATE_BREAKOUT:       stateStr = "💥 Breakout";   break;
         case STATE_COMPLETED:      stateStr = "✅ Completed";  break;
      }
      
      info += StringFormat("%s | %s\n   %.5f - %.5f | %s\n",
                           zones[i].objectName, typeStr,
                           zones[i].priceBottom, zones[i].priceTop,
                           stateStr);
   }
   
   info += "──────────────────────────────────────\n";
   info += "📌 Click box: Support ↔ Resistance ↔ Xóa\n";
   info += "══════════════════════════════════════";
   
   Comment(info);
}
//+------------------------------------------------------------------+
