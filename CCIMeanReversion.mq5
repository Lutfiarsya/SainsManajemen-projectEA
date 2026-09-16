//+------------------------------------------------------------------+
//|                          CCI_Mean_Reversion_EA.mq5               |
//|            CCI Mean Reversion (Confirmed Reversal) Expert Advisor|
//|                                                                  |
//|  Strategy: CCI Extreme -> CCI Recovery -> Price Confirmation ->  |
//|  Trend-Strength Filter -> Risk/Reward Validation -> Entry.       |
//|  Targets a reversion to the EMA mean with ATR-based risk control.|
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

// --- CCI
input group "=== CCI Parameters ==="
input int      CCIPeriod                 = 20;      // CCI Period
input double   CCIOverbought             = 100.0;   // CCI Overbought threshold
input double   CCIOversold               = -100.0;  // CCI Oversold threshold
input double   CCIExtremeOverbought      = 200.0;   // CCI Extreme overbought threshold
input double   CCIExtremeOversold        = -200.0;  // CCI Extreme oversold threshold
input bool     RequireExtremeCCI         = false;   // Require extreme CCI level to arm setup

// --- EMA
input group "=== EMA Trend Filter ==="
input int      EMAPeriod                 = 100;     // EMA Period (mean reference)
input bool     UseEMAFilter              = true;    // Reject entries too far from EMA
input double   MaxEMADistanceATR         = 3.0;     // Max allowed |Close-EMA| in units of ATR
input bool     UseEMADirectionFilter     = false;   // Prefer reversions not fighting EMA slope

// --- ADX
input group "=== ADX Trend-Strength Filter ==="
input int      ADXPeriod                 = 14;      // ADX Period
input bool     UseADXFilter              = true;    // Block entries during strong trends
input double   MaxADX                    = 25.0;    // Maximum ADX allowed for mean reversion

// --- ATR
input group "=== ATR Parameters ==="
input int      ATRPeriod                 = 14;      // ATR Period
input bool     UseATRFilter              = true;    // Filter trades by volatility range
input double   MinimumATR                = 0.0;     // Minimum ATR required (symbol-scale dependent)
input double   MaximumATR                = 0.0;     // Maximum ATR allowed, 0 = no upper cap

// --- Price Confirmation
input group "=== Reversal Confirmation ==="
input bool     UsePriceConfirmation      = true;    // Require close beyond prior candle's high/low

// --- Risk Management
input group "=== Stop Loss / Take Profit ==="
input double   StopLossATRMultiplier     = 1.5;     // Stop Loss ATR Multiplier
input bool     UseMeanTarget             = true;    // Target the EMA mean as primary TP
input double   TakeProfitATRMultiplier   = 1.5;     // ATR-based TP fallback multiplier
input double   MinimumRewardRisk         = 0.8;     // Minimum acceptable reward/risk ratio

// --- Position Sizing
input group "=== Position Sizing ==="
input bool     UseRiskBasedLot           = false;   // Use Risk-Based Lot Sizing
input double   RiskPercent               = 1.0;     // Risk percent of equity per trade
input double   FixedLot                  = 0.01;    // Fixed lot size
input double   MinLot                    = 0.01;    // Minimum allowed lot (risk-based clamp)
input double   MaxLot                    = 10.0;    // Maximum allowed lot (risk-based clamp)

// --- Break-Even
input group "=== Break-Even ==="
input bool     UseBreakEven              = true;    // Enable break-even stop move
input double   BreakEvenTriggerATR       = 1.0;     // Profit trigger, in units of ATR
input int      BreakEvenOffsetPoints     = 10;      // Offset beyond entry price, in points

// --- Trailing Stop
input group "=== Trailing Stop ==="
input bool     UseTrailingStop           = false;   // Enable ATR Trailing Stop
input double   TrailingStopATRMultiplier = 1.0;     // Trailing Stop ATR Multiplier

// --- CCI Failure Exit
input group "=== CCI Reversal-Failure Exit ==="
input bool     UseCCIExit                = true;    // Close if CCI re-enters extreme zone

// --- Holding Period
input group "=== Maximum Holding Period ==="
input bool     UseMaxHoldingBars         = true;    // Close positions held too long
input int      MaxHoldingBars            = 30;      // Maximum completed bars to hold a position

// --- Cooldown
input group "=== Entry Cooldown ==="
input int      CooldownBars              = 5;       // Bars to wait after a close before re-entering

