//+------------------------------------------------------------------+
//|                                           Range_Breakout_EA.mq5  |
//|                                        Bản quyền: Đối tác lập trình|
//+------------------------------------------------------------------+
#property copyright "Đối tác lập trình"
#property version   "1.30"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\HistoryOrderInfo.mqh>

//--- ĐỊNH NGHĨA CÁC MENU LỰA CHỌN (ENUM) ---
enum ENUM_LOT_METHOD {
    CALC_FIXED_LOT, // Cố định Lot
    CALC_RISK_MONEY // Tính theo Risk (USD)
};

enum ENUM_EXIT_MODE {
    EXIT_TIME_ONLY,   // 1. Chỉ đóng theo Thời gian (Không TP)
    EXIT_RR_ONLY,     // 2. Chỉ đóng theo TP (Risk:Reward)
    EXIT_BOTH_TIME_RR // 3. Kết hợp (Chạm TP trước hoặc Hết giờ)
};

enum ENUM_STOP_CALC_MODE {
    CALC_MODE_OFF,     // Tắt (Dùng SL ở biên đối diện)
    CALC_MODE_FACTOR,  // Tính theo Hệ số (Factor x Range)
    CALC_MODE_PERCENT, // Tính theo % Giá vào lệnh
    CALC_MODE_POINTS   // Tính theo số Points cố định
};

//--- CÁC THÔNG SỐ ĐẦU VÀO (INPUT GROUPS) ---

input group "=== 1. Thiết lập Vùng giá (Giờ Server) ==="
input ENUM_TIMEFRAMES InpRangeTimeFrame   = PERIOD_M1;  // Khung thời gian đo Range
input int             InpRangeHourStart   = 3;      // Giờ bắt đầu đo Range
input int             InpRangeMinuteStart = 0;      // Phút bắt đầu đo Range
input int             InpRangeHourEnd     = 6;      // Giờ kết thúc đo Range
input int             InpRangeMinuteEnd   = 0;      // Phút kết thúc đo Range
input int             InpDeleteOrderHour  = 18;     // Giờ xóa lệnh chờ (Delete Order)
input int             InpDeleteOrderMinute= 0;      // Phút xóa lệnh chờ

input group "=== 2. Cài đặt Thời gian Đóng lệnh ==="
input int             InpTradingEndHour   = 18;     // Giờ đóng toàn bộ lệnh cuối ngày
input int             InpTradingEndMinute = 0;      // Phút đóng toàn bộ lệnh

input group "=== 3. Quản lý Khối lượng (Lot) ==="
input ENUM_LOT_METHOD InpLotMethod        = CALC_FIXED_LOT; // Cách tính Lot
input double          InpFixedLot         = 0.1;            // Khối lượng (Nếu chọn Cố định)
input double          InpRiskMoney        = 50.0;           // Risk Money USD (Nếu chọn Risk)
input ulong           InpMagicNumber      = 102030;         // Magic Number

input group "=== 4. Quản lý Chốt lời (Take Profit) ==="
input ENUM_EXIT_MODE  InpExitMode         = EXIT_BOTH_TIME_RR; // Phương pháp Chốt lệnh
input double          InpRiskReward       = 2.0;               // Tỷ lệ R:R (Ví dụ: 2.0 là 1 mất 2 được)

input group "=== 5. Quản lý Dừng lỗ (Stop Loss) ==="
input ENUM_STOP_CALC_MODE InpStopCalcMode = CALC_MODE_FACTOR; // Chế độ tính Stop Loss
input double              InpStopValue    = 1.0;              // Giá trị (Factor/Percent/Points)

input group "=== 6. Trading Frequency ==="
input int             InpMaxLongTrade     = 1;      // Max Long Trade
input int             InpMaxShortTrade    = 1;      // Max Short Trade
input int             InpMaxTotalTrade    = 2;      // Max Total Trade

