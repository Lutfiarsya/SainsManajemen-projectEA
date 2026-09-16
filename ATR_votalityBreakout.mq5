//+------------------------------------------------------------------+
//|                                  ATR_Volatility_Breakout_EA.mq5 |
//|                        ATR Volatility Breakout Expert Advisor    |
//|                                                                  |
//|  Strategy: Detects volatility-adjusted breakouts of the prior    |
//|  N-candle range using ATR, with ATR-based SL/TP, optional        |
//|  ATR trailing stop, and fixed or risk-based position sizing.     |
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

// --- Strategy
input group "=== Strategy Parameters ==="
input int      ATRPeriod              = 14;      // ATR Period
input int      BreakoutLookback       = 20;       // Breakout Lookback Period (candles)
input double   ATRMultiplier          = 1.0;      // ATR Multiplier for breakout levels
input bool     UseMinimumATRFilter    = false;    // Use Minimum ATR Filter
input double   MinimumATR             = 0.0;      // Minimum ATR value required to trade

// --- Risk Management
input group "=== Risk Management ==="
input bool     UseRiskBasedLot        = false;    // Use Risk-Based Lot Sizing
input double   RiskPercent            = 1.0;      // Risk percent of equity per trade
input double   FixedLot               = 0.10;     // Fixed lot size (used if UseRiskBasedLot=false)
input double   MinLot                 = 0.01;     // Minimum allowed lot (risk-based sizing clamp)
input double   MaxLot                 = 10.0;     // Maximum allowed lot (risk-based sizing clamp)
input double   StopLossATRMultiplier  = 1.5;      // Stop Loss ATR Multiplier
input double   TakeProfitATRMultiplier= 3.0;      // Take Profit ATR Multiplier

// --- Trailing Stop
input group "=== Trailing Stop ==="
input bool     UseTrailingStop        = false;    // Enable ATR Trailing Stop
input double   TrailingStopATRMultiplier = 1.5;   // Trailing Stop ATR Multiplier

// --- Trading Control
input group "=== Trading Control ==="
input long     MagicNumber            = 20240601; // Unique Magic Number
input int      MaxPositions           = 1;        // Max simultaneous positions (this EA, this symbol)
input bool     AllowBuy               = true;     // Allow BUY trades
input bool     AllowSell              = true;     // Allow SELL trades
input int      SlippagePoints         = 30;       // Slippage (points)

//====================================================================
// GLOBAL VARIABLES
//====================================================================

CTrade         trade;
CSymbolInfo    symbolInfo;
CPositionInfo  positionInfo;

int            atrHandle = INVALID_HANDLE;
datetime       lastBarTime = 0;
bool           initializedOk = false;

// Track the bar time of the last breakout signal actually acted upon,
// separately for buy and sell, to avoid multiple entries on the same signal.
datetime       lastBuySignalBarTime  = 0;
datetime       lastSellSignalBarTime = 0;

