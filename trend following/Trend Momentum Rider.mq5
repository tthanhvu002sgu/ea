//+------------------------------------------------------------------+
//|                                           TrendMomentumRider.mq5 |
//|                                      Copyright 2026, Antigravity |
//+------------------------------------------------------------------+
#property copyright "Antigravity"
#property link      ""
#property version   "1.00"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>

//====================================================================
// ENUMS FOR VOLUME CONFIG
//====================================================================
enum ENUM_VOLUME_MODE
{
   VOL_FIXED = 0,      // Fixed Lot
   VOL_RISK_MONEY = 1, // Risk per trade (USD)
   VOL_RISK_PERC = 2   // Risk per trade (% balance)
};

//====================================================================
// INPUT PARAMETERS
//====================================================================
input group "=== Main Settings ==="
input int    InpMagicNumber     = 20260404; // Magic Number
input int    InpMaxDailyLosses  = 2;        // Max Daily Losses
input int    InpMaxSpread       = 30;       // Max Spread (points)
input int    InpMaxSlippage     = 5;        // Max Slippage (points)
input int    InpMinSLPoints     = 100;      // Min SL distance (points)

input group "=== Volume Settings ==="
input ENUM_VOLUME_MODE InpVolumeMode = VOL_RISK_PERC; // Volume Mode
input double InpFixedLot        = 0.1;      // Fixed Lot (if Mode = Fixed)
input double InpRiskMoney       = 50.0;     // Risk $ (if Mode = Risk USD)
input double InpRiskPercent     = 1.0;      // Risk % (if Mode = Risk %)

input group "=== Indicators Setup ==="
input int    InpEmaFastPeriod   = 21;       // H1 Fast EMA Period
input int    InpEmaSlowPeriod   = 50;       // H1 Slow EMA Period
input int    InpH4EmaPeriod     = 50;       // H4 Trend EMA Period
input int    InpAdxPeriod       = 14;       // H1 ADX Period
input double InpAdxThreshold    = 20.0;     // H1 ADX Min Threshold
input int    InpAtrPeriod       = 14;       // H1 ATR Period

input group "=== Risk & Reward Multipliers ==="
input double InpSlAtrMulti      = 1.5;      // SL = ATR x Multiplier
input double InpTpAtrMulti      = 3.5;      // TP = ATR x Multiplier

input group "=== Trailing Stop ==="
input bool   InpUseTrailing     = true;     // Enable Trailing Stop
input double InpTrailAtrMulti   = 2.0;      // Trailing Distance = ATR x
input double InpTrailStepMulti  = 0.5;      // Trailing Step = ATR x

input group "=== Session Times ==="
input string InpSessionLondonStart = "08:00"; // London Session Start 
input string InpSessionLondonEnd   = "12:00"; // London Session End
input string InpSessionNYStart     = "13:00"; // New York Session Start
input string InpSessionNYEnd       = "17:00"; // New York Session End


//====================================================================
// GLOBAL VARIABLES
//====================================================================
CTrade         trade;
CPositionInfo  posInfo;
CSymbolInfo    symInfo;
CAccountInfo   accInfo;

int            hEmaFast;
int            hEmaSlow;
int            hEmaH4;
int            hAdx;
int            hAtr;