input group "=== 7. Range Filter ==="
input int             InpMinRangePoint    = 0;      // Min Range (Points)
input double          InpMinRangePercent  = 0.0;    // Min Range (%)
input int             InpMaxRangePoint    = 100000; // Max Range (Points)
input double          InpMaxRangePercent  = 100.0;  // Max Range (%)

input group "=== 8. Trailing Stop (Chandelier) ==="
input bool            InpUseTrailing      = true;   // Kích hoạt Trailing Stop
input int             InpATRPeriod        = 22;     // ATR Period
input double          InpChandelierMult   = 3.0;    // Chandelier Multiplier

//--- BIẾN TOÀN CỤC ---
CTrade         trade;
CPositionInfo  posInfo;
int            currentDay          = -1;
int            dailyLongTrades     = 0;
int            dailyShortTrades    = 0;
bool           isRangeCalculated   = false;
double         RangeHigh           = 0;
double         RangeLow            = 0;
int            atrHandle           = INVALID_HANDLE;
string         eaStateStr          = "Khởi tạo";

// --- Biến tối ưu hiệu suất ---
bool           isTesting           = false;
bool           isOptimization      = false;
bool           isVisualMode        = false;
bool           dayFullyTraded      = false;   // Đã hết quota trade trong ngày
bool           closedForDay        = false;   // Đã đóng lệnh cuối ngày rồi
bool           deletedForDay       = false;   // Đã xóa pending orders rồi
bool           rangeFilterPassed   = false;   // Range filter đã pass (chỉ cần kiểm tra 1 lần)
bool           rangeFilterChecked  = false;   // Đã kiểm tra range filter chưa

// --- Biến cache cho Chandelier ---
datetime       lastChandelierBar   = 0;
double         cachedChandelierLong  = 0;
double         cachedChandelierShort = 0;

// --- Biến cache pre-computed cho SL/TP (dùng giá tại breakout level thay vì ask/bid) ---
double         precomputedSlDistBuy  = 0;
double         precomputedSlDistSell = 0;
double         precomputedSlBuy      = 0;
double         precomputedSlSell     = 0;
double         precomputedTpBuy      = 0;
double         precomputedTpSell     = 0;
bool           slTpPrecomputed       = false;

//+------------------------------------------------------------------+
//| Hàm Khởi tạo                                                     |
//+------------------------------------------------------------------+
int OnInit() {
    isTesting = (bool)MQLInfoInteger(MQL_TESTER);
    isOptimization = (bool)MQLInfoInteger(MQL_OPTIMIZATION);
    isVisualMode = (bool)MQLInfoInteger(MQL_VISUAL_MODE);
    
    trade.SetExpertMagicNumber(InpMagicNumber);
    
    atrHandle = iATR(_Symbol, PERIOD_CURRENT, InpATRPeriod);
    if(atrHandle == INVALID_HANDLE) {
        Print("Lỗi tạo ATR Indicator");
        return(INIT_FAILED);
    }

    datetime currentTime = TimeCurrent();
    MqlDateTime dt;
    TimeToStruct(currentTime, dt);
    currentDay = dt.day_of_year;

    RecoverState(currentTime, dt);
    
    UpdateDashboard();
    Print("Bot Morning Range v1.3 khởi chạy thành công!");
    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Hàm Deinit                                                       |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
    if(atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle);
    Comment(""); // Clear dashboard
    
    // Clean up range boxes created by EA
    for(int i = ObjectsTotal(0) - 1; i >= 0; i--) {
        string name = ObjectName(0, i);
        if(StringFind(name, "RangeBox_") == 0) {
            ObjectDelete(0, name);
        }
    }
}

