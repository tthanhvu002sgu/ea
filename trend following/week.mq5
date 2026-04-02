//+------------------------------------------------------------------+
//|                                                         week.mq5 |
//+------------------------------------------------------------------+
#property copyright "AI"
#property link      ""
#property version   "1.00"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

CTrade         trade;
CPositionInfo  posInfo;

sinput string _separator1 = "--- Khối Lượng & DCA ---";
input double InitialLot = 0.10;         // Khối lượng Lệnh Mua đầu tiên
input double DCALot = 0.02;             // Khối lượng lệnh DCA
input int    Max_DCA_Times = 3;         // Số lần DCA tối đa trong chu kỳ

sinput string _separator2 = "--- Nền Tảng (Khung W1) ---";
input int    SMA_Period = 50;           // Chu kỳ SMA50 (Lọc xu hướng)
input int    EMA_Period = 20;           // Chu kỳ EMA20 (Đường Bóp Cò)

sinput string _separator3 = "--- Chốt Lời 50% (Keltner W1) ---";
input int    Keltner_Period = 20;       // Chu kỳ tính Keltner
input double Keltner_Multiplier = 2.5;  // Hệ số biên trên Keltner (Bùng nổ)

sinput string _separator4 = "--- Other Settings ---";
input ulong  MagicNumber = 777999;      // Magic Number

int smaHandle;
int emaHandle;
int atrHandle;

static bool hasPartialClosed = false;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetExpertMagicNumber(MagicNumber);
   
   smaHandle = iMA(_Symbol, PERIOD_W1, SMA_Period, 0, MODE_SMA, PRICE_CLOSE);
   emaHandle = iMA(_Symbol, PERIOD_W1, EMA_Period, 0, MODE_EMA, PRICE_CLOSE);
   atrHandle = iATR(_Symbol, PERIOD_W1, Keltner_Period);
   
   if(smaHandle == INVALID_HANDLE || emaHandle == INVALID_HANDLE || atrHandle == INVALID_HANDLE)
     {
      Print("Lỗi khởi tạo Indicator!");
      return INIT_FAILED;
     }

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   IndicatorRelease(smaHandle);
   IndicatorRelease(emaHandle);
   IndicatorRelease(atrHandle);
  }

//+------------------------------------------------------------------+
//| Lấy thông tin tổng lệnh và tổng Lot đang giữ                     |
//+------------------------------------------------------------------+
int GetPositionCount(double &outTotalVolume)
  {
   int count = 0;
   outTotalVolume = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(posInfo.SelectByIndex(i))
        {
         if(posInfo.Symbol() == _Symbol && posInfo.Magic() == MagicNumber)
           {
            count++;
            outTotalVolume += posInfo.Volume();
           }
        }
     }
   return count;
  }

