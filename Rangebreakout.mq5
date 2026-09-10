//+------------------------------------------------------------------+
//|                                        DailyRangeBreakout.mq5     |
//|                        Daily Range Breakout Expert Advisor       |
//|                                                                    |
//| Strategy:                                                          |
//|  - Build a price range between InpRangeStart and InpRangeEnd       |
//|  - At range end, place BuyStop at range high / SellStop at low     |
//|  - SL of each order = opposite side of range                       |
//|  - TP = RangeSize * InpTP_RangeMultiplier (0 = no TP)               |
//|  - When one order triggers, the sibling pending order is deleted   |
//|  - At InpCloseTime, all EA positions are closed and all EA         |
//|    pending orders are deleted; daily state resets for next day     |
//|                                                                    |
//| Safety:                                                             |
//|  - Only manages orders/positions with InpMagicNumber on _Symbol    |
//|  - State persisted via GlobalVariables, reconciled on restart      |
//|  - Optimizer friendly (all inputs are numeric/enum, no strings     |
//|    required for logic)                                             |
//+------------------------------------------------------------------+
#property copyright "Daily Range Breakout EA"
#property version   "1.00"

#include <Trade\Trade.mqh>
#include <Trade\SymbolInfo.mqh>

//====================================================================
// INPUTS
//====================================================================

enum ENUM_RISK_MODE
{
   RISK_MODE_MONEY   = 0, // Fixed monetary amount
   RISK_MODE_PERCENT = 1  // Percentage of account equity
};

input group "===== Range Definition ====="
input int    InpRangeStartHour   = 3;     // Range Start Hour   (0-23, server time)
input int    InpRangeStartMinute = 0;     // Range Start Minute (0-59)
input int    InpRangeEndHour     = 6;     // Range End Hour     (0-23, server time)
input int    InpRangeEndMinute   = 0;     // Range End Minute   (0-59)

input group "===== Daily Close ====="
input int    InpCloseHour        = 18;    // Daily Close Hour   (0-23, server time)
input int    InpCloseMinute      = 0;     // Daily Close Minute (0-59)

input group "===== Take Profit ====="
input double InpTP_RangeMultiplier = 2.0; // TP = Range Size x Multiplier (0 = no TP)

input group "===== Risk Management ====="
input ENUM_RISK_MODE InpRiskMode   = RISK_MODE_PERCENT; // Risk Mode
input double InpRiskMoney          = 100.0;             // Fixed Risk (account currency)
input double InpRiskPercent        = 1.0;               // Risk (% of Equity)

input group "===== Order Execution ====="
input int    InpBufferPoints     = 0;     // Extra buffer added to entries/SL (points, 0=off)
input int    InpSlippagePoints   = 20;    // Max allowed slippage/deviation (points)
input double InpMinVolumeFallback = 0.0;  // If >0, used when calc lot < broker min (0=skip trade instead)

input group "===== General ====="
input long   InpMagicNumber      = 20260910; // Magic Number (unique per EA instance)
input string InpTradeComment     = "DRB_EA"; // Order/Position comment

input group "===== Visualization ====="
input bool   InpShowRangeObjects = true;             // Draw range box on chart
input color  InpRangeColor       = clrDodgerBlue;     // Range box color
input color  InpHighLineColor    = clrLimeGreen;      // High line color
input color  InpLowLineColor     = clrOrangeRed;      // Low line color

//====================================================================
// GLOBAL STATE
//====================================================================

CTrade         trade;
CSymbolInfo    symInfo;

enum ENUM_DAY_STATE
{
   STATE_IDLE          = 0, // waiting for range window to start
   STATE_BUILDING      = 1, // inside range window, accumulating high/low
   STATE_ORDERS_PLACED = 2, // range finished, both pending orders live
   STATE_IN_TRADE      = 3, // one order triggered, position open
   STATE_DONE          = 4  // day finished (closed / no-trade / invalid range)
};

ENUM_DAY_STATE g_state        = STATE_IDLE;
int            g_currentDay   = -1;     // YYYYMMDD of the day currently tracked
double         g_rangeHigh    = 0.0;
double         g_rangeLow     = 0.0;
bool           g_rangeInit    = false;  // has at least one price been sampled today
ulong          g_buyTicket    = 0;
ulong          g_sellTicket   = 0;
bool           g_buyPlaced    = false; // true if a BuyStop was successfully sent today
bool           g_sellPlaced   = false; // true if a SellStop was successfully sent today

