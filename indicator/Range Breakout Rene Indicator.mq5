//+------------------------------------------------------------------+
//|                                Range Breakout Rene Indicator.mq5 |
//|                                        Range Breakout Strategy   |
//+------------------------------------------------------------------+
#property copyright "Converted by Gemini CLI"
#property version   "1.00"
#property indicator_chart_window
#property indicator_buffers 6
#property indicator_plots   6

// Plot 1: Buy Entry
#property indicator_label1  "Buy Entry"
#property indicator_type1   DRAW_ARROW
#property indicator_color1  clrDodgerBlue
#property indicator_width1  2

// Plot 2: Sell Entry
#property indicator_label2  "Sell Entry"
#property indicator_type2   DRAW_ARROW
#property indicator_color2  clrCrimson
#property indicator_width2  2

// Plot 3: Buy Exit
#property indicator_label3  "Buy Exit"
#property indicator_type3   DRAW_ARROW
#property indicator_color3  clrOrange
#property indicator_width3  2

// Plot 4: Sell Exit
#property indicator_label4  "Sell Exit"
#property indicator_type4   DRAW_ARROW
#property indicator_color4  clrMediumOrchid
#property indicator_width4  2

// Plot 5: Buy SL
#property indicator_label5  "Buy SL"
#property indicator_type5   DRAW_ARROW
#property indicator_color5  clrRed
#property indicator_width5  2

// Plot 6: Sell SL
#property indicator_label6  "Sell SL"
#property indicator_type6   DRAW_ARROW
#property indicator_color6  clrRed
#property indicator_width6  2

//--- ENUM DEFINITIONS ---
enum ENUM_VOLUME_MODE {
   VOLUME_FIXED,           
   RISK_PERCENT,           
   RISK_MONEY,             
   FIXED_LOTS_PER_MONEY    
};

enum ENUM_TARGET_CALC_MODE {
   TARGET_OFF,             
   TARGET_POINTS,          
   TARGET_RISK_REWARD      
};

enum ENUM_STOP_CALC_MODE {
   STOP_OFF,               
   STOP_POINTS,            
   STOP_FACTOR,            
   STOP_ACCOUNT_PERCENT    
};

//--- INPUT PARAMETERS ---
input group "=== A. General Settings ==="
input ENUM_TIMEFRAMES     InpRangeTimeFrame      = PERIOD_M1;
input ENUM_VOLUME_MODE    InpVolumeMode          = VOLUME_FIXED;
input double              InpFixedLots           = 0.01;
input double              InpLotsPerMoney        = 1000.0;
input double              InpRiskPercent         = 0.5;
input double              InpRiskMoney           = 50.0;
input int                 InpOrderBuffer         = 0;
input ENUM_TARGET_CALC_MODE InpTargetMode        = TARGET_OFF;
input double              InpTargetValue         = 100.0;
input ENUM_STOP_CALC_MODE InpStopMode            = STOP_FACTOR;
input double              InpStopValue           = 1.0;

input group "=== B. Time Settings (Server Time) ==="
input int                 InpRangeStartHour      = 0;
input int                 InpRangeStartMinute    = 0;
input int                 InpRangeEndHour        = 7;
input int                 InpRangeEndMinute      = 30;
input int                 InpDeleteOrderHour     = 18;
input int                 InpDeleteOrderMinute   = 0;
input bool                InpClosePositions      = true;
input int                 InpCloseLongHour       = 18;
input int                 InpCloseLongMinute     = 0;
input int                 InpCloseShortHour      = 18;
input int                 InpCloseShortMinute    = 0;

input group "=== C. Trading Frequency & Filters ==="
input int                 InpMaxLongTrades       = 1;
input int                 InpMaxShortTrades      = 1;
input int                 InpMaxTotalTrades      = 2;
input int                 InpMinRangePoints      = 0;
input int                 InpMaxRangePoints      = 100000;
input double              InpMinRangePercent     = 0.0;
input double              InpMaxRangePercent     = 100.0;

//--- BUFFERS ---
double EntryBuyBuffer[];
double EntrySellBuffer[];
double ExitBuyBuffer[];
double ExitSellBuffer[];
double SlBuyBuffer[];
double SlSellBuffer[];

//--- STATE STRUCTURE ---
struct STradeState {
    int currentDay;
    bool isRangeCalculated;
    double RangeHigh;
    double RangeLow;
    