//+------------------------------------------------------------------+
//| Forward declarations                                              |
//+------------------------------------------------------------------+
bool     IsNewBar();
bool     GetATR(int shift, double &atrValue);
bool     CalculateBreakoutLevels(double &upperBreakout, double &lowerBreakout, double atrValue);
bool     CheckBuySignal(double &outAtr, double &outUpperBreakout);
bool     CheckSellSignal(double &outAtr, double &outLowerBreakout);
void     OpenBuy(double atrValue);
void     OpenSell(double atrValue);
double   CalculateLotSize(double stopLossDistancePrice);
void     ManagePositions();
void     ApplyTrailingStop();
int      CountOwnPositions(int direction); // -1 = any, 0 = buy, 1 = sell
bool     IsOwnPosition();
double   NormalizeVolume(double volume);
double   NormalizePrice(double price);
bool     ValidateStops(bool isBuy, double entryPrice, double &sl, double &tp);

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

   if(ATRPeriod <= 0)
   {
      Print("ERROR: ATRPeriod must be greater than zero.");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(BreakoutLookback <= 0)
   {
      Print("ERROR: BreakoutLookback must be greater than zero.");
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
   if(StopLossATRMultiplier <= 0)
   {
      Print("ERROR: StopLossATRMultiplier must be greater than zero.");
      return(INIT_PARAMETERS_INCORRECT);
   }

   atrHandle = iATR(_Symbol, _Period, ATRPeriod);
   if(atrHandle == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create ATR indicator handle. Error code: ", GetLastError());
      return(INIT_FAILED);
   }

   // Restore state on restart: reset new-bar tracker to current bar time
   // so the EA does not immediately re-evaluate a signal that already
   // triggered before restart. We deliberately do NOT persist
   // lastBuySignalBarTime/lastSellSignalBarTime across restarts because
   // open-position checks (CountOwnPositions/IsOwnPosition) already
   // prevent duplicate entries based on live terminal state, which is
   // the authoritative source of truth after a restart.
   MqlRates rates[];
   if(CopyRates(_Symbol, _Period, 0, 1, rates) > 0)
      lastBarTime = rates[0].time;
   else
      lastBarTime = 0;

   initializedOk = true;
   Print("EA initialized successfully. Symbol=", _Symbol, " Period=", EnumToString(_Period),
         " Magic=", MagicNumber, " ATRPeriod=", ATRPeriod, " BreakoutLookback=", BreakoutLookback);

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
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

   // Manage existing positions (trailing stop) on every tick for responsiveness.
   if(UseTrailingStop)
      ApplyTrailingStop();

   // Signal evaluation only on a new completed bar.
   if(!IsNewBar())
      return;

   // Basic trading-allowed / market state checks.
   if(!SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE) != SYMBOL_TRADE_MODE_DISABLED)
   {
      // placeholder guard removed below (kept for clarity, real check follows)
   }
   long tradeMode = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
   if(tradeMode == SYMBOL_TRADE_MODE_DISABLED)
   {
      Print("Trading disabled for symbol ", _Symbol, ". Skipping signal evaluation.");
      return;
   }

   double atrValue = 0.0;
   double upperBreakout = 0.0;
   double lowerBreakout = 0.0;

   bool buySignal  = AllowBuy  && CheckBuySignal(atrValue, upperBreakout);
   bool sellSignal = AllowSell && CheckSellSignal(atrValue, lowerBreakout);

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
         Print("BUY signal detected. Bar time: ", TimeToString(signalBarTime), " ATR: ", atrValue,
               " UpperBreakout: ", upperBreakout);
         OpenBuy(atrValue);
      }
      lastBuySignalBarTime = signalBarTime;
   }

   if(sellSignal && lastSellSignalBarTime != signalBarTime)
   {
      if(totalOwn < MaxPositions && CountOwnPositions(1) == 0)
      {
         Print("SELL signal detected. Bar time: ", TimeToString(signalBarTime), " ATR: ", atrValue,
               " LowerBreakout: ", lowerBreakout);
         OpenSell(atrValue);
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
//| Retrieve ATR value at given shift (1 = previous completed candle) |
//+------------------------------------------------------------------+
bool GetATR(int shift, double &atrValue)
{
   atrValue = 0.0;

   if(atrHandle == INVALID_HANDLE)
   {
      Print("ERROR: ATR handle is invalid.");
      return(false);
   }

   double buffer[];
   ArraySetAsSeries(buffer, true);

   int copied = CopyBuffer(atrHandle, 0, shift, 1, buffer);
   if(copied <= 0)
   {
      Print("ERROR: CopyBuffer failed for ATR. Error: ", GetLastError());
      return(false);
   }

   atrValue = buffer[0];
   if(atrValue <= 0.0)
      return(false);

   return(true);
}

//+------------------------------------------------------------------+
//| Calculate the highest high / lowest low of the previous            |
//| BreakoutLookback COMPLETED candles, excluding the confirmation     |
//| candle (shift 1) itself: range is computed over shifts [2 .. N+1]  |
//+------------------------------------------------------------------+
bool CalculateBreakoutLevels(double &upperBreakout, double &lowerBreakout, double atrValue)
{
   upperBreakout = 0.0;
   lowerBreakout = 0.0;

   int startShift = 2; // exclude shift 0 (forming) and shift 1 (confirmation candle)
   int count = BreakoutLookback;

   double highs[];
   double lows[];
   ArraySetAsSeries(highs, true);
   ArraySetAsSeries(lows, true);

   int copiedHigh = CopyHigh(_Symbol, _Period, startShift, count, highs);
   int copiedLow  = CopyLow(_Symbol, _Period, startShift, count, lows);

   if(copiedHigh <= 0 || copiedLow <= 0)
   {
      Print("ERROR: Failed to copy High/Low data for breakout range. Error: ", GetLastError());
      return(false);
   }

   double highestHigh = highs[ArrayMaximum(highs, 0, copiedHigh)];
   double lowestLow   = lows[ArrayMinimum(lows, 0, copiedLow)];

   upperBreakout = highestHigh + (atrValue * ATRMultiplier);
   lowerBreakout = lowestLow   - (atrValue * ATRMultiplier);

   return(true);
}

//+------------------------------------------------------------------+
//| Check BUY signal based on previous completed candle close          |
//+------------------------------------------------------------------+
bool CheckBuySignal(double &outAtr, double &outUpperBreakout)
{
   double atrValue = 0.0;
   if(!GetATR(1, atrValue))
      return(false);

   if(UseMinimumATRFilter && atrValue < MinimumATR)
      return(false);

   double upperBreakout = 0.0;
   double lowerBreakoutDummy = 0.0;
   if(!CalculateBreakoutLevels(upperBreakout, lowerBreakoutDummy, atrValue))
      return(false);

   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, _Period, 1, 1, rates) <= 0)
   {
      Print("ERROR: Failed to copy previous completed candle for BUY signal check. Error: ", GetLastError());
      return(false);
   }

   double prevClose = rates[0].close;

   outAtr = atrValue;
   outUpperBreakout = upperBreakout;

   return(prevClose > upperBreakout);
}

