//+------------------------------------------------------------------+
//|                                              XAUUSD_AI_EA V2.mq5|
//|       Advanced XAUUSD AI trading EA with news & volatility filters|
//|       Uses multi-timeframe analysis, news API, volatility filters |
//|                                                                  |
//|  V2 Features:                                                     |
//|  - News API integration (blocks trades during high-impact events)|
//|  - ATR volatility filter (compares to historical average)       |
//|  - Time-based blocking (USD news windows)                        |
//|  - D1 macro trend filter (200 EMA)                               |
//|  - Week range analysis                                           |
//|  - Multiple TP levels (TP1, TP2, TP3)                           |
//|                                                                  |
//|  VPS (MQL5): 1) Attach to any XAUUSD chart (M5 aanbevolen).      |
//|  2) Enable AutoTrading. 3) Account Navigator > right-click       |
//|  account > Migrate > Migrate All. 4) Check VPS Journal for       |
//|  "[VPS] ... OK" heartbeat each hour.                             |
//+------------------------------------------------------------------+
#property copyright "AI Trading by Chiel"
#property link      "https://www.mql5.com/"
#property version   "2.0"
#property strict

#include <Trade\Trade.mqh>

//--- trade object
CTrade trade;

//+------------------------------------------------------------------+
//| Input parameters                                                 |
//+------------------------------------------------------------------+
input string           TradeSymbol      = "XAUUSD";        // Trading symbol
input ENUM_TIMEFRAMES  EntryTF          = PERIOD_M5;       // Entry timeframe
input ENUM_TIMEFRAMES  TrendTF          = PERIOD_H1;       // Trend filter timeframe

//--- risk management
input double           RiskPercent      = 2.0;             // Risk per trade (% of balance)
input double           MaxSpreadPoints  = 300;             // Max allowed spread in points

//--- confidence / AI
input double           MinConfidence    = 70.0;            // Minimum confidence (0-100) to allow entry
input bool             UseMLModel       = false;           // Use ONNX ML model (stub for now)
input string           OnnxModelPath    = "";              // Path to ONNX model (future use)

//--- TP/SL & trailing
input double           AtrSLFactor      = 2.5;             // SL = ATR * factor
input double           BaseRR           = 2.0;             // Base Risk:Reward for TP (final TP3)
input bool             UseTrailingStop  = true;            // Enable trailing stop
input double           TrailStartRR     = 1.0;             // Start trailing at this RR
input double           TrailStepPoints  = 300;             // Trailing step in points
input bool             ShowVPSHeartbeat = true;            // Log status periodically (for VPS monitoring)

//--- Multiple TP levels (partial profit taking)
input bool             UseMultipleTPs    = true;            // Enable TP1, TP2, TP3 partial closing
input double           TP1_RR           = 1.0;             // TP1 Risk:Reward (sluit %TP1_Percent)
input double           TP1_Percent      = 30.0;            // % van positie sluiten bij TP1
input double           TP2_RR           = 1.5;             // TP2 Risk:Reward (sluit %TP2_Percent)
input double           TP2_Percent      = 30.0;            // % van positie sluiten bij TP2
input double           TP3_RR           = 2.0;             // TP3 Risk:Reward (sluit resterende %)
input double           TP3_Percent      = 40.0;            // % van positie sluiten bij TP3 (rest)

//--- web log (api.aitrading.software)
input bool             UseWebLog        = true;            // Send logs to web dashboard
input string           WebLogUrl        = "https://api.aitrading.software/api/log";  // Log API URL
input string           WebLogSecret    = "";              // Optional: same as LOG_API_KEY on Vercel

//--- test (één keer een BUY plaatsen om order/TP/SL te testen)
input bool             PlaceTestTrade   = false;           // Place one test BUY (zet daarna weer op false)

//--- web instellingen (haal op van api.aitrading.software)
input bool             UseWebSettings   = false;           // Instellingen van website gebruiken
input string           WebSettingsUrl   = "https://api.aitrading.software/api/settings";  // Settings API

//--- command center: heartbeat (VPS/account/positions naar dashboard)
input bool             UseWebHeartbeat  = true;            // Stuur account + posities naar command center
input string           WebHeartbeatUrl  = "https://api.aitrading.software/api/heartbeat";  // Heartbeat API

//--- News & Volatility Protection (V2 features)
input bool             UseNewsFilter    = true;            // Enable news filtering (block trades during news)
input string           NewsApiUrl       = "https://api.aitrading.software/api/news";  // News API URL (returns upcoming high-impact USD events)
input int              NewsBlockMinutes = 60;              // Block trades X minutes before/after news
input bool             UseTimeBlock     = true;            // Block trades during known USD news times (14:30-15:30 CET)
input int              BlockStartHour   = 14;               // Start blocking at this hour (CET)
input int              BlockStartMin    = 30;              // Start blocking at this minute
input int              BlockEndHour     = 15;              // End blocking at this hour (CET)
input int              BlockEndMin      = 30;              // End blocking at this minute
input bool             BlockNFPFriday   = true;            // Block first Friday of month (NFP day)

//--- Volatility filters
input bool             UseAtrVolatilityFilter = true;      // Block trades if ATR > X times average
input double           AtrVolatilityMultiplier = 2.0;      // Block if current ATR > average * this multiplier
input int              AtrHistoryDays    = 7;              // Days to calculate ATR average
input bool             UseSpreadRatioFilter = true;        // Block if spread > X times normal
input double           SpreadRatioMultiplier = 1.5;         // Block if spread > normal * this multiplier
input double           NormalSpreadPoints = 150.0;          // Normal spread for XAUUSD (points)

//--- Multi-timeframe analysis (V2 features)
input bool             UseD1TrendFilter = true;            // Use D1 200 EMA as macro trend filter
input int              D1MaPeriod       = 200;             // D1 MA period for macro trend
input bool             UseWeekRange     = true;            // Analyze position within weekly range
input double           WeekRangeMinPercent = 20.0;         // Min % from week low to allow BUY
input double           WeekRangeMaxPercent = 80.0;         // Max % from week low to allow BUY

//+------------------------------------------------------------------+
//| Global variables / handles                                       |
//+------------------------------------------------------------------+
int      atrHandleEntry   = INVALID_HANDLE;
int      rsiHandleEntry   = INVALID_HANDLE;
int      maHandleTrend    = INVALID_HANDLE;

datetime lastEntryBarTime = 0;   // To ensure once-per-bar logic on EntryTF
datetime lastHeartbeat    = 0;   // For VPS status log
bool     testTradePlaced  = false;  // één test-BUY per sessie

// TP tracking: welke TP's zijn al getriggerd per positie ticket
struct TPTracking
{
   ulong ticket;
   bool  tp1Hit;
   bool  tp2Hit;
   bool  tp3Hit;
};
TPTracking tpTracking[];  // Array om TP status per positie bij te houden

// Web settings (opgehaald van API)
double   g_riskPercent      = 2.0;
double   g_minConfidence    = 70.0;
bool     g_placeTestTrade   = false;
bool     g_useTrailingStop  = true;
double   g_atrSLFactor      = 2.5;
double   g_baseRR           = 2.0;
bool     g_tradingEnabled   = true;   // AI trading AAN/UIT (vanaf command center)
bool     g_webSettingsLoaded = false;
int      g_barsSinceSettingsFetch = 0;