string         g_gvPrefix;              // unique global-variable namespace for this symbol+magic
string         g_objPrefix;             // unique chart-object namespace for this symbol+magic

//====================================================================
// UTILITY: date helpers
//====================================================================

int DayKeyFromTime(const datetime t)
{
   MqlDateTime m;
   TimeToStruct(t, m);
   return m.year * 10000 + m.mon * 100 + m.day;
}

string DayStringFromTime(const datetime t)
{
   MqlDateTime m;
   TimeToStruct(t, m);
   return StringFormat("%04d%02d%02d", m.year, m.mon, m.day);
}

int MinutesOfDay(const datetime t)
{
   MqlDateTime m;
   TimeToStruct(t, m);
   return m.hour * 60 + m.min;
}

datetime TimeAtHourMinute(const datetime t, const int hour, const int minute)
{
   MqlDateTime m;
   TimeToStruct(t, m);
   m.hour = hour;
   m.min  = minute;
   m.sec  = 0;
   return StructToTime(m);
}

//====================================================================
// UTILITY: GlobalVariable persistence
//====================================================================

void BuildNamespaces()
{
   g_gvPrefix  = StringFormat("DRB_%I64d_%s_", InpMagicNumber, _Symbol);
   g_objPrefix = StringFormat("DRB_%I64d_%s_", InpMagicNumber, _Symbol);
}

void SaveState()
{
   GlobalVariableSet(g_gvPrefix + "Day",        (double)g_currentDay);
   GlobalVariableSet(g_gvPrefix + "State",      (double)g_state);
   GlobalVariableSet(g_gvPrefix + "High",       g_rangeHigh);
   GlobalVariableSet(g_gvPrefix + "Low",        g_rangeLow);
   GlobalVariableSet(g_gvPrefix + "Init",       g_rangeInit ? 1.0 : 0.0);
   GlobalVariableSet(g_gvPrefix + "BuyTicket",  (double)g_buyTicket);
   GlobalVariableSet(g_gvPrefix + "SellTicket", (double)g_sellTicket);
   GlobalVariableSet(g_gvPrefix + "BuyPlaced",  g_buyPlaced  ? 1.0 : 0.0);
   GlobalVariableSet(g_gvPrefix + "SellPlaced", g_sellPlaced ? 1.0 : 0.0);
}

bool LoadState()
{
   if(!GlobalVariableCheck(g_gvPrefix + "Day"))
      return false;

   g_currentDay = (int)GlobalVariableGet(g_gvPrefix + "Day");
   g_state      = (ENUM_DAY_STATE)(int)GlobalVariableGet(g_gvPrefix + "State");
   g_rangeHigh  = GlobalVariableGet(g_gvPrefix + "High");
   g_rangeLow   = GlobalVariableGet(g_gvPrefix + "Low");
   g_rangeInit  = GlobalVariableGet(g_gvPrefix + "Init") > 0.5;
   g_buyTicket  = (ulong)GlobalVariableGet(g_gvPrefix + "BuyTicket");
   g_sellTicket = (ulong)GlobalVariableGet(g_gvPrefix + "SellTicket");
   g_buyPlaced  = GlobalVariableCheck(g_gvPrefix + "BuyPlaced")  && GlobalVariableGet(g_gvPrefix + "BuyPlaced")  > 0.5;
   g_sellPlaced = GlobalVariableCheck(g_gvPrefix + "SellPlaced") && GlobalVariableGet(g_gvPrefix + "SellPlaced") > 0.5;
   return true;
}

//====================================================================
// UTILITY: ownership filters (magic + symbol only — never touch others)
//====================================================================

bool IsOwnOrder(const ulong ticket)
{
   if(!OrderSelect(ticket))
      return false;
   return (OrderGetInteger(ORDER_MAGIC) == InpMagicNumber &&
           OrderGetString(ORDER_SYMBOL) == _Symbol);
}

bool HasOwnOpenPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC)  == InpMagicNumber)
         return true;
   }
   return false;
}

//====================================================================
// RECONCILIATION: rebuild in-memory state from live terminal state
// (used on OnInit in case GlobalVariables are missing/stale, or the
//  terminal was closed mid-cycle and tickets were manually touched)
//====================================================================

