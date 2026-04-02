//+------------------------------------------------------------------+
//|                                       SMA12_Monthly_Investor.mq5 |
//|                                        Bản quyền: Đối tác lập trình|
//+------------------------------------------------------------------+
#property copyright "Đối tác lập trình"
#property version   "1.00"

#include <Trade\Trade.mqh>

//--- CÁC THÔNG SỐ ĐẦU VÀO (INPUT GROUPS) ---

input group "=== 1. Cài đặt Khối lượng ==="
input double   InpLotSize     = 0.1;       // Khối lượng Mua (Lot)
input ulong    InpMagicNumber = 777888;    // Magic Number để quản lý lệnh

input group "=== 2. Cài đặt Chỉ báo ==="
input int      InpSmaPeriod   = 12;        // Chu kỳ SMA (Mặc định: 12 tháng)

//--- BIẾN TOÀN CỤC ---
CTrade         trade;
int            handle_sma;
datetime       lastBarTime    = 0;

//+------------------------------------------------------------------+
//| Hàm Khởi tạo                                                     |
//+------------------------------------------------------------------+
int OnInit() {
    trade.SetExpertMagicNumber(InpMagicNumber);
    
    // Khởi tạo chỉ báo SMA
    // Lưu ý: PERIOD_CURRENT sẽ tự động lấy khung thời gian của biểu đồ bạn gắn bot vào
    handle_sma = iMA(_Symbol, PERIOD_CURRENT, InpSmaPeriod, 0, MODE_SMA, PRICE_CLOSE);
    
    if(handle_sma == INVALID_HANDLE) {
        Print("Lỗi: Không thể khởi tạo SMA. Vui lòng kiểm tra lại.");
        return(INIT_FAILED);
    }
    
    Print("Bot Đầu tư SMA 12 khởi chạy thành công! Hãy đảm bảo bạn đang bật biểu đồ Tháng (MN1).");
    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Hàm Hủy (Dọn dẹp bộ nhớ)                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
    IndicatorRelease(handle_sma);
}

//+------------------------------------------------------------------+
//| Hàm Tick (Chạy mỗi khi có giá mới)                               |
//+------------------------------------------------------------------+
void OnTick() {
    // 1. CHỈ CHẠY LOGIC KHI CÓ NẾN MỚI
    datetime currentBarTime = (datetime)SeriesInfoInteger(_Symbol, PERIOD_CURRENT, SERIES_LASTBAR_DATE);
    if(currentBarTime == lastBarTime) return; // Thoát nếu nến chưa đóng

    // 2. LẤY DỮ LIỆU NẾN VÀ SMA
    MqlRates rates[];
    double sma[];
    
    // Đảo ngược mảng để index 1 luôn là nến vừa đóng, index 2 là nến trước đó
    ArraySetAsSeries(rates, true);
    ArraySetAsSeries(sma, true);
    
    // Lấy 3 nến gần nhất là đủ để so sánh
    if(CopyRates(_Symbol, PERIOD_CURRENT, 0, 3, rates) < 0) return;
    if(CopyBuffer(handle_sma, 0, 0, 3, sma) < 0) return;

    // 3. KIỂM TRA TRẠNG THÁI VỊ THẾ HIỆN TẠI
    bool isLongOpen = false;
    ulong ticketToClose = 0;
    
    for(int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber) {
            if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) {
                isLongOpen = true;
                ticketToClose = ticket;
            }
        }
    }

    // 4. KIỂM TRA TÍN HIỆU (Dựa trên nến vừa đóng - Index 1)
    
    // TÍN HIỆU BÁN (EXIT TO CASH): Đang có lệnh Mua VÀ Giá đóng cửa < SMA
    if(isLongOpen && rates[1].close < sma[1]) {
        if(trade.PositionClose(ticketToClose)) {
            PrintFormat(">> [TÍN HIỆU EXIT] Giá đóng cửa (%.2f) cắt xuống SMA 12 (%.2f). Đã BÁN để giữ tiền mặt!", rates[1].close, sma[1]);
        }
    }
    
    // TÍN HIỆU MUA: Chưa có lệnh VÀ Giá đóng cửa cắt lên trên SMA
    else if(!isLongOpen && rates[1].close > sma[1] && rates[2].close <= sma[2]) {
        double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
        if(trade.Buy(InpLotSize, _Symbol, ask, 0, 0, "SMA 12 Long")) {
            PrintFormat(">> [TÍN HIỆU MUA] Giá đóng cửa (%.2f) cắt lên SMA 12 (%.2f). Bắt đầu chu kỳ Tăng trưởng!", rates[1].close, sma[1]);
        }
    }

    // Cập nhật lại thời gian nến
    lastBarTime = currentBarTime; 
}