// News & Volatility tracking (V2)
datetime g_lastNewsCheck    = 0;      // Last time we checked for news
bool     g_newsBlockActive  = false;  // Is news blocking currently active?
string   g_nextNewsEvent    = "";     // Description of next news event
datetime g_nextNewsTime     = 0;      // Time of next news event
double   g_atrAverage       = 0.0;    // Average ATR over last N days
double   g_normalSpread     = 150.0;  // Normal spread (calculated or set)

//+------------------------------------------------------------------+
//| Forward declarations                                             |
//+------------------------------------------------------------------+
bool     InitIndicators();
void     ReleaseIndicators();
bool     IsNewBar(const string symbol, ENUM_TIMEFRAMES tf, datetime &storedTime);
double   GetAtr(const string symbol, ENUM_TIMEFRAMES tf, int period);
double   GetRsi(const string symbol, ENUM_TIMEFRAMES tf, int period);
double   GetMa(const string symbol, ENUM_TIMEFRAMES tf, int period);

// analysis / signal
int      CalculateSignalDirection(double &confidence);

// ML stub
double   MlPredictConfidence(double &ruleBasedConfidence);

// risk & order
bool     OpenPosition(const ENUM_ORDER_TYPE orderType,
                      const double           riskPercent,
                      const double           confidence);
bool     HasOpenPosition(const string symbol);
void     ManageTrailingStop(const string symbol);
void     ManagePartialTPs(const string symbol);
int      FindTPTrackingIndex(ulong ticket);
void     AddTPTracking(ulong ticket);

// helpers
double   CalculateLotSizeByRisk(const string symbol,
                                const double  riskPercent,
                                const double  stopLossPrice);
void     WebLog(const string message, const string level = "info");
bool     FetchWebSettings();
void     SendHeartbeat();
double   ParseJsonDouble(const string json, const string key);
bool     ParseJsonBool(const string json, const string key);

// V2: News & Volatility filters
bool     CheckNewsBlock();
bool     FetchNewsEvents();
bool     IsTimeBlocked();
bool     IsNFPFriday();
bool     CheckAtrVolatility();
bool     CheckSpreadRatio();
void     UpdateAtrAverage();
double   GetWeekRangePercent(const string symbol);
int      GetD1TrendDirection(const string symbol);

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   // Ensure we only run on configured symbol
   if(Symbol() != TradeSymbol)
     {
      Print("XAUUSD_AI_EA: Please attach EA to chart of ", TradeSymbol);
      WebLog("Please attach EA to chart of " + TradeSymbol, "warn");
     }

   trade.SetExpertMagicNumber(20260211);

   if(!InitIndicators())
     {
      Print("XAUUSD_AI_EA: Failed to initialize indicators.");
      WebLog("Failed to initialize indicators.", "error");
      return(INIT_FAILED);
     }

   // V2: Initialize normal spread
   g_normalSpread = NormalSpreadPoints;
   if(g_normalSpread <= 0.0)
      g_normalSpread = 150.0; // Default for XAUUSD
   
   // V2: Initialize ATR average
   if(UseAtrVolatilityFilter)
      UpdateAtrAverage();
   
   string initMsg = "XAUUSD_AI_EA V2 initialized. Symbol=" + TradeSymbol +
                    " EntryTF=" + EnumToString(EntryTF) + " TrendTF=" + EnumToString(TrendTF) +
                    " | NewsFilter=" + (UseNewsFilter ? "ON" : "OFF") +
                    " | AtrFilter=" + (UseAtrVolatilityFilter ? "ON" : "OFF") +
                    " | D1Trend=" + (UseD1TrendFilter ? "ON" : "OFF");
   Print(initMsg);
   WebLog(initMsg);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   ReleaseIndicators();
   string deinitMsg = "XAUUSD_AI_EA deinitialized. Reason=" + IntegerToString(reason);
   Print(deinitMsg);
   WebLog(deinitMsg);
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   // Only operate on configured symbol
   if(Symbol() != TradeSymbol)
      return;

   // New bar filter on EntryTF
   if(!IsNewBar(TradeSymbol, EntryTF, lastEntryBarTime))
     {
      // Still manage trailing stop and partial TP's on every tick
      if(UseWebSettings && g_webSettingsLoaded ? g_useTrailingStop : UseTrailingStop)
         ManageTrailingStop(TradeSymbol);
      if(UseMultipleTPs)
         ManagePartialTPs(TradeSymbol);
      return;
     }

   // Web settings ophalen (elke 5 bars of eerste bar)
   if(UseWebSettings)
     {
      g_barsSinceSettingsFetch++;
      if(g_barsSinceSettingsFetch >= 5 || !g_webSettingsLoaded)
        {
         FetchWebSettings();
         g_barsSinceSettingsFetch = 0;
        }
     }

   // Command center: stuur account + posities (zelfde ritme als settings)
   if(UseWebHeartbeat && StringLen(WebHeartbeatUrl) >= 10)
     {
      if(g_barsSinceSettingsFetch == 0 || !UseWebSettings)
         SendHeartbeat();
     }

   // VPS heartbeat: log once per hour so you see EA is running
   if(ShowVPSHeartbeat)
     {
      datetime now = TimeCurrent();
      if(now - lastHeartbeat >= 3600)  // 1 hour
        {
         lastHeartbeat = now;
         int spread = (int)SymbolInfoInteger(TradeSymbol, SYMBOL_SPREAD);
         bool hasPos = HasOpenPosition(TradeSymbol);
         string vpsMsg = StringFormat("[VPS] %s XAUUSD_AI_EA OK | spread=%d pos=%s",
                                      TimeToString(now, TIME_DATE|TIME_MINUTES), spread, hasPos ? "yes" : "no");
         Print(vpsMsg);
         WebLog(vpsMsg);
        }
     }

   // Basic spread filter
   double spreadPoints = (double)SymbolInfoInteger(TradeSymbol, SYMBOL_SPREAD);
   if(spreadPoints > MaxSpreadPoints && MaxSpreadPoints > 0)
     {
      string spreadMsg = StringFormat("Spread too high: %.0f > %.0f", spreadPoints, MaxSpreadPoints);
      Print(spreadMsg);
      WebLog(spreadMsg, "warn");
      return;
     }

   // Only one position at a time on this symbol
   if(HasOpenPosition(TradeSymbol))
     {
      if(UseWebSettings && g_webSettingsLoaded ? g_useTrailingStop : UseTrailingStop)
         ManageTrailingStop(TradeSymbol);
      if(UseMultipleTPs)
         ManagePartialTPs(TradeSymbol);
      return;
     }

   // Command center: AI trading UIT = geen nieuwe trades openen
   if(UseWebSettings && g_webSettingsLoaded && !g_tradingEnabled)
      return;

   bool effPlaceTestTrade = (UseWebSettings && g_webSettingsLoaded) ? g_placeTestTrade : PlaceTestTrade;
   if(effPlaceTestTrade && !testTradePlaced)
     {
      Print("XAUUSD_AI_EA: Placing test BUY (0.5% risk). Zet PlaceTestTrade daarna op false.");
      WebLog("Placing test BUY to verify order execution.");
      if(OpenPosition(ORDER_TYPE_BUY, 0.5, 100.0))
         testTradePlaced = true;
      return;
     }

   // V2: Update ATR average (once per bar)
   if(UseAtrVolatilityFilter)
      UpdateAtrAverage();

   // V2: News filter check
   if(UseNewsFilter)
     {
      if(CheckNewsBlock())
        {
         string newsMsg = "Trade blocked: News event detected. " + g_nextNewsEvent;
         Print(newsMsg);
         WebLog(newsMsg, "warn");
         return;
        }
     }

   // V2: Time-based blocking (USD news times)
   if(UseTimeBlock)
     {
      if(IsTimeBlocked())
        {
         string timeMsg = "Trade blocked: USD news time window (14:30-15:30 CET)";
         Print(timeMsg);
         WebLog(timeMsg, "warn");
         return;
        }
      if(BlockNFPFriday && IsNFPFriday())
        {
         string nfpMsg = "Trade blocked: NFP Friday (first Friday of month)";
         Print(nfpMsg);
         WebLog(nfpMsg, "warn");
         return;
        }
     }

   // V2: ATR Volatility filter
   if(UseAtrVolatilityFilter)
     {
      if(!CheckAtrVolatility())
        {
         string atrMsg = StringFormat("Trade blocked: ATR volatility too high (%.2f > %.2f * %.2f)",
                                      GetAtr(TradeSymbol, EntryTF, 14), g_atrAverage, AtrVolatilityMultiplier);
         Print(atrMsg);
         WebLog(atrMsg, "warn");
         return;
        }
     }

   // V2: Spread ratio filter
   if(UseSpreadRatioFilter)
     {
      if(!CheckSpreadRatio())
        {
         double currentSpread = (double)SymbolInfoInteger(TradeSymbol, SYMBOL_SPREAD);
         string spreadMsg = StringFormat("Trade blocked: Spread ratio too high (%.0f > %.0f * %.2f)",
                                        currentSpread, NormalSpreadPoints, SpreadRatioMultiplier);
         Print(spreadMsg);
         WebLog(spreadMsg, "warn");
         return;
        }
     }

   // Calculate signal + confidence
   double confidence = 0.0;
   int signalDir = CalculateSignalDirection(confidence); // 1 = buy, -1 = sell, 0 = none

   // Optionally pass through ML model (stub)
   if(UseMLModel)
     {
      confidence = MlPredictConfidence(confidence);
     }

   // Log why no signal: trend (1=up,-1=down,0=flat) and RSI help interpret confidence=0
   double rsiNow = GetRsi(TradeSymbol, EntryTF, 14);
   int trendNow  = 0;
   double maBuf[2];
   int hMa = iMA(TradeSymbol, TrendTF, 50, 0, MODE_EMA, PRICE_CLOSE);
   if(hMa != INVALID_HANDLE && CopyBuffer(hMa, 0, 0, 2, maBuf) == 2)
     {
      if(maBuf[0] > maBuf[1]) trendNow = 1;
      else if(maBuf[0] < maBuf[1]) trendNow = -1;
      IndicatorRelease(hMa);
     }
   string signalMsg = StringFormat("SignalDir=%d, confidence=%.2f | trend=%d RSI=%.1f (BUY need trend=1 RSI<40, SELL need trend=-1 RSI>60)",
                                   signalDir, confidence, trendNow, rsiNow);
   Print(signalMsg);
   WebLog(signalMsg);

   if(signalDir == 0)
      return;

   double effMinConfidence = (UseWebSettings && g_webSettingsLoaded) ? g_minConfidence : MinConfidence;
   if(confidence < effMinConfidence)
     {
      string confMsg = StringFormat("Confidence %.2f below MinConfidence %.2f, no trade.", confidence, effMinConfidence);
      Print(confMsg);
      WebLog(confMsg);
      return;
     }

   ENUM_ORDER_TYPE orderType = (signalDir > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   double effRiskPercent = (UseWebSettings && g_webSettingsLoaded) ? g_riskPercent : RiskPercent;

   if(!OpenPosition(orderType, effRiskPercent, confidence))
     {
      Print("Failed to open position.");
      WebLog("Failed to open position.", "error");
     }
  }

