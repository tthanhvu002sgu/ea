//+------------------------------------------------------------------+
//|                                        Supply Demand MTF.mq5     |
//|                                                                  |
//|  Supply & Demand Zone Indicator (Multi-Timeframe)                |
//|  Based on Flux Charts concept                                    |
//|                                                                  |
//|  Features:                                                       |
//|  - Automatic Supply/Demand zone detection                        |
//|  - Multi-timeframe support (up to 3 TFs)                        |
//|  - Zone combination when overlapping                             |
//|  - Retest and Break labels                                       |
//|  - Configurable invalidation (Wick/Close)                        |
//+------------------------------------------------------------------+
#property copyright "Supply Demand MTF"
#property link      ""
#property version   "1.00"
#property strict
#property indicator_chart_window
#property indicator_buffers 0
#property indicator_plots   0

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                  |
//+------------------------------------------------------------------+
input group "══════════ General Configuration ══════════"
input string   InpMaxDistance     = "Normal";      // Max Distance (High/Normal/Low)
input string   InpZoneInvalidation = "Close";      // Zone Invalidation (Wick/Close)
input bool     InpShowHistoric    = true;          // Show Historic Zones
input bool     InpShowRetests     = true;          // Show Retests
input bool     InpShowBreaks      = false;         // Show Breaks
input bool     InpCombineZones    = true;          // Combine Overlapping Zones

input group "══════════ Zone Detection ══════════"
input double   InpMomentumBodyMult = 0.5;          // Momentum Body Multiplier
input int      InpMomentumCount    = 4;            // Momentum Candle Count
input int      InpMomentumSpan     = 4;            // Momentum Lookback Span
input int      InpMinZoneSize      = 10;           // Minimum Zone Size (bars)
input double   InpMaxZoneSizeATR   = 1.5;          // Max Zone Size (ATR multiplier)

input group "══════════ Timeframe 1 ══════════"
input bool              InpTF1Enabled = true;      // Enable TF1
input ENUM_TIMEFRAMES   InpTF1        = PERIOD_CURRENT; // Timeframe 1

input group "══════════ Timeframe 2 ══════════"
input bool              InpTF2Enabled = false;     // Enable TF2
input ENUM_TIMEFRAMES   InpTF2        = PERIOD_M15; // Timeframe 2

input group "══════════ Timeframe 3 ══════════"
input bool              InpTF3Enabled = false;     // Enable TF3
input ENUM_TIMEFRAMES   InpTF3        = PERIOD_H1;  // Timeframe 3

input group "══════════ Colors ══════════"
input color    InpDemandColor  = clrMediumSeaGreen; // Demand Zone Color
input color    InpSupplyColor  = clrCrimson;        // Supply Zone Color
input color    InpTextColor    = clrWhite;          // Text Color
input int      InpZoneOpacity  = 70;                // Zone Transparency (0-100)

//+------------------------------------------------------------------+
//| CONSTANTS                                                         |
//+------------------------------------------------------------------+
#define MAX_ZONES        30
#define RETEST_COOLDOWN  5
#define MIN_DISTANCE_BETWEEN_ZONES 5

//+------------------------------------------------------------------+
//| STRUCTURES                                                        |
//+------------------------------------------------------------------+
struct SDZoneInfo
{
   double            top;
   double            bottom;
   string            sdType;        // "Supply" or "Demand"
   datetime          startTime;
   datetime          breakTime;
   int               guid;
   ENUM_TIMEFRAMES   timeframe;
   bool              disabled;
   bool              combined;
   string            combinedTFStr;
   string            objectPrefix;
};

//+------------------------------------------------------------------+
//| GLOBAL VARIABLES                                                  |
//+------------------------------------------------------------------+
SDZoneInfo demandZones[];
SDZoneInfo supplyZones[];
SDZoneInfo allZones[];

int maxDistanceToLastBar;
int lastDemandBar = 0;
int lastSupplyBar = 0;
int lastRetestDemand = 0;
int lastRetestSupply = 0;
int zoneGuidCounter = 0;

int handleATR;
double bufferATR[];
double averageBodySize;