//+------------------------------------------------------------------+
//| Phục hồi trạng thái khi EA restart (Crash/Mất điện)              |
//+------------------------------------------------------------------+
void RecoverState(datetime currentTime, MqlDateTime &dt) {
    dailyLongTrades = 0;
    dailyShortTrades = 0;
    isRangeCalculated = false;
    RangeHigh = 0;
    RangeLow = 0;
    eaStateStr = "Recovering...";

    // 1. Phục hồi số lệnh đã giao dịch trong ngày từ History
    HistorySelect(currentTime - dt.hour*3600 - dt.min*60 - dt.sec, currentTime + 86400); // Lịch sử ngày hôm nay
    for(int i = 0; i < HistoryDealsTotal(); i++) {
        ulong ticket = HistoryDealGetTicket(i);
        if(ticket > 0) {
            long magic = HistoryDealGetInteger(ticket, DEAL_MAGIC);
            string symbol = HistoryDealGetString(ticket, DEAL_SYMBOL);
            if(magic == InpMagicNumber && symbol == _Symbol) {
                if(HistoryDealGetInteger(ticket, DEAL_ENTRY) == DEAL_ENTRY_IN) {
                    if(HistoryDealGetInteger(ticket, DEAL_TYPE) == DEAL_TYPE_BUY) dailyLongTrades++;
                    else if(HistoryDealGetInteger(ticket, DEAL_TYPE) == DEAL_TYPE_SELL) dailyShortTrades++;
                }
            }
        }
    }

    // Đếm lệnh đang mở (nếu có lệnh in-market thì cũng được tính là đang trade)
    bool hasOpenTrades = false;
    for(int i = PositionsTotal() - 1; i >= 0; i--) {
        if(posInfo.SelectByIndex(i)) {
            if(posInfo.Magic() == InpMagicNumber && posInfo.Symbol() == _Symbol) {
                hasOpenTrades = true;
            }
        }
    }

    // 2. Tìm Object RangeBox của ngày hôm nay
    MqlDateTime startDt = dt; startDt.hour = InpRangeHourStart; startDt.min = InpRangeMinuteStart; startDt.sec = 0;
    datetime startTime = StructToTime(startDt);
    string objName = "RangeBox_" + TimeToString(startTime, TIME_DATE);
    
    if(ObjectFind(0, objName) >= 0) {
        RangeHigh = ObjectGetDouble(0, objName, OBJPROP_PRICE, 0); // Price 1 (High)
        RangeLow  = ObjectGetDouble(0, objName, OBJPROP_PRICE, 1); // Price 2 (Low)
        if(RangeHigh > 0 && RangeLow > 0) {
            isRangeCalculated = true;
            Print("Đã phục hồi RangeBox: High=", RangeHigh, " Low=", RangeLow);
        }
    }
    
    // Cập nhật flag quota
    dayFullyTraded = (dailyLongTrades + dailyShortTrades >= InpMaxTotalTrade);
    closedForDay = false;
    deletedForDay = false;
    rangeFilterChecked = false;
    slTpPrecomputed = false;
    
    if(dailyLongTrades > 0 || dailyShortTrades > 0 || hasOpenTrades) {
        eaStateStr = "Traded";
    } else if(isRangeCalculated) {
        eaStateStr = "Waiting Breakout";
    } else {
        eaStateStr = "Waiting for Range";
    }
}

//+------------------------------------------------------------------+
//| Cập nhật Dashboard                                               |
//+------------------------------------------------------------------+
void UpdateDashboard() {
    // Tắt hoàn toàn Dashboard khi Optimization (không có chart)
    if(isOptimization) return;
    
    // Trong Tester (không visual): cũng không cần vẽ Dashboard
    if(isTesting && !isVisualMode) return;
    
    string txt = "\n=== RANGE BREAKOUT RENE ===\n";
    txt += "State: " + eaStateStr + "\n";
    txt += StringFormat("Trades Today: Long (%d/%d) | Short (%d/%d)\n", dailyLongTrades, InpMaxLongTrade, dailyShortTrades, InpMaxShortTrade);
    
    if(isRangeCalculated) {
        double rangeSize = RangeHigh - RangeLow;
        double rangeSizePoints = rangeSize / SymbolInfoDouble(_Symbol, SYMBOL_POINT);
        txt += StringFormat("Range High: %.5f\n", RangeHigh);
        txt += StringFormat("Range Low : %.5f\n", RangeLow);
        txt += StringFormat("Range Size: %.1f Points\n", rangeSizePoints);
    } else {
        txt += "Range: Not calculated yet\n";
    }
    
    Comment(txt);
}

