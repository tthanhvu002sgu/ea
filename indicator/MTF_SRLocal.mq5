//+------------------------------------------------------------------+
//|                                                MTF_SRLocal.mq5   |
//|                                  Copyright 2024, Antigravity IDE |
//|                                                                  |
//| Multi-Timeframe Support & Resistance Channel Indicator           |
//+------------------------------------------------------------------+
#property copyright "Antigravity IDE"
#property version   "1.00"
#property indicator_chart_window
#property indicator_buffers 0
#property indicator_plots   0

//--- Input Parameters ---
input string Settings_Pivot   = "=== Pivot Settings ===";
input int    InpPivotPeriod   = 10;          // Pivot Check Period (Left & Right)
input int    InpChannelWidth  = 5;           // Maximum Channel Width (%)
input int    InpMinStrength   = 1;           // Minimum Strength (Number of touches)
input int    InpMaxSR         = 6;           // Max number of S/R channels per TF
input int    InpLoopback      = 290;         // Lookback Period

input string Settings_Colors  = "=== Colors & Visualization ===";
input bool   InpShowH1        = true;        // Show H1 SR?
input color  InpSupColH1      = clrLimeGreen; // H1 Support Color
input color  InpResColH1      = clrOrangeRed; // H1 Resistance Color
input bool   InpShowH4        = true;        // Show H4 SR?
input color  InpSupColH4      = clrDeepSkyBlue;// H4 Support Color
input color  InpResColH4      = clrViolet;    // H4 Resistance Color
input bool   InpShowD1        = true;        // Show D1 SR?
input color  InpSupColD1      = clrGold;      // D1 Support Color
input color  InpResColD1      = clrFireBrick; // D1 Resistance Color
input ushort InpAlpha         = 50;          // Transparency (0-255)

input string Settings_Alerts  = "=== Alerts & Mail ===";
input bool   InpEnableMail    = true;        // Enable Email when touching SR
input int    InpAlertCooldown = 3;           // Cooldown (Bars) between alerts to avoid spam

//--- Structures
struct PivotPoint
{
   double price;
   int    index;
   bool   is_high;
};

struct SRZone
{
   double upper_bound;
   double lower_bound;
   int    strength;
   int    start_index;    // Save the oldest pivot index that formed this zone
   ENUM_TIMEFRAMES timeframe;
   datetime start_time;   // Start time for drawing
   bool   is_drawn;
};

//--- Global limits
#define MAX_PIVOTS 200
#define HIST_PERIODS 300

//--- Globals for multi-timeframe
ENUM_TIMEFRAMES g_tfs[] = {PERIOD_H1, PERIOD_H4, PERIOD_D1};
int g_num_tfs = 3;
double g_cwidth[3]; // Channel width threshold for each TF

// Mail cooldown trackers
datetime g_last_alert_time[3] = {0, 0, 0};

// Array to store active zones to prevent redundant chart objects
SRZone g_active_zones[];

// Identifier
string g_obj_prefix = "MTFSR_";

//+------------------------------------------------------------------+
//| Initialize                                                       |
//+------------------------------------------------------------------+
int OnInit()
{
   ObjectsDeleteAll(0, g_obj_prefix);
   EventSetTimer(1); // Timer for regular cleanup or cross-TF checks (1 second)
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Deinit                                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   ObjectsDeleteAll(0, g_obj_prefix);
   EventKillTimer();
}

//+------------------------------------------------------------------+
//| Cleanup via timer (Optional, if you want dynamic update without ticks)
//+------------------------------------------------------------------+
void OnTimer()
{
   // Redraw if objects were accidentally deleted
}

