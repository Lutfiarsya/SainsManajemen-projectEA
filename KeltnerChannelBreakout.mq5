//+------------------------------------------------------------------+
//|                             Keltner_Channel_Breakout_EA.mq5      |
//|                  Keltner Channel Breakout Expert Advisor         |
//|                                                                  |
//|  Strategy: Trades fresh breakouts of an EMA-centered, ATR-based  |
//|  Keltner Channel, confirmed by the completed candle close.       |
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

// --- Keltner Channel
input group "=== Keltner Channel Parameters ==="
input int      EMAPeriod                 = 20;     // EMA Period (channel middle line)
input int      ATRPeriod                 = 10;     // ATR Period
input double   ATRMultiplier             = 2.0;    // ATR Multiplier for channel width

// --- Breakout Filters
input group "=== Breakout Filters ==="
input bool     UseCandleConfirmation     = true;   // Require bullish/bearish confirmation candle
input bool     UseBreakoutStrengthFilter = false;  // Require minimum breakout penetration
input double   MinimumBreakoutATR        = 0.10;   // Minimum breakout distance, in units of ATR

// --- Trading
input group "=== Trading Control ==="
input long     MagicNumber               = 20240603;// Unique Magic Number
input int      MaxPositions              = 1;       // Max simultaneous positions (this EA, this symbol)
input bool     AllowBuy                  = true;    // Allow BUY trades
input bool     AllowSell                 = true;    // Allow SELL trades
input int      SlippagePoints            = 30;      // Slippage (points)

// --- Risk Management
input group "=== Position Sizing ==="
input bool     UseRiskBasedLot           = false;   // Use Risk-Based Lot Sizing
input double   RiskPercent               = 1.0;     // Risk percent of equity per trade
input double   FixedLot                  = 0.10;    // Fixed lot size
input double   MinLot                    = 0.01;    // Minimum allowed lot (risk-based clamp)
input double   MaxLot                    = 10.0;    // Maximum allowed lot (risk-based clamp)

// --- Stop Loss / Take Profit
input group "=== Stop Loss / Take Profit ==="
input bool     UseATRStopLoss            = true;    // Use ATR-based Stop Loss
input double   StopLossATRMultiplier     = 1.5;     // Stop Loss ATR Multiplier
input bool     UseATRTakeProfit          = true;    // Use ATR-based Take Profit
input double   TakeProfitATRMultiplier   = 3.0;     // Take Profit ATR Multiplier

// --- Channel-Based Exits
input group "=== Channel-Based Exits ==="
input bool     UseMiddleLineExit         = false;   // Exit when close crosses back over EMA middle line
input bool     CloseOnOppositeBreakout   = false;   // Exit on a confirmed opposite breakout

// --- Trailing Stop
input group "=== Trailing Stop ==="
input bool     UseTrailingStop           = false;   // Enable ATR Trailing Stop
input double   TrailingStopATRMultiplier = 1.5;     // Trailing Stop ATR Multiplier

//====================================================================
// GLOBAL VARIABLES
//====================================================================

CTrade         trade;
CSymbolInfo    symbolInfo;
CPositionInfo  positionInfo;

int            emaHandle = INVALID_HANDLE;
int            atrHandle = INVALID_HANDLE;

datetime       lastBarTime = 0;
bool           initializedOk = false;

datetime       lastBuySignalBarTime  = 0;
datetime       lastSellSignalBarTime = 0;

//+------------------------------------------------------------------+
//| Forward declarations                                              |
//+------------------------------------------------------------------+
bool   IsNewBar();
bool   GetEMAValues(double &emaArr[], int shiftStart, int count);
bool   GetATRValues(double &atrArr[], int shiftStart, int count);
bool   CalculateKeltnerChannel(double &middle1, double &upper1, double &lower1, double &atr1,
                                double &middle2, double &upper2, double &lower2, double &atr2);