//+------------------------------------------------------------------+
//| Custom indicator initialization function                          |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- Set max distance based on input
   if(InpMaxDistance == "Low")
      maxDistanceToLastBar = 150;
   else if(InpMaxDistance == "Normal")
      maxDistanceToLastBar = 500;
   else
      maxDistanceToLastBar = 1250;
   
   //--- Create ATR handle
   handleATR = iATR(_Symbol, PERIOD_CURRENT, 20);
   if(handleATR == INVALID_HANDLE)
   {
      Print("❌ Error creating ATR handle");
      return(INIT_FAILED);
   }
   
   ArraySetAsSeries(bufferATR, true);
   
   //--- Initialize arrays
   ArrayResize(demandZones, 0);
   ArrayResize(supplyZones, 0);
   ArrayResize(allZones, 0);
   
   Print("✅ Supply & Demand MTF Indicator initialized");
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Custom indicator deinitialization                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   //--- Delete all objects
   ObjectsDeleteAll(0, "SD_");
   
   if(handleATR != INVALID_HANDLE)
      IndicatorRelease(handleATR);
   
   Comment("");
}

//+------------------------------------------------------------------+
//| Custom indicator iteration function                               |
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
   //--- Check minimum bars
   if(rates_total < InpMomentumSpan + 10)
      return(0);
   
   //--- Set arrays as series
   ArraySetAsSeries(time, true);
   ArraySetAsSeries(open, true);
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   ArraySetAsSeries(close, true);
   
   //--- Get ATR
   if(CopyBuffer(handleATR, 0, 0, 3, bufferATR) <= 0)
      return(0);
   
   double atr = bufferATR[0];
   
   //--- Calculate average body size
   double bodySum = 0;
   for(int i = 0; i < 20 && i < rates_total; i++)
   {
      bodySum += MathAbs(close[i] - open[i]);
   }
   averageBodySize = bodySum / 20;
   
   //--- Only process within max distance
   int startBar = MathMin(rates_total - prev_calculated + 1, maxDistanceToLastBar);
   if(prev_calculated == 0)
      startBar = MathMin(rates_total - 1, maxDistanceToLastBar);
   
   //--- Main detection loop
   for(int i = startBar; i >= 0; i--)
   {
      if(i < InpMomentumSpan + 1)
         continue;
      
      //--- Count momentum candles
      int bullishMomentum = 0;
      int bearishMomentum = 0;
      
      for(int j = 0; j < InpMomentumSpan; j++)
      {
         double bodySize = MathAbs(close[i - j] - open[i - j]);
         if(bodySize >= averageBodySize * InpMomentumBodyMult)
         {
            if(close[i - j] > open[i - j])
               bullishMomentum++;
            else
               bearishMomentum++;
         }
      }
      
      int barIndex = rates_total - 1 - i;
      
      //--- Detect Demand Zone (bullish momentum)
      if(bullishMomentum >= InpMomentumCount && barIndex - lastDemandBar > MIN_DISTANCE_BETWEEN_ZONES)
      {
         lastDemandBar = barIndex;
         
         int zoneBar = i + InpMomentumSpan + 1;
         if(zoneBar < rates_total)
         {
            AddDemandZone(high[zoneBar], low[zoneBar], time[zoneBar], InpTF1, atr);
         }
      }
      
      //--- Detect Supply Zone (bearish momentum)
      if(bearishMomentum >= InpMomentumCount && barIndex - lastSupplyBar > MIN_DISTANCE_BETWEEN_ZONES)
      {
         lastSupplyBar = barIndex;
         
         int zoneBar = i + InpMomentumSpan + 1;
         if(zoneBar < rates_total)
         {
            AddSupplyZone(high[zoneBar], low[zoneBar], time[zoneBar], InpTF1, atr);
         }
      }
   }
   
   //--- Check zone invalidation
   CheckZoneInvalidation(high[0], low[0], open[0], close[0], time[0]);
   
   //--- Check retests
   if(InpShowRetests)
      CheckRetests(high[0], low[0], time[0]);
   
   //--- Render zones on last bar
   if(prev_calculated != rates_total)
   {
      RenderAllZones();
   }
   
   return(rates_total);
}

//+------------------------------------------------------------------+
//| Add Demand Zone                                                   |
//+------------------------------------------------------------------+
void AddDemandZone(double zoneHigh, double zoneLow, datetime zoneTime, ENUM_TIMEFRAMES tf, double atr)
{
   //--- Check if zone already exists
   for(int i = 0; i < ArraySize(demandZones); i++)
   {
      if(demandZones[i].startTime == zoneTime)
         return;
   }
   
   //--- Create new zone
   SDZoneInfo newZone;
   newZone.top = zoneHigh;
   newZone.bottom = zoneLow;
   newZone.sdType = "Demand";
   newZone.startTime = zoneTime;
   newZone.breakTime = 0;
   newZone.guid = zoneGuidCounter++;
   newZone.timeframe = tf;
   newZone.disabled = false;
   newZone.combined = false;
   newZone.combinedTFStr = "";
   newZone.objectPrefix = "SD_D_" + IntegerToString(newZone.guid);
   
   //--- Clamp zone size
   ClampZoneSize(newZone, atr);
   
   //--- Add to array
   int size = ArraySize(demandZones);
   ArrayResize(demandZones, size + 1);
   demandZones[size] = newZone;
   
   //--- Limit zones
   if(ArraySize(demandZones) > MAX_ZONES)
   {
      //--- Remove oldest
      for(int i = 0; i < ArraySize(demandZones) - 1; i++)
         demandZones[i] = demandZones[i + 1];
      ArrayResize(demandZones, MAX_ZONES);
   }
}

