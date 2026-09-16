//+------------------------------------------------------------------+
//|                                     Donchian_Breakout_Pro.mq5    |
//|                                  Copyright 2026, Algorithmic EA  |
//|                                       Strict MQL5 Implementation |
//+------------------------------------------------------------------+
#property copyright "Algorithmic EA Developer"
#property link      ""
#property version   "1.00"
#property description "Donchian Channel Breakout + ATR Risk Management"

#include <Trade\Trade.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\AccountInfo.mqh>

//--- Enums
enum ENUM_BREAKOUT_MODE
  {
   CLOSE_BREAKOUT = 0,     // Close Breakout
   HIGH_LOW_BREAKOUT = 1   // High/Low Breakout
  };

enum ENUM_SL_MODE
  {
   SL_ATR = 0,             // ATR Stop Loss
   SL_DONCHIAN = 1,        // Donchian Channel Stop Loss
   SL_FIXED = 2            // Fixed Points Stop Loss
  };

enum ENUM_TP_MODE
  {
   TP_RISK_REWARD = 0,     // Risk/Reward Multiplier
   TP_FIXED = 1,           // Fixed Points Take Profit
   TP_ATR = 2              // ATR Take Profit
  };

enum ENUM_LOT_MODE
  {
   LOT_FIXED = 0,          // Fixed Lot Size
   LOT_RISK_PERCENT = 1    // Risk Percentage of Equity
  };

//--- Input Parameters
input group "=== Strategy Core ==="
input int                InpDonchianPeriod = 20;               // Donchian Period
input ENUM_TIMEFRAMES    InpSignalTimeframe = PERIOD_H1;       // Signal Timeframe
input ENUM_BREAKOUT_MODE InpBreakoutMode = CLOSE_BREAKOUT;     // Breakout Evaluation Mode
input int                InpBreakoutBufferPoints = 0;          // Breakout Buffer (Points)
input bool               InpEnableBreakoutRetest = false;      // Enable Breakout Retest Entry

input group "=== Trend & Volatility Filters ==="
input bool               InpEnableEMAFilter = true;            // Enable EMA Trend Filter
input int                InpEMAPeriod = 200;                   // EMA Period
input bool               InpEnableATRFilter = false;           // Enable ATR Volatility Filter
input int                InpATRPeriod = 14;                    // ATR Period
input double             InpMinimumATR = 0.0010;               // Minimum ATR Value
input bool               InpEnableADXFilter = true;            // Enable ADX Trend Filter
input int                InpADXPeriod = 14;                    // ADX Period
input double             InpMinimumADX = 20.0;                 // Minimum ADX Value
input bool               InpEnableVolumeFilter = false;        // Enable Volume Filter
input int                InpVolumeLookback = 20;               // Volume Lookback Period
input double             InpMinimumVolumeRatio = 1.2;          // Minimum Volume Ratio

input group "=== Stop Loss ==="
input ENUM_SL_MODE       InpSLMode = SL_ATR;                   // Stop Loss Mode
input double             InpATRMultiplier = 2.0;               // ATR Multiplier (for SL)
input int                InpStopLossBufferPoints = 50;         // Donchian SL Buffer (Points)
input int                InpFixedStopLossPoints = 500;         // Fixed SL (Points)

input group "=== Take Profit ==="
input ENUM_TP_MODE       InpTPMode = TP_RISK_REWARD;           // Take Profit Mode
input double             InpRiskReward = 2.0;                  // Risk/Reward Ratio
input int                InpFixedTakeProfitPoints = 1000;      // Fixed TP (Points)
input double             InpTakeProfitATRMultiplier = 3.0;     // Take Profit ATR Multiplier

input group "=== Risk & Position Sizing ==="
input ENUM_LOT_MODE      InpLotMode = LOT_RISK_PERCENT;        // Lot Calculation Mode
input double             InpFixedLot = 0.1;                    // Fixed Lot Size
input double             InpRiskPercent = 1.0;                 // Risk % of Equity
input int                InpMaxOpenPositions = 1;              // Max Open Positions (EA Total)
input bool               InpOnePositionPerSymbol = true;       // Strict One Position Per Symbol
input long               InpMagicNumber = 20260913;            // EA Magic Number