//+------------------------------------------------------------------+
//| Hàm Tick (Kiểm tra điều kiện liên tục)                           |
//+------------------------------------------------------------------+
void OnTick() {
    datetime currentTime = TimeCurrent();
    MqlDateTime dt;
    TimeToStruct(currentTime, dt);

    // 1. KIỂM TRA NGÀY MỚI (Reset)
    if(dt.day_of_year != currentDay) {
        currentDay = dt.day_of_year;
        dailyLongTrades = 0;
        dailyShortTrades = 0;
        isRangeCalculated = false;
        RangeHigh = 0;
        RangeLow = 0;
        dayFullyTraded = false;
        closedForDay = false;
        deletedForDay = false;
        rangeFilterChecked = false;
        rangeFilterPassed = false;
        slTpPrecomputed = false;
        eaStateStr = "Waiting for Range";
    }

    // Thiết lập các mốc thời gian
    MqlDateTime startDt = dt; startDt.hour = InpRangeHourStart; startDt.min = InpRangeMinuteStart; startDt.sec = 0;
    MqlDateTime endDt   = dt; endDt.hour   = InpRangeHourEnd;   endDt.min   = InpRangeMinuteEnd;   endDt.sec = 0;
    MqlDateTime closeDt = dt; closeDt.hour = InpTradingEndHour; closeDt.min = InpTradingEndMinute; closeDt.sec = 0;
    MqlDateTime delDt   = dt; delDt.hour   = InpDeleteOrderHour; delDt.min = InpDeleteOrderMinute; delDt.sec = 0;

    datetime startTime = StructToTime(startDt);
    datetime endTime   = StructToTime(endDt);
    datetime closeTime = StructToTime(closeDt);
    datetime deleteTime= StructToTime(delDt);

    if(currentTime < endTime) {
        eaStateStr = "Waiting for Range";
    } else if(currentTime >= endTime && isRangeCalculated) {
        if(eaStateStr != "Traded" && eaStateStr != "Trading Ended for Day") eaStateStr = "Waiting Breakout";
    }

    // XÓA LỆNH CHỜ KHI TỚI GIỜ (chỉ thực hiện 1 lần)
    if(currentTime >= deleteTime && !deletedForDay) {
        DeletePendingOrders();
        deletedForDay = true;
    }

    // 2. ĐÓNG LỆNH THEO THỜI GIAN (chỉ thực hiện 1 lần)
    if(currentTime >= closeTime) {
        if(!closedForDay) {
            if(InpExitMode == EXIT_TIME_ONLY || InpExitMode == EXIT_BOTH_TIME_RR) {
                CloseAllPositions();
            }
            closedForDay = true;
        }
        eaStateStr = "Trading Ended for Day";
        UpdateDashboard();
        return; // Hết ngày không quét tín hiệu nữa
    }

    // 3. TÍNH TOÁN VÙNG GIÁ
    if(currentTime >= endTime && !isRangeCalculated) {
        CalculateMorningRange(startTime, endTime);
    }

    // 4. KIỂM TRA VÀO LỆNH (bỏ qua nếu đã hết quota)
    if(isRangeCalculated && currentTime >= endTime && !dayFullyTraded) {
        CheckBreakoutAndTrade();
    }
    
    // 5. TRAILING STOP (chỉ khi có lệnh mở)
    if(InpUseTrailing) {
        ApplyChandelierTrailingStop();
    }
    
    UpdateDashboard();
}