//+------------------------------------------------------------------+
//| Main Calculation                                                 |
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
   // Execute only on new bar forming on CURRENT timeframe to avoid freezing terminal on every tick
   static datetime last_bar_time = 0;
   if(time[rates_total - 1] == last_bar_time && prev_calculated > 0) return rates_total;
   last_bar_time = time[rates_total - 1];

   // Delete all old zones to draw fresh ones
   ObjectsDeleteAll(0, g_obj_prefix);
   ArrayResize(g_active_zones, 0);

   // Determine which timeframes to calculate based on current chart TF
   ENUM_TIMEFRAMES current_tf = Period();
   
   for(int t = 0; t < g_num_tfs; t++)
   {
      ENUM_TIMEFRAMES loop_tf = g_tfs[t];
      
      // Filter: Only show HTF zones on LTF chart (e.g. on M15 show H1,H4,D1. On H4 show H4,D1)
      if(PeriodSeconds(loop_tf) < PeriodSeconds(current_tf)) continue;
      
      // User toggle check
      if(loop_tf == PERIOD_H1 && !InpShowH1) continue;
      if(loop_tf == PERIOD_H4 && !InpShowH4) continue;
      if(loop_tf == PERIOD_D1 && !InpShowD1) continue;
      
      CalculateAndDrawForTF(loop_tf, t);
   }

   // After drawing all zones, check if current price touched any of them to alert
   CheckAlerts();

   return(rates_total);
}

