//+------------------------------------------------------------------+
//|                                              weekly_strategy.mq5 |
//|                                                                  |
//+------------------------------------------------------------------+
#property copyright "AI"
#property link      ""
#property version   "1.00"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

CTrade         trade;
CPositionInfo  posInfo;

sinput string _separator1 = "--- Volume Settings ---";
input double InitialLot = 0.10;         // Lệnh đầu tiên
input double DCALot = 0.02;             // Khối lượng lệnh DCA
input int    DCA_Frequency_Weeks = 1;   // Tần suất DCA (số tuần)

sinput string _separator2 = "--- EMA Settings ---";
input int    EMA_Fast_Period = 10;   // Chu kỳ EMA Nhanh
input int    EMA_Slow_Period = 30;   // Chu kỳ EMA Chậm

sinput string _separator3 = "--- Timing & Other Settings ---";
input int    US_Session_Hour = 15;   // Giờ mở cửa Phiên Mỹ (Broker Time)
input ulong  MagicNumber = 123456;   // Magic Number

int emaFastHandle;
int emaSlowHandle;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetExpertMagicNumber(MagicNumber);
   
   emaFastHandle = iMA(_Symbol, PERIOD_W1, EMA_Fast_Period, 0, MODE_EMA, PRICE_CLOSE);
   emaSlowHandle = iMA(_Symbol, PERIOD_W1, EMA_Slow_Period, 0, MODE_EMA, PRICE_CLOSE);
   
   if(emaFastHandle == INVALID_HANDLE || emaSlowHandle == INVALID_HANDLE)
     {
      Print("Lỗi khởi tạo EMA!");
      return INIT_FAILED;
     }

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   IndicatorRelease(emaFastHandle);
   IndicatorRelease(emaSlowHandle);
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   static datetime confirmedBarTime = 0;
   datetime currentW1Time = iTime(_Symbol, PERIOD_W1, 0);
   
   // 1. Chỉ xử lý tiếp nếu là nến tuần mới chưa được xác nhận
   if(currentW1Time == confirmedBarTime) return;

   // 2. Chờ đến phiên Mỹ ngày thứ 2 (không mua/bán lúc mở cửa đầu tuần)
   datetime currentTime = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(currentTime, dt);
   
   if(dt.day_of_week == 1 && dt.hour < US_Session_Hour) return;

   double emaFast[], emaSlow[];
   ArraySetAsSeries(emaFast, true);
   ArraySetAsSeries(emaSlow, true);
   
   // 3. Lấy dữ liệu 3 nến gần nhất trên khung W1
   // [0]: Nến tuần hiện tại đang chạy (chưa đóng cửa)
   // [1]: Nến tuần vừa đóng cửa
   // [2]: Nến tuần đóng cửa trước đó
   if(CopyBuffer(emaFastHandle, 0, 0, 3, emaFast) != 3) return;
   if(CopyBuffer(emaSlowHandle, 0, 0, 3, emaSlow) != 3) return;
   
   // 4. CHỈ KHI CopyBuffer thành công mới khóa nến
   confirmedBarTime = currentW1Time;
   
   double fast1 = emaFast[1]; // EMA10 nến đóng cửa
   double slow1 = emaSlow[1]; // EMA30 nến đóng cửa
   double fast2 = emaFast[2]; // EMA10 nến trước đó
   double slow2 = emaSlow[2]; // EMA30 nến trước đó
   
   bool crossAbove = (fast1 > slow1) && (fast2 <= slow2); // Vừa cắt lên (Giao cắt vàng)
   bool crossBelow = (fast1 < slow1) && (fast2 >= slow2); // Vừa cắt xuống (Giao cắt tử thần)
   bool trendUp    = (fast1 > slow1) && (fast2 > slow2);  // Đang duy trì trên (Xu hướng tăng)
   
   // ĐIỂM THOÁT (EXIT): EMA10 cắt xuống dưới EMA30
   if(crossBelow)
     {
      CloseAllPositions();
      return; 
     }
     
   // ĐIỂM VÀO LỆNH ĐẦU TIÊN: EMA10 cắt lên trên EMA30
   if(crossAbove)
     {
      // Đóng các vị thế cũ (nếu có) để chuẩn bị chu kỳ mới
      CloseAllPositions();
      
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      trade.Buy(InitialLot, _Symbol, ask, 0, 0, "MUA: EMA10 cắt lên EMA30");
     }
   // LỆNH DCA: Mua thêm theo tần suất tuần đã cài đặt MIỄN LÀ EMA10 nằm trên EMA30
   else if(trendUp)
     {
      // Chỉ DCA nếu đã có lệnh ban đầu (để tránh tự nhảy vào thị trường ở giữa sóng tăng nếu bật EA muộn)
      if(HasPositions())
        {
         datetime lastBuyTime = GetLastBuyTime();
         int barsSinceBuy = Bars(_Symbol, PERIOD_W1, lastBuyTime, TimeCurrent()) - 1;
         
         if(barsSinceBuy >= DCA_Frequency_Weeks)
           {
            double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            trade.Buy(DCALot, _Symbol, ask, 0, 0, "DCA: Trend follow W1");
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Lấy thời gian mở lệnh gần nhất                                   |
//+------------------------------------------------------------------+
datetime GetLastBuyTime()
  {
   datetime lastTime = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(posInfo.SelectByIndex(i))
        {
         if(posInfo.Symbol() == _Symbol && posInfo.Magic() == MagicNumber)
           {
            datetime openTime = (datetime)posInfo.Time();
            if(openTime > lastTime)
               lastTime = openTime;
           }
        }
     }
   return lastTime;
  }

//+------------------------------------------------------------------+
//| Đóng toàn bộ vị thế của EA                                       |
//+------------------------------------------------------------------+
void CloseAllPositions()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(posInfo.SelectByIndex(i))
        {
         if(posInfo.Symbol() == _Symbol && posInfo.Magic() == MagicNumber)
           {
            trade.PositionClose(posInfo.Ticket());
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Kiểm tra xem EA có đang giữ vị thế nào không                     |
//+------------------------------------------------------------------+
bool HasPositions()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(posInfo.SelectByIndex(i))
        {
         if(posInfo.Symbol() == _Symbol && posInfo.Magic() == MagicNumber)
           {
            return true; // Có ít nhất 1 lệnh đang chạy
           }
        }
     }
   return false;
  }
//+------------------------------------------------------------------+