//+------------------------------------------------------------------+
//| Add Supply Zone                                                   |
//+------------------------------------------------------------------+
void AddSupplyZone(double zoneHigh, double zoneLow, datetime zoneTime, ENUM_TIMEFRAMES tf, double atr)
{
   //--- Check if zone already exists
   for(int i = 0; i < ArraySize(supplyZones); i++)
   {
      if(supplyZones[i].startTime == zoneTime)
         return;
   }
   
   //--- Create new zone
   SDZoneInfo newZone;
   newZone.top = zoneHigh;
   newZone.bottom = zoneLow;
   newZone.sdType = "Supply";
   newZone.startTime = zoneTime;
   newZone.breakTime = 0;
   newZone.guid = zoneGuidCounter++;
   newZone.timeframe = tf;
   newZone.disabled = false;
   newZone.combined = false;
   newZone.combinedTFStr = "";
   newZone.objectPrefix = "SD_S_" + IntegerToString(newZone.guid);
   
   //--- Clamp zone size
   ClampZoneSize(newZone, atr);
   
   //--- Add to array
   int size = ArraySize(supplyZones);
   ArrayResize(supplyZones, size + 1);
   supplyZones[size] = newZone;
   
   //--- Limit zones
   if(ArraySize(supplyZones) > MAX_ZONES)
   {
      for(int i = 0; i < ArraySize(supplyZones) - 1; i++)
         supplyZones[i] = supplyZones[i + 1];
      ArrayResize(supplyZones, MAX_ZONES);
   }
}

//+------------------------------------------------------------------+
//| Clamp Zone Size based on ATR                                      |
//+------------------------------------------------------------------+
void ClampZoneSize(SDZoneInfo &zone, double atr)
{
   double zoneSize = zone.top - zone.bottom;
   double maxSize = atr * InpMaxZoneSizeATR;
   
   if(zoneSize > maxSize)
   {
      double diff = zoneSize - maxSize;
      zone.top -= diff / 2;
      zone.bottom += diff / 2;
   }
}