//+------------------------------------------------------------------+
//| Core Logic for single timeframe
//+------------------------------------------------------------------+
void CalculateAndDrawForTF(ENUM_TIMEFRAMES tf, int tf_idx)
{
   double high_tf[], low_tf[], close_tf[];
   datetime time_tf[];
   
   if(CopyHigh(_Symbol, tf, 0, HIST_PERIODS, high_tf) < HIST_PERIODS) return;
   if(CopyLow(_Symbol, tf, 0, HIST_PERIODS, low_tf) < HIST_PERIODS) return;
   if(CopyClose(_Symbol, tf, 0, HIST_PERIODS, close_tf) < HIST_PERIODS) return;
   if(CopyTime(_Symbol, tf, 0, HIST_PERIODS, time_tf) < HIST_PERIODS) return;
   
   ArraySetAsSeries(high_tf, true);
   ArraySetAsSeries(low_tf, true);
   ArraySetAsSeries(close_tf, true);
   ArraySetAsSeries(time_tf, true);
   
   // 1. Calculate Maximum Channel Width
   double highest_price = high_tf[ArrayMaximum(high_tf, 0, HIST_PERIODS)];
   double lowest_price  = low_tf[ArrayMinimum(low_tf, 0, HIST_PERIODS)];
   g_cwidth[tf_idx] = (highest_price - lowest_price) * InpChannelWidth / 100.0;
   
   // 2. Gather Pivot Points
   PivotPoint pivots[];
   int p_count = 0;
   int max_bars = MathMin(HIST_PERIODS, InpLoopback);
   
   for(int i = InpPivotPeriod; i < max_bars - InpPivotPeriod; i++)
   {
      double h_val = high_tf[i];
      double l_val = low_tf[i];
      
      bool is_ph = true;
      bool is_pl = true;
      
      for(int j = 1; j <= InpPivotPeriod; j++)
      {
         if(high_tf[i-j] > h_val || high_tf[i+j] > h_val) is_ph = false;
         if(low_tf[i-j] < l_val || low_tf[i+j] < l_val) is_pl = false;
      }
      
      if(is_ph || is_pl)
      {
         ArrayResize(pivots, p_count + 1);
         pivots[p_count].price = is_ph ? h_val : l_val;
         pivots[p_count].index = i;
         pivots[p_count].is_high = is_ph;
         p_count++;
      }
   }
   
   if(p_count < 2) return;
   
   // 3. Cluster Pivots into S/R Channels (Zones)
   SRZone temp_zones[];
   int num_zones = 0;
   
   for(int i = 0; i < p_count; i++)
   {
      if(pivots[i].price == 0) continue; // Skip merged
      
      double z_upper = pivots[i].price;
      double z_lower = pivots[i].price;
      int strength = 1;
      int oldest_idx = pivots[i].index; // Track the oldest pivot inside the zone
      
      for(int j = 0; j < p_count; j++)
      {
         if(i == j || pivots[j].price == 0) continue;
         
         double dist_up = MathAbs(z_upper - pivots[j].price);
         double dist_low = MathAbs(z_lower - pivots[j].price);
         double wdth = (pivots[j].price <= z_upper) ? (z_upper - pivots[j].price) : (pivots[j].price - z_lower);
         
          if(wdth <= g_cwidth[tf_idx])
         {
            if(pivots[j].price <= z_upper) z_lower = MathMin(z_lower, pivots[j].price);
            else                           z_upper = MathMax(z_upper, pivots[j].price);
            strength++;
            oldest_idx = MathMax(oldest_idx, pivots[j].index); // Since array is series, higher index means older in time
         }
      }
      
      if(strength >= InpMinStrength)
      {
         ArrayResize(temp_zones, num_zones + 1);
         temp_zones[num_zones].upper_bound = z_upper;
         temp_zones[num_zones].lower_bound = z_lower;
         temp_zones[num_zones].strength    = strength;
         temp_zones[num_zones].start_index = oldest_idx;
         num_zones++;
      }
   }
   
   // 4. Sort zones by strength (Bubble sort)
   for(int i = 0; i < num_zones - 1; i++)
   {
      for(int j = 0; j < num_zones - i - 1; j++)
      {
         if(temp_zones[j].strength < temp_zones[j+1].strength)
         {
            SRZone temp = temp_zones[j];
            temp_zones[j] = temp_zones[j+1];
            temp_zones[j+1] = temp;
         }
      }
   }
   
   // 5. Deduplicate overlapping prominent zones
   int final_zones = 0;
   for(int i = 0; i < num_zones; i++)
   {
      bool is_overlap = false;
      for(int k = 0; k < final_zones; k++)
      {
         if(temp_zones[i].upper_bound >= g_active_zones[k].lower_bound && 
            temp_zones[i].lower_bound <= g_active_zones[k].upper_bound &&
            g_active_zones[k].timeframe == tf)
         {
            is_overlap = true;
            break;
         }
      }
      
      if(!is_overlap)
      {
         int idx = ArraySize(g_active_zones);
         ArrayResize(g_active_zones, idx + 1);
         g_active_zones[idx] = temp_zones[i];
         g_active_zones[idx].timeframe = tf;
         g_active_zones[idx].start_time = time_tf[temp_zones[i].start_index]; // Map index back to true time
         final_zones++;
      }
      
      if(final_zones >= InpMaxSR) break;
   }
   
   // 6. Draw the zones on the chart
   double current_close = close_tf[0];
   DrawZonesForTF(tf, current_close);
}

//+------------------------------------------------------------------+
void DrawZonesForTF(ENUM_TIMEFRAMES tf, double current_close)
{
   color sup_col, res_col;
   string tf_str = EnumToString(tf);
   
   if(tf == PERIOD_H1) { sup_col = InpSupColH1; res_col = InpResColH1; }
   else if(tf == PERIOD_H4) { sup_col = InpSupColH4; res_col = InpResColH4; }
   else { sup_col = InpSupColD1; res_col = InpResColD1; }
   
   // Current chart time bounds
   datetime time_arr[];
   CopyTime(_Symbol, PERIOD_CURRENT, 0, 1, time_arr);
   datetime t_end = time_arr[0] + PeriodSeconds()*20; // Extend into future
   
   for(int i = 0; i < ArraySize(g_active_zones); i++)
   {
      if(g_active_zones[i].timeframe != tf) continue;
      
      string obj_name = g_obj_prefix + tf_str + "_" + IntegerToString(i);
      datetime t_start = g_active_zones[i].start_time;
      
      // Determine if it acts as Support or Resistance relative to current price
      color fill_color;
      if(current_close > g_active_zones[i].upper_bound) fill_color = sup_col;      // Price is above -> Support
      else if(current_close < g_active_zones[i].lower_bound) fill_color = res_col; // Price is below -> Resistance
      else fill_color = clrGray; // Price is inside the zone
      
      // Draw Rectangle
      ObjectCreate(0, obj_name, OBJ_RECTANGLE, 0, t_start, g_active_zones[i].upper_bound, t_end, g_active_zones[i].lower_bound);
      ObjectSetInteger(0, obj_name, OBJPROP_COLOR, fill_color);
      ObjectSetInteger(0, obj_name, OBJPROP_BACK, true);
      ObjectSetInteger(0, obj_name, OBJPROP_FILL, true);
      ObjectSetInteger(0, obj_name, OBJPROP_RAY_RIGHT, true);
      // Optional: Since MQL5 doesn't natively support easy alpha in base properties via inputs without ARGB
      // We will set the chart foreground flag. But true transparency in native MT5 rectangles isn't perfect unless using Bitmap or ARGB colors.
      // We will use standard color rendering.
      
      // Draw Label
      string lbl_name = obj_name + "_lbl";
      ObjectCreate(0, lbl_name, OBJ_TEXT, 0, t_end - PeriodSeconds()*5, g_active_zones[i].upper_bound);
      ObjectSetString(0, lbl_name, OBJPROP_TEXT, tf_str + " Zone (Strength: " + IntegerToString(g_active_zones[i].strength) + ")");
      ObjectSetInteger(0, lbl_name, OBJPROP_COLOR, clrWhite);
   }
}

//+------------------------------------------------------------------+
//| Check for Email Alerts                                           |
//+------------------------------------------------------------------+
void CheckAlerts()
{
   if(!InpEnableMail) return;
   
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   for(int i = 0; i < ArraySize(g_active_zones); i++)
   {
      double up = g_active_zones[i].upper_bound;
      double dn = g_active_zones[i].lower_bound;
      ENUM_TIMEFRAMES tf = g_active_zones[i].timeframe;
      
      int tf_idx = 0;
      if(tf == PERIOD_H4) tf_idx = 1;
      else if(tf == PERIOD_D1) tf_idx = 2;
      
      // Check if price is touching/inside the zone
      bool touching = (bid <= up && ask >= dn);
      
      if(touching)
      {
         datetime current_time = TimeCurrent();
         // Enforce Cooldown logic (3 bars of THAT timeframe)
         int cooldown_seconds = InpAlertCooldown * PeriodSeconds(tf);
         
         if(current_time >= g_last_alert_time[tf_idx] + cooldown_seconds || g_last_alert_time[tf_idx] == 0)
         {
            g_last_alert_time[tf_idx] = current_time;
            
            // Send Alert
            string type_str = (bid > up) ? "SUPPORT" : ((ask < dn) ? "RESISTANCE" : "INSIDE S/R");
            string subject = "[Alert] Price touched " + EnumToString(tf) + " S/R Zone on " + _Symbol;
            string body = "--- MTF S/R Alert ---\n\n";
            body += "Symbol: " + _Symbol + "\n";
            body += "Zone Timeframe: " + EnumToString(tf) + "\n";
            body += "Zone Type: " + type_str + "\n";
            body += "Upper Boundary: " + DoubleToString(up, _Digits) + "\n";
            body += "Lower Boundary: " + DoubleToString(dn, _Digits) + "\n";
            body += "Current Price Bid: " + DoubleToString(bid, _Digits) + "\n";
            body += "Zone Strength: " + IntegerToString(g_active_zones[i].strength) + " pivots touches\n\n";
            body += "Time: " + TimeToString(current_time, TIME_DATE|TIME_SECONDS);
            
            SendMail(subject, body);
            Print("Mail Alert Sent: ", subject);
         }
      }
   }
}
