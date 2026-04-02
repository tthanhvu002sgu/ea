//+------------------------------------------------------------------+
//|                                           Range_Breakout_EA.mq5  |
//|                                        Bản quyền: Đối tác lập trình|
//+------------------------------------------------------------------+
#property copyright "Đối tác lập trình"
#property version   "1.00"

#include <Trade\Trade.mqh>

//--- 1. CÁC THÔNG SỐ ĐẦU VÀO (INPUT GROUPS) ---

input group "=== 1. Thiết lập Vùng giá (Giờ Server) ==="
input int      InpRangeHourStart   = 3;      // Giờ bắt đầu đo Range (Mặc định: 3)
input int      InpRangeMinuteStart = 0;      // Phút bắt đầu đo Range
input int      InpRangeHourEnd     = 6;      // Giờ kết thúc đo Range (Mặc định: 6)
input int      InpRangeMinuteEnd   = 0;      // Phút kết thúc đo Range

input group "=== 2. Thiết lập Giao dịch ==="
input int      InpTradingEndHour   = 18;     // Giờ đóng toàn bộ lệnh cuối ngày (Mặc định: 18)
input int      InpTradingEndMinute = 0;      // Phút đóng toàn bộ lệnh

input group "=== 3. Quản lý Vốn (Risk Management) ==="
input double   InpRiskMoney        = 50.0;   // Số tiền rủi ro tối đa mỗi lệnh (USD)
input ulong    InpMagicNumber      = 102030; // Magic Number

//--- BIẾN TOÀN CỤC ---
CTrade         trade;
int            currentDay          = -1;     // Lưu ngày hiện tại để reset trạng thái
bool           isTrade             = false;  // Đảm bảo chỉ vào 1 lệnh mỗi ngày
bool           isRangeCalculated   = false;  // Đã tính toán Range hôm nay chưa?

double         RangeHigh           = 0;
double         RangeLow            = 0;

