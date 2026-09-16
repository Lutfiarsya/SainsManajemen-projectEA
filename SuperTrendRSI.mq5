//+------------------------------------------------------------------+
//|                                     Supertrend_RSI_Confirmed.mq5 |
//|                                  Copyright 2023, Quant Developer |
//|                                                                  |
//+------------------------------------------------------------------+
#property copyright "Senior Algorithmic Trader & Quant Developer"
#property link      ""
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\PositionInfo.mqh>

//--- ENUMS ---
enum ENUM_LOT_MODE
  {
   LOT_MODE_FIXED = 0,    // Fixed Lot
   LOT_MODE_RISK = 1      // Risk Percentage
  };

enum ENUM_ENTRY_MODE
  {
   ENTRY_MODE_MOMENTUM = 0, // Trend Momentum
   ENTRY_MODE_PULLBACK = 1, // Pullback Re-entry
   ENTRY_MODE_BOTH = 2      // Both
  };

//--- INPUT PARAMETERS ---
input group "=== General Settings ==="
input ulong             MagicNumber             = 77778888;
input ulong             DeviationPoints         = 20;
input int               MaxPositions            = 1;
input bool              EnableDebugLog          = false;

input group "=== Supertrend Internal ==="
input int               SupertrendATRPeriod     = 10;
input double            SupertrendMultiplier    = 3.0;
input int               SupertrendLookbackBars  = 300;
input bool              UseFreshSupertrendFlip  = false;
input bool              UseSupertrendDistanceFilter = true;
input double            MaximumDistanceATR      = 2.0;

input group "=== RSI Filter Settings ==="
input int               RSIPeriod               = 14;
input ENUM_ENTRY_MODE   EntryMode               = ENTRY_MODE_MOMENTUM;
input bool              UseRSISlopeFilter       = true;

input double            RSIBuyMinimum           = 50.0;
input double            RSIBuyMaximum           = 70.0;
input double            RSISellMinimum          = 30.0;
input double            RSISellMaximum          = 50.0;

input double            PullbackRSIBuyLevel     = 45.0;
input double            RecoveryRSIBuyLevel     = 50.0;
input double            PullbackRSISellLevel    = 55.0;
input double            RecoveryRSISellLevel    = 50.0;

input group "=== Price Action Confirmation ==="
input bool              UseCandleConfirmation   = true;
input bool              UseMinimumBodyFilter    = true;
input double            MinimumBodyATR          = 0.20;

input group "=== ATR Filter ==="
input int               ATRPeriod               = 14;
input bool              UseATRFilter            = true;
input double            MinimumATRPoints        = 50.0;

input group "=== ADX Filter ==="
input bool              UseADXFilter            = false;
input int               ADXPeriod               = 14;
input double            MinimumADX              = 20.0;
input double            MaximumADX              = 50.0;

input group "=== Risk Management & Stops ==="
input bool              UseSupertrendStopLoss   = true;
input double            SupertrendSLBufferATR   = 0.30;
input bool              UseATRStopLossFallback  = true;
input double            SL_ATR_Multiplier       = 1.5;
input double            MaximumSL_ATR           = 3.0;
input bool              UseTakeProfit           = true;
input double            TP_ATR_Multiplier       = 2.5;
input double            MinimumRiskReward       = 1.3;

input group "=== Position Sizing ==="
input ENUM_LOT_MODE     LotMode                 = LOT_MODE_FIXED;
input double            FixedLot                = 0.01;
input double            RiskPercent             = 1.0;

input group "=== Trade Management ==="
input bool              UseSupertrendExit       = true;
input bool              UseRSIExit              = false;
input double            RSIExitBuyLevel         = 45.0;
input double            RSIExitSellLevel        = 55.0;

input bool              UseBreakEven            = true;
input double            BreakEvenTriggerATR     = 1.0;
input int               BreakEvenOffsetPoints   = 10;

input bool              UseTrailingStop         = false;
input double            TrailingATRMultiplier   = 1.5;

input group "=== Operational Filters ==="
input bool              UseSpreadFilter         = true;
input int               MaximumSpreadPoints     = 30;
input bool              UseCooldown             = true;
input int               CooldownBars            = 3;
input bool              UseTradingSession       = false;
input int               StartHour               = 7;
input int               StartMinute             = 0;
input int               EndHour                 = 22;
input int               EndMinute               = 0;

//--- GLOBAL VARIABLES ---
CTrade            m_trade;
CSymbolInfo       m_symbol;
CPositionInfo     m_position;