void ReconcileWithLiveState()
{
   bool buyLive  = (g_buyPlaced  && g_buyTicket  != 0 && IsOwnOrder(g_buyTicket));
   bool sellLive = (g_sellPlaced && g_sellTicket != 0 && IsOwnOrder(g_sellTicket));
   bool posLive  = HasOwnOpenPosition();

   if(posLive)
   {
      g_state = STATE_IN_TRADE;
      // any leftover sibling pending order must be removed
      if(buyLive)  { trade.OrderDelete(g_buyTicket);  g_buyTicket  = 0; }
      if(sellLive) { trade.OrderDelete(g_sellTicket); g_sellTicket = 0; }
   }
   else if(g_buyPlaced && g_sellPlaced)
   {
      // both sides were originally placed
      if(buyLive && sellLive)
         g_state = STATE_ORDERS_PLACED;
      else
      {
         // one vanished while EA was offline (triggered+closed already, or
         // manually removed) — cancel the remaining side, day is done since
         // we cannot safely resume an OCO pair with an unknown outcome.
         if(buyLive)  trade.OrderDelete(g_buyTicket);
         if(sellLive) trade.OrderDelete(g_sellTicket);
         g_buyTicket  = 0;
         g_sellTicket = 0;
         g_state = STATE_DONE;
      }
   }
   else if(g_buyPlaced || g_sellPlaced)
   {
      // only a single side was ever placed (other side's sizing failed) —
      // no OCO pair exists, just verify the lone order is still there.
      if(!buyLive)  g_buyTicket  = 0;
      if(!sellLive) g_sellTicket = 0;
      g_state = (buyLive || sellLive) ? STATE_ORDERS_PLACED : STATE_DONE;
   }
   else
   {
      g_buyTicket  = 0;
      g_sellTicket = 0;
      // keep g_state as loaded (IDLE / BUILDING / DONE) — will be
      // re-evaluated naturally by the OnTick state machine
      if(g_state == STATE_ORDERS_PLACED || g_state == STATE_IN_TRADE)
         g_state = STATE_DONE; // safety net: nothing live, don't re-arm mid-day
   }
}

//====================================================================
// DAILY RESET
//====================================================================

void ResetDailyState(const int newDayKey)
{
   g_currentDay = newDayKey;
   g_state      = STATE_IDLE;
   g_rangeHigh  = 0.0;
   g_rangeLow   = 0.0;
   g_rangeInit  = false;
   g_buyTicket  = 0;
   g_sellTicket = 0;
   g_buyPlaced  = false;
   g_sellPlaced = false;
   SaveState();
}

//====================================================================
// VISUALIZATION
//====================================================================

void DrawRange(const datetime rangeStart, const datetime rangeEnd,
               const double high, const double low)
{
   if(!InpShowRangeObjects) return;

   string day     = DayStringFromTime(rangeStart);
   string boxName = g_objPrefix + day + "_Box";
   string hiName  = g_objPrefix + day + "_High";
   string loName  = g_objPrefix + day + "_Low";

   datetime extendTo = rangeEnd + PeriodSeconds(PERIOD_D1) / 3; // extend visual a bit into the day

   if(ObjectFind(0, boxName) < 0)
      ObjectCreate(0, boxName, OBJ_RECTANGLE, 0, rangeStart, high, rangeEnd, low);
   else
   {
      ObjectMove(0, boxName, 0, rangeStart, high);
      ObjectMove(0, boxName, 1, rangeEnd,   low);
   }
   ObjectSetInteger(0, boxName, OBJPROP_COLOR,  InpRangeColor);
   ObjectSetInteger(0, boxName, OBJPROP_FILL,   false);
   ObjectSetInteger(0, boxName, OBJPROP_STYLE,  STYLE_SOLID);
   ObjectSetInteger(0, boxName, OBJPROP_WIDTH,  1);
   ObjectSetInteger(0, boxName, OBJPROP_BACK,   true);
   ObjectSetInteger(0, boxName, OBJPROP_SELECTABLE, false);

   if(ObjectFind(0, hiName) < 0)
      ObjectCreate(0, hiName, OBJ_TREND, 0, rangeEnd, high, extendTo, high);
   else
   {
      ObjectMove(0, hiName, 0, rangeEnd, high);
      ObjectMove(0, hiName, 1, extendTo, high);
   }
   ObjectSetInteger(0, hiName, OBJPROP_COLOR, InpHighLineColor);
   ObjectSetInteger(0, hiName, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, hiName, OBJPROP_SELECTABLE, false);

   if(ObjectFind(0, loName) < 0)
      ObjectCreate(0, loName, OBJ_TREND, 0, rangeEnd, low, extendTo, low);
   else
   {
      ObjectMove(0, loName, 0, rangeEnd, low);
      ObjectMove(0, loName, 1, extendTo, low);
   }
   ObjectSetInteger(0, loName, OBJPROP_COLOR, InpLowLineColor);
   ObjectSetInteger(0, loName, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, loName, OBJPROP_SELECTABLE, false);
}