//+------------------------------------------------------------------+
//| Hàm Khởi tạo                                                     |
//+------------------------------------------------------------------+
int OnInit() {
    trade.SetExpertMagicNumber(InpMagicNumber);
    Print("Bot Morning Range Breakout khởi chạy thành công!");
    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Hàm Tick (Kiểm tra điều kiện liên tục)                           |
//+------------------------------------------------------------------+
void OnTick() {
    datetime currentTime = TimeCurrent();
    MqlDateTime dt;
    TimeToStruct(currentTime, dt);

    // 1. KIỂM TRA NGÀY MỚI (Reset các biến trạng thái)
    if(dt.day_of_year != currentDay) {
        currentDay = dt.day_of_year;
        isTrade = false;
        isRangeCalculated = false;
        RangeHigh = 0;
        RangeLow = 0;
    }

    // Thiết lập các mốc thời gian trong ngày hiện tại
    MqlDateTime startDt = dt; startDt.hour = InpRangeHourStart; startDt.min = InpRangeMinuteStart; startDt.sec = 0;
    MqlDateTime endDt   = dt; endDt.hour   = InpRangeHourEnd;   endDt.min   = InpRangeMinuteEnd;   endDt.sec = 0;
    MqlDateTime closeDt = dt; closeDt.hour = InpTradingEndHour; closeDt.min = InpTradingEndMinute; closeDt.sec = 0;

    datetime startTime = StructToTime(startDt);
    datetime endTime   = StructToTime(endDt);
    datetime closeTime = StructToTime(closeDt);

    // 2. ĐÓNG LỆNH CUỐI NGÀY
    if(currentTime >= closeTime) {
        CloseAllPositions();
        return; // Hết ngày rồi thì không làm gì thêm nữa
    }

    // 3. TÍNH TOÁN VÙNG GIÁ (Chỉ tính 1 lần sau khi kết thúc giờ đo Range)
    if(currentTime >= endTime && !isRangeCalculated) {
        CalculateMorningRange(startTime, endTime);
    }

    // 4. KIỂM TRA VÀO LỆNH (Nếu đã tính Range và chưa trade hôm nay)
    if(isRangeCalculated && !isTrade && currentTime >= endTime) {
        CheckBreakoutAndTrade();
    }
}

//+------------------------------------------------------------------+
//| Hàm tính toán Range và vẽ Hình chữ nhật                          |
//+------------------------------------------------------------------+
void CalculateMorningRange(datetime startTime, datetime endTime) {
    double high[], low[];
    
    // Copy dữ liệu High/Low của khung M1 trong khoảng thời gian Range
    int copiedHigh = CopyHigh(_Symbol, PERIOD_M1, startTime, endTime, high);
    int copiedLow  = CopyLow(_Symbol, PERIOD_M1, startTime, endTime, low);
    
    if(copiedHigh <= 0 || copiedLow <= 0) {
        Print("Chưa đủ dữ liệu M1 để tính Range. Sẽ thử lại...");
        return;
    }

    // Tìm giá trị lớn nhất và nhỏ nhất
    RangeHigh = high[ArrayMaximum(high)];
    RangeLow  = low[ArrayMinimum(low)];
    isRangeCalculated = true;

    PrintFormat(">> Xác định xong Range: High = %f, Low = %f", RangeHigh, RangeLow);

    // Vẽ Hình chữ nhật (Rectangle)
    string objName = "RangeBox_" + TimeToString(startTime, TIME_DATE);
    ObjectDelete(0, objName); // Xóa cái cũ nếu có
    ObjectCreate(0, objName, OBJ_RECTANGLE, 0, startTime, RangeHigh, endTime, RangeLow);
    ObjectSetInteger(0, objName, OBJPROP_COLOR, clrDodgerBlue);
    ObjectSetInteger(0, objName, OBJPROP_FILL, true); // Đổ màu nền
    ObjectSetInteger(0, objName, OBJPROP_BACK, true); // Nằm dưới nến
}

//+------------------------------------------------------------------+
//| Hàm kiểm tra Phá vỡ (Breakout) và Vào lệnh                       |
//+------------------------------------------------------------------+
void CheckBreakoutAndTrade() {
    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

    // Breakout Lên (Buy)
    if(ask > RangeHigh) {
        double lotSize = CalculateLotSize(RangeHigh, RangeLow);
        if(lotSize > 0) {
            trade.Buy(lotSize, _Symbol, ask, RangeLow, 0, "Morning Breakout Buy");
            isTrade = true;
            Print(">> Đã mở lệnh BUY phá vỡ cạnh trên!");
        }
    }
    // Breakout Xuống (Sell)
    else if(bid < RangeLow) {
        double lotSize = CalculateLotSize(RangeHigh, RangeLow);
        if(lotSize > 0) {
            trade.Sell(lotSize, _Symbol, bid, RangeHigh, 0, "Morning Breakout Sell");
            isTrade = true;
            Print(">> Đã mở lệnh SELL phá vỡ cạnh dưới!");
        }
    }
}

//+------------------------------------------------------------------+
//| Hàm tính toán khối lượng lệnh (Lot) theo Risk Money              |
//+------------------------------------------------------------------+
double CalculateLotSize(double highPrice, double lowPrice) {
    double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double lotStep   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    
    double rangeSize = highPrice - lowPrice;
    
    if(rangeSize <= 0 || tickSize <= 0 || tickValue <= 0) return 0.0;

    // Công thức tính Lot chuẩn theo yêu cầu
    double rawLot = InpRiskMoney / ((rangeSize / tickSize) * tickValue);
    
    // Làm tròn Lot theo quy định của sàn (Lot Step)
    double finalLot = MathFloor(rawLot / lotStep) * lotStep;
    
    // Ràng buộc Min/Max Lot
    double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    if(finalLot < minLot) finalLot = minLot;
    if(finalLot > maxLot) finalLot = maxLot;

    return finalLot;
}

//+------------------------------------------------------------------+
//| Hàm quét và Đóng lệnh cuối ngày                                  |
//+------------------------------------------------------------------+
void CloseAllPositions() {
    // Nếu không có lệnh nào thì bỏ qua để tiết kiệm tài nguyên
    if(PositionsTotal() == 0) return; 

    for(int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber) {
            if(trade.PositionClose(ticket)) {
                PrintFormat(">> Đã đóng lệnh #%llu vào cuối ngày.", ticket);
            }
        }
    }
}