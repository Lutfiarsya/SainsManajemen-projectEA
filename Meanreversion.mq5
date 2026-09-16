//+------------------------------------------------------------------+
//|                                             MeanReversionEA.mq5   |
//|                  Bollinger Bands + RSI Mean Reversion EA          |
//|                                                                    |
//| STRATEGY                                                            |
//| -------------------------------------------------------------      |
//| On each newly closed bar of InpBB_Timeframe:                       |
//|   BUY  when Close <= Lower Band AND RSI <= Oversold threshold      |
//|   SELL when Close >= Upper Band AND RSI >= Overbought threshold    |
//| Optionally requires a "band re-entry" confirmation (price closed   |
//| beyond the band one bar ago, then closed back inside it) to        |
//| reduce false signals during strong trending moves.                 |
//| Optionally filtered by ADX (skip signals when the market is        |
//| trending too strongly to be a good mean-reversion candidate).      |
//|                                                                    |
//| ARCHITECTURE                                                        |
//| -------------------------------------------------------------      |
//|   CLogger          - centralized, level-aware logging              |
//|   CTimeUtils       - stateless time helpers                        |
//|   CStateStore      - GlobalVariable-backed persistence             |
//|   CIndicatorSet    - owns indicator handles, exposes typed getters |
//|   CRiskManager     - position sizing (money or % equity risk)      |
//|   CTradeEngine     - orchestrates signal evaluation, entries,      |
//|                      and in-trade management (breakeven/trailing)  |
//|                                                                    |
//| DESIGN NOTES                                                        |
//| -------------------------------------------------------------      |
//|  - Entry signals are evaluated ONLY on a newly closed bar (not     |
//|    every tick) to avoid re-evaluating a still-forming, unstable    |
//|    bar and to prevent duplicate signals firing repeatedly within   |
//|    the same bar.                                                   |
//|  - In-trade management (breakeven / trailing / session close) runs |
//|    every tick regardless, since risk protection should react       |
//|    promptly to price, not wait for the next bar close.             |
//|  - Restart safety: the last processed bar time and the currently   |
//|    tracked position's initial risk distance are persisted via      |
//|    GlobalVariables and reconciled against live broker state on     |
//|    OnInit(), so a terminal restart can never cause a duplicate      |
//|    entry on the same bar nor lose breakeven/trailing context for   |
//|    an already-open position.                                        |
//+------------------------------------------------------------------+
#property copyright "Mean Reversion EA (Bollinger Bands + RSI)"
#property version   "1.00"

#include <Trade\Trade.mqh>
#include <Trade\SymbolInfo.mqh>

//====================================================================
// INPUTS  (numeric/enum only -> every field is optimizer-usable)
//====================================================================

enum ENUM_RISK_MODE
{
   RISK_MODE_MONEY   = 0, // Fixed monetary amount
   RISK_MODE_PERCENT = 1  // Percentage of account equity
};

enum ENUM_SL_MODE
{
   SL_MODE_ATR  = 0, // SL = entry -/+ ATR x multiplier
   SL_MODE_BAND = 1  // SL = opposite side of the signal band +/- buffer
};

enum ENUM_TP_MODE
{
   TP_MODE_MIDDLE_BAND = 0, // TP = Bollinger middle band (SMA) at signal time
   TP_MODE_RR_MULTIPLE  = 1  // TP = entry +/- (risk distance x multiple)
};

input group "===== Bollinger Bands ====="
input ENUM_TIMEFRAMES    InpBB_Timeframe   = PERIOD_CURRENT; // Signal Timeframe
input int                InpBB_Period      = 20;             // BB Period
input double              InpBB_Deviation   = 2.0;            // BB Deviation
input ENUM_APPLIED_PRICE InpBB_AppliedPrice = PRICE_CLOSE;    // BB Applied Price

input group "===== RSI ====="
input int    InpRSI_Period     = 14;   // RSI Period
input double InpRSI_Oversold   = 30.0; // RSI Oversold Threshold (Buy trigger)
input double InpRSI_Overbought = 70.0; // RSI Overbought Threshold (Sell trigger)

input group "===== Signal Quality Filters ====="
input bool   InpRequireBandReentry = true;  // Require close-back-inside-band confirmation
input bool   InpUseADXFilter       = false; // Skip signals when market is trending (ADX high)
input int    InpADX_Period         = 14;    // ADX Period
input double InpADX_MaxThreshold   = 25.0;  // Max ADX allowed to take a signal
input int    InpMaxSpreadPoints    = 0;     // Max spread allowed at entry (points, 0 = disabled)

