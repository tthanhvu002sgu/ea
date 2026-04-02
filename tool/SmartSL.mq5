//+------------------------------------------------------------------+
//|                                              SmartSL.mq5         |
//|                          Multi-Factor Optimal StopLoss Tool      |
//|                                                                  |
//|  Scoring System:                                                 |
//|  - Structure (swing depth)         : 0-35 pts                    |
//|  - ATR Distance (noise filter)     : 0-25 pts                    |
//|  - Volume Backing                  : 0-20 pts                    |
//|  - Recency                         : 0-10 pts                    |
//|  - MTF Confluence                  : +10 bonus                   |
//|  - Round Number Trap               : -15 penalty                 |
//|                                                                  |
//|  Modes: Real SL / Virtual SL / Hybrid (Virtual + Safety Real)    |
//+------------------------------------------------------------------+
#property copyright "Smart StopLoss Tool"
#property link      ""
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

CTrade trade;

//+------------------------------------------------------------------+
//| ENUMS                                                            |
//+------------------------------------------------------------------+
enum ENUM_SL_MODE
  {
   MODE_REAL    = 0,   // Real SL Only
   MODE_VIRTUAL = 1,   // Virtual SL Only
   MODE_HYBRID  = 2    // Virtual SL + Safety Real SL
  };

//+------------------------------------------------------------------+
//| INPUTS                                                           |
//+------------------------------------------------------------------+
input string         sep0             = "═══ Mode ═══";                  // ─── Mode ───
input ENUM_SL_MODE   InpMode          = MODE_HYBRID;                     // SL Mode
input bool           InpAutoApply     = true;                            // Auto-apply SL on new positions
input bool           InpAutoTrail     = true;                            // Auto-trail SL when in profit

input string         sep1             = "═══ Scoring Parameters ═══";    // ─── Scoring ───
input int            InpATRPeriod     = 14;                              // ATR Period
input double         InpATRMultiplier = 1.5;                             // ATR Multiplier (min distance)
input int            InpSwingLookback = 100;                             // Swing Lookback (bars)
input int            InpSwingStrength = 5;                               // Swing Strength (bars each side)
input int            InpRoundNumBuffer= 30;                              // Round Number Buffer (points)
input ENUM_TIMEFRAMES InpMTFPeriod    = PERIOD_H1;                       // MTF Confluence Timeframe
input int            InpMTFSwingStr   = 10;                              // MTF Swing Strength

input string         sep2             = "═══ Virtual SL ═══";            // ─── Virtual SL ───
input int            InpSafetyOffset  = 200;                             // Safety SL Offset (points beyond Virtual)
input int            InpAntiSpikeSec  = 2;                               // Anti-Spike Wait (seconds)

input string         sep3             = "═══ Risk Limits ═══";           // ─── Risk ───
input double         InpMaxSLUSD      = 5.0;                             // Max SL Loss (USD, 0=disabled)
input double         InpMinSLPoints   = 50;                              // Min SL Distance (points)

input string         sep4             = "═══ Trailing ═══";              // ─── Trail ───
input double         InpTrailATRMult  = 1.0;                             // Trail ATR Multiplier
input int            InpTrailStep     = 10;                              // Trail Step (points, avoid micro-moves)

input string         sep5             = "═══ Visual ═══";                 // ─── Visual ───
input int            InpPanelX        = 20;                              // Panel X
input int            InpPanelY        = 50;                              // Panel Y
input color          InpBullColor     = clrDodgerBlue;                   // Buy SL Color
input color          InpBearColor     = clrOrangeRed;                    // Sell SL Color

//+------------------------------------------------------------------+
//| STRUCTURES                                                       |
//+------------------------------------------------------------------+
struct SwingPoint
  {
   double            price;          // Swing price level
   int               barIndex;       // Bar index (0 = current)
   double            depth;          // How prominent the swing is
   double            volumeAtSwing;  // Volume on the swing bar
   bool              isHigh;         // true = swing high, false = swing low
  };

struct SLCandidate
  {
   double            price;          // Proposed SL price
   double            structureScore; // 0-35
   double            atrScore;       // 0-25
   double            volumeScore;    // 0-20
   double            recencyScore;   // 0-10
   double            mtfBonus;       // 0 or +10
   double            roundPenalty;   // 0 or -15
   double            totalScore;     // Sum of all
   int               barIndex;       // Source bar
  };

struct VirtualSLInfo
  {
   ulong             ticket;         // Position ticket
   double            virtualSL;      // Virtual SL price
   double            safetySL;       // Real safety SL price (for hybrid)
   datetime          spikeStartTime; // When spike detection started
   bool              spikeActive;    // Is anti-spike watching?
   double            entryPrice;     // Position entry price
   int               posType;        // POSITION_TYPE_BUY or SELL
  };

//+------------------------------------------------------------------+
//| GLOBALS                                                          |
//+------------------------------------------------------------------+
string Prefix = "SmartSL_";
VirtualSLInfo g_virtualSLs[];
int           g_virtualCount = 0;
datetime      g_lastCalcTime = 0;
double        g_lastOptimalSL = 0;
double        g_lastScore     = 0;
int           g_candidateCount = 0;

// Panel objects
string ObjPanel, ObjTitle;
string ObjLabels[], ObjValues[];

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
  {
   ObjPanel = Prefix + "Panel";
   ObjTitle = Prefix + "Title";

   CreatePanel();
   EventSetMillisecondTimer(500); // Check virtual SL every 500ms

   Print("Smart StopLoss Tool initialized. Mode: ",
         InpMode == MODE_REAL ? "Real" : InpMode == MODE_VIRTUAL ? "Virtual" : "Hybrid");

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   ObjectsDeleteAll(0, Prefix);
   EventKillTimer();
   // Remove SL lines
   ObjectDelete(0, Prefix + "VirtualSL_Line");
   ObjectDelete(0, Prefix + "SafetySL_Line");
   ObjectDelete(0, Prefix + "OptimalSL_Line");
   ChartRedraw();
  }

