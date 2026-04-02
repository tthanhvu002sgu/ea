//+------------------------------------------------------------------+
//|                                                  Pullback_EA.mq5 |
//|                                        Bản quyền: Đối tác lập trình|
//+------------------------------------------------------------------+
#property copyright "Đối tác lập trình"
#property version   "1.00"

#include <Trade\Trade.mqh> // Khai báo thư viện giao dịch chuẩn của MQL5

//--- Nhóm: Giao dịch cơ bản
input group    "=== Giao Dịch ===";
input double   InpLotSize        = 0.1;    // Khối lượng giao dịch (Lot)
input ulong    InpMagicNumber    = 123456; // Magic Number để quản lý lệnh
input int      InpPullbackMax    = 15;     // Số nến tối đa quét ngược về trước để tìm Pullback
input double   InpTPMultiplier   = 2.0;    // Hệ số Take Profit (TP = khoảng SL × hệ số)

//--- Nhóm: Bộ lọc ATR
input group    "=== Bộ Lọc ATR ===";
input double   InpMinATR         = 0.0;    // Ngưỡng ATR tối thiểu (0 = tắt lọc)

//--- Nhóm: Bộ lọc EMA Weekly
input group    "=== Bộ Lọc EMA Weekly ===";
input bool     InpUseWeeklyEMA   = true;   // Bật/tắt bộ lọc EMA21 khung Weekly

//--- Nhóm: Bộ lọc cấu trúc H4 (ZigZag Swing)
input group    "=== Bộ Lọc Cấu Trúc H4 ===";
input bool            InpUseH4Structure = true;        // Bật/tắt bộ lọc cấu trúc H4
input ENUM_TIMEFRAMES InpHTFPeriod      = PERIOD_H4;   // Khung thời gian Higher Timeframe
input int             InpSwingStrength  = 3;            // Số nến xác nhận swing (khuyến nghị 3-5)
input int             InpSwingLookback  = 100;          // Số nến H4 lookback để tìm swing
input int             InpMinSwings      = 4;            // Số swing tối thiểu để xác định trend

//+------------------------------------------------------------------+
//| Cấu trúc lưu Swing Point                                        |
//+------------------------------------------------------------------+
struct SwingPoint {
    double   price;
    datetime time;
    int      barIndex;
    bool     isHigh;
};

//--- Biến toàn cục
CTrade         trade;            // Đối tượng thực thi lệnh
datetime       lastBarTime = 0;  // Lưu thời gian nến để chạy On New Bar
int            handle_ema20;
int            handle_ema50;
int            handle_ema21_w;   // EMA21 khung Weekly (bộ lọc xu hướng dài hạn)
int            handle_adx_m1;
int            handle_atr;

//--- Cache cho phân tích HTF (H4) ---
int            cachedH4Trend = 0;          // Kết quả trend đã tính
datetime       lastH4TrendUpdate = 0;    // Thời gian bar H4 đã tính

//+------------------------------------------------------------------+
//| Hàm Khởi tạo                                                     |
//+------------------------------------------------------------------+
int OnInit() {
    // Cài đặt Magic Number cho đối tượng trade
    trade.SetExpertMagicNumber(InpMagicNumber);
    
    // Khởi tạo các Handles (Chỉ báo)
    handle_ema20    = iMA(_Symbol, PERIOD_CURRENT, 20, 0, MODE_EMA, PRICE_CLOSE);
    handle_ema50    = iMA(_Symbol, PERIOD_CURRENT, 50, 0, MODE_EMA, PRICE_CLOSE);
    handle_ema21_w  = iMA(_Symbol, PERIOD_W1,      21, 0, MODE_EMA, PRICE_CLOSE); // EMA21 Weekly
    handle_atr      = iATR(_Symbol, PERIOD_CURRENT, 14);
    handle_adx_m1   = iADX(_Symbol, PERIOD_M1, 14); // Khung M1 để lấy ADX Real-time
    
    if(handle_ema20 == INVALID_HANDLE || handle_ema50 == INVALID_HANDLE ||
       handle_ema21_w == INVALID_HANDLE ||
       handle_atr == INVALID_HANDLE || handle_adx_m1 == INVALID_HANDLE) {
        Print("Lỗi khởi tạo chỉ báo!");
        return(INIT_FAILED);
    }
    
    Print("Bot MT5 khởi chạy thành công!");
    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Hàm Hủy (Dọn dẹp bộ nhớ khi tắt bot)                             |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
    IndicatorRelease(handle_ema20);
    IndicatorRelease(handle_ema50);
    IndicatorRelease(handle_ema21_w);
    IndicatorRelease(handle_atr);
    IndicatorRelease(handle_adx_m1);
}