int            currentDailyLosses = 0;
int            lastDay = -1;
datetime       lastBarTime = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpMaxSlippage);
   symInfo.Name(_Symbol);
   
   // Khởi tạo Handles
   hEmaFast = iMA(_Symbol, PERIOD_H1, InpEmaFastPeriod, 0, MODE_EMA, PRICE_CLOSE);
   hEmaSlow = iMA(_Symbol, PERIOD_H1, InpEmaSlowPeriod, 0, MODE_EMA, PRICE_CLOSE);
   hEmaH4   = iMA(_Symbol, PERIOD_H4, InpH4EmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
   hAdx     = iADX(_Symbol, PERIOD_H1, InpAdxPeriod);
   hAtr     = iATR(_Symbol, PERIOD_H1, InpAtrPeriod);
   
   if(hEmaFast == INVALID_HANDLE || hEmaSlow == INVALID_HANDLE || 
      hEmaH4 == INVALID_HANDLE || hAdx == INVALID_HANDLE || hAtr == INVALID_HANDLE)
   {
      Print("Lỗi khởi tạo Indicator handles!");
      return INIT_FAILED;
   }

   Print("Khởi tạo Trend Momentum Rider thành công. Magic: ", InpMagicNumber);
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(hEmaFast);
   IndicatorRelease(hEmaSlow);
   IndicatorRelease(hEmaH4);
   IndicatorRelease(hAdx);
   IndicatorRelease(hAtr);
   Print("Deinit EA. Lý do: ", reason);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   if(!symInfo.RefreshRates()) return;

   // 1. Quản lý Trailing Stop
   ManageOpenPositions();

   // 2. Tối ưu hiệu năng: Các logic nặng kiểm tra tín hiệu vào lệnh CHỈ CHẠY 1 LẦN khi có nến H1 mới
   if(IsNewBar())
   {
      // Check qua ngày mới để reset bộ đếm lệnh thua
      ResetDailyVariables();
      
      // Xóa log nếu đã đạt lượng max daily loss
      if(currentDailyLosses >= InpMaxDailyLosses) {
         PrintFormat("Bỏ qua tín hiệu: Đã chạm tối đa ngương lỗ trong ngày (%d lệnh). Dừng EA hôm nay.", InpMaxDailyLosses);
         return;
      }
      
      // Kiểm tra Entry Logic
      ProcessNewBarLogic();
   }
}

//+------------------------------------------------------------------+
//| Check New Bar trên H1                                            |
//+------------------------------------------------------------------+
bool IsNewBar()
{
   datetime currentTime = iTime(_Symbol, PERIOD_H1, 0);
   if(currentTime != lastBarTime)
   {
      lastBarTime = currentTime;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Reset Daily Loss Counter                                         |
//+------------------------------------------------------------------+
void ResetDailyVariables()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.day != lastDay)
   {
      if(lastDay != -1) {
         Print("Ngày mới! Reset bộ đếm số lệnh thua: ", currentDailyLosses, " -> 0");
      }
      currentDailyLosses = 0;
      lastDay = dt.day;
   }
}

//+------------------------------------------------------------------+
//| Xử lý Logic khi có nến mới                                       |
//+------------------------------------------------------------------+
void ProcessNewBarLogic()
{
   // Nếu đang có lệnh thì không vào thêm
   if(PositionsTotal() > 0)
   {
      for(int i = 0; i < PositionsTotal(); i++)
      {
         if(posInfo.SelectByIndex(i) && posInfo.Symbol() == _Symbol && posInfo.Magic() == InpMagicNumber)
         {
            return; // Đã có lệnh của EA
         }
      }
   }

   // Lọc khung giờ giao dịch
   if(!IsInTradingSession()) return;

   // Lọc thanh khoản (Spread)
   double currentSpread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(currentSpread > InpMaxSpread)
   {
      PrintFormat("Bỏ qua tín hiệu: Spread hiện tại (%f) cao hơn Max Spread", currentSpread);
      return;
   }

   // Tính toán giá trị Indicator
   double emaFast[], emaSlow[], emaH4[], adx[], atr[];
   ArraySetAsSeries(emaFast, true);
   ArraySetAsSeries(emaSlow, true);
   ArraySetAsSeries(emaH4, true);
   ArraySetAsSeries(adx, true);
   ArraySetAsSeries(atr, true);

   if(CopyBuffer(hEmaFast, 0, 0, 2, emaFast) <= 0 ||
      CopyBuffer(hEmaSlow, 0, 0, 2, emaSlow) <= 0 ||
      CopyBuffer(hEmaH4,   0, 0, 1, emaH4) <= 0   ||
      CopyBuffer(hAdx,     0, 0, 2, adx) <= 0     ||
      CopyBuffer(hAtr,     0, 0, 2, atr) <= 0) 
   {
      Print("Lỗi lấy dữ liệu Indicator!");
      return;
   }

   // Lấy giá Close, Open, High, Low của nến H1
   double close1 = iClose(_Symbol, PERIOD_H1, 1);
   double open1  = iOpen(_Symbol,  PERIOD_H1, 1);
   double high2  = iHigh(_Symbol,  PERIOD_H1, 2);
   double low2   = iLow(_Symbol,   PERIOD_H1, 2);
   double currentPrice = symInfo.Ask();
   double bidPrice = symInfo.Bid();
   double h4Close = iClose(_Symbol, PERIOD_H4, 0);

   // S3: ADX Filter
   if(adx[1] <= InpAdxThreshold) return; 

   // ========== CHECK MUA ==========
   bool isBuySetup = (h4Close > emaH4[0]) && (emaFast[1] > emaSlow[1]) && (currentPrice > emaFast[1]);
   if(isBuySetup)
   {
      if(close1 > open1 && close1 > high2)
      {
         Print("-> Phát hiện tín hiệu BUY.");
         ExecuteTrade(ORDER_TYPE_BUY, atr[1] * InpSlAtrMulti, atr[1] * InpTpAtrMulti);
         return;
      }
   }

   // ========== CHECK BÁN ==========
   bool isSellSetup = (h4Close < emaH4[0]) && (emaFast[1] < emaSlow[1]) && (bidPrice < emaFast[1]);
   if(isSellSetup)
   {
      if(close1 < open1 && close1 < low2)
      {
         Print("-> Phát hiện tín hiệu SELL.");
         ExecuteTrade(ORDER_TYPE_SELL, atr[1] * InpSlAtrMulti, atr[1] * InpTpAtrMulti);
         return;
      }
   }
}