    int dailyLongTrades;
    int dailyShortTrades;
    bool closedLongForDay;
    bool closedShortForDay;
    bool deletedForDay;
    bool rangeFilterPassed;
    
    double preBuyEntry;
    double preSellEntry;
    double preSlBuy;
    double preSlSell;
    double preTpBuy;
    double preTpSell;
    
    bool inBuy;
    bool inSell;
    
    datetime rangeStartTime;
    datetime rangeEndTime;
};

STradeState globalState;
STradeState lastClosedBarState;

string g_boxNames[];

//+------------------------------------------------------------------+
//| Custom indicator initialization function                         |
//+------------------------------------------------------------------+
int OnInit()
{
    SetIndexBuffer(0, EntryBuyBuffer, INDICATOR_DATA);
    PlotIndexSetInteger(0, PLOT_ARROW, 232); // Arrow Right
    PlotIndexSetDouble(0, PLOT_EMPTY_VALUE, 0.0);
    
    SetIndexBuffer(1, EntrySellBuffer, INDICATOR_DATA);
    PlotIndexSetInteger(1, PLOT_ARROW, 232); // Arrow Right
    PlotIndexSetDouble(1, PLOT_EMPTY_VALUE, 0.0);
    
    SetIndexBuffer(2, ExitBuyBuffer, INDICATOR_DATA);
    PlotIndexSetInteger(2, PLOT_ARROW, 251); // Cross
    PlotIndexSetDouble(2, PLOT_EMPTY_VALUE, 0.0);
    
    SetIndexBuffer(3, ExitSellBuffer, INDICATOR_DATA);
    PlotIndexSetInteger(3, PLOT_ARROW, 252); // Cross in circle
    PlotIndexSetDouble(3, PLOT_EMPTY_VALUE, 0.0);

    SetIndexBuffer(4, SlBuyBuffer, INDICATOR_DATA);
    PlotIndexSetInteger(4, PLOT_ARROW, 258); // Dash
    PlotIndexSetDouble(4, PLOT_EMPTY_VALUE, 0.0);

    SetIndexBuffer(5, SlSellBuffer, INDICATOR_DATA);
    PlotIndexSetInteger(5, PLOT_ARROW, 258); // Dash
    PlotIndexSetDouble(5, PLOT_EMPTY_VALUE, 0.0);

    ObjectsDeleteAll(0, "RBR_RangeBox_");
    
    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Custom indicator deinitialization function                       |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    ObjectsDeleteAll(0, "RBR_RangeBox_");
}

void DrawRangeBox(datetime start, datetime end, double high, double low) {
    string name = "RBR_RangeBox_" + TimeToString(start, TIME_DATE|TIME_MINUTES);
    if(ObjectFind(0, name) < 0) {
        ObjectCreate(0, name, OBJ_RECTANGLE, 0, start, high, end, low);
        ObjectSetInteger(0, name, OBJPROP_COLOR, clrDodgerBlue);
        ObjectSetInteger(0, name, OBJPROP_FILL, true);
        ObjectSetInteger(0, name, OBJPROP_BACK, true);
        
        int size = ArraySize(g_boxNames);
        ArrayResize(g_boxNames, size + 1);
        g_boxNames[size] = name;
        
        if(ArraySize(g_boxNames) > 10) {
            ObjectDelete(0, g_boxNames[0]);
            ArrayRemove(g_boxNames, 0, 1);
        }
    }
}