//+------------------------------------------------------------------+
//| Hàm Tick (Chạy mỗi khi có giá mới)                               |
//+------------------------------------------------------------------+
void OnTick() {
    // 1. Trigger On New Bar (Kiểm tra nến mới)
    datetime currentBarTime = (datetime)SeriesInfoInteger(_Symbol, PERIOD_CURRENT, SERIES_LASTBAR_DATE);
    if(currentBarTime == lastBarTime) return; // Thoát nếu vẫn là nến cũ

    // 2. Lấy dữ liệu nến và chỉ báo cần thiết
    MqlRates rates[];
    double ema20[], ema50[], ema21w[], adx[], atr[];
    
    // Đảo ngược mảng để Index 0 là nến hiện tại, 1 là nến vừa đóng...
    ArraySetAsSeries(rates,  true);
    ArraySetAsSeries(ema20,  true);
    ArraySetAsSeries(ema50,  true);
    ArraySetAsSeries(ema21w, true);
    
    // Chỉ cần lấy mảng kích thước đủ dùng
    if(CopyRates(_Symbol, PERIOD_CURRENT, 0, InpPullbackMax + 2, rates)  < 0) return;
    if(CopyBuffer(handle_ema20,   0, 0, InpPullbackMax + 2, ema20)  < 0) return;
    if(CopyBuffer(handle_ema50,   0, 0, InpPullbackMax + 2, ema50)  < 0) return;
    if(CopyBuffer(handle_ema21_w, 0, 1, 1, ema21w) < 0) return; // EMA21 Weekly nến vừa đóng
    
    // Lấy ADX từ khung M1 (Index 1) và ATR (Index 1)
    if(CopyBuffer(handle_adx_m1, 0, 1, 1, adx) < 0) return; // Buffer 0 của ADX là Main Line
    if(CopyBuffer(handle_atr,    0, 1, 1, atr) < 0) return;

    // 3. Xử lý logic lệnh
    ManageOpenPositions(rates[1].close, ema20[1]);
    CheckForEntry(rates, ema20, ema50, ema21w[0], adx[0], atr[0]);

    // 4. Cập nhật thời gian
    lastBarTime = currentBarTime; 
}