void DeleteAllOwnObjects()
{
   int total = ObjectsTotal(0, 0, -1);
   for(int i = total - 1; i >= 0; i--)
   {
      string name = ObjectName(0, i, 0, -1);
      if(StringFind(name, g_objPrefix) == 0)
         ObjectDelete(0, name);
   }
}

//====================================================================
// LOT SIZE CALCULATION
//====================================================================

bool CalculateLotSize(const double entryPrice, const double slPrice, double &outLots)
{
   outLots = 0.0;

   if(!symInfo.Name(_Symbol)) return false;
   symInfo.RefreshRates();

   double tickSize  = symInfo.TickSize();
   double tickValue = symInfo.TickValue();
   double volStep   = symInfo.LotsStep();
   double volMin    = symInfo.LotsMin();
   double volMax    = symInfo.LotsMax();

   if(tickSize <= 0.0 || tickValue <= 0.0)
   {
      Print("DRB: invalid tick size/value for ", _Symbol);
      return false;
   }

   double slDistance = MathAbs(entryPrice - slPrice);
   if(slDistance <= 0.0)
   {
      Print("DRB: zero SL distance, cannot size position");
      return false;
   }

   double riskMoney = 0.0;
   if(InpRiskMode == RISK_MODE_MONEY)
      riskMoney = InpRiskMoney;
   else
      riskMoney = AccountInfoDouble(ACCOUNT_EQUITY) * (InpRiskPercent / 100.0);

   if(riskMoney <= 0.0)
   {
      Print("DRB: computed risk amount is <= 0");
      return false;
   }

   double moneyPerLot = (slDistance / tickSize) * tickValue;
   if(moneyPerLot <= 0.0)
   {
      Print("DRB: computed moneyPerLot is <= 0");
      return false;
   }

   double lots = riskMoney / moneyPerLot;

   // normalize to broker constraints
   lots = MathFloor(lots / volStep) * volStep;

   if(lots < volMin)
   {
      if(InpMinVolumeFallback > 0.0)
         lots = InpMinVolumeFallback;
      else
      {
         Print("DRB: calculated lot ", DoubleToString(lots, 2),
               " is below broker minimum ", DoubleToString(volMin, 2),
               " — skipping trade (risk too small for this SL distance).");
         return false;
      }
   }
   if(lots > volMax)
      lots = volMax;

   outLots = NormalizeDouble(lots, 8);
   return true;
}

//====================================================================
// ORDER FILLING MODE (auto-detect, per symbol)
//====================================================================

ENUM_ORDER_TYPE_FILLING DetectFillingMode()
{
   long fillingMask = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);

   if((fillingMask & SYMBOL_FILLING_FOK) != 0)
      return ORDER_FILLING_FOK;
   if((fillingMask & SYMBOL_FILLING_IOC) != 0)
      return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN;
}

//====================================================================
// PLACE BREAKOUT ORDERS
//====================================================================