input group "===== Stop Loss / Take Profit ====="
input int          InpATR_Period        = 14;               // ATR Period (used for SL_MODE_ATR)
input ENUM_SL_MODE InpSLMode            = SL_MODE_ATR;       // Stop Loss Mode
input double       InpSL_ATRMultiplier  = 1.5;               // SL distance = ATR x this (ATR mode)
input int          InpSL_BandBufferPoints = 50;              // SL buffer beyond band, in points (Band mode)
input ENUM_TP_MODE InpTPMode            = TP_MODE_MIDDLE_BAND; // Take Profit Mode
input double       InpTP_RRMultiple     = 1.5;               // TP = risk x this (RR mode)

input group "===== Trade Management (Breakeven / Trailing) ====="
input bool   InpUseBreakeven          = false; // Move SL to breakeven after trigger reached
input double InpBreakevenTriggerRR    = 0.5;   // Shared trigger for BOTH breakeven & trailing: profit >= risk x this
input int    InpBreakevenOffsetPoints = 10;    // Points beyond entry to lock in when moving to BE
input bool   InpUseTrailingStop       = false; // Enable trailing stop (also gated by trigger above)
input int    InpTrailingStopPoints    = 100;   // Trailing distance behind current price (points)
input int    InpTrailingStepPoints    = 10;    // Minimum improvement before SL is updated again

input group "===== Position Control ====="
input bool   InpCloseOnOppositeSignal = true; // Close & reverse if an opposite signal appears mid-trade

input group "===== Day-of-Week Filter ====="
input bool   InpTradeMonday    = true;  // Trade on Monday
input bool   InpTradeTuesday   = true;  // Trade on Tuesday
input bool   InpTradeWednesday = true;  // Trade on Wednesday
input bool   InpTradeThursday  = true;  // Trade on Thursday
input bool   InpTradeFriday    = true;  // Trade on Friday
input bool   InpTradeSaturday  = false; // Trade on Saturday
input bool   InpTradeSunday    = false; // Trade on Sunday

input group "===== Session Filter ====="
input bool InpUseSessionFilter      = false; // Restrict new entries to a time window (server time)
input int  InpSessionStartHour      = 7;     // Session Start Hour   (0-23)
input int  InpSessionStartMinute    = 0;     // Session Start Minute (0-59)
input int  InpSessionEndHour        = 20;    // Session End Hour     (0-23)
input int  InpSessionEndMinute      = 0;     // Session End Minute   (0-59)
input bool InpCloseOutsideSession   = false; // Also force-close open position outside the session

input group "===== Risk Management ====="
input ENUM_RISK_MODE InpRiskMode  = RISK_MODE_PERCENT; // Risk Mode
input double InpRiskMoney         = 100.0;             // Fixed Risk (account currency)
input double InpRiskPercent       = 1.0;               // Risk (% of Equity)
input double InpMinVolumeFallback = 0.0;                // If >0, used when calc lot < broker min (0=skip trade)

input group "===== Order Execution ====="
input int  InpSlippagePoints = 20; // Max allowed slippage/deviation (points)

input group "===== General ====="
input long   InpMagicNumber    = 20260913;      // Magic Number (unique per EA instance)
input string InpTradeComment   = "MeanRev_EA";  // Order/Position comment
input bool   InpVerboseLogging = false;         // Verbose (debug-level) logging

input group "===== Visualization ====="
input bool InpShowIndicatorsOnChart = true; // Attach BB/RSI indicators to the chart

//====================================================================
// TYPES
//====================================================================

enum ENUM_SIGNAL
{
   SIGNAL_NONE = 0,
   SIGNAL_BUY  = 1,
   SIGNAL_SELL = 2
};

struct SEngineState
{
   datetime lastBarTime;
   ulong    positionTicket;
   double   riskDistance;     // |entry - initial SL| for the currently tracked position
   bool     breakevenApplied;

   void Reset()
   {
      lastBarTime      = 0;
      positionTicket   = 0;
      riskDistance     = 0.0;
      breakevenApplied = false;
   }
};

//====================================================================
// CLogger - centralized, level-aware logging
//====================================================================

class CLogger
{
private:
   static bool s_verbose;

public:
   static void SetVerbose(const bool v) { s_verbose = v; }

   static void Debug(const string msg) { if(s_verbose) Print("[MRV][DEBUG] ", msg); }
   static void Info(const string msg)  { Print("[MRV][INFO] ",  msg); }
   static void Warn(const string msg)  { Print("[MRV][WARN] ",  msg); }
   static void Error(const string msg) { Print("[MRV][ERROR] ", msg); }
};
bool CLogger::s_verbose = false;

//====================================================================
// CTimeUtils - pure, stateless time helpers
//====================================================================

class CTimeUtils
{
public:
   static int MinutesOfDay(const datetime t)
   {
      MqlDateTime m; TimeToStruct(t, m);
      return m.hour * 60 + m.min;
   }