void PrecomputeSlTp(STradeState &state) {
    double rangeSize = state.RangeHigh - state.RangeLow;
    double point     = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    
    double rangeSizePoints  = (point > 0) ? rangeSize / point : 0;
    double rangeSizePercent = (state.RangeLow > 0) ? (rangeSize / state.RangeLow) * 100.0 : 0;
    
    if(rangeSizePoints < InpMinRangePoints || rangeSizePoints > InpMaxRangePoints) {
        state.rangeFilterPassed = false;
        return;
    }
    if(rangeSizePercent < InpMinRangePercent || rangeSizePercent > InpMaxRangePercent) {
        state.rangeFilterPassed = false;
        return;
    }
    state.rangeFilterPassed = true;
    
    double bufferDist = InpOrderBuffer * point;
    state.preBuyEntry  = NormalizeDouble(state.RangeHigh + bufferDist, _Digits);
    state.preSellEntry = NormalizeDouble(state.RangeLow  - bufferDist, _Digits);
    
    double preSlDistBuy = 0, preSlDistSell = 0;
    
    switch(InpStopMode) {
        case STOP_OFF:
            state.preSlBuy      = state.RangeLow;
            state.preSlSell     = state.RangeHigh;
            preSlDistBuy  = state.preBuyEntry - state.RangeLow;
            preSlDistSell = state.RangeHigh - state.preSellEntry;
            break;
        case STOP_POINTS:
            preSlDistBuy  = InpStopValue * point;
            preSlDistSell = InpStopValue * point;
            state.preSlBuy      = NormalizeDouble(state.preBuyEntry  - preSlDistBuy,  _Digits);
            state.preSlSell     = NormalizeDouble(state.preSellEntry + preSlDistSell, _Digits);
            break;
        case STOP_FACTOR:
            preSlDistBuy  = rangeSize * InpStopValue;
            preSlDistSell = rangeSize * InpStopValue;
            state.preSlBuy      = NormalizeDouble(state.preBuyEntry  - preSlDistBuy,  _Digits);
            state.preSlSell     = NormalizeDouble(state.preSellEntry + preSlDistSell, _Digits);
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
            state.preSlBuy      = NormalizeDouble(state.preBuyEntry  - preSlDistBuy,  _Digits);
            state.preSlSell     = NormalizeDouble(state.preSellEntry + preSlDistSell, _Digits);
            break;
        }
    }
    
    state.preTpBuy  = 0;
    state.preTpSell = 0;
    switch(InpTargetMode) {
        case TARGET_OFF:
            break;
        case TARGET_POINTS:
            state.preTpBuy  = NormalizeDouble(state.preBuyEntry  + InpTargetValue * point, _Digits);
            state.preTpSell = NormalizeDouble(state.preSellEntry - InpTargetValue * point, _Digits);
            break;
        case TARGET_RISK_REWARD:
            state.preTpBuy  = NormalizeDouble(state.preBuyEntry  + preSlDistBuy  * InpTargetValue, _Digits);
            state.preTpSell = NormalizeDouble(state.preSellEntry - preSlDistSell * InpTargetValue, _Digits);
            break;
    }
}