// --- Spread / Session
input group "=== Market Safety Filters ==="
input bool     UseSpreadFilter           = true;    // Reject entries when spread is too wide
input int      MaxSpreadPoints           = 50;      // Maximum allowed spread, in points
input bool     UseTradingSession         = false;   // Restrict new entries to a trading session
input int      StartHour                 = 3;       // Session start hour (0-23, terminal time)
input int      StartMinute               = 0;       // Session start minute
input int      EndHour                   = 22;      // Session end hour (0-23, terminal time)
input int      EndMinute                 = 0;       // Session end minute

// --- Trading Control
input group "=== Trading Control ==="
input long     MagicNumber               = 20240604;// Unique Magic Number
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

int            cciHandle = INVALID_HANDLE;
int            emaHandle = INVALID_HANDLE;
int            atrHandle = INVALID_HANDLE;
int            adxHandle = INVALID_HANDLE;

datetime       lastBarTime = 0;
bool           initializedOk = false;

// Setup state machine: 0 = NONE, 1 = ARMED, 2 = TRADED
// Requires a full CCI recovery back through the oversold/overbought
// threshold before a new setup can arm, so only ONE trade is taken
// per distinct CCI extreme event ("one signal per reversal").
int            buySetupState  = 0;
int            sellSetupState = 0;

datetime       lastPositionCloseTime = 0;