input group "=== Trade Management ==="
input bool               InpEnableBreakEven = false;           // Enable Break-Even
input int                InpBreakEvenTriggerPoints = 200;      // Break-Even Trigger (Points)
input int                InpBreakEvenOffsetPoints = 20;        // Break-Even Offset (Points)
input bool               InpEnableTrailingStop = false;        // Enable ATR Trailing Stop
input double             InpTrailingATRMultiplier = 1.5;       // Trailing ATR Multiplier

input group "=== Environment Filters ==="
input bool               InpEnableSpreadFilter = true;         // Enable Spread Filter
input int                InpMaxSpreadPoints = 30;              // Max Allowed Spread (Points)
input bool               InpEnableTradingHours = false;        // Enable Trading Hours
input int                InpStartHour = 8;                     // Start Hour
input int                InpStartMinute = 0;                   // Start Minute
input int                InpEndHour = 20;                      // End Hour
input int                InpEndMinute = 0;                     // End Minute
input bool               InpEnableDebugLogs = false;           // Enable Debug Logging

//--- Global Variables & Objects
CTrade         m_trade;
CSymbolInfo    m_symbol;
CPositionInfo  m_position;
CAccountInfo   m_account;

int            h_ema = INVALID_HANDLE;
int            h_atr = INVALID_HANDLE;
int            h_adx = INVALID_HANDLE;

datetime       m_last_bar_time = 0;

//--- Retest State Variables (RAM based, resets safely on EA restart)
bool           m_retest_pending = false;
ENUM_ORDER_TYPE m_retest_type;
double         m_retest_level = 0.0;
double         m_retest_sl = 0.0;
double         m_retest_tp = 0.0;
datetime       m_retest_expiration = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   if(!m_symbol.Name(_Symbol))
     {
      Print("Error initializing SymbolInfo");
      return(INIT_FAILED);
     }
   m_symbol.Refresh();

   m_trade.SetExpertMagicNumber(InpMagicNumber);
   m_trade.SetMarginMode();
   m_trade.SetTypeFillingBySymbol(_Symbol);
   m_trade.SetDeviationInPoints(10);

   if(InpEnableEMAFilter) h_ema = iMA(_Symbol, InpSignalTimeframe, InpEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if(InpEnableATRFilter || InpSLMode == SL_ATR || InpTPMode == TP_ATR || InpEnableTrailingStop) 
      h_atr = iATR(_Symbol, InpSignalTimeframe, InpATRPeriod);
   if(InpEnableADXFilter) h_adx = iADX(_Symbol, InpSignalTimeframe, InpADXPeriod);

   if((InpEnableEMAFilter && h_ema == INVALID_HANDLE) ||
      ((InpEnableATRFilter || InpSLMode == SL_ATR) && h_atr == INVALID_HANDLE) ||
      (InpEnableADXFilter && h_adx == INVALID_HANDLE))
     {
      Print("Error creating indicator handles. Check parameters.");
      return(INIT_FAILED);
     }

   Print("Donchian Breakout Pro Initialized.");
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(h_ema != INVALID_HANDLE) IndicatorRelease(h_ema);
   if(h_atr != INVALID_HANDLE) IndicatorRelease(h_atr);
   if(h_adx != INVALID_HANDLE) IndicatorRelease(h_adx);
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   m_symbol.RefreshRates();

   // 1. Continuous Management (Every Tick)
   ManageBreakEven();
   ManageTrailingStop();
   CheckRetestExecution();

   // 2. Signal Generation (Strictly Once Per New Bar)
   if(IsNewBar(InpSignalTimeframe))
     {
      if(InpEnableTradingHours && !IsTradingTime()) return;
      if(CountOpenPositions() >= InpMaxOpenPositions) return;
      if(InpOnePositionPerSymbol && HasPositionOnCurrentSymbol()) return;

      double upper, lower, middle;
      if(!GetDonchianLevels(upper, lower, middle)) return;

      if(!CheckTrendFilter() || !CheckATRFilter() || !CheckADXFilter() || !CheckVolumeFilter()) return;

      if(CheckBuySignal(upper))
        {
         if(InpEnableBreakoutRetest) SetupRetest(ORDER_TYPE_BUY, upper);
         else ExecuteTrade(ORDER_TYPE_BUY, upper, lower);
        }
      else if(CheckSellSignal(lower))
        {
         if(InpEnableBreakoutRetest) SetupRetest(ORDER_TYPE_SELL, lower);
         else ExecuteTrade(ORDER_TYPE_SELL, upper, lower);
        }
     }
  }