int               m_handleATR_ST = INVALID_HANDLE;
int               m_handleATR    = INVALID_HANDLE;
int               m_handleRSI    = INVALID_HANDLE;
int               m_handleADX    = INVALID_HANDLE;

datetime          m_lastBarTime  = 0;
datetime          m_lastBuySignalTime = 0;
datetime          m_lastSellSignalTime = 0;

// Internal Supertrend Buffers (SetAsSeries = true)
double            m_st_upper[];
double            m_st_lower[];
double            m_st_line[];
int               m_st_trend[]; // 1 = Bullish, -1 = Bearish

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   if(!m_symbol.Name(_Symbol)) return(INIT_FAILED);
   m_symbol.RefreshRates();

   m_trade.SetExpertMagicNumber(MagicNumber);
   m_trade.SetDeviationInPoints(DeviationPoints);
   
   int filling_mode = (int)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((filling_mode & SYMBOL_FILLING_FOK) != 0) 
      m_trade.SetTypeFilling(ORDER_FILLING_FOK);
   else if((filling_mode & SYMBOL_FILLING_IOC) != 0) 
      m_trade.SetTypeFilling(ORDER_FILLING_IOC);
   else 
      m_trade.SetTypeFilling(ORDER_FILLING_RETURN);

   m_handleATR_ST = iATR(_Symbol, _Period, SupertrendATRPeriod);
   m_handleATR    = iATR(_Symbol, _Period, ATRPeriod);
   m_handleRSI    = iRSI(_Symbol, _Period, RSIPeriod, PRICE_CLOSE);
   
   if(UseADXFilter) m_handleADX = iADX(_Symbol, _Period, ADXPeriod);

   if(m_handleATR_ST == INVALID_HANDLE || m_handleATR == INVALID_HANDLE || m_handleRSI == INVALID_HANDLE)
     {
      Print("Error initializing indicator handles!");
      return(INIT_FAILED);
     }

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(m_handleATR_ST != INVALID_HANDLE) IndicatorRelease(m_handleATR_ST);
   if(m_handleATR != INVALID_HANDLE)    IndicatorRelease(m_handleATR);
   if(m_handleRSI != INVALID_HANDLE)    IndicatorRelease(m_handleRSI);
   if(m_handleADX != INVALID_HANDLE)    IndicatorRelease(m_handleADX);
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   if(!m_symbol.RefreshRates()) return;

   ManageOpenPositions();

   if(IsNewBar())
     {
      if(!CalculateSupertrend()) return;

      CheckSupertrendExit();
      CheckRSIExit();

      if(CountOwnPositions() < MaxPositions)
        {
         if(!IsTradingSession()) return;
         if(!IsSpreadAcceptable()) return;
         if(!IsCooldownFinished()) return;
         
         double rsi[], atr[], adx[];
         MqlRates rates[];
         
         if(CopyBuffer(m_handleRSI, 0, 0, 3, rsi) < 3) return;
         if(CopyBuffer(m_handleATR, 0, 0, 2, atr) < 2) return;
         if(CopyRates(_Symbol, _Period, 0, 3, rates) < 3) return;
         
         ArraySetAsSeries(rsi, true);
         ArraySetAsSeries(atr, true);
         ArraySetAsSeries(rates, true);
         
         if(UseADXFilter)
           {
            if(CopyBuffer(m_handleADX, 0, 0, 2, adx) < 2) return;
            ArraySetAsSeries(adx, true);
           }

         bool isBuy = CheckBuySignal(rates, rsi, atr, adx);
         bool isSell = CheckSellSignal(rates, rsi, atr, adx);
         
         datetime currentBar = iTime(_Symbol, _Period, 0);

         if(isBuy && m_lastBuySignalTime != currentBar)
           {
            OpenBuy(atr[1]);
            m_lastBuySignalTime = currentBar;
           }
         else if(isSell && m_lastSellSignalTime != currentBar)
           {
            OpenSell(atr[1]);
            m_lastSellSignalTime = currentBar;
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Check BUY Signal                                                 |
//+------------------------------------------------------------------+
bool CheckBuySignal(MqlRates &rates[], double &rsi[], double &atr[], double &adx[])
  {
   if(m_st_trend[1] != 1) return false;
   if(UseFreshSupertrendFlip && m_st_trend[2] != -1) return false;

   bool momentumValid = false;
   bool pullbackValid = false;

   // Momentum Check
   if(EntryMode == ENTRY_MODE_MOMENTUM || EntryMode == ENTRY_MODE_BOTH)
     {
      if(rsi[1] >= RSIBuyMinimum && rsi[1] <= RSIBuyMaximum)
        {
         if(!UseRSISlopeFilter || rsi[1] > rsi[2]) momentumValid = true;
        }
     }

   // Pullback Check
   if(EntryMode == ENTRY_MODE_PULLBACK || EntryMode == ENTRY_MODE_BOTH)
     {
      if(rsi[2] <= PullbackRSIBuyLevel && rsi[1] > RecoveryRSIBuyLevel) pullbackValid = true;
     }

   if(!momentumValid && !pullbackValid) return false;

   if(!CheckCandleConfirmation(rates[1], atr[1], ORDER_TYPE_BUY)) return false;
   if(UseSupertrendDistanceFilter && !CheckSupertrendDistance(rates[1].close, atr[1])) return false;
   if(UseATRFilter && !CheckATRFilter(atr[1])) return false;
   if(UseADXFilter && !CheckADXFilter(adx[1])) return false;

   if(EnableDebugLog) LogSignal("BUY", rates[1].close, rsi[1], atr[1], (UseADXFilter?adx[1]:0));

   return true;
  }

//+------------------------------------------------------------------+
//| Check SELL Signal                                                |
//+------------------------------------------------------------------+
bool CheckSellSignal(MqlRates &rates[], double &rsi[], double &atr[], double &adx[])
  {
   if(m_st_trend[1] != -1) return false;
   if(UseFreshSupertrendFlip && m_st_trend[2] != 1) return false;

   bool momentumValid = false;
   bool pullbackValid = false;

   // Momentum Check
   if(EntryMode == ENTRY_MODE_MOMENTUM || EntryMode == ENTRY_MODE_BOTH)
     {
      if(rsi[1] <= RSISellMaximum && rsi[1] >= RSISellMinimum)
        {
         if(!UseRSISlopeFilter || rsi[1] < rsi[2]) momentumValid = true;
        }
     }

   // Pullback Check
   if(EntryMode == ENTRY_MODE_PULLBACK || EntryMode == ENTRY_MODE_BOTH)
     {
      if(rsi[2] >= PullbackRSISellLevel && rsi[1] < RecoveryRSISellLevel) pullbackValid = true;
     }

   if(!momentumValid && !pullbackValid) return false;

   if(!CheckCandleConfirmation(rates[1], atr[1], ORDER_TYPE_SELL)) return false;
   if(UseSupertrendDistanceFilter && !CheckSupertrendDistance(rates[1].close, atr[1])) return false;
   if(UseATRFilter && !CheckATRFilter(atr[1])) return false;
   if(UseADXFilter && !CheckADXFilter(adx[1])) return false;
   
   if(EnableDebugLog) LogSignal("SELL", rates[1].close, rsi[1], atr[1], (UseADXFilter?adx[1]:0));

   return true;
  }

//+------------------------------------------------------------------+
//| Core Function: Sequential Supertrend Calculation                 |
//+------------------------------------------------------------------+
bool CalculateSupertrend()
  {
   double atr[];
   MqlRates rates[];

   if(CopyBuffer(m_handleATR_ST, 0, 0, SupertrendLookbackBars, atr) < SupertrendLookbackBars) return false;
   if(CopyRates(_Symbol, _Period, 0, SupertrendLookbackBars, rates) < SupertrendLookbackBars) return false;

   ArraySetAsSeries(atr, true);
   ArraySetAsSeries(rates, true);

   ArrayResize(m_st_upper, SupertrendLookbackBars);
   ArrayResize(m_st_lower, SupertrendLookbackBars);
   ArrayResize(m_st_line, SupertrendLookbackBars);
   ArrayResize(m_st_trend, SupertrendLookbackBars);

   ArraySetAsSeries(m_st_upper, true);
   ArraySetAsSeries(m_st_lower, true);
   ArraySetAsSeries(m_st_line, true);
   ArraySetAsSeries(m_st_trend, true);

   // Calculate sequentially from oldest to newest
   for(int i = SupertrendLookbackBars - 1; i >= 0; i--)
     {
      double hl2 = (rates[i].high + rates[i].low) / 2.0;
      double basic_upper = hl2 + SupertrendMultiplier * atr[i];
      double basic_lower = hl2 - SupertrendMultiplier * atr[i];

      if(i == SupertrendLookbackBars - 1) 
        {
         m_st_upper[i] = basic_upper;
         m_st_lower[i] = basic_lower;
         m_st_trend[i] = 1; 
         m_st_line[i] = basic_lower;
         continue;
        }

      // Recursive Final Upper Band
      if(basic_upper < m_st_upper[i+1] || rates[i+1].close > m_st_upper[i+1])
         m_st_upper[i] = basic_upper;
      else
         m_st_upper[i] = m_st_upper[i+1];

      // Recursive Final Lower Band
      if(basic_lower > m_st_lower[i+1] || rates[i+1].close < m_st_lower[i+1])
         m_st_lower[i] = basic_lower;
      else
         m_st_lower[i] = m_st_lower[i+1];

      // Trend Detection
      if(m_st_trend[i+1] == 1 && rates[i].close <= m_st_upper[i+1] && rates[i].close < m_st_lower[i]) 
         m_st_trend[i] = -1;
      else if(m_st_trend[i+1] == 1 && rates[i].close < m_st_lower[i])
         m_st_trend[i] = -1;
      else if(m_st_trend[i+1] == -1 && rates[i].close > m_st_upper[i]) 
         m_st_trend[i] = 1;
      else 
         m_st_trend[i] = m_st_trend[i+1];

      m_st_line[i] = (m_st_trend[i] == 1) ? m_st_lower[i] : m_st_upper[i];
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Filter Check Functions                                           |
//+------------------------------------------------------------------+
bool CheckCandleConfirmation(MqlRates &rate, double atr, ENUM_ORDER_TYPE type)
  {
   if(!UseCandleConfirmation) return true;
   
   if(type == ORDER_TYPE_BUY && rate.close <= rate.open) return false;
   if(type == ORDER_TYPE_SELL && rate.close >= rate.open) return false;
   
   if(UseMinimumBodyFilter)
     {
      double body = MathAbs(rate.close - rate.open);
      if(body < atr * MinimumBodyATR) return false;
     }
   return true;
  }

bool CheckSupertrendDistance(double closePrice, double atr)
  {
   double distance = MathAbs(closePrice - m_st_line[1]);
   return (distance <= atr * MaximumDistanceATR);
  }

bool CheckATRFilter(double atr)
  {
   return (atr >= MinimumATRPoints * m_symbol.Point());
  }

bool CheckADXFilter(double adx)
  {
   return (adx >= MinimumADX && adx <= MaximumADX);
  }

bool IsSpreadAcceptable() 
  { 
   return (!UseSpreadFilter || SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) <= MaximumSpreadPoints); 
  }

bool IsTradingSession()
  {
   if(!UseTradingSession) return true;
   MqlDateTime dt; TimeCurrent(dt);
   int currentMins = dt.hour * 60 + dt.min;
   int startMins = StartHour * 60 + StartMinute;
   int endMins = EndHour * 60 + EndMinute;
   
   if(startMins < endMins) 
      return (currentMins >= startMins && currentMins <= endMins);
   else 
      return (currentMins >= startMins || currentMins <= endMins);
  }

bool IsCooldownFinished()
  {
   if(!UseCooldown) return true;
   HistorySelect(0, TimeCurrent());
   datetime lastClose = 0;
   
   for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket > 0 && HistoryDealGetInteger(ticket, DEAL_MAGIC) == MagicNumber && 
         HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol && 
         HistoryDealGetInteger(ticket, DEAL_ENTRY) == DEAL_ENTRY_OUT)
        { 
         lastClose = (datetime)HistoryDealGetInteger(ticket, DEAL_TIME); 
         break; 
        }
     }
   return (lastClose == 0 || iBarShift(_Symbol, _Period, lastClose) >= CooldownBars);
  }

//+------------------------------------------------------------------+
//| Trade Execution                                                  |
//+------------------------------------------------------------------+
void OpenBuy(double atr)
  {
   double entry = m_symbol.Ask();
   double sl = 0;
   
   if(UseSupertrendStopLoss)
     {
      sl = m_st_line[1] - (atr * SupertrendSLBufferATR);
      if(sl >= entry || (entry - sl) > (atr * MaximumSL_ATR)) sl = 0; 
     }
     
   if(sl == 0 && UseATRStopLossFallback) sl = entry - (atr * SL_ATR_Multiplier);
   if(sl == 0 || (entry - sl) > (atr * MaximumSL_ATR)) return; 

   double tp = UseTakeProfit ? entry + (atr * TP_ATR_Multiplier) : 0;
   
   if(!CheckRiskReward(entry, sl, tp)) return;
   
   sl = NormalizePrice(ORDER_TYPE_BUY, entry, sl, true);
   if(tp != 0) tp = NormalizePrice(ORDER_TYPE_BUY, entry, tp, false);
   
   double volume = CalculateLotSize(MathAbs(entry - sl));
   if(volume <= 0) return;

   if(!m_trade.Buy(volume, _Symbol, entry, sl, tp, "ST+RSI BUY"))
      PrintFormat("BUY Failed: %d - %s", m_trade.ResultRetcode(), m_trade.ResultRetcodeDescription());
  }

void OpenSell(double atr)
  {
   double entry = m_symbol.Bid();
   double sl = 0;
   
   if(UseSupertrendStopLoss)
     {
      sl = m_st_line[1] + (atr * SupertrendSLBufferATR);
      if(sl <= entry || (sl - entry) > (atr * MaximumSL_ATR)) sl = 0;
     }
     
   if(sl == 0 && UseATRStopLossFallback) sl = entry + (atr * SL_ATR_Multiplier);
   if(sl == 0 || (sl - entry) > (atr * MaximumSL_ATR)) return;

   double tp = UseTakeProfit ? entry - (atr * TP_ATR_Multiplier) : 0;
   
   if(!CheckRiskReward(entry, sl, tp)) return;

   sl = NormalizePrice(ORDER_TYPE_SELL, entry, sl, true);
   if(tp != 0) tp = NormalizePrice(ORDER_TYPE_SELL, entry, tp, false);
   
   double volume = CalculateLotSize(MathAbs(sl - entry));
   if(volume <= 0) return;

   if(!m_trade.Sell(volume, _Symbol, entry, sl, tp, "ST+RSI SELL"))
      PrintFormat("SELL Failed: %d - %s", m_trade.ResultRetcode(), m_trade.ResultRetcodeDescription());
  }

//+------------------------------------------------------------------+
//| Order Math & Normalization                                       |
//+------------------------------------------------------------------+
double CalculateLotSize(double slDistance)
  {
   double volume = FixedLot;
   if(LotMode == LOT_MODE_RISK && slDistance > 0)
     {
      double riskAmount = AccountInfoDouble(ACCOUNT_EQUITY) * (RiskPercent / 100.0);
      double tickSize = m_symbol.TickSize();
      double tickValue = m_symbol.TickValue();
      if(tickSize > 0 && tickValue > 0)
        {
         double slPoints = slDistance / tickSize;
         volume = riskAmount / (slPoints * tickValue);
        }
     }
   double stepVol = m_symbol.LotsStep();
   return MathRound(MathMax(m_symbol.LotsMin(), MathMin(m_symbol.LotsMax(), volume)) / stepVol) * stepVol;
  }

bool CheckRiskReward(double entry, double sl, double tp)
  {
   if(!UseTakeProfit || sl == 0 || tp == 0) return true;
   double risk = MathAbs(entry - sl);
   double reward = MathAbs(tp - entry);
   if(risk == 0) return false;
   return ((reward / risk) >= MinimumRiskReward);
  }

double NormalizePrice(ENUM_ORDER_TYPE type, double entry, double price, bool isSL)
  {
   double minLevel = MathMax(m_symbol.StopsLevel(), m_symbol.FreezeLevel()) * m_symbol.Point();
   if(type == ORDER_TYPE_BUY)
     {
      if(isSL && entry - price < minLevel) price = entry - minLevel;
      if(!isSL && price - entry < minLevel) price = entry + minLevel;
     }
   else
     {
      if(isSL && price - entry < minLevel) price = entry + minLevel;
      if(!isSL && entry - price < minLevel) price = entry - minLevel;
     }
   return NormalizeDouble(price, m_symbol.Digits());
  }

//+------------------------------------------------------------------+
//| Trade Management                                                 |
//+------------------------------------------------------------------+
void ManageOpenPositions()
  {
   if(!UseBreakEven && !UseTrailingStop) return;
   
   double atr[];
   if(CopyBuffer(m_handleATR, 0, 0, 1, atr) <= 0) return;
   double currentAtr = atr[0];
   if(currentAtr <= 0) return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(m_position.SelectByIndex(i) && m_position.Symbol() == _Symbol && m_position.Magic() == MagicNumber)
        {
         double entry = m_position.PriceOpen();
         double sl = m_position.StopLoss();
         double currentPrice = m_position.PriceCurrent();
         ENUM_POSITION_TYPE type = m_position.PositionType();
         
         bool modified = false; 
         double newSL = sl;
         
         if(UseBreakEven)
           {
            if(type == POSITION_TYPE_BUY && currentPrice >= entry + (currentAtr * BreakEvenTriggerATR))
              {
               double bePrice = entry + (BreakEvenOffsetPoints * m_symbol.Point());
               if(sl < bePrice || sl == 0) { newSL = bePrice; modified = true; }
              }
            else if(type == POSITION_TYPE_SELL && currentPrice <= entry - (currentAtr * BreakEvenTriggerATR))
              {
               double bePrice = entry - (BreakEvenOffsetPoints * m_symbol.Point());
               if(sl > bePrice || sl == 0) { newSL = bePrice; modified = true; }
              }
           }
           
         if(UseTrailingStop)
           {
            if(type == POSITION_TYPE_BUY)
              {
               double trSL = m_symbol.Bid() - (currentAtr * TrailingATRMultiplier);
               if(trSL > newSL || newSL == 0) { newSL = trSL; modified = true; }
              }
            else if(type == POSITION_TYPE_SELL)
              {
               double trSL = m_symbol.Ask() + (currentAtr * TrailingATRMultiplier);
               if(trSL < newSL || newSL == 0) { newSL = trSL; modified = true; }
              }
           }
           
         if(modified)
           {
            newSL = NormalizePrice(type == POSITION_TYPE_BUY ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, entry, newSL, true);
            if(MathAbs(newSL - sl) > m_symbol.Point()) m_trade.PositionModify(m_position.Ticket(), newSL, m_position.TakeProfit());
           }
        }
     }
  }

void CheckSupertrendExit()
  {
   if(!UseSupertrendExit) return;
   
   bool flipSell = (m_st_trend[1] == -1 && m_st_trend[2] == 1);
   bool flipBuy  = (m_st_trend[1] == 1 && m_st_trend[2] == -1);
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(m_position.SelectByIndex(i) && m_position.Symbol() == _Symbol && m_position.Magic() == MagicNumber)
        {
         if(m_position.PositionType() == POSITION_TYPE_BUY && flipSell) m_trade.PositionClose(m_position.Ticket());
         else if(m_position.PositionType() == POSITION_TYPE_SELL && flipBuy) m_trade.PositionClose(m_position.Ticket());
        }
     }
  }