//+------------------------------------------------------------------+
//| Forward declarations                                              |
//+------------------------------------------------------------------+
bool   IsNewBar();
bool   GetCCI(double &cci1, double &cci2);
bool   GetEMA(double &ema1, double &ema2);
bool   GetATR(double &atr1);
bool   GetADX(double &adx1);
void   UpdateSetupStates(double cci1, double cci2);
bool   CheckBuyConfirmation(double cci1, double cci2, double &outAtr, double &outEma1);
bool   CheckSellConfirmation(double cci1, double cci2, double &outAtr, double &outEma1);
bool   CheckTrendFilter(bool isBuy, double close1, double ema1, double ema2, double atr1);
bool   CheckADXFilter(double adx1);
bool   CheckATRFilter(double atr1);
bool   CheckSpreadFilter();
bool   CheckTradingSession();
bool   CheckCooldown();
double CalculateMeanTarget(double ema1);
double CalculateStopLoss(bool isBuy, double entryPrice, double atr1);
double CalculateTakeProfit(bool isBuy, double entryPrice, double atr1, double meanTarget, bool &usedMean);
bool   ValidateRiskReward(bool isBuy, double entryPrice, double sl, double tp);
double CalculateLotSize(double stopLossDistancePrice);
void   OpenBuy(double atr1, double ema1);
void   OpenSell(double atr1, double ema1);
void   ManagePositions();
void   CheckCCIExit();
void   CheckMaxHoldingTime();
void   ApplyBreakEven();
void   ApplyTrailingStop();
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

   if(CCIPeriod <= 0 || EMAPeriod <= 0 || ADXPeriod <= 0 || ATRPeriod <= 0)
   {
      Print("ERROR: Indicator periods must be greater than zero.");
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
   if(MinimumRewardRisk <= 0)
   {
      Print("ERROR: MinimumRewardRisk must be greater than zero.");
      return(INIT_PARAMETERS_INCORRECT);
   }

   cciHandle = iCCI(_Symbol, _Period, CCIPeriod, PRICE_TYPICAL);
   if(cciHandle == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create CCI indicator handle. Error code: ", GetLastError());
      return(INIT_FAILED);
   }

   emaHandle = iMA(_Symbol, _Period, EMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if(emaHandle == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create EMA indicator handle. Error code: ", GetLastError());
      IndicatorRelease(cciHandle); cciHandle = INVALID_HANDLE;
      return(INIT_FAILED);
   }

   atrHandle = iATR(_Symbol, _Period, ATRPeriod);
   if(atrHandle == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create ATR indicator handle. Error code: ", GetLastError());
      IndicatorRelease(cciHandle); cciHandle = INVALID_HANDLE;
      IndicatorRelease(emaHandle); emaHandle = INVALID_HANDLE;
      return(INIT_FAILED);
   }

   adxHandle = iADX(_Symbol, _Period, ADXPeriod);
   if(adxHandle == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create ADX indicator handle. Error code: ", GetLastError());
      IndicatorRelease(cciHandle); cciHandle = INVALID_HANDLE;
      IndicatorRelease(emaHandle); emaHandle = INVALID_HANDLE;
      IndicatorRelease(atrHandle); atrHandle = INVALID_HANDLE;
      return(INIT_FAILED);
   }

   // Restart safety: initialize new-bar tracker to the current bar so the
   // EA does not immediately evaluate a signal at restart. Setup states
   // and cooldown timer intentionally start fresh (NONE / no cooldown)
   // because live open positions are re-detected from the terminal via
   // Symbol+Magic filtering, which is the authoritative source of truth.
   MqlRates rates[];
   if(CopyRates(_Symbol, _Period, 0, 1, rates) > 0)
      lastBarTime = rates[0].time;
   else
      lastBarTime = 0;

   buySetupState  = 0;
   sellSetupState = 0;
   lastPositionCloseTime = 0;

   initializedOk = true;
   Print("EA initialized successfully. Symbol=", _Symbol, " Period=", EnumToString(_Period),
         " Magic=", MagicNumber, " CCIPeriod=", CCIPeriod, " EMAPeriod=", EMAPeriod,
         " ADXPeriod=", ADXPeriod, " ATRPeriod=", ATRPeriod);

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(cciHandle != INVALID_HANDLE) { IndicatorRelease(cciHandle); cciHandle = INVALID_HANDLE; }
   if(emaHandle != INVALID_HANDLE) { IndicatorRelease(emaHandle); emaHandle = INVALID_HANDLE; }
   if(atrHandle != INVALID_HANDLE) { IndicatorRelease(atrHandle); atrHandle = INVALID_HANDLE; }
   if(adxHandle != INVALID_HANDLE) { IndicatorRelease(adxHandle); adxHandle = INVALID_HANDLE; }
   Print("EA deinitialized. Reason code: ", reason);
}

//+------------------------------------------------------------------+
//| Trade transaction handler - used to timestamp position closes for |
//| the entry cooldown mechanism.                                     |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                         const MqlTradeRequest &request,
                         const MqlTradeResult &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;

   if(!HistoryDealSelect(trans.deal))
      return;

   long dealMagic  = HistoryDealGetInteger(trans.deal, DEAL_MAGIC);
   string dealSym  = HistoryDealGetString(trans.deal, DEAL_SYMBOL);
   long dealEntry  = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);

   if(dealMagic == MagicNumber && dealSym == _Symbol && dealEntry == DEAL_ENTRY_OUT)
   {
      lastPositionCloseTime = TimeCurrent();
      Print("Position closed. Cooldown timer started (", CooldownBars, " bars).");
   }
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

   // Manage existing positions every tick (exits, break-even, trailing).
   ManagePositions();

   if(!IsNewBar())
      return;

   long tradeMode = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
   if(tradeMode == SYMBOL_TRADE_MODE_DISABLED)
   {
      Print("Trading disabled for symbol ", _Symbol, ". Skipping signal evaluation.");
      return;
   }

   double cci1 = 0.0, cci2 = 0.0;
   if(!GetCCI(cci1, cci2))
      return;

   // Update the ARM/TRADED/NONE state machine for both directions based on
   // the latest completed-candle CCI values.
   UpdateSetupStates(cci1, cci2);

   int totalOwn = CountOwnPositions(-1);
   if(totalOwn >= MaxPositions)
      return; // Position slot full; still allow ManagePositions() above to run exits.

   if(!CheckCooldown())
      return;

   if(UseSpreadFilter && !CheckSpreadFilter())
      return;

   if(UseTradingSession && !CheckTradingSession())
      return;

   double atr1 = 0.0;
   if(!GetATR(atr1) || atr1 <= 0.0)
      return;

   if(UseATRFilter && !CheckATRFilter(atr1))
      return;

   double adx1 = 0.0;
   if(UseADXFilter)
   {
      if(!GetADX(adx1) || !CheckADXFilter(adx1))
         return;
   }

   // --- BUY ---
   if(AllowBuy && buySetupState == 1) // ARMED
   {
      double confirmAtr = 0.0, confirmEma1 = 0.0;
      if(CheckBuyConfirmation(cci1, cci2, confirmAtr, confirmEma1))
      {
         if(CountOwnPositions(0) == 0)
         {
            Print("BUY reversal confirmed. CCI[1]=", cci1, " CCI[2]=", cci2);
            OpenBuy(confirmAtr, confirmEma1);
         }
      }
   }

   // --- SELL ---
   if(AllowSell && sellSetupState == 1) // ARMED
   {
      double confirmAtr = 0.0, confirmEma1 = 0.0;
      if(CheckSellConfirmation(cci1, cci2, confirmAtr, confirmEma1))
      {
         if(CountOwnPositions(1) == 0)
         {
            Print("SELL reversal confirmed. CCI[1]=", cci1, " CCI[2]=", cci2);
            OpenSell(confirmAtr, confirmEma1);
         }
      }
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
//| Retrieve CCI[1] and CCI[2] (most recent completed candles)        |
//+------------------------------------------------------------------+
bool GetCCI(double &cci1, double &cci2)
{
   if(cciHandle == INVALID_HANDLE)
      return(false);

   double buffer[];
   ArraySetAsSeries(buffer, true);
   int copied = CopyBuffer(cciHandle, 0, 1, 2, buffer);
   if(copied < 2)
   {
      Print("ERROR: CopyBuffer failed for CCI. Error: ", GetLastError());
      return(false);
   }

   cci1 = buffer[0];
   cci2 = buffer[1];
   return(true);
}

//+------------------------------------------------------------------+
//| Retrieve EMA[1] and EMA[2]                                        |
//+------------------------------------------------------------------+
bool GetEMA(double &ema1, double &ema2)
{
   if(emaHandle == INVALID_HANDLE)
      return(false);

   double buffer[];
   ArraySetAsSeries(buffer, true);
   int copied = CopyBuffer(emaHandle, 0, 1, 2, buffer);
   if(copied < 2)
   {
      Print("ERROR: CopyBuffer failed for EMA. Error: ", GetLastError());
      return(false);
   }

   ema1 = buffer[0];
   ema2 = buffer[1];
   return(true);
}

//+------------------------------------------------------------------+
//| Retrieve ATR[1]                                                   |
//+------------------------------------------------------------------+
bool GetATR(double &atr1)
{
   if(atrHandle == INVALID_HANDLE)
      return(false);

   double buffer[];
   ArraySetAsSeries(buffer, true);
   int copied = CopyBuffer(atrHandle, 0, 1, 1, buffer);
   if(copied < 1)
   {
      Print("ERROR: CopyBuffer failed for ATR. Error: ", GetLastError());
      return(false);
   }

   atr1 = buffer[0];
   return(atr1 > 0.0);
}

//+------------------------------------------------------------------+
//| Retrieve ADX[1] (main ADX line, buffer 0)                         |
//+------------------------------------------------------------------+
bool GetADX(double &adx1)
{
   if(adxHandle == INVALID_HANDLE)
      return(false);

   double buffer[];
   ArraySetAsSeries(buffer, true);
   int copied = CopyBuffer(adxHandle, 0, 1, 1, buffer);
   if(copied < 1)
   {
      Print("ERROR: CopyBuffer failed for ADX. Error: ", GetLastError());
      return(false);
   }

   adx1 = buffer[0];
   return(true);
}

//+------------------------------------------------------------------+
//| Update the BUY/SELL setup state machines.                         |
//| NONE    -> ARMED  when a fresh extreme (CCI[2]) is detected        |
//| ARMED   -> TRADED once a confirmed entry is taken (set elsewhere)  |
//| TRADED  -> NONE   once CCI[1] fully recovers past the threshold,   |
//|                    which requires a brand-new extreme before the   |
//|                    next trade can be armed ("one signal per        |
//|                    reversal").                                     |
//+------------------------------------------------------------------+
void UpdateSetupStates(double cci1, double cci2)
{
   double buyArmThreshold  = RequireExtremeCCI ? CCIExtremeOversold   : CCIOversold;
   double sellArmThreshold = RequireExtremeCCI ? CCIExtremeOverbought : CCIOverbought;

   // --- BUY state machine ---
   if(buySetupState == 2) // TRADED
   {
      if(cci1 > CCIOversold)
         buySetupState = 0; // fully recovered, ready to arm again on a new event
   }
   else if(buySetupState == 0) // NONE
   {
      if(cci2 <= buyArmThreshold)
      {
         buySetupState = 1; // ARMED
         Print("CCI oversold setup detected. CCI[2]=", cci2, " Threshold=", buyArmThreshold);
      }
   }
   else if(buySetupState == 1) // ARMED
   {
      // Invalidate the armed setup if CCI has moved into overbought
      // territory without a confirmed entry (setup no longer relevant).
      if(cci1 >= CCIOverbought)
         buySetupState = 0;
   }

   // --- SELL state machine ---
   if(sellSetupState == 2) // TRADED
   {
      if(cci1 < CCIOverbought)
         sellSetupState = 0;
   }
   else if(sellSetupState == 0) // NONE
   {
      if(cci2 >= sellArmThreshold)
      {
         sellSetupState = 1; // ARMED
         Print("CCI overbought setup detected. CCI[2]=", cci2, " Threshold=", sellArmThreshold);
      }
   }
   else if(sellSetupState == 1) // ARMED
   {
      if(cci1 <= CCIOversold)
         sellSetupState = 0;
   }
}

//+------------------------------------------------------------------+
//| Full BUY reversal confirmation (CCI recovery + price + filters)   |
//+------------------------------------------------------------------+
bool CheckBuyConfirmation(double cci1, double cci2, double &outAtr, double &outEma1)
{
   // Condition 1: CCI recovering
   if(!(cci1 > cci2))
      return(false);

   // Condition 2: CCI has recovered back above the oversold threshold
   if(!(cci1 > CCIOversold))
      return(false);

   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, _Period, 1, 2, rates) < 2)
   {
      Print("ERROR: Failed to copy completed candles for BUY confirmation. Error: ", GetLastError());
      return(false);
   }

   double close1 = rates[0].close;
   double open1  = rates[0].open;
   double high2  = rates[1].high;

   // Condition 3: bullish confirmation candle
   if(!(close1 > open1))
      return(false);

   // Condition 4: price confirmation
   if(UsePriceConfirmation && !(close1 > high2))
      return(false);

   double atr1 = 0.0;
   if(!GetATR(atr1) || atr1 <= 0.0)
      return(false);

   double ema1 = 0.0, ema2 = 0.0;
   if(!GetEMA(ema1, ema2))
      return(false);

   if(UseEMAFilter && !CheckTrendFilter(true, close1, ema1, ema2, atr1))
      return(false);

   if(UseEMADirectionFilter && !(ema1 >= ema2))
      return(false);

   outAtr = atr1;
   outEma1 = ema1;

   return(true);
}