//+------------------------------------------------------------------+
//| Initialize indicator handles                                     |
//+------------------------------------------------------------------+
bool InitIndicators()
  {
   int atrPeriod = 14;
   int rsiPeriod = 14;
   int maPeriod  = 50;

   atrHandleEntry = iATR(TradeSymbol, EntryTF, atrPeriod);
   rsiHandleEntry = iRSI(TradeSymbol, EntryTF, rsiPeriod, PRICE_CLOSE);
   maHandleTrend  = iMA(TradeSymbol, TrendTF, maPeriod, 0, MODE_EMA, PRICE_CLOSE);

   if(atrHandleEntry == INVALID_HANDLE ||
      rsiHandleEntry == INVALID_HANDLE ||
      maHandleTrend  == INVALID_HANDLE)
     {
      string errMsg = StringFormat("Failed to create indicator handles. ATR=%d RSI=%d MA=%d",
                                   atrHandleEntry, rsiHandleEntry, maHandleTrend);
      Print(errMsg);
      WebLog(errMsg, "error");
      return(false);
     }
   return(true);
  }

//+------------------------------------------------------------------+
//| Release indicator handles                                        |
//+------------------------------------------------------------------+
void ReleaseIndicators()
  {
   if(atrHandleEntry != INVALID_HANDLE)
      IndicatorRelease(atrHandleEntry);
   if(rsiHandleEntry != INVALID_HANDLE)
      IndicatorRelease(rsiHandleEntry);
   if(maHandleTrend != INVALID_HANDLE)
      IndicatorRelease(maHandleTrend);
  }

//+------------------------------------------------------------------+
//| Detect new bar on given symbol/timeframe                         |
//+------------------------------------------------------------------+
bool IsNewBar(const string symbol, ENUM_TIMEFRAMES tf, datetime &storedTime)
  {
   datetime times[2];
   if(CopyTime(symbol, tf, 0, 2, times) != 2)
      return(false);

   datetime lastTime = times[0];
   if(lastTime != storedTime)
     {
      storedTime = lastTime;
      return(true);
     }
   return(false);
  }

//+------------------------------------------------------------------+
//| Helper: get ATR value                                            |
//+------------------------------------------------------------------+
double GetAtr(const string symbol, ENUM_TIMEFRAMES tf, int period)
  {
   double buffer[2];
   int handle = iATR(symbol, tf, period);
   if(handle == INVALID_HANDLE)
      return(0.0);
   if(CopyBuffer(handle, 0, 0, 1, buffer) != 1)
     {
      IndicatorRelease(handle);
      return(0.0);
     }
   IndicatorRelease(handle);
   return(buffer[0]);
  }

//+------------------------------------------------------------------+
//| Helper: get RSI value                                            |
//+------------------------------------------------------------------+
double GetRsi(const string symbol, ENUM_TIMEFRAMES tf, int period)
  {
   double buffer[2];
   int handle = iRSI(symbol, tf, period, PRICE_CLOSE);
   if(handle == INVALID_HANDLE)
      return(50.0);
   if(CopyBuffer(handle, 0, 0, 1, buffer) != 1)
     {
      IndicatorRelease(handle);
      return(50.0);
     }
   IndicatorRelease(handle);
   return(buffer[0]);
  }

