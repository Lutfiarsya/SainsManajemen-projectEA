//+------------------------------------------------------------------+
//|                          SR_Breakout_ATR_EA.mq5                   |
//|        Support & Resistance Breakout + ATR Trend Confirmation     |
//|                                                                    |
//| STRATEGY (see spec sections 1-11 for full rationale)                |
//| -------------------------------------------------------------      |
//|  Resistance = highest High of shift 2..(SRLookback+1)               |
//|  Support    = lowest  Low  of shift 2..(SRLookback+1)               |
//|  BUY  when: Close[2]<=Resistance AND Close[1]>Resistance(+buffer)   |
//|             AND Close[1]>Open[1]                                    |
//|  SELL when: Close[2]>=Support    AND Close[1]<Support(-buffer)      |
//|             AND Close[1]<Open[1]                                    |
//|  Entry = current Ask (BUY) / current Bid (SELL) - never Close[1]    |
//|  SL    = Entry -/+ ATR[1] x ATRMultiplier                           |
//|  TP    = Entry +/- (RiskDistance x RiskRewardRatio)                 |
//|                                                                    |
//| The signal candle (shift 1) is NEVER included in the S/R            |
//| calculation, eliminating look-ahead bias / repainting by            |
//| construction. Signals are evaluated exactly once per newly closed  |
//| bar of InpSignalTimeframe.                                          |
//|                                                                    |
//| No martingale, grid, averaging, trailing stop, breakeven, or any   |
//| other feature beyond what is specified above.                      |
//+------------------------------------------------------------------+
#property copyright "SR Breakout + ATR EA"
#property version   "1.00"

#include <Trade\Trade.mqh>

//====================================================================
// INPUT PARAMETERS (exact set per specification section 28)
//====================================================================

input ENUM_TIMEFRAMES InpSignalTimeframe = PERIOD_H1; // Signal Timeframe

input int InpSRLookback = 20; // Support/Resistance Lookback (candles)

input int    InpATRPeriod     = 14;  // ATR Period
input double InpATRMultiplier = 2.0; // ATR Stop Loss Multiplier

input double InpRiskPercent     = 1.0; // Risk Per Trade (% of equity)
input double InpRiskRewardRatio = 2.0; // Risk/Reward Ratio (TP distance = SL distance x this)

input bool InpUseBreakoutBuffer   = false; // Use Breakout Buffer
input int  InpBreakoutBufferPoints = 0;    // Breakout Buffer (points)

input bool InpUseSpreadFilter = true; // Use Spread Filter
input int  InpMaxSpreadPoints = 30;   // Maximum Allowed Spread (points)

input int InpMaximumPositionsPerSymbol = 1; // Maximum Positions Per Symbol

input long InpMagicNumber = 20260916; // Magic Number

input bool EnableDebugLog = false; // Enable Debug Logging

//====================================================================
// GLOBAL STATE
//====================================================================

CTrade   trade;
int      g_atrHandle  = INVALID_HANDLE;
datetime g_lastBarTime = 0;

//====================================================================
// FORWARD DECLARATIONS (grouped here for readability; implementations
// follow below in the same order as specification section 29)
//====================================================================

bool   IsNewBar();
bool   HasOpenPosition();
bool   CalculateResistance(const int lookback, double &outResistance);
bool   CalculateSupport(const int lookback, double &outSupport);
bool   GetATRData(double &outATR);
bool   CheckBuySignal();
bool   CheckSellSignal();
bool   CalculateLotSize(const double entry, const double sl, double &outLot);
double CalculateBuyStopLoss(const double entry, const double atr1);
double CalculateSellStopLoss(const double entry, const double atr1);
double CalculateBuyTakeProfit(const double entry, const double sl);
double CalculateSellTakeProfit(const double entry, const double sl);
bool   ValidateStops(const bool isBuy, const double entry, const double sl, const double tp);
bool   IsSpreadAcceptable();
bool   HasSufficientMargin(const ENUM_ORDER_TYPE orderType, const double lot, const double price);
void   OpenBuy();
void   OpenSell();
void   PrintTradeError(const string context, const uint retcode, const string description);
ENUM_ORDER_TYPE_FILLING DetectFillingMode();

//====================================================================
// OnInit
//====================================================================

