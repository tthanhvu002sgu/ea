//+------------------------------------------------------------------+
//|                                         Range Breakout Rene.mq5  |
//|                                        Range Breakout Strategy   |
//+------------------------------------------------------------------+
#property copyright "Range Breakout Strategy"
#property version   "2.00"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//--- ENUM DEFINITIONS ---

enum ENUM_VOLUME_MODE {
   VOLUME_FIXED,           // Fixed Lots
   RISK_PERCENT,           // Risk % of Balance
   RISK_MONEY,             // Risk Money (USD)
   FIXED_LOTS_PER_MONEY    // Fixed Lots per x Money
};

enum ENUM_TARGET_CALC_MODE {
   TARGET_OFF,             // OFF (No TP)
   TARGET_POINTS,          // Points
   TARGET_RISK_REWARD      // Risk:Reward Ratio
};

enum ENUM_STOP_CALC_MODE {
   STOP_OFF,               // OFF (SL at opposite border)
   STOP_POINTS,            // Points
   STOP_FACTOR,            // Factor (1.0 = opposite border)
   STOP_ACCOUNT_PERCENT    // % of Account Balance
};

//--- INPUT PARAMETERS ---

input group "=== A. General Settings ==="
input ENUM_TIMEFRAMES     InpRangeTimeFrame      = PERIOD_M1;    // Timeframe Range Calculation
input ENUM_VOLUME_MODE    InpVolumeMode          = VOLUME_FIXED; // Trading Volume Mode
input double              InpFixedLots           = 0.01;         // Fixed Lots (for VOLUME_FIXED)
input double              InpLotsPerMoney        = 1000.0;       // Fixed Lots Per x Money (Balance)
input double              InpRiskPercent         = 0.5;          // Risk % of Balance
input double              InpRiskMoney           = 50.0;         // Risk Money (USD)
input int                 InpOrderBuffer         = 0;            // Order Buffer (Points)
input ENUM_TARGET_CALC_MODE InpTargetMode        = TARGET_OFF;   // Take Profit Mode
input double              InpTargetValue         = 100.0;        // TP Value (Points or R:R ratio)
input ENUM_STOP_CALC_MODE InpStopMode            = STOP_FACTOR;  // Stop Loss Mode
input double              InpStopValue           = 1.0;          // SL Value (Points or Factor)
input ulong               InpMagicNumber         = 111;          // Magic Number

input group "=== B. Time Settings (Server Time) ==="
input int                 InpRangeStartHour      = 0;            // Range Start Hour
input int                 InpRangeStartMinute    = 0;            // Range Start Minute
input int                 InpRangeEndHour        = 7;            // Range End Hour
input int                 InpRangeEndMinute      = 30;           // Range End Minute
input int                 InpDeleteOrderHour     = 18;           // Delete Orders Hour
input int                 InpDeleteOrderMinute   = 0;            // Delete Orders Minute
input bool                InpClosePositions      = true;         // Close Positions at End of Day
input int                 InpCloseLongHour       = 18;           // Close Long Positions Hour
input int                 InpCloseLongMinute     = 0;            // Close Long Positions Minute
input int                 InpCloseShortHour      = 18;           // Close Short Positions Hour
input int                 InpCloseShortMinute    = 0;            // Close Short Positions Minute

input group "=== C. Trading Frequency & Filters ==="
input int                 InpMaxLongTrades       = 1;            // Max Long Trades per Day
input int                 InpMaxShortTrades      = 1;            // Max Short Trades per Day
input int                 InpMaxTotalTrades      = 2;            // Max Total Trades per Day
input int                 InpMinRangePoints      = 0;            // Min Range (Points)
input int                 InpMaxRangePoints      = 100000;       // Max Range (Points)
input double              InpMinRangePercent     = 0.0;          // Min Range (% of Price)
input double              InpMaxRangePercent     = 100.0;        // Max Range (% of Price)

//--- GLOBAL VARIABLES ---
CTrade         trade;
CPositionInfo  posInfo;