   // 0=Sunday .. 6=Saturday, matching MqlDateTime::day_of_week
   static int DayOfWeek(const datetime t)
   {
      MqlDateTime m; TimeToStruct(t, m);
      return m.day_of_week;
   }
};

//====================================================================
// CStateStore - GlobalVariable-backed persistence, namespaced per
// (magic, symbol) so multiple instances never collide.
//====================================================================

class CStateStore
{
private:
   string m_prefix;

public:
   void Init(const long magic, const string symbol)
   {
      m_prefix = StringFormat("MRV_%I64d_%s_", magic, symbol);
   }

   void Save(const SEngineState &s) const
   {
      GlobalVariableSet(m_prefix + "LastBar",  (double)s.lastBarTime);
      GlobalVariableSet(m_prefix + "Ticket",   (double)s.positionTicket);
      GlobalVariableSet(m_prefix + "Risk",     s.riskDistance);
      GlobalVariableSet(m_prefix + "BE",       s.breakevenApplied ? 1.0 : 0.0);
   }

   bool Load(SEngineState &s) const
   {
      if(!GlobalVariableCheck(m_prefix + "LastBar"))
         return false;

      s.lastBarTime      = (datetime)GlobalVariableGet(m_prefix + "LastBar");
      s.positionTicket   = (ulong)GlobalVariableGet(m_prefix + "Ticket");
      s.riskDistance     = GlobalVariableGet(m_prefix + "Risk");
      s.breakevenApplied = GlobalVariableGet(m_prefix + "BE") > 0.5;
      return true;
   }

   void Clear() const
   {
      GlobalVariableDel(m_prefix + "LastBar");
      GlobalVariableDel(m_prefix + "Ticket");
      GlobalVariableDel(m_prefix + "Risk");
      GlobalVariableDel(m_prefix + "BE");
   }
};

//====================================================================
// CIndicatorSet - owns indicator handles, exposes typed getters.
// Buffer index 0 in the returned arrays always corresponds to the
// requested 'shift' (as-series convention), matching Close[]/etc.
//====================================================================

class CIndicatorSet
{
private:
   int m_bbHandle;
   int m_rsiHandle;
   int m_atrHandle;
   int m_adxHandle;

public:
   CIndicatorSet() : m_bbHandle(INVALID_HANDLE), m_rsiHandle(INVALID_HANDLE),
                     m_atrHandle(INVALID_HANDLE), m_adxHandle(INVALID_HANDLE) {}

   bool Init(const string symbol)
   {
      m_bbHandle = iBands(symbol, InpBB_Timeframe, InpBB_Period, 0, InpBB_Deviation, InpBB_AppliedPrice);
      if(m_bbHandle == INVALID_HANDLE) { CLogger::Error("Failed to create iBands handle."); return false; }

      m_rsiHandle = iRSI(symbol, InpBB_Timeframe, InpRSI_Period, PRICE_CLOSE);
      if(m_rsiHandle == INVALID_HANDLE) { CLogger::Error("Failed to create iRSI handle."); return false; }

      m_atrHandle = iATR(symbol, InpBB_Timeframe, InpATR_Period);
      if(m_atrHandle == INVALID_HANDLE) { CLogger::Error("Failed to create iATR handle."); return false; }

      if(InpUseADXFilter)
      {
         m_adxHandle = iADX(symbol, InpBB_Timeframe, InpADX_Period);
         if(m_adxHandle == INVALID_HANDLE) { CLogger::Error("Failed to create iADX handle."); return false; }
      }
      return true;
   }

   void Deinit()
   {
      if(m_bbHandle  != INVALID_HANDLE) { IndicatorRelease(m_bbHandle);  m_bbHandle  = INVALID_HANDLE; }
      if(m_rsiHandle != INVALID_HANDLE) { IndicatorRelease(m_rsiHandle); m_rsiHandle = INVALID_HANDLE; }
      if(m_atrHandle != INVALID_HANDLE) { IndicatorRelease(m_atrHandle); m_atrHandle = INVALID_HANDLE; }
      if(m_adxHandle != INVALID_HANDLE) { IndicatorRelease(m_adxHandle); m_adxHandle = INVALID_HANDLE; }
   }

   int BandsHandle() const { return m_bbHandle; }
   int RsiHandle()   const { return m_rsiHandle; }

   bool GetBands(const int shift, double &mid, double &upper, double &lower) const
   {
      double midBuf[], upperBuf[], lowerBuf[];
      ArraySetAsSeries(midBuf, true);
      ArraySetAsSeries(upperBuf, true);
      ArraySetAsSeries(lowerBuf, true);

      if(CopyBuffer(m_bbHandle, 0, shift, 1, midBuf)   <= 0) return false;
      if(CopyBuffer(m_bbHandle, 1, shift, 1, upperBuf) <= 0) return false;
      if(CopyBuffer(m_bbHandle, 2, shift, 1, lowerBuf) <= 0) return false;

      mid   = midBuf[0];
      upper = upperBuf[0];
      lower = lowerBuf[0];
      return true;
   }