//+------------------------------------------------------------------+
//| Helper: get MA value                                             |
//+------------------------------------------------------------------+
double GetMa(const string symbol, ENUM_TIMEFRAMES tf, int period)
  {
   double buffer[2];
   int handle = iMA(symbol, tf, period, 0, MODE_EMA, PRICE_CLOSE);
   if(handle == INVALID_HANDLE)
      return(0.0);
   if(CopyBuffer(handle, 0, 0, 1, buffer) != 1)
     {
      IndicatorRelease(handle);
      return(0.0);
     }
   IndicatorRelease(handle);
   return(buffer[0]);
  }

//+------------------------------------------------------------------+
//| Calculate signal direction & confidence                          |
//+------------------------------------------------------------------+
int CalculateSignalDirection(double &confidence)
  {
   confidence = 0.0;

   // V2: D1 Macro Trend Filter (200 EMA)
   int d1Trend = 0;
   if(UseD1TrendFilter)
     {
      d1Trend = GetD1TrendDirection(TradeSymbol);
      if(d1Trend == 0)
         return(0); // No clear D1 trend, no trade
      if(d1Trend > 0)
         confidence += 20.0; // D1 uptrend bonus
      else
         confidence += 20.0; // D1 downtrend bonus
     }

   // Trend via MA slope on TrendTF
   int    maPeriod = 50;
   double maCurrent, maPrev;
   double maBuffer[2];
   int    handle = iMA(TradeSymbol, TrendTF, maPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if(handle == INVALID_HANDLE)
      return(0);
   if(CopyBuffer(handle, 0, 0, 2, maBuffer) != 2)
     {
      IndicatorRelease(handle);
      return(0);
     }
   IndicatorRelease(handle);
   maCurrent = maBuffer[0];
   maPrev    = maBuffer[1];

   int trendDir = 0; // 1 up, -1 down
   if(maCurrent > maPrev)
      trendDir = 1;
   else if(maCurrent < maPrev)
      trendDir = -1;

   // V2: H1 trend must align with D1 trend
   if(UseD1TrendFilter && d1Trend != 0 && trendDir != d1Trend)
     {
      // Trend conflict: H1 and D1 don't align
      confidence -= 30.0; // Penalty for trend conflict
     }

   if(trendDir != 0)
      confidence += 30.0; // base trend score

   // RSI filter on EntryTF
   int    rsiPeriod = 14;
   double rsi       = GetRsi(TradeSymbol, EntryTF, rsiPeriod);

   int signalDir = 0;

   // Simple logic:
   // - if trend up and RSI from oversold zone, look for BUY
   // - if trend down and RSI from overbought zone, look for SELL
   if(trendDir > 0 && rsi < 40.0)
     {
      signalDir   = 1;
      confidence += 25.0;
     }
   else if(trendDir < 0 && rsi > 60.0)
     {
      signalDir   = -1;
      confidence += 25.0;
     }

   // V2: Week Range Filter
   if(UseWeekRange && signalDir != 0)
     {
      double weekRangePercent = GetWeekRangePercent(TradeSymbol);
      if(signalDir > 0) // BUY signal
        {
         if(weekRangePercent < WeekRangeMinPercent || weekRangePercent > WeekRangeMaxPercent)
           {
            // Price too low or too high in weekly range for BUY
            confidence -= 15.0;
           }
         else
           {
            confidence += 10.0; // Good position in weekly range
           }
        }
      else // SELL signal
        {
         if(weekRangePercent < WeekRangeMinPercent || weekRangePercent > WeekRangeMaxPercent)
           {
            // For SELL, we want price near top of range
            if(weekRangePercent > (100.0 - WeekRangeMinPercent))
              {
               confidence += 10.0; // Good position for SELL
              }
            else
              {
               confidence -= 15.0;
              }
           }
        }
     }

   // Volatility (ATR) check
   int    atrPeriod = 14;
   double atr       = GetAtr(TradeSymbol, EntryTF, atrPeriod);
   if(atr > 0.0)
     {
      confidence += 20.0;
     }

   // Normalize / cap confidence
   if(confidence > 100.0)
      confidence = 100.0;
   if(confidence < 0.0)
      confidence = 0.0;

   // If no clear trend or RSI condition, no signal
   if(signalDir == 0)
      confidence = 0.0;

   return(signalDir);
  }

//+------------------------------------------------------------------+
//| ML confidence stub (ONNX-ready interface)                        |
//+------------------------------------------------------------------+
double MlPredictConfidence(double &ruleBasedConfidence)
  {
   // Stub: in future this will:
   // - assemble feature vector (OHLC, indicators, etc.)
   // - call ONNX model via new MT5 ONNX API
   // For now, just slightly smooth rule-based confidence.

   double mlConfidence = ruleBasedConfidence; // placeholder

   // Combine (for now identity)
   double combined = 0.7 * ruleBasedConfidence + 0.3 * mlConfidence;
   if(combined > 100.0)
      combined = 100.0;
   if(combined < 0.0)
      combined = 0.0;
   return(combined);
  }

//+------------------------------------------------------------------+
//| Check if there is any open position for this symbol              |
//+------------------------------------------------------------------+
bool HasOpenPosition(const string symbol)
  {
   for(int i = PositionsTotal() - 1; i >= 0; --i)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionSelectByTicket(ticket))
        {
         if((string)PositionGetString(POSITION_SYMBOL) == symbol)
            return(true);
        }
     }
   return(false);
  }

//+------------------------------------------------------------------+
//| Calculate lot size based on risk % and SL price                  |
//+------------------------------------------------------------------+
double CalculateLotSizeByRisk(const string symbol,
                              const double  riskPercent,
                              const double  stopLossPrice)
  {
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMoney = balance * (riskPercent / 100.0);

   double price      = SymbolInfoDouble(symbol, SYMBOL_BID);
   double point      = SymbolInfoDouble(symbol, SYMBOL_POINT);
   double tickValue  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize   = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);

   if(point <= 0.0 || tickValue <= 0.0 || tickSize <= 0.0)
      return(0.0);

   double slPoints = MathAbs(price - stopLossPrice) / point;
   if(slPoints <= 0.0)
      return(0.0);

   double moneyPerPointPerLot = tickValue / (tickSize / point);
   double lot = riskMoney / (slPoints * moneyPerPointPerLot);

   double minLot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);

   lot = MathMax(minLot, MathMin(maxLot, lot));
   if(lotStep > 0.0)
      lot = MathFloor(lot / lotStep) * lotStep;

   int volumeDigits = 2;
   if(lotStep > 0.0)
     {
      double tmpStep = lotStep;
      volumeDigits   = 0;
      while(tmpStep < 1.0 && volumeDigits < 8)
        {
         tmpStep *= 10.0;
         volumeDigits++;
        }
     }

   return(NormalizeDouble(lot, volumeDigits));
  }

