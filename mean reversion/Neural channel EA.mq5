//+------------------------------------------------------------------+
//|                                            Neural_Channel_EA.mq5 |
//|                                           AlgoPoint Conversion   |
//+------------------------------------------------------------------+
#property copyright "AlgoPoint / Converted to EA"
#property link      ""
#property version   "1.00"

#include <Trade\Trade.mqh>
CTrade trade;

//--- input parameters
input string   group_ml      = "--- Machine Learning Core ---";
input int      InpLength     = 24;      // Lookback Window
input double   InpHParam     = 8.0;     // Smoothness (Bandwidth)
input double   InpRParam     = 2.0;     // Regression Alpha

input string   group_stats   = "--- Channel Width (Volatility) ---";
input double   InpMultOuter  = 2.5;     // Outer Channel Multiplier

input string   group_trade   = "--- Trading Settings ---";
input double   InpLots       = 0.1;     // Trade Volume (Lots)
input double   InpStopLoss   = 50.0;    // Stop Loss (pips, 0 = disabled)
input double   InpTakeProfit = 100.0;   // Take Profit (pips, 0 = disabled)
input ulong    InpMagicNum   = 123456;  // Magic Number

double w_array[]; // Precomputed weights
bool weights_calculated = false;
double pip_size; // Store true pip value

//+------------------------------------------------------------------+
//| Precompute weights                                               |
//+------------------------------------------------------------------+
void PrecomputeWeights()
{
    ArrayResize(w_array, InpLength);
    for(int i = 0; i < InpLength; i++)
    {
        double d = MathPow(i, 2);
        w_array[i] = MathPow(1.0 + d / (2.0 * InpRParam * MathPow(InpHParam, 2)), -InpRParam);
    }
    weights_calculated = true;
}

//+------------------------------------------------------------------+
//| RMA True Range (Matches Pine Script ta.atr)                      |
//+------------------------------------------------------------------+
double GetATR_RMA(string symbol, ENUM_TIMEFRAMES period, int length, int shift)
{
    int lookback = 250 + length * 10; 
    MqlRates rates[];
    ArraySetAsSeries(rates, true);
    if(CopyRates(symbol, period, shift, lookback + length, rates) <= 0) return 0.0;
    
    int oldest_idx = lookback + length - 1;
    
    double sum = 0;
    for(int i = oldest_idx; i > oldest_idx - length; i--)
    {
        double current_tr = rates[i].high - rates[i].low;
        if (i < oldest_idx) 
        { 
            double tr1 = MathAbs(rates[i].high - rates[i+1].close);
            double tr2 = MathAbs(rates[i].low - rates[i+1].close);
            current_tr = MathMax(current_tr, MathMax(tr1, tr2));
        }
        sum += current_tr;
    }
    double rma = sum / length;
    
    double alpha = 1.0 / length;
    for(int i = oldest_idx - length; i >= 0; i--)
    {
        double current_tr = rates[i].high - rates[i].low;
        double tr1 = MathAbs(rates[i].high - rates[i+1].close);
        double tr2 = MathAbs(rates[i].low - rates[i+1].close);
        current_tr = MathMax(current_tr, MathMax(tr1, tr2));
        
        rma = alpha * current_tr + (1.0 - alpha) * rma;
    }
    return rma;
}

//+------------------------------------------------------------------+
//| Calculate Neural Channel outputs                                 |
//+------------------------------------------------------------------+
void CalculateNeuralChannel(string symbol, ENUM_TIMEFRAMES period, int shift, double &y_hat, double &lower_outer, double &upper_outer)
{
    if(!weights_calculated) PrecomputeWeights();
    
    MqlRates rates[];
    ArraySetAsSeries(rates, true);
    if (CopyRates(symbol, period, shift, InpLength, rates) <= 0) return;
    
    double numerator = 0.0;
    double denominator = 0.0;
    
    for(int i = 0; i < InpLength; i++)
    {
        double src = (rates[i].high + rates[i].low + rates[i].close) / 3.0; // HLC3
        numerator += src * w_array[i];
        denominator += w_array[i];
    }
    
    y_hat = denominator != 0.0 ? numerator / denominator : 0.0;
    
    double error_sum = 0.0;
    for(int i = 0; i < InpLength; i++)
    {
        double src = (rates[i].high + rates[i].low + rates[i].close) / 3.0;
        error_sum += MathAbs(src - y_hat);
    }
    
    double mean_deviation = error_sum / InpLength;
    double atr = GetATR_RMA(symbol, period, InpLength, shift);
    double volatility = (mean_deviation + atr) / 2.0;
    
    upper_outer = y_hat + (volatility * InpMultOuter);
    lower_outer = y_hat - (volatility * InpMultOuter);
}