   bool GetRSI(const int shift, double &value) const
   {
      double buf[];
      ArraySetAsSeries(buf, true);
      if(CopyBuffer(m_rsiHandle, 0, shift, 1, buf) <= 0) return false;
      value = buf[0];
      return true;
   }

   bool GetATR(const int shift, double &value) const
   {
      double buf[];
      ArraySetAsSeries(buf, true);
      if(CopyBuffer(m_atrHandle, 0, shift, 1, buf) <= 0) return false;
      value = buf[0];
      return true;
   }

   bool GetADX(const int shift, double &value) const
   {
      if(m_adxHandle == INVALID_HANDLE) return false;
      double buf[];
      ArraySetAsSeries(buf, true);
      if(CopyBuffer(m_adxHandle, 0, shift, 1, buf) <= 0) return false;
      value = buf[0];
      return true;
   }
};

//====================================================================
// CRiskManager - position sizing from a risk amount + SL distance
//====================================================================

class CRiskManager
{
public:
   static bool CalculateLots(CSymbolInfo &sym, const double entryPrice, const double slPrice,
                              const ENUM_RISK_MODE mode, const double riskMoneyInput,
                              const double riskPercentInput, const double minVolumeFallback,
                              double &outLots)
   {
      outLots = 0.0;
      sym.RefreshRates();

      const double tickSize  = sym.TickSize();
      const double tickValue = sym.TickValue();
      const double volStep   = sym.LotsStep();
      const double volMin    = sym.LotsMin();
      const double volMax    = sym.LotsMax();

      if(tickSize <= 0.0 || tickValue <= 0.0)
      {
         CLogger::Error("Invalid tick size/value for " + sym.Name());
         return false;
      }

      const double slDistance = MathAbs(entryPrice - slPrice);
      if(slDistance <= 0.0)
      {
         CLogger::Error("Zero SL distance - cannot size position.");
         return false;
      }

      const double riskMoney = (mode == RISK_MODE_MONEY)
                                ? riskMoneyInput
                                : AccountInfoDouble(ACCOUNT_EQUITY) * (riskPercentInput / 100.0);

      if(riskMoney <= 0.0)
      {
         CLogger::Error("Computed risk amount is <= 0.");
         return false;
      }

      const double moneyPerLot = (slDistance / tickSize) * tickValue;
      if(moneyPerLot <= 0.0)
      {
         CLogger::Error("Computed money-per-lot is <= 0.");
         return false;
      }

      double lots = MathFloor((riskMoney / moneyPerLot) / volStep) * volStep;

      if(lots < volMin)
      {
         if(minVolumeFallback > 0.0)
         {
            lots = minVolumeFallback;
         }
         else
         {
            CLogger::Warn(StringFormat(
               "Calculated lot %.2f below broker minimum %.2f - risk too small for this SL distance, skipping.",
               lots, volMin));
            return false;
         }
      }
      if(lots > volMax) lots = volMax;

      outLots = NormalizeDouble(lots, 8);
      return true;
   }
};

//====================================================================
// CTradeEngine - orchestrates signal evaluation, entries, and
// in-trade management (breakeven / trailing / session close).
//====================================================================

class CTradeEngine
{
private:
   CTrade        m_trade;
   CSymbolInfo   m_sym;
   CStateStore   m_store;
   CIndicatorSet m_indicators;
   SEngineState  m_state;

public:
   bool Init()
   {
      CLogger::SetVerbose(InpVerboseLogging);

      if(!ValidateInputs())
         return false;

      if(!m_sym.Name(_Symbol))
      {
         CLogger::Error("Failed to initialize symbol info for " + _Symbol);
         return false;
      }

      m_trade.SetExpertMagicNumber(InpMagicNumber);
      m_trade.SetDeviationInPoints(InpSlippagePoints);
      m_trade.SetAsyncMode(false);
      m_trade.SetTypeFilling(DetectFillingMode());

      if(!m_indicators.Init(_Symbol))
         return false;

      m_store.Init(InpMagicNumber, _Symbol);

      if(m_store.Load(m_state))
      {
         // Reconcile: if the tracked ticket is no longer a live position of
         // ours, forget the associated risk context (either it closed while
         // the EA was offline, or it never really belonged to us).
         if(m_state.positionTicket != 0 && !IsOwnPositionTicket(m_state.positionTicket))
         {
            CLogger::Info("Tracked position ticket is no longer live - clearing risk-management state.");
            m_state.positionTicket   = 0;
            m_state.riskDistance     = 0.0;
            m_state.breakevenApplied = false;
         }

         // If a position exists live that we weren't tracking (e.g. state
         // file lost), adopt it but without a known risk distance so
         // breakeven/trailing stay safely disabled for that trade only.
         const ulong livePosition = GetOwnPositionTicket();
         if(livePosition != 0 && livePosition != m_state.positionTicket)
         {
            CLogger::Warn("Found an open position not in saved state; adopting it without breakeven/trailing context.");
            m_state.positionTicket   = livePosition;
            m_state.riskDistance     = 0.0;
            m_state.breakevenApplied = true; // prevents attempting BE with an unknown risk base
         }

         m_store.Save(m_state);
         CLogger::Info("State restored.");
      }
      else
      {
         m_state.Reset();
         const ulong livePosition = GetOwnPositionTicket();
         if(livePosition != 0)
         {
            m_state.positionTicket   = livePosition;
            m_state.breakevenApplied = true; // unknown risk base, keep BE/trailing off for this trade
         }
         m_store.Save(m_state);
         CLogger::Info("Starting fresh state.");
      }

      if(InpShowIndicatorsOnChart)
         AttachVisualIndicators();

      return true;
   }