//+------------------------------------------------------------------+
//| Timer — Virtual SL monitoring                                    |
//+------------------------------------------------------------------+
void OnTimer()
  {
   if(InpMode == MODE_REAL)
      return;

   MonitorVirtualSLs();
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   // Auto-apply on new positions
   if(InpAutoApply)
      CheckAndApplyNewPositions();

   // Auto-trail
   if(InpAutoTrail)
      TrailStopLosses();

   // Update panel every new bar
   static datetime lastBar = 0;
   datetime currentBar = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(currentBar != lastBar)
     {
      lastBar = currentBar;
      RecalculateAndDisplay();
     }
  }

//+------------------------------------------------------------------+
//| Chart Event — Button clicks                                      |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
  {
   if(id == CHARTEVENT_OBJECT_CLICK)
     {
      if(sparam == Prefix + "BtnRecalc")
        {
         ObjectSetInteger(0, Prefix + "BtnRecalc", OBJPROP_STATE, false);
         RecalculateAndDisplay();
         ChartRedraw();
        }
      else if(sparam == Prefix + "BtnApply")
        {
         ObjectSetInteger(0, Prefix + "BtnApply", OBJPROP_STATE, false);
         ApplySLToAllPositions();
         ChartRedraw();
        }
     }
  }

//+------------------------------------------------------------------+
//| SWING POINT DETECTION                                            |
//+------------------------------------------------------------------+
int FindSwingPoints(SwingPoint &points[], int lookback, int strength,
                    ENUM_TIMEFRAMES tf = PERIOD_CURRENT)
  {
   ArrayResize(points, 0);
   int count = 0;

   // Need enough bars
   int barsAvail = iBars(_Symbol, tf);
   if(barsAvail < lookback + strength)
      lookback = barsAvail - strength - 1;

   if(lookback < strength * 2)
      return 0;

   for(int i = strength; i < lookback - strength; i++)
     {
      double hi = iHigh(_Symbol, tf, i);
      double lo = iLow(_Symbol, tf, i);
      long   vol = iVolume(_Symbol, tf, i);

      // Check swing high
      bool isSwingHigh = true;
      for(int j = 1; j <= strength; j++)
        {
         if(iHigh(_Symbol, tf, i - j) >= hi || iHigh(_Symbol, tf, i + j) >= hi)
           {
            isSwingHigh = false;
            break;
           }
        }

      // Check swing low
      bool isSwingLow = true;
      for(int j = 1; j <= strength; j++)
        {
         if(iLow(_Symbol, tf, i - j) <= lo || iLow(_Symbol, tf, i + j) <= lo)
           {
            isSwingLow = false;
            break;
           }
        }

      if(isSwingHigh)
        {
         count++;
         ArrayResize(points, count);
         SwingPoint sp;
         sp.price = hi;
         sp.barIndex = i;
         sp.volumeAtSwing = (double)vol;
         sp.isHigh = true;

         // Depth = how much higher than neighbors
         double avgNeighbor = 0;
         for(int j = 1; j <= strength; j++)
            avgNeighbor += (iHigh(_Symbol, tf, i - j) + iHigh(_Symbol, tf, i + j));
         avgNeighbor /= (strength * 2);
         sp.depth = hi - avgNeighbor;

         points[count - 1] = sp;
        }

      if(isSwingLow)
        {
         count++;
         ArrayResize(points, count);
         SwingPoint sp;
         sp.price = lo;
         sp.barIndex = i;
         sp.volumeAtSwing = (double)vol;
         sp.isHigh = false;

         // Depth = how much lower than neighbors
         double avgNeighbor = 0;
         for(int j = 1; j <= strength; j++)
            avgNeighbor += (iLow(_Symbol, tf, i - j) + iLow(_Symbol, tf, i + j));
         avgNeighbor /= (strength * 2);
         sp.depth = avgNeighbor - lo;

         points[count - 1] = sp;
        }
     }

   return count;
  }

//+------------------------------------------------------------------+
//| SCORE A SINGLE SL CANDIDATE                                      |
//+------------------------------------------------------------------+
SLCandidate ScoreCandidate(double slPrice, double entryPrice,
                           int posType, SwingPoint &swing,
                           double atr, double avgVolume, int lookback,
                           SwingPoint &mtfSwings[], int mtfCount)
  {
   SLCandidate cand;
   cand.price = slPrice;
   cand.barIndex = swing.barIndex;

   // ──── 1. Structure Score (0-35) ────
   // Depth normalized by ATR
   double depthRatio = (atr > 0) ? swing.depth / atr : 0;
   cand.structureScore = MathMin(depthRatio * 35.0, 35.0);

   // ──── 2. ATR Distance Score (0-25) ────
   double distance = MathAbs(slPrice - entryPrice);
   double minRequired = atr * InpATRMultiplier;

   if(distance < minRequired * 0.8)
      cand.atrScore = 0; // Too close — disqualified
   else if(distance < minRequired)
      cand.atrScore = 10.0;
   else if(distance < minRequired * 1.5)
      cand.atrScore = 20.0;
   else if(distance < minRequired * 2.0)
      cand.atrScore = 25.0;
   else if(distance < minRequired * 3.0)
      cand.atrScore = 20.0; // A bit too far
   else
      cand.atrScore = 12.0; // Way too far — diminishing returns

   // ──── 3. Volume Backing (0-20) ────
   double relVol = (avgVolume > 0) ? swing.volumeAtSwing / avgVolume : 0;
   if(relVol < 0.5)
      cand.volumeScore = 0;
   else if(relVol < 1.0)
      cand.volumeScore = relVol * 10.0;
   else if(relVol < 2.0)
      cand.volumeScore = 10.0 + (relVol - 1.0) * 10.0;
   else
      cand.volumeScore = 20.0;

   // ──── 4. Recency (0-10) ────
   double recency = 1.0 - ((double)swing.barIndex / (double)lookback);
   cand.recencyScore = MathMax(recency * 10.0, 0);

   // ──── 5. MTF Confluence (+10) ────
   cand.mtfBonus = 0;
   double confluenceThreshold = atr * 0.5; // Within half ATR
   for(int i = 0; i < mtfCount; i++)
     {
      // For BUY SL, check MTF swing lows; for SELL SL, check MTF swing highs
      bool relevant = (posType == POSITION_TYPE_BUY && !mtfSwings[i].isHigh) ||
                      (posType == POSITION_TYPE_SELL && mtfSwings[i].isHigh);
      if(relevant && MathAbs(mtfSwings[i].price - slPrice) < confluenceThreshold)
        {
         cand.mtfBonus = 10.0;
         break;
        }
     }

   // ──── 6. Round Number Penalty (-15) ────
   cand.roundPenalty = 0;
   double bufferPrice = InpRoundNumBuffer * _Point;
   double priceCheck = slPrice;

   // Check proximity to round numbers (00, 50 for gold, 000 for forex)
   double roundLevels[];
   int rlCount = GetNearbyRoundLevels(priceCheck, roundLevels);
   for(int i = 0; i < rlCount; i++)
     {
      if(MathAbs(priceCheck - roundLevels[i]) < bufferPrice)
        {
         cand.roundPenalty = -15.0;
         break;
        }
     }

   // ──── Total Score ────
   cand.totalScore = cand.structureScore + cand.atrScore + cand.volumeScore +
                     cand.recencyScore + cand.mtfBonus + cand.roundPenalty;

   // Clamp
   if(cand.totalScore < 0)
      cand.totalScore = 0;

   return cand;
  }