//+------------------------------------------------------------------+
//| Check SELL signal based on previous completed candle close         |
//+------------------------------------------------------------------+
bool CheckSellSignal(double &outAtr, double &outLowerBreakout)
{
   double atrValue = 0.0;
   if(!GetATR(1, atrValue))
      return(false);

   if(UseMinimumATRFilter && atrValue < MinimumATR)
      return(false);

   double upperBreakoutDummy = 0.0;
   double lowerBreakout = 0.0;
   if(!CalculateBreakoutLevels(upperBreakoutDummy, lowerBreakout, atrValue))
      return(false);

   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, _Period, 1, 1, rates) <= 0)
   {
      Print("ERROR: Failed to copy previous completed candle for SELL signal check. Error: ", GetLastError());
      return(false);
   }

   double prevClose = rates[0].close;

   outAtr = atrValue;
   outLowerBreakout = lowerBreakout;

   return(prevClose < lowerBreakout);
}

//+------------------------------------------------------------------+
//| Open a BUY position                                                |
//+------------------------------------------------------------------+
void OpenBuy(double atrValue)
{
   if(!symbolInfo.RefreshRates())
   {
      Print("ERROR: Failed to refresh symbol rates before BUY execution.");
      return;
   }

   double entryPrice = symbolInfo.Ask();
   double slDistance = atrValue * StopLossATRMultiplier;
   double tpDistance = atrValue * TakeProfitATRMultiplier;

   double sl = entryPrice - slDistance;
   double tp = entryPrice + tpDistance;

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

   if(!trade.Buy(lot, _Symbol, entryPrice, sl, tp, "ATR Breakout Buy"))
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
void OpenSell(double atrValue)
{
   if(!symbolInfo.RefreshRates())
   {
      Print("ERROR: Failed to refresh symbol rates before SELL execution.");
      return;
   }

   double entryPrice = symbolInfo.Bid();
   double slDistance = atrValue * StopLossATRMultiplier;
   double tpDistance = atrValue * TakeProfitATRMultiplier;

   double sl = entryPrice + slDistance;
   double tp = entryPrice - tpDistance;

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

   if(!trade.Sell(lot, _Symbol, entryPrice, sl, tp, "ATR Breakout Sell"))
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

   double stopLevelPoints = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double freezeLevelPoints = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   double point = symbolInfo.Point();

   double minStopDistance = MathMax(stopLevelPoints, freezeLevelPoints) * point;

   if(minStopDistance <= 0)
      minStopDistance = point; // safety fallback

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

   // Value of one price unit of movement, per 1.0 lot.
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

   int stepDigits = 2;
   double tmpStep = stepVol;
   stepDigits = 0;
   while(tmpStep < 1.0 && stepDigits < 8)
   {
      tmpStep *= 10.0;
      stepDigits++;
   }

   normalized = NormalizeDouble(normalized, stepDigits);

   return(normalized);
}

//+------------------------------------------------------------------+
//| Normalize price to symbol digits                                  |
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
//| Manage open positions (placeholder for future extensions such as  |
//| partial closes, break-even logic, etc. Currently delegates to     |
//| trailing stop when enabled).                                      |
//+------------------------------------------------------------------+
void ManagePositions()
{
   if(UseTrailingStop)
      ApplyTrailingStop();
}

//+------------------------------------------------------------------+
//| Apply ATR-based trailing stop to this EA's own positions only     |
//+------------------------------------------------------------------+
void ApplyTrailingStop()
{
   double atrValue = 0.0;
   if(!GetATR(1, atrValue))
      return; // do not trail without a valid ATR reading

   if(!symbolInfo.RefreshRates())
      return;

   double bid = symbolInfo.Bid();
   double ask = symbolInfo.Ask();

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
      double openPrice = positionInfo.PriceOpen();

      double stopLevelPoints = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
      double point = symbolInfo.Point();
      double minStopDistance = stopLevelPoints * point;
      if(minStopDistance <= 0)
         minStopDistance = point;

      if(positionInfo.PositionType() == POSITION_TYPE_BUY)
      {
         double newSL = bid - (atrValue * TrailingStopATRMultiplier);
         newSL = NormalizePrice(newSL);

         // Only move SL up (in the direction of profit), never loosen it,
         // and never move it above current bid minus min stop distance.
         if(newSL > currentSL && newSL < (bid - minStopDistance) && newSL > 0.0)
         {
            if(!trade.PositionModify(ticket, newSL, currentTP))
            {
               Print("ERROR: Failed to modify trailing SL for BUY ticket ", ticket,
                     ". Retcode: ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
            }
            else
            {
               Print("Trailing stop updated for BUY ticket ", ticket, ". New SL: ", newSL);
            }
         }
      }
      else if(positionInfo.PositionType() == POSITION_TYPE_SELL)
      {
         double newSL = ask + (atrValue * TrailingStopATRMultiplier);
         newSL = NormalizePrice(newSL);

         // Only move SL down (in the direction of profit), never loosen it.
         if((newSL < currentSL || currentSL == 0.0) && newSL > (ask + minStopDistance))
         {
            if(!trade.PositionModify(ticket, newSL, currentTP))
            {
               Print("ERROR: Failed to modify trailing SL for SELL ticket ", ticket,
                     ". Retcode: ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
            }
            else
            {
               Print("Trailing stop updated for SELL ticket ", ticket, ". New SL: ", newSL);
            }
         }
      }
   }
}
//+------------------------------------------------------------------+