   void Deinit(const int reason)
   {
      m_indicators.Deinit();

      if(reason == REASON_REMOVE || reason == REASON_CHARTCLOSE)
         m_store.Clear();
      else
         m_store.Save(m_state);
   }

   void Tick()
   {
      const datetime now = TimeCurrent();

      ManageExistingPosition(now);
      EvaluateEntriesOnNewBar(now);
   }

private:
   //--- input validation ---------------------------------------------
   bool ValidateInputs() const
   {
      if(InpBB_Period <= 1 || InpBB_Deviation <= 0.0)
      {
         CLogger::Error("Invalid Bollinger Bands period/deviation.");
         return false;
      }
      if(InpRSI_Period <= 1)
      {
         CLogger::Error("Invalid RSI period.");
         return false;
      }
      if(InpRSI_Oversold < 0.0 || InpRSI_Overbought > 100.0 || InpRSI_Oversold >= InpRSI_Overbought)
      {
         CLogger::Error("RSI Oversold must be < Overbought, both within [0,100].");
         return false;
      }
      if(InpATR_Period <= 1)
      {
         CLogger::Error("Invalid ATR period.");
         return false;
      }
      if(InpSLMode == SL_MODE_ATR && InpSL_ATRMultiplier <= 0.0)
      {
         CLogger::Error("SL ATR Multiplier must be > 0 in ATR SL mode.");
         return false;
      }
      if(InpSLMode == SL_MODE_BAND && InpSL_BandBufferPoints < 0)
      {
         CLogger::Error("SL Band Buffer Points cannot be negative.");
         return false;
      }
      if(InpTPMode == TP_MODE_RR_MULTIPLE && InpTP_RRMultiple <= 0.0)
      {
         CLogger::Error("TP RR Multiple must be > 0 in RR TP mode.");
         return false;
      }
      if(InpUseADXFilter && (InpADX_Period <= 1 || InpADX_MaxThreshold <= 0.0))
      {
         CLogger::Error("Invalid ADX Period/MaxThreshold when ADX filter is enabled.");
         return false;
      }
      if(InpUseBreakeven && InpBreakevenTriggerRR <= 0.0)
      {
         CLogger::Error("Breakeven Trigger RR must be > 0 when breakeven is enabled.");
         return false;
      }
      if(InpUseTrailingStop && InpTrailingStopPoints <= 0)
      {
         CLogger::Error("Trailing Stop Points must be > 0 when trailing is enabled.");
         return false;
      }
      if(InpUseSessionFilter &&
         (InpSessionStartHour < 0 || InpSessionStartHour > 23 || InpSessionEndHour < 0 || InpSessionEndHour > 23 ||
          InpSessionStartMinute < 0 || InpSessionStartMinute > 59 || InpSessionEndMinute < 0 || InpSessionEndMinute > 59))
      {
         CLogger::Error("Invalid session hour/minute input(s).");
         return false;
      }
      if(InpRiskMode == RISK_MODE_MONEY && InpRiskMoney <= 0.0)
      {
         CLogger::Error("Fixed risk money must be > 0.");
         return false;
      }
      if(InpRiskMode == RISK_MODE_PERCENT && InpRiskPercent <= 0.0)
      {
         CLogger::Error("Risk percent must be > 0.");
         return false;
      }
      if(InpMagicNumber <= 0)
      {
         CLogger::Error("Magic Number must be a positive integer.");
         return false;
      }
      return true;
   }

   //--- ownership helpers ----------------------------------------------
   bool IsOwnPositionTicket(const ulong ticket) const
   {
      if(!PositionSelectByTicket(ticket)) return false;
      return (PositionGetInteger(POSITION_MAGIC) == InpMagicNumber &&
              PositionGetString(POSITION_SYMBOL) == _Symbol);
   }

