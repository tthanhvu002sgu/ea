//+------------------------------------------------------------------+
//|                                             Sniper Box.mq5       |
//|                                        Antigravity (AI Assistant)|
//+------------------------------------------------------------------+
#property copyright "Antigravity AI"
#property link      ""
#property version   "2.00"
#property description "Chỉ báo theo dõi Hộp nén (Rectangle) + Vẽ EMA"

#property indicator_chart_window
#property indicator_buffers 1
#property indicator_plots   1

#property indicator_label1  "EMA 50"
#property indicator_type1   DRAW_LINE
#property indicator_color1  clrYellow
#property indicator_style1  STYLE_SOLID
#property indicator_width1  2

//=== INPUTS ===
input group "=== 1. Cài đặt Chỉ báo ==="
input int    InpEmaPeriod      = 50;       // Chu kỳ đường EMA

input group "=== 2. Cài đặt Cảnh báo & Email ==="
input bool   InpEnableEmail    = true;     // Cho phép gửi Email (SendMail)
input bool   InpEnableAlert    = true;     // Cho phép Alert trên màn hình MT5
input string InpEmailPrefix    = "BOX";    // Tiền tố tiêu đề Email (ví dụ: BOX)

//=== BUFFERS ===
double BufEMA[];

//=== GLOBALS ===
int      g_emaHandle;
datetime g_lastPeriodicEmailTime = 0;
string   g_lastTouchObjName      = "";
int      g_lastTouchEdge         = 0;      // 0: none, 1: top, -1: bottom
datetime g_lastBreakoutTime      = 0;

struct ActiveBox {
   bool     valid;
   string   name;
   double   top;
   double   bottom;
   datetime t1;
   datetime t2;
};