//+------------------------------------------------------------------+
//| New Bar Detection Mechanism                                      |
//+------------------------------------------------------------------+
bool IsNewBar(ENUM_TIMEFRAMES timeframe)
  {
   datetime time[1];
   if(CopyTime(_Symbol, timeframe, 0, 1, time) <= 0) return false;
   
   if(time[0] != m_last_bar_time)
     {
      if(m_last_bar_time != 0) 
        {
         m_last_bar_time = time[0];
         return true;
        }
      m_last_bar_time = time[0];
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Get Donchian Levels strictly using shift 2 to N+1                |
//+------------------------------------------------------------------+
bool GetDonchianLevels(double &upper, double &lower, double &middle)
  {
   double high_arr[], low_arr[];
   // Starting at index 2 (skips forming candle [0] and breakout signal candle [1])
   if(CopyHigh(_Symbol, InpSignalTimeframe, 2, InpDonchianPeriod, high_arr) < InpDonchianPeriod) return false;
   if(CopyLow(_Symbol, InpSignalTimeframe, 2, InpDonchianPeriod, low_arr) < InpDonchianPeriod) return false;
   
   upper = high_arr[ArrayMaximum(high_arr)];
   lower = low_arr[ArrayMinimum(low_arr)];
   middle = (upper + lower) / 2.0;
   
   return true;
  }

//+------------------------------------------------------------------+
//| Evaluates Buy Signal (Index 1)                                   |
//+------------------------------------------------------------------+
bool CheckBuySignal(double upper)
  {
   double close[1], high[1];
   if(CopyClose(_Symbol, InpSignalTimeframe, 1, 1, close) <= 0) return false;
   if(CopyHigh(_Symbol, InpSignalTimeframe, 1, 1, high) <= 0) return false;
   
   double buffer = InpBreakoutBufferPoints * m_symbol.Point();
   double threshold = upper + buffer;

   if(InpBreakoutMode == CLOSE_BREAKOUT) return (close[0] > threshold);
   else return (high[0] > threshold);
  }

//+------------------------------------------------------------------+
//| Evaluates Sell Signal (Index 1)                                  |
//+------------------------------------------------------------------+
bool CheckSellSignal(double lower)
  {
   double close[1], low[1];
   if(CopyClose(_Symbol, InpSignalTimeframe, 1, 1, close) <= 0) return false;
   if(CopyLow(_Symbol, InpSignalTimeframe, 1, 1, low) <= 0) return false;
   
   double buffer = InpBreakoutBufferPoints * m_symbol.Point();
   double threshold = lower - buffer;

   if(InpBreakoutMode == CLOSE_BREAKOUT) return (close[0] < threshold);
   else return (low[0] < threshold);
  }

//+------------------------------------------------------------------+
//| Filter Evaluators (Evaluated strictly on Index 1)                |
//+------------------------------------------------------------------+
bool CheckTrendFilter()
  {
   if(!InpEnableEMAFilter) return true;
   double ema[1], close[1];
   if(CopyBuffer(h_ema, 0, 1, 1, ema) <= 0) return false;
   if(CopyClose(_Symbol, InpSignalTimeframe, 1, 1, close) <= 0) return false;
   
   // Logic check is handled contextually in execution, but macro trend check:
   // If price is below EMA, only sells allowed (vice versa). 
   // We return true if filter passes general existence, specific direction is filtered below.
   return true; 
  }

bool CheckATRFilter()
  {
   if(!InpEnableATRFilter) return true;
   double atr[1];
   if(CopyBuffer(h_atr, 0, 1, 1, atr) <= 0) return false;
   return (atr[0] >= InpMinimumATR);
  }

bool CheckADXFilter()
  {
   if(!InpEnableADXFilter) return true;
   double adx[1];
   if(CopyBuffer(h_adx, 0, 1, 1, adx) <= 0) return false; // Buffer 0 = Main ADX
   return (adx[0] >= InpMinimumADX);
  }

bool CheckVolumeFilter()
  {
   if(!InpEnableVolumeFilter) return true;
   long vol[1], hist_vol[];
   if(CopyTickVolume(_Symbol, InpSignalTimeframe, 1, 1, vol) <= 0) return false;
   if(CopyTickVolume(_Symbol, InpSignalTimeframe, 2, InpVolumeLookback, hist_vol) < InpVolumeLookback) return false;
   
   long sum = 0;
   for(int i=0; i<InpVolumeLookback; i++) sum += hist_vol[i];
   double avg = (double)sum / InpVolumeLookback;
   
   return (vol[0] >= avg * InpMinimumVolumeRatio);
  }

//+------------------------------------------------------------------+
//| Trade Execution Engine                                           |
//+------------------------------------------------------------------+
void ExecuteTrade(ENUM_ORDER_TYPE type, double donchianUpper, double donchianLower)
  {
   if(InpEnableSpreadFilter && !IsSpreadAcceptable()) return;

   // Trend Filter Enforcement
   if(InpEnableEMAFilter)
     {
      double ema[1], close[1];
      CopyBuffer(h_ema, 0, 1, 1, ema);
      CopyClose(_Symbol, InpSignalTimeframe, 1, 1, close);
      if(type == ORDER_TYPE_BUY && close[0] <= ema[0]) return;
      if(type == ORDER_TYPE_SELL && close[0] >= ema[0]) return;
     }

   double entryPrice = (type == ORDER_TYPE_BUY) ? m_symbol.Ask() : m_symbol.Bid();
   double slPrice = CalculateStopLoss(type, entryPrice, donchianUpper, donchianLower);
   
   ValidateStopLevel(type, entryPrice, slPrice);
   
   double slDistance = MathAbs(entryPrice - slPrice) / m_symbol.Point();
   double volume = CalculateLotSize(slDistance);
   
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   
   if(volume < minLot || volume > maxLot)
     {
      if(InpEnableDebugLogs) Print("Execution aborted: Invalid volume size: ", volume);
      return;
     }

   double tpPrice = CalculateTakeProfit(type, entryPrice, slDistance);
   
   slPrice = m_symbol.NormalizePrice(slPrice);
   tpPrice = m_symbol.NormalizePrice(tpPrice);
   entryPrice = m_symbol.NormalizePrice(entryPrice);

   if(InpEnableDebugLogs)
     {
      PrintFormat("Executing %s | Vol: %.2f | Entry: %.5f | SL: %.5f | TP: %.5f",
                  (type == ORDER_TYPE_BUY ? "BUY" : "SELL"), volume, entryPrice, slPrice, tpPrice);
     }

   bool res = false;
   if(type == ORDER_TYPE_BUY) res = m_trade.Buy(volume, _Symbol, entryPrice, slPrice, tpPrice, "DonchianPro");
   else res = m_trade.Sell(volume, _Symbol, entryPrice, slPrice, tpPrice, "DonchianPro");

   if(!res) PrintFormat("Trade Failed! Err: %d | %s", m_trade.ResultRetcode(), m_trade.ResultRetcodeDescription());
  }
//+------------------------------------------------------------------+
//| Retest Logic Management                                          |
//+------------------------------------------------------------------+
void SetupRetest(ENUM_ORDER_TYPE type, double level)
  {
   m_retest_pending = true;
   m_retest_type = type;
   m_retest_level = level;
   if(InpEnableDebugLogs) Print("Retest mode activated. Waiting for price to return to: ", level);
  }

void CheckRetestExecution()
  {
   if(!m_retest_pending) return;
   
   if(m_retest_type == ORDER_TYPE_BUY && m_symbol.Ask() <= m_retest_level)
     {
      m_retest_pending = false; // Execute and clear
      double up=0, dn=0, mid=0;
      if(GetDonchianLevels(up, dn, mid)) ExecuteTrade(ORDER_TYPE_BUY, up, dn);
     }
   else if(m_retest_type == ORDER_TYPE_SELL && m_symbol.Bid() >= m_retest_level)
     {
      m_retest_pending = false; // Execute and clear
      double up=0, dn=0, mid=0;
      if(GetDonchianLevels(up, dn, mid)) ExecuteTrade(ORDER_TYPE_SELL, up, dn);
     }
  }

//+------------------------------------------------------------------+
//| Dynamic Calculation Functions                                    |
//+------------------------------------------------------------------+
double CalculateStopLoss(ENUM_ORDER_TYPE type, double entry, double upper, double lower)
  {
   double sl = 0.0;
   if(type == ORDER_TYPE_BUY)
     {
      switch(InpSLMode)
        {
         case SL_ATR:
           {
            double atr_b[1]; CopyBuffer(h_atr, 0, 1, 1, atr_b);
            sl = entry - (atr_b[0] * InpATRMultiplier); 
            break;
           }
         case SL_DONCHIAN: 
            sl = lower - (InpStopLossBufferPoints * m_symbol.Point()); break;
         case SL_FIXED:    
            sl = entry - (InpFixedStopLossPoints * m_symbol.Point()); break;
        }
     }
   else
     {
      switch(InpSLMode)
        {
         case SL_ATR:
           {
            double atr_s[1]; CopyBuffer(h_atr, 0, 1, 1, atr_s);
            sl = entry + (atr_s[0] * InpATRMultiplier); 
            break;
           }
         case SL_DONCHIAN: 
            sl = upper + (InpStopLossBufferPoints * m_symbol.Point()); break;
         case SL_FIXED:    
            sl = entry + (InpFixedStopLossPoints * m_symbol.Point()); break;
        }
     }
   return sl;
  }

double CalculateTakeProfit(ENUM_ORDER_TYPE type, double entry, double slDistancePoints)
  {
   double tp = 0.0;
   double riskPoints = slDistancePoints * m_symbol.Point();

   if(type == ORDER_TYPE_BUY)
     {
      switch(InpTPMode)
        {
         case TP_RISK_REWARD: tp = entry + (riskPoints * InpRiskReward); break;
         case TP_FIXED:       tp = entry + (InpFixedTakeProfitPoints * m_symbol.Point()); break;
         case TP_ATR:         
           {
            double atr_b[1]; CopyBuffer(h_atr, 0, 1, 1, atr_b);
            tp = entry + (atr_b[0] * InpTakeProfitATRMultiplier); 
            break;
           }
        }
     }
   else
     {
      switch(InpTPMode)
        {
         case TP_RISK_REWARD: tp = entry - (riskPoints * InpRiskReward); break;
         case TP_FIXED:       tp = entry - (InpFixedTakeProfitPoints * m_symbol.Point()); break;
         case TP_ATR:         
           {
            double atr_s[1]; CopyBuffer(h_atr, 0, 1, 1, atr_s);
            tp = entry - (atr_s[0] * InpTakeProfitATRMultiplier); 
            break;
           }
        }
     }
   return tp;
  }

double CalculateLotSize(double slDistancePoints)
  {
   if(InpLotMode == LOT_FIXED) return NormalizeVolume(InpFixedLot);
   
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   if(slDistancePoints <= 0) return minLot;

   double riskMoney = m_account.Equity() * (InpRiskPercent / 100.0);
   double pointValue = m_symbol.TickValue() * (m_symbol.Point() / m_symbol.TickSize());
   double riskPerLot = slDistancePoints * pointValue;
   
   if(riskPerLot <= 0) return minLot;
   
   double calculatedVol = riskMoney / riskPerLot;
   return NormalizeVolume(calculatedVol);
  }

double NormalizeVolume(double vol)
  {
   double min = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double max = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   
   if(step <= 0) return min; 
   
   double result = MathFloor(vol / step) * step;
   if(result < min) result = min;
   if(result > max) result = max;
   return result;
  }

void ValidateStopLevel(ENUM_ORDER_TYPE type, double entry, double &sl)
  {
   double stopLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * m_symbol.Point();
   if(MathAbs(entry - sl) < stopLevel)
      sl = (type == ORDER_TYPE_BUY) ? entry - stopLevel : entry + stopLevel;
  }

//+------------------------------------------------------------------+
//| Trade Management Routines                                        |
//+------------------------------------------------------------------+
void ManageBreakEven()
  {
   if(!InpEnableBreakEven) return;
   double stopLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * m_symbol.Point();

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(m_position.SelectByIndex(i) && m_position.Symbol() == _Symbol && m_position.Magic() == InpMagicNumber)
        {
         double entry = m_position.PriceOpen();
         double sl = m_position.StopLoss();
         double price = m_position.PriceCurrent();
         double trigger = InpBreakEvenTriggerPoints * m_symbol.Point();
         double offset = InpBreakEvenOffsetPoints * m_symbol.Point();

         if(m_position.PositionType() == POSITION_TYPE_BUY)
           {
            if(price - entry >= trigger && sl < entry)
              {
               double newSL = m_symbol.NormalizePrice(entry + offset);
               if(price - newSL > stopLevel && newSL > sl) m_trade.PositionModify(m_position.Ticket(), newSL, m_position.TakeProfit());
              }
           }
         else if(m_position.PositionType() == POSITION_TYPE_SELL)
           {
            if(entry - price >= trigger && (sl > entry || sl == 0.0))
              {
               double newSL = m_symbol.NormalizePrice(entry - offset);
               if(newSL - price > stopLevel && (newSL < sl || sl == 0.0)) m_trade.PositionModify(m_position.Ticket(), newSL, m_position.TakeProfit());
              }
           }
        }
     }
  }

void ManageTrailingStop()
  {
   if(!InpEnableTrailingStop) return;
   
   double atr_val[1];
   if(CopyBuffer(h_atr, 0, 1, 1, atr_val) <= 0) return;
   double trailDist = atr_val[0] * InpTrailingATRMultiplier;
   double stopLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * m_symbol.Point();

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(m_position.SelectByIndex(i) && m_position.Symbol() == _Symbol && m_position.Magic() == InpMagicNumber)
        {
         double sl = m_position.StopLoss();
         double price = m_position.PriceCurrent();
         
         if(m_position.PositionType() == POSITION_TYPE_BUY)
           {
            double newSL = m_symbol.NormalizePrice(price - trailDist);
            if(newSL > sl && price - newSL > stopLevel) m_trade.PositionModify(m_position.Ticket(), newSL, m_position.TakeProfit());
           }
         else if(m_position.PositionType() == POSITION_TYPE_SELL)
           {
            double newSL = m_symbol.NormalizePrice(price + trailDist);
            if((newSL < sl || sl == 0.0) && newSL - price > stopLevel) m_trade.PositionModify(m_position.Ticket(), newSL, m_position.TakeProfit());
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Utility & Info Functions                                         |
//+------------------------------------------------------------------+
bool IsTradingTime()
  {
   MqlDateTime dt; TimeCurrent(dt);
   int currentMins = dt.hour * 60 + dt.min;
   int startMins = InpStartHour * 60 + InpStartMinute;
   int endMins = InpEndHour * 60 + InpEndMinute;
   if(startMins == endMins) return true; 
   if(startMins < endMins) return (currentMins >= startMins && currentMins < endMins);
   else return (currentMins >= startMins || currentMins < endMins); 
  }

bool IsSpreadAcceptable()
  {
   return (SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) <= InpMaxSpreadPoints);
  }

int CountOpenPositions()
  {
   int count = 0;
   for(int i = 0; i < PositionsTotal(); i++)
     {
      if(m_position.SelectByIndex(i) && m_position.Magic() == InpMagicNumber) count++;
     }
   return count;
  }

bool HasPositionOnCurrentSymbol()
  {
   for(int i = 0; i < PositionsTotal(); i++)
     {
      if(m_position.SelectByIndex(i) && m_position.Symbol() == _Symbol && m_position.Magic() == InpMagicNumber) return true;
     }
   return false;
  }
//+------------------------------------------------------------------+