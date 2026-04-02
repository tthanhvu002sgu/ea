//+------------------------------------------------------------------+
//|                             SmartManager_V5_5_Pro.mq5            |
//|                        Copyright 2024, Đối tác lập trình Gemini  |
//+------------------------------------------------------------------+
#property copyright "SmartManager Pro V5.5"
#property version   "5.50"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

// --- ENUMS ---
enum ENUM_SL_MODE { MODE_REAL = 0, MODE_VIRTUAL = 1, MODE_HYBRID = 2 };

// --- INPUTS ---

input group "=== 4. Visuals (Bottom-Left) ==="
input int          InpUI_X          = 20;             // Cách lề TRÁI
input int          InpUI_Y          = 45;             // Cách lề DƯỚI (tránh thanh thời gian)
input int          InpPanelWidth    = 170;            // Độ rộng bảng
input color        InpColorText     = C'220,220,220'; // Màu chữ sáng
input color        InpColorProfit   = clrLimeGreen;   // Màu lãi
input color        InpColorLoss     = clrTomato;      // Màu lỗ

input group "=== 5. Stopout Calculator ==="
input bool         InpShowStopout   = true;           // Hiển thị đường Giá Stopout
input double       InpSimulatedLot  = 0.01;           // Lot giả định (0.01)

input group "=== 6. Max Loss Limit ==="
input double       InpMaxLossUSD    = 0;              // Giới hạn lỗ floating ($, 0=tắt)

input group "=== 7. Daily Discipline ==="
input bool         InpDailyLimit    = true;           // Bật giới hạn lệnh trong ngày
input int          InpMaxDailyTrades= 3;              // Số lệnh tối đa / ngày

// --- GLOBALS ---
string Prefix = "SM_v5_5_";
// GUI Objects (Bottom Left)
string ObjPanel     = Prefix + "Panel";
string ObjLabelPL     = Prefix + "LblPL";
string ObjValPL       = Prefix + "ValPL";
string ObjLabelTrades = Prefix + "LblTrd";
string ObjValTrades   = Prefix + "ValTrd";
string ObjBtnClose    = Prefix + "BtnClose";
string ObjLabelDaily  = Prefix + "LblDay";
string ObjValDaily    = Prefix + "ValDay";
string ObjLabelSeq    = Prefix + "LblSeq";
string ObjValSeq      = Prefix + "ValSeq";
string ObjValBlock    = Prefix + "ValBlk";


// State Variables
// Daily Discipline State
int      g_DailyTradeCount = 0;
string   g_DailySequence = "";      // e.g. "W-L-W"
bool     g_DailyBlocked = false;
datetime g_LastDailyReset = 0;
int      g_LastKnownPositions = 0;   // Track position changes

// Popup State
bool g_ShowConfirmDialog = false;
string ObjDlgBg    = Prefix + "DlgBg";
string ObjDlgText1 = Prefix + "DlgText1";
string ObjDlgText2 = Prefix + "DlgText2";
string ObjDlgText3 = Prefix + "DlgText3";
string ObjDlgYes   = Prefix + "DlgBtnYes";
string ObjDlgNo    = Prefix + "DlgBtnNo";