void ProcessBar(int i, datetime time, double high, double low, double close, STradeState &state) {
    MqlDateTime dt;
    TimeToStruct(time, dt);

    if(dt.day_of_year != state.currentDay) {
        state.currentDay = dt.day_of_year;
        state.dailyLongTrades = 0;
        state.dailyShortTrades = 0;
        state.isRangeCalculated = false;
        state.closedLongForDay = false;
        state.closedShortForDay = false;
        state.deletedForDay = false;
        state.rangeFilterPassed = false;
    }

    MqlDateTime startDt = dt; startDt.hour = InpRangeStartHour; startDt.min = InpRangeStartMinute; startDt.sec = 0;
    MqlDateTime endDt = dt; endDt.hour = InpRangeEndHour; endDt.min = InpRangeEndMinute; endDt.sec = 0;
    MqlDateTime delDt = dt; delDt.hour = InpDeleteOrderHour; delDt.min = InpDeleteOrderMinute; delDt.sec = 0;
    MqlDateTime closLongDt = dt; closLongDt.hour = InpCloseLongHour; closLongDt.min = InpCloseLongMinute; closLongDt.sec = 0;
    MqlDateTime closShortDt = dt; closShortDt.hour = InpCloseShortHour; closShortDt.min = InpCloseShortMinute; closShortDt.sec = 0;

    datetime startTime = StructToTime(startDt);
    datetime endTime = StructToTime(endDt);
    datetime deleteTime = StructToTime(delDt);
    datetime closeLongTime = StructToTime(closLongDt);
    datetime closeShortTime = StructToTime(closShortDt);

    if(endTime <= startTime) startTime -= 86400;
    if(deleteTime < endTime) deleteTime += 86400;
    if(closeLongTime < endTime) closeLongTime += 86400;
    if(closeShortTime < endTime) closeShortTime += 86400;

    if(time >= endTime && !state.isRangeCalculated) {
        double h[], l[];
        if(CopyHigh(_Symbol, InpRangeTimeFrame, startTime, endTime, h) > 0 &&
           CopyLow(_Symbol, InpRangeTimeFrame, startTime, endTime, l) > 0) {
           
           state.RangeHigh = h[ArrayMaximum(h)];
           state.RangeLow = l[ArrayMinimum(l)];
           state.isRangeCalculated = true;
           state.rangeStartTime = startTime;
           state.rangeEndTime = endTime;
           
           PrecomputeSlTp(state);
           
           if(state.rangeFilterPassed) {
               DrawRangeBox(startTime, endTime, state.RangeHigh, state.RangeLow);
           }
        }
    }

    if(time >= deleteTime && !state.deletedForDay) {
        state.deletedForDay = true;
    }

    if(InpClosePositions) {
        if(time >= closeLongTime && !state.closedLongForDay) {
            state.closedLongForDay = true;
            if(state.inBuy) {
                state.inBuy = false;
                ExitBuyBuffer[i] = close; 
            }
        }
        if(time >= closeShortTime && !state.closedShortForDay) {
            state.closedShortForDay = true;
            if(state.inSell) {
                state.inSell = false;
                ExitSellBuffer[i] = close; 
            }
        }
    }

    if(state.isRangeCalculated && state.rangeFilterPassed && !state.deletedForDay) {
        int totalTrades = state.dailyLongTrades + state.dailyShortTrades;
        bool dayFullyTraded = (totalTrades >= InpMaxTotalTrades);
        
        if(!dayFullyTraded) {
            if(!state.inBuy && !state.closedLongForDay && state.dailyLongTrades < InpMaxLongTrades) {
                if(high >= state.preBuyEntry) { 
                    state.inBuy = true;
                    state.dailyLongTrades++;
                    EntryBuyBuffer[i] = state.preBuyEntry;
                    SlBuyBuffer[i] = state.preSlBuy;
                    
                    if(InpMaxTotalTrades == 1) {
                        state.deletedForDay = true; 
                    }
                }
            }
            
            if(!state.inSell && !state.closedShortForDay && state.dailyShortTrades < InpMaxShortTrades) {
                if(low <= state.preSellEntry) {
                    state.inSell = true;
                    state.dailyShortTrades++;
                    EntrySellBuffer[i] = state.preSellEntry;
                    SlSellBuffer[i] = state.preSlSell;
                    
                    if(InpMaxTotalTrades == 1) {
                        state.deletedForDay = true; 
                    }
                }
            }
        }
    }

    if(state.inBuy) {
        bool hitSL = (low <= state.preSlBuy);
        bool hitTP = (InpTargetMode != TARGET_OFF && high >= state.preTpBuy);
        
        if(hitSL || hitTP) {
            state.inBuy = false;
            ExitBuyBuffer[i] = hitSL ? state.preSlBuy : state.preTpBuy;
        }
    }
    
    if(state.inSell) {
        bool hitSL = (high >= state.preSlSell);
        bool hitTP = (InpTargetMode != TARGET_OFF && low <= state.preTpSell);
        
        if(hitSL || hitTP) {
            state.inSell = false;
            ExitSellBuffer[i] = hitSL ? state.preSlSell : state.preTpSell;
        }
    }
}

//+------------------------------------------------------------------+
//| Custom indicator iteration function                              |
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
    ArraySetAsSeries(time, false);
    ArraySetAsSeries(high, false);
    ArraySetAsSeries(low, false);
    ArraySetAsSeries(close, false);
    
    int start_index = 0;
    if(prev_calculated == 0) {
        start_index = 0;
        
        ZeroMemory(globalState);
        globalState.currentDay = -1;
        
        ObjectsDeleteAll(0, "RBR_RangeBox_");
        ArrayResize(g_boxNames, 0);
        
        ArrayInitialize(EntryBuyBuffer, 0.0);
        ArrayInitialize(EntrySellBuffer, 0.0);
        ArrayInitialize(ExitBuyBuffer, 0.0);
        ArrayInitialize(ExitSellBuffer, 0.0);
        ArrayInitialize(SlBuyBuffer, 0.0);
        ArrayInitialize(SlSellBuffer, 0.0);
    } else {
        start_index = prev_calculated - 1;
        globalState = lastClosedBarState; 
        
        EntryBuyBuffer[start_index] = 0.0;
        EntrySellBuffer[start_index] = 0.0;
        ExitBuyBuffer[start_index] = 0.0;
        ExitSellBuffer[start_index] = 0.0;
        SlBuyBuffer[start_index] = 0.0;
        SlSellBuffer[start_index] = 0.0;
    }
    
    for(int i = start_index; i < rates_total; i++) {
        bool isLastBar = (i == rates_total - 1);
        
        ProcessBar(i, time[i], high[i], low[i], close[i], globalState);
        
        if(!isLastBar) {
            lastClosedBarState = globalState;
        }
    }
    
    return(rates_total);
}
//+------------------------------------------------------------------+