//+------------------------------------------------------------------+
//| GET NEARBY ROUND LEVELS                                          |
//+------------------------------------------------------------------+
int GetNearbyRoundLevels(double price, double &levels[])
  {
   ArrayResize(levels, 0);
   int count = 0;

   // Determine round level granularity based on symbol
   double granularity[];
   int gCount = 0;

   // For gold-like (2-3 digits): check 00, 50 levels
   // For forex (4-5 digits): check 000, 500 levels
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   if(digits <= 3)
     {
      // Gold, indices: round to 10, 50, 100
      ArrayResize(granularity, 3);
      granularity[0] = 10.0;
      granularity[1] = 50.0;
      granularity[2] = 100.0;
      gCount = 3;
     }
   else
     {
      // Forex: round to 0.001, 0.005, 0.01
      ArrayResize(granularity, 3);
      granularity[0] = 0.001;
      granularity[1] = 0.005;
      granularity[2] = 0.01;
      gCount = 3;
     }

   for(int g = 0; g < gCount; g++)
     {
      double nearest = MathRound(price / granularity[g]) * granularity[g];
      // Add nearest and neighbors
      for(int offset = -1; offset <= 1; offset++)
        {
         double lvl = nearest + offset * granularity[g];
         // Check for duplicates
         bool exists = false;
         for(int i = 0; i < count; i++)
           {
            if(MathAbs(levels[i] - lvl) < _Point)
              { exists = true; break; }
           }
         if(!exists)
           {
            count++;
            ArrayResize(levels, count);
            levels[count - 1] = lvl;
           }
        }
     }

   return count;
  }

//+------------------------------------------------------------------+
//| CALCULATE OPTIMAL SL FOR A POSITION                              |
//+------------------------------------------------------------------+
double CalculateOptimalSL(double entryPrice, int posType,
                          double &outScore, int &outCandidates)
  {
   outScore = 0;
   outCandidates = 0;

   // Get ATR
   double atr = 0;
   int atrHandle = iATR(_Symbol, PERIOD_CURRENT, InpATRPeriod);
   if(atrHandle != INVALID_HANDLE)
     {
      double atrBuf[];
      ArraySetAsSeries(atrBuf, true);
      CopyBuffer(atrHandle, 0, 0, 1, atrBuf);
      atr = atrBuf[0];
      IndicatorRelease(atrHandle);
     }

   if(atr <= 0)
     {
      Print("ATR calculation failed");
      return 0;
     }

   // Get average volume
   double avgVolume = 0;
   for(int i = 0; i < 20; i++)
      avgVolume += (double)iVolume(_Symbol, PERIOD_CURRENT, i);
   avgVolume /= 20.0;

   // Find swing points on current TF
   SwingPoint swings[];
   int swingCount = FindSwingPoints(swings, InpSwingLookback, InpSwingStrength);

   // Find swing points on MTF
   SwingPoint mtfSwings[];
   int mtfCount = FindSwingPoints(mtfSwings, 50, InpMTFSwingStr, InpMTFPeriod);

   // Score each relevant swing point as SL candidate
   SLCandidate candidates[];
   int candCount = 0;

   for(int i = 0; i < swingCount; i++)
     {
      // For BUY: SL below entry → use swing lows
      // For SELL: SL above entry → use swing highs
      if(posType == POSITION_TYPE_BUY && swings[i].isHigh)
         continue;
      if(posType == POSITION_TYPE_SELL && !swings[i].isHigh)
         continue;

      double slPrice = swings[i].price;

      // Add buffer beyond the swing (a few points past it)
      double buffer = atr * 0.05; // 5% of ATR beyond swing
      if(posType == POSITION_TYPE_BUY)
         slPrice -= buffer; // SL below swing low
      else
         slPrice += buffer; // SL above swing high

      // Basic validity check
      if(posType == POSITION_TYPE_BUY && slPrice >= entryPrice)
         continue;
      if(posType == POSITION_TYPE_SELL && slPrice <= entryPrice)
         continue;

      // Score it
      SLCandidate cand = ScoreCandidate(slPrice, entryPrice, posType,
                                        swings[i], atr, avgVolume,
                                        InpSwingLookback,
                                        mtfSwings, mtfCount);

      candCount++;
      ArrayResize(candidates, candCount);
      candidates[candCount - 1] = cand;
     }

   outCandidates = candCount;

   // If no candidates found, use ATR fallback
   if(candCount == 0)
     {
      double fallbackSL;
      if(posType == POSITION_TYPE_BUY)
         fallbackSL = entryPrice - atr * InpATRMultiplier;
      else
         fallbackSL = entryPrice + atr * InpATRMultiplier;

      outScore = 30.0; // Decent but not great (no structure)
      return NormalizeDouble(fallbackSL, _Digits);
     }

   // Select highest scoring candidate
   int bestIdx = 0;
   double bestScore = candidates[0].totalScore;
   for(int i = 1; i < candCount; i++)
     {
      if(candidates[i].totalScore > bestScore)
        {
         bestScore = candidates[i].totalScore;
         bestIdx = i;
        }
     }

   // Apply max SL limit (USD)
   double finalSL = candidates[bestIdx].price;
   if(InpMaxSLUSD > 0)
     {
      double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      if(tickValue > 0 && tickSize > 0)
        {
         // Find min lot among positions
         double minLot = 1.0;
         for(int i = PositionsTotal() - 1; i >= 0; i--)
           {
            ulong ticket = PositionGetTicket(i);
            if(PositionGetString(POSITION_SYMBOL) == _Symbol)
              {
               double vol = PositionGetDouble(POSITION_VOLUME);
               if(vol < minLot) minLot = vol;
              }
           }

         double maxDistPoints = (InpMaxSLUSD / (minLot * tickValue / tickSize)) / _Point;
         double maxDist = maxDistPoints * _Point;
         double currentDist = MathAbs(finalSL - entryPrice);
         if(currentDist > maxDist)
           {
            if(posType == POSITION_TYPE_BUY)
               finalSL = entryPrice - maxDist;
            else
               finalSL = entryPrice + maxDist;
           }
        }
     }

   // Apply min SL distance
   double minDist = InpMinSLPoints * _Point;
   double curDist = MathAbs(finalSL - entryPrice);
   if(curDist < minDist)
     {
      if(posType == POSITION_TYPE_BUY)
         finalSL = entryPrice - minDist;
      else
         finalSL = entryPrice + minDist;
     }

   outScore = bestScore;
   return NormalizeDouble(finalSL, _Digits);
  }