//+------------------------------------------------------------------+
//| Trailing Stop (Chandelier) - Tối ưu: chỉ tính lại khi nến mới   |
//+------------------------------------------------------------------+
void ApplyChandelierTrailingStop() {
    // Early exit: không có position nào thì không cần quét
    if(PositionsTotal() == 0) return;
    
    // Kiểm tra có position nào của EA không (tránh tính toán nặng khi không cần)
    bool hasOurPositions = false;
    for(int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if(PositionSelectByTicket(ticket)) {
            if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber) {
                hasOurPositions = true;
                break;
            }
        }
    }
    if(!hasOurPositions) return;
    
    // Tính Chandelier 1 lần cho mỗi cây nến mới (dữ liệu từ nến đã đóng không đổi trong cùng 1 nến)
    datetime currentBarTime = (datetime)SeriesInfoInteger(_Symbol, PERIOD_CURRENT, SERIES_LASTBAR_DATE);
    
    if(currentBarTime != lastChandelierBar) {
        double atr[];
        if(CopyBuffer(atrHandle, 0, 1, 1, atr) <= 0) return;
        
        double high[], low[];
        if(CopyHigh(_Symbol, PERIOD_CURRENT, 1, InpATRPeriod, high) <= 0 || CopyLow(_Symbol, PERIOD_CURRENT, 1, InpATRPeriod, low) <= 0) return;
        
        double highestH = high[ArrayMaximum(high)];
        double lowestL = low[ArrayMinimum(low)];
        
        double atrValue = atr[0];
        cachedChandelierLong = NormalizeDouble(highestH - atrValue * InpChandelierMult, _Digits);
        cachedChandelierShort = NormalizeDouble(lowestL + atrValue * InpChandelierMult, _Digits);
        
        lastChandelierBar = currentBarTime;
    }
    
    // Áp dụng trailing cho các position của EA
    for(int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if(PositionSelectByTicket(ticket)) {
            if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber) {
                double currentSL = PositionGetDouble(POSITION_SL);
                long type = PositionGetInteger(POSITION_TYPE);
                double currentPrice = PositionGetDouble(POSITION_PRICE_CURRENT);
                
                if(type == POSITION_TYPE_BUY) {
                    // Dời SL lên nếu Chandelier cao hơn SL hiện tại (và phải thấp hơn giá hiện tại)
                    if(cachedChandelierLong > currentSL && cachedChandelierLong < currentPrice) {
                        trade.PositionModify(ticket, cachedChandelierLong, PositionGetDouble(POSITION_TP));
                    }
                } else if(type == POSITION_TYPE_SELL) {
                    // Dời SL xuống nếu Chandelier thấp hơn SL hiện tại (hoặc chưa có SL) và phải cao hơn giá hiện tại
                    if((cachedChandelierShort < currentSL || currentSL == 0) && cachedChandelierShort > currentPrice) {
                        trade.PositionModify(ticket, cachedChandelierShort, PositionGetDouble(POSITION_TP));
                    }
                }
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Tính toán Range & Vẽ Hộp                                         |
//+------------------------------------------------------------------+
void CalculateMorningRange(datetime startTime, datetime endTime) {
    double high[], low[];
    
    if(CopyHigh(_Symbol, InpRangeTimeFrame, startTime, endTime, high) <= 0 || 
       CopyLow(_Symbol, InpRangeTimeFrame, startTime, endTime, low) <= 0) return;

    RangeHigh = high[ArrayMaximum(high)];
    RangeLow  = low[ArrayMinimum(low)];
    isRangeCalculated = true;
    eaStateStr = "Waiting Breakout";

    // Vẽ hộp (bỏ qua khi Optimization hoặc Tester không visual)
    if(!isOptimization && (!isTesting || isVisualMode)) {
        string objName = "RangeBox_" + TimeToString(startTime, TIME_DATE);
        ObjectDelete(0, objName);
        ObjectCreate(0, objName, OBJ_RECTANGLE, 0, startTime, RangeHigh, endTime, RangeLow);
        ObjectSetInteger(0, objName, OBJPROP_COLOR, clrDodgerBlue);
        ObjectSetInteger(0, objName, OBJPROP_FILL, true);
        ObjectSetInteger(0, objName, OBJPROP_BACK, true);
    }
    
    // Pre-compute SL/TP dựa trên breakout level (RangeHigh/RangeLow) thay vì ask/bid
    // => Đảm bảo kết quả NHẤT QUÁN giữa Every Tick và M1 OHLC
    PrecomputeSlTp();
}

//+------------------------------------------------------------------+
//| Pre-compute SL/TP dựa trên mức breakout cố định                  |
//| Giải quyết sai khác Every Tick vs M1 OHLC                        |
//+------------------------------------------------------------------+
void PrecomputeSlTp() {
    double rangeSize = RangeHigh - RangeLow;
    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    
    // --- Range Filter (chỉ kiểm tra 1 lần) ---
    double rangeSizePoints = rangeSize / point;
    double rangeSizePercent = (rangeSize / RangeLow) * 100.0;
    
    rangeFilterChecked = true;
    if(rangeSizePoints < InpMinRangePoint || rangeSizePoints > InpMaxRangePoint) {
        rangeFilterPassed = false;
        return;
    }
    if(rangeSizePercent < InpMinRangePercent || rangeSizePercent > InpMaxRangePercent) {
        rangeFilterPassed = false;
        return;
    }
    rangeFilterPassed = true;
    
    // --- Tính SL distance dựa trên breakout level cố định ---
    // Dùng RangeHigh làm giá vào Buy, RangeLow làm giá vào Sell
    // => Kết quả GIỐNG NHAU bất kể mô hình tick
    precomputedSlDistBuy = rangeSize;
    precomputedSlDistSell = rangeSize;

    if(InpStopCalcMode == CALC_MODE_FACTOR) {
        precomputedSlDistBuy = rangeSize * InpStopValue;
        precomputedSlDistSell = rangeSize * InpStopValue;
    } else if(InpStopCalcMode == CALC_MODE_PERCENT) {
        precomputedSlDistBuy = RangeHigh * (InpStopValue / 100.0);
        precomputedSlDistSell = RangeLow * (InpStopValue / 100.0);
    } else if(InpStopCalcMode == CALC_MODE_POINTS) {
        precomputedSlDistBuy = InpStopValue * point;
        precomputedSlDistSell = InpStopValue * point;
    }

    // SL cố định dựa theo breakout level
    if(InpStopCalcMode == CALC_MODE_OFF) {
        precomputedSlBuy = RangeLow;
        precomputedSlSell = RangeHigh;
    } else {
        precomputedSlBuy = RangeHigh - precomputedSlDistBuy;
        precomputedSlSell = RangeLow + precomputedSlDistSell;
    }

    // TP cố định dựa theo breakout level
    precomputedTpBuy = 0;
    precomputedTpSell = 0;
    if(InpExitMode == EXIT_RR_ONLY || InpExitMode == EXIT_BOTH_TIME_RR) {
        precomputedTpBuy  = RangeHigh + (precomputedSlDistBuy * InpRiskReward);
        precomputedTpSell = RangeLow - (precomputedSlDistSell * InpRiskReward);
    }
    
    slTpPrecomputed = true;
}

//+------------------------------------------------------------------+
//| Kiểm tra Phá vỡ & Vào lệnh (Kết hợp R:R)                         |
//+------------------------------------------------------------------+
void CheckBreakoutAndTrade() {
    if(dayFullyTraded) return;
    
    // Range filter đã fail => không cần check nữa
    if(rangeFilterChecked && !rangeFilterPassed) return;
    
    // Chưa precompute SL/TP => không trade
    if(!slTpPrecomputed) return;

    // Phân tích trạng thái lệnh đang mở
    bool hasOpenLong = false;
    bool hasOpenShort = false;
    for(int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber) {
            long type = PositionGetInteger(POSITION_TYPE);
            if(type == POSITION_TYPE_BUY) hasOpenLong = true;
            if(type == POSITION_TYPE_SELL) hasOpenShort = true;
        }
    }

    bool canBuy = (!hasOpenLong) && (dailyLongTrades < InpMaxLongTrade) && ((dailyLongTrades + dailyShortTrades) < InpMaxTotalTrade);
    bool canSell = (!hasOpenShort) && (dailyShortTrades < InpMaxShortTrade) && ((dailyLongTrades + dailyShortTrades) < InpMaxTotalTrade);
    if(!canBuy && !canSell) return;

    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

    // Kích hoạt BUY - Dùng SL/TP đã pre-compute từ breakout level
    if(canBuy && ask > RangeHigh) {
        double lotSizeBuy = CalculateLotSize(precomputedSlDistBuy);
        if(lotSizeBuy <= 0) return;
        if(trade.Buy(lotSizeBuy, _Symbol, ask, precomputedSlBuy, precomputedTpBuy, "Breakout Buy")) {
            dailyLongTrades++;
            eaStateStr = "Traded";
            dayFullyTraded = (dailyLongTrades + dailyShortTrades >= InpMaxTotalTrade);
            PrintFormat(">> Mở BUY. Lot: %.2f | SL: %f | TP: %f", lotSizeBuy, precomputedSlBuy, precomputedTpBuy);
        }
    }
    // Kích hoạt SELL
    else if(canSell && bid < RangeLow) {
        double lotSizeSell = CalculateLotSize(precomputedSlDistSell);
        if(lotSizeSell <= 0) return;
        if(trade.Sell(lotSizeSell, _Symbol, bid, precomputedSlSell, precomputedTpSell, "Breakout Sell")) {
            dailyShortTrades++;
            eaStateStr = "Traded";
            dayFullyTraded = (dailyLongTrades + dailyShortTrades >= InpMaxTotalTrade);
            PrintFormat(">> Mở SELL. Lot: %.2f | SL: %f | TP: %f", lotSizeSell, precomputedSlSell, precomputedTpSell);
        }
    }
}

//+------------------------------------------------------------------+
//| Tính toán Lot (Hỗ trợ 2 chế độ: Cố định / Risk)                  |
//+------------------------------------------------------------------+
double CalculateLotSize(double slDistance) {
    if(InpLotMethod == CALC_FIXED_LOT) {
        return InpFixedLot;
    }

    double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double lotStep   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    
    if(slDistance <= 0 || tickSize <= 0 || tickValue <= 0) return 0.0;

    double rawLot = InpRiskMoney / ((slDistance / tickSize) * tickValue);
    double finalLot = MathFloor(rawLot / lotStep) * lotStep;
    
    double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    if(finalLot < minLot) finalLot = minLot;
    if(finalLot > maxLot) finalLot = maxLot;

    return finalLot;
}

//+------------------------------------------------------------------+
//| Đóng lệnh cuối ngày                                              |
//+------------------------------------------------------------------+
void CloseAllPositions() {
    if(PositionsTotal() == 0) return; 

    for(int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber) {
            trade.PositionClose(ticket);
        }
    }
}

//+------------------------------------------------------------------+
//| Xóa tất cả các lệnh chờ (Pending Orders)                         |
//+------------------------------------------------------------------+
void DeletePendingOrders() {
    if(OrdersTotal() == 0) return; 

    for(int i = OrdersTotal() - 1; i >= 0; i--) {
        ulong ticket = OrderGetTicket(i);
        if(OrderGetString(ORDER_SYMBOL) == _Symbol && OrderGetInteger(ORDER_MAGIC) == InpMagicNumber) {
            trade.OrderDelete(ticket);
        }
    }
}