//+------------------------------------------------------------------+
//|                              MACD_Histogram_Momentum_EA.mq5     |
//|              MACD Histogram Momentum Acceleration Expert Advisor|
//|                                                                  |
//|  Strategy: Enters trades when MACD Histogram momentum is         |
//|  strengthening (direction + acceleration), confirmed by price    |
//|  action, rather than on a simple MACD/Signal crossover.          |
//+------------------------------------------------------------------+
#property copyright "Generated Expert Advisor"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\PositionInfo.mqh>

//====================================================================
// INPUT PARAMETERS
//====================================================================

// --- MACD
input group "=== MACD Parameters ==="
input int      FastEMA                   = 12;     // Fast EMA Period
input int      SlowEMA                   = 26;      // Slow EMA Period
input int      SignalPeriod              = 9;       // Signal EMA Period

// --- Momentum
input group "=== Momentum Filters ==="
input bool     UseZeroLineConfirmation   = true;    // Require Histogram beyond zero line
input bool     UseHistogramStrengthFilter= false;   // Require minimum histogram strength
input double   MinimumHistogramStrength  = 0.0;     // Minimum |Histogram| value required
input int      MomentumLookback          = 3;       // Number of completed candles compared (min 3)

// --- ATR Risk Management
input group "=== ATR Risk Management ==="
input int      ATRPeriod                 = 14;      // ATR Period
input double   StopLossATRMultiplier     = 1.5;     // Stop Loss ATR Multiplier
input double   TakeProfitATRMultiplier   = 3.0;     // Take Profit ATR Multiplier

// --- Position Sizing
input group "=== Position Sizing ==="
input bool     UseRiskBasedLot           = false;   // Use Risk-Based Lot Sizing
input double   RiskPercent               = 1.0;     // Risk percent of equity per trade
input double   FixedLot                  = 0.10;    // Fixed lot size
input double   MinLot                    = 0.01;    // Minimum allowed lot (risk-based clamp)
input double   MaxLot                    = 10.0;    // Maximum allowed lot (risk-based clamp)

// --- Exit
input group "=== Exit Logic ==="
input bool     UseMomentumExit           = true;    // Exit when momentum reverses
input bool     UseZeroLineExit           = false;   // Exit when histogram crosses zero line

// --- Trailing Stop
input group "=== Trailing Stop ==="
input bool     UseTrailingStop           = false;   // Enable ATR Trailing Stop
input double   TrailingStopATRMultiplier = 1.5;     // Trailing Stop ATR Multiplier

// --- Trading Control
input group "=== Trading Control ==="
input long     MagicNumber               = 20240602;// Unique Magic Number
input int      MaxPositions              = 1;       // Max simultaneous positions (this EA, this symbol)
input bool     AllowBuy                  = true;    // Allow BUY trades
input bool     AllowSell                 = true;    // Allow SELL trades
input int      SlippagePoints            = 30;      // Slippage (points)

//====================================================================
// GLOBAL VARIABLES
//====================================================================

CTrade         trade;
CSymbolInfo    symbolInfo;
CPositionInfo  positionInfo;

int            macdHandle = INVALID_HANDLE;
int            atrHandle  = INVALID_HANDLE;

datetime       lastBarTime = 0;
bool           initializedOk = false;

datetime       lastBuySignalBarTime  = 0;
datetime       lastSellSignalBarTime = 0;

int            effectiveLookback = 3; // MomentumLookback clamped to a safe minimum of 3

//+------------------------------------------------------------------+
//| Forward declarations                                              |
//+------------------------------------------------------------------+
bool   IsNewBar();
bool   GetMACDValues(double &mainArr[], double &signalArr[], int count);
bool   CalculateHistogramMomentum(double &hist1, double &hist2, double &hist3);
bool   GetATRValue(double &atrValue);
bool   CheckBuySignal(double &outHist1, double &outHist2);
bool   CheckSellSignal(double &outHist1, double &outHist2);
void   OpenBuy();
void   OpenSell();
void   ManagePositions();
void   CheckMomentumExit();
void   CheckZeroLineExit();
void   ApplyTrailingStop();
double CalculateLotSize(double stopLossDistancePrice);
int    CountOwnPositions(int direction);
bool   IsOwnPosition();
double NormalizeVolume(double volume);
double NormalizePrice(double price);
bool   ValidateStops(bool isBuy, double entryPrice, double &sl, double &tp);