void CheckRSIExit()
  {
   if(!UseRSIExit) return;
   
   double rsi[];
   if(CopyBuffer(m_handleRSI, 0, 1, 1, rsi) <= 0) return;
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(m_position.SelectByIndex(i) && m_position.Symbol() == _Symbol && m_position.Magic() == MagicNumber)
        {
         if(m_position.PositionType() == POSITION_TYPE_BUY && rsi[0] < RSIExitBuyLevel) 
            m_trade.PositionClose(m_position.Ticket());
         else if(m_position.PositionType() == POSITION_TYPE_SELL && rsi[0] > RSIExitSellLevel) 
            m_trade.PositionClose(m_position.Ticket());
        }
     }
  }

//+------------------------------------------------------------------+
//| Helpers                                                          |
//+------------------------------------------------------------------+
bool IsNewBar()
  {
   datetime currentBarTime = (datetime)SeriesInfoInteger(_Symbol, _Period, SERIES_LASTBAR_DATE);
   if(currentBarTime != m_lastBarTime)
     {
      m_lastBarTime = currentBarTime;
      return true;
     }
   return false;
  }

int CountOwnPositions()
  {
   int count = 0;
   for(int i = 0; i < PositionsTotal(); i++)
     {
      if(m_position.SelectByIndex(i) && m_position.Symbol() == _Symbol && m_position.Magic() == MagicNumber) 
         count++;
     }
   return count;
  }

void LogSignal(string type, double price, double rsi, double atr, double adx)
  {
   PrintFormat("--- SIGNAL %s --- Time: %s, Price: %f, ST: %s, RSI[1]: %.2f, ATR[1]: %f, ADX[1]: %.2f", 
               type, TimeToString(iTime(_Symbol, _Period, 0)), price, 
               (m_st_trend[1]==1?"UP":"DOWN"), rsi, atr, adx);
  }
//+------------------------------------------------------------------+