//+------------------------------------------------------------------+
//| Full SELL reversal confirmation (CCI decline + price + filters)   |
//+------------------------------------------------------------------+
bool CheckSellConfirmation(double cci1, double cci2, double &outAtr, double &outEma1)
{
   // Condition 1: CCI declining
   if(!(cci1 < cci2))
      return(false);

   // Condition 2: CCI has returned back below the overbought threshold
   if(!(cci1 < CCIOverbought))
      return(false);

   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, _Period, 1, 2, rates) < 2)
   {
      Print("ERROR: Failed to copy completed candles for SELL confirmation. Error: ", GetLastError());
      return(false);
   }

   double close1 = rates[0].close;
   double open1  = rates[0].open;
   double low2   = rates[1].low;

   // Condition 3: bearish confirmation candle
   if(!(close1 < open1))
      return(false);

   // Condition 4: price confirmation
   if(UsePriceConfirmation && !(close1 < low2))
      return(false);

   double atr1 = 0.0;
   if(!GetATR(atr1) || atr1 <= 0.0)
      return(false);

   double ema1 = 0.0, ema2 = 0.0;
   if(!GetEMA(ema1, ema2))
      return(false);

   if(UseEMAFilter && !CheckTrendFilter(false, close1, ema1, ema2, atr1))
      return(false);

   if(UseEMADirectionFilter && !(ema1 <= ema2))
      return(false);

   outAtr = atr1;
   outEma1 = ema1;

   return(true);
}

