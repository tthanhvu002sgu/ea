//+------------------------------------------------------------------+
//|                                            LiveFeedUploader.mq5 |
//|                                  Copyright 2026, Antigravity AI |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Antigravity AI"
#property link      "https://github.com/tthanhvu002sgu/ea"
#property version   "1.00"
#property description "Uploads MT5 live chart candles to Google Drive via Apps Script WebApp"

//--- inputs
input group "=== Google Apps Script Settings ==="
input string InpAppsScriptUrl = "https://script.google.com/macros/s/YOUR_SCRIPT_ID/exec"; // Apps Script URL

input group "=== Data Settings ==="
input int    InpCandleLimit   = 500;  // Number of candles to upload
input int    InpUploadMinutes = 5;    // Upload interval in minutes

//--- global variables
datetime last_upload_time = 0;
string   last_symbol      = "";
ENUM_TIMEFRAMES last_tf   = WRONG_VALUE;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   EventSetTimer(60); // Check every 60 seconds
   last_symbol = Symbol();
   last_tf = Period();
   
   Print("LiveFeedUploader initialized. Uploading every ", InpUploadMinutes, " minutes to: ", InpAppsScriptUrl);
   // Force upload once on init
   UploadLiveFeed();
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // Check for a new bar close to trigger immediate upload
   static datetime last_bar_time = 0;
   datetime current_bar_time = (datetime)SeriesInfoInteger(Symbol(), Period(), SERIES_LASTBAR_DATE);
   if(current_bar_time != last_bar_time)
   {
      last_bar_time = current_bar_time;
      Print("New bar detected. Triggering upload...");
      UploadLiveFeed();
   }
}

//+------------------------------------------------------------------+
//| Timer function                                                   |
//+------------------------------------------------------------------+
void OnTimer()
{
   datetime now = TimeCurrent();
   if(now - last_upload_time >= InpUploadMinutes * 60)
   {
      UploadLiveFeed();
   }
}

//+------------------------------------------------------------------+
//| Upload function                                                  |
//+------------------------------------------------------------------+
void UploadLiveFeed()
{
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   
   int copied = CopyRates(Symbol(), Period(), 0, InpCandleLimit, rates);
   if(copied <= 0)
   {
      Print("Error: Failed to copy rates from chart.");
      return;
   }
   
   // Format as CSV
   string csv = "Time,Open,High,Low,Close,TickVol\n";
   for(int i = copied - 1; i >= 0; i--)
   {
      string time_str = TimeToString(rates[i].time, TIME_DATE|TIME_MINUTES|TIME_SECONDS);
      // Replace dots with hyphens if preferred, but pandas parses dot format YYYY.MM.DD HH:MM:SS perfectly
      csv += time_str + "," +
             DoubleToString(rates[i].open, _Digits) + "," +
             DoubleToString(rates[i].high, _Digits) + "," +
             DoubleToString(rates[i].low, _Digits) + "," +
             DoubleToString(rates[i].close, _Digits) + "," +
             IntegerToString(rates[i].tick_volume) + "\n";
   }
   
   // Create JSON Payload
   // Target file name matching what Streamlit looks for
   string tf_str = StringSubstr(EnumToString(Period()), 7); // Remove "PERIOD_"
   string file_name = Symbol() + "_" + tf_str + "_live.csv";
   
   // Clean symbols (e.g. XAUUSDm -> XAUUSD)
   StringReplace(file_name, "/", ""); 
   
   // Construct JSON manually to avoid complex parsing libraries
   // Escape quotes and newlines in csv
   string escaped_csv = csv;
   StringReplace(escaped_csv, "\\", "\\\\");
   StringReplace(escaped_csv, "\"", "\\\"");
   StringReplace(escaped_csv, "\n", "\\n");
   StringReplace(escaped_csv, "\r", "\\r");
   
   string post_data = "{\"file_name\":\"" + file_name + "\",\"csv_content\":\"" + escaped_csv + "\"}";
   
   // Send WebRequest
   string headers = "Content-Type: application/json\r\n";
   char post_data_char[];
   char result[];
   string result_headers;
   
   StringToCharArray(post_data, post_data_char, 0, StringLen(post_data), CP_UTF8);
   // Make sure null terminator is removed
   if(ArraySize(post_data_char) > 0 && post_data_char[ArraySize(post_data_char)-1] == 0)
   {
      ArrayResize(post_data_char, ArraySize(post_data_char) - 1);
   }
   
   ResetLastError();
   int res = WebRequest("POST", InpAppsScriptUrl, headers, 10000, post_data_char, result, result_headers);
   
   if(res == 200 || res == 302 || res == 301)
   {
      Print("Upload successful: ", file_name, " (", copied, " bars)");
      last_upload_time = TimeCurrent();
   }
   else
   {
      Print("Error: WebRequest failed. Code: ", res, ". Last error: ", GetLastError());
      if(res == -1)
      {
         Print("Hint: Ensure the domain is added to Tools -> Options -> Expert Advisors -> Allow WebRequest.");
      }
   }
}