bool   CheckBuyBreakout(double &outAtr1, double &outUpper1);
bool   CheckSellBreakout(double &outAtr1, double &outLower1);
void   OpenBuy(double atrValue);
void   OpenSell(double atrValue);
void   ManagePositions();
void   CheckMiddleLineExit();
void   CheckOppositeBreakoutExit();
void   ApplyTrailingStop();
double CalculateLotSize(double stopLossDistancePrice);
int    CountOwnPositions(int direction);
bool   IsOwnPosition();
double NormalizeVolume(double volume);
double NormalizePrice(double price);
bool   ValidateStops(bool isBuy, double entryPrice, double &sl, double &tp, bool useSL, bool useTP);

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

   if(EMAPeriod <= 0)
   {
      Print("ERROR: EMAPeriod must be greater than zero.");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(ATRPeriod <= 0)
   {
      Print("ERROR: ATRPeriod must be greater than zero.");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(ATRMultiplier <= 0)
   {
      Print("ERROR: ATRMultiplier must be greater than zero.");
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
   if(UseATRStopLoss && StopLossATRMultiplier <= 0)
   {
      Print("ERROR: StopLossATRMultiplier must be greater than zero when UseATRStopLoss is true.");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(UseRiskBasedLot && !UseATRStopLoss)
   {
      Print("ERROR: Risk-based lot sizing requires UseATRStopLoss=true to determine SL distance.");
      return(INIT_PARAMETERS_INCORRECT);
   }

   emaHandle = iMA(_Symbol, _Period, EMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if(emaHandle == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create EMA indicator handle. Error code: ", GetLastError());
      return(INIT_FAILED);
   }

   atrHandle = iATR(_Symbol, _Period, ATRPeriod);
   if(atrHandle == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create ATR indicator handle. Error code: ", GetLastError());
      IndicatorRelease(emaHandle);
      emaHandle = INVALID_HANDLE;
      return(INIT_FAILED);
   }

   // Initialize new-bar tracker to the current bar so a restart does not
   // immediately evaluate a stale/incomplete signal, and does not open a
   // trade simply because price happens to be outside the channel at
   // restart time (signal evaluation only fires on the NEXT new bar).
   MqlRates rates[];
   if(CopyRates(_Symbol, _Period, 0, 1, rates) > 0)
      lastBarTime = rates[0].time;
   else
      lastBarTime = 0;

   initializedOk = true;
   Print("EA initialized successfully. Symbol=", _Symbol, " Period=", EnumToString(_Period),
         " Magic=", MagicNumber, " EMAPeriod=", EMAPeriod, " ATRPeriod=", ATRPeriod,
         " ATRMultiplier=", ATRMultiplier);

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(emaHandle != INVALID_HANDLE)
   {
      IndicatorRelease(emaHandle);
      emaHandle = INVALID_HANDLE;
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

   // Manage existing positions (exits + trailing) every tick.
   ManagePositions();

   if(!IsNewBar())
      return;

   long tradeMode = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
   if(tradeMode == SYMBOL_TRADE_MODE_DISABLED)
   {
      Print("Trading disabled for symbol ", _Symbol, ". Skipping signal evaluation.");
      return;
   }

   double atr1ForBuy = 0.0, upper1 = 0.0;
   double atr1ForSell = 0.0, lower1 = 0.0;

   bool buySignal  = AllowBuy  && CheckBuyBreakout(atr1ForBuy, upper1);
   bool sellSignal = AllowSell && CheckSellBreakout(atr1ForSell, lower1);

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
         Print("BUY Keltner breakout detected. Bar time: ", TimeToString(signalBarTime),
               " ATR: ", atr1ForBuy, " UpperChannel: ", upper1);
         OpenBuy(atr1ForBuy);
      }
      lastBuySignalBarTime = signalBarTime;
   }

   if(sellSignal && lastSellSignalBarTime != signalBarTime)
   {
      if(totalOwn < MaxPositions && CountOwnPositions(1) == 0)
      {
         Print("SELL Keltner breakout detected. Bar time: ", TimeToString(signalBarTime),
               " ATR: ", atr1ForSell, " LowerChannel: ", lower1);
         OpenSell(atr1ForSell);
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
//| Retrieve 'count' EMA values as series starting at shift 'shiftStart'|
//+------------------------------------------------------------------+
bool GetEMAValues(double &emaArr[], int shiftStart, int count)
{
   if(emaHandle == INVALID_HANDLE)
   {
      Print("ERROR: EMA handle is invalid.");
      return(false);
   }

   ArraySetAsSeries(emaArr, true);
   int copied = CopyBuffer(emaHandle, 0, shiftStart, count, emaArr);
   if(copied <= 0 || copied < count)
   {
      Print("ERROR: CopyBuffer failed for EMA. Error: ", GetLastError());
      return(false);
   }
   return(true);
}

//+------------------------------------------------------------------+
//| Retrieve 'count' ATR values as series starting at shift 'shiftStart'|
//+------------------------------------------------------------------+
bool GetATRValues(double &atrArr[], int shiftStart, int count)
{
   if(atrHandle == INVALID_HANDLE)
   {
      Print("ERROR: ATR handle is invalid.");
      return(false);
   }

   ArraySetAsSeries(atrArr, true);
   int copied = CopyBuffer(atrHandle, 0, shiftStart, count, atrArr);
   if(copied <= 0 || copied < count)
   {
      Print("ERROR: CopyBuffer failed for ATR. Error: ", GetLastError());
      return(false);
   }
   return(true);
}

//+------------------------------------------------------------------+
//| Calculate Keltner Channel middle/upper/lower for shift 1 and 2     |
//+------------------------------------------------------------------+
bool CalculateKeltnerChannel(double &middle1, double &upper1, double &lower1, double &atr1,
                              double &middle2, double &upper2, double &lower2, double &atr2)
{
   double emaArr[];
   double atrArr[];

   // Need shift 1 and shift 2 => start at shift 1, count 2
   if(!GetEMAValues(emaArr, 1, 2))
      return(false);
   if(!GetATRValues(atrArr, 1, 2))
      return(false);

   middle1 = emaArr[0];
   middle2 = emaArr[1];
   atr1    = atrArr[0];
   atr2    = atrArr[1];

   if(atr1 <= 0.0 || atr2 <= 0.0)
      return(false);

   upper1 = middle1 + (atr1 * ATRMultiplier);
   lower1 = middle1 - (atr1 * ATRMultiplier);

   upper2 = middle2 + (atr2 * ATRMultiplier);
   lower2 = middle2 - (atr2 * ATRMultiplier);

   return(true);
}

//+------------------------------------------------------------------+
//| Check for a fresh BUY breakout of the upper Keltner Channel       |
//+------------------------------------------------------------------+
bool CheckBuyBreakout(double &outAtr1, double &outUpper1)
{
   double middle1, upper1, lower1, atr1;
   double middle2, upper2, lower2, atr2;

   if(!CalculateKeltnerChannel(middle1, upper1, lower1, atr1, middle2, upper2, lower2, atr2))
      return(false);

   outAtr1 = atr1;
   outUpper1 = upper1;

   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, _Period, 1, 2, rates) < 2)
   {
      Print("ERROR: Failed to copy completed candles for BUY breakout check. Error: ", GetLastError());
      return(false);
   }

   double close1 = rates[0].close; // latest completed candle
   double open1  = rates[0].open;
   double close2 = rates[1].close; // candle before that

   // Fresh breakout: candle[2] was NOT above upper channel, candle[1] IS above upper channel.
   if(!(close1 > upper1))
      return(false);
   if(!(close2 <= upper2))
      return(false);

   if(UseCandleConfirmation && !(close1 > open1))
      return(false);

   if(UseBreakoutStrengthFilter)
   {
      double penetration = close1 - upper1;
      if(penetration < (atr1 * MinimumBreakoutATR))
         return(false);
   }

   return(true);
}

//+------------------------------------------------------------------+
//| Check for a fresh SELL breakout of the lower Keltner Channel      |
//+------------------------------------------------------------------+
bool CheckSellBreakout(double &outAtr1, double &outLower1)
{
   double middle1, upper1, lower1, atr1;
   double middle2, upper2, lower2, atr2;

   if(!CalculateKeltnerChannel(middle1, upper1, lower1, atr1, middle2, upper2, lower2, atr2))
      return(false);

   outAtr1 = atr1;
   outLower1 = lower1;

   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, _Period, 1, 2, rates) < 2)
   {
      Print("ERROR: Failed to copy completed candles for SELL breakout check. Error: ", GetLastError());
      return(false);
   }

   double close1 = rates[0].close; // latest completed candle
   double open1  = rates[0].open;
   double close2 = rates[1].close; // candle before that

   // Fresh breakout: candle[2] was NOT below lower channel, candle[1] IS below lower channel.
   if(!(close1 < lower1))
      return(false);
   if(!(close2 >= lower2))
      return(false);

   if(UseCandleConfirmation && !(close1 < open1))
      return(false);

   if(UseBreakoutStrengthFilter)
   {
      double penetration = lower1 - close1;
      if(penetration < (atr1 * MinimumBreakoutATR))
         return(false);
   }

   return(true);
}

//+------------------------------------------------------------------+
//| Open a BUY position                                                |
//+------------------------------------------------------------------+
void OpenBuy(double atrValue)
{
   if(atrValue <= 0.0)
   {
      Print("ERROR: Invalid ATR value passed to OpenBuy. Aborting.");
      return;
   }

   if(!symbolInfo.RefreshRates())
   {
      Print("ERROR: Failed to refresh symbol rates before BUY execution.");
      return;
   }

   double entryPrice = symbolInfo.Ask();
   double sl = UseATRStopLoss   ? entryPrice - (atrValue * StopLossATRMultiplier)   : 0.0;
   double tp = UseATRTakeProfit ? entryPrice + (atrValue * TakeProfitATRMultiplier) : 0.0;

   if(!ValidateStops(true, entryPrice, sl, tp, UseATRStopLoss, UseATRTakeProfit))
   {
      Print("ERROR: Invalid SL/TP computed for BUY. Aborting order. SL=", sl, " TP=", tp);
      return;
   }

   double slDistanceForSizing = UseATRStopLoss ? (entryPrice - sl) : (atrValue * MathMax(StopLossATRMultiplier, 0.01));
   double lot = CalculateLotSize(slDistanceForSizing);
   if(lot <= 0.0)
   {
      Print("ERROR: Calculated lot size is invalid (<=0). Aborting BUY order.");
      return;
   }

   if(UseATRStopLoss) sl = NormalizePrice(sl);
   if(UseATRTakeProfit) tp = NormalizePrice(tp);

   if(!trade.Buy(lot, _Symbol, entryPrice, (UseATRStopLoss ? sl : 0.0), (UseATRTakeProfit ? tp : 0.0), "Keltner Breakout Buy"))
   {
      Print("ERROR: BUY order failed. Retcode: ", trade.ResultRetcode(),
            " Description: ", trade.ResultRetcodeDescription(),
            " Comment: ", trade.ResultComment());
      return;
   }

   Print("BUY order executed successfully. Ticket: ", trade.ResultOrder(),
         " Lot: ", lot, " Entry: ", entryPrice, " SL: ", (UseATRStopLoss ? sl : 0.0),
         " TP: ", (UseATRTakeProfit ? tp : 0.0));
}

//+------------------------------------------------------------------+
//| Open a SELL position                                              |
//+------------------------------------------------------------------+
void OpenSell(double atrValue)
{
   if(atrValue <= 0.0)
   {
      Print("ERROR: Invalid ATR value passed to OpenSell. Aborting.");
      return;
   }

   if(!symbolInfo.RefreshRates())
   {
      Print("ERROR: Failed to refresh symbol rates before SELL execution.");
      return;
   }

   double entryPrice = symbolInfo.Bid();
   double sl = UseATRStopLoss   ? entryPrice + (atrValue * StopLossATRMultiplier)   : 0.0;
   double tp = UseATRTakeProfit ? entryPrice - (atrValue * TakeProfitATRMultiplier) : 0.0;

   if(!ValidateStops(false, entryPrice, sl, tp, UseATRStopLoss, UseATRTakeProfit))
   {
      Print("ERROR: Invalid SL/TP computed for SELL. Aborting order. SL=", sl, " TP=", tp);
      return;
   }

   double slDistanceForSizing = UseATRStopLoss ? (sl - entryPrice) : (atrValue * MathMax(StopLossATRMultiplier, 0.01));
   double lot = CalculateLotSize(slDistanceForSizing);
   if(lot <= 0.0)
   {
      Print("ERROR: Calculated lot size is invalid (<=0). Aborting SELL order.");
      return;
   }

   if(UseATRStopLoss) sl = NormalizePrice(sl);
   if(UseATRTakeProfit) tp = NormalizePrice(tp);

   if(!trade.Sell(lot, _Symbol, entryPrice, (UseATRStopLoss ? sl : 0.0), (UseATRTakeProfit ? tp : 0.0), "Keltner Breakout Sell"))
   {
      Print("ERROR: SELL order failed. Retcode: ", trade.ResultRetcode(),
            " Description: ", trade.ResultRetcodeDescription(),
            " Comment: ", trade.ResultComment());
      return;
   }

   Print("SELL order executed successfully. Ticket: ", trade.ResultOrder(),
         " Lot: ", lot, " Entry: ", entryPrice, " SL: ", (UseATRStopLoss ? sl : 0.0),
         " TP: ", (UseATRTakeProfit ? tp : 0.0));
}

//+------------------------------------------------------------------+
//| Validate and adjust SL/TP against broker's minimum stop distance   |
//| useSL/useTP indicate whether each is active; inactive ones (0.0)  |
//| are skipped from the distance checks.                             |
//+------------------------------------------------------------------+
bool ValidateStops(bool isBuy, double entryPrice, double &sl, double &tp, bool useSL, bool useTP)
{
   if(!useSL && !useTP)
      return(true);

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
      if(useSL)
      {
         if(entryPrice - sl < minStopDistance)
            sl = entryPrice - minStopDistance;
         if(sl >= entryPrice || sl <= 0.0)
            return(false);
      }
      if(useTP)
      {
         if(tp - entryPrice < minStopDistance)
            tp = entryPrice + minStopDistance;
         if(tp <= entryPrice)
            return(false);
      }
   }
   else
   {
      if(useSL)
      {
         if(sl - entryPrice < minStopDistance)
            sl = entryPrice + minStopDistance;
         if(sl <= entryPrice || sl <= 0.0)
            return(false);
      }
      if(useTP)
      {
         if(entryPrice - tp < minStopDistance)
            tp = entryPrice - minStopDistance;
         if(tp >= entryPrice || tp <= 0.0)
            return(false);
      }
   }

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
   if(UseMiddleLineExit)
      CheckMiddleLineExit();

   if(CloseOnOppositeBreakout)
      CheckOppositeBreakoutExit();

   if(UseTrailingStop)
      ApplyTrailingStop();
}

//+------------------------------------------------------------------+
//| Exit: close when completed candle closes back across the EMA      |
//| middle line, evaluated once per new completed bar.                |
//+------------------------------------------------------------------+
void CheckMiddleLineExit()
{
   static datetime lastMiddleExitCheckBar = 0;
   datetime currentBarTime = iTime(_Symbol, _Period, 0);
   if(currentBarTime == lastMiddleExitCheckBar)
      return;

   double emaArr[];
   if(!GetEMAValues(emaArr, 1, 1))
      return;

   double middle1 = emaArr[0];

   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, _Period, 1, 1, rates) <= 0)
      return;

   double close1 = rates[0].close;

   lastMiddleExitCheckBar = currentBarTime;

   int total = PositionsTotal();
   for(int i = total - 1; i >= 0; i--)
   {
      if(!positionInfo.SelectByIndex(i))
         continue;
      if(!IsOwnPosition())
         continue;

      ulong ticket = positionInfo.Ticket();

      if(positionInfo.PositionType() == POSITION_TYPE_BUY && close1 < middle1)
      {
         if(trade.PositionClose(ticket))
            Print("Position closed on middle-line exit (BUY). Ticket: ", ticket);
         else
            Print("ERROR: Failed to close BUY ticket ", ticket, " on middle-line exit. Retcode: ", trade.ResultRetcode());
      }
      else if(positionInfo.PositionType() == POSITION_TYPE_SELL && close1 > middle1)
      {
         if(trade.PositionClose(ticket))
            Print("Position closed on middle-line exit (SELL). Ticket: ", ticket);
         else
            Print("ERROR: Failed to close SELL ticket ", ticket, " on middle-line exit. Retcode: ", trade.ResultRetcode());
      }
   }
}