//+------------------------------------------------------------------+
//| Check for New Bar                                                |
//+------------------------------------------------------------------+
bool IsNewBar()
{
    static datetime last_time = 0;
    datetime current_time = iTime(Symbol(), Period(), 0);
    if (current_time != last_time)
    {
        if (last_time == 0) // First run Initialization safeguard
        {
            last_time = current_time;
            return false;
        }
        last_time = current_time;
        return true;
    }
    return false;
}

//+------------------------------------------------------------------+
//| Position Management helpers                                      |
//+------------------------------------------------------------------+
bool HasPosition(ENUM_POSITION_TYPE pos_type)
{
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(PositionGetString(POSITION_SYMBOL) == Symbol() && PositionGetInteger(POSITION_MAGIC) == InpMagicNum)
        {
            if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == pos_type) return true;
        }
    }
    return false;
}

void ClosePositions(ENUM_POSITION_TYPE pos_type)
{
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(PositionGetString(POSITION_SYMBOL) == Symbol() && PositionGetInteger(POSITION_MAGIC) == InpMagicNum)
        {
            if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == pos_type)
            {
                trade.PositionClose(ticket);
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    trade.SetExpertMagicNumber(InpMagicNum);
    int digits = (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS);
    pip_size = Point();
    if(digits == 3 || digits == 5) pip_size *= 10.0;
    
    PrecomputeWeights();
    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
    if (!IsNewBar()) return; // Execute only on the close of a bar
    
    double y_hat_1, lower_outer_1, upper_outer_1;
    CalculateNeuralChannel(Symbol(), Period(), 1, y_hat_1, lower_outer_1, upper_outer_1);
    
    double y_hat_2, lower_outer_2, upper_outer_2;
    CalculateNeuralChannel(Symbol(), Period(), 2, y_hat_2, lower_outer_2, upper_outer_2);
    
    double close_1 = iClose(Symbol(), Period(), 1);
    double close_2 = iClose(Symbol(), Period(), 2);
    
    // Pine Script logic checks crossover for signal triggering 
    bool long_cond = (close_2 <= lower_outer_2 && close_1 > lower_outer_1);
    bool short_cond = (close_2 >= upper_outer_2 && close_1 < upper_outer_1);
    
    if (long_cond)
    {
        if (!HasPosition(POSITION_TYPE_BUY))
        {
            double sl = InpStopLoss > 0 ? SymbolInfoDouble(Symbol(), SYMBOL_ASK) - InpStopLoss * pip_size : 0;
            double tp = InpTakeProfit > 0 ? SymbolInfoDouble(Symbol(), SYMBOL_ASK) + InpTakeProfit * pip_size : 0;
            trade.Buy(InpLots, Symbol(), 0, sl, tp, "Neural Channel long");
        }
    }
    else if (short_cond)
    {
        if (!HasPosition(POSITION_TYPE_SELL))
        {
            double sl = InpStopLoss > 0 ? SymbolInfoDouble(Symbol(), SYMBOL_BID) + InpStopLoss * pip_size : 0;
            double tp = InpTakeProfit > 0 ? SymbolInfoDouble(Symbol(), SYMBOL_BID) - InpTakeProfit * pip_size : 0;
            trade.Sell(InpLots, Symbol(), 0, sl, tp, "Neural Channel short");
        }
    }
}
//+------------------------------------------------------------------+