//+------------------------------------------------------------------+
//| Hàm Quản lý vị thế (Exit & Trailing Stop theo EMA20)             |
//+------------------------------------------------------------------+
void ManageOpenPositions(double close1, double ema20_1) {
    for(int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber) {
            
            long type = PositionGetInteger(POSITION_TYPE);
            double current_sl = PositionGetDouble(POSITION_SL);
            
            // --- QUẢN LÝ LỆNH BUY ---
            if(type == POSITION_TYPE_BUY) {
                // Thoát lệnh: Nến đóng dưới EMA20
                if(close1 < ema20_1) {
                    trade.PositionClose(ticket);
                    continue;
                }
                // Trailing SL: Nâng SL lên EMA20
                double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
                if(ema20_1 > current_sl && ema20_1 < bid) {
                    trade.PositionModify(ticket, ema20_1, PositionGetDouble(POSITION_TP));
                }
            }
            
            // --- QUẢN LÝ LỆNH SELL ---
            else if(type == POSITION_TYPE_SELL) {
                // Thoát lệnh: Nến đóng trên EMA20
                if(close1 > ema20_1) {
                    trade.PositionClose(ticket);
                    continue;
                }
                // Trailing SL: Hạ SL xuống EMA20
                double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
                if((ema20_1 < current_sl || current_sl == 0) && ema20_1 > ask) {
                    trade.PositionModify(ticket, ema20_1, PositionGetDouble(POSITION_TP));
                }
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Hàm kiểm tra tín hiệu vào lệnh                                   |
//+------------------------------------------------------------------+
void CheckForEntry(const MqlRates &rates[], const double &ema20[], const double &ema50[],
                   double ema21w_val, double adx_val, double atr_val) {
    if(PositionsTotal() > 0) return; // Chỉ đánh 1 lệnh tại 1 thời điểm

    // --- Lọc ATR tối thiểu: bỏ qua khi thị trường quá flat ---
    if(InpMinATR > 0 && atr_val < InpMinATR) return;

    // --- Lọc cấu trúc H4 ---
    int h4Trend = 0; // 0 = không lọc
    if(InpUseH4Structure) {
        h4Trend = AnalyzeHTFTrend(InpHTFPeriod, InpSwingStrength, InpSwingLookback, InpMinSwings);
        if(h4Trend == 0) return; // Sideways — không vào lệnh
    }

    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

    // ==========================================
    // KIỂM TRA TÍN HIỆU BUY
    // ==========================================
    // Điều kiện: EMA thứ tự tăng + ADX đủ mạnh
    //            + (Weekly) giá trên EMA21W
    //            + (H4) cấu trúc uptrend
    bool weeklyBuyOk = !InpUseWeeklyEMA || (ask > ema21w_val);
    bool h4BuyOk     = !InpUseH4Structure || (h4Trend == 1);

    if(ema20[1] > ema50[1] && adx_val > 30 && weeklyBuyOk && h4BuyOk) {
        if(rates[1].close > rates[1].open && rates[1].close > ema20[1]) {
            double slPrice = GetBuyStopLoss(rates, ema20, ema50, atr_val);
            if(slPrice != 0) {
                double slDist  = ask - slPrice;
                double tpPrice = (InpTPMultiplier > 0) ? ask + slDist * InpTPMultiplier : 0;
                trade.Buy(InpLotSize, _Symbol, ask, slPrice, tpPrice, "Pullback Buy");
            }
        }
    }

    // ==========================================
    // KIỂM TRA TÍN HIỆU SELL
    // ==========================================
    bool weeklySellOk = !InpUseWeeklyEMA || (bid < ema21w_val);
    bool h4SellOk     = !InpUseH4Structure || (h4Trend == -1);

    if(ema20[1] < ema50[1] && adx_val > 30 && weeklySellOk && h4SellOk) {
        if(rates[1].close < rates[1].open && rates[1].close < ema20[1]) {
            double slPrice = GetSellStopLoss(rates, ema20, ema50, atr_val);
            if(slPrice != 0) {
                double slDist  = slPrice - bid;
                double tpPrice = (InpTPMultiplier > 0) ? bid - slDist * InpTPMultiplier : 0;
                trade.Sell(InpLotSize, _Symbol, bid, slPrice, tpPrice, "Pullback Sell");
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Tìm N swing points gần nhất từ dữ liệu HTF                      |
//| strength : số nến xác nhận mỗi bên (khuyến nghị 3-5)            |
//| Trả về số swing tìm được                                         |
//+------------------------------------------------------------------+
int FindSwingPoints(const MqlRates &rates[], int totalBars, int strength,
                    SwingPoint &swings[], int maxSwings) {
    int count = 0;
    ArrayResize(swings, maxSwings);

    for(int i = strength; i < totalBars - strength && count < maxSwings; i++) {
        bool isSwingHigh = true;
        bool isSwingLow  = true;

        for(int j = 1; j <= strength; j++) {
            if(rates[i].high <= rates[i-j].high || rates[i].high <= rates[i+j].high) isSwingHigh = false;
            if(rates[i].low  >= rates[i-j].low  || rates[i].low  >= rates[i+j].low ) isSwingLow  = false;
        }

        if(isSwingHigh) {
            swings[count].price    = rates[i].high;
            swings[count].time     = rates[i].time;
            swings[count].barIndex = i;
            swings[count].isHigh   = true;
            count++;
        } else if(isSwingLow) {
            swings[count].price    = rates[i].low;
            swings[count].time     = rates[i].time;
            swings[count].barIndex = i;
            swings[count].isHigh   = false;
            count++;
        }
    }
    return count;
}

//+------------------------------------------------------------------+
//| Phân tích xu hướng HTF từ chuỗi swing points                    |
//| Trả về: 1 = uptrend, -1 = downtrend, 0 = sideways/unclear       |
//+------------------------------------------------------------------+
int AnalyzeHTFTrend(ENUM_TIMEFRAMES htfPeriod, int strength, int lookback, int minSwings) {
    // Cache: nếu bar H4 chưa thay đổi thì trả về kết quả đã tính
    datetime currentH4Bar = (datetime)SeriesInfoInteger(_Symbol, htfPeriod, SERIES_LASTBAR_DATE);
    if(currentH4Bar == lastH4TrendUpdate) return cachedH4Trend;

    MqlRates htfRates[];
    ArraySetAsSeries(htfRates, true);

    int copied = CopyRates(_Symbol, htfPeriod, 0, lookback, htfRates);
    if(copied < lookback) {
        cachedH4Trend = 0;
        lastH4TrendUpdate = currentH4Bar;
        return 0;
    }

    SwingPoint swings[];
    int swingCount = FindSwingPoints(htfRates, copied, strength, swings, 20);
    if(swingCount < minSwings) {
        cachedH4Trend = 0;
        lastH4TrendUpdate = currentH4Bar;
        return 0; // Không đủ swing để xác định cấu trúc
    }

    // Tách swing highs và lows, đọc từ cũ → mới (index cao → thấp trong AsSeries)
    double highs[10], lows[10];
    int    hCount = 0, lCount = 0;

    // swings[0] = swing GẦN NHẤT, swings[swingCount-1] = swing CŨ NHẤT
    for(int i = swingCount - 1; i >= 0 && (hCount < 10 || lCount < 10); i--) {
        if( swings[i].isHigh && hCount < 10) highs[hCount++] = swings[i].price;
        if(!swings[i].isHigh && lCount < 10) lows [lCount++] = swings[i].price;
    }

    if(hCount < 2 || lCount < 2) {
        cachedH4Trend = 0;
        lastH4TrendUpdate = currentH4Bar;
        return 0;
    }

    // Đếm số lần HH/LH và HL/LL
    int hhCount = 0, hlCount = 0, lhCount = 0, llCount = 0;
    for(int i = 1; i < hCount; i++) {
        if(highs[i] > highs[i-1]) hhCount++; else lhCount++;
    }
    for(int i = 1; i < lCount; i++) {
        if(lows[i]  > lows[i-1])  hlCount++; else llCount++;
    }

    // Quyết định xu hướng theo đa số, yêu cầu ít nhất 2 HH để tránh false positive
    bool upCondition   = (hhCount > lhCount) && (hlCount >= llCount) && (hhCount >= 2);
    bool downCondition = (lhCount >  hhCount) && (llCount >  hlCount) && (lhCount >= 2);

    int result = 0;
    if(upCondition)   result = 1;   // Uptrend: HH + HL
    else if(downCondition) result = -1; // Downtrend: LH + LL

    // Cập nhật cache
    cachedH4Trend = result;
    lastH4TrendUpdate = currentH4Bar;
    return result;
}

//+------------------------------------------------------------------+
//| Dò tìm SL Lệnh BUY (Cực trị Pullback - Buffer)                   |
//+------------------------------------------------------------------+
double GetBuyStopLoss(const MqlRates &rates[], const double &ema20[], const double &ema50[], double atr) {
    double lowestLow = DBL_MAX; // Mức cực đại ban đầu
    bool isValidPullback = false;

    for(int i = 2; i <= InpPullbackMax; i++) {
        if(rates[i].low < lowestLow) lowestLow = rates[i].low;

        if(rates[i].low < ema20[i] && rates[i].low > ema50[i]) {
            isValidPullback = true;
        }

        // Kết thúc Pullback (rời xa EMA20 lên trên)
        if(isValidPullback && rates[i].low > ema20[i]) break;
    }

    if(isValidPullback) return (lowestLow - 0.5 * atr);
    return 0;
}

//+------------------------------------------------------------------+
//| Dò tìm SL Lệnh SELL (Cực trị Pullback + Buffer)                  |
//+------------------------------------------------------------------+
double GetSellStopLoss(const MqlRates &rates[], const double &ema20[], const double &ema50[], double atr) {
    double highestHigh = 0;
    bool isValidPullback = false;

    for(int i = 2; i <= InpPullbackMax; i++) {
        if(rates[i].high > highestHigh) highestHigh = rates[i].high;

        if(rates[i].high > ema20[i] && rates[i].high < ema50[i]) {
            isValidPullback = true;
        }

        // Kết thúc Pullback (rời xa EMA20 xuống dưới)
        if(isValidPullback && rates[i].high < ema20[i]) break;
    }

    if(isValidPullback) return (highestHigh + 0.5 * atr);
    return 0;
}