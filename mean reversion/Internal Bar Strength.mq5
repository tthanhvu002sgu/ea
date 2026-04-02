//+------------------------------------------------------------------+
//|                                        Internal Bar Strength.mq5 |
//|                                       Copyright 2026, Antigravity|
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Antigravity"
#property link      ""
#property version   "1.01"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>

input string               __Settings__               = "--- Cài Đặt Chung ---";
input double               InpLotSize                 = 0.1;      // Khối lượng lệnh (Lots)
input ulong                InpMagicNumber             = 123456;   // Magic Number

input string               __TimeSettings__           = "--- Thời Gian Giao Dịch ---";
input int                  InpTradeHour               = 23;       // Giờ vào lệnh (Broker Server Time)
input int                  InpTradeMinute             = 50;       // Phút vào lệnh trước khi đóng nến (để 50 cho an toàn nếu thiếu tick)

input string               __IBSSettings__            = "--- Cài Đặt IBS ---";
input double               InpIBS_BuyThreshold        = 0.2;      // Ngưỡng Mua IBS (< 0.2)
input double               InpIBS_SellThreshold       = 0.8;      // Ngưỡng Bán IBS (> 0.8)

input string               __TrendSettings__          = "--- Lọc Xu Hướng ---";
input bool                 InpUseTrendFilter          = true;     // Bật/Tắt Lọc Xu Hướng
input int                  InpMAPeriod                = 200;      // Chu kỳ MA dài hạn
input double               InpMaxMADistancePct        = 50.0;     // Khoảng cách tối đa so với đường MA (%) - Đã mở rộng ra 50% để test dễ hơn

input string               __RiskSettings__           = "--- Quản Trị Rủi Ro ---";
input double               InpStopLossPct             = 10.0;     // Mức Stop-Loss theo % giá

CTrade         trade;
CPositionInfo  posInfo;
CSymbolInfo    symInfo;

int            maHandle;
int            lastTradeDay = -1;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    trade.SetExpertMagicNumber(InpMagicNumber);
    symInfo.Name(_Symbol);
    
    if (InpUseTrendFilter)
    {
        maHandle = iMA(_Symbol, PERIOD_D1, InpMAPeriod, 0, MODE_SMA, PRICE_CLOSE);
        if(maHandle == INVALID_HANDLE)
        {
            Print("Lỗi khởi tạo handle cho indicator MA!");
            return(INIT_FAILED);
        }
    }
    
    Print("IBS EA Đã Khởi Chạy! Đang quét tín hiệu vào lúc ", InpTradeHour, ":", InpTradeMinute, " mỗi ngày.");
    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    if (InpUseTrendFilter)
        IndicatorRelease(maHandle);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
    if(!symInfo.RefreshRates()) return;
    
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    
    // Nếu chạy backtest chế độ "Open Prices Only" trên chart D1, giờ sẽ luôn là 0:00!
    // Bạn phải chọn chế độ "Every Tick" hoặc "1 minute OHLC" thì điều kiện giờ == 23 mới kích hoạt được.
    
    if(dt.hour == InpTradeHour && dt.min >= InpTradeMinute)
    {
        int current_day = dt.day_of_year;
        
        // Chỉ đánh giá 1 lần duy nhất mỗi ngày để tránh spam lệnh
        if(lastTradeDay == current_day) return;
        
        // Lấy thông tin giá trị nến D1 hiện tại (Bar 0 - nến của ngày hôm nay chuẩn bị đóng)
        double high  = iHigh(_Symbol, PERIOD_D1, 0);
        double low   = iLow(_Symbol, PERIOD_D1, 0);
        double close = iClose(_Symbol, PERIOD_D1, 0); 
        
        // Tránh lỗi chia cho 0 nếu thị trường chưa biến động
        if(high - low == 0) return;
        
        // Tính công thức IBS: (Giá Đóng cửa - Giá Thấp nhất) / (Giá Cao nhất - Giá Thấp nhất)
        double ibs = (close - low) / (high - low);
        
        // Lấy thông tin các vị thế đang rải trên thị trường
        bool isLong = false;
        ulong posTicket = 0;
        int totalPositions = PositionsTotal();
        
        for(int i = totalPositions - 1; i >= 0; i--)
        {
            if(posInfo.SelectByIndex(i))
            {
                if(posInfo.Symbol() == _Symbol && posInfo.Magic() == InpMagicNumber)
                {
                    if(posInfo.PositionType() == POSITION_TYPE_BUY)
                    {
                        isLong = true;
                        posTicket = posInfo.Ticket();
                    }
                }
            }
        }
        
        // IN RA NHẬT KÝ ĐỂ THEO DÕI LOGIC TRONG BACKTEST
        // Print("Bar: ", dt.day_of_year, " | Giờ: ", dt.hour, ":", dt.min, " | IBS = ", DoubleToString(ibs, 3), " | Close = ", DoubleToString(close, 5));
        
        // XÉT ĐIỀU KIỆN THOÁT LỆNH BÁN (EXIT)
        if(isLong)
        {
            if(ibs > InpIBS_SellThreshold)
            {
                if(trade.PositionClose(posTicket))
                {
                    Print("Đã THOÁT LỆNH Mua do IBS = ", DoubleToString(ibs, 2), " đạt điều kiện > ", InpIBS_SellThreshold);
                }
            }
        }
        // XÉT ĐIỀU KIỆN VÀO LỆNH MUA (ENTRY)
        else 
        {
            if(ibs < InpIBS_BuyThreshold)
            {
                bool trend_ok = true;
                
                // Màng lọc xu hướng: Giá nằm trong xu thế tăng dài hạn
                if(InpUseTrendFilter)
                {
                    double ma_val[];
                    if(CopyBuffer(maHandle, 0, 0, 1, ma_val) > 0)
                    {
                        double distance_pct = (close - ma_val[0]) / ma_val[0] * 100.0;
                        
                        if(close <= ma_val[0])
                        {
                            Print("TỪ CHỐI LỆNH: Giá đóng cửa (", close, ") dưới đường MA200 (", ma_val[0], ")");
                            trend_ok = false;
                        }
                        else if(distance_pct > InpMaxMADistancePct)
                        {
                            Print("TỪ CHỐI LỆNH: Giá cách MA200 quá xa (", DoubleToString(distance_pct, 1), "% > ", InpMaxMADistancePct, "%)");
                            trend_ok = false;
                        }
                        else
                        {
                            Print("Bộ lọc MA hợp lệ! Khoảng cách MA: ", DoubleToString(distance_pct, 1), "%");
                        }
                    }
                    else
                    {
                        Print("Lỗi không lấy được dữ liệu MA200!");
                        trend_ok = false;
                    }
                }
                
                if(trend_ok)
                {
                    double ask = symInfo.Ask();
                    double sl_price = ask * (1.0 - InpStopLossPct / 100.0);
                    sl_price = NormalizeDouble(sl_price, _Digits);
                    
                    if(trade.Buy(InpLotSize, _Symbol, ask, sl_price, 0, "IBS Mean Reversion Mua"))
                    {
                        Print("Đã VÀO LỆNH Mua do IBS = ", DoubleToString(ibs, 2), " đạt điều kiện < ", InpIBS_BuyThreshold);
                    }
                    else
                    {
                        Print("Vào lệnh Mua thất bại! Mã lỗi: ", trade.ResultRetcode(), " | Description: ", trade.ResultRetcodeDescription());
                    }
                }
            }
        }
        
        lastTradeDay = current_day;
    }
}
//+------------------------------------------------------------------+