//+------------------------------------------------------------------+
//| EMA distance filter: reject entries too far displaced from mean   |
//+------------------------------------------------------------------+
bool CheckTrendFilter(bool isBuy, double close1, double ema1, double ema2, double atr1)
{
   double distance = MathAbs(close1 - ema1);
   double maxDistance = atr1 * MaxEMADistanceATR;
   return(distance <= maxDistance);
}

//+------------------------------------------------------------------+
//| ADX trend-strength filter                                         |
//+------------------------------------------------------------------+
bool CheckADXFilter(double adx1)
{
   return(adx1 <= MaxADX);
}

//+------------------------------------------------------------------+
//| ATR volatility range filter                                       |
//+------------------------------------------------------------------+
bool CheckATRFilter(double atr1)
{
   if(atr1 < MinimumATR)
      return(false);
   if(MaximumATR > 0.0 && atr1 > MaximumATR)
      return(false);
   return(true);
}

//+------------------------------------------------------------------+
//| Spread filter                                                     |
//+------------------------------------------------------------------+
bool CheckSpreadFilter()
{
   if(!symbolInfo.RefreshRates())
      return(false);

   double point = symbolInfo.Point();
   if(point <= 0.0)
      return(false);

   double spreadPoints = (symbolInfo.Ask() - symbolInfo.Bid()) / point;
   return(spreadPoints <= (double)MaxSpreadPoints);
}

//+------------------------------------------------------------------+
//| Trading session filter (new entries only)                         |
//+------------------------------------------------------------------+
bool CheckTradingSession()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   int nowMinutes   = dt.hour * 60 + dt.min;
   int startMinutes = StartHour * 60 + StartMinute;
   int endMinutes   = EndHour * 60 + EndMinute;

   if(startMinutes <= endMinutes)
      return(nowMinutes >= startMinutes && nowMinutes <= endMinutes);

   // Session wraps past midnight
   return(nowMinutes >= startMinutes || nowMinutes <= endMinutes);
}