void PlaceBreakoutOrders(const datetime rangeStart, const datetime rangeEnd)
{
   if(!symInfo.Name(_Symbol)) return;
   symInfo.RefreshRates();

   double point   = symInfo.Point();
   int    digits  = (int)symInfo.Digits();
   double buffer  = InpBufferPoints * point;

   double high = g_rangeHigh;
   double low  = g_rangeLow;
   double rangeSize = high - low;

   int stopLevelPoints = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minStopDistance = stopLevelPoints * point;

   double ask = symInfo.Ask();
   double bid = symInfo.Bid();

   // Sanity checks: degenerate range, or too close to current price for stops
   if(rangeSize <= 0.0 || rangeSize < 2 * point)
   {
      Print("DRB: range size invalid (", DoubleToString(rangeSize, digits), ") — skipping trading for today.");
      g_state = STATE_DONE;
      SaveState();
      return;
   }

   double buyEntry  = NormalizeDouble(high + buffer, digits);
   double sellEntry = NormalizeDouble(low  - buffer, digits);
   double buySL     = NormalizeDouble(low  - buffer, digits);
   double sellSL    = NormalizeDouble(high + buffer, digits);

   double buyTP  = 0.0;
   double sellTP = 0.0;
   if(InpTP_RangeMultiplier > 0.0)
   {
      buyTP  = NormalizeDouble(buyEntry  + rangeSize * InpTP_RangeMultiplier, digits);
      sellTP = NormalizeDouble(sellEntry - rangeSize * InpTP_RangeMultiplier, digits);
   }

   // Respect broker minimum stop distance from current market price
   if(MathAbs(buyEntry - ask) < minStopDistance || MathAbs(sellEntry - bid) < minStopDistance)
   {
      Print("DRB: range too close to current price vs. broker stop level (",
            stopLevelPoints, " pts) — skipping trading for today.");
      g_state = STATE_DONE;
      SaveState();
      return;
   }

   double lotsBuy = 0.0, lotsSell = 0.0;
   bool okBuy  = CalculateLotSize(buyEntry,  buySL,  lotsBuy);
   bool okSell = CalculateLotSize(sellEntry, sellSL, lotsSell);

   if(!okBuy && !okSell)
   {
      Print("DRB: lot size calculation failed for both sides — skipping trading for today.");
      g_state = STATE_DONE;
      SaveState();
      return;
   }

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippagePoints);

   ENUM_ORDER_TYPE_FILLING filling = DetectFillingMode();
   trade.SetTypeFilling(filling);

   g_buyTicket  = 0;
   g_sellTicket = 0;
   g_buyPlaced  = false;
   g_sellPlaced = false;

   if(okBuy)
   {
      if(trade.BuyStop(lotsBuy, buyEntry, _Symbol, buySL, buyTP, ORDER_TIME_GTC, 0, InpTradeComment))
      {
         g_buyTicket = trade.ResultOrder();
         g_buyPlaced = true;
      }
      else
         Print("DRB: BuyStop failed, retcode=", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
   }

   if(okSell)
   {
      if(trade.SellStop(lotsSell, sellEntry, _Symbol, sellSL, sellTP, ORDER_TIME_GTC, 0, InpTradeComment))
      {
         g_sellTicket = trade.ResultOrder();
         g_sellPlaced = true;
      }
      else
         Print("DRB: SellStop failed, retcode=", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
   }

   DrawRange(rangeStart, rangeEnd, high, low);

   if(g_buyTicket == 0 && g_sellTicket == 0)
      g_state = STATE_DONE;
   else
      g_state = STATE_ORDERS_PLACED;

   SaveState();
}

//====================================================================
// OCO MANAGEMENT: if one pending order is gone, cancel the other
//====================================================================

void ManageOCO()
{
   bool buyLive  = (g_buyPlaced  && g_buyTicket  != 0 && IsOwnOrder(g_buyTicket));
   bool sellLive = (g_sellPlaced && g_sellTicket != 0 && IsOwnOrder(g_sellTicket));
   bool posLive  = HasOwnOpenPosition();

   // --- Case: both sides were originally placed -> true OCO pair ---
   if(g_buyPlaced && g_sellPlaced)
   {
      if(buyLive && sellLive)
         return; // still both waiting, nothing to do

      if(!buyLive && sellLive)
      {
         trade.OrderDelete(g_sellTicket); // buy side triggered -> cancel sell
         g_sellTicket = 0;
         g_buyTicket  = 0;
         g_state = posLive ? STATE_IN_TRADE : STATE_DONE;
         SaveState();
      }
      else if(buyLive && !sellLive)
      {
         trade.OrderDelete(g_buyTicket); // sell side triggered -> cancel buy
         g_buyTicket  = 0;
         g_sellTicket = 0;
         g_state = posLive ? STATE_IN_TRADE : STATE_DONE;
         SaveState();
      }
      else // both already gone (expired/removed) without a live position
      {
         g_buyTicket  = 0;
         g_sellTicket = 0;
         g_state = posLive ? STATE_IN_TRADE : STATE_DONE;
         SaveState();
      }
      return;
   }

   // --- Case: only one side was ever placed -> no sibling to cancel,
   //           just track whether that lone order is still pending ---
   if(g_buyPlaced && !g_sellPlaced)
   {
      if(!buyLive)
      {
         g_buyTicket = 0;
         g_state = posLive ? STATE_IN_TRADE : STATE_DONE;
         SaveState();
      }
      return;
   }

   if(g_sellPlaced && !g_buyPlaced)
   {
      if(!sellLive)
      {
         g_sellTicket = 0;
         g_state = posLive ? STATE_IN_TRADE : STATE_DONE;
         SaveState();
      }
      return;
   }

   // Neither side placed — should not normally reach STATE_ORDERS_PLACED
   // in this case, but fail safe rather than looping forever.
   g_state = STATE_DONE;
   SaveState();
}

//====================================================================
// MONITOR OPEN TRADE: detect natural close (SL/TP hit) before CloseTime
//====================================================================

void MonitorInTrade()
{
   if(!HasOwnOpenPosition())
   {
      g_state = STATE_DONE;
      SaveState();
   }
}

//====================================================================
// DAILY CLOSE: flatten all own positions, delete all own pending orders
//====================================================================

void DoDailyClose()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC)  == InpMagicNumber)
      {
         if(!trade.PositionClose(ticket, InpSlippagePoints))
            Print("DRB: failed to close position #", ticket, " retcode=", trade.ResultRetcode());
      }
   }

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) == _Symbol &&
         OrderGetInteger(ORDER_MAGIC)  == InpMagicNumber)
      {
         if(!trade.OrderDelete(ticket))
            Print("DRB: failed to delete order #", ticket, " retcode=", trade.ResultRetcode());
      }
   }

   g_buyTicket  = 0;
   g_sellTicket = 0;
   g_buyPlaced  = false;
   g_sellPlaced = false;
   g_state = STATE_DONE;
   SaveState();
}

