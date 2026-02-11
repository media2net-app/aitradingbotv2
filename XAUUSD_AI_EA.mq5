//+------------------------------------------------------------------+
//|                                                  XAUUSD_AI_EA.mq5|
//|       Simple XAUUSD AI-style trading EA skeleton                 |
//|       Uses indicator logic + confidence score, AI-ready stub     |
//|                                                                  |
//|  VPS (MQL5): 1) Attach to XAUUSD M15 chart. 2) Enable AutoTrading.|
//|  3) Account Navigator > right-click account > Migrate > Migrate  |
//|  All. 4) Check VPS Journal for "[VPS] ... OK" heartbeat each hour.|
//+------------------------------------------------------------------+
#property copyright "BUILD4POWER"
#property link      "https://www.mql5.com/"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

//--- trade object
CTrade trade;

//+------------------------------------------------------------------+
//| Input parameters                                                 |
//+------------------------------------------------------------------+
input string           TradeSymbol      = "XAUUSD";        // Trading symbol
input ENUM_TIMEFRAMES  EntryTF          = PERIOD_M15;      // Entry timeframe
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
input double           BaseRR           = 2.0;             // Base Risk:Reward for TP
input bool             UseTrailingStop  = true;            // Enable trailing stop
input double           TrailStartRR     = 1.0;             // Start trailing at this RR
input double           TrailStepPoints  = 300;             // Trailing step in points
input bool             ShowVPSHeartbeat = true;            // Log status periodically (for VPS monitoring)

//--- web log (api.aitrading.software)
input bool             UseWebLog        = false;           // Send logs to web dashboard
input string           WebLogUrl        = "https://api.aitrading.software/api/log";  // Log API URL
input string           WebLogSecret    = "";              // Optional: same as LOG_API_KEY on Vercel

//+------------------------------------------------------------------+
//| Global variables / handles                                       |
//+------------------------------------------------------------------+
int      atrHandleEntry   = INVALID_HANDLE;
int      rsiHandleEntry   = INVALID_HANDLE;
int      maHandleTrend    = INVALID_HANDLE;

datetime lastEntryBarTime = 0;   // To ensure once-per-bar logic on EntryTF
datetime lastHeartbeat    = 0;   // For VPS status log

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

// helpers
double   CalculateLotSizeByRisk(const string symbol,
                                const double  riskPercent,
                                const double  stopLossPrice);
void     WebLog(const string message, const string level = "info");

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

   string initMsg = "XAUUSD_AI_EA initialized. Symbol=" + TradeSymbol +
                    " EntryTF=" + EnumToString(EntryTF) + " TrendTF=" + EnumToString(TrendTF);
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
      // Still manage trailing stop on every tick
      if(UseTrailingStop)
         ManageTrailingStop(TradeSymbol);
      return;
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
      if(UseTrailingStop)
         ManageTrailingStop(TradeSymbol);
      return;
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

   // Confidence filter
   if(confidence < MinConfidence)
     {
      string confMsg = StringFormat("Confidence %.2f below MinConfidence %.2f, no trade.", confidence, MinConfidence);
      Print(confMsg);
      WebLog(confMsg);
      return;
     }

   ENUM_ORDER_TYPE orderType = (signalDir > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);

   if(!OpenPosition(orderType, RiskPercent, confidence))
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

   double bid   = SymbolInfoDouble(symbol, SYMBOL_BID);
   double ask   = SymbolInfoDouble(symbol, SYMBOL_ASK);
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);

   if(bid <= 0.0 || ask <= 0.0 || point <= 0.0)
      return(false);

   // Determine SL based on ATR and recent swing
   int    atrPeriod  = 14;
   double atr        = GetAtr(symbol, EntryTF, atrPeriod);
   double atrPoints  = atr / point;
   double slDistancePoints = atrPoints * AtrSLFactor;

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

   // TP based on BaseRR
   double tpDistancePoints = slDistancePoints * BaseRR;
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
                                lot, entryPrice, slPrice, tpPrice, BaseRR, confidence);
   Print(openMsg);
   WebLog(openMsg);
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

   if(!WebRequest("POST", WebLogUrl, headers, data))
      return;  // silent fail: MT5 may block URL or network error
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