int OnInit()
{
   //--- input validation ------------------------------------------------
   if(InpSRLookback <= 0)
   {
      Print("[INIT ERROR] SRLookback must be > 0.");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(InpATRPeriod <= 0)
   {
      Print("[INIT ERROR] ATRPeriod must be > 0.");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(InpATRMultiplier <= 0.0)
   {
      Print("[INIT ERROR] ATRMultiplier must be > 0.");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(InpRiskPercent <= 0.0)
   {
      Print("[INIT ERROR] RiskPercent must be > 0.");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(InpRiskRewardRatio <= 0.0)
   {
      Print("[INIT ERROR] RiskRewardRatio must be > 0.");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(InpBreakoutBufferPoints < 0)
   {
      Print("[INIT ERROR] BreakoutBufferPoints cannot be negative.");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(InpMaxSpreadPoints < 0)
   {
      Print("[INIT ERROR] MaxSpreadPoints cannot be negative.");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(InpMaximumPositionsPerSymbol <= 0)
   {
      Print("[INIT ERROR] MaximumPositionsPerSymbol must be > 0.");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(InpMagicNumber <= 0)
   {
      Print("[INIT ERROR] MagicNumber must be a positive integer.");
      return(INIT_PARAMETERS_INCORRECT);
   }

   //--- indicator handle, created exactly once ---------------------------
   g_atrHandle = iATR(_Symbol, InpSignalTimeframe, InpATRPeriod);
   if(g_atrHandle == INVALID_HANDLE)
   {
      PrintFormat("[INIT ERROR] Failed to create ATR indicator handle. Error=%d", GetLastError());
      return(INIT_FAILED);
   }

   //--- sufficient historical data check (S/R lookback + signal candles +
   //    ATR warm-up); the per-call functions re-validate this defensively
   //    as well, so this is an early, informative fail-fast check only.
   const int barsAvailable = Bars(_Symbol, InpSignalTimeframe);
   const int barsRequired  = InpSRLookback + 2 + InpATRPeriod;
   if(barsAvailable < barsRequired)
   {
      PrintFormat("[INIT ERROR] Insufficient historical data: have %d bars, need at least %d.",
                  barsAvailable, barsRequired);
      IndicatorRelease(g_atrHandle);
      g_atrHandle = INVALID_HANDLE;
      return(INIT_FAILED);
   }

   //--- trade execution setup --------------------------------------------
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(10); // internal execution tolerance, not a strategy parameter
   trade.SetAsyncMode(false);
   trade.SetTypeFilling(DetectFillingMode());

   //--- arm new-bar detection starting from the NEXT bar (restart-safe;
   //    see header comment for the rationale).
   g_lastBarTime = iTime(_Symbol, InpSignalTimeframe, 0);

   if(EnableDebugLog)
      PrintFormat("[INIT] EA initialized. Symbol=%s Timeframe=%s Magic=%d",
                  _Symbol, EnumToString(InpSignalTimeframe), (int)InpMagicNumber);

   return(INIT_SUCCEEDED);
}

//====================================================================
// OnDeinit
//====================================================================

void OnDeinit(const int reason)
{
   if(g_atrHandle != INVALID_HANDLE)
   {
      IndicatorRelease(g_atrHandle);
      g_atrHandle = INVALID_HANDLE;
   }
}

//====================================================================
// OnTick - architecture per specification section 32
//====================================================================

void OnTick()
{
   if(!IsNewBar())
      return;

   if(HasOpenPosition())
      return;

   if(InpUseSpreadFilter && !IsSpreadAcceptable())
      return;

   if(CheckBuySignal())
   {
      OpenBuy();
      return;
   }

   if(CheckSellSignal())
   {
      OpenSell();
      return;
   }
}

//====================================================================
// IsNewBar
//====================================================================

bool IsNewBar()
{
   const datetime currentBarTime = iTime(_Symbol, InpSignalTimeframe, 0);
   if(currentBarTime == 0)
      return false; // history not ready yet

   if(currentBarTime == g_lastBarTime)
      return false;

   g_lastBarTime = currentBarTime;
   return true;
}

//====================================================================
// HasOpenPosition
//====================================================================

bool HasOpenPosition()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;

      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC)  == InpMagicNumber)
         count++;
   }
   return (count >= InpMaximumPositionsPerSymbol);
}

//====================================================================
// CalculateResistance / CalculateSupport
// Both draw EXCLUSIVELY from shift 2 .. shift (lookback+1) - the
// signal candle (shift 1) and the forming candle (shift 0) are never
// included, by construction, eliminating look-ahead bias.
//====================================================================

bool CalculateResistance(const int lookback, double &outResistance)
{
   double highs[];
   ArraySetAsSeries(highs, true);

   const int copied = CopyHigh(_Symbol, InpSignalTimeframe, 2, lookback, highs);
   if(copied < lookback)
   {
      if(EnableDebugLog)
         PrintFormat("[S/R] CalculateResistance: insufficient bars (%d of %d).", copied, lookback);
      return false;
   }

   double resistance = highs[0];
   for(int i = 1; i < lookback; i++)
      if(highs[i] > resistance) resistance = highs[i];

   if(resistance <= 0.0)
      return false;

   outResistance = resistance;
   return true;
}

bool CalculateSupport(const int lookback, double &outSupport)
{
   double lows[];
   ArraySetAsSeries(lows, true);

   const int copied = CopyLow(_Symbol, InpSignalTimeframe, 2, lookback, lows);
   if(copied < lookback)
   {
      if(EnableDebugLog)
         PrintFormat("[S/R] CalculateSupport: insufficient bars (%d of %d).", copied, lookback);
      return false;
   }

   double support = lows[0];
   for(int i = 1; i < lookback; i++)
      if(lows[i] < support) support = lows[i];

   if(support <= 0.0)
      return false;

   outSupport = support;
   return true;
}

//====================================================================
// GetATRData - always reads ATR[1] (the completed breakout candle),
// never ATR[0] (the still-forming candle).
//====================================================================

bool GetATRData(double &outATR)
{
   double buf[];
   ArraySetAsSeries(buf, true);

   if(CopyBuffer(g_atrHandle, 0, 1, 1, buf) <= 0)
   {
      if(EnableDebugLog) Print("[ATR] CopyBuffer failed - ATR data not available.");
      return false;
   }

   if(buf[0] <= 0.0 || buf[0] == EMPTY_VALUE)
   {
      if(EnableDebugLog) Print("[ATR] Invalid ATR value returned.");
      return false;
   }

   outATR = buf[0];
   return true;
}

//====================================================================
// CheckBuySignal / CheckSellSignal
//====================================================================

bool CheckBuySignal()
{
   double resistance;
   if(!CalculateResistance(InpSRLookback, resistance))
      return false;

   const double close1 = iClose(_Symbol, InpSignalTimeframe, 1);
   const double close2 = iClose(_Symbol, InpSignalTimeframe, 2);
   const double open1  = iOpen(_Symbol, InpSignalTimeframe, 1);

   if(close1 <= 0.0 || close2 <= 0.0 || open1 <= 0.0)
      return false;

   const double buffer = InpUseBreakoutBuffer ? (InpBreakoutBufferPoints * _Point) : 0.0;

   const bool cond1 = (close2 <= resistance);
   const bool cond2 = (close1 > resistance + buffer);
   const bool cond3 = (close1 > open1);

   if(EnableDebugLog)
      PrintFormat("[BUY CHECK] R=%.*f C2=%.*f C1=%.*f O1=%.*f | c1=%s c2=%s c3=%s",
                  _Digits, resistance, _Digits, close2, _Digits, close1, _Digits, open1,
                  cond1 ? "true" : "false", cond2 ? "true" : "false", cond3 ? "true" : "false");

   return (cond1 && cond2 && cond3);
}

bool CheckSellSignal()
{
   double support;
   if(!CalculateSupport(InpSRLookback, support))
      return false;

   const double close1 = iClose(_Symbol, InpSignalTimeframe, 1);
   const double close2 = iClose(_Symbol, InpSignalTimeframe, 2);
   const double open1  = iOpen(_Symbol, InpSignalTimeframe, 1);

   if(close1 <= 0.0 || close2 <= 0.0 || open1 <= 0.0)
      return false;

   const double buffer = InpUseBreakoutBuffer ? (InpBreakoutBufferPoints * _Point) : 0.0;

   const bool cond1 = (close2 >= support);
   const bool cond2 = (close1 < support - buffer);
   const bool cond3 = (close1 < open1);

   if(EnableDebugLog)
      PrintFormat("[SELL CHECK] S=%.*f C2=%.*f C1=%.*f O1=%.*f | c1=%s c2=%s c3=%s",
                  _Digits, support, _Digits, close2, _Digits, close1, _Digits, open1,
                  cond1 ? "true" : "false", cond2 ? "true" : "false", cond3 ? "true" : "false");

   return (cond1 && cond2 && cond3);
}

//====================================================================
// Stop Loss / Take Profit calculation
//====================================================================

double CalculateBuyStopLoss(const double entry, const double atr1)
{
   return NormalizeDouble(entry - (atr1 * InpATRMultiplier), _Digits);
}

double CalculateSellStopLoss(const double entry, const double atr1)
{
   return NormalizeDouble(entry + (atr1 * InpATRMultiplier), _Digits);
}

double CalculateBuyTakeProfit(const double entry, const double sl)
{
   const double riskDistance = entry - sl;
   return NormalizeDouble(entry + (riskDistance * InpRiskRewardRatio), _Digits);
}

double CalculateSellTakeProfit(const double entry, const double sl)
{
   const double riskDistance = sl - entry;
   return NormalizeDouble(entry - (riskDistance * InpRiskRewardRatio), _Digits);
}

//====================================================================
// ValidateStops - direction + broker minimum-distance validation.
// Never adjusts SL/TP or the R:R ratio; only accepts or rejects.
//====================================================================

bool ValidateStops(const bool isBuy, const double entry, const double sl, const double tp)
{
   if(isBuy)
   {
      if(sl >= entry) { if(EnableDebugLog) Print("[VALIDATE] BUY rejected: SL >= Entry."); return false; }
      if(tp <= entry) { if(EnableDebugLog) Print("[VALIDATE] BUY rejected: TP <= Entry."); return false; }
   }
   else
   {
      if(sl <= entry) { if(EnableDebugLog) Print("[VALIDATE] SELL rejected: SL <= Entry."); return false; }
      if(tp >= entry) { if(EnableDebugLog) Print("[VALIDATE] SELL rejected: TP >= Entry."); return false; }
   }

   const int stopsLevelPoints  = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   const int freezeLevelPoints = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   const int minPoints         = MathMax(stopsLevelPoints, freezeLevelPoints);
   const double minDistance    = minPoints * _Point;

   if(minDistance > 0.0)
   {
      if(MathAbs(entry - sl) < minDistance)
      {
         if(EnableDebugLog) PrintFormat("[VALIDATE] Rejected: SL distance below broker minimum (%d pts).", minPoints);
         return false;
      }
      if(MathAbs(entry - tp) < minDistance)
      {
         if(EnableDebugLog) PrintFormat("[VALIDATE] Rejected: TP distance below broker minimum (%d pts).", minPoints);
         return false;
      }
   }

   return true;
}

//====================================================================
// IsSpreadAcceptable
//====================================================================

bool IsSpreadAcceptable()
{
   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(ask <= 0.0 || bid <= 0.0 || _Point <= 0.0)
      return false;

   const double spreadPoints = (ask - bid) / _Point;

   if(EnableDebugLog)
      PrintFormat("[SPREAD] Current=%.1f pts, Max allowed=%d pts", spreadPoints, InpMaxSpreadPoints);

   return (spreadPoints <= (double)InpMaxSpreadPoints);
}

//====================================================================
// CalculateLotSize - risk-based position sizing.
//====================================================================

bool CalculateLotSize(const double entry, const double sl, double &outLot)
{
   outLot = 0.0;

   const double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   const double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   const double volMin    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   const double volMax    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   const double volStep   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(tickSize <= 0.0 || tickValue <= 0.0 || volStep <= 0.0)
   {
      if(EnableDebugLog) Print("[LOT] Invalid symbol tick size/value/volume step.");
      return false;
   }

   const double slDistance = MathAbs(entry - sl);
   if(slDistance <= 0.0)
   {
      if(EnableDebugLog) Print("[LOT] Zero SL distance - cannot size position.");
      return false;
   }

   const double equity    = AccountInfoDouble(ACCOUNT_EQUITY);
   const double riskMoney = equity * (InpRiskPercent / 100.0);
   if(riskMoney <= 0.0)
   {
      if(EnableDebugLog) Print("[LOT] Computed risk amount is <= 0.");
      return false;
   }

   const double moneyPerLot = (slDistance / tickSize) * tickValue;
   if(moneyPerLot <= 0.0)
   {
      if(EnableDebugLog) Print("[LOT] Computed money-per-lot is <= 0.");
      return false;
   }

   double lot = MathFloor((riskMoney / moneyPerLot) / volStep) * volStep;

   if(lot < volMin)
   {
      if(EnableDebugLog)
         PrintFormat("[LOT] Calculated lot %.4f below broker minimum %.4f - trade skipped.", lot, volMin);
      return false;
   }
   if(lot > volMax)
      lot = volMax;

   outLot = NormalizeDouble(lot, 8);

   if(EnableDebugLog)
      PrintFormat("[LOT] Equity=%.2f RiskMoney=%.2f SLDistance=%.*f MoneyPerLot=%.2f -> Lot=%.4f",
                  equity, riskMoney, _Digits, slDistance, moneyPerLot, outLot);

   return true;
}

//====================================================================
// HasSufficientMargin
//====================================================================

bool HasSufficientMargin(const ENUM_ORDER_TYPE orderType, const double lot, const double price)
{
   double requiredMargin = 0.0;
   if(!OrderCalcMargin(orderType, _Symbol, lot, price, requiredMargin))
   {
      if(EnableDebugLog) PrintFormat("[MARGIN] OrderCalcMargin failed. Error=%d", GetLastError());
      return false;
   }

   const double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);

   if(EnableDebugLog)
      PrintFormat("[MARGIN] Required=%.2f Free=%.2f", requiredMargin, freeMargin);

   return (requiredMargin <= freeMargin);
}

//====================================================================
// DetectFillingMode - broker-compatible order filling mode, internal
// execution detail (not a strategy parameter).
//====================================================================

ENUM_ORDER_TYPE_FILLING DetectFillingMode()
{
   const long mask = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((mask & SYMBOL_FILLING_FOK) != 0) return ORDER_FILLING_FOK;
   if((mask & SYMBOL_FILLING_IOC) != 0) return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN;
}

//====================================================================
// OpenBuy / OpenSell
//====================================================================

void OpenBuy()
{
   double atr1;
   if(!GetATRData(atr1))
   {
      if(EnableDebugLog) Print("[BUY] Aborted: ATR data unavailable.");
      return;
   }

   const double entry = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(entry <= 0.0)
   {
      if(EnableDebugLog) Print("[BUY] Aborted: invalid Ask price.");
      return;
   }

   const double sl = CalculateBuyStopLoss(entry, atr1);
   const double tp = CalculateBuyTakeProfit(entry, sl);

   if(!ValidateStops(true, entry, sl, tp))
   {
      if(EnableDebugLog) Print("[BUY] Aborted: stop levels failed validation.");
      return;
   }

   double lot;
   if(!CalculateLotSize(entry, sl, lot))
   {
      if(EnableDebugLog) Print("[BUY] Aborted: lot size calculation failed.");
      return;
   }

   if(!HasSufficientMargin(ORDER_TYPE_BUY, lot, entry))
   {
      if(EnableDebugLog) Print("[BUY] Aborted: insufficient free margin.");
      return;
   }

   if(EnableDebugLog)
      PrintFormat("[BUY ORDER] Entry=%.*f SL=%.*f TP=%.*f RiskDistance=%.*f Lot=%.4f",
                  _Digits, entry, _Digits, sl, _Digits, tp, _Digits, MathAbs(entry - sl), lot);

   if(!trade.Buy(lot, _Symbol, entry, sl, tp, "SR_Breakout_EA"))
      PrintTradeError("BUY", trade.ResultRetcode(), trade.ResultRetcodeDescription());
   else if(EnableDebugLog)
      Print("[BUY] Order sent successfully.");
}

void OpenSell()
{
   double atr1;
   if(!GetATRData(atr1))
   {
      if(EnableDebugLog) Print("[SELL] Aborted: ATR data unavailable.");
      return;
   }

   const double entry = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(entry <= 0.0)
   {
      if(EnableDebugLog) Print("[SELL] Aborted: invalid Bid price.");
      return;
   }

   const double sl = CalculateSellStopLoss(entry, atr1);
   const double tp = CalculateSellTakeProfit(entry, sl);

   if(!ValidateStops(false, entry, sl, tp))
   {
      if(EnableDebugLog) Print("[SELL] Aborted: stop levels failed validation.");
      return;
   }

   double lot;
   if(!CalculateLotSize(entry, sl, lot))
   {
      if(EnableDebugLog) Print("[SELL] Aborted: lot size calculation failed.");
      return;
   }

   if(!HasSufficientMargin(ORDER_TYPE_SELL, lot, entry))
   {
      if(EnableDebugLog) Print("[SELL] Aborted: insufficient free margin.");
      return;
   }

   if(EnableDebugLog)
      PrintFormat("[SELL ORDER] Entry=%.*f SL=%.*f TP=%.*f RiskDistance=%.*f Lot=%.4f",
                  _Digits, entry, _Digits, sl, _Digits, tp, _Digits, MathAbs(sl - entry), lot);

   if(!trade.Sell(lot, _Symbol, entry, sl, tp, "SR_Breakout_EA"))
      PrintTradeError("SELL", trade.ResultRetcode(), trade.ResultRetcodeDescription());
   else if(EnableDebugLog)
      Print("[SELL] Order sent successfully.");
}

//====================================================================
// PrintTradeError
//====================================================================

void PrintTradeError(const string context, const uint retcode, const string description)
{
   PrintFormat("[TRADE ERROR] %s failed. Retcode=%u Description=%s", context, retcode, description);
}

//+------------------------------------------------------------------+