//+------------------------------------------------------------------+
//| Expert initialization function                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   initializedOk = false;

   if(!symbolInfo.Name(_Symbol))
   {
      Print("ERROR: Failed to initialize SymbolInfo for ", _Symbol);
      return(INIT_FAILED);
   }

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetAsyncMode(false);

   if(FastEMA <= 0 || SlowEMA <= 0 || SignalPeriod <= 0)
   {
      Print("ERROR: MACD periods must be greater than zero.");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(FastEMA >= SlowEMA)
   {
      Print("ERROR: FastEMA must be less than SlowEMA.");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(ATRPeriod <= 0)
   {
      Print("ERROR: ATRPeriod must be greater than zero.");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(StopLossATRMultiplier <= 0)
   {
      Print("ERROR: StopLossATRMultiplier must be greater than zero.");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(FixedLot <= 0 && !UseRiskBasedLot)
   {
      Print("ERROR: FixedLot must be greater than zero when UseRiskBasedLot is false.");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(UseRiskBasedLot && RiskPercent <= 0)
   {
      Print("ERROR: RiskPercent must be greater than zero when UseRiskBasedLot is true.");
      return(INIT_PARAMETERS_INCORRECT);
   }

   effectiveLookback = MathMax(MomentumLookback, 3);

   macdHandle = iMACD(_Symbol, _Period, FastEMA, SlowEMA, SignalPeriod, PRICE_CLOSE);
   if(macdHandle == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create MACD indicator handle. Error code: ", GetLastError());
      return(INIT_FAILED);
   }

   atrHandle = iATR(_Symbol, _Period, ATRPeriod);
   if(atrHandle == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create ATR indicator handle. Error code: ", GetLastError());
      IndicatorRelease(macdHandle);
      macdHandle = INVALID_HANDLE;
      return(INIT_FAILED);
   }

   MqlRates rates[];
   if(CopyRates(_Symbol, _Period, 0, 1, rates) > 0)
      lastBarTime = rates[0].time;
   else
      lastBarTime = 0;

   initializedOk = true;
   Print("EA initialized successfully. Symbol=", _Symbol, " Period=", EnumToString(_Period),
         " Magic=", MagicNumber, " FastEMA=", FastEMA, " SlowEMA=", SlowEMA,
         " SignalPeriod=", SignalPeriod, " MomentumLookback=", effectiveLookback);

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(macdHandle != INVALID_HANDLE)
   {
      IndicatorRelease(macdHandle);
      macdHandle = INVALID_HANDLE;
   }
   if(atrHandle != INVALID_HANDLE)
   {
      IndicatorRelease(atrHandle);
      atrHandle = INVALID_HANDLE;
   }
   Print("EA deinitialized. Reason code: ", reason);
}

//+------------------------------------------------------------------+
//| Expert tick function                                              |
//+------------------------------------------------------------------+
void OnTick()
{
   if(!initializedOk)
      return;

   if(!symbolInfo.RefreshRates())
      return;

   // Manage existing positions (exits + trailing) every tick for responsiveness.
   ManagePositions();

   if(!IsNewBar())
      return;

   long tradeMode = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
   if(tradeMode == SYMBOL_TRADE_MODE_DISABLED)
   {
      Print("Trading disabled for symbol ", _Symbol, ". Skipping signal evaluation.");
      return;
   }

   double hist1 = 0.0, hist2 = 0.0;

   bool buySignal  = AllowBuy  && CheckBuySignal(hist1, hist2);
   bool sellSignal = AllowSell && CheckSellSignal(hist1, hist2);

   MqlRates rates[];
   if(CopyRates(_Symbol, _Period, 1, 1, rates) <= 0)
   {
      Print("ERROR: Failed to copy rates for signal bar identification. Error: ", GetLastError());
      return;
   }
   datetime signalBarTime = rates[0].time;

   int totalOwn = CountOwnPositions(-1);

   if(buySignal && lastBuySignalBarTime != signalBarTime)
   {
      if(totalOwn < MaxPositions && CountOwnPositions(0) == 0)
      {
         Print("BUY signal detected (momentum strengthening). Bar time: ", TimeToString(signalBarTime),
               " Hist[1]=", hist1, " Hist[2]=", hist2);
         OpenBuy();
      }
      lastBuySignalBarTime = signalBarTime;
   }

   if(sellSignal && lastSellSignalBarTime != signalBarTime)
   {
      if(totalOwn < MaxPositions && CountOwnPositions(1) == 0)
      {
         Print("SELL signal detected (momentum strengthening). Bar time: ", TimeToString(signalBarTime),
               " Hist[1]=", hist1, " Hist[2]=", hist2);
         OpenSell();
      }
      lastSellSignalBarTime = signalBarTime;
   }
}

//+------------------------------------------------------------------+
//| Detect a new completed bar                                        |
//+------------------------------------------------------------------+
bool IsNewBar()
{
   datetime currentBarTime = iTime(_Symbol, _Period, 0);
   if(currentBarTime == 0)
      return(false);

   if(currentBarTime != lastBarTime)
   {
      lastBarTime = currentBarTime;
      return(true);
   }
   return(false);
}

//+------------------------------------------------------------------+
//| Retrieve MACD main and signal buffers, 'count' values as series   |
//| starting at shift 1 (previous completed candle).                  |
//+------------------------------------------------------------------+
bool GetMACDValues(double &mainArr[], double &signalArr[], int count)
{
   if(macdHandle == INVALID_HANDLE)
   {
      Print("ERROR: MACD handle is invalid.");
      return(false);
   }

   ArraySetAsSeries(mainArr, true);
   ArraySetAsSeries(signalArr, true);

   int copiedMain   = CopyBuffer(macdHandle, 0, 1, count, mainArr);   // MACD main line, buffer 0
   int copiedSignal = CopyBuffer(macdHandle, 1, 1, count, signalArr); // MACD signal line, buffer 1

   if(copiedMain <= 0 || copiedSignal <= 0 || copiedMain < count || copiedSignal < count)
   {
      Print("ERROR: CopyBuffer failed for MACD. Error: ", GetLastError());
      return(false);
   }

   return(true);
}

//+------------------------------------------------------------------+
//| Calculate Histogram[1], Histogram[2], Histogram[3] from           |
//| completed candles only (shift 1 = most recently completed).       |
//+------------------------------------------------------------------+
bool CalculateHistogramMomentum(double &hist1, double &hist2, double &hist3)
{
   int needed = MathMax(effectiveLookback, 3);

   double mainArr[];
   double signalArr[];

   if(!GetMACDValues(mainArr, signalArr, needed))
      return(false);

   // Index 0 in these series-ordered arrays corresponds to shift 1 (most recent completed candle).
   hist1 = mainArr[0] - signalArr[0]; // Histogram[1]
   hist2 = mainArr[1] - signalArr[1]; // Histogram[2]
   hist3 = mainArr[2] - signalArr[2]; // Histogram[3]

   return(true);
}

//+------------------------------------------------------------------+
//| Retrieve current ATR value from the previous completed candle     |
//+------------------------------------------------------------------+
bool GetATRValue(double &atrValue)
{
   atrValue = 0.0;

   if(atrHandle == INVALID_HANDLE)
   {
      Print("ERROR: ATR handle is invalid.");
      return(false);
   }

   double buffer[];
   ArraySetAsSeries(buffer, true);

   int copied = CopyBuffer(atrHandle, 0, 1, 1, buffer);
   if(copied <= 0)
   {
      Print("ERROR: CopyBuffer failed for ATR. Error: ", GetLastError());
      return(false);
   }

   atrValue = buffer[0];
   return(atrValue > 0.0);
}

//+------------------------------------------------------------------+
//| Check BUY signal: histogram positive, increasing, accelerating,   |
//| and confirmed by a bullish completed candle.                      |
//+------------------------------------------------------------------+
bool CheckBuySignal(double &outHist1, double &outHist2)
{
   double hist1 = 0.0, hist2 = 0.0, hist3 = 0.0;
   if(!CalculateHistogramMomentum(hist1, hist2, hist3))
      return(false);

   outHist1 = hist1;
   outHist2 = hist2;

   if(UseZeroLineConfirmation && hist1 <= 0.0)
      return(false);

   if(UseHistogramStrengthFilter && hist1 < MinimumHistogramStrength)
      return(false);

   // Condition 2: histogram increasing
   if(!(hist1 > hist2))
      return(false);

   // Condition 3: momentum acceleration
   if(!((hist1 - hist2) > (hist2 - hist3)))
      return(false);

   // Condition 4: price confirmation on the latest completed candle
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, _Period, 1, 1, rates) <= 0)
   {
      Print("ERROR: Failed to copy previous completed candle for BUY price confirmation. Error: ", GetLastError());
      return(false);
   }

   if(!(rates[0].close > rates[0].open))
      return(false);

   return(true);
}

//+------------------------------------------------------------------+
//| Check SELL signal: histogram negative, decreasing, accelerating   |
//| bearishly, and confirmed by a bearish completed candle.           |
//+------------------------------------------------------------------+
bool CheckSellSignal(double &outHist1, double &outHist2)
{
   double hist1 = 0.0, hist2 = 0.0, hist3 = 0.0;
   if(!CalculateHistogramMomentum(hist1, hist2, hist3))
      return(false);

   outHist1 = hist1;
   outHist2 = hist2;

   if(UseZeroLineConfirmation && hist1 >= 0.0)
      return(false);

   if(UseHistogramStrengthFilter && hist1 > -MinimumHistogramStrength)
      return(false);

   // Condition 2: histogram decreasing
   if(!(hist1 < hist2))
      return(false);

   // Condition 3: bearish momentum acceleration
   if(!((hist1 - hist2) < (hist2 - hist3)))
      return(false);

   // Condition 4: price confirmation on the latest completed candle
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, _Period, 1, 1, rates) <= 0)
   {
      Print("ERROR: Failed to copy previous completed candle for SELL price confirmation. Error: ", GetLastError());
      return(false);
   }

   if(!(rates[0].close < rates[0].open))
      return(false);

   return(true);
}

