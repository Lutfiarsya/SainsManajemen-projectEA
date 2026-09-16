//+------------------------------------------------------------------+
//|                                     WPR_Extreme_Reversion_EA.mq5 |
//|                                  Copyright 2023, Quant Developer |
//|                                              https://www.mql5.com|
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

//--- INPUT PARAMETERS ---
input group "=== General Settings ==="
input ulong             MagicNumber             = 88889999;
input int               MaxPositions            = 1;
input ulong             DeviationPoints         = 20;

input group "=== Williams %R Strategy ==="
input int               WilliamsPeriod          = 14;
input double            OverboughtLevel         = -20.0;
input double            OversoldLevel           = -80.0;
input int               ExtremeLookback         = 3;       // Max bars to look for extreme

input group "=== Price Action Confirmation ==="
input bool              UseCandleConfirmation   = true;
input double            MinimumBodyATR          = 0.20;    // Min Body Size (ATR Multiplier)
input double            MinimumWickBodyRatio    = 0.5;     // Min Rejection Wick vs Body Ratio

input group "=== EMA Market Context Filter ==="
input bool              UseEMAFilter            = true;
input int               EMAPeriod               = 50;
input bool              UseEMASlopeFilter       = true;

input group "=== ADX Trend Filter ==="
input bool              UseADXFilter            = false;
input int               ADXPeriod               = 14;
input double            MinimumADX              = 18.0;
input double            MaximumADX              = 35.0;

input group "=== RSI Secondary Filter ==="
input bool              UseRSIFilter            = false;
input int               RSIPeriod               = 14;
input double            RSIBuyMaximum           = 45.0;
input double            RSISellMinimum          = 55.0;

input group "=== ATR Volatility Filter ==="
input bool              UseMinimumATRFilter     = true;
input int               ATRPeriod               = 14;
input double            MinimumATR              = 0.0010;

input group "=== Risk Management & Stops ==="
input bool              UseATRStopLoss          = true;
input double            SL_ATR_Multiplier       = 1.5;
input bool              UseSwingStopLoss        = false;
input int               SwingLookback           = 5;
input double            SwingBufferATR          = 0.2;
input double            MaximumSL_ATR           = 5.0;     // Max allowed SL distance in ATR
input bool              UseTakeProfit           = true;
input double            TP_ATR_Multiplier       = 2.0;
input double            MinimumRiskReward       = 1.2;

input group "=== Position Sizing ==="
input ENUM_LOT_MODE     LotMode                 = LOT_MODE_RISK;
input double            FixedLot                = 0.01;
input double            RiskPercent             = 1.0;

input group "=== Trade Management ==="
input bool              UseOppositeSignalExit   = true;
input bool              UseBreakEven            = true;
input double            BreakEvenTriggerATR     = 1.0;
input int               BreakEvenOffsetPoints   = 10;
input bool              UseTrailingStop         = false;
input double            TrailingATRMultiplier   = 1.2;

input group "=== Operational Filters ==="
input bool              UseSpreadFilter         = true;
input int               MaximumSpreadPoints     = 30;
input bool              UseCooldown             = true;
input int               CooldownBars            = 3;

input group "=== Trading Session ==="
input bool              UseTradingSession       = false;
input int               StartHour               = 7;
input int               StartMinute             = 0;
input int               EndHour                 = 22;
input int               EndMinute               = 0;

//--- GLOBAL VARIABLES ---
CTrade            m_trade;
CSymbolInfo       m_symbol;
CPositionInfo     m_position;

int               m_handleWPR = INVALID_HANDLE;
int               m_handleEMA = INVALID_HANDLE;
int               m_handleADX = INVALID_HANDLE;
int               m_handleRSI = INVALID_HANDLE;
int               m_handleATR = INVALID_HANDLE;

datetime          m_lastBarTime = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   if(!m_symbol.Name(_Symbol))
      return(INIT_FAILED);
      
   m_symbol.RefreshRates();

   m_trade.SetExpertMagicNumber(MagicNumber);
   m_trade.SetDeviationInPoints(DeviationPoints);
   
// Set Filling Mode safely
int filling_mode = (int)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);