//====================================================================
// INPUT VALIDATION
//====================================================================

bool ValidateInputs()
{
   if(InpRangeStartHour < 0 || InpRangeStartHour > 23 ||
      InpRangeEndHour   < 0 || InpRangeEndHour   > 23 ||
      InpCloseHour      < 0 || InpCloseHour      > 23 ||
      InpRangeStartMinute < 0 || InpRangeStartMinute > 59 ||
      InpRangeEndMinute   < 0 || InpRangeEndMinute   > 59 ||
      InpCloseMinute      < 0 || InpCloseMinute      > 59)
   {
      Print("DRB: invalid hour/minute input(s).");
      return false;
   }

   int startMin = InpRangeStartHour * 60 + InpRangeStartMinute;
   int endMin   = InpRangeEndHour   * 60 + InpRangeEndMinute;
   int closeMin = InpCloseHour      * 60 + InpCloseMinute;

   if(startMin >= endMin)
   {
      Print("DRB: Range Start must be earlier than Range End (same-day ranges only).");
      return false;
   }
   if(closeMin <= endMin)
   {
      Print("DRB: Daily Close time must be after Range End time.");
      return false;
   }
   if(InpTP_RangeMultiplier < 0.0)
   {
      Print("DRB: TP_Range_Multiplier cannot be negative.");
      return false;
   }
   if(InpRiskMode == RISK_MODE_MONEY && InpRiskMoney <= 0.0)
   {
      Print("DRB: Fixed risk money must be > 0.");
      return false;
   }
   if(InpRiskMode == RISK_MODE_PERCENT && InpRiskPercent <= 0.0)
   {
      Print("DRB: Risk percent must be > 0.");
      return false;
   }
   if(InpMagicNumber <= 0)
   {
      Print("DRB: Magic Number must be a positive integer.");
      return false;
   }
   return true;
}

//====================================================================
// EXPERT EVENT HANDLERS
//====================================================================

int OnInit()
{
   if(!ValidateInputs())
      return(INIT_PARAMETERS_INCORRECT);

   if(!symInfo.Name(_Symbol))
   {
      Print("DRB: failed to initialize symbol info for ", _Symbol);
      return(INIT_FAILED);
   }

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippagePoints);
   trade.SetAsyncMode(false);

   BuildNamespaces();

   datetime now = TimeCurrent();
   int todayKey = DayKeyFromTime(now);

   if(LoadState() && g_currentDay == todayKey)
   {
      // Same trading day as before restart: reconcile stored tickets
      // against what is actually live in the terminal.
      ReconcileWithLiveState();
      SaveState();
      Print("DRB: state restored for today (state=", EnumToString(g_state), ")");
   }
   else
   {
      // Different day, or no prior state: start fresh. If mid-range or
      // past range-end already (e.g. EA attached mid-day), the OnTick
      // loop below will correctly pick up from wherever "now" is.
      ResetDailyState(todayKey);
      Print("DRB: starting fresh daily state for ", DayStringFromTime(now));
   }

   return(INIT_SUCCEEDED);
}