//+------------------------------------------------------------------+
//| APPLY SL TO ALL POSITIONS ON THIS SYMBOL                         |
//+------------------------------------------------------------------+
void ApplySLToAllPositions()
  {
   int applied = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      double entry = PositionGetDouble(POSITION_PRICE_OPEN);
      int posType  = (int)PositionGetInteger(POSITION_TYPE);
      double tp    = PositionGetDouble(POSITION_TP);

      double score = 0;
      int candCount = 0;
      double optimalSL = CalculateOptimalSL(entry, posType, score, candCount);

      if(optimalSL <= 0)
        {
         Print("Could not calculate SL for ticket #", ticket);
         continue;
        }

      if(InpMode == MODE_REAL)
        {
         // Set real SL directly
         if(trade.PositionModify(ticket, optimalSL, tp))
           {
            Print("✓ Real SL set to ", optimalSL, " (Score: ", DoubleToString(score, 1),
                  ") for #", ticket);
            applied++;
           }
         else
            Print("✗ Failed to modify #", ticket, ": ", GetLastError());
        }
      else
        {
         // Virtual SL (or Hybrid)
         RegisterVirtualSL(ticket, optimalSL, entry, posType);

         // Hybrid: also set a safety real SL further away
         if(InpMode == MODE_HYBRID)
           {
            double safetySL;
            if(posType == POSITION_TYPE_BUY)
               safetySL = optimalSL - InpSafetyOffset * _Point;
            else
               safetySL = optimalSL + InpSafetyOffset * _Point;

            safetySL = NormalizeDouble(safetySL, _Digits);
            trade.PositionModify(ticket, safetySL, tp);

            // Update safety SL in virtual tracking
            for(int v = 0; v < g_virtualCount; v++)
              {
               if(g_virtualSLs[v].ticket == ticket)
                 {
                  g_virtualSLs[v].safetySL = safetySL;
                  break;
                 }
              }

            Print("✓ Hybrid SL: Virtual=", optimalSL, " Safety=", safetySL,
                  " (Score: ", DoubleToString(score, 1), ") for #", ticket);
           }
         else
           {
            Print("✓ Virtual SL set to ", optimalSL,
                  " (Score: ", DoubleToString(score, 1), ") for #", ticket);
           }
         applied++;
        }
     }

   if(applied > 0)
      Print("Applied Smart SL to ", applied, " positions");
   else
      Print("No positions found for ", _Symbol);

   // Draw SL lines
   DrawSLLines();
   UpdatePanel();
  }

//+------------------------------------------------------------------+
//| REGISTER VIRTUAL SL                                              |
//+------------------------------------------------------------------+
void RegisterVirtualSL(ulong ticket, double virtualSL, double entryPrice, int posType)
  {
   // Check if already tracked
   for(int i = 0; i < g_virtualCount; i++)
     {
      if(g_virtualSLs[i].ticket == ticket)
        {
         g_virtualSLs[i].virtualSL = virtualSL;
         g_virtualSLs[i].entryPrice = entryPrice;
         g_virtualSLs[i].posType = posType;
         g_virtualSLs[i].spikeActive = false;
         g_virtualSLs[i].spikeStartTime = 0;
         return;
        }
     }

   // Add new
   g_virtualCount++;
   ArrayResize(g_virtualSLs, g_virtualCount);
   VirtualSLInfo info;
   info.ticket = ticket;
   info.virtualSL = virtualSL;
   info.safetySL = 0;
   info.entryPrice = entryPrice;
   info.posType = posType;
   info.spikeActive = false;
   info.spikeStartTime = 0;
   g_virtualSLs[g_virtualCount - 1] = info;
  }