//+------------------------------------------------------------------+
int OnInit()
{
   // Gắn Buffer EMA vào biểu đồ
   SetIndexBuffer(0, BufEMA, INDICATOR_DATA);
   PlotIndexSetDouble(0, PLOT_EMPTY_VALUE, 0.0);
   PlotIndexSetString(0, PLOT_LABEL, "EMA " + IntegerToString(InpEmaPeriod));

   // Khởi tạo Handle cho EMA
   g_emaHandle = iMA(_Symbol, PERIOD_CURRENT, InpEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if(g_emaHandle == INVALID_HANDLE) {
      Print("Lỗi KHỞI TẠO: Không thể lấy dữ liệu EMA.");
      return(INIT_FAILED);
   }

   // Lấy mốc chẵn giờ cho báo cáo định kỳ
   datetime now = TimeCurrent();
   g_lastPeriodicEmailTime = now - (now % 3600); 

   EventSetTimer(60);

   Print("Sniper Box Indicator đã khởi chạy thành công.");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(g_emaHandle);
   EventKillTimer();
}

//+------------------------------------------------------------------+
// Đi tìm hộp vẽ cuối cùng thỏa điều kiện chưa hết thời gian t2
ActiveBox GetLatestBox()
{
   ActiveBox result;
   result.valid = false;
   datetime newestTime = 0;
   int total = ObjectsTotal(0, 0, OBJ_RECTANGLE);
   datetime now = TimeCurrent();
   
   for(int i = 0; i < total; i++) {
      string name = ObjectName(0, i, 0, OBJ_RECTANGLE);
      
      datetime t1 = (datetime)ObjectGetInteger(0, name, OBJPROP_TIME, 0);
      datetime t2 = (datetime)ObjectGetInteger(0, name, OBJPROP_TIME, 1);
      if(t1 > t2) { datetime tmp = t1; t1 = t2; t2 = tmp; }
      
      // Bỏ qua hộp đã vượt ngang (hết hiệu lực thời gian)
      if(now >= t2) continue;
      
      // Tìm hộp mới vẽ nhất dựa vào mốc bắt đầu
      if(t1 > newestTime) {
         newestTime = t1;
         result.valid = true;
         result.name = name;
         result.top = MathMax(ObjectGetDouble(0, name, OBJPROP_PRICE, 0), ObjectGetDouble(0, name, OBJPROP_PRICE, 1));
         result.bottom = MathMin(ObjectGetDouble(0, name, OBJPROP_PRICE, 0), ObjectGetDouble(0, name, OBJPROP_PRICE, 1));
         result.t1 = t1;
         result.t2 = t2;
      }
   }
   
   return result;
}

//+------------------------------------------------------------------+
string BuildEmailContent(ActiveBox &box, double price, double curEma, string titleStr, string status)
{
   int dec = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double pointsToTop = MathAbs(box.top - price) / _Point;
   double pointsToBot = MathAbs(price - box.bottom) / _Point;
   
   string txt = "========================================\n";
   txt += " 🔔 " + titleStr + "\n";
   txt += "========================================\n\n";
   
   txt += "[THÔNG TIN THỊ TRƯỜNG]\n";
   txt += "- Cặp giao dịch: " + _Symbol + " (" + EnumToString(Period()) + ")\n";
   txt += "- Giá (Lúc Cảnh Báo): " + DoubleToString(price, dec) + "\n";
   txt += "- Đường EMA " + IntegerToString(InpEmaPeriod) + ": " + DoubleToString(curEma, dec);
   if(curEma > 0) {
      txt += (price > curEma) ? " (Giá NẰM TRÊN xu hướng EMA)\n\n" : " (Giá NẰM DƯỚI xu hướng EMA)\n\n";
   } else txt += "\n\n";

   txt += "[THÔNG TIN HỘP NÉN - BOX " + box.name + "]\n";
   txt += "- Cạnh Trên Box: " + DoubleToString(box.top, dec) + "\n";
   txt += "- Cạnh Dưới Box: " + DoubleToString(box.bottom, dec) + "\n";
   txt += "- Hết hạn (Tới): " + TimeToString(box.t2, TIME_DATE|TIME_MINUTES) + "\n\n";
   
   txt += "[CHI TIẾT KIỂU CHẠM]\n";
   txt += ">> Trạng Thái: " + status + " <<\n";
   txt += "- Khoảng cách tới cạnh TRÊN:  " + DoubleToString(pointsToTop, 0) + " Points\n";
   txt += "- Khoảng cách tới cạnh DƯỚI: " + DoubleToString(pointsToBot, 0) + " Points\n";
   txt += "========================================\n";
   
   return txt;
}

//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
{
   if(rates_total < 3) return 0;
   
   // --- VẼ EMA LÊN BIỂU ĐỒ ---
   int to_copy = (prev_calculated > rates_total || prev_calculated <= 0) ? rates_total : rates_total - prev_calculated + 1;
   double tempEMA[];
   if(CopyBuffer(g_emaHandle, 0, 0, to_copy, tempEMA) > 0) {
      int start = rates_total - to_copy;
      for(int i = 0; i < to_copy; i++) {
         BufEMA[start + i] = tempEMA[i];
      }
   }
   
   // --- KIỂM TRA HỘP MỚI NHẤT YÊU CẦU ---
   ActiveBox box = GetLatestBox();
   if(!box.valid) return rates_total;
   
   double curEma = BufEMA[rates_total - 1];      // Mức EMA hiện hành
   double lastClose = close[rates_total - 2];    // Nến đóng cửa ngay trước đó (Gần nhất)
   double prevClose = close[rates_total - 3];    // Nến trước của "nến đóng cửa trước đó"
   datetime lastTime = time[rates_total - 2];
   
   // =========================================================================
   // LOẠI 1: CẢNH BÁO BÓP CÒ (CHỐT NẾN BREAKOUT CLOSED)
   // =========================================================================
   bool isBreakoutClose = false;
   string breakDir = "";
   
   // Nếu nến prev nằm TRONG (hoặc Ở MÉP) hộp, còn nến last đóng NGOÀI hộp
   if(lastClose > box.top && prevClose <= box.top) { 
       isBreakoutClose = true; 
       breakDir = "CẠNH TRÊN (BULLISH)"; 
   }
   else if(lastClose < box.bottom && prevClose >= box.bottom) { 
       isBreakoutClose = true; 
       breakDir = "CẠNH DƯỚI (BEARISH)"; 
   }
   
   if(isBreakoutClose && g_lastBreakoutTime != lastTime) {
      string subject = StringFormat("[%s] - %s BÓP CÒ: NẾN ĐÓNG CỬA PHÁ %s!", InpEmailPrefix, _Symbol, breakDir);
      string body = BuildEmailContent(box, lastClose, curEma, "CẢNH BÁO BÓP CÒ (BREAKOUT CLOSE)", "CHỐT NẾN PHÁ VỠ " + breakDir);
      
      if(InpEnableEmail) SendMail(subject, body);
      if(InpEnableAlert) Alert(subject);
      
      g_lastBreakoutTime = lastTime;
   }
   
   // Nếu hộp này đã vỡ hỏng hoàn toàn (vì chốt nến bên ngoài), ta ko cần báo chạm Râu nữa
   if(lastClose > box.top || lastClose < box.bottom) {
      return rates_total;
   }
   
   // =========================================================================
   // LOẠI 2: CẢNH BÁO CHUẨN BỊ (CHẠM RÂU - HIGH/LOW TOUCH) TRONG NẾN HIỆN TẠI
   // =========================================================================
   double curHigh = high[rates_total - 1]; // Giá cao nhất nến đang hình thành
   double curLow = low[rates_total - 1];   // Giá thấp nhất nến đang hình thành
   double curClose = close[rates_total - 1]; // Current Close/Last tick
   
   int touch = 0;
   if(curHigh >= box.top) touch = 1;
   else if(curLow <= box.bottom) touch = -1;
   
   if(touch != 0 && (g_lastTouchObjName != box.name || g_lastTouchEdge != touch)) {
      string touchDir = (touch == 1) ? "TRÊN" : "DƯỚI";
      string subject = StringFormat("[%s] - %s CHẠM CẠNH %s (CHUẨN BỊ)!", InpEmailPrefix, _Symbol, touchDir);
      string body = BuildEmailContent(box, curClose, curEma, "CẢNH BÁO CHUẨN BỊ (TOUCH BIÊN)", "GIÁ ĐANG XUYÊN CHẠM CẠNH " + touchDir);
      
      if(InpEnableEmail) SendMail(subject, body);
      if(InpEnableAlert) Alert(subject);
      
      g_lastTouchObjName = box.name;
      g_lastTouchEdge = touch;
   }
   
   // Reset Touch state nếu giá co râu rút ngược thẳng vào giữa lòng hộp
   if(touch == 0 && curHigh < box.top - 2*_Point && curLow > box.bottom + 2*_Point) {
      g_lastTouchEdge = 0;
   }
   
   return rates_total;
}

//+------------------------------------------------------------------+
void OnTimer()
{
   datetime now = TimeCurrent();
   if(now - g_lastPeriodicEmailTime >= 3600) {
      g_lastPeriodicEmailTime = now - (now % 3600); // Lưu mốc tròn giờ
      
      ActiveBox box = GetLatestBox();
      if(box.valid) {
         // Kiểm tra xem hộp này đã vỡ chưa (Nếu chốt nến nằm ngoài rồi thì thôi ko gửi báo cáo 1H nữa)
         double lastClose = iClose(_Symbol, PERIOD_CURRENT, 1);
         if(lastClose <= box.top && lastClose >= box.bottom) {
            
            double curPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
            double emaArr[];
            CopyBuffer(g_emaHandle, 0, 0, 1, emaArr);
            double curEma = emaArr[0];
            
            string subject = StringFormat("[%s] - %s Báo Cáo Hộp Nén 1 Giờ", InpEmailPrefix, _Symbol);
            string body = BuildEmailContent(box, curPrice, curEma, "BÁO CÁO NHỊP TÍCH LŨY (1H)", "ĐANG TÍCH LŨY AN TOÀN TRONG HỘP");
            
            if(InpEnableEmail) SendMail(subject, body);
            Print("Đã gửi Email báo cáo hộp Sniper 1 giờ lúc: ", TimeToString(now));
         }
      }
   }
}
//+------------------------------------------------------------------+