void DeleteState()
{
   GlobalVariableDel(g_gvPrefix + "Day");
   GlobalVariableDel(g_gvPrefix + "State");
   GlobalVariableDel(g_gvPrefix + "High");
   GlobalVariableDel(g_gvPrefix + "Low");
   GlobalVariableDel(g_gvPrefix + "Init");
   GlobalVariableDel(g_gvPrefix + "BuyTicket");
   GlobalVariableDel(g_gvPrefix + "SellTicket");
   GlobalVariableDel(g_gvPrefix + "BuyPlaced");
   GlobalVariableDel(g_gvPrefix + "SellPlaced");
}

void OnDeinit(const int reason)
{
   // REASON_REMOVE / REASON_CHARTCLOSE = user explicitly removed the EA or
   // closed the chart -> forget saved state, next attach starts fresh.
   // Any other reason (terminal shutdown/restart, recompile, parameter
   // change, account/timeframe switch) -> persist state so it can be
   // restored, per the "restore state on MT5 restart" requirement.
   if(reason == REASON_REMOVE || reason == REASON_CHARTCLOSE)
   {
      DeleteState();
      DeleteAllOwnObjects();
   }
   else
   {
      SaveState();
   }
}

void OnTick()
{
   datetime now = TimeCurrent();
   int todayKey = DayKeyFromTime(now);

   // --- Daily rollover ---
   if(todayKey != g_currentDay)
   {
      ResetDailyState(todayKey);
   }

   int nowMin    = MinutesOfDay(now);
   int startMin  = InpRangeStartHour * 60 + InpRangeStartMinute;
   int endMin    = InpRangeEndHour   * 60 + InpRangeEndMinute;
   int closeMin  = InpCloseHour      * 60 + InpCloseMinute;

   datetime rangeStartTime = TimeAtHourMinute(now, InpRangeStartHour, InpRangeStartMinute);
   datetime rangeEndTime   = TimeAtHourMinute(now, InpRangeEndHour,   InpRangeEndMinute);

   // --- Daily close: always checked first, highest priority ---
   if(nowMin >= closeMin && g_state != STATE_DONE)
   {
      DoDailyClose();
      return;
   }

   // --- State machine ---
   switch(g_state)
   {
      case STATE_IDLE:
      {
         if(nowMin >= startMin && nowMin < endMin)
         {
            symInfo.Name(_Symbol);
            symInfo.RefreshRates();
            double price = symInfo.Bid();
            g_rangeHigh = price;
            g_rangeLow  = price;
            g_rangeInit = true;
            g_state = STATE_BUILDING;
            SaveState();
         }
         break;
      }

      case STATE_BUILDING:
      {
         symInfo.Name(_Symbol);
         symInfo.RefreshRates();
         double price = symInfo.Bid();

         if(nowMin < endMin)
         {
            if(!g_rangeInit)
            {
               g_rangeHigh = price;
               g_rangeLow  = price;
               g_rangeInit = true;
            }
            else
            {
               if(price > g_rangeHigh) g_rangeHigh = price;
               if(price < g_rangeLow)  g_rangeLow  = price;
            }
            // Not saved every tick to reduce disk I/O; saved on range completion
            // and on OnDeinit. Acceptable: worst case on crash mid-build the
            // range restarts sampling from the restart point, which is safe
            // (never places an order without a completed window).
         }
         else
         {
            // Range window just ended -> finalize and place orders
            if(!g_rangeInit)
            {
               Print("DRB: range window elapsed without any price sample — skipping today.");
               g_state = STATE_DONE;
               SaveState();
            }
            else
            {
               PlaceBreakoutOrders(rangeStartTime, rangeEndTime);
            }
         }
         break;
      }

      case STATE_ORDERS_PLACED:
      {
         ManageOCO();
         break;
      }

      case STATE_IN_TRADE:
      {
         MonitorInTrade();
         break;
      }

      case STATE_DONE:
      default:
         break; // nothing to do until next day's rollover
   }
}

//+------------------------------------------------------------------+