//+------------------------------------------------------------------+
//| Execute Trade Order với cấu hình Volume                          |
//+------------------------------------------------------------------+
void ExecuteTrade(ENUM_ORDER_TYPE orderType, double slDistAtr, double tpDistAtr)
{
   double entryPrice = (orderType == ORDER_TYPE_BUY) ? symInfo.Ask() : symInfo.Bid();
   long stopLevelPoints = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double stopLevelDist = stopLevelPoints * _Point;
   
   // Distance Calculations
   double finalSlDist = MathMax(slDistAtr, InpMinSLPoints * _Point);
   finalSlDist = MathMax(finalSlDist, stopLevelDist);
   
   double slPrice = (orderType == ORDER_TYPE_BUY) ? entryPrice - finalSlDist : entryPrice + finalSlDist;
   double tpPrice = 0;
   if(tpDistAtr > 0)
   {
       double finalTpDist = MathMax(tpDistAtr, stopLevelDist);
       tpPrice = (orderType == ORDER_TYPE_BUY) ? entryPrice + finalTpDist : entryPrice - finalTpDist;
   }
   
   // Volume Calculation
   double finalVolume = 0;
   if(InpVolumeMode == VOL_FIXED)
   {
      finalVolume = InpFixedLot;
   }
   else
   {
      double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      double lossPoints = finalSlDist / tickSize;
      
      double riskMoney = 0;
      if(InpVolumeMode == VOL_RISK_PERC)
         riskMoney = accInfo.Balance() * (InpRiskPercent / 100.0);
      else if(InpVolumeMode == VOL_RISK_MONEY)
         riskMoney = InpRiskMoney;
         
      double rawVolume = 0;
      if(lossPoints > 0 && tickValue > 0)
          rawVolume = riskMoney / (lossPoints * tickValue);
          
      double stepVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
      if(stepVol > 0)
         finalVolume = MathFloor(rawVolume / stepVol) * stepVol;
   }
   
   // Validate Volume
   double minVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(finalVolume < minVol) 
   {
      PrintFormat("Volume quá nhỏ (%f). Hủy lệnh.", finalVolume);
      return;
   }
   if(finalVolume > maxVol) finalVolume = maxVol;
   
   slPrice = NormalizeDouble(slPrice, symInfo.Digits());
   tpPrice = NormalizeDouble(tpPrice, symInfo.Digits());
   
   if(orderType == ORDER_TYPE_BUY)
   {
      if(trade.Buy(finalVolume, _Symbol, entryPrice, slPrice, tpPrice, "Trend Momentum Rider"))
         Print("Gửi lệnh BUY thành công! Ticket:", trade.ResultOrder());
   }
   else
   {
      if(trade.Sell(finalVolume, _Symbol, entryPrice, slPrice, tpPrice, "Trend Momentum Rider"))
         Print("Gửi lệnh SELL thành công! Ticket:", trade.ResultOrder());
   }
}

