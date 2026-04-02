//+------------------------------------------------------------------+
//|                                                   buyandhold.mq5 |
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
input double InitialLot = 0.10;         // Lệnh Mua đầu tiên
input double DCALot = 0.02;             // Khối lượng DCA
input int    DCA_Frequency_Weeks = 1;   // Tần suất DCA (số tuần)

sinput string _separator2 = "--- Other Settings ---";
input ulong  MagicNumber = 999111;      // Magic Number

double totalLotsEntered = 0.0;          // Biến lưu trữ tổng Lot

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetExpertMagicNumber(MagicNumber);
   
   // Tính toán lại tổng Lot đã vào từ các vị thế đang mở (hữu ích khi khởi động lại EA)
   totalLotsEntered = CalculateTotalLots();
   Print("EA Buy & Hold Bắt đầu. Tổng Lot hiện tại đang giữ: ", DoubleToString(totalLotsEntered, 2));
   
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   totalLotsEntered = CalculateTotalLots();
   Print("=================================================");
   Print("KẾT THÚC CHIẾN LƯỢC BUY & HOLD");
   Print("Tổng số Lot đã giải ngân: ", DoubleToString(totalLotsEntered, 2), " Lots");
   Print("=================================================");
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   // Tối ưu hóa: Chỉ cần kiểm tra mua mỗi khi qua nến Tuần (W1) mới hoặc chạy lần đầu
   static datetime lastCheckedWeek = 0;
   datetime currentW1Time = iTime(_Symbol, PERIOD_W1, 0);
   
   if(currentW1Time == lastCheckedWeek) return;

   // Lấy thời gian hiện tại
   datetime currentTime = TimeCurrent();
   
   // Nếu chưa có vị thế nào của EA, tiến hành mua lệnh đầu tiên
   if(!HasPositions())
     {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      if(trade.Buy(InitialLot, _Symbol, ask, 0, 0, "Buy & Hold: Mua Lần Đầu"))
        {
         lastCheckedWeek = currentW1Time;
        }
     }
   else
     {
      // Đã có vị thế, tiến hành DCA theo tần suất tuần
      datetime lastBuyTime = GetLastBuyTime();
      int barsSinceBuy = Bars(_Symbol, PERIOD_W1, lastBuyTime, currentTime) - 1;
      
      // Nếu số nến tuần >= tần suất cho phép
      if(barsSinceBuy >= DCA_Frequency_Weeks)
        {
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         if(trade.Buy(DCALot, _Symbol, ask, 0, 0, "Buy & Hold: DCA Hàng Tuần"))
           {
            lastCheckedWeek = currentW1Time;
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
            return true;
           }
        }
     }
   return false;
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
//| Tính toán tổng số Lot đang Hold                                  |
//+------------------------------------------------------------------+
double CalculateTotalLots()
  {
   double sumLots = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(posInfo.SelectByIndex(i))
        {
         if(posInfo.Symbol() == _Symbol && posInfo.Magic() == MagicNumber)
           {
            sumLots += posInfo.Volume();
           }
        }
     }
   return sumLots;
  }
//+------------------------------------------------------------------+