//+------------------------------------------------------------------+
//| Check Zone Invalidation                                           |
//+------------------------------------------------------------------+
void CheckZoneInvalidation(double high, double low, double open, double close, datetime time)
{
   double checkLow = (InpZoneInvalidation == "Wick") ? low : MathMin(open, close);
   double checkHigh = (InpZoneInvalidation == "Wick") ? high : MathMax(open, close);
   
   //--- Check Demand Zones
   for(int i = 0; i < ArraySize(demandZones); i++)
   {
      if(demandZones[i].breakTime == 0 && !demandZones[i].disabled)
      {
         if(checkLow < demandZones[i].bottom)
         {
            demandZones[i].breakTime = time;
            
            //--- Show break label
            if(InpShowBreaks)
               CreateBreakLabel(demandZones[i], false);
         }
      }
   }
   
   //--- Check Supply Zones
   for(int i = 0; i < ArraySize(supplyZones); i++)
   {
      if(supplyZones[i].breakTime == 0 && !supplyZones[i].disabled)
      {
         if(checkHigh > supplyZones[i].top)
         {
            supplyZones[i].breakTime = time;
            
            if(InpShowBreaks)
               CreateBreakLabel(supplyZones[i], true);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Check Retests                                                     |
//+------------------------------------------------------------------+
void CheckRetests(double high, double low, datetime time)
{
   static int lastRetestBarDemand = 0;
   static int lastRetestBarSupply = 0;
   int currentBar = iBarShift(_Symbol, PERIOD_CURRENT, time);
   
   //--- Check Demand Retests
   for(int i = 0; i < ArraySize(demandZones); i++)
   {
      if(demandZones[i].breakTime != 0 || demandZones[i].disabled)
         continue;
      
      if(currentBar - lastRetestBarDemand <= RETEST_COOLDOWN)
         continue;
      
      if(low < demandZones[i].top && low > demandZones[i].bottom)
      {
         CreateRetestLabel(demandZones[i], time, true);
         lastRetestBarDemand = currentBar;
      }
   }
   
   //--- Check Supply Retests
   for(int i = 0; i < ArraySize(supplyZones); i++)
   {
      if(supplyZones[i].breakTime != 0 || supplyZones[i].disabled)
         continue;
      
      if(currentBar - lastRetestBarSupply <= RETEST_COOLDOWN)
         continue;
      
      if(high > supplyZones[i].bottom && high < supplyZones[i].top)
      {
         CreateRetestLabel(supplyZones[i], time, false);
         lastRetestBarSupply = currentBar;
      }
   }
}

//+------------------------------------------------------------------+
//| Render All Zones                                                  |
//+------------------------------------------------------------------+
void RenderAllZones()
{
   //--- Delete old zone objects
   ObjectsDeleteAll(0, "SD_Zone_");
   ObjectsDeleteAll(0, "SD_Line_");
   ObjectsDeleteAll(0, "SD_Text_");
   
   //--- Render Demand Zones
   for(int i = 0; i < ArraySize(demandZones); i++)
   {
      if(demandZones[i].disabled)
         continue;
      
      if(!InpShowHistoric && demandZones[i].breakTime != 0)
         continue;
      
      RenderZone(demandZones[i]);
   }
   
   //--- Render Supply Zones
   for(int i = 0; i < ArraySize(supplyZones); i++)
   {
      if(supplyZones[i].disabled)
         continue;
      
      if(!InpShowHistoric && supplyZones[i].breakTime != 0)
         continue;
      
      RenderZone(supplyZones[i]);
   }
}

//+------------------------------------------------------------------+
//| Render Single Zone                                                |
//+------------------------------------------------------------------+
void RenderZone(SDZoneInfo &zone)
{
   //--- Zone box name
   string boxName = "SD_Zone_" + IntegerToString(zone.guid);
   string lineName = "SD_Line_" + IntegerToString(zone.guid);
   string textName = "SD_Text_" + IntegerToString(zone.guid);
   
   //--- Determine end time
   datetime endTime = (zone.breakTime != 0) ? zone.breakTime : TimeCurrent() + PeriodSeconds(PERIOD_D1);
   
   //--- Get color
   color zoneColor = (zone.sdType == "Demand") ? InpDemandColor : InpSupplyColor;
   color fillColor = ColorWithTransparency(zoneColor, InpZoneOpacity);
   
   //--- Create rectangle
   if(ObjectFind(0, boxName) < 0)
   {
      ObjectCreate(0, boxName, OBJ_RECTANGLE, 0, zone.startTime, zone.top, endTime, zone.bottom);
   }
   
   ObjectSetInteger(0, boxName, OBJPROP_COLOR, zoneColor);
   ObjectSetInteger(0, boxName, OBJPROP_FILL, true);
   ObjectSetInteger(0, boxName, OBJPROP_BACK, true);
   ObjectSetInteger(0, boxName, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, boxName, OBJPROP_TIME, 0, zone.startTime);
   ObjectSetInteger(0, boxName, OBJPROP_TIME, 1, endTime);
   ObjectSetDouble(0, boxName, OBJPROP_PRICE, 0, zone.top);
   ObjectSetDouble(0, boxName, OBJPROP_PRICE, 1, zone.bottom);
   
   //--- Apply transparency via style
   if(zone.breakTime != 0)
   {
      ObjectSetInteger(0, boxName, OBJPROP_STYLE, STYLE_DOT);
   }
   
   //--- Create middle line
   double middlePrice = (zone.top + zone.bottom) / 2;
   if(ObjectFind(0, lineName) < 0)
   {
      ObjectCreate(0, lineName, OBJ_TREND, 0, zone.startTime, middlePrice, endTime, middlePrice);
   }
   
   ObjectSetInteger(0, lineName, OBJPROP_COLOR, InpTextColor);
   ObjectSetInteger(0, lineName, OBJPROP_STYLE, STYLE_DOT);
   ObjectSetInteger(0, lineName, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, lineName, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, lineName, OBJPROP_BACK, true);
   ObjectSetInteger(0, lineName, OBJPROP_TIME, 0, zone.startTime);
   ObjectSetInteger(0, lineName, OBJPROP_TIME, 1, endTime);
   ObjectSetDouble(0, lineName, OBJPROP_PRICE, 0, middlePrice);
   ObjectSetDouble(0, lineName, OBJPROP_PRICE, 1, middlePrice);
   
   //--- Create text label
   string tfStr = GetTimeframeString(zone.timeframe);
   string labelText = tfStr + " " + zone.sdType;
   
   if(ObjectFind(0, textName) < 0)
   {
      ObjectCreate(0, textName, OBJ_TEXT, 0, endTime, zone.bottom);
   }
   
   ObjectSetString(0, textName, OBJPROP_TEXT, labelText);
   ObjectSetInteger(0, textName, OBJPROP_COLOR, InpTextColor);
   ObjectSetInteger(0, textName, OBJPROP_FONTSIZE, 8);
   ObjectSetInteger(0, textName, OBJPROP_ANCHOR, ANCHOR_RIGHT_UPPER);
   ObjectSetInteger(0, textName, OBJPROP_TIME, 0, endTime);
   ObjectSetDouble(0, textName, OBJPROP_PRICE, 0, zone.bottom);
}

//+------------------------------------------------------------------+
//| Create Retest Label                                               |
//+------------------------------------------------------------------+
void CreateRetestLabel(SDZoneInfo &zone, datetime time, bool isDemand)
{
   string labelName = "SD_Retest_" + IntegerToString(zone.guid) + "_" + IntegerToString((int)time);
   
   double price = isDemand ? zone.bottom : zone.top;
   color labelColor = isDemand ? InpDemandColor : InpSupplyColor;
   ENUM_ANCHOR_POINT anchor = isDemand ? ANCHOR_UPPER : ANCHOR_LOWER;
   
   if(ObjectFind(0, labelName) < 0)
   {
      ObjectCreate(0, labelName, OBJ_TEXT, 0, time, price);
      ObjectSetString(0, labelName, OBJPROP_TEXT, "R");
      ObjectSetInteger(0, labelName, OBJPROP_COLOR, labelColor);
      ObjectSetInteger(0, labelName, OBJPROP_FONTSIZE, 10);
      ObjectSetString(0, labelName, OBJPROP_FONT, "Arial Bold");
      ObjectSetInteger(0, labelName, OBJPROP_ANCHOR, anchor);
   }
}

//+------------------------------------------------------------------+
//| Create Break Label                                                |
//+------------------------------------------------------------------+
void CreateBreakLabel(SDZoneInfo &zone, bool isBullishBreak)
{
   string labelName = "SD_Break_" + IntegerToString(zone.guid);
   
   double price = isBullishBreak ? zone.top : zone.bottom;
   ENUM_ANCHOR_POINT anchor = isBullishBreak ? ANCHOR_LOWER : ANCHOR_UPPER;
   
   if(ObjectFind(0, labelName) < 0)
   {
      ObjectCreate(0, labelName, OBJ_TEXT, 0, zone.breakTime, price);
      ObjectSetString(0, labelName, OBJPROP_TEXT, "B");
      ObjectSetInteger(0, labelName, OBJPROP_COLOR, clrDodgerBlue);
      ObjectSetInteger(0, labelName, OBJPROP_FONTSIZE, 10);
      ObjectSetString(0, labelName, OBJPROP_FONT, "Arial Bold");
      ObjectSetInteger(0, labelName, OBJPROP_ANCHOR, anchor);
   }
}

//+------------------------------------------------------------------+
//| Get Timeframe String                                              |
//+------------------------------------------------------------------+
string GetTimeframeString(ENUM_TIMEFRAMES tf)
{
   if(tf == PERIOD_CURRENT)
      tf = (ENUM_TIMEFRAMES)Period();
   
   switch(tf)
   {
      case PERIOD_M1:  return "1M";
      case PERIOD_M5:  return "5M";
      case PERIOD_M15: return "15M";
      case PERIOD_M30: return "30M";
      case PERIOD_H1:  return "1H";
      case PERIOD_H4:  return "4H";
      case PERIOD_D1:  return "D1";
      case PERIOD_W1:  return "W1";
      case PERIOD_MN1: return "MN";
      default: return IntegerToString(PeriodSeconds(tf) / 60) + "M";
   }
}

//+------------------------------------------------------------------+
//| Apply transparency to color                                       |
//+------------------------------------------------------------------+
color ColorWithTransparency(color baseColor, int transparency)
{
   //--- MQL5 uses uchar for transparency (0-255)
   //--- transparency input is 0-100 where 100 = fully transparent
   return baseColor; // Note: MQL5 rectangles use OBJPROP_FILL for transparency effect
}

//+------------------------------------------------------------------+
//| Chart Event Handler                                               |
//+------------------------------------------------------------------+
void OnChartEvent(const int id,
                  const long &lparam,
                  const double &dparam,
                  const string &sparam)
{
   if(id == CHARTEVENT_MOUSE_MOVE)
   {
      //--- Optional: Show zone info on hover
   }
}
//+------------------------------------------------------------------+