if((filling_mode & SYMBOL_FILLING_FOK) != 0) {
    m_trade.SetTypeFilling(ORDER_FILLING_FOK);
} 
else if((filling_mode & SYMBOL_FILLING_IOC) != 0) {
    m_trade.SetTypeFilling(ORDER_FILLING_IOC);
} 
else {
    m_trade.SetTypeFilling(ORDER_FILLING_RETURN);
}
   // Initialize Indicator Handles
   m_handleWPR = iWPR(_Symbol, _Period, WilliamsPeriod);
   if(m_handleWPR == INVALID_HANDLE) { Print("Error initializing iWPR"); return(INIT_FAILED); }

   if(UseEMAFilter || UseEMASlopeFilter)
     {
      m_handleEMA = iMA(_Symbol, _Period, EMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
      if(m_handleEMA == INVALID_HANDLE) { Print("Error initializing iMA"); return(INIT_FAILED); }
     }

   if(UseADXFilter)
     {
      m_handleADX = iADX(_Symbol, _Period, ADXPeriod);
      if(m_handleADX == INVALID_HANDLE) { Print("Error initializing iADX"); return(INIT_FAILED); }
     }

   if(UseRSIFilter)
     {
      m_handleRSI = iRSI(_Symbol, _Period, RSIPeriod, PRICE_CLOSE);
      if(m_handleRSI == INVALID_HANDLE) { Print("Error initializing iRSI"); return(INIT_FAILED); }
     }

   m_handleATR = iATR(_Symbol, _Period, ATRPeriod);
   if(m_handleATR == INVALID_HANDLE) { Print("Error initializing iATR"); return(INIT_FAILED); }

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(m_handleWPR != INVALID_HANDLE) IndicatorRelease(m_handleWPR);
   if(m_handleEMA != INVALID_HANDLE) IndicatorRelease(m_handleEMA);
   if(m_handleADX != INVALID_HANDLE) IndicatorRelease(m_handleADX);
   if(m_handleRSI != INVALID_HANDLE) IndicatorRelease(m_handleRSI);
   if(m_handleATR != INVALID_HANDLE) IndicatorRelease(m_handleATR);
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   if(!m_symbol.RefreshRates()) return;

   // Per-tick position management
   ManageOpenPositions();

   // New Bar Evaluation
   if(IsNewBar())
     {
      // Check Opposite Signal Exit First
      if(UseOppositeSignalExit)
         CheckOppositeSignalExit();

      // Proceed to evaluate new entries if below max positions
      if(CountOwnPositions() < MaxPositions)
        {
         if(!IsTradingSessionValid()) return;
         if(!IsSpreadAcceptable()) return;
         if(!IsCooldownFinished()) return;

         if(CheckBuySignal())
           {
            OpenBuy();
           }
         else if(CheckSellSignal())
           {
            OpenSell();
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Check for New Bar                                                |
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

//+------------------------------------------------------------------+
//| BUY Signal Logic                                                 |
//+------------------------------------------------------------------+
bool CheckBuySignal()
  {
   // 1. Williams %R Reversal Check
   double wpr[];
   if(CopyBuffer(m_handleWPR, 0, 1, ExtremeLookback + 2, wpr) <= 0) return false;
   ArraySetAsSeries(wpr, true);

   // Exit Oversold: WPR[2] <= Oversold AND WPR[1] > Oversold
   if(!(wpr[1] <= OversoldLevel && wpr[0] > OversoldLevel)) // Index 1 is candle [2], Index 0 is candle [1] when AsSeries=true
      return false;

   // Extreme Lookback Check: Did it actually go deep into oversold?
   bool foundExtreme = false;
   for(int i = 1; i <= ExtremeLookback; i++)
     {
      if(wpr[i] <= OversoldLevel)
        {
         foundExtreme = true;
         break;
        }
     }
   if(!foundExtreme) return false;

   // 2. ATR Filter
   double atr[];
   if(CopyBuffer(m_handleATR, 0, 1, 1, atr) <= 0) return false;
   if(UseMinimumATRFilter && atr[0] < MinimumATR) return false;
   double currentATR = atr[0];

   // 3. Price Action / Candle Confirmation
   if(UseCandleConfirmation)
     {
      double open1 = iOpen(_Symbol, _Period, 1);
      double close1 = iClose(_Symbol, _Period, 1);
      double low1 = iLow(_Symbol, _Period, 1);
      
      if(close1 <= open1) return false; // Must be Bullish
      
      double body = close1 - open1;
      if(body < currentATR * MinimumBodyATR) return false;
      
      double lowerWick = open1 - low1;
      if(MinimumWickBodyRatio > 0 && lowerWick < body * MinimumWickBodyRatio) return false;
     }

   // 4. EMA Context Filter
   if(UseEMAFilter || UseEMASlopeFilter)
     {
      double ema[];
      if(CopyBuffer(m_handleEMA, 0, 1, 2, ema) <= 0) return false;
      ArraySetAsSeries(ema, true);
      
      if(UseEMAFilter && iClose(_Symbol, _Period, 1) <= ema[0]) return false;
      if(UseEMASlopeFilter && ema[0] <= ema[1]) return false;
     }

   // 5. ADX Trend Filter
   if(UseADXFilter)
     {
      double adx[];
      if(CopyBuffer(m_handleADX, 0, 1, 1, adx) <= 0) return false;
      if(adx[0] < MinimumADX || adx[0] > MaximumADX) return false;
     }

   // 6. RSI Filter
   if(UseRSIFilter)
     {
      double rsi[];
      if(CopyBuffer(m_handleRSI, 0, 1, 1, rsi) <= 0) return false;
      if(rsi[0] > RSIBuyMaximum) return false;
     }

   return true;
  }

//+------------------------------------------------------------------+
//| SELL Signal Logic                                                |
//+------------------------------------------------------------------+
bool CheckSellSignal()
  {
   // 1. Williams %R Reversal Check
   double wpr[];
   if(CopyBuffer(m_handleWPR, 0, 1, ExtremeLookback + 2, wpr) <= 0) return false;
   ArraySetAsSeries(wpr, true);

   // Exit Overbought: WPR[2] >= Overbought AND WPR[1] < Overbought
   if(!(wpr[1] >= OverboughtLevel && wpr[0] < OverboughtLevel)) 
      return false;

   // Extreme Lookback Check
   bool foundExtreme = false;
   for(int i = 1; i <= ExtremeLookback; i++)
     {
      if(wpr[i] >= OverboughtLevel)
        {
         foundExtreme = true;
         break;
        }
     }
   if(!foundExtreme) return false;

   // 2. ATR Filter
   double atr[];
   if(CopyBuffer(m_handleATR, 0, 1, 1, atr) <= 0) return false;
   if(UseMinimumATRFilter && atr[0] < MinimumATR) return false;
   double currentATR = atr[0];

   // 3. Price Action / Candle Confirmation
   if(UseCandleConfirmation)
     {
      double open1 = iOpen(_Symbol, _Period, 1);
      double close1 = iClose(_Symbol, _Period, 1);
      double high1 = iHigh(_Symbol, _Period, 1);
      
      if(close1 >= open1) return false; // Must be Bearish
      
      double body = open1 - close1;
      if(body < currentATR * MinimumBodyATR) return false;
      
      double upperWick = high1 - open1;
      if(MinimumWickBodyRatio > 0 && upperWick < body * MinimumWickBodyRatio) return false;
     }

   // 4. EMA Context Filter
   if(UseEMAFilter || UseEMASlopeFilter)
     {
      double ema[];
      if(CopyBuffer(m_handleEMA, 0, 1, 2, ema) <= 0) return false;
      ArraySetAsSeries(ema, true);
      
      if(UseEMAFilter && iClose(_Symbol, _Period, 1) >= ema[0]) return false;
      if(UseEMASlopeFilter && ema[0] >= ema[1]) return false;
     }

   // 5. ADX Trend Filter
   if(UseADXFilter)
     {
      double adx[];
      if(CopyBuffer(m_handleADX, 0, 1, 1, adx) <= 0) return false;
      if(adx[0] < MinimumADX || adx[0] > MaximumADX) return false;
     }

   // 6. RSI Filter
   if(UseRSIFilter)
     {
      double rsi[];
      if(CopyBuffer(m_handleRSI, 0, 1, 1, rsi) <= 0) return false;
      if(rsi[0] < RSISellMinimum) return false;
     }

   return true;
  }

//+------------------------------------------------------------------+
//| Open BUY Trade                                                   |
//+------------------------------------------------------------------+
void OpenBuy()
  {
   double entryPrice = m_symbol.Ask();
   double atrVal = GetATR(1);
   if(atrVal <= 0) return;

   double sl = CalculateStopLoss(ORDER_TYPE_BUY, entryPrice, atrVal);
   if(sl <= 0) return;

   double tp = CalculateTakeProfit(ORDER_TYPE_BUY, entryPrice, atrVal);
   
   if(!ValidateRiskReward(entryPrice, sl, tp)) return;
   
   double volume = CalculateLotSize(MathAbs(entryPrice - sl));
   if(volume <= 0) return;

   if(!m_trade.Buy(volume, _Symbol, entryPrice, sl, tp, "WPR BUY"))
     {
      PrintFormat("BUY Error: %d - %s", m_trade.ResultRetcode(), m_trade.ResultRetcodeDescription());
     }
  }

//+------------------------------------------------------------------+
//| Open SELL Trade                                                  |
//+------------------------------------------------------------------+
void OpenSell()
  {
   double entryPrice = m_symbol.Bid();
   double atrVal = GetATR(1);
   if(atrVal <= 0) return;

   double sl = CalculateStopLoss(ORDER_TYPE_SELL, entryPrice, atrVal);
   if(sl <= 0) return;

   double tp = CalculateTakeProfit(ORDER_TYPE_SELL, entryPrice, atrVal);

   if(!ValidateRiskReward(entryPrice, sl, tp)) return;

   double volume = CalculateLotSize(MathAbs(sl - entryPrice));
   if(volume <= 0) return;

   if(!m_trade.Sell(volume, _Symbol, entryPrice, sl, tp, "WPR SELL"))
     {
      PrintFormat("SELL Error: %d - %s", m_trade.ResultRetcode(), m_trade.ResultRetcodeDescription());
     }
  }

//+------------------------------------------------------------------+
//| Calculate Stop Loss                                              |
//+------------------------------------------------------------------+
double CalculateStopLoss(ENUM_ORDER_TYPE type, double entryPrice, double atr)
  {
   double sl = 0.0;
   
   if(UseSwingStopLoss)
     {
      if(type == ORDER_TYPE_BUY)
        {
         double lowestLow = entryPrice;
         for(int i = 1; i <= SwingLookback; i++)
           {
            double l = iLow(_Symbol, _Period, i);
            if(l < lowestLow) lowestLow = l;
           }
         sl = lowestLow - (atr * SwingBufferATR);
        }
      else
        {
         double highestHigh = entryPrice;
         for(int i = 1; i <= SwingLookback; i++)
           {
            double h = iHigh(_Symbol, _Period, i);
            if(h > highestHigh) highestHigh = h;
           }
         sl = highestHigh + (atr * SwingBufferATR);
        }
     }
   else if(UseATRStopLoss)
     {
      if(type == ORDER_TYPE_BUY)
         sl = entryPrice - (atr * SL_ATR_Multiplier);
      else
         sl = entryPrice + (atr * SL_ATR_Multiplier);
     }
     
   // Enforce Max SL ATR distance
   double maxDist = atr * MaximumSL_ATR;
   if(MathAbs(entryPrice - sl) > maxDist) return 0.0; // Rejected by Max SL dist
   
   return NormalizeStopPrice(type, entryPrice, sl, true);
  }

//+------------------------------------------------------------------+
//| Calculate Take Profit                                            |
//+------------------------------------------------------------------+
double CalculateTakeProfit(ENUM_ORDER_TYPE type, double entryPrice, double atr)
  {
   if(!UseTakeProfit) return 0.0;
   double tp = 0.0;
   
   if(type == ORDER_TYPE_BUY)
      tp = entryPrice + (atr * TP_ATR_Multiplier);
   else
      tp = entryPrice - (atr * TP_ATR_Multiplier);
      
   return NormalizeStopPrice(type, entryPrice, tp, false);
  }

//+------------------------------------------------------------------+
//| Validate Risk Reward                                             |
//+------------------------------------------------------------------+
bool ValidateRiskReward(double entry, double sl, double tp)
  {
   if(!UseTakeProfit || sl == 0 || tp == 0) return true;
   double risk = MathAbs(entry - sl);
   double reward = MathAbs(tp - entry);
   if(risk == 0) return false;
   return (reward / risk) >= MinimumRiskReward;
  }

//+------------------------------------------------------------------+
//| Lot Size Calculation                                             |
//+------------------------------------------------------------------+
double CalculateLotSize(double slDistance)
  {
   double volume = FixedLot;
   
   if(LotMode == LOT_MODE_RISK && slDistance > 0)
     {
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      double riskAmount = equity * (RiskPercent / 100.0);
      
      double tickSize = m_symbol.TickSize();
      double tickValue = m_symbol.TickValue();
      
      if(tickSize > 0 && tickValue > 0)
        {
         double slPoints = slDistance / tickSize;
         volume = riskAmount / (slPoints * tickValue);
        }
     }
     
   return NormalizeVolume(volume);
  }

//+------------------------------------------------------------------+
//| Normalize Volume                                                 |
//+------------------------------------------------------------------+
double NormalizeVolume(double vol)
  {
   double minVol = m_symbol.LotsMin();
   double maxVol = m_symbol.LotsMax();
   double stepVol = m_symbol.LotsStep();
   
   double result = MathRound(vol / stepVol) * stepVol;
   if(result < minVol) result = minVol;
   if(result > maxVol) result = maxVol;
   
   return result;
  }

//+------------------------------------------------------------------+
//| Normalize Stop Price (Enforce Stop/Freeze Levels)                |
//+------------------------------------------------------------------+
double NormalizeStopPrice(ENUM_ORDER_TYPE type, double entry, double price, bool isSL)
  {
   double point = m_symbol.Point();
   double minLevel = MathMax(m_symbol.StopsLevel(), m_symbol.FreezeLevel()) * point;
   
   if(type == ORDER_TYPE_BUY)
     {
      if(isSL) 
        {
         if(entry - price < minLevel) price = entry - minLevel;
        }
      else 
        {
         if(price - entry < minLevel) price = entry + minLevel;
        }
     }
   else if(type == ORDER_TYPE_SELL)
     {
      if(isSL) 
        {
         if(price - entry < minLevel) price = entry + minLevel;
        }
      else 
        {
         if(entry - price < minLevel) price = entry - minLevel;
        }
     }
     
   return NormalizeDouble(price, m_symbol.Digits());
  }

//+------------------------------------------------------------------+
//| Per-tick Management (Breakeven & Trailing)                       |
//+------------------------------------------------------------------+
void ManageOpenPositions()
  {
   if(!UseBreakEven && !UseTrailingStop) return;
   
   double atr = GetATR(0);
   if(atr <= 0) return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(m_position.SelectByIndex(i))
        {
         if(m_position.Symbol() == _Symbol && m_position.Magic() == MagicNumber)
           {
            double entry = m_position.PriceOpen();
            double sl = m_position.StopLoss();
            double currentPrice = m_position.PriceCurrent();
            ENUM_POSITION_TYPE type = m_position.PositionType();
            
            bool modified = false;
            double newSL = sl;
            
            // Break Even
            if(UseBreakEven)
              {
               if(type == POSITION_TYPE_BUY && currentPrice >= entry + (atr * BreakEvenTriggerATR))
                 {
                  double bePrice = entry + (BreakEvenOffsetPoints * m_symbol.Point());
                  if(sl < bePrice || sl == 0) { newSL = bePrice; modified = true; }
                 }
               else if(type == POSITION_TYPE_SELL && currentPrice <= entry - (atr * BreakEvenTriggerATR))
                 {
                  double bePrice = entry - (BreakEvenOffsetPoints * m_symbol.Point());
                  if(sl > bePrice || sl == 0) { newSL = bePrice; modified = true; }
                 }
              }

            // Trailing Stop
            if(UseTrailingStop)
              {
               if(type == POSITION_TYPE_BUY)
                 {
                  double trSL = m_symbol.Bid() - (atr * TrailingATRMultiplier);
                  if(trSL > newSL || newSL == 0) { newSL = trSL; modified = true; }
                 }
               else if(type == POSITION_TYPE_SELL)
                 {
                  double trSL = m_symbol.Ask() + (atr * TrailingATRMultiplier);
                  if(trSL < newSL || newSL == 0) { newSL = trSL; modified = true; }
                 }
              }

            if(modified)
              {
               newSL = NormalizeStopPrice(type == POSITION_TYPE_BUY ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, entry, newSL, true);
               if(MathAbs(newSL - sl) > m_symbol.Point())
                  m_trade.PositionModify(m_position.Ticket(), newSL, m_position.TakeProfit());
              }
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Exit on Opposite Signal                                          |
//+------------------------------------------------------------------+
void CheckOppositeSignalExit()
  {
   bool hasBuySignal = CheckBuySignal();
   bool hasSellSignal = CheckSellSignal();
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(m_position.SelectByIndex(i))
        {
         if(m_position.Symbol() == _Symbol && m_position.Magic() == MagicNumber)
           {
            if(m_position.PositionType() == POSITION_TYPE_BUY && hasSellSignal)
               m_trade.PositionClose(m_position.Ticket());
            else if(m_position.PositionType() == POSITION_TYPE_SELL && hasBuySignal)
               m_trade.PositionClose(m_position.Ticket());
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Count Own Positions                                              |
//+------------------------------------------------------------------+
int CountOwnPositions()
  {
   int count = 0;
   for(int i = 0; i < PositionsTotal(); i++)
     {
      if(m_position.SelectByIndex(i))
        {
         if(m_position.Symbol() == _Symbol && m_position.Magic() == MagicNumber)
            count++;
        }
     }
   return count;
  }

//+------------------------------------------------------------------+
//| Get ATR Value Safely                                             |
//+------------------------------------------------------------------+
double GetATR(int shift)
  {
   double atr[];
   if(CopyBuffer(m_handleATR, 0, shift, 1, atr) > 0)
      return atr[0];
   return 0.0;
  }

//+------------------------------------------------------------------+
//| Spread Filter                                                    |
//+------------------------------------------------------------------+
bool IsSpreadAcceptable()
  {
   if(!UseSpreadFilter) return true;
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   return spread <= MaximumSpreadPoints;
  }

//+------------------------------------------------------------------+
//| Trading Session Check                                            |
//+------------------------------------------------------------------+
bool IsTradingSessionValid()
  {
   if(!UseTradingSession) return true;
   
   MqlDateTime dt;
   TimeCurrent(dt);
   
   int currentMins = dt.hour * 60 + dt.min;
   int startMins = StartHour * 60 + StartMinute;
   int endMins = EndHour * 60 + EndMinute;
   
   if(startMins < endMins)
     {
      return (currentMins >= startMins && currentMins <= endMins);
     }
   else
     {
      return (currentMins >= startMins || currentMins <= endMins);
     }
  }

//+------------------------------------------------------------------+
//| Cooldown Check                                                   |
//+------------------------------------------------------------------+
bool IsCooldownFinished()
  {
   if(!UseCooldown) return true;
   
   HistorySelect(0, TimeCurrent());
   int total = HistoryDealsTotal();
   datetime lastCloseTime = 0;
   
   for(int i = total - 1; i >= 0; i--)
     {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket > 0)
        {
         if(HistoryDealGetInteger(ticket, DEAL_MAGIC) == MagicNumber && 
            HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol &&
            HistoryDealGetInteger(ticket, DEAL_ENTRY) == DEAL_ENTRY_OUT)
           {
            lastCloseTime = (datetime)HistoryDealGetInteger(ticket, DEAL_TIME);
            break;
           }
        }
     }
     
   if(lastCloseTime == 0) return true;
   
   int barsPassed = iBarShift(_Symbol, _Period, lastCloseTime);
   return (barsPassed >= CooldownBars);
  }
//+------------------------------------------------------------------+