//+------------------------------------------------------------------+
//| Exit: close BUY on a confirmed SELL breakout and vice versa       |
//+------------------------------------------------------------------+
void CheckOppositeBreakoutExit()
{
   static datetime lastOppositeExitCheckBar = 0;
   datetime currentBarTime = iTime(_Symbol, _Period, 0);
   if(currentBarTime == lastOppositeExitCheckBar)
      return;

   lastOppositeExitCheckBar = currentBarTime;

   double dummyAtr = 0.0, dummyLevel = 0.0;
   bool sellBreakout = CheckSellBreakout(dummyAtr, dummyLevel);
   bool buyBreakout  = CheckBuyBreakout(dummyAtr, dummyLevel);

   int total = PositionsTotal();
   for(int i = total - 1; i >= 0; i--)
   {
      if(!positionInfo.SelectByIndex(i))
         continue;
      if(!IsOwnPosition())
         continue;

      ulong ticket = positionInfo.Ticket();

      if(positionInfo.PositionType() == POSITION_TYPE_BUY && sellBreakout)
      {
         if(trade.PositionClose(ticket))
            Print("Position closed on opposite breakout exit (BUY closed on SELL breakout). Ticket: ", ticket);
         else
            Print("ERROR: Failed to close BUY ticket ", ticket, " on opposite breakout exit. Retcode: ", trade.ResultRetcode());
      }
      else if(positionInfo.PositionType() == POSITION_TYPE_SELL && buyBreakout)
      {
         if(trade.PositionClose(ticket))
            Print("Position closed on opposite breakout exit (SELL closed on BUY breakout). Ticket: ", ticket);
         else
            Print("ERROR: Failed to close SELL ticket ", ticket, " on opposite breakout exit. Retcode: ", trade.ResultRetcode());
      }
   }
}

//+------------------------------------------------------------------+
//| Apply ATR-based trailing stop to this EA's own positions only     |
//+------------------------------------------------------------------+
void ApplyTrailingStop()
{
   double atrArr[];
   if(!GetATRValues(atrArr, 1, 1))
      return;

   double atrValue = atrArr[0];
   if(atrValue <= 0.0)
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