   ulong GetOwnPositionTicket() const
   {
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         const ulong ticket = PositionGetTicket(i);
         if(ticket == 0) continue;
         if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
            PositionGetInteger(POSITION_MAGIC)  == InpMagicNumber)
            return ticket;
      }
      return 0;
   }

   ENUM_ORDER_TYPE_FILLING DetectFillingMode() const
   {
      const long mask = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
      if((mask & SYMBOL_FILLING_FOK) != 0) return ORDER_FILLING_FOK;
      if((mask & SYMBOL_FILLING_IOC) != 0) return ORDER_FILLING_IOC;
      return ORDER_FILLING_RETURN;
   }

   //--- filters ----------------------------------------------------------
   bool IsTradingDayAllowed(const datetime now) const
   {
      switch(CTimeUtils::DayOfWeek(now))
      {
         case 0: return InpTradeSunday;
         case 1: return InpTradeMonday;
         case 2: return InpTradeTuesday;
         case 3: return InpTradeWednesday;
         case 4: return InpTradeThursday;
         case 5: return InpTradeFriday;
         case 6: return InpTradeSaturday;
         default: return true;
      }
   }

   bool IsWithinSession(const datetime now) const
   {
      if(!InpUseSessionFilter) return true;

      const int nowMin   = CTimeUtils::MinutesOfDay(now);
      const int startMin = InpSessionStartHour * 60 + InpSessionStartMinute;
      const int endMin   = InpSessionEndHour   * 60 + InpSessionEndMinute;

      if(startMin <= endMin)
         return nowMin >= startMin && nowMin < endMin;
      return nowMin >= startMin || nowMin < endMin; // overnight session wrap
   }

   //--- visualization ------------------------------------------------
   void AttachVisualIndicators()
   {
      if(!ChartIndicatorAdd(0, 0, m_indicators.BandsHandle()))
         CLogger::Debug("Could not attach Bollinger Bands to chart (non-critical).");

      const int subWindow = (int)ChartGetInteger(0, CHART_WINDOWS_TOTAL);
      if(!ChartIndicatorAdd(0, subWindow, m_indicators.RsiHandle()))
         CLogger::Debug("Could not attach RSI to chart (non-critical).");
   }

   //--- signal evaluation ----------------------------------------------
   ENUM_SIGNAL EvaluateSignal() const
   {
      double mid1, upper1, lower1;
      if(!m_indicators.GetBands(1, mid1, upper1, lower1)) return SIGNAL_NONE;

      double rsi1;
      if(!m_indicators.GetRSI(1, rsi1)) return SIGNAL_NONE;

      if(InpUseADXFilter)
      {
         double adx1;
         if(!m_indicators.GetADX(1, adx1)) return SIGNAL_NONE;
         if(adx1 > InpADX_MaxThreshold) return SIGNAL_NONE; // trending too strongly for mean reversion
      }

      const double close1 = iClose(_Symbol, InpBB_Timeframe, 1);
      if(close1 <= 0.0) return SIGNAL_NONE; // history not ready

      bool buyCondition, sellCondition;

      if(InpRequireBandReentry)
      {
         double mid2, upper2, lower2, rsi2;
         if(!m_indicators.GetBands(2, mid2, upper2, lower2)) return SIGNAL_NONE;
         if(!m_indicators.GetRSI(2, rsi2)) return SIGNAL_NONE;
         const double close2 = iClose(_Symbol, InpBB_Timeframe, 2);
         if(close2 <= 0.0) return SIGNAL_NONE;

         buyCondition  = (close2 <= lower2) && (close1 > lower1) && (rsi1 <= InpRSI_Oversold);
         sellCondition = (close2 >= upper2) && (close1 < upper1) && (rsi1 >= InpRSI_Overbought);
      }
      else
      {
         buyCondition  = (close1 <= lower1) && (rsi1 <= InpRSI_Oversold);
         sellCondition = (close1 >= upper1) && (rsi1 >= InpRSI_Overbought);
      }

      if(buyCondition)  return SIGNAL_BUY;
      if(sellCondition) return SIGNAL_SELL;
      return SIGNAL_NONE;
   }

   //--- entry evaluation, gated to once per new bar ----------------------
   void EvaluateEntriesOnNewBar(const datetime now)
   {
      const datetime barTime = iTime(_Symbol, InpBB_Timeframe, 0);
      if(barTime == 0 || barTime == m_state.lastBarTime)
         return;

      m_state.lastBarTime = barTime;
      m_store.Save(m_state);

      if(!IsTradingDayAllowed(now)) return;
      if(!IsWithinSession(now))     return;

      const ulong currentTicket = GetOwnPositionTicket();

      if(currentTicket != 0)
      {
         if(!InpCloseOnOppositeSignal) return;

         const ENUM_SIGNAL signal = EvaluateSignal();
         if(signal == SIGNAL_NONE) return;

         if(!PositionSelectByTicket(currentTicket)) return;
         const bool currentIsBuy = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
         const bool signalIsBuy  = (signal == SIGNAL_BUY);
         if(currentIsBuy == signalIsBuy) return; // same direction, no pyramiding

         ClosePosition(currentTicket, "opposite signal");
         OpenPosition(signal);
         return;
      }

      const ENUM_SIGNAL signal = EvaluateSignal();
      if(signal == SIGNAL_NONE) return;

      OpenPosition(signal);
   }

   //--- order placement --------------------------------------------------
   void OpenPosition(const ENUM_SIGNAL signal)
   {
      if(InpMaxSpreadPoints > 0)
      {
         const long spreadPoints = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
         if(spreadPoints > InpMaxSpreadPoints)
         {
            CLogger::Debug(StringFormat("Spread %d pts exceeds max %d pts - skipping entry.", (int)spreadPoints, InpMaxSpreadPoints));
            return;
         }
      }

      m_sym.RefreshRates();
      const double point  = m_sym.Point();
      const int    digits = (int)m_sym.Digits();

      double mid1, upper1, lower1;
      if(!m_indicators.GetBands(1, mid1, upper1, lower1))
      {
         CLogger::Warn("Could not read bands for order placement - skipping.");
         return;
      }
      double atr1;
      if(!m_indicators.GetATR(1, atr1))
      {
         CLogger::Warn("Could not read ATR for order placement - skipping.");
         return;
      }

      const bool   isBuy      = (signal == SIGNAL_BUY);
      const double entryPrice = isBuy ? m_sym.Ask() : m_sym.Bid();

      double sl;
      if(InpSLMode == SL_MODE_ATR)
         sl = isBuy ? entryPrice - atr1 * InpSL_ATRMultiplier : entryPrice + atr1 * InpSL_ATRMultiplier;
      else
         sl = isBuy ? lower1 - InpSL_BandBufferPoints * point : upper1 + InpSL_BandBufferPoints * point;
      sl = NormalizeDouble(sl, digits);

      const double riskDistance = MathAbs(entryPrice - sl);
      if(riskDistance <= 0.0)
      {
         CLogger::Warn("Computed zero risk distance - skipping entry.");
         return;
      }

      double tp;
      if(InpTPMode == TP_MODE_MIDDLE_BAND)
         tp = NormalizeDouble(mid1, digits);
      else
         tp = NormalizeDouble(isBuy ? entryPrice + riskDistance * InpTP_RRMultiple
                                     : entryPrice - riskDistance * InpTP_RRMultiple, digits);

      const int    stopLevelPoints = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
      const double minStopDistance = stopLevelPoints * point;
      if(MathAbs(entryPrice - sl) < minStopDistance || (tp != 0.0 && MathAbs(entryPrice - tp) < minStopDistance))
      {
         CLogger::Warn(StringFormat("SL/TP too close to price vs. broker stop level (%d pts) - skipping entry.", stopLevelPoints));
         return;
      }

      double lots = 0.0;
      if(!CRiskManager::CalculateLots(m_sym, entryPrice, sl, InpRiskMode, InpRiskMoney, InpRiskPercent, InpMinVolumeFallback, lots))
         return;

      const bool sent = isBuy ? m_trade.Buy(lots, _Symbol, entryPrice, sl, tp, InpTradeComment)
                                : m_trade.Sell(lots, _Symbol, entryPrice, sl, tp, InpTradeComment);

      if(!sent)
      {
         CLogger::Error(StringFormat("%s order failed, retcode=%d %s",
                        isBuy ? "Buy" : "Sell", m_trade.ResultRetcode(), m_trade.ResultRetcodeDescription()));
         return;
      }

      const ulong newTicket = GetOwnPositionTicket();
      m_state.positionTicket   = newTicket;
      m_state.riskDistance     = riskDistance;
      m_state.breakevenApplied = false;
      m_store.Save(m_state);

      CLogger::Info(StringFormat("%s opened #%I64u @ %.*f SL=%.*f TP=%.*f lots=%.2f",
                    isBuy ? "BUY" : "SELL", newTicket, digits, entryPrice, digits, sl, digits, tp, lots));
   }

   void ClosePosition(const ulong ticket, const string reason)
   {
      if(m_trade.PositionClose(ticket, InpSlippagePoints))
      {
         CLogger::Info(StringFormat("Closed position #%I64u (%s)", ticket, reason));
         m_state.positionTicket   = 0;
         m_state.riskDistance     = 0.0;
         m_state.breakevenApplied = false;
         m_store.Save(m_state);
      }
      else
      {
         CLogger::Error(StringFormat("Failed to close position #%I64u retcode=%d", ticket, m_trade.ResultRetcode()));
      }
   }

   //--- in-trade management, runs every tick -----------------------------
   void ManageExistingPosition(const datetime now)
   {
      const ulong ticket = GetOwnPositionTicket();

      if(ticket == 0)
      {
         if(m_state.positionTicket != 0)
         {
            // The position we were tracking is gone (SL/TP hit or manual close)
            m_state.positionTicket   = 0;
            m_state.riskDistance     = 0.0;
            m_state.breakevenApplied = false;
            m_store.Save(m_state);
         }
         return;
      }

      if(m_state.positionTicket != ticket)
      {
         // A position exists that we weren't tracking (shouldn't normally
         // happen outside of the OnInit reconciliation path, but handle it
         // defensively rather than silently mismanaging an unknown trade).
         m_state.positionTicket   = ticket;
         m_state.riskDistance     = 0.0;
         m_state.breakevenApplied = true; // unknown risk base, keep BE/trailing off
         m_store.Save(m_state);
         CLogger::Warn("Adopted an untracked open position defensively; breakeven/trailing disabled for it.");
      }

      if(InpUseBreakeven || InpUseTrailingStop)
         ManageBreakevenAndTrailing(ticket);

      if(InpUseSessionFilter && InpCloseOutsideSession && !IsWithinSession(now))
         ClosePosition(ticket, "outside session");
   }

   void ManageBreakevenAndTrailing(const ulong ticket)
   {
      if(!PositionSelectByTicket(ticket)) return;
      if(m_state.riskDistance <= 0.0)     return; // safety: nothing to base R-multiples on

      const long   type       = PositionGetInteger(POSITION_TYPE);
      const double entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      const double currentSL  = PositionGetDouble(POSITION_SL);
      const double currentTP  = PositionGetDouble(POSITION_TP);
      const bool   isBuy      = (type == POSITION_TYPE_BUY);

      m_sym.RefreshRates();
      const double point        = m_sym.Point();
      const int    digits       = (int)m_sym.Digits();
      const double currentPrice = isBuy ? m_sym.Bid() : m_sym.Ask();

      const double profitDistance  = isBuy ? (currentPrice - entryPrice) : (entryPrice - currentPrice);
      const double triggerDistance = m_state.riskDistance * InpBreakevenTriggerRR;

      if(profitDistance < triggerDistance)
         return;

      const int    stopLevelPoints = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
      const double minStopDistance = stopLevelPoints * point;

      double newSL   = currentSL;
      bool   changed = false;

      if(InpUseBreakeven && !m_state.breakevenApplied)
      {
         const double beOffset = InpBreakevenOffsetPoints * point;
         const double beSL = isBuy ? NormalizeDouble(entryPrice + beOffset, digits)
                                    : NormalizeDouble(entryPrice - beOffset, digits);
         const bool improves = isBuy ? (beSL > currentSL) : (beSL < currentSL || currentSL == 0.0);

         if(improves && MathAbs(currentPrice - beSL) >= minStopDistance)
         {
            newSL   = beSL;
            changed = true;
         }
      }

      if(InpUseTrailingStop)
      {
         const double trailDist = InpTrailingStopPoints * point;
         const double candidate = isBuy ? NormalizeDouble(currentPrice - trailDist, digits)
                                         : NormalizeDouble(currentPrice + trailDist, digits);

         const double baseline  = changed ? newSL : currentSL;
         const double stepDist  = InpTrailingStepPoints * point;
         const bool improvesEnough = isBuy ? (candidate - baseline >= stepDist)
                                            : (baseline - candidate >= stepDist);

         if(improvesEnough && MathAbs(currentPrice - candidate) >= minStopDistance)
         {
            newSL   = candidate;
            changed = true;
         }
      }

      if(!changed) return;

      if(m_trade.PositionModify(ticket, newSL, currentTP))
      {
         if(InpUseBreakeven && !m_state.breakevenApplied)
         {
            m_state.breakevenApplied = true;
            m_store.Save(m_state);
         }
         CLogger::Debug(StringFormat("SL updated to %.*f for ticket #%I64u", digits, newSL, ticket));
      }
      else
      {
         CLogger::Debug(StringFormat("PositionModify failed retcode=%d", m_trade.ResultRetcode()));
      }
   }
};

//====================================================================
// EXPERT EVENT HANDLERS - thin adapters delegating to CTradeEngine
//====================================================================

CTradeEngine g_engine;

int OnInit()
{
   if(!g_engine.Init())
      return(INIT_PARAMETERS_INCORRECT);
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   g_engine.Deinit(reason);
}

void OnTick()
{
   g_engine.Tick();
}

//+------------------------------------------------------------------+