// Structs for Logic

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   CreateGUI();
   EventSetTimer(1); 
   // Initialize daily tracking
   g_DailyTradeCount = 0;
   g_DailySequence = "";
   g_DailyBlocked = false;
   g_LastDailyReset = 0;
   g_LastKnownPositions = 0;
   
   // Load today's state from history on init
   ScanDailyHistory();
   
   // Tắt hiển thị lịch sử lệnh / mũi tên entry exit trên biểu đồ
   ChartSetInteger(0, CHART_SHOW_TRADE_HISTORY, false);
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   ObjectsDeleteAll(0, Prefix);
   ObjectDelete(0, Prefix + "StopoutBuy");
   ObjectDelete(0, Prefix + "StopoutSell");
   ChartRedraw();
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // === MAX LOSS CHECK (Floating only) - Runs EVERY TICK ===
   if(InpMaxLossUSD > 0) {
      double floatingPL = 0;
      for(int i = PositionsTotal() - 1; i >= 0; i--) {
         if(PositionGetSymbol(i) == _Symbol) {
            floatingPL += PositionGetDouble(POSITION_PROFIT)
                        + PositionGetDouble(POSITION_SWAP);
         }
      }
      if(floatingPL <= -InpMaxLossUSD) {
         CloseAllPositions();
         Alert("[SmartManager] MAX LOSS HIT! Floating: $",
               DoubleToString(floatingPL, 2),
               " | Limit: -$", DoubleToString(InpMaxLossUSD, 2));
      }
   }

   // === DAILY DISCIPLINE: Force breakeven TP on trade #4+ ===
   if(InpDailyLimit && g_DailyTradeCount >= InpMaxDailyTrades) {
      for(int i = PositionsTotal() - 1; i >= 0; i--) {
         if(PositionGetSymbol(i) != _Symbol) continue;
         ulong ticket = PositionGetTicket(i);
         double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         double currentTP = PositionGetDouble(POSITION_TP);
         
         // Set TP = entry price (breakeven) if not already set
         if(MathAbs(currentTP - openPrice) > _Point || currentTP == 0) {
            trade.PositionModify(ticket, PositionGetDouble(POSITION_SL), 
                                NormalizeDouble(openPrice, _Digits));
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Expert timer function                                            |
//+------------------------------------------------------------------+
void OnTimer()
{

   
   // Daily reset check (new day)
   MqlDateTime dt;
   TimeCurrent(dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   datetime startOfDay = StructToTime(dt);
   if(startOfDay != g_LastDailyReset) {
      ScanDailyHistory(); // Reset & rescan for new day
   }
   
   // Detect position close (trade completed) -> rescan
   int currentPositions = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      if(PositionGetSymbol(i) == _Symbol) currentPositions++;
   }
   if(currentPositions < g_LastKnownPositions && g_LastKnownPositions > 0) {
      // A position was closed, rescan daily history
      ScanDailyHistory();
   }
   g_LastKnownPositions = currentPositions;

   UpdateGUI();
   UpdateStopoutLines();
}

//+------------------------------------------------------------------+
//| Chart Event Handler                                              |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   if(id == CHARTEVENT_OBJECT_CLICK)
   {
      if(sparam == ObjBtnClose)
      {
         ObjectSetInteger(0, ObjBtnClose, OBJPROP_STATE, false);
         g_ShowConfirmDialog = true; // Kích hoạt Popup UI Của Mình
         CreateDialogUI();           // Tạo UI
      }
      else if(sparam == ObjDlgYes)
      {
         ObjectSetInteger(0, ObjDlgYes, OBJPROP_STATE, false);
         g_ShowConfirmDialog = false;
         HideDialogUI();
         CloseAllPositions();
      }
      else if(sparam == ObjDlgNo)
      {
         ObjectSetInteger(0, ObjDlgNo, OBJPROP_STATE, false);
         g_ShowConfirmDialog = false;
         HideDialogUI();
      }
   }
}

// ==========================================================================
// LOGIC: WEEKLY STATS (History Scan)
// ==========================================================================
void GetWeeklyStats(double &profit, int &trades)
{
   profit = 0.0;
   trades = 0;

   // Lấy thời gian bắt đầu tuần (00:00 Server Time)
   datetime startOfWeek = iTime(_Symbol, PERIOD_W1, 0);
   datetime now = TimeCurrent();

   // Chọn lịch sử từ đầu tuần đến hiện tại
   if(!HistorySelect(startOfWeek, now)) return;

   int deals = HistoryDealsTotal();

   for(int i = 0; i < deals; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      string symbol = HistoryDealGetString(ticket, DEAL_SYMBOL);
      
      if(symbol == _Symbol) 
      {
         double dealProfit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
         double dealSwap = HistoryDealGetDouble(ticket, DEAL_SWAP);
         double dealComm = HistoryDealGetDouble(ticket, DEAL_COMMISSION);
         profit += (dealProfit + dealSwap + dealComm);
         
         // Đếm số lệnh đã mở
         long entryType = HistoryDealGetInteger(ticket, DEAL_ENTRY);
         if(entryType == DEAL_ENTRY_IN) {
            trades++;
         }
      }
   }
}

// ==========================================================================
// LOGIC: DAILY DISCIPLINE (Scan History for Today)
// ==========================================================================
void ScanDailyHistory()
{
   // Reset daily state
   g_DailyTradeCount = 0;
   g_DailySequence = "";
   g_DailyBlocked = false;
   
   // Get start of today (server time)
   MqlDateTime dt;
   TimeCurrent(dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   datetime startOfDay = StructToTime(dt);
   datetime now = TimeCurrent();
   g_LastDailyReset = startOfDay;
   
   if(!HistorySelect(startOfDay, now)) return;
   
   int deals = HistoryDealsTotal();
   
   // We need to pair DEAL_ENTRY_OUT deals to get W/L results
   for(int i = 0; i < deals; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      string symbol = HistoryDealGetString(ticket, DEAL_SYMBOL);
      if(symbol != _Symbol) continue;
      
      long entryType = HistoryDealGetInteger(ticket, DEAL_ENTRY);
      
      // Count entries (DEAL_ENTRY_IN)
      if(entryType == DEAL_ENTRY_IN) {
         g_DailyTradeCount++;
      }
      
      // Track results from exits (DEAL_ENTRY_OUT)
      if(entryType == DEAL_ENTRY_OUT) {
         double dealPL = HistoryDealGetDouble(ticket, DEAL_PROFIT)
                       + HistoryDealGetDouble(ticket, DEAL_SWAP);
         
         string result = (dealPL >= 0) ? "W" : "L";
         if(g_DailySequence == "")
            g_DailySequence = result;
         else
            g_DailySequence += "-" + result;
      }
   }
   
   // Check block conditions
   CheckDailyBlock();
}

void CheckDailyBlock()
{
   if(!InpDailyLimit) { g_DailyBlocked = false; return; }
   
   // Block if max trades reached
   if(g_DailyTradeCount >= InpMaxDailyTrades) {
      g_DailyBlocked = true;
      return;
   }
   
   // Block if WW or LL pattern detected (consecutive)
   int len = StringLen(g_DailySequence);
   if(len >= 3) { // minimum "W-W" = 3 chars
      // Get last 2 results
      string parts[];
      int count = StringSplit(g_DailySequence, '-', parts);
      if(count >= 2) {
         string last  = parts[count - 1];
         string prev  = parts[count - 2];
         if((last == "W" && prev == "W") || (last == "L" && prev == "L")) {
            g_DailyBlocked = true;
            return;
         }
      }
   }
   
   g_DailyBlocked = false;
}



// ==========================================================================

void CloseAllPositions() {
   for(int i=PositionsTotal()-1; i>=0; i--) if(PositionGetSymbol(i) == _Symbol) trade.PositionClose(PositionGetTicket(i));
}

// ==========================================================================
// GUI: BOTTOM-LEFT & TOP-RIGHT
// ==========================================================================
void CreateGUI()
{
   int w = InpPanelWidth; 
   int h = 160; // Giảm chiều cao vì bỏ nút Apply
   int rowH = 22;
   int padding = 10;
   
   int topRowY = InpUI_Y + h - 25; 
   
   // --- Row 3: Weekly Profit (was Row 4, moved up) ---
   int row4Y = InpUI_Y + h - 85;
   CreateLabel(ObjLabelPL, InpUI_X + padding, row4Y, "Weekly P/L:", clrGray, 8, ANCHOR_LEFT_UPPER);
   CreateLabel(ObjValPL, InpUI_X + w - padding, row4Y, "$0.00", clrWhite, 8, ANCHOR_RIGHT_UPPER);

   // --- Row 3.1: Weekly Trades (moved up) ---
   int rowTradesY = InpUI_Y + h - 110;
   CreateLabel(ObjLabelTrades, InpUI_X + padding, rowTradesY, "Weekly Trades:", clrGray, 8, ANCHOR_LEFT_UPPER);
   CreateLabel(ObjValTrades, InpUI_X + w - padding, rowTradesY, "0", clrWhite, 8, ANCHOR_RIGHT_UPPER);
   
   // --- Row 4: Daily Trades (W/L sequence, moved up) ---
   int rowDailyY = InpUI_Y + h - 135;
   CreateLabel(ObjLabelDaily, InpUI_X + padding, rowDailyY, "Daily:", clrGray, 8, ANCHOR_LEFT_UPPER);
   CreateLabel(ObjValDaily, InpUI_X + w - padding, rowDailyY, "---", clrWhite, 8, ANCHOR_RIGHT_UPPER);
   
   // --- Row 4.1: Daily Sequence (moved up) ---
   int rowSeqY = InpUI_Y + h - 160;
   CreateLabel(ObjLabelSeq, InpUI_X + padding, rowSeqY, "Results:", clrGray, 8, ANCHOR_LEFT_UPPER);
   CreateLabel(ObjValSeq, InpUI_X + w - padding, rowSeqY, "---", clrWhite, 8, ANCHOR_RIGHT_UPPER);
   
   // --- Row 4.2: Block Status (moved up) ---
   int rowBlkY = InpUI_Y + h - 185;
   CreateLabel(ObjValBlock, InpUI_X + w/2, rowBlkY, "", clrGray, 8, ANCHOR_LEFT_UPPER);

   // --- Row 5: Close All ---
   int btnCloseY = InpUI_Y + 35; 
   if(ObjectFind(0, ObjBtnClose) < 0) ObjectCreate(0, ObjBtnClose, OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, ObjBtnClose, OBJPROP_CORNER, CORNER_LEFT_LOWER);
   ObjectSetInteger(0, ObjBtnClose, OBJPROP_XDISTANCE, InpUI_X + padding);
   ObjectSetInteger(0, ObjBtnClose, OBJPROP_YDISTANCE, btnCloseY);
   ObjectSetInteger(0, ObjBtnClose, OBJPROP_XSIZE, w - (padding * 2));
   ObjectSetInteger(0, ObjBtnClose, OBJPROP_YSIZE, 25);
   ObjectSetString(0, ObjBtnClose, OBJPROP_TEXT, "CLOSE ALL");
   ObjectSetInteger(0, ObjBtnClose, OBJPROP_BGCOLOR, C'200, 60, 60'); 
   ObjectSetInteger(0, ObjBtnClose, OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, ObjBtnClose, OBJPROP_ZORDER, 11);


}

// ==========================================================================
// GUI: DIALOG MODULE (Realtime Confirm)
// ==========================================================================
void CreateDialogUI()
{
   int cx = (int)ChartGetInteger(0, CHART_WIDTH_IN_PIXELS) / 2;
   int cy = (int)ChartGetInteger(0, CHART_HEIGHT_IN_PIXELS) / 2;
   
   int w = 360, h = 180;
   int padding = 30;

   // 1. Background (Light Theme)
   if(ObjectFind(0, ObjDlgBg) < 0) ObjectCreate(0, ObjDlgBg, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, ObjDlgBg, OBJPROP_XDISTANCE, cx - w/2);
   ObjectSetInteger(0, ObjDlgBg, OBJPROP_YDISTANCE, cy - h/2);
   ObjectSetInteger(0, ObjDlgBg, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, ObjDlgBg, OBJPROP_YSIZE, h);
   ObjectSetInteger(0, ObjDlgBg, OBJPROP_BGCOLOR, C'245,245,250');
   ObjectSetInteger(0, ObjDlgBg, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, ObjDlgBg, OBJPROP_HIDDEN, false);
   ObjectSetInteger(0, ObjDlgBg, OBJPROP_ZORDER, 100);

   // 2. Text (Line 1)
   if(ObjectFind(0, ObjDlgText1) < 0) ObjectCreate(0, ObjDlgText1, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, ObjDlgText1, OBJPROP_XDISTANCE, cx);
   ObjectSetInteger(0, ObjDlgText1, OBJPROP_YDISTANCE, cy - 50);
   ObjectSetInteger(0, ObjDlgText1, OBJPROP_ANCHOR, ANCHOR_CENTER);
   ObjectSetInteger(0, ObjDlgText1, OBJPROP_COLOR, C'100,100,100'); 
   ObjectSetInteger(0, ObjDlgText1, OBJPROP_FONTSIZE, 10);
   ObjectSetString(0, ObjDlgText1, OBJPROP_FONT, "Trebuchet MS");
   ObjectSetInteger(0, ObjDlgText1, OBJPROP_HIDDEN, false);
   ObjectSetInteger(0, ObjDlgText1, OBJPROP_ZORDER, 101);

   // 2. Text (Line 2 - P/L)
   if(ObjectFind(0, ObjDlgText2) < 0) ObjectCreate(0, ObjDlgText2, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, ObjDlgText2, OBJPROP_XDISTANCE, cx);
   ObjectSetInteger(0, ObjDlgText2, OBJPROP_YDISTANCE, cy - 20);
   ObjectSetInteger(0, ObjDlgText2, OBJPROP_ANCHOR, ANCHOR_CENTER);
   ObjectSetInteger(0, ObjDlgText2, OBJPROP_COLOR, C'30,30,30'); 
   ObjectSetInteger(0, ObjDlgText2, OBJPROP_FONTSIZE, 14);
   ObjectSetString(0, ObjDlgText2, OBJPROP_FONT, "Trebuchet MS");
   ObjectSetInteger(0, ObjDlgText2, OBJPROP_HIDDEN, false);
   ObjectSetInteger(0, ObjDlgText2, OBJPROP_ZORDER, 101);

   // 2. Text (Line 3)
   if(ObjectFind(0, ObjDlgText3) < 0) ObjectCreate(0, ObjDlgText3, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, ObjDlgText3, OBJPROP_XDISTANCE, cx);
   ObjectSetInteger(0, ObjDlgText3, OBJPROP_YDISTANCE, cy + 10);
   ObjectSetInteger(0, ObjDlgText3, OBJPROP_ANCHOR, ANCHOR_CENTER);
   ObjectSetInteger(0, ObjDlgText3, OBJPROP_COLOR, C'30,30,30'); 
   ObjectSetInteger(0, ObjDlgText3, OBJPROP_FONTSIZE, 11);
   ObjectSetString(0, ObjDlgText3, OBJPROP_FONT, "Trebuchet MS");
   ObjectSetInteger(0, ObjDlgText3, OBJPROP_HIDDEN, false);
   ObjectSetInteger(0, ObjDlgText3, OBJPROP_ZORDER, 101);

   // 3. Btn Yes
   if(ObjectFind(0, ObjDlgYes) < 0) ObjectCreate(0, ObjDlgYes, OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, ObjDlgYes, OBJPROP_XDISTANCE, cx - w/2 + padding + 10);
   ObjectSetInteger(0, ObjDlgYes, OBJPROP_YDISTANCE, cy + 45);
   ObjectSetInteger(0, ObjDlgYes, OBJPROP_XSIZE, 125);
   ObjectSetInteger(0, ObjDlgYes, OBJPROP_YSIZE, 35);
   ObjectSetString(0, ObjDlgYes, OBJPROP_TEXT, "YES (CLOSE)");
   ObjectSetInteger(0, ObjDlgYes, OBJPROP_BGCOLOR, C'220, 50, 50');
   ObjectSetInteger(0, ObjDlgYes, OBJPROP_COLOR, clrWhite);
   ObjectSetString(0, ObjDlgYes, OBJPROP_FONT, "Trebuchet MS");
   ObjectSetInteger(0, ObjDlgYes, OBJPROP_HIDDEN, false);
   ObjectSetInteger(0, ObjDlgYes, OBJPROP_ZORDER, 101);

   // 4. Btn No
   if(ObjectFind(0, ObjDlgNo) < 0) ObjectCreate(0, ObjDlgNo, OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, ObjDlgNo, OBJPROP_XDISTANCE, cx + w/2 - padding - 135);
   ObjectSetInteger(0, ObjDlgNo, OBJPROP_YDISTANCE, cy + 45);
   ObjectSetInteger(0, ObjDlgNo, OBJPROP_XSIZE, 125);
   ObjectSetInteger(0, ObjDlgNo, OBJPROP_YSIZE, 35);
   ObjectSetString(0, ObjDlgNo, OBJPROP_TEXT, "NO (CANCEL)");
   ObjectSetInteger(0, ObjDlgNo, OBJPROP_BGCOLOR, C'220, 220, 225'); // Light gray button
   ObjectSetInteger(0, ObjDlgNo, OBJPROP_COLOR, C'30,30,30');        // Dark text for contrast
   ObjectSetString(0, ObjDlgNo, OBJPROP_FONT, "Trebuchet MS");
   ObjectSetInteger(0, ObjDlgNo, OBJPROP_HIDDEN, false);
   ObjectSetInteger(0, ObjDlgNo, OBJPROP_ZORDER, 101);

   ChartRedraw();
}

void HideDialogUI()
{
   ObjectDelete(0, ObjDlgBg);
   ObjectDelete(0, ObjDlgText1);
   ObjectDelete(0, ObjDlgText2);
   ObjectDelete(0, ObjDlgText3);
   ObjectDelete(0, ObjDlgYes);
   ObjectDelete(0, ObjDlgNo);
   ChartRedraw();
}

void UpdateDialogData()
{
   if(!g_ShowConfirmDialog) return;

   double floatingPL = 0;
   int openPosCount = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      if(PositionGetSymbol(i) == _Symbol) {
         floatingPL += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
         openPosCount++;
      }
   }

   string sign = (floatingPL >= 0) ? "+" : "";
   
   ObjectSetString(0, ObjDlgText1, OBJPROP_TEXT, StringFormat("YOU ARE ABOUT TO CLOSE [%d] POSITIONS", openPosCount));
   ObjectSetString(0, ObjDlgText2, OBJPROP_TEXT, StringFormat("Floating P/L: %s$ %.2f", sign, floatingPL));
   ObjectSetString(0, ObjDlgText3, OBJPROP_TEXT, "Confirm Close?");

   // Đổi màu chữ P/L riêng biệt (Xanh Lãi, Đỏ Lỗ, Đen Hòa Mức) cho nổi bật trên nền trắng
   color textColor = (floatingPL > 0) ? C'34,139,34' : (floatingPL < 0) ? C'220,20,60' : C'30,30,30';
   ObjectSetInteger(0, ObjDlgText2, OBJPROP_COLOR, textColor);
}

void UpdateGUI()
{
   // Tách riêng update GUI của Popup nếu đang hiện
   if(g_ShowConfirmDialog) {
       UpdateDialogData();
   }
   // 1. Weekly Stats
   double weeklyPL = 0;
   int weeklyTrades = 0;
   GetWeeklyStats(weeklyPL, weeklyTrades);
   
   string prefixPL = (weeklyPL >= 0) ? "+$" : "-$";
   ObjectSetString(0, ObjValPL, OBJPROP_TEXT, prefixPL + DoubleToString(MathAbs(weeklyPL), 2));
   ObjectSetInteger(0, ObjValPL, OBJPROP_COLOR, (weeklyPL >= 0) ? InpColorProfit : InpColorLoss);

   ObjectSetString(0, ObjValTrades, OBJPROP_TEXT, IntegerToString(weeklyTrades));
   ObjectSetInteger(0, ObjValTrades, OBJPROP_COLOR, clrWhite);

   // 3.5 Daily Discipline - Show W/L sequence on Daily row
   string dailyDisplay = "";
   if(g_DailySequence == "")
      dailyDisplay = "--- (0/" + IntegerToString(InpMaxDailyTrades) + ")";
   else
      dailyDisplay = g_DailySequence + " (" + IntegerToString(g_DailyTradeCount) + "/" + IntegerToString(InpMaxDailyTrades) + ")";
   ObjectSetString(0, ObjValDaily, OBJPROP_TEXT, dailyDisplay);
   
   // Color based on sequence
   color dailyClr = clrWhite;
   if(g_DailyBlocked)
      dailyClr = clrMagenta;
   else if(StringFind(g_DailySequence, "W") >= 0 && StringFind(g_DailySequence, "L") < 0)
      dailyClr = InpColorProfit;
   else if(StringFind(g_DailySequence, "L") >= 0 && StringFind(g_DailySequence, "W") < 0)
      dailyClr = InpColorLoss;
   else if(g_DailySequence != "")
      dailyClr = clrGold;
   ObjectSetInteger(0, ObjValDaily, OBJPROP_COLOR, dailyClr);
   
   // Sequence detail on row below
   string seqInfo = "";
   if(g_DailyBlocked && g_DailyTradeCount >= InpMaxDailyTrades)
      seqInfo = "Max reached";
   else if(g_DailyBlocked)
      seqInfo = "Pattern stop";
   else if(g_DailyTradeCount > 0)
      seqInfo = IntegerToString(InpMaxDailyTrades - g_DailyTradeCount) + " left";
   ObjectSetString(0, ObjValSeq, OBJPROP_TEXT, seqInfo);
   ObjectSetInteger(0, ObjValSeq, OBJPROP_COLOR, g_DailyBlocked ? clrMagenta : clrGray);
   
   // Block status
   if(g_DailyBlocked) {
      ObjectSetString(0, ObjValBlock, OBJPROP_TEXT, "⛔ BLOCKED - REST!");
      ObjectSetInteger(0, ObjValBlock, OBJPROP_COLOR, clrMagenta);
   } else if(InpDailyLimit) {
      ObjectSetString(0, ObjValBlock, OBJPROP_TEXT, "✓ TRADING OK");
      ObjectSetInteger(0, ObjValBlock, OBJPROP_COLOR, C'80,180,80');
   } else {
      ObjectSetString(0, ObjValBlock, OBJPROP_TEXT, "");
   }


   
   ChartRedraw();
}

void CreateLabel(string name, int x, int y, string text, color clr, int fontSize, ENUM_ANCHOR_POINT anchor)
{
   if(ObjectFind(0, name) < 0) ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_LOWER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x); 
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, anchor); 
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontSize);
   ObjectSetString(0, name, OBJPROP_FONT, "Segoe UI");
   ObjectSetInteger(0, name, OBJPROP_ZORDER, 11);
}