//+------------------------------------------------------------------+
//| Open a BUY position                                                |
//+------------------------------------------------------------------+
void OpenBuy()
{
   double atrValue = 0.0;
   if(!GetATRValue(atrValue))
   {
      Print("ERROR: Invalid ATR value. Aborting BUY order.");
      return;
   }

   if(!symbolInfo.RefreshRates())
   {
      Print("ERROR: Failed to refresh symbol rates before BUY execution.");
      return;
   }

   double entryPrice = symbolInfo.Ask();
   double sl = entryPrice - (atrValue * StopLossATRMultiplier);
   double tp = entryPrice + (atrValue * TakeProfitATRMultiplier);

   if(!ValidateStops(true, entryPrice, sl, tp))
   {
      Print("ERROR: Invalid SL/TP computed for BUY. Aborting order. SL=", sl, " TP=", tp);
      return;
   }

   double lot = CalculateLotSize(entryPrice - sl);
   if(lot <= 0.0)
   {
      Print("ERROR: Calculated lot size is invalid (<=0). Aborting BUY order.");
      return;
   }

   sl = NormalizePrice(sl);
   tp = NormalizePrice(tp);

   if(!trade.Buy(lot, _Symbol, entryPrice, sl, tp, "MACD Histogram Momentum Buy"))
   {
      Print("ERROR: BUY order failed. Retcode: ", trade.ResultRetcode(),
            " Description: ", trade.ResultRetcodeDescription(),
            " Comment: ", trade.ResultComment());
      return;
   }

   Print("BUY order executed successfully. Ticket: ", trade.ResultOrder(),
         " Lot: ", lot, " Entry: ", entryPrice, " SL: ", sl, " TP: ", tp);
}