int            currentDay           = -1;
int            dailyLongTrades      = 0;
int            dailyShortTrades     = 0;
bool           isRangeCalculated    = false;
double         RangeHigh            = 0;
double         RangeLow             = 0;
string         eaStateStr           = "Initializing";

// Performance optimization flags
bool           isTesting            = false;
bool           isOptimization       = false;
bool           isVisualMode         = false;
bool           dayFullyTraded       = false;
bool           closedLongForDay     = false;
bool           closedShortForDay    = false;
bool           deletedForDay        = false;
bool           rangeFilterPassed    = false;
bool           rangeFilterChecked   = false;
bool           pendingOrdersPlaced  = false;

// Pre-computed SL/TP values
double         preSlDistBuy         = 0;
double         preSlDistSell        = 0;
double         preSlBuy             = 0;
double         preSlSell            = 0;
double         preTpBuy             = 0;
double         preTpSell            = 0;
double         preBuyEntry          = 0;
double         preSellEntry         = 0;
bool           slTpPrecomputed      = false;

//+------------------------------------------------------------------+
//| Expert initialization                                             |
//+------------------------------------------------------------------+
int OnInit() {
    isTesting      = (bool)MQLInfoInteger(MQL_TESTER);
    isOptimization = (bool)MQLInfoInteger(MQL_OPTIMIZATION);
    isVisualMode   = (bool)MQLInfoInteger(MQL_VISUAL_MODE);
    
    trade.SetExpertMagicNumber(InpMagicNumber);
    trade.SetDeviationInPoints(10); // Slippage tolerance
    
    // Validate inputs
    if(InpRangeStartHour < 0 || InpRangeStartHour > 23 ||
       InpRangeEndHour < 0   || InpRangeEndHour > 23) {
        Print("ERROR: Invalid Range Hour settings!");
        return(INIT_PARAMETERS_INCORRECT);
    }

    datetime currentTime = TimeCurrent();
    MqlDateTime dt;
    TimeToStruct(currentTime, dt);
    currentDay = dt.day_of_year;

    RecoverState(currentTime, dt);
    
    UpdateDashboard();
    Print("Range Breakout Rene v2.0 initialized successfully!");
    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
    Comment("");
    
    // Clean up range box objects
    for(int i = ObjectsTotal(0) - 1; i >= 0; i--) {
        string name = ObjectName(0, i);
        if(StringFind(name, "RangeBox_") == 0) {
            ObjectDelete(0, name);
        }
    }
}