//+------------------------------------------------------------------+
//| Quản lý Trailing Stop                                            |
//+------------------------------------------------------------------+
void ManageOpenPositions()
{
   if(!InpUseTrailing || PositionsTotal() == 0) return;

   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(hAtr, 0, 0, 1, atr) <= 0) return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(posInfo.SelectByIndex(i) && posInfo.Symbol() == _Symbol && posInfo.Magic() == InpMagicNumber)
      {
         double currentPrice = posInfo.PriceCurrent();
         double slPrice = posInfo.StopLoss();
         long stopLevelPoints = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
         double stopLevelDist = stopLevelPoints * _Point;
         
         double trailingDist = atr[0] * InpTrailAtrMulti;
         double stepDist     = atr[0] * InpTrailStepMulti;
         
         if(posInfo.PositionType() == POSITION_TYPE_BUY)
         {
            double possibleSl = currentPrice - trailingDist;
            possibleSl = NormalizeDouble(possibleSl, symInfo.Digits());
            
            if((slPrice == 0 || possibleSl > (slPrice + stepDist)) && (currentPrice - possibleSl) > stopLevelDist)
            {
               trade.PositionModify(posInfo.Ticket(), possibleSl, posInfo.TakeProfit());
            }
         }
         else if(posInfo.PositionType() == POSITION_TYPE_SELL)
         {
            double possibleSl = currentPrice + trailingDist;
            possibleSl = NormalizeDouble(possibleSl, symInfo.Digits());
            
            if((slPrice == 0 || possibleSl < (slPrice - stepDist)) && (possibleSl - currentPrice) > stopLevelDist)
            {
               trade.PositionModify(posInfo.Ticket(), possibleSl, posInfo.TakeProfit());
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Bắt sự kiện OnTradeTransaction để đếm số lệnh thua               |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction& trans, const MqlTradeRequest& request, const MqlTradeResult& result)
{
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
   {
      ulong ticket = trans.deal;
      if(HistoryDealSelect(ticket))
      {
         long   magic  = HistoryDealGetInteger(ticket, DEAL_MAGIC);
         string symbol = HistoryDealGetString(ticket, DEAL_SYMBOL);
         long   entry  = HistoryDealGetInteger(ticket, DEAL_ENTRY);
         double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
         
         if(magic == InpMagicNumber && symbol == _Symbol && (entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY))
         {
            if(profit < 0)
            {
               currentDailyLosses++;
               PrintFormat("Cảnh báo: Lệnh vừa đóng bị LỖ. Tổng lệnh thua trong ngày: %d / %d", currentDailyLosses, InpMaxDailyLosses);
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Checks whether current time is within trading sessions           |
//+------------------------------------------------------------------+
bool IsInTradingSession()
{
   datetime timeCurrent = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(timeCurrent, dt);
   int currentMin = dt.hour * 60 + dt.min;
   
   string lPieces[];
   if(StringSplit(InpSessionLondonStart, ':', lPieces) > 0)
   {
      int lStartMin = (int)StringToInteger(lPieces[0]) * 60 + (int)StringToInteger(lPieces[1]);
      StringSplit(InpSessionLondonEnd, ':', lPieces);
      int lEndMin = (int)StringToInteger(lPieces[0]) * 60 + (int)StringToInteger(lPieces[1]);
      if(currentMin >= lStartMin && currentMin <= lEndMin) return true;
   }
   
   string nPieces[];
   if(StringSplit(InpSessionNYStart, ':', nPieces) > 0)
   {
      int nStartMin = (int)StringToInteger(nPieces[0]) * 60 + (int)StringToInteger(nPieces[1]);
      StringSplit(InpSessionNYEnd, ':', nPieces);
      int nEndMin = (int)StringToInteger(nPieces[0]) * 60 + (int)StringToInteger(nPieces[1]);
      if(currentMin >= nStartMin && currentMin <= nEndMin) return true;
   }
   
   return false;
}