//+------------------------------------------------------------------+
//| Entry cooldown check based on bars elapsed since last close       |
//+------------------------------------------------------------------+
bool CheckCooldown()
{
   if(CooldownBars <= 0 || lastPositionCloseTime == 0)
      return(true);

   int barsElapsed = iBarShift(_Symbol, _Period, lastPositionCloseTime, false);
   if(barsElapsed < 0)
      return(true); // could not resolve; do not block trading

   return(barsElapsed >= CooldownBars);
}

//+------------------------------------------------------------------+
//| Mean-reversion target: the EMA value at the signal candle         |
//+------------------------------------------------------------------+
double CalculateMeanTarget(double ema1)
{
   return(ema1);
}

//+------------------------------------------------------------------+
//| ATR-based Stop Loss                                                |
//+------------------------------------------------------------------+
double CalculateStopLoss(bool isBuy, double entryPrice, double atr1)
{
   if(isBuy)
      return(entryPrice - (atr1 * StopLossATRMultiplier));
   else
      return(entryPrice + (atr1 * StopLossATRMultiplier));
}

//+------------------------------------------------------------------+
//| Take Profit: mean target primary, ATR-based fallback              |
//+------------------------------------------------------------------+
double CalculateTakeProfit(bool isBuy, double entryPrice, double atr1, double meanTarget, bool &usedMean)
{
   usedMean = false;

   double point = symbolInfo.Point();
   double stopLevelPoints = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDistance = MathMax(stopLevelPoints * point, point);

   if(UseMeanTarget)
   {
      bool meanValid = isBuy ? (meanTarget > entryPrice + minDistance)
                              : (meanTarget < entryPrice - minDistance);
      if(meanValid)
      {
         usedMean = true;
         return(meanTarget);
      }
   }

   // ATR-based fallback
   if(isBuy)
      return(entryPrice + (atr1 * TakeProfitATRMultiplier));
   else
      return(entryPrice - (atr1 * TakeProfitATRMultiplier));
}

//+------------------------------------------------------------------+
//| Validate the reward/risk ratio meets the configured minimum       |
//+------------------------------------------------------------------+
bool ValidateRiskReward(bool isBuy, double entryPrice, double sl, double tp)
{
   double risk   = MathAbs(entryPrice - sl);
   double reward = MathAbs(tp - entryPrice);

   if(risk <= 0.0)
      return(false);

   double rr = reward / risk;
   return(rr >= MinimumRewardRisk);
}