//+------------------------------------------------------------------+
//| Open a SELL position                                              |
//+------------------------------------------------------------------+
void OpenSell()
{
   double atrValue = 0.0;
   if(!GetATRValue(atrValue))
   {
      Print("ERROR: Invalid ATR value. Aborting SELL order.");
      return;
   }

   if(!symbolInfo.RefreshRates())
   {
      Print("ERROR: Failed to refresh symbol rates before SELL execution.");
      return;
   }

   double entryPrice = symbolInfo.Bid();
   double sl = entryPrice + (atrValue * StopLossATRMultiplier);
   double tp = entryPrice - (atrValue * TakeProfitATRMultiplier);

   if(!ValidateStops(false, entryPrice, sl, tp))
   {
      Print("ERROR: Invalid SL/TP computed for SELL. Aborting order. SL=", sl, " TP=", tp);
      return;
   }

   double lot = CalculateLotSize(sl - entryPrice);
   if(lot <= 0.0)
   {
      Print("ERROR: Calculated lot size is invalid (<=0). Aborting SELL order.");
      return;
   }

   sl = NormalizePrice(sl);
   tp = NormalizePrice(tp);

   if(!trade.Sell(lot, _Symbol, entryPrice, sl, tp, "MACD Histogram Momentum Sell"))
   {
      Print("ERROR: SELL order failed. Retcode: ", trade.ResultRetcode(),
            " Description: ", trade.ResultRetcodeDescription(),
            " Comment: ", trade.ResultComment());
      return;
   }

   Print("SELL order executed successfully. Ticket: ", trade.ResultOrder(),
         " Lot: ", lot, " Entry: ", entryPrice, " SL: ", sl, " TP: ", tp);
}