//+------------------------------------------------------------------+
//| Thực thi việc chốt lời 50% khối lượng                            |
//+------------------------------------------------------------------+
void PartialClose50Percent()
  {
   Print("BÙNG NỔ! Giá chạm Keltner Upper - Tiến hành chốt 50% khối lượng bảo toàn vốn.");
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(posInfo.SelectByIndex(i) && posInfo.Symbol() == _Symbol && posInfo.Magic() == MagicNumber)
        {
         double vol = posInfo.Volume();
         double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
         
         // Tính 50% khối lượng và làm tròn chuẩn Step
         double closeVol = MathFloor((vol * 0.5) / minLot) * minLot;
         
         if(closeVol >= SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN))
           {
            trade.PositionClosePartial(posInfo.Ticket(), closeVol);
           }
         else
           {
            trade.PositionClose(posInfo.Ticket()); // Rất nhỏ nên chốt hết toàn bộ
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Dọn dẹp đóng toàn bộ vị thế                                      |
//+------------------------------------------------------------------+
void CloseAllPositions()
  {
   Print("NGUY HIỂM: Giá đóng cửa dưới SMA50. Kích hoạt ĐIỂM CẮT chạy thoát khỏi thị trường.");
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(posInfo.SelectByIndex(i) && posInfo.Symbol() == _Symbol && posInfo.Magic() == MagicNumber)
        {
         trade.PositionClose(posInfo.Ticket());
        }
     }
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   double sma[], ema[], atr[];
   ArraySetAsSeries(sma, true);
   ArraySetAsSeries(ema, true);
   ArraySetAsSeries(atr, true);
   
   if(CopyBuffer(smaHandle, 0, 0, 2, sma) != 2) return;
   if(CopyBuffer(emaHandle, 0, 0, 2, ema) != 2) return;
   if(CopyBuffer(atrHandle, 0, 0, 1, atr) != 1) return;
   
   double totalVolume = 0.0;
   int posCount = GetPositionCount(totalVolume);
   
   // Tự động suy luận state hasPartialClosed trong trường hợp khởi động lại VPS/EA
   if(posCount > 0)
     {
      double expectedVolume = InitialLot + (posCount - 1) * DCALot;
      // Nếu tổng lượng giữ bị tụt hụt đáng kể so với kỳ vọng (nhỏ hơn 80%) => Đã bị chốt 50%
      if(totalVolume < expectedVolume * 0.8) hasPartialClosed = true;
     }
   else 
     {
      hasPartialClosed = false;
     }

   // 1. TRỤC CHỐT LỜI (Thực thi ngay lập tức ở chế độ Real-time từng Tick)
   if(!hasPartialClosed && posCount > 0)
     {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double keltnerUp = ema[0] + (Keltner_Multiplier * atr[0]);
      
      // Chạm/Phá vỡ biên trên Keltner W1 -> Chốt ngay 50% túi tiền
      if(bid >= keltnerUp)
        {
         PartialClose50Percent();
         hasPartialClosed = true;
         // Tiếp tục xuống đánh giá các điều kiện khác nếu cần, nhưng cờ chốt 50% đã nhảy
        }
     }

   // 2. TRỤC ĐÁNH GIÁ ĐIỂM VÀO / THOÁT TOÀN BỘ (Chỉ chạy KHI NẾN TUẦN ĐÓNG CỬA)
   static datetime confirmedBarTime = 0;
   datetime currentW1Time = iTime(_Symbol, PERIOD_W1, 0);
   
   // Chỉ đánh giá khi nhảy nến tuần mới (W1 có thời điểm mới) & đã CopyBuffer data thành công
   if(currentW1Time != confirmedBarTime && currentW1Time > 0)
     {
      // Lưu lại nến an toàn
      confirmedBarTime = currentW1Time;
      
      double close1 = iClose(_Symbol, PERIOD_W1, 1);
      double open1  = iOpen(_Symbol, PERIOD_W1, 1);
      double low1   = iLow(_Symbol, PERIOD_W1, 1);
      double high1  = iHigh(_Symbol, PERIOD_W1, 1);
      
      double sma1 = sma[1];
      double ema1 = ema[1];

      // ------ EXIT TOÀN BỘ THEO KỶ LUẬT (Đường lùi cuối cùng) ------
      // Cây nến Tuần đóng cửa hoàn toàn dưới đường SMA50
      if(close1 < sma1)
        {
         if(posCount > 0) CloseAllPositions();
         hasPartialClosed = false; // Reset lại vòng luân hồi mới
         return; 
        }

      // ------ TÌM KIẾM ĐẦU TƯ / DCA ------
      // Quy tắc Bắt buộc tối thượng 1: Giá nằm hoàn toàn TRÊN đường SMA50 (Lấy râu dưới cũng phải nằm trên)
      bool strictlyAboveSMA = (low1 > sma1); 
      
      // Quy tắc Cò Súng 2: Giá điều chỉnh giảm chạm/đâm xuyên qua EMA20
      bool touchEMA = (low1 <= ema1) && (high1 >= ema1); 
      
      // Định nghĩa Hành Động Giá Đảo Chiều (Nến Xanh tăng giá hoặc Nến rút chân Pinbar)
      double body = MathAbs(close1 - open1);
      double lowerWick = MathMin(open1, close1) - low1;
      
      bool isGreenReversal = (close1 > open1) && (close1 > ema1);                    // Nến Xanh bứt phá ngược lên trên EMA20
      bool isPinbarDoji    = (body == 0) && (lowerWick > 0) && (close1 >= ema1);    // Doji rút chân nằm trên EMA
      bool isPinbarStrong  = (lowerWick >= body * 1.5) && (close1 > ema1);          // Rút chân mạnh mẽ, râu dưới lớn hơn thân
      
      bool validPriceAction = (isGreenReversal || isPinbarDoji || isPinbarStrong);

      // KHỚP LỆNH
      if(strictlyAboveSMA && touchEMA && validPriceAction)
        {
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         if(posCount == 0)
           {
            trade.Buy(InitialLot, _Symbol, ask, 0, 0, "Bắt Đầu Giải Ngân (W1 Bounce EMA20)");
           }
         // Kiểm tra số lần DCA. Đầu tiên (Entry) = 1 pos. Nếu posCount < 1 + 3 (MaxDCA) => Vẫn được bắn thêm
         else if(posCount < (1 + Max_DCA_Times))
           {
            // Chỉ DCA 1 lệnh mỗi tuần nên if logic này nằm trong cơ chế kiểm tra nhảy nến tuần W1 là hoàn hảo!
            trade.Buy(DCALot, _Symbol, ask, 0, 0, "DCA Bóp Cò (W1 Bounce EMA20)");
           }
        }
     }
  }
//+------------------------------------------------------------------+