// ==========================================================================
// LOGIC: STOPOUT CALCULATOR
// ==========================================================================
void UpdateStopoutLines()
{
   if(!InpShowStopout)
   {
      ObjectDelete(0, Prefix + "StopoutBuy");
      ObjectDelete(0, Prefix + "StopoutSell");
      return;
   }
   
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   
   if(tv == 0 || ts == 0 || InpSimulatedLot <= 0) return;
   
   // Bật hiển thị mô tả Object của Biểu đồ (để thấy text ghi chú trên đường kẻ)
   ChartSetInteger(0, CHART_SHOW_OBJECT_DESCR, true);
   
   // Công thức: Khoảng giá = Equity / (Lot_giả_định * TickValue_của_1_Lot / TickSize)
   double delta_price = eq * ts / (InpSimulatedLot * tv);
   
   double stopout_buy = SymbolInfoDouble(_Symbol, SYMBOL_BID) - delta_price;
   double stopout_sell = SymbolInfoDouble(_Symbol, SYMBOL_ASK) + delta_price;
   
   // Draw Buy Stopout (Giá giảm xuống)
   DrawHLine(Prefix + "StopoutBuy", stopout_buy, clrCrimson, STYLE_DASHDOT, StringFormat("Stopout (Buy %.2f Lot)", InpSimulatedLot));
   
   // Draw Sell Stopout (Giá tăng lên)
   DrawHLine(Prefix + "StopoutSell", stopout_sell, clrCrimson, STYLE_DASHDOT, StringFormat("Stopout (Sell %.2f Lot)", InpSimulatedLot));
}

void DrawHLine(string name, double price, color clr, ENUM_LINE_STYLE style, string tooltip)
{
   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_HLINE, 0, 0, price);
      ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
      ObjectSetInteger(0, name, OBJPROP_STYLE, style);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, name, OBJPROP_BACK, true);
      ObjectSetString(0, name, OBJPROP_TOOLTIP, tooltip);
      ObjectSetString(0, name, OBJPROP_TEXT, tooltip);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true); // Ẩn khỏi list object
   }
   else
   {
      ObjectSetDouble(0, name, OBJPROP_PRICE, price);
      ObjectSetString(0, name, OBJPROP_TEXT, tooltip);
      ObjectSetString(0, name, OBJPROP_TOOLTIP, tooltip);
   }
}