//+------------------------------------------------------------------+
//| Validate and adjust SL/TP against broker's minimum stop distance   |
//+------------------------------------------------------------------+
bool ValidateStops(bool isBuy, double entryPrice, double &sl, double &tp)
{
   if(!symbolInfo.Name(_Symbol))
      return(false);

   double stopLevelPoints   = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double freezeLevelPoints = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   double point = symbolInfo.Point();

   double minStopDistance = MathMax(stopLevelPoints, freezeLevelPoints) * point;
   if(minStopDistance <= 0)
      minStopDistance = point;

   if(isBuy)
   {
      if(entryPrice - sl < minStopDistance)
         sl = entryPrice - minStopDistance;
      if(tp - entryPrice < minStopDistance)
         tp = entryPrice + minStopDistance;

      if(sl >= entryPrice || tp <= entryPrice)
         return(false);
   }
   else
   {
      if(sl - entryPrice < minStopDistance)
         sl = entryPrice + minStopDistance;
      if(entryPrice - tp < minStopDistance)
         tp = entryPrice - minStopDistance;

      if(sl <= entryPrice || tp >= entryPrice)
         return(false);
   }

   if(sl <= 0.0 || tp <= 0.0)
      return(false);

   return(true);
}

//+------------------------------------------------------------------+
//| Calculate lot size (fixed or risk-based)                          |
//+------------------------------------------------------------------+
double CalculateLotSize(double stopLossDistancePrice)
{
   if(!UseRiskBasedLot)
      return(NormalizeVolume(FixedLot));

   if(stopLossDistancePrice <= 0.0)
   {
      Print("ERROR: Invalid stop loss distance for risk-based lot calculation.");
      return(0.0);
   }

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskAmount = equity * (RiskPercent / 100.0);

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tickValue <= 0.0 || tickSize <= 0.0)
   {
      Print("ERROR: Invalid tick value/size for symbol ", _Symbol, ". Falling back to FixedLot.");
      return(NormalizeVolume(FixedLot));
   }

   double valuePerPriceUnit = tickValue / tickSize;
   double lossPerLot = stopLossDistancePrice * valuePerPriceUnit;

   if(lossPerLot <= 0.0)
   {
      Print("ERROR: Computed loss-per-lot is invalid. Falling back to FixedLot.");
      return(NormalizeVolume(FixedLot));
   }

   double rawLot = riskAmount / lossPerLot;

   rawLot = MathMax(rawLot, MinLot);
   rawLot = MathMin(rawLot, MaxLot);

   return(NormalizeVolume(rawLot));
}