//+------------------------------------------------------------------+
//| Open position with given order type                              |
//+------------------------------------------------------------------+
bool OpenPosition(const ENUM_ORDER_TYPE orderType,
                  const double           riskPercent,
                  const double           confidence)
  {
   string symbol = TradeSymbol;
   double effAtr = (UseWebSettings && g_webSettingsLoaded) ? g_atrSLFactor : AtrSLFactor;
   double effRR  = (UseWebSettings && g_webSettingsLoaded) ? g_baseRR : BaseRR;

   double bid   = SymbolInfoDouble(symbol, SYMBOL_BID);
   double ask   = SymbolInfoDouble(symbol, SYMBOL_ASK);
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);

   if(bid <= 0.0 || ask <= 0.0 || point <= 0.0)
      return(false);

   // Determine SL based on ATR and recent swing
   int    atrPeriod  = 14;
   double atr        = GetAtr(symbol, EntryTF, atrPeriod);
   double atrPoints  = atr / point;
   double slDistancePoints = atrPoints * effAtr;

   if(slDistancePoints <= 0.0)
      return(false);

   double slPrice, tpPrice, entryPrice;
   if(orderType == ORDER_TYPE_BUY)
     {
      entryPrice = ask;
      slPrice    = entryPrice - slDistancePoints * point;
     }
   else
     {
      entryPrice = bid;
      slPrice    = entryPrice + slDistancePoints * point;
     }

   // Lot size
   double lot = CalculateLotSizeByRisk(symbol, riskPercent, slPrice);
   if(lot <= 0.0)
     {
      Print("Lot size calculated as 0. Check risk settings or SL distance.");
      WebLog("Lot size calculated as 0. Check risk settings or SL distance.", "error");
      return(false);
     }

   // TP based on BaseRR (or TP3_RR if multiple TP's enabled)
   double tpRR = UseMultipleTPs ? TP3_RR : effRR;
   double tpDistancePoints = slDistancePoints * tpRR;
   if(orderType == ORDER_TYPE_BUY)
      tpPrice = entryPrice + tpDistancePoints * point;
   else
      tpPrice = entryPrice - tpDistancePoints * point;

   slPrice = NormalizeDouble(slPrice, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS));
   tpPrice = NormalizeDouble(tpPrice, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS));

   trade.SetDeviationInPoints(50);

   bool result = false;
   if(orderType == ORDER_TYPE_BUY)
      result = trade.Buy(lot, symbol, entryPrice, slPrice, tpPrice, "XAUUSD_AI_EA BUY");
   else
      result = trade.Sell(lot, symbol, entryPrice, slPrice, tpPrice, "XAUUSD_AI_EA SELL");

   if(!result)
     {
      string errMsg = "Order send failed. Error " + IntegerToString(GetLastError());
      Print(errMsg);
      WebLog(errMsg, "error");
      return(false);
     }

   string openMsg = StringFormat("Opened %s %.2f lots at %.3f, SL=%.3f, TP=%.3f, RR=%.2f, confidence=%.2f",
                                orderType == ORDER_TYPE_BUY ? "BUY" : "SELL",
                                lot, entryPrice, slPrice, tpPrice, effRR, confidence);
   Print(openMsg);
   WebLog(openMsg);
   
   // Add TP tracking for new position (if multiple TP's enabled)
   if(UseMultipleTPs)
     {
      // Find the newly opened position by searching for matching symbol and magic number
      Sleep(100); // Small delay to ensure position is registered
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong posTicket = PositionGetTicket(i);
         if(posTicket > 0 && PositionSelectByTicket(posTicket))
           {
            string posSymbol = (string)PositionGetString(POSITION_SYMBOL);
            long posMagic = PositionGetInteger(POSITION_MAGIC);
            if(posSymbol == symbol && posMagic == trade.RequestMagic())
              {
               AddTPTracking(posTicket);
               break;
              }
           }
        }
     }
   
   return(true);
  }

//+------------------------------------------------------------------+
//| Manage trailing stop for open position                           |
//+------------------------------------------------------------------+
void ManageTrailingStop(const string symbol)
  {
   for(int i = PositionsTotal() - 1; i >= 0; --i)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;

      string posSymbol = (string)PositionGetString(POSITION_SYMBOL);
      if(posSymbol != symbol)
         continue;

      long   type      = PositionGetInteger(POSITION_TYPE);
      double volume    = PositionGetDouble(POSITION_VOLUME);
      double priceOpen = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl        = PositionGetDouble(POSITION_SL);
      double tp        = PositionGetDouble(POSITION_TP);

      if(volume <= 0.0)
         continue;

      double bid  = SymbolInfoDouble(symbol, SYMBOL_BID);
      double ask  = SymbolInfoDouble(symbol, SYMBOL_ASK);
      double point = SymbolInfoDouble(symbol, SYMBOL_POINT);

      if(point <= 0.0)
         continue;

      double currentPrice = (type == POSITION_TYPE_BUY ? bid : ask);
      double slDistancePoints = MathAbs(priceOpen - sl) / point;
      if(slDistancePoints <= 0.0)
         continue;

      double profitPoints = (type == POSITION_TYPE_BUY ?
                             (currentPrice - priceOpen) / point :
                             (priceOpen - currentPrice) / point);

      double currentRR = profitPoints / slDistancePoints;
      if(currentRR < TrailStartRR)
         continue;

      double newSl;
      if(type == POSITION_TYPE_BUY)
         newSl = currentPrice - TrailStepPoints * point;
      else
         newSl = currentPrice + TrailStepPoints * point;

      // ensure SL only moves in favorable direction
      if(type == POSITION_TYPE_BUY && newSl <= sl)
         continue;
      if(type == POSITION_TYPE_SELL && newSl >= sl)
         continue;

      newSl = NormalizeDouble(newSl, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS));

      if(!trade.PositionModify(symbol, newSl, tp))
        {
         string modErr = "Failed to modify position for trailing stop. Error " + IntegerToString(GetLastError());
         Print(modErr);
         WebLog(modErr, "warn");
        }
      else
        {
         string trailMsg = StringFormat("Trailing stop moved. Ticket=%I64u, new SL=%.3f", ticket, newSl);
         Print(trailMsg);
         WebLog(trailMsg);
        }
     }
  }

//+------------------------------------------------------------------+
//| Find index in TP tracking array for given ticket                 |
//+------------------------------------------------------------------+
int FindTPTrackingIndex(ulong ticket)
  {
   int size = ArraySize(tpTracking);
   for(int i = 0; i < size; i++)
     {
      if(tpTracking[i].ticket == ticket)
         return(i);
     }
   return(-1);
  }

//+------------------------------------------------------------------+
//| Add new TP tracking entry for a position                          |
//+------------------------------------------------------------------+
void AddTPTracking(ulong ticket)
  {
   int size = ArraySize(tpTracking);
   ArrayResize(tpTracking, size + 1);
   tpTracking[size].ticket = ticket;
   tpTracking[size].tp1Hit = false;
   tpTracking[size].tp2Hit = false;
   tpTracking[size].tp3Hit = false;
  }

//+------------------------------------------------------------------+
//| Manage partial TP closing (TP1, TP2, TP3)                       |
//+------------------------------------------------------------------+
void ManagePartialTPs(const string symbol)
  {
   if(!UseMultipleTPs)
      return;

   for(int i = PositionsTotal() - 1; i >= 0; --i)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;

      string posSymbol = (string)PositionGetString(POSITION_SYMBOL);
      if(posSymbol != symbol)
         continue;

      long   type      = PositionGetInteger(POSITION_TYPE);
      double volume    = PositionGetDouble(POSITION_VOLUME);
      double priceOpen = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl        = PositionGetDouble(POSITION_SL);

      if(volume <= 0.0)
         continue;

      // Find or create tracking entry
      int trackIdx = FindTPTrackingIndex(ticket);
      if(trackIdx < 0)
        {
         AddTPTracking(ticket);
         trackIdx = ArraySize(tpTracking) - 1;
        }

      double bid   = SymbolInfoDouble(symbol, SYMBOL_BID);
      double ask   = SymbolInfoDouble(symbol, SYMBOL_ASK);
      double point = SymbolInfoDouble(symbol, SYMBOL_POINT);

      if(point <= 0.0)
         continue;

      double currentPrice = (type == POSITION_TYPE_BUY ? bid : ask);
      double slDistancePoints = MathAbs(priceOpen - sl) / point;
      if(slDistancePoints <= 0.0)
         continue;

      double profitPoints = (type == POSITION_TYPE_BUY ?
                             (currentPrice - priceOpen) / point :
                             (priceOpen - currentPrice) / point);

      double currentRR = profitPoints / slDistancePoints;

      // Calculate TP price levels based on RR
      double tp1Price, tp2Price, tp3Price;
      if(type == POSITION_TYPE_BUY)
        {
         tp1Price = priceOpen + (slDistancePoints * TP1_RR) * point;
         tp2Price = priceOpen + (slDistancePoints * TP2_RR) * point;
         tp3Price = priceOpen + (slDistancePoints * TP3_RR) * point;
        }
      else
        {
         tp1Price = priceOpen - (slDistancePoints * TP1_RR) * point;
         tp2Price = priceOpen - (slDistancePoints * TP2_RR) * point;
         tp3Price = priceOpen - (slDistancePoints * TP3_RR) * point;
        }

      // Check TP1
      if(!tpTracking[trackIdx].tp1Hit)
        {
         bool tp1Reached = (type == POSITION_TYPE_BUY && currentPrice >= tp1Price) ||
                           (type == POSITION_TYPE_SELL && currentPrice <= tp1Price);
         if(tp1Reached)
           {
            double closeVolume = NormalizeDouble(volume * (TP1_Percent / 100.0), 2);
            double minLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
            double lotStep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
            if(lotStep > 0.0)
               closeVolume = MathFloor(closeVolume / lotStep) * lotStep;
            closeVolume = MathMax(minLot, closeVolume);

            if(closeVolume >= minLot && closeVolume < volume)
              {
               if(trade.PositionClosePartial(ticket, closeVolume))
                 {
                  tpTracking[trackIdx].tp1Hit = true;
                  string tp1Msg = StringFormat("TP1 hit! Closed %.2f lots (%.1f%%) at %.3f, RR=%.2f",
                                               closeVolume, TP1_Percent, currentPrice, currentRR);
                  Print(tp1Msg);
                  WebLog(tp1Msg);
                 }
              }
           }
        }

      // Check TP2
      if(!tpTracking[trackIdx].tp2Hit && tpTracking[trackIdx].tp1Hit)
        {
         bool tp2Reached = (type == POSITION_TYPE_BUY && currentPrice >= tp2Price) ||
                           (type == POSITION_TYPE_SELL && currentPrice <= tp2Price);
         if(tp2Reached)
           {
            // Get remaining volume after TP1
            double remainingVolume = PositionGetDouble(POSITION_VOLUME);
            double closeVolume = NormalizeDouble(remainingVolume * (TP2_Percent / 100.0), 2);
            double minLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
            double lotStep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
            if(lotStep > 0.0)
               closeVolume = MathFloor(closeVolume / lotStep) * lotStep;
            closeVolume = MathMax(minLot, closeVolume);

            if(closeVolume >= minLot && closeVolume < remainingVolume)
              {
               if(trade.PositionClosePartial(ticket, closeVolume))
                 {
                  tpTracking[trackIdx].tp2Hit = true;
                  string tp2Msg = StringFormat("TP2 hit! Closed %.2f lots (%.1f%%) at %.3f, RR=%.2f",
                                               closeVolume, TP2_Percent, currentPrice, currentRR);
                  Print(tp2Msg);
                  WebLog(tp2Msg);
                 }
              }
           }
        }

      // Check TP3
      if(!tpTracking[trackIdx].tp3Hit && tpTracking[trackIdx].tp1Hit && tpTracking[trackIdx].tp2Hit)
        {
         bool tp3Reached = (type == POSITION_TYPE_BUY && currentPrice >= tp3Price) ||
                           (type == POSITION_TYPE_SELL && currentPrice <= tp3Price);
         if(tp3Reached)
           {
            // Close remaining volume (rest)
            double remainingVolume = PositionGetDouble(POSITION_VOLUME);
            double minLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
            if(remainingVolume >= minLot)
              {
               if(trade.PositionClose(ticket))
                 {
                  tpTracking[trackIdx].tp3Hit = true;
                  string tp3Msg = StringFormat("TP3 hit! Closed remaining %.2f lots at %.3f, RR=%.2f",
                                               remainingVolume, currentPrice, currentRR);
                  Print(tp3Msg);
                  WebLog(tp3Msg);
                 }
              }
           }
        }
     }

   // Clean up tracking for closed positions
   int size = ArraySize(tpTracking);
   for(int j = size - 1; j >= 0; j--)
     {
      bool positionExists = false;
      for(int k = PositionsTotal() - 1; k >= 0; k--)
        {
         ulong t = PositionGetTicket(k);
         if(t == tpTracking[j].ticket)
           {
            positionExists = true;
            break;
           }
        }
      if(!positionExists)
        {
         // Remove from array
         for(int m = j; m < size - 1; m++)
            tpTracking[m] = tpTracking[m + 1];
         ArrayResize(tpTracking, size - 1);
         size--;
        }
     }
  }

//+------------------------------------------------------------------+
//| Parse a double value from JSON string (simple "key":value)       |
//+------------------------------------------------------------------+
double ParseJsonDouble(const string json, const string key)
  {
   string search = "\"" + key + "\":";
   int pos = StringFind(json, search);
   if(pos < 0)
      return(0.0);
   int start = pos + StringLen(search);
   int end   = start;
   int len   = StringLen(json);
   while(end < len)
     {
      ushort c = (ushort)StringGetCharacter(json, end);
      if(c == '.' || c == '-' || (c >= '0' && c <= '9'))
         end++;
      else
         break;
     }
   if(end <= start)
      return(0.0);
   return((double)StringToDouble(StringSubstr(json, start, end - start)));
  }

//+------------------------------------------------------------------+
//| Parse a bool from JSON ("key":true/false)                        |
//+------------------------------------------------------------------+
bool ParseJsonBool(const string json, const string key)
  {
   string search = "\"" + key + "\":";
   int pos = StringFind(json, search);
   if(pos < 0)
      return(false);
   int start = pos + StringLen(search);
   if(StringFind(json, "true", start) == start)
      return(true);
   return(false);
  }

//+------------------------------------------------------------------+
//| Fetch settings from web API (GET)                                |
//+------------------------------------------------------------------+
bool FetchWebSettings()
  {
   if(StringLen(WebSettingsUrl) < 10)
      return(false);

   uchar data[];
   ArrayResize(data, 0);
   uchar result[];
   string resultHeaders;
   string headers = "";
   int timeout = 5000;

   if(WebRequest("GET", WebSettingsUrl, headers, timeout, data, result, resultHeaders) == -1)
      return(false);

   int n = ArraySize(result);
   if(n <= 0)
      return(false);

   string json = CharArrayToString(result, 0, n, CP_UTF8);

   g_riskPercent     = ParseJsonDouble(json, "riskPercent");
   if(g_riskPercent <= 0.0)
      g_riskPercent = 2.0;
   g_minConfidence   = ParseJsonDouble(json, "minConfidence");
   if(g_minConfidence < 0.0)
      g_minConfidence = 70.0;
   g_atrSLFactor     = ParseJsonDouble(json, "atrSLFactor");
   if(g_atrSLFactor <= 0.0)
      g_atrSLFactor = 2.5;
   g_baseRR          = ParseJsonDouble(json, "baseRR");
   if(g_baseRR <= 0.0)
      g_baseRR = 2.0;
   g_placeTestTrade  = ParseJsonBool(json, "placeTestTrade");
   g_useTrailingStop = ParseJsonBool(json, "useTrailingStop");
   if(StringFind(json, "tradingEnabled") >= 0)
      g_tradingEnabled = ParseJsonBool(json, "tradingEnabled");
   else
      g_tradingEnabled = true;

   g_webSettingsLoaded = true;
   return(true);
  }

//+------------------------------------------------------------------+
//| Escape string for JSON (backslash and double quote)               |
//+------------------------------------------------------------------+
string JsonEscape(const string s)
  {
   string out = s;
   StringReplace(out, "\\", "\\\\");
   StringReplace(out, "\"", "\\\"");
   return(out);
  }

//+------------------------------------------------------------------+
//| Send heartbeat to command center (account + open positions)       |
//+------------------------------------------------------------------+
void SendHeartbeat()
  {
   if(StringLen(WebHeartbeatUrl) < 10)
      return;

   long   accountId   = AccountInfoInteger(ACCOUNT_LOGIN);
   string hostname    = JsonEscape(TerminalInfoString(TERMINAL_NAME));
   string serverName  = JsonEscape(AccountInfoString(ACCOUNT_SERVER));
   double balance    = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity     = AccountInfoDouble(ACCOUNT_EQUITY);
   double margin     = AccountInfoDouble(ACCOUNT_MARGIN);
   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);

   string tradesJson = "";
   double totalProfit = 0.0;
   int count = PositionsTotal();
   for(int i = count - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      string symRaw = (string)PositionGetString(POSITION_SYMBOL);
      string sym    = JsonEscape(symRaw);
      long   type   = PositionGetInteger(POSITION_TYPE);
      double vol    = PositionGetDouble(POSITION_VOLUME);
      double openP  = PositionGetDouble(POSITION_PRICE_OPEN);
      double profit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      double sl     = PositionGetDouble(POSITION_SL);
      double tp     = PositionGetDouble(POSITION_TP);
      double curP   = (type == POSITION_TYPE_BUY) ? SymbolInfoDouble(symRaw, SYMBOL_BID) : SymbolInfoDouble(symRaw, SYMBOL_ASK);
      totalProfit  += profit;
      if(StringLen(tradesJson) > 0)
         tradesJson += ",";
      tradesJson += "{\"symbol\":\"" + sym + "\",\"type\":" + IntegerToString((int)type) +
                    ",\"volume\":" + DoubleToString(vol, 2) + ",\"openPrice\":" + DoubleToString(openP, 5) +
                    ",\"currentPrice\":" + DoubleToString(curP, 5) + ",\"profit\":" + DoubleToString(profit, 2) +
                    ",\"sl\":" + DoubleToString(sl, 5) + ",\"tp\":" + DoubleToString(tp, 5) +
                    ",\"ticket\":" + IntegerToString((int)ticket) + "}";
     }

   string body = "{\"accountId\":" + IntegerToString((int)accountId) +
                 ",\"hostname\":\"" + hostname + "\"" +
                 ",\"serverName\":\"" + serverName + "\"" +
                 ",\"balance\":" + DoubleToString(balance, 2) +
                 ",\"equity\":" + DoubleToString(equity, 2) +
                 ",\"margin\":" + DoubleToString(margin, 2) +
                 ",\"freeMargin\":" + DoubleToString(freeMargin, 2) +
                 ",\"floatingProfit\":" + DoubleToString(totalProfit, 2) +
                 ",\"openTrades\":[" + tradesJson + "]}";

   uchar data[];
   int len = StringToCharArray(body, data, 0, StringLen(body), CP_UTF8);
   if(len <= 0)
      return;
   if(data[len-1] == 0)
      ArrayResize(data, len - 1);
   else
      ArrayResize(data, len);

   string headers = "Content-Type: application/json\r\n";
   if(StringLen(WebLogSecret) > 0)
      headers += "X-API-Key: " + WebLogSecret + "\r\n";

   uchar result[];
   string resultHeaders;
   int timeout = 5000;
   if(WebRequest("POST", WebHeartbeatUrl, headers, timeout, data, result, resultHeaders) == -1)
      return;
  }

//+------------------------------------------------------------------+
//| Send log line to web API (api.aitrading.software)                |
//+------------------------------------------------------------------+
void WebLog(const string message, const string level = "info")
  {
   if(!UseWebLog || StringLen(WebLogUrl) < 10)
      return;

   string escaped = message;
   StringReplace(escaped, "\\", "\\\\");
   StringReplace(escaped, "\"", "\\\"");

   string timeStr = TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS);
   StringReplace(timeStr, ".", "-");

   string body = "{\"message\":\"" + escaped + "\",\"level\":\"" + level +
                  "\",\"time\":\"" + timeStr + "\",\"symbol\":\"" + TradeSymbol +
                  "\",\"source\":\"XAUUSD_AI_EA\"}";

   uchar data[];
   int len = StringToCharArray(body, data, 0, StringLen(body), CP_UTF8);
   if(len <= 0)
      return;
   if(data[len-1] == 0)
      ArrayResize(data, len - 1);
   else
      ArrayResize(data, len);

   string headers = "Content-Type: application/json\r\n";
   if(StringLen(WebLogSecret) > 0)
      headers += "X-API-Key: " + WebLogSecret + "\r\n";

   uchar result[];
   string resultHeaders;
   int timeout = 5000;
   if(WebRequest("POST", WebLogUrl, headers, timeout, data, result, resultHeaders) == -1)
      return;  // silent fail: MT5 may block URL or network error
  }