//+------------------------------------------------------------------+
//| Open a BUY position                                                |
//+------------------------------------------------------------------+
void OpenBuy(double atr1, double ema1)
{
   if(!symbolInfo.RefreshRates())
   {
      Print("ERROR: Failed to refresh symbol rates before BUY execution.");
      return;
   }

   double entryPrice = symbolInfo.Ask();
   double sl = CalculateStopLoss(true, entryPrice, atr1);

   double meanTarget = CalculateMeanTarget(ema1);
   bool usedMean = false;
   double tp = CalculateTakeProfit(true, entryPrice, atr1, meanTarget, usedMean);

   if(!ValidateStops(true, entryPrice, sl, tp))
   {
      Print("ERROR: Invalid SL/TP computed for BUY. Aborting order. SL=", sl, " TP=", tp);
      return;
   }

   if(!ValidateRiskReward(true, entryPrice, sl, tp))
   {
      Print("BUY signal rejected: reward/risk below MinimumRewardRisk (", MinimumRewardRisk, "). Trade skipped.");
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

   if(!trade.Buy(lot, _Symbol, entryPrice, sl, tp, "CCI Mean Reversion Buy"))
   {
      Print("ERROR: BUY order failed. Retcode: ", trade.ResultRetcode(),
            " Description: ", trade.ResultRetcodeDescription(),
            " Comment: ", trade.ResultComment());
      return;
   }

   buySetupState = 2; // TRADED - consumes this reversal event

   Print("BUY order executed successfully. Ticket: ", trade.ResultOrder(),
         " Lot: ", lot, " Entry: ", entryPrice, " SL: ", sl, " TP: ", tp,
         " TargetType: ", (usedMean ? "Mean(EMA)" : "ATR Fallback"));
}

//+------------------------------------------------------------------+
//| Open a SELL position                                              |
//+------------------------------------------------------------------+
void OpenSell(double atr1, double ema1)
{
   if(!symbolInfo.RefreshRates())
   {
      Print("ERROR: Failed to refresh symbol rates before SELL execution.");
      return;
   }

   double entryPrice = symbolInfo.Bid();
   double sl = CalculateStopLoss(false, entryPrice, atr1);

   double meanTarget = CalculateMeanTarget(ema1);
   bool usedMean = false;
   double tp = CalculateTakeProfit(false, entryPrice, atr1, meanTarget, usedMean);

   if(!ValidateStops(false, entryPrice, sl, tp))
   {
      Print("ERROR: Invalid SL/TP computed for SELL. Aborting order. SL=", sl, " TP=", tp);
      return;
   }

   if(!ValidateRiskReward(false, entryPrice, sl, tp))
   {
      Print("SELL signal rejected: reward/risk below MinimumRewardRisk (", MinimumRewardRisk, "). Trade skipped.");
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

   if(!trade.Sell(lot, _Symbol, entryPrice, sl, tp, "CCI Mean Reversion Sell"))
   {
      Print("ERROR: SELL order failed. Retcode: ", trade.ResultRetcode(),
            " Description: ", trade.ResultRetcodeDescription(),
            " Comment: ", trade.ResultComment());
      return;
   }

   sellSetupState = 2; // TRADED - consumes this reversal event

   Print("SELL order executed successfully. Ticket: ", trade.ResultOrder(),
         " Lot: ", lot, " Entry: ", entryPrice, " SL: ", sl, " TP: ", tp,
         " TargetType: ", (usedMean ? "Mean(EMA)" : "ATR Fallback"));
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

      if(sl >= entryPrice || tp <= entryPrice || sl <= 0.0 || tp <= 0.0)
         return(false);
   }
   else
   {
      if(sl - entryPrice < minStopDistance)
         sl = entryPrice + minStopDistance;
      if(entryPrice - tp < minStopDistance)
         tp = entryPrice - minStopDistance;

      if(sl <= entryPrice || tp >= entryPrice || sl <= 0.0 || tp <= 0.0)
         return(false);
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
//| Manage all open positions belonging to this EA                    |
//+------------------------------------------------------------------+
void ManagePositions()
{
   if(UseCCIExit)
      CheckCCIExit();

   if(UseMaxHoldingBars)
      CheckMaxHoldingTime();

   if(UseBreakEven)
      ApplyBreakEven();

   if(UseTrailingStop)
      ApplyTrailingStop();
}

//+------------------------------------------------------------------+
//| Close positions when CCI re-enters the extreme zone against the   |
//| position's direction (reversal-failure exit). Evaluated once per  |
//| completed bar using completed-candle CCI[1].                      |
//+------------------------------------------------------------------+
void CheckCCIExit()
{
   static datetime lastCciExitCheckBar = 0;
   datetime currentBarTime = iTime(_Symbol, _Period, 0);
   if(currentBarTime == lastCciExitCheckBar)
      return;

   double cci1 = 0.0, cci2 = 0.0;
   if(!GetCCI(cci1, cci2))
      return;

   lastCciExitCheckBar = currentBarTime;

   int total = PositionsTotal();
   for(int i = total - 1; i >= 0; i--)
   {
      if(!positionInfo.SelectByIndex(i))
         continue;
      if(!IsOwnPosition())
         continue;

      ulong ticket = positionInfo.Ticket();

      if(positionInfo.PositionType() == POSITION_TYPE_BUY && cci1 <= CCIExtremeOversold)
      {
         if(trade.PositionClose(ticket))
            Print("Position closed on CCI reversal-failure exit (BUY). Ticket: ", ticket, " CCI[1]=", cci1);
         else
            Print("ERROR: Failed to close BUY ticket ", ticket, " on CCI exit. Retcode: ", trade.ResultRetcode());
      }
      else if(positionInfo.PositionType() == POSITION_TYPE_SELL && cci1 >= CCIExtremeOverbought)
      {
         if(trade.PositionClose(ticket))
            Print("Position closed on CCI reversal-failure exit (SELL). Ticket: ", ticket, " CCI[1]=", cci1);
         else
            Print("ERROR: Failed to close SELL ticket ", ticket, " on CCI exit. Retcode: ", trade.ResultRetcode());
      }
   }
}

//+------------------------------------------------------------------+
//| Close positions that have exceeded the maximum holding period     |
//+------------------------------------------------------------------+
void CheckMaxHoldingTime()
{
   static datetime lastHoldingCheckBar = 0;
   datetime currentBarTime = iTime(_Symbol, _Period, 0);
   if(currentBarTime == lastHoldingCheckBar)
      return;
   lastHoldingCheckBar = currentBarTime;

   int total = PositionsTotal();
   for(int i = total - 1; i >= 0; i--)
   {
      if(!positionInfo.SelectByIndex(i))
         continue;
      if(!IsOwnPosition())
         continue;

      datetime openTime = (datetime)positionInfo.Time();
      int barsHeld = iBarShift(_Symbol, _Period, openTime, false);
      if(barsHeld < 0)
         continue;

      if(barsHeld >= MaxHoldingBars)
      {
         ulong ticket = positionInfo.Ticket();
         if(trade.PositionClose(ticket))
            Print("Position closed: maximum holding period reached (", barsHeld, " bars). Ticket: ", ticket);
         else
            Print("ERROR: Failed to close ticket ", ticket, " on max holding time. Retcode: ", trade.ResultRetcode());
      }
   }
}

//+------------------------------------------------------------------+
//| Move SL to break-even (+ offset) once profit target is reached.   |
//| Never loosens an existing Stop Loss.                               |
//+------------------------------------------------------------------+
void ApplyBreakEven()
{
   double atr1 = 0.0;
   if(!GetATR(atr1) || atr1 <= 0.0)
      return;

   if(!symbolInfo.RefreshRates())
      return;

   double bid = symbolInfo.Bid();
   double ask = symbolInfo.Ask();
   double point = symbolInfo.Point();
   double offset = BreakEvenOffsetPoints * point;

   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      if(!positionInfo.SelectByIndex(i))
         continue;
      if(!IsOwnPosition())
         continue;

      ulong ticket = positionInfo.Ticket();
      double openPrice = positionInfo.PriceOpen();
      double currentSL = positionInfo.StopLoss();
      double currentTP = positionInfo.TakeProfit();
      double triggerDistance = atr1 * BreakEvenTriggerATR;

      if(positionInfo.PositionType() == POSITION_TYPE_BUY)
      {
         double profit = bid - openPrice;
         double newSL  = openPrice + offset;

         if(profit >= triggerDistance && newSL > currentSL && newSL < bid)
         {
            if(!trade.PositionModify(ticket, NormalizePrice(newSL), currentTP))
               Print("ERROR: Failed to apply break-even for BUY ticket ", ticket,
                     ". Retcode: ", trade.ResultRetcode());
            else
               Print("Break-even applied for BUY ticket ", ticket, ". New SL: ", NormalizePrice(newSL));
         }
      }
      else if(positionInfo.PositionType() == POSITION_TYPE_SELL)
      {
         double profit = openPrice - ask;
         double newSL  = openPrice - offset;

         if(profit >= triggerDistance && (newSL < currentSL || currentSL == 0.0) && newSL > ask)
         {
            if(!trade.PositionModify(ticket, NormalizePrice(newSL), currentTP))
               Print("ERROR: Failed to apply break-even for SELL ticket ", ticket,
                     ". Retcode: ", trade.ResultRetcode());
            else
               Print("Break-even applied for SELL ticket ", ticket, ". New SL: ", NormalizePrice(newSL));
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Apply ATR-based trailing stop to this EA's own positions only     |
//+------------------------------------------------------------------+
void ApplyTrailingStop()
{
   double atr1 = 0.0;
   if(!GetATR(atr1) || atr1 <= 0.0)
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
         double newSL = bid - (atr1 * TrailingStopATRMultiplier);
         newSL = NormalizePrice(newSL);

         if(newSL > currentSL && newSL < (bid - minStopDistance) && newSL > 0.0)
         {
            if(!trade.PositionModify(ticket, newSL, currentTP))
               Print("ERROR: Failed to modify trailing SL for BUY ticket ", ticket,
                     ". Retcode: ", trade.ResultRetcode());
            else
               Print("Trailing stop updated for BUY ticket ", ticket, ". New SL: ", newSL);
         }
      }
      else if(positionInfo.PositionType() == POSITION_TYPE_SELL)
      {
         double newSL = ask + (atr1 * TrailingStopATRMultiplier);
         newSL = NormalizePrice(newSL);

         if((newSL < currentSL || currentSL == 0.0) && newSL > (ask + minStopDistance))
         {
            if(!trade.PositionModify(ticket, newSL, currentTP))
               Print("ERROR: Failed to modify trailing SL for SELL ticket ", ticket,
                     ". Retcode: ", trade.ResultRetcode());
            else
               Print("Trailing stop updated for SELL ticket ", ticket, ". New SL: ", newSL);
         }
      }
   }
}
//+------------------------------------------------------------------+