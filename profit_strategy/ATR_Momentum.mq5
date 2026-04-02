//+------------------------------------------------------------------+
//|                                             ATR_Momentum_Pro.mq5 |
//|                                        Bản quyền: Đối tác lập trình|
//+------------------------------------------------------------------+
#property copyright "Đối tác lập trình"
#property version   "1.00"

#include <Trade\Trade.mqh>

//--- INPUT PARAMETERS ---
input group "=== 1. Strategy Settings ==="
input ENUM_TIMEFRAMES InpTimeframe      = PERIOD_H1;     // Flexible Timeframe
input int             InpAtrPeriod      = 14;            // ATR Period (y)
input double          InpAtrMultiplier  = 2.0;           // ATR Multiplier (x)
input double          InpCloseProximity = 20.0;          // Max Close Distance from Top/Bottom (%)

input group "=== 2. Risk & Trade Management ==="
input double          InpRiskMoney      = 100.0;         // Fixed Risk per Trade (in Account Currency)
input double          InpStopLossPct    = 1.0;           // Stop Loss (% of Entry Price)
input double          InpTakeProfitPct  = 2.0;           // Take Profit (% of Entry Price)
input ulong           InpMagicNumber    = 999888;        // Magic Number

//--- GLOBAL VARIABLES ---
CTrade         trade;
int            atr_handle;
datetime       last_bar_time = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit() {
    // Set Magic Number for trade management
    trade.SetExpertMagicNumber(InpMagicNumber);
    
    // Initialize the ATR indicator on the user-defined timeframe
    atr_handle = iATR(_Symbol, InpTimeframe, InpAtrPeriod);
    if(atr_handle == INVALID_HANDLE) {
        Print("Error initializing ATR indicator.");
        return(INIT_FAILED);
    }
    
    Print("ATR Momentum EA initialized successfully.");
    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
    // Release the indicator handle to free up memory
    IndicatorRelease(atr_handle);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick() {
    // 1. EFFICIENCY CHECK: Only execute logic when a new bar forms on the chosen timeframe.
    datetime current_bar_time = (datetime)SeriesInfoInteger(_Symbol, InpTimeframe, SERIES_LASTBAR_DATE);
    if(current_bar_time == last_bar_time) return; 

    // 2. FETCH DATA: Get the completed candle (Index 1) and its ATR value
    MqlRates rates[];
    double atr[];
    
    // Copy exactly 1 element starting from index 1 (the just-closed candle)
    if(CopyRates(_Symbol, InpTimeframe, 1, 1, rates) != 1) return;
    if(CopyBuffer(atr_handle, 0, 1, 1, atr) != 1) return;
    
    double candle_high  = rates[0].high;
    double candle_low   = rates[0].low;
    double candle_close = rates[0].close;
    double candle_open  = rates[0].open;
    
    double candle_size  = candle_high - candle_low;
    double atr_value    = atr[0];
    
    // 3. STRATEGY LOGIC: Check if candle size is larger than x times ATR
    if(candle_size > (InpAtrMultiplier * atr_value)) {
        
        // Calculate the threshold for the close proximity to top/bottom
        double proximity_threshold = candle_size * (InpCloseProximity / 100.0);
        
        // --- BUY SIGNAL ---
        // Bullish candle AND Close is within the top Z% of the candle
        if(candle_close > candle_open && (candle_high - candle_close) <= proximity_threshold) {
            ExecuteTrade(ORDER_TYPE_BUY);
        }
        
        // --- SELL SIGNAL ---
        // Bearish candle AND Close is within the bottom Z% of the candle
        else if(candle_close < candle_open && (candle_close - candle_low) <= proximity_threshold) {
            ExecuteTrade(ORDER_TYPE_SELL);
        }
    }
    
    // Update the bar time only after successful processing
    last_bar_time = current_bar_time;
}

//+------------------------------------------------------------------+
//| Function to calculate lot size and execute the trade             |
//+------------------------------------------------------------------+
void ExecuteTrade(ENUM_ORDER_TYPE type) {
    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    
    double entry_price = (type == ORDER_TYPE_BUY) ? ask : bid;
    
    // Calculate SL and TP distances based on percentage of Entry Price
    double sl_distance = entry_price * (InpStopLossPct / 100.0);
    double tp_distance = entry_price * (InpTakeProfitPct / 100.0);
    
    double sl_price = (type == ORDER_TYPE_BUY) ? entry_price - sl_distance : entry_price + sl_distance;
    double tp_price = (type == ORDER_TYPE_BUY) ? entry_price + tp_distance : entry_price - tp_distance;
    
    // Calculate Lot Size based on Fixed Risk Money
    double lot_size = CalculateLotSize(sl_distance);
    
    if(lot_size <= 0) {
        Print("Trade aborted: Calculated Lot Size violates symbol restrictions or risk is too low.");
        return;
    }
    
    // Execute
    if(type == ORDER_TYPE_BUY) {
        trade.Buy(lot_size, _Symbol, entry_price, sl_price, tp_price, "ATR Momentum Buy");
        PrintFormat("Executed BUY -> Lot: %.2f, Entry: %f, SL: %f, TP: %f", lot_size, entry_price, sl_price, tp_price);
    } else {
        trade.Sell(lot_size, _Symbol, entry_price, sl_price, tp_price, "ATR Momentum Sell");
        PrintFormat("Executed SELL -> Lot: %.2f, Entry: %f, SL: %f, TP: %f", lot_size, entry_price, sl_price, tp_price);
    }
}

//+------------------------------------------------------------------+
//| Function to calculate exact lot size for Fixed Money Risk        |
//+------------------------------------------------------------------+
double CalculateLotSize(double sl_distance_price) {
    double tick_size  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double volume_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    
    if(tick_size == 0 || tick_value == 0 || sl_distance_price == 0) return 0;
    
    // How much money we lose if 1 Lot hits the SL
    double loss_per_lot = (sl_distance_price / tick_size) * tick_value;
    
    // Calculate raw lot size
    double raw_lot = InpRiskMoney / loss_per_lot;
    
    // Normalize to broker's volume step requirements
    double final_lot = MathFloor(raw_lot / volume_step) * volume_step;
    
    double min_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double max_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    
    // Strict risk management: if the calculated lot is smaller than the minimum allowed,
    // we return 0 to prevent risking MORE than the user specified.
    if(final_lot < min_lot) {
        PrintFormat("Warning: Required lot (%.2f) is smaller than broker minimum (%.2f).", final_lot, min_lot);
        return 0; 
    }
    if(final_lot > max_lot) final_lot = max_lot;
    
    return final_lot;
}