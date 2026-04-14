//+------------------------------------------------------------------+
//|                                     US30_Advanced_Breakout.mq5   |
//|                                        Bản quyền: Đối tác lập trình|
//+------------------------------------------------------------------+
#property copyright "Đối tác lập trình"
#property version   "2.00"

#include <Trade\Trade.mqh>

//--- ENUMS CHO GIAO DIỆN ---
enum ENUM_TRADING_VOLUME {
    VOLUME_FIXED,           // VOLUME_FIXED
    VOLUME_MANAGED,         // VOLUME_MANAGED (Fixed Lots per Money)
    VOLUME_PERCENT,         // VOLUME_PERCENT (% Balance)
    VOLUME_MONEY            // VOLUME_MONEY (Risk Money USD)
};

enum ENUM_CALC_MODE {
    CALC_MODE_OFF,          // Tắt (Không sử dụng)
    CALC_MODE_PERCENT,      // Tính theo % giá trị (Percent of price)
    CALC_MODE_POINTS        // Tính theo Points
};

//--- INPUT PARAMETERS ---

input group "+--- General Settings ---+"
input bool                InpWaitNewDayHigh    = false;              // Wait For New Day High
input ENUM_TRADING_VOLUME InpTradingVolume     = VOLUME_PERCENT;     // Trading Volume
input double              InpFixedLots         = 0.01;               // Fixed Lots
input double              InpFixedLotsPerMoney = 1000.0;             // Fixed Lots Per x Money
input double              InpRiskPercent       = 100;                // Risk Percentage of Balance
input double              InpRiskMoney         = 50.0;               // Risk Money
input ENUM_CALC_MODE      InpTargetCalcMode    = CALC_MODE_OFF;      // Target Calc Mode
input double              InpTargetValue       = 0.0;                // Target Value
input ENUM_CALC_MODE      InpStopCalcMode      = CALC_MODE_PERCENT;  // Stop Calc Mode
input double              InpStopValue         = 5.0;                // Stop Value

input group "+--- Time Settings ---+"
input int                 InpObserveStartHour  = 1;                  // Observe Start Hour (Custom add for Logic)
input int                 InpObserveStartMin   = 5;                  // Observe Start Minute
input int                 InpTradingStartHour  = 1;                  // Trading Start Hour
input int                 InpTradingStartMinute= 5;                  // Trading Start Minute
input bool                InpClosePositions    = true;               // Close Positions
input int                 InpClosePositionHour = 22;                 // Close Position Hour
input int                 InpClosePositionMin  = 55;                 // Close Position Minute

input group "+--- Trailing Stop Settings ---+"
input ENUM_CALC_MODE      InpBEStopCalcMode    = CALC_MODE_OFF;      // BE Stop Calc Mode
input double              InpBEStopTriggerVal  = 0.0;                // BE Stop Trigger Value
input double              InpBEStopBufferVal   = 0.05;               // BE Stop Buffer Value
input ENUM_CALC_MODE      InpTSLCalcMode       = CALC_MODE_OFF;      // TSL Calc Mode
input double              InpTSLTriggerValue   = 0.0;                // TSL Trigger Value
input double              InpTSLValue          = 100.0;              // TSL Value
input double              InpTSLStepValue      = 10.0;               // TSL Step Value

// Khai báo ẩn Magic Number để quản lý lệnh
input ulong               InpMagicNumber       = 303030;             

//--- GLOBAL VARIABLES ---
CTrade         trade;
int            currentDay          = -1;
bool           tradeExecutedToday  = false;
double         sessionHigh         = 0.0;
datetime       lastBarTime         = 0;

//+------------------------------------------------------------------+
//| Khởi tạo EA                                                      |
//+------------------------------------------------------------------+
int OnInit() {
    trade.SetExpertMagicNumber(InpMagicNumber);
    Print("US30 Advanced Breakout EA initialized.");
    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Hàm Tick chính                                                   |
//+------------------------------------------------------------------+
void OnTick() {
    // 1. Quản lý dời lỗ (Break-even & Trailing Stop) chạy liên tục
    ManageTrailingAndBE();

    datetime currentTime = TimeCurrent();
    MqlDateTime dt; TimeToStruct(currentTime, dt);

    int curMin = dt.hour * 60 + dt.min;
    int trdMin = InpTradingStartHour * 60 + InpTradingStartMinute;
    int clsMin = InpClosePositionHour * 60 + InpClosePositionMin;
    int obsMin = InpObserveStartHour * 60 + InpObserveStartMin;

    bool isOvernight = (clsMin <= trdMin);

    // 2. Xác định Phiên giao dịch (Session Day) hỗ trợ vòng qua đêm
    datetime shiftTime = currentTime;
    if(isOvernight && curMin <= clsMin) {
        shiftTime = currentTime - 86400; // Khi chưa tới giờ đóng lệnh, được tính là chu kỳ của ngày hôm trước
    }
    MqlDateTime shiftDt; TimeToStruct(shiftTime, shiftDt);
    int currentSessionDay = shiftDt.day_of_year;

    // Reset cờ khi bước sang chu kỳ mới
    if(currentSessionDay != currentDay) {
        currentDay = currentSessionDay;
        tradeExecutedToday = false;
        sessionHigh = 0.0;
    }

    // 3. Phân luồng Cửa sổ Thời gian
    bool timeToClose = false;
    bool allowObserve = false;
    bool allowTrading = false;

    if(!isOvernight) {
        // Cùng ngày (Ví dụ: Start 01:00 -> Close 22:00)
        if(curMin >= clsMin) timeToClose = true;
        else {
            if(curMin >= obsMin) allowObserve = true;
            if(curMin >= trdMin) allowTrading = true;
        }
    } else {
        // Qua đêm (Ví dụ: Start 22:00 -> Close 16:00 hôm sau)
        // Cửa sổ nghỉ ngơi/đóng lệnh: Từ Close tới Start
        if(curMin >= clsMin && curMin < trdMin) {
            timeToClose = true;
        } else {
            if(curMin >= obsMin || curMin < clsMin) allowObserve = true;
            if(curMin >= trdMin || curMin < clsMin) allowTrading = true;
        }
    }

    // 4. Thực thi Đóng lệnh trong khoảng thời gian nghỉ
    if(timeToClose) {
        if(InpClosePositions) CloseAllPositions();
        tradeExecutedToday = true; // Chốt cờ chờ qua phiên tiếp theo để ngăn mở lệnh dư
        return;
    }

    // 5. Theo dõi mức High
    datetime currentBarTime = (datetime)SeriesInfoInteger(_Symbol, PERIOD_M1, SERIES_LASTBAR_DATE);
    if(allowObserve && currentBarTime != lastBarTime) {
        double highM1[];
        if(CopyHigh(_Symbol, PERIOD_M1, 1, 1, highM1) == 1) {
            if(highM1[0] > sessionHigh) sessionHigh = highM1[0];
        }
        lastBarTime = currentBarTime;
    }

    // 6. Kích hoạt lệnh
    if(allowTrading && !tradeExecutedToday) {
        double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
        
        bool trigger = false;
        if(InpWaitNewDayHigh) {
            if(sessionHigh > 0 && ask > sessionHigh) trigger = true;
        } else {
            trigger = true; // Đánh Blind Buy trong ngày không chờ phá đỉnh
        }

        if(trigger) {
            ExecuteTrade(ask);
        }
    }
}

//+------------------------------------------------------------------+
//| Thực thi lệnh                                                    |
//+------------------------------------------------------------------+
void ExecuteTrade(double ask) {
    double sl_dist = CalculateDistance(InpStopCalcMode, InpStopValue, ask);
    double tp_dist = CalculateDistance(InpTargetCalcMode, InpTargetValue, ask);
    
    double sl_price = (sl_dist > 0) ? ask - sl_dist : 0;
    double tp_price = (tp_dist > 0) ? ask + tp_dist : 0;
    
    double lotSize = CalculateVolume(sl_dist, ask);
    
    if(lotSize > 0) {
        if(trade.Buy(lotSize, _Symbol, ask, sl_price, tp_price, "Adv Breakout")) {
            PrintFormat(">> Mở BUY %.2f lot. SL: %f, TP: %f", lotSize, sl_price, tp_price);
            tradeExecutedToday = true; 
        } else {
            PrintFormat(">> Lỗi mở BUY %.2f lot. Mã lỗi MT5: %d", lotSize, GetLastError());
        }
    } else {
        PrintFormat(">> KHÔNG VÀO LỆNH: Khối lượng lotSize = %.2f (Rủi ro cho phép không đủ lớn để vào lệnh với SL %.1f Points)", lotSize, sl_dist / _Point);
    }
}

//+------------------------------------------------------------------+
//| Tính toán Khoảng cách (Points / Percent)                         |
//+------------------------------------------------------------------+
double CalculateDistance(ENUM_CALC_MODE mode, double value, double price) {
    if(mode == CALC_MODE_OFF || value <= 0) return 0.0;
    if(mode == CALC_MODE_PERCENT) {
        return price * (value / 100.0);
    }
    if(mode == CALC_MODE_POINTS) {
        return value * _Point;
    }
    return 0.0;
}

//+------------------------------------------------------------------+
//| Tính toán Khối lượng (Volume)                                    |
//+------------------------------------------------------------------+
double CalculateVolume(double sl_dist, double price) {
    double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    if(lotStep <= 0) lotStep = 0.01;
    double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    double calcLot = 0.0;
    double balance = AccountInfoDouble(ACCOUNT_BALANCE);

    switch(InpTradingVolume) {
        case VOLUME_FIXED:
            calcLot = InpFixedLots;
            break;
            
        case VOLUME_MANAGED:
            if(InpFixedLotsPerMoney > 0)
                calcLot = (balance / InpFixedLotsPerMoney) * InpFixedLots;
            break;
            
        case VOLUME_PERCENT:
        case VOLUME_MONEY:
        { 
            double riskAmount = (InpTradingVolume == VOLUME_PERCENT) ? (balance * InpRiskPercent / 100.0) : InpRiskMoney;
            
            // Nếu có SL, tính lot theo khoảng cách SL
            if(sl_dist > 0) {
                double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
                double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
                if(tickSize > 0 && tickValue > 0) {
                    double lossPerLot = (sl_dist / tickSize) * tickValue;
                    if(lossPerLot > 0) {
                        calcLot = riskAmount / lossPerLot;
                        PrintFormat("[Risk Logic] Balance=%.2f, %%=%.1f -> Rủi ro USD: %.2f", balance, InpRiskPercent, riskAmount);
                        PrintFormat("[Risk Logic] SL Khoảng cách=%.1f | Loss/1 Lot EUR/USD: %.2f -> Tính toán: %.3f Lot", sl_dist, lossPerLot, calcLot);
                    }
                }
            } else {
                double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
                double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
                if(tickSize > 0 && tickValue > 0) {
                    double lossPerLotToZero = (price / tickSize) * tickValue; // Mức lỗ của 1 Lot nếu chỉ số sập về 0
                    if(lossPerLotToZero > 0) {
                        calcLot = riskAmount / lossPerLotToZero;
                        
                        double minLotLossToZero = lossPerLotToZero * minLot;
                        double xPercentMinLot = (minLotLossToZero / balance) * 100.0;
                        
                        PrintFormat("[No-SL Logic] Nếu rớt về 0 với Min Lot (%.2f), bạn sẽ mất %.2f USD (tức %.2f%% Balance của bạn).", minLot, minLotLossToZero, xPercentMinLot);
                        PrintFormat("[No-SL Logic] Mức Rủi ro Cài đặt: %.2f%% (%.2f USD) -> Tính ra khối lượng: %.3f Lot", InpRiskPercent, riskAmount, calcLot);
                    }
                }
            }
            break;
        } 
    }

    double finalLot = MathFloor(calcLot / lotStep) * lotStep;
    if(finalLot < minLot) {
        PrintFormat(">> CẢNH BÁO TỪ BOT: Tính được %.3f Lot nhưng KHÔNG ĐẠT số Lot tối thiểu là %.2f Lot. Xin hãy tăng % rủi ro lên hoặc giảm khoảng cách SL lại.", finalLot, minLot);
        return 0;
    }
    if(finalLot > maxLot) return maxLot;
    return finalLot;
}

//+------------------------------------------------------------------+
//| Quản lý Break-Even & Trailing Stop                               |
//+------------------------------------------------------------------+
void ManageTrailingAndBE() {
    if(PositionsTotal() == 0) return;
    
    for(int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber) {
            
            if(PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_BUY) continue; // Logic này chuyên cho BUY Breakout
            
            double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
            double current_sl = PositionGetDouble(POSITION_SL);
            double tp         = PositionGetDouble(POSITION_TP);
            double bid        = SymbolInfoDouble(_Symbol, SYMBOL_BID);
            
            // 1. Xử lý Break-Even (BE)
            if(InpBEStopCalcMode != CALC_MODE_OFF) {
                double be_trigger = CalculateDistance(InpBEStopCalcMode, InpBEStopTriggerVal, open_price);
                double be_buffer  = CalculateDistance(InpBEStopCalcMode, InpBEStopBufferVal, open_price);
                
                // Nếu giá đi được 1 khoảng bằng Trigger và SL vẫn đang ở vạch xuất phát (hoặc thấp hơn)
                if(bid >= open_price + be_trigger && current_sl < open_price + be_buffer) {
                    trade.PositionModify(ticket, open_price + be_buffer, tp);
                    current_sl = open_price + be_buffer; // Cập nhật lại sl để lát check Trailing
                }
            }
            
            // 2. Xử lý Trailing Stop (TSL)
            if(InpTSLCalcMode != CALC_MODE_OFF) {
                double tsl_trigger = CalculateDistance(InpTSLCalcMode, InpTSLTriggerValue, open_price);
                double tsl_value   = CalculateDistance(InpTSLCalcMode, InpTSLValue, open_price);
                double tsl_step    = CalculateDistance(InpTSLCalcMode, InpTSLStepValue, open_price);
                
                // Kích hoạt dời lỗ nếu qua vạch Trigger
                if(bid >= open_price + tsl_trigger) {
                    double new_sl = bid - tsl_value;
                    // Chỉ dời SL lên nếu khoảng cách mới lớn hơn Step quy định
                    if(new_sl >= current_sl + tsl_step || current_sl == 0) {
                        trade.PositionModify(ticket, new_sl, tp);
                    }
                }
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Đóng toàn bộ lệnh                                                |
//+------------------------------------------------------------------+
void CloseAllPositions() {
    for(int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber) {
            trade.PositionClose(ticket);
        }
    }
}