//+------------------------------------------------------------------+
//| Normalize volume to broker constraints                            |
//+------------------------------------------------------------------+
double NormalizeVolume(double volume)
{
   double minVol  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxVol  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(stepVol <= 0.0)
      stepVol = 0.01;

   double steps = MathFloor((volume - minVol) / stepVol + 0.5);
   double normalized = minVol + steps * stepVol;

   if(normalized < minVol)
      normalized = minVol;
   if(normalized > maxVol)
      normalized = maxVol;

   int stepDigits = 0;
   double tmpStep = stepVol;
   while(tmpStep < 1.0 && stepDigits < 8)
   {
      tmpStep *= 10.0;
      stepDigits++;
   }

   normalized = NormalizeDouble(normalized, stepDigits);

   return(normalized);
}

//+------------------------------------------------------------------+
//| Normalize price to symbol digits / tick size                      |
//+------------------------------------------------------------------+
double NormalizePrice(double price)
{
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tickSize > 0.0)
   {
      double rounded = MathRound(price / tickSize) * tickSize;
      return(NormalizeDouble(rounded, digits));
   }

   return(NormalizeDouble(price, digits));
}

//+------------------------------------------------------------------+
//| Count this EA's open positions on this symbol.                    |
//| direction: -1 = any, 0 = buy only, 1 = sell only                  |
//+------------------------------------------------------------------+
int CountOwnPositions(int direction)
{
   int count = 0;
   int total = PositionsTotal();

   for(int i = 0; i < total; i++)
   {
      if(!positionInfo.SelectByIndex(i))
         continue;

      if(positionInfo.Symbol() != _Symbol)
         continue;

      if(positionInfo.Magic() != MagicNumber)
         continue;

      if(direction == 0 && positionInfo.PositionType() != POSITION_TYPE_BUY)
         continue;

      if(direction == 1 && positionInfo.PositionType() != POSITION_TYPE_SELL)
         continue;

      count++;
   }

   return(count);
}

//+------------------------------------------------------------------+
//| Check if the currently selected position belongs to this EA       |
//+------------------------------------------------------------------+
bool IsOwnPosition()
{
   return(positionInfo.Symbol() == _Symbol && positionInfo.Magic() == MagicNumber);
}

//+------------------------------------------------------------------+
//| Manage all open positions belonging to this EA: exits + trailing  |
//+------------------------------------------------------------------+
void ManagePositions()
{
   if(UseMomentumExit)
      CheckMomentumExit();

   if(UseZeroLineExit)
      CheckZeroLineExit();

   if(UseTrailingStop)
      ApplyTrailingStop();
}