//+------------------------------------------------------------------+
//| V2: Check if news blocking is active                            |
//+------------------------------------------------------------------+
bool CheckNewsBlock()
  {
   datetime now = TimeCurrent();
   
   // Check news API every 5 minutes
   if(now - g_lastNewsCheck >= 300)
     {
      g_lastNewsCheck = now;
      FetchNewsEvents();
     }
   
   // Check if we're in news block window
   if(g_newsBlockActive && g_nextNewsTime > 0)
     {
      datetime blockStart = g_nextNewsTime - (NewsBlockMinutes * 60);
      datetime blockEnd   = g_nextNewsTime + (NewsBlockMinutes * 60);
      
      if(now >= blockStart && now <= blockEnd)
         return(true);
     }
   
   return(false);
  }

//+------------------------------------------------------------------+
//| V2: Fetch news events from API                                  |
//+------------------------------------------------------------------+
bool FetchNewsEvents()
  {
   if(StringLen(NewsApiUrl) < 10)
      return(false);
   
   uchar data[];
   ArrayResize(data, 0);
   uchar result[];
   string resultHeaders;
   string headers = "";
   if(StringLen(WebLogSecret) > 0)
      headers = "X-API-Key: " + WebLogSecret + "\r\n";
   int timeout = 5000;
   
   if(WebRequest("GET", NewsApiUrl, headers, timeout, data, result, resultHeaders) == -1)
      return(false);
   
   int n = ArraySize(result);
   if(n <= 0)
      return(false);
   
   string json = CharArrayToString(result, 0, n, CP_UTF8);
   
   // Parse JSON: {"hasNews":true,"nextEvent":"NFP","nextTime":1234567890}
   bool hasNews = ParseJsonBool(json, "hasNews");
   if(hasNews)
     {
      g_newsBlockActive = true;
      g_nextNewsEvent = "High-impact USD news";
      g_nextNewsTime = (datetime)ParseJsonDouble(json, "nextTime");
     }
   else
     {
      g_newsBlockActive = false;
      g_nextNewsTime = 0;
     }
   
   return(true);
  }

//+------------------------------------------------------------------+
//| V2: Check if current time is in blocked window                  |
//+------------------------------------------------------------------+
bool IsTimeBlocked()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   
   int currentHour = dt.hour;
   int currentMin  = dt.min;
   
   // Convert to CET (assuming server time is already CET or adjust)
   int blockStartTotal = BlockStartHour * 60 + BlockStartMin;
   int blockEndTotal   = BlockEndHour * 60 + BlockEndMin;
   int currentTotal    = currentHour * 60 + currentMin;
   
   if(blockStartTotal <= blockEndTotal)
     {
      // Normal case: same day block
      if(currentTotal >= blockStartTotal && currentTotal <= blockEndTotal)
         return(true);
     }
   else
     {
      // Overnight block
      if(currentTotal >= blockStartTotal || currentTotal <= blockEndTotal)
         return(true);
     }
   
   return(false);
  }

//+------------------------------------------------------------------+
//| V2: Check if today is NFP Friday (first Friday of month)        |
//+------------------------------------------------------------------+
bool IsNFPFriday()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   
   // Check if it's Friday
   if(dt.day_of_week != 5) // 5 = Friday
      return(false);
   
   // Check if it's in first week of month (day 1-7)
   if(dt.day >= 1 && dt.day <= 7)
      return(true);
   
   return(false);
  }

//+------------------------------------------------------------------+
//| V2: Check ATR volatility against historical average             |
//+------------------------------------------------------------------+
bool CheckAtrVolatility()
  {
   if(g_atrAverage <= 0.0)
      return(true); // No data yet, allow trade
   
   double currentAtr = GetAtr(TradeSymbol, EntryTF, 14);
   if(currentAtr <= 0.0)
      return(true);
   
   double threshold = g_atrAverage * AtrVolatilityMultiplier;
   if(currentAtr > threshold)
      return(false); // Too volatile
   
   return(true);
  }

//+------------------------------------------------------------------+
//| V2: Check spread ratio against normal                           |
//+------------------------------------------------------------------+
bool CheckSpreadRatio()
  {
   double currentSpread = (double)SymbolInfoInteger(TradeSymbol, SYMBOL_SPREAD);
   double threshold = NormalSpreadPoints * SpreadRatioMultiplier;
   
   if(currentSpread > threshold)
      return(false); // Spread too high
   
   return(true);
  }

//+------------------------------------------------------------------+
//| V2: Update ATR average over last N days                         |
//+------------------------------------------------------------------+
void UpdateAtrAverage()
  {
   double totalAtr = 0.0;
   int count = 0;
   int barsNeeded = AtrHistoryDays * 24 * 12; // Assuming H1, adjust if needed
   
   double atrBuffer[];
   int handle = iATR(TradeSymbol, PERIOD_H1, 14);
   if(handle == INVALID_HANDLE)
      return;
   
   if(ArraySetAsSeries(atrBuffer, true) && CopyBuffer(handle, 0, 0, barsNeeded, atrBuffer) > 0)
     {
      int size = ArraySize(atrBuffer);
      for(int i = 0; i < size && i < barsNeeded; i++)
        {
         if(atrBuffer[i] > 0.0)
           {
            totalAtr += atrBuffer[i];
            count++;
           }
        }
     }
   
   IndicatorRelease(handle);
   
   if(count > 0)
      g_atrAverage = totalAtr / count;
  }

//+------------------------------------------------------------------+
//| V2: Get week range percentage (0-100)                           |
//+------------------------------------------------------------------+
double GetWeekRangePercent(const string symbol)
  {
   double high[], low[];
   datetime times[];
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   ArraySetAsSeries(times, true);
   
   // Get weekly high/low (last 7 days = ~1 week)
   int bars = 7 * 24 * 12; // H1 bars for 7 days
   if(CopyHigh(symbol, PERIOD_H1, 0, bars, high) <= 0 ||
      CopyLow(symbol, PERIOD_H1, 0, bars, low) <= 0)
      return(50.0); // Default to middle
   
   double weekHigh = high[ArrayMaximum(high)];
   double weekLow  = low[ArrayMinimum(low)];
   double currentPrice = SymbolInfoDouble(symbol, SYMBOL_BID);
   
   if(weekHigh <= weekLow)
      return(50.0);
   
   double range = weekHigh - weekLow;
   double position = currentPrice - weekLow;
   double percent = (position / range) * 100.0;
   
   return(MathMax(0.0, MathMin(100.0, percent)));
  }

//+------------------------------------------------------------------+
//| V2: Get D1 trend direction (200 EMA)                            |
//+------------------------------------------------------------------+
int GetD1TrendDirection(const string symbol)
  {
   double maBuffer[2];
   int handle = iMA(symbol, PERIOD_D1, D1MaPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if(handle == INVALID_HANDLE)
      return(0);
   
   if(CopyBuffer(handle, 0, 0, 2, maBuffer) != 2)
     {
      IndicatorRelease(handle);
      return(0);
     }
   
   IndicatorRelease(handle);
   
   double maCurrent = maBuffer[0];
   double maPrev    = maBuffer[1];
   double currentPrice = SymbolInfoDouble(symbol, SYMBOL_BID);
   
   // Check if price is above/below MA and MA direction
   if(currentPrice > maCurrent && maCurrent > maPrev)
      return(1); // Uptrend
   else if(currentPrice < maCurrent && maCurrent < maPrev)
      return(-1); // Downtrend
   
   return(0); // No clear trend
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