//+------------------------------------------------------------------+
//| MONITOR VIRTUAL SLs (Called by Timer)                            |
//+------------------------------------------------------------------+
void MonitorVirtualSLs()
  {
   if(g_virtualCount == 0)
      return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   for(int i = g_virtualCount - 1; i >= 0; i--)
     {
      ulong ticket = g_virtualSLs[i].ticket;

      // Check if position still exists
      if(!PositionSelectByTicket(ticket))
        {
         RemoveVirtualSL(i);
         continue;
        }

      double virtualSL = g_virtualSLs[i].virtualSL;
      int posType = g_virtualSLs[i].posType;
      bool triggered = false;

      // Check if price has crossed virtual SL
      if(posType == POSITION_TYPE_BUY && bid <= virtualSL)
         triggered = true;
      else if(posType == POSITION_TYPE_SELL && ask >= virtualSL)
         triggered = true;

      if(triggered)
        {
         // Anti-spike filter
         if(InpAntiSpikeSec > 0)
           {
            if(!g_virtualSLs[i].spikeActive)
              {
               // Start spike timer
               g_virtualSLs[i].spikeActive = true;
               g_virtualSLs[i].spikeStartTime = TimeCurrent();
               Print("⚡ Anti-spike: Price crossed Virtual SL for #", ticket,
                     ". Waiting ", InpAntiSpikeSec, "s to confirm...");
               continue;
              }
            else
              {
               // Check if enough time has passed
               if(TimeCurrent() - g_virtualSLs[i].spikeStartTime < InpAntiSpikeSec)
                  continue; // Still waiting

               // Confirm: price still beyond SL after wait?
               bool stillTriggered = false;
               if(posType == POSITION_TYPE_BUY && bid <= virtualSL)
                  stillTriggered = true;
               else if(posType == POSITION_TYPE_SELL && ask >= virtualSL)
                  stillTriggered = true;

               if(!stillTriggered)
                 {
                  // Spike recovered — cancel trigger
                  g_virtualSLs[i].spikeActive = false;
                  g_virtualSLs[i].spikeStartTime = 0;
                  Print("✓ Anti-spike: Price recovered for #", ticket, ". SL NOT triggered.");
                  continue;
                 }
              }
           }

         // === EXECUTE VIRTUAL SL CLOSE ===
         Print("🛡️ Virtual SL triggered for #", ticket, " at ", virtualSL);
         if(trade.PositionClose(ticket))
           {
            Print("✓ Position #", ticket, " closed by Virtual SL at ",
                  (posType == POSITION_TYPE_BUY ? bid : ask));
            RemoveVirtualSL(i);
           }
         else
           {
            Print("✗ Failed to close #", ticket, ": ", GetLastError());
           }
        }
      else
        {
         // Reset spike timer if price moved back
         if(g_virtualSLs[i].spikeActive)
           {
            g_virtualSLs[i].spikeActive = false;
            g_virtualSLs[i].spikeStartTime = 0;
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| REMOVE VIRTUAL SL ENTRY                                          |
//+------------------------------------------------------------------+
void RemoveVirtualSL(int index)
  {
   for(int i = index; i < g_virtualCount - 1; i++)
      g_virtualSLs[i] = g_virtualSLs[i + 1];

   g_virtualCount--;
   ArrayResize(g_virtualSLs, MathMax(g_virtualCount, 0));
  }

//+------------------------------------------------------------------+
//| CHECK AND APPLY SL TO NEW POSITIONS                              |
//+------------------------------------------------------------------+
void CheckAndApplyNewPositions()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      double currentSL = PositionGetDouble(POSITION_SL);
      bool isTracked = false;

      // Check if already tracked virtually
      for(int v = 0; v < g_virtualCount; v++)
        {
         if(g_virtualSLs[v].ticket == ticket)
           { isTracked = true; break; }
        }

      // New position without SL and not tracked
      if(currentSL == 0 && !isTracked)
        {
         double entry = PositionGetDouble(POSITION_PRICE_OPEN);
         int posType  = (int)PositionGetInteger(POSITION_TYPE);
         double tp    = PositionGetDouble(POSITION_TP);

         double score = 0;
         int candCount = 0;
         double optimalSL = CalculateOptimalSL(entry, posType, score, candCount);

         if(optimalSL > 0)
           {
            if(InpMode == MODE_REAL)
              {
               trade.PositionModify(ticket, optimalSL, tp);
               Print("Auto-applied Real SL: ", optimalSL, " for new position #", ticket);
              }
            else
              {
               RegisterVirtualSL(ticket, optimalSL, entry, posType);
               if(InpMode == MODE_HYBRID)
                 {
                  double safetySL;
                  if(posType == POSITION_TYPE_BUY)
                     safetySL = optimalSL - InpSafetyOffset * _Point;
                  else
                     safetySL = optimalSL + InpSafetyOffset * _Point;
                  safetySL = NormalizeDouble(safetySL, _Digits);
                  trade.PositionModify(ticket, safetySL, tp);
                 }
               Print("Auto-applied Virtual SL: ", optimalSL, " for new position #", ticket);
              }

            DrawSLLines();
            UpdatePanel();
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| TRAIL STOP LOSSES                                                |
//+------------------------------------------------------------------+
void TrailStopLosses()
  {
   double atr = 0;
   int atrHandle = iATR(_Symbol, PERIOD_CURRENT, InpATRPeriod);
   if(atrHandle != INVALID_HANDLE)
     {
      double atrBuf[];
      ArraySetAsSeries(atrBuf, true);
      CopyBuffer(atrHandle, 0, 0, 1, atrBuf);
      atr = atrBuf[0];
      IndicatorRelease(atrHandle);
     }

   if(atr <= 0) return;

   double trailDist = atr * InpTrailATRMult;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      double entry     = PositionGetDouble(POSITION_PRICE_OPEN);
      int    posType   = (int)PositionGetInteger(POSITION_TYPE);
      double profit    = PositionGetDouble(POSITION_PROFIT);

      if(profit <= 0) continue; // Only trail when in profit

      // Calculate new trail SL using scoring system
      double trailScore = 0;
      int trailCandCount = 0;
      double newTrailSL = CalculateOptimalSL(
         posType == POSITION_TYPE_BUY ? bid : ask,
         posType, trailScore, trailCandCount);

      if(newTrailSL <= 0) continue;

      // Ensure trail only moves in favor (never against trade)
      if(posType == POSITION_TYPE_BUY)
        {
         double currentSL = GetEffectiveSL(ticket);
         if(newTrailSL <= currentSL) continue;
         if(newTrailSL - currentSL < InpTrailStep * _Point) continue;
         if(newTrailSL >= bid) continue;
        }
      else
        {
         double currentSL = GetEffectiveSL(ticket);
         if(currentSL > 0 && newTrailSL >= currentSL) continue;
         if(currentSL > 0 && currentSL - newTrailSL < InpTrailStep * _Point) continue;
         if(newTrailSL <= ask) continue;
        }

      // Apply trail
      if(InpMode == MODE_REAL)
        {
         double tp = PositionGetDouble(POSITION_TP);
         if(trade.PositionModify(ticket, newTrailSL, tp))
            Print("Trail SL → ", newTrailSL, " for #", ticket);
        }
      else
        {
         // Update virtual SL
         for(int v = 0; v < g_virtualCount; v++)
           {
            if(g_virtualSLs[v].ticket == ticket)
              {
               g_virtualSLs[v].virtualSL = newTrailSL;
               if(InpMode == MODE_HYBRID)
                 {
                  double safetySL;
                  if(posType == POSITION_TYPE_BUY)
                     safetySL = newTrailSL - InpSafetyOffset * _Point;
                  else
                     safetySL = newTrailSL + InpSafetyOffset * _Point;
                  safetySL = NormalizeDouble(safetySL, _Digits);
                  double tp = PositionGetDouble(POSITION_TP);
                  trade.PositionModify(ticket, safetySL, tp);
                  g_virtualSLs[v].safetySL = safetySL;
                 }
               Print("Trail Virtual SL → ", newTrailSL, " for #", ticket);
               break;
              }
           }
        }

      DrawSLLines();
     }
  }

//+------------------------------------------------------------------+
//| GET EFFECTIVE SL (virtual or real)                               |
//+------------------------------------------------------------------+
double GetEffectiveSL(ulong ticket)
  {
   // First check virtual
   for(int i = 0; i < g_virtualCount; i++)
     {
      if(g_virtualSLs[i].ticket == ticket)
         return g_virtualSLs[i].virtualSL;
     }

   // Fallback to real SL
   if(PositionSelectByTicket(ticket))
      return PositionGetDouble(POSITION_SL);

   return 0;
  }

//+------------------------------------------------------------------+
//| RECALCULATE AND DISPLAY                                          |
//+------------------------------------------------------------------+
void RecalculateAndDisplay()
  {
   // Find first position on this symbol
   bool found = false;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(PositionGetString(POSITION_SYMBOL) == _Symbol)
        {
         double entry = PositionGetDouble(POSITION_PRICE_OPEN);
         int posType  = (int)PositionGetInteger(POSITION_TYPE);

         g_lastOptimalSL = CalculateOptimalSL(entry, posType,
                                              g_lastScore, g_candidateCount);
         g_lastCalcTime  = TimeCurrent();
         found = true;
         break;
        }
     }

   if(!found)
     {
      g_lastOptimalSL = 0;
      g_lastScore = 0;
      g_candidateCount = 0;
     }

   DrawSLLines();
   UpdatePanel();
  }

//+------------------------------------------------------------------+
//| DRAW SL LINES ON CHART                                           |
//+------------------------------------------------------------------+
void DrawSLLines()
  {
   string virtualLine = Prefix + "VirtualSL_Line";
   string safetyLine  = Prefix + "SafetySL_Line";

   // Clean old lines
   ObjectDelete(0, virtualLine);
   ObjectDelete(0, safetyLine);

   if(g_virtualCount == 0 && g_lastOptimalSL <= 0)
      return;

   // Draw main SL line
   double slToDraw = 0;
   int posType = -1;

   if(g_virtualCount > 0)
     {
      slToDraw = g_virtualSLs[0].virtualSL;
      posType = g_virtualSLs[0].posType;
     }
   else if(g_lastOptimalSL > 0)
     {
      slToDraw = g_lastOptimalSL;
     }

   if(slToDraw > 0)
     {
      ObjectCreate(0, virtualLine, OBJ_HLINE, 0, 0, slToDraw);
      ObjectSetInteger(0, virtualLine, OBJPROP_COLOR,
                       posType == POSITION_TYPE_BUY ? InpBullColor : InpBearColor);
      ObjectSetInteger(0, virtualLine, OBJPROP_STYLE, STYLE_DASH);
      ObjectSetInteger(0, virtualLine, OBJPROP_WIDTH, 2);
      ObjectSetString(0, virtualLine, OBJPROP_TEXT, "Smart SL: " + DoubleToString(slToDraw, _Digits));
      ObjectSetInteger(0, virtualLine, OBJPROP_BACK, true);
     }

   // Draw safety SL line (hybrid mode)
   if(g_virtualCount > 0 && g_virtualSLs[0].safetySL > 0)
     {
      ObjectCreate(0, safetyLine, OBJ_HLINE, 0, 0, g_virtualSLs[0].safetySL);
      ObjectSetInteger(0, safetyLine, OBJPROP_COLOR, clrGray);
      ObjectSetInteger(0, safetyLine, OBJPROP_STYLE, STYLE_DOT);
      ObjectSetInteger(0, safetyLine, OBJPROP_WIDTH, 1);
      ObjectSetString(0, safetyLine, OBJPROP_TEXT,
                      "Safety SL: " + DoubleToString(g_virtualSLs[0].safetySL, _Digits));
      ObjectSetInteger(0, safetyLine, OBJPROP_BACK, true);
     }

   ChartRedraw();
  }

//+------------------------------------------------------------------+
//| CREATE PANEL                                                     |
//+------------------------------------------------------------------+
void CreatePanel()
  {
   int panelW = 260;
   int panelH = 310;

   // Background
   ObjectCreate(0, ObjPanel, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, ObjPanel, OBJPROP_XDISTANCE, InpPanelX);
   ObjectSetInteger(0, ObjPanel, OBJPROP_YDISTANCE, InpPanelY);
   ObjectSetInteger(0, ObjPanel, OBJPROP_XSIZE, panelW);
   ObjectSetInteger(0, ObjPanel, OBJPROP_YSIZE, panelH);
   ObjectSetInteger(0, ObjPanel, OBJPROP_BGCOLOR, C'26,26,46');
   ObjectSetInteger(0, ObjPanel, OBJPROP_BORDER_TYPE, BORDER_RAISED);
   ObjectSetInteger(0, ObjPanel, OBJPROP_CORNER, CORNER_LEFT_UPPER);

   // Title
   CreateLabel(ObjTitle, InpPanelX + 10, InpPanelY + 8,
               "🛡️ SMART STOPLOSS", clrWhite, 11);

   // Mode
   string modeStr = InpMode == MODE_REAL ? "REAL" :
                     InpMode == MODE_VIRTUAL ? "VIRTUAL" : "HYBRID";
   CreateLabel(Prefix + "Mode", InpPanelX + panelW - 80, InpPanelY + 10,
               "[" + modeStr + "]", clrGold, 9);

   // Separator
   CreateLabel(Prefix + "Sep1", InpPanelX + 10, InpPanelY + 30,
               "────────────────────────────────", C'74,74,106', 7);

   // Info rows
   int y = InpPanelY + 48;
   int rowH = 20;

   CreateLabel(Prefix + "L_SL",      InpPanelX + 10, y, "Optimal SL:", clrSilver, 9);
   CreateLabel(Prefix + "V_SL",      InpPanelX + 130, y, "—", clrWhite, 9);
   y += rowH;

   CreateLabel(Prefix + "L_Score",   InpPanelX + 10, y, "Score:", clrSilver, 9);
   CreateLabel(Prefix + "V_Score",   InpPanelX + 130, y, "—", clrWhite, 9);
   y += rowH;

   CreateLabel(Prefix + "L_Struct",  InpPanelX + 10, y, "  Structure:", clrDimGray, 8);
   CreateLabel(Prefix + "V_Struct",  InpPanelX + 130, y, "—", clrDimGray, 8);
   y += rowH - 4;

   CreateLabel(Prefix + "L_ATR",     InpPanelX + 10, y, "  ATR Dist:", clrDimGray, 8);
   CreateLabel(Prefix + "V_ATR",     InpPanelX + 130, y, "—", clrDimGray, 8);
   y += rowH - 4;

   CreateLabel(Prefix + "L_Vol",     InpPanelX + 10, y, "  Volume:", clrDimGray, 8);
   CreateLabel(Prefix + "V_Vol",     InpPanelX + 130, y, "—", clrDimGray, 8);
   y += rowH - 4;

   CreateLabel(Prefix + "L_Rec",     InpPanelX + 10, y, "  Recency:", clrDimGray, 8);
   CreateLabel(Prefix + "V_Rec",     InpPanelX + 130, y, "—", clrDimGray, 8);
   y += rowH - 4;

   CreateLabel(Prefix + "L_MTF",     InpPanelX + 10, y, "  MTF:", clrDimGray, 8);
   CreateLabel(Prefix + "V_MTF",     InpPanelX + 130, y, "—", clrDimGray, 8);
   y += rowH - 4;

   CreateLabel(Prefix + "L_Round",   InpPanelX + 10, y, "  RoundNum:", clrDimGray, 8);
   CreateLabel(Prefix + "V_Round",   InpPanelX + 130, y, "—", clrDimGray, 8);
   y += rowH;

   CreateLabel(Prefix + "L_Cands",   InpPanelX + 10, y, "Candidates:", clrSilver, 9);
   CreateLabel(Prefix + "V_Cands",   InpPanelX + 130, y, "—", clrWhite, 9);
   y += rowH;

   CreateLabel(Prefix + "L_Dist",    InpPanelX + 10, y, "Distance:", clrSilver, 9);
   CreateLabel(Prefix + "V_Dist",    InpPanelX + 130, y, "—", clrWhite, 9);
   y += rowH;

   // Separator
   CreateLabel(Prefix + "Sep2", InpPanelX + 10, y,
               "────────────────────────────────", C'74,74,106', 7);
   y += 16;

   // Buttons
   string btnRecalc = Prefix + "BtnRecalc";
   ObjectCreate(0, btnRecalc, OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, btnRecalc, OBJPROP_XDISTANCE, InpPanelX + 10);
   ObjectSetInteger(0, btnRecalc, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, btnRecalc, OBJPROP_XSIZE, 115);
   ObjectSetInteger(0, btnRecalc, OBJPROP_YSIZE, 28);
   ObjectSetString(0, btnRecalc, OBJPROP_TEXT, "Recalculate");
   ObjectSetInteger(0, btnRecalc, OBJPROP_BGCOLOR, C'42,42,74');
   ObjectSetInteger(0, btnRecalc, OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, btnRecalc, OBJPROP_FONTSIZE, 9);

   string btnApply = Prefix + "BtnApply";
   ObjectCreate(0, btnApply, OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, btnApply, OBJPROP_XDISTANCE, InpPanelX + 135);
   ObjectSetInteger(0, btnApply, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, btnApply, OBJPROP_XSIZE, 115);
   ObjectSetInteger(0, btnApply, OBJPROP_YSIZE, 28);
   ObjectSetString(0, btnApply, OBJPROP_TEXT, "Apply SL");
   ObjectSetInteger(0, btnApply, OBJPROP_BGCOLOR, clrForestGreen);
   ObjectSetInteger(0, btnApply, OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, btnApply, OBJPROP_FONTSIZE, 9);

   ChartRedraw();
  }

//+------------------------------------------------------------------+
//| CREATE LABEL HELPER                                              |
//+------------------------------------------------------------------+
void CreateLabel(string name, int x, int y, string text, color clr, int fontSize)
  {
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);

   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontSize);
   ObjectSetString(0, name, OBJPROP_FONT, "Consolas");
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
  }

//+------------------------------------------------------------------+
//| UPDATE PANEL                                                     |
//+------------------------------------------------------------------+
void UpdatePanel()
  {
   // Find position info
   double entry = 0;
   int posType = -1;
   bool hasPos = false;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(PositionGetString(POSITION_SYMBOL) == _Symbol)
        {
         entry = PositionGetDouble(POSITION_PRICE_OPEN);
         posType = (int)PositionGetInteger(POSITION_TYPE);
         hasPos = true;
         break;
        }
     }

   if(!hasPos || g_lastOptimalSL <= 0)
     {
      ObjectSetString(0, Prefix + "V_SL",     OBJPROP_TEXT, hasPos ? "Calculating..." : "No Position");
      ObjectSetString(0, Prefix + "V_Score",   OBJPROP_TEXT, "—");
      ObjectSetString(0, Prefix + "V_Struct",  OBJPROP_TEXT, "—");
      ObjectSetString(0, Prefix + "V_ATR",     OBJPROP_TEXT, "—");
      ObjectSetString(0, Prefix + "V_Vol",     OBJPROP_TEXT, "—");
      ObjectSetString(0, Prefix + "V_Rec",     OBJPROP_TEXT, "—");
      ObjectSetString(0, Prefix + "V_MTF",     OBJPROP_TEXT, "—");
      ObjectSetString(0, Prefix + "V_Round",   OBJPROP_TEXT, "—");
      ObjectSetString(0, Prefix + "V_Cands",   OBJPROP_TEXT, "—");
      ObjectSetString(0, Prefix + "V_Dist",    OBJPROP_TEXT, "—");
      ChartRedraw();
      return;
     }

   // Recalculate with detail for display
   double atr = 0;
   int atrHandle = iATR(_Symbol, PERIOD_CURRENT, InpATRPeriod);
   if(atrHandle != INVALID_HANDLE)
     {
      double atrBuf[];
      ArraySetAsSeries(atrBuf, true);
      CopyBuffer(atrHandle, 0, 0, 1, atrBuf);
      atr = atrBuf[0];
      IndicatorRelease(atrHandle);
     }

   // Re-score the best candidate for display breakdown
   double avgVolume = 0;
   for(int i = 0; i < 20; i++)
      avgVolume += (double)iVolume(_Symbol, PERIOD_CURRENT, i);
   avgVolume /= 20.0;

   SwingPoint swings[];
   int swingCount = FindSwingPoints(swings, InpSwingLookback, InpSwingStrength);

   SwingPoint mtfSwings[];
   int mtfCount = FindSwingPoints(mtfSwings, 50, InpMTFSwingStr, InpMTFPeriod);

   // Find best candidate details
   SLCandidate bestCand;
   bestCand.totalScore = 0;
   bool foundCand = false;

   for(int i = 0; i < swingCount; i++)
     {
      if(posType == POSITION_TYPE_BUY && swings[i].isHigh) continue;
      if(posType == POSITION_TYPE_SELL && !swings[i].isHigh) continue;

      double slPrice = swings[i].price;
      double buffer = atr * 0.05;
      if(posType == POSITION_TYPE_BUY) slPrice -= buffer;
      else slPrice += buffer;

      if(posType == POSITION_TYPE_BUY && slPrice >= entry) continue;
      if(posType == POSITION_TYPE_SELL && slPrice <= entry) continue;

      SLCandidate cand = ScoreCandidate(slPrice, entry, posType, swings[i],
                                        atr, avgVolume, InpSwingLookback,
                                        mtfSwings, mtfCount);

      if(cand.totalScore > bestCand.totalScore || !foundCand)
        {
         bestCand = cand;
         foundCand = true;
        }
     }

   // SL Price
   color slColor = g_lastScore >= 70 ? clrLime :
                   g_lastScore >= 50 ? clrGold :
                   g_lastScore >= 30 ? clrOrange : clrOrangeRed;

   ObjectSetString(0, Prefix + "V_SL", OBJPROP_TEXT, DoubleToString(g_lastOptimalSL, _Digits));
   ObjectSetInteger(0, Prefix + "V_SL", OBJPROP_COLOR, slColor);

   // Total Score
   string scoreRank = g_lastScore >= 70 ? " ★★★" :
                      g_lastScore >= 50 ? " ★★" :
                      g_lastScore >= 30 ? " ★" : " ☆";
   ObjectSetString(0, Prefix + "V_Score", OBJPROP_TEXT,
                   DoubleToString(g_lastScore, 1) + "/100" + scoreRank);
   ObjectSetInteger(0, Prefix + "V_Score", OBJPROP_COLOR, slColor);

   if(foundCand)
     {
      // Breakdown scores
      ObjectSetString(0, Prefix + "V_Struct", OBJPROP_TEXT,
                      DoubleToString(bestCand.structureScore, 1) + "/35");
      ObjectSetInteger(0, Prefix + "V_Struct", OBJPROP_COLOR,
                       bestCand.structureScore >= 20 ? clrLime : clrOrange);

      ObjectSetString(0, Prefix + "V_ATR", OBJPROP_TEXT,
                      DoubleToString(bestCand.atrScore, 1) + "/25");
      ObjectSetInteger(0, Prefix + "V_ATR", OBJPROP_COLOR,
                       bestCand.atrScore >= 15 ? clrLime : clrOrange);

      ObjectSetString(0, Prefix + "V_Vol", OBJPROP_TEXT,
                      DoubleToString(bestCand.volumeScore, 1) + "/20");
      ObjectSetInteger(0, Prefix + "V_Vol", OBJPROP_COLOR,
                       bestCand.volumeScore >= 10 ? clrLime : clrOrange);

      ObjectSetString(0, Prefix + "V_Rec", OBJPROP_TEXT,
                      DoubleToString(bestCand.recencyScore, 1) + "/10");

      ObjectSetString(0, Prefix + "V_MTF", OBJPROP_TEXT,
                      bestCand.mtfBonus > 0 ? "+10 ✓" : "0");
      ObjectSetInteger(0, Prefix + "V_MTF", OBJPROP_COLOR,
                       bestCand.mtfBonus > 0 ? clrLime : clrGray);

      ObjectSetString(0, Prefix + "V_Round", OBJPROP_TEXT,
                      bestCand.roundPenalty < 0 ? "-15 ⚠" : "0 ✓");
      ObjectSetInteger(0, Prefix + "V_Round", OBJPROP_COLOR,
                       bestCand.roundPenalty < 0 ? clrOrangeRed : clrLime);
     }

   // Candidates count
   ObjectSetString(0, Prefix + "V_Cands", OBJPROP_TEXT,
                   IntegerToString(g_candidateCount) + " swing points");

   // Distance
   double dist = MathAbs(g_lastOptimalSL - entry);
   double distPoints = dist / _Point;
   ObjectSetString(0, Prefix + "V_Dist", OBJPROP_TEXT,
                   DoubleToString(distPoints, 0) + " pts (" +
                   DoubleToString(dist / atr, 1) + "× ATR)");

   ChartRedraw();
  }

//+------------------------------------------------------------------+