//+------------------------------------------------------------------+
//| Exit Method 1: close when momentum reverses direction             |
//| (evaluated only on a completed-candle basis via cached histogram) |
//+------------------------------------------------------------------+
void CheckMomentumExit()
{
   // Only evaluate on new bar to use completed-candle histogram values
   // and avoid excessive position modifications intratick.
   static datetime lastExitCheckBar = 0;
   datetime currentBarTime = iTime(_Symbol, _Period, 0);
   if(currentBarTime == lastExitCheckBar)
      return;

   double hist1 = 0.0, hist2 = 0.0, hist3 = 0.0;
   if(!CalculateHistogramMomentum(hist1, hist2, hist3))
      return;

   lastExitCheckBar = currentBarTime;

   int total = PositionsTotal();
   for(int i = total - 1; i >= 0; i--)
   {
      if(!positionInfo.SelectByIndex(i))
         continue;
      if(!IsOwnPosition())
         continue;

      ulong ticket = positionInfo.Ticket();

      if(positionInfo.PositionType() == POSITION_TYPE_BUY)
      {
         if(hist1 < hist2)
         {
            if(trade.PositionClose(ticket))
               Print("Position closed on MACD momentum reversal (BUY). Ticket: ", ticket);
            else
               Print("ERROR: Failed to close BUY ticket ", ticket, " on momentum exit. Retcode: ", trade.ResultRetcode());
         }
      }
      else if(positionInfo.PositionType() == POSITION_TYPE_SELL)
      {
         if(hist1 > hist2)
         {
            if(trade.PositionClose(ticket))
               Print("Position closed on MACD momentum reversal (SELL). Ticket: ", ticket);
            else
               Print("ERROR: Failed to close SELL ticket ", ticket, " on momentum exit. Retcode: ", trade.ResultRetcode());
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Exit Method 2: close when histogram crosses the zero line         |
//+------------------------------------------------------------------+
void CheckZeroLineExit()
{
   static datetime lastZeroExitCheckBar = 0;
   datetime currentBarTime = iTime(_Symbol, _Period, 0);
   if(currentBarTime == lastZeroExitCheckBar)
      return;

   double hist1 = 0.0, hist2 = 0.0, hist3 = 0.0;
   if(!CalculateHistogramMomentum(hist1, hist2, hist3))
      return;

   lastZeroExitCheckBar = currentBarTime;

   int total = PositionsTotal();
   for(int i = total - 1; i >= 0; i--)
   {
      if(!positionInfo.SelectByIndex(i))
         continue;
      if(!IsOwnPosition())
         continue;

      ulong ticket = positionInfo.Ticket();

      if(positionInfo.PositionType() == POSITION_TYPE_BUY)
      {
         if(hist1 < 0.0)
         {
            if(trade.PositionClose(ticket))
               Print("Position closed on zero-line exit (BUY). Ticket: ", ticket);
            else
               Print("ERROR: Failed to close BUY ticket ", ticket, " on zero-line exit. Retcode: ", trade.ResultRetcode());
         }
      }
      else if(positionInfo.PositionType() == POSITION_TYPE_SELL)
      {
         if(hist1 > 0.0)
         {
            if(trade.PositionClose(ticket))
               Print("Position closed on zero-line exit (SELL). Ticket: ", ticket);
            else
               Print("ERROR: Failed to close SELL ticket ", ticket, " on zero-line exit. Retcode: ", trade.ResultRetcode());
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Apply ATR-based trailing stop to this EA's own positions only     |
//+------------------------------------------------------------------+
void ApplyTrailingStop()
{
   double atrValue = 0.0;
   if(!GetATRValue(atrValue))
      return;

   if(!symbolInfo.RefreshRates())
      return;

   double bid = symbolInfo.Bid();
   double ask = symbolInfo.Ask();

   double stopLevelPoints = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double point = symbolInfo.Point();
   double minStopDistance = stopLevelPoints * point;
   if(minStopDistance <= 0)
      minStopDistance = point;

   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      if(!positionInfo.SelectByIndex(i))
         continue;
      if(!IsOwnPosition())
         continue;

      ulong ticket = positionInfo.Ticket();
      double currentSL = positionInfo.StopLoss();
      double currentTP = positionInfo.TakeProfit();

      if(positionInfo.PositionType() == POSITION_TYPE_BUY)
      {
         double newSL = bid - (atrValue * TrailingStopATRMultiplier);
         newSL = NormalizePrice(newSL);

         if(newSL > currentSL && newSL < (bid - minStopDistance) && newSL > 0.0)
         {
            if(!trade.PositionModify(ticket, newSL, currentTP))
               Print("ERROR: Failed to modify trailing SL for BUY ticket ", ticket,
                     ". Retcode: ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
            else
               Print("Trailing stop updated for BUY ticket ", ticket, ". New SL: ", newSL);
         }
      }
      else if(positionInfo.PositionType() == POSITION_TYPE_SELL)
      {
         double newSL = ask + (atrValue * TrailingStopATRMultiplier);
         newSL = NormalizePrice(newSL);

         if((newSL < currentSL || currentSL == 0.0) && newSL > (ask + minStopDistance))
         {
            if(!trade.PositionModify(ticket, newSL, currentTP))
               Print("ERROR: Failed to modify trailing SL for SELL ticket ", ticket,
                     ". Retcode: ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
            else
               Print("Trailing stop updated for SELL ticket ", ticket, ". New SL: ", newSL);
         }
      }
   }
}
//+------------------------------------------------------------------+