//+------------------------------------------------------------------+
//| Recover state on restart (crash/power loss)                       |
//+------------------------------------------------------------------+
void RecoverState(datetime currentTime, MqlDateTime &dt) {
    dailyLongTrades  = 0;
    dailyShortTrades = 0;
    isRangeCalculated = false;
    RangeHigh = 0;
    RangeLow  = 0;
    eaStateStr = "Recovering...";

    // 1. Count today's trades from history
    datetime dayStart = currentTime - dt.hour * 3600 - dt.min * 60 - dt.sec;
    HistorySelect(dayStart, currentTime + 86400);
    for(int i = 0; i < HistoryDealsTotal(); i++) {
        ulong ticket = HistoryDealGetTicket(i);
        if(ticket > 0) {
            long   magic  = HistoryDealGetInteger(ticket, DEAL_MAGIC);
            string symbol = HistoryDealGetString(ticket, DEAL_SYMBOL);
            if(magic == (long)InpMagicNumber && symbol == _Symbol) {
                if(HistoryDealGetInteger(ticket, DEAL_ENTRY) == DEAL_ENTRY_IN) {
                    if(HistoryDealGetInteger(ticket, DEAL_TYPE) == DEAL_TYPE_BUY)
                        dailyLongTrades++;
                    else if(HistoryDealGetInteger(ticket, DEAL_TYPE) == DEAL_TYPE_SELL)
                        dailyShortTrades++;
                }
            }
        }
    }

    // Check for open positions
    bool hasOpenTrades = false;
    for(int i = PositionsTotal() - 1; i >= 0; i--) {
        if(posInfo.SelectByIndex(i)) {
            if(posInfo.Magic() == InpMagicNumber && posInfo.Symbol() == _Symbol) {
                hasOpenTrades = true;
            }
        }
    }
    
    // Check for pending orders
    bool hasPendingOrders = false;
    for(int i = OrdersTotal() - 1; i >= 0; i--) {
        ulong ticket = OrderGetTicket(i);
        if(OrderGetString(ORDER_SYMBOL) == _Symbol && OrderGetInteger(ORDER_MAGIC) == (long)InpMagicNumber) {
            hasPendingOrders = true;
        }
    }

    // 2. Recover RangeBox from chart objects
    MqlDateTime startDt = dt;
    startDt.hour = InpRangeStartHour;
    startDt.min  = InpRangeStartMinute;
    startDt.sec  = 0;
    datetime startTime = StructToTime(startDt);
    string objName = "RangeBox_" + TimeToString(startTime, TIME_DATE);
    
    if(ObjectFind(0, objName) >= 0) {
        RangeHigh = ObjectGetDouble(0, objName, OBJPROP_PRICE, 0);
        RangeLow  = ObjectGetDouble(0, objName, OBJPROP_PRICE, 1);
        if(RangeHigh > 0 && RangeLow > 0) {
            isRangeCalculated = true;
            PrecomputeSlTp();
            Print("Recovered RangeBox: High=", RangeHigh, " Low=", RangeLow);
        }
    }
    
    // Update flags
    dayFullyTraded    = (dailyLongTrades + dailyShortTrades >= InpMaxTotalTrades);
    closedLongForDay  = false;
    closedShortForDay = false;
    deletedForDay     = false;
    rangeFilterChecked = false;
    slTpPrecomputed   = false;
    pendingOrdersPlaced = hasPendingOrders;
    
    if(dailyLongTrades > 0 || dailyShortTrades > 0 || hasOpenTrades) {
        eaStateStr = "Traded";
    } else if(isRangeCalculated) {
        eaStateStr = "Waiting Breakout";
    } else {
        eaStateStr = "Waiting for Range";
    }
}

//+------------------------------------------------------------------+
//| Update Dashboard                                                  |
//+------------------------------------------------------------------+
void UpdateDashboard() {
    if(isOptimization) return;
    if(isTesting && !isVisualMode) return;
    
    string txt = "\n=== RANGE BREAKOUT RENE v2.0 ===\n";
    txt += "State: " + eaStateStr + "\n";
    txt += StringFormat("Trades: Long (%d/%d) | Short (%d/%d) | Total (%d/%d)\n",
           dailyLongTrades, InpMaxLongTrades,
           dailyShortTrades, InpMaxShortTrades,
           dailyLongTrades + dailyShortTrades, InpMaxTotalTrades);
    
    if(isRangeCalculated) {
        double rangeSize = RangeHigh - RangeLow;
        double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
        double rangePts = (point > 0) ? rangeSize / point : 0;
        txt += StringFormat("Range High : %.5f\n", RangeHigh);
        txt += StringFormat("Range Low  : %.5f\n", RangeLow);
        txt += StringFormat("Range Size : %.1f Points\n", rangePts);
        
        if(slTpPrecomputed) {
            txt += StringFormat("Buy Entry  : %.5f | SL: %.5f | TP: %.5f\n", preBuyEntry, preSlBuy, preTpBuy);
            txt += StringFormat("Sell Entry : %.5f | SL: %.5f | TP: %.5f\n", preSellEntry, preSlSell, preTpSell);
        }
        
        if(rangeFilterChecked && !rangeFilterPassed) {
            txt += "*** RANGE FILTER: REJECTED ***\n";
        }
    } else {
        txt += "Range: Not calculated yet\n";
    }
    
    Comment(txt);
}

//+------------------------------------------------------------------+
//| Main tick function                                                |
//+------------------------------------------------------------------+
void OnTick() {
    datetime currentTime = TimeCurrent();
    MqlDateTime dt;
    TimeToStruct(currentTime, dt);

    // 1. NEW DAY RESET
    if(dt.day_of_year != currentDay) {
        currentDay         = dt.day_of_year;
        dailyLongTrades    = 0;
        dailyShortTrades   = 0;
        isRangeCalculated  = false;
        RangeHigh          = 0;
        RangeLow           = 0;
        dayFullyTraded     = false;
        closedLongForDay   = false;
        closedShortForDay  = false;
        deletedForDay      = false;
        rangeFilterChecked = false;
        rangeFilterPassed  = false;
        slTpPrecomputed    = false;
        pendingOrdersPlaced = false;
        eaStateStr         = "Waiting for Range";
    }

    // Build time references
    MqlDateTime startDt = dt; startDt.hour = InpRangeStartHour;    startDt.min = InpRangeStartMinute;    startDt.sec = 0;
    MqlDateTime endDt   = dt; endDt.hour   = InpRangeEndHour;      endDt.min   = InpRangeEndMinute;      endDt.sec   = 0;
    MqlDateTime delDt   = dt; delDt.hour   = InpDeleteOrderHour;   delDt.min   = InpDeleteOrderMinute;   delDt.sec   = 0;
    MqlDateTime closLongDt = dt; closLongDt.hour = InpCloseLongHour; closLongDt.min = InpCloseLongMinute; closLongDt.sec = 0;
    MqlDateTime closShortDt = dt; closShortDt.hour = InpCloseShortHour; closShortDt.min = InpCloseShortMinute; closShortDt.sec = 0;

    datetime startTime  = StructToTime(startDt);
    datetime endTime    = StructToTime(endDt);
    datetime deleteTime = StructToTime(delDt);
    datetime closeLongTime  = StructToTime(closLongDt);
    datetime closeShortTime = StructToTime(closShortDt);

    // Update state display
    if(currentTime < endTime) {
        if(eaStateStr != "Traded" && eaStateStr != "Trading Ended")
            eaStateStr = "Waiting for Range";
    } else if(currentTime >= endTime && isRangeCalculated) {
        if(eaStateStr != "Traded" && eaStateStr != "Trading Ended")
            eaStateStr = "Waiting Breakout";
    }

    // 2. DELETE PENDING ORDERS at scheduled time (once per day)
    if(currentTime >= deleteTime && !deletedForDay) {
        DeletePendingOrders();
        deletedForDay = true;
    }

    // 3. CLOSE POSITIONS at scheduled time (once per day)
    if(InpClosePositions) {
        if(currentTime >= closeLongTime && !closedLongForDay) {
            ClosePositionsType(POSITION_TYPE_BUY);
            DeletePendingOrdersType(ORDER_TYPE_BUY_STOP);
            closedLongForDay = true;
        }
        if(currentTime >= closeShortTime && !closedShortForDay) {
            ClosePositionsType(POSITION_TYPE_SELL);
            DeletePendingOrdersType(ORDER_TYPE_SELL_STOP);
            closedShortForDay = true;
        }
        
        if (closedLongForDay && closedShortForDay) {
            eaStateStr = "Trading Ended";
        }
    }

    // 4. CALCULATE RANGE
    if(currentTime >= endTime && !isRangeCalculated) {
        CalculateRange(startTime, endTime);
    }

    // 5. ENTRY CHECK — place pending orders or market orders
    if(isRangeCalculated && currentTime >= endTime && !dayFullyTraded) {
        CheckBreakoutAndTrade();
    }

    UpdateDashboard();
}

//+------------------------------------------------------------------+
//| Calculate Range (High/Low) and draw box                           |
//+------------------------------------------------------------------+
void CalculateRange(datetime startTime, datetime endTime) {
    double high[], low[];
    
    if(CopyHigh(_Symbol, InpRangeTimeFrame, startTime, endTime, high) <= 0 ||
       CopyLow(_Symbol, InpRangeTimeFrame, startTime, endTime, low) <= 0) {
        Print("WARNING: Failed to copy range data.");
        return;
    }

    RangeHigh = high[ArrayMaximum(high)];
    RangeLow  = low[ArrayMinimum(low)];
    isRangeCalculated = true;
    eaStateStr = "Waiting Breakout";

    // Draw range box (skip during optimization / non-visual testing)
    if(!isOptimization && (!isTesting || isVisualMode)) {
        string objName = "RangeBox_" + TimeToString(startTime, TIME_DATE);
        ObjectDelete(0, objName);
        ObjectCreate(0, objName, OBJ_RECTANGLE, 0, startTime, RangeHigh, endTime, RangeLow);
        ObjectSetInteger(0, objName, OBJPROP_COLOR, clrDodgerBlue);
        ObjectSetInteger(0, objName, OBJPROP_FILL, true);
        ObjectSetInteger(0, objName, OBJPROP_BACK, true);
    }
    
    PrecomputeSlTp();
}

//+------------------------------------------------------------------+
//| Pre-compute SL, TP, and Entry levels based on ranges              |
//+------------------------------------------------------------------+
void PrecomputeSlTp() {
    double rangeSize = RangeHigh - RangeLow;
    double point     = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    
    // --- RANGE FILTER ---
    double rangeSizePoints  = (point > 0) ? rangeSize / point : 0;
    double rangeSizePercent = (RangeLow > 0) ? (rangeSize / RangeLow) * 100.0 : 0;
    
    rangeFilterChecked = true;
    if(rangeSizePoints < InpMinRangePoints || rangeSizePoints > InpMaxRangePoints) {
        rangeFilterPassed = false;
        Print("Range REJECTED (Points): ", rangeSizePoints, " not in [", InpMinRangePoints, ", ", InpMaxRangePoints, "]");
        return;
    }
    if(rangeSizePercent < InpMinRangePercent || rangeSizePercent > InpMaxRangePercent) {
        rangeFilterPassed = false;
        Print("Range REJECTED (%): ", rangeSizePercent, " not in [", InpMinRangePercent, ", ", InpMaxRangePercent, "]");
        return;
    }
    rangeFilterPassed = true;
    
    // --- ENTRY LEVELS (with buffer) ---
    double bufferDist = InpOrderBuffer * point;
    preBuyEntry  = NormalizeDouble(RangeHigh + bufferDist, _Digits);
    preSellEntry = NormalizeDouble(RangeLow  - bufferDist, _Digits);
    
    // --- STOP LOSS ---
    switch(InpStopMode) {
        case STOP_OFF:
            // SL at opposite border
            preSlBuy      = RangeLow;
            preSlSell     = RangeHigh;
            preSlDistBuy  = preBuyEntry - RangeLow;
            preSlDistSell = RangeHigh - preSellEntry;
            break;
        case STOP_POINTS:
            preSlDistBuy  = InpStopValue * point;
            preSlDistSell = InpStopValue * point;
            preSlBuy      = NormalizeDouble(preBuyEntry  - preSlDistBuy,  _Digits);
            preSlSell     = NormalizeDouble(preSellEntry + preSlDistSell, _Digits);
            break;
        case STOP_FACTOR:
            // Factor * RangeSize from entry level
            // Factor = 1.0 means SL at opposite border distance
            preSlDistBuy  = rangeSize * InpStopValue;
            preSlDistSell = rangeSize * InpStopValue;
            preSlBuy      = NormalizeDouble(preBuyEntry  - preSlDistBuy,  _Digits);
            preSlSell     = NormalizeDouble(preSellEntry + preSlDistSell, _Digits);
            break;
        case STOP_ACCOUNT_PERCENT: {
            double balance = AccountInfoDouble(ACCOUNT_BALANCE);
            double riskMoney = balance * (InpStopValue / 100.0);
            double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
            double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
            double refLot = InpFixedLots;
            if(tickSize > 0 && tickValue > 0 && refLot > 0) {
                preSlDistBuy  = riskMoney / ((refLot * tickValue) / tickSize);
                preSlDistSell = preSlDistBuy;
            } else {
                preSlDistBuy  = rangeSize;
                preSlDistSell = rangeSize;
            }
            preSlBuy      = NormalizeDouble(preBuyEntry  - preSlDistBuy,  _Digits);
            preSlSell     = NormalizeDouble(preSellEntry + preSlDistSell, _Digits);
            break;
        }
    }
    
    // --- TAKE PROFIT ---
    preTpBuy  = 0;
    preTpSell = 0;
    switch(InpTargetMode) {
        case TARGET_OFF:
            // No TP
            break;
        case TARGET_POINTS:
            preTpBuy  = NormalizeDouble(preBuyEntry  + InpTargetValue * point, _Digits);
            preTpSell = NormalizeDouble(preSellEntry - InpTargetValue * point, _Digits);
            break;
        case TARGET_RISK_REWARD:
            preTpBuy  = NormalizeDouble(preBuyEntry  + preSlDistBuy  * InpTargetValue, _Digits);
            preTpSell = NormalizeDouble(preSellEntry - preSlDistSell * InpTargetValue, _Digits);
            break;
    }
    
    slTpPrecomputed = true;
    
    PrintFormat("Pre-computed: BuyEntry=%.5f SL=%.5f TP=%.5f | SellEntry=%.5f SL=%.5f TP=%.5f",
                preBuyEntry, preSlBuy, preTpBuy, preSellEntry, preSlSell, preTpSell);
}

//+------------------------------------------------------------------+
//| Check for breakout and execute trades                             |
//+------------------------------------------------------------------+
void CheckBreakoutAndTrade() {
    if(dayFullyTraded) return;
    
    // Range filter failed => skip
    if(rangeFilterChecked && !rangeFilterPassed) return;
    
    // SL/TP not ready => skip
    if(!slTpPrecomputed) return;

    // Count open positions of this EA
    bool hasOpenLong  = false;
    bool hasOpenShort = false;
    for(int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if(PositionSelectByTicket(ticket)) {
            if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
               PositionGetInteger(POSITION_MAGIC) == (long)InpMagicNumber) {
                long type = PositionGetInteger(POSITION_TYPE);
                if(type == POSITION_TYPE_BUY)  hasOpenLong  = true;
                if(type == POSITION_TYPE_SELL) hasOpenShort = true;
            }
        }
    }
    
    // Check pending orders already placed
    bool hasPendingBuyStop  = false;
    bool hasPendingSellStop = false;
    for(int i = OrdersTotal() - 1; i >= 0; i--) {
        ulong ticket = OrderGetTicket(i);
        if(OrderGetString(ORDER_SYMBOL) == _Symbol &&
           OrderGetInteger(ORDER_MAGIC) == (long)InpMagicNumber) {
            long orderType = OrderGetInteger(ORDER_TYPE);
            if(orderType == ORDER_TYPE_BUY_STOP)  hasPendingBuyStop  = true;
            if(orderType == ORDER_TYPE_SELL_STOP) hasPendingSellStop = true;
        }
    }

    int totalTrades = dailyLongTrades + dailyShortTrades;
    bool canBuy  = !hasOpenLong  && !hasPendingBuyStop  && (dailyLongTrades  < InpMaxLongTrades)  && (totalTrades < InpMaxTotalTrades) && !closedLongForDay;
    bool canSell = !hasOpenShort && !hasPendingSellStop && (dailyShortTrades < InpMaxShortTrades) && (totalTrades < InpMaxTotalTrades) && !closedShortForDay;
    
    if(!canBuy && !canSell) return;

    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

    // --- BUY LOGIC ---
    if(canBuy) {
        double lotBuy = CalculateLotSize(preSlDistBuy);
        if(lotBuy > 0) {
            if(ask > preBuyEntry) {
                // Price already above entry => Market Order Buy
                if(trade.Buy(lotBuy, _Symbol, ask, preSlBuy, preTpBuy, "RangeBreakout Buy")) {
                    dailyLongTrades++;
                    eaStateStr = "Traded";
                    dayFullyTraded = (dailyLongTrades + dailyShortTrades >= InpMaxTotalTrades);
                    PrintFormat(">> MARKET BUY. Lot: %.2f | Entry: %.5f | SL: %.5f | TP: %.5f",
                               lotBuy, ask, preSlBuy, preTpBuy);
                }
            } else {
                // Price below entry => Place Buy Stop
                if(trade.BuyStop(lotBuy, preBuyEntry, _Symbol, preSlBuy, preTpBuy, ORDER_TIME_DAY, 0, "RangeBreakout BuyStop")) {
                    PrintFormat(">> BUY STOP placed at %.5f | Lot: %.2f | SL: %.5f | TP: %.5f",
                               preBuyEntry, lotBuy, preSlBuy, preTpBuy);
                } else {
                    PrintFormat("WARNING: BuyStop failed. Error: %d", GetLastError());
                }
            }
        }
    }

    // --- SELL LOGIC ---
    if(canSell) {
        double lotSell = CalculateLotSize(preSlDistSell);
        if(lotSell > 0) {
            if(bid < preSellEntry) {
                // Price already below entry => Market Order Sell
                if(trade.Sell(lotSell, _Symbol, bid, preSlSell, preTpSell, "RangeBreakout Sell")) {
                    dailyShortTrades++;
                    eaStateStr = "Traded";
                    dayFullyTraded = (dailyLongTrades + dailyShortTrades >= InpMaxTotalTrades);
                    PrintFormat(">> MARKET SELL. Lot: %.2f | Entry: %.5f | SL: %.5f | TP: %.5f",
                               lotSell, bid, preSlSell, preTpSell);
                }
            } else {
                // Price above entry => Place Sell Stop
                if(trade.SellStop(lotSell, preSellEntry, _Symbol, preSlSell, preTpSell, ORDER_TIME_DAY, 0, "RangeBreakout SellStop")) {
                    PrintFormat(">> SELL STOP placed at %.5f | Lot: %.2f | SL: %.5f | TP: %.5f",
                               preSellEntry, lotSell, preSlSell, preTpSell);
                } else {
                    PrintFormat("WARNING: SellStop failed. Error: %d", GetLastError());
                }
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Calculate lot size based on volume mode                           |
//+------------------------------------------------------------------+
double CalculateLotSize(double slDistance) {
    double lotSize = 0;
    double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    
    switch(InpVolumeMode) {
        case VOLUME_FIXED:
            lotSize = InpFixedLots;
            break;
            
        case RISK_PERCENT: {
            double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
            double riskMoney = balance * (InpRiskPercent / 100.0);
            lotSize = CalcLotFromRisk(riskMoney, slDistance);
            break;
        }
        
        case RISK_MONEY:
            lotSize = CalcLotFromRisk(InpRiskMoney, slDistance);
            break;
            
        case FIXED_LOTS_PER_MONEY: {
            double balance = AccountInfoDouble(ACCOUNT_BALANCE);
            if(InpLotsPerMoney > 0) {
                lotSize = InpFixedLots * MathFloor(balance / InpLotsPerMoney);
            }
            if(lotSize <= 0) lotSize = InpFixedLots; // Minimum 1 unit
            break;
        }
    }
    
    // Normalize to lot step
    if(lotStep > 0)
        lotSize = MathFloor(lotSize / lotStep) * lotStep;
    
    // Clamp to min/max
    if(lotSize < minLot) lotSize = minLot;
    if(lotSize > maxLot) lotSize = maxLot;
    
    return lotSize;
}

//+------------------------------------------------------------------+
//| Helper: Calculate lots from risk money and SL distance            |
//+------------------------------------------------------------------+
double CalcLotFromRisk(double riskMoney, double slDistance) {
    if(slDistance <= 0) return 0;
    
    double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    
    if(tickSize <= 0 || tickValue <= 0) return 0;
    
    double lot = riskMoney / ((slDistance / tickSize) * tickValue);
    return lot;
}

//+------------------------------------------------------------------+
//| Helper to close positions by type (BUY/SELL)                      |
//+------------------------------------------------------------------+
void ClosePositionsType(long posType) {
    for(int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if(PositionSelectByTicket(ticket)) {
            if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
               PositionGetInteger(POSITION_MAGIC) == (long)InpMagicNumber &&
               PositionGetInteger(POSITION_TYPE) == posType) {
                if(!trade.PositionClose(ticket)) {
                    PrintFormat("WARNING: Failed to close position #%d. Error: %d", ticket, GetLastError());
                }
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Helper to delete pending orders by type                           |
//+------------------------------------------------------------------+
void DeletePendingOrdersType(long orderType) {
    for(int i = OrdersTotal() - 1; i >= 0; i--) {
        ulong ticket = OrderGetTicket(i);
        if(OrderGetString(ORDER_SYMBOL) == _Symbol &&
           OrderGetInteger(ORDER_MAGIC) == (long)InpMagicNumber &&
           OrderGetInteger(ORDER_TYPE) == orderType) {
            if(!trade.OrderDelete(ticket)) {
                PrintFormat("WARNING: Failed to delete order #%d. Error: %d", ticket, GetLastError());
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Delete all pending orders of this EA                              |
//+------------------------------------------------------------------+
void DeletePendingOrders() {
    if(OrdersTotal() == 0) return;
    
    for(int i = OrdersTotal() - 1; i >= 0; i--) {
        ulong ticket = OrderGetTicket(i);
        if(OrderGetString(ORDER_SYMBOL) == _Symbol &&
           OrderGetInteger(ORDER_MAGIC) == (long)InpMagicNumber) {
            if(!trade.OrderDelete(ticket)) {
                PrintFormat("WARNING: Failed to delete order #%d. Error: %d", ticket, GetLastError());
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Trade transaction handler — track pending order fills             |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result) {
    // When a pending order is filled, update the daily trade counter
    if(trans.type == TRADE_TRANSACTION_DEAL_ADD) {
        ulong dealTicket = trans.deal;
        if(HistoryDealSelect(dealTicket)) {
            long magic  = HistoryDealGetInteger(dealTicket, DEAL_MAGIC);
            string sym  = HistoryDealGetString(dealTicket, DEAL_SYMBOL);
            long entry  = HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
            long dtype  = HistoryDealGetInteger(dealTicket, DEAL_TYPE);
            
            if(magic == (long)InpMagicNumber && sym == _Symbol && entry == DEAL_ENTRY_IN) {
                if(dtype == DEAL_TYPE_BUY) {
                    // Only count if not already counted (market orders count in CheckBreakoutAndTrade)
                    // For pending order fills, we need to increment here
                    // Check if this was from a pending order (not a direct market order)
                    long orderTicket = (long)HistoryDealGetInteger(dealTicket, DEAL_ORDER);
                    if(orderTicket > 0) {
                        // Re-sync trade count from history to avoid double-counting
                        ResyncTradeCount();
                    }
                } else if(dtype == DEAL_TYPE_SELL) {
                    long orderTicket = (long)HistoryDealGetInteger(dealTicket, DEAL_ORDER);
                    if(orderTicket > 0) {
                        ResyncTradeCount();
                    }
                }
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Re-synchronize daily trade count from history                     |
//+------------------------------------------------------------------+
void ResyncTradeCount() {
    datetime currentTime = TimeCurrent();
    MqlDateTime dt;
    TimeToStruct(currentTime, dt);
    datetime dayStart = currentTime - dt.hour * 3600 - dt.min * 60 - dt.sec;
    
    int longCount  = 0;
    int shortCount = 0;
    
    HistorySelect(dayStart, currentTime + 86400);
    for(int i = 0; i < HistoryDealsTotal(); i++) {
        ulong ticket = HistoryDealGetTicket(i);
        if(ticket > 0) {
            long   magic = HistoryDealGetInteger(ticket, DEAL_MAGIC);
            string sym   = HistoryDealGetString(ticket, DEAL_SYMBOL);
            if(magic == (long)InpMagicNumber && sym == _Symbol) {
                if(HistoryDealGetInteger(ticket, DEAL_ENTRY) == DEAL_ENTRY_IN) {
                    if(HistoryDealGetInteger(ticket, DEAL_TYPE) == DEAL_TYPE_BUY)
                        longCount++;
                    else if(HistoryDealGetInteger(ticket, DEAL_TYPE) == DEAL_TYPE_SELL)
                        shortCount++;
                }
            }
        }
    }
    
    dailyLongTrades  = longCount;
    dailyShortTrades = shortCount;
    dayFullyTraded   = (dailyLongTrades + dailyShortTrades >= InpMaxTotalTrades);
    
    if(dailyLongTrades > 0 || dailyShortTrades > 0)
        eaStateStr = "Traded";
}
//+------------------------------------------------------------------+
