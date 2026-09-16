//+------------------------------------------------------------------+
//|                                     BollingerBandsBreakoutEA.mq5 |
//|                                  Copyright 2026, Algorithmic EA  |
//|                                       Strict MQL5 Implementation |
//+------------------------------------------------------------------+
#property copyright "Algorithmic EA Developer"
#property link      ""
#property version   "1.00"
#property description "Bollinger Bands Breakout System with ATR Risk Management"

#include <Trade\Trade.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\AccountInfo.mqh>

//--- Input Parameters
input group "=== Strategy Core ==="
input ENUM_TIMEFRAMES InpSignalTimeframe = PERIOD_H1;       // Signal Timeframe
input bool            InpOnePositionPerSymbol = true;       // One Position Per Symbol
input long            InpMagicNumber = 20260913;            // Magic Number

input group "=== Bollinger Bands ==="
input int             InpBBPeriod = 20;                     // BB Period
input double          InpBBDeviation = 2.0;                 // BB Deviation

input group "=== Trend & Strength Filters ==="
input int             InpEMAPeriod = 200;                   // EMA Period
input int             InpADXPeriod = 14;                    // ADX Period
input double          InpMinimumADX = 20.0;                 // Minimum ADX Value

input group "=== Stop Loss & Take Profit ==="
input int             InpATRPeriod = 14;                    // ATR Period
input double          InpATRMultiplier = 2.0;               // ATR Multiplier (for SL)
input double          InpRiskReward = 2.0;                  // Risk/Reward Ratio

input group "=== Risk Management ==="
input double          InpRiskPercent = 1.0;                 // Risk Percent of Equity
input bool            InpEnableSpreadFilter = true;         // Enable Spread Filter
input double          InpMaxSpreadPoints = 30.0;            // Max Spread (Points)

input group "=== Debug Logging ==="
input bool            InpEnableDebugLogs = false;           // Enable Debug Logs

//--- Global Objects & Handles
CTrade         m_trade;
CSymbolInfo    m_symbol;
CPositionInfo  m_position;
CAccountInfo   m_account;

int            h_bb  = INVALID_HANDLE;
int            h_ema = INVALID_HANDLE;
int            h_adx = INVALID_HANDLE;
int            h_atr = INVALID_HANDLE;

datetime       m_last_bar_time = 0;

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

   // Create Indicator Handles
   h_bb  = iBands(_Symbol, InpSignalTimeframe, InpBBPeriod, 0, InpBBDeviation, PRICE_CLOSE);
   h_ema = iMA(_Symbol, InpSignalTimeframe, InpEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   h_adx = iADX(_Symbol, InpSignalTimeframe, InpADXPeriod);
   h_atr = iATR(_Symbol, InpSignalTimeframe, InpATRPeriod);

   if(h_bb == INVALID_HANDLE || h_ema == INVALID_HANDLE || h_adx == INVALID_HANDLE || h_atr == INVALID_HANDLE)
     {
      Print("Error creating indicator handles. Initialization failed.");
      return(INIT_FAILED);
     }

   Print("Bollinger Bands Breakout EA Initialized Successfully.");
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(h_bb != INVALID_HANDLE) IndicatorRelease(h_bb);
   if(h_ema != INVALID_HANDLE) IndicatorRelease(h_ema);
   if(h_adx != INVALID_HANDLE) IndicatorRelease(h_adx);
   if(h_atr != INVALID_HANDLE) IndicatorRelease(h_atr);
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   if(IsNewBar())
     {
      if(InpOnePositionPerSymbol && HasOpenPosition())
         return;

      if(InpEnableSpreadFilter && !IsSpreadAcceptable())
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
  }

//+------------------------------------------------------------------+
//| Check for a new bar on the Signal Timeframe                      |
//+------------------------------------------------------------------+
bool IsNewBar()
  {
   datetime time[1];
   if(CopyTime(_Symbol, InpSignalTimeframe, 0, 1, time) <= 0)
      return false;
   
   if(time[0] != m_last_bar_time)
     {
      if(m_last_bar_time != 0)
        {
         m_last_bar_time = time[0];
         if(InpEnableDebugLogs) Print("New bar detected on timeframe: ", EnumToString(InpSignalTimeframe));
         return true;
        }
      m_last_bar_time = time[0];
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Position Check Filter                                            |
//+------------------------------------------------------------------+
bool HasOpenPosition()
  {
   for(int i = 0; i < PositionsTotal(); i++)
     {
      if(m_position.SelectByIndex(i))
        {
         if(m_position.Symbol() == _Symbol && m_position.Magic() == InpMagicNumber)
            return true;
        }
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Spread Filter                                                    |
//+------------------------------------------------------------------+
bool IsSpreadAcceptable()
  {
   m_symbol.RefreshRates();
   double spreadPoints = (m_symbol.Ask() - m_symbol.Bid()) / m_symbol.Point();
   if(spreadPoints > InpMaxSpreadPoints)
     {
      if(InpEnableDebugLogs) PrintFormat("Spread %.1f exceeds max allowed %.1f", spreadPoints, InpMaxSpreadPoints);
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| BUY Signal Logic                                                 |
//+------------------------------------------------------------------+
bool CheckBuySignal()
  {
   MqlRates rates[2];
   if(CopyRates(_Symbol, InpSignalTimeframe, 1, 2, rates) != 2) return false;
   // rates[0] = shift 2, rates[1] = shift 1

   double upperBand[2];
   if(CopyBuffer(h_bb, 1, 1, 2, upperBand) != 2) return false;

   double ema[1];
   if(CopyBuffer(h_ema, 0, 1, 1, ema) != 1) return false;

   double adx[1];
   if(CopyBuffer(h_adx, 0, 1, 1, adx) != 1) return false;

   // 1. Prior candle did NOT close above Upper Band
   if(rates[0].close > upperBand[0]) return false;

   // 2. Breakout candle closes above Upper Band
   if(rates[1].close <= upperBand[1]) return false;

   // 3. Breakout candle is bullish
   if(rates[1].close <= rates[1].open) return false;

   // 4. EMA Filter (Close above EMA)
   if(rates[1].close <= ema[0]) return false;

   // 5. ADX Filter (Sufficient trend strength)
   if(adx[0] < InpMinimumADX) return false;

   if(InpEnableDebugLogs)
     {
      PrintFormat("BUY SIGNAL CONFIRMED | Close[1]: %.5f | UpperBB[1]: %.5f | EMA[1]: %.5f | ADX[1]: %.2f", 
                  rates[1].close, upperBand[1], ema[0], adx[0]);
     }
   return true;
  }

//+------------------------------------------------------------------+
//| SELL Signal Logic                                                |
//+------------------------------------------------------------------+
bool CheckSellSignal()
  {
   MqlRates rates[2];
   if(CopyRates(_Symbol, InpSignalTimeframe, 1, 2, rates) != 2) return false;

   double lowerBand[2];
   if(CopyBuffer(h_bb, 2, 1, 2, lowerBand) != 2) return false;

   double ema[1];
   if(CopyBuffer(h_ema, 0, 1, 1, ema) != 1) return false;

   double adx[1];
   if(CopyBuffer(h_adx, 0, 1, 1, adx) != 1) return false;

   // 1. Prior candle did NOT close below Lower Band
   if(rates[0].close < lowerBand[0]) return false;

   // 2. Breakout candle closes below Lower Band
   if(rates[1].close >= lowerBand[1]) return false;

   // 3. Breakout candle is bearish
   if(rates[1].close >= rates[1].open) return false;

   // 4. EMA Filter (Close below EMA)
   if(rates[1].close >= ema[0]) return false;

   // 5. ADX Filter (Sufficient trend strength)
   if(adx[0] < InpMinimumADX) return false;

   if(InpEnableDebugLogs)
     {
      PrintFormat("SELL SIGNAL CONFIRMED | Close[1]: %.5f | LowerBB[1]: %.5f | EMA[1]: %.5f | ADX[1]: %.2f", 
                  rates[1].close, lowerBand[1], ema[0], adx[0]);
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Trade Calculations                                               |
//+------------------------------------------------------------------+
double CalculateBuyStopLoss(double entry)
  {
   double atr[1];
   if(CopyBuffer(h_atr, 0, 1, 1, atr) != 1) return 0.0;
   return NormalizeDouble(entry - (atr[0] * InpATRMultiplier), m_symbol.Digits());
  }

double CalculateSellStopLoss(double entry)
  {
   double atr[1];
   if(CopyBuffer(h_atr, 0, 1, 1, atr) != 1) return 0.0;
   return NormalizeDouble(entry + (atr[0] * InpATRMultiplier), m_symbol.Digits());
  }

double CalculateBuyTakeProfit(double entry, double sl)
  {
   double risk = entry - sl;
   return NormalizeDouble(entry + (risk * InpRiskReward), m_symbol.Digits());
  }

double CalculateSellTakeProfit(double entry, double sl)
  {
   double risk = sl - entry;
   return NormalizeDouble(entry - (risk * InpRiskReward), m_symbol.Digits());
  }

//+------------------------------------------------------------------+
//| Lot Size & Volume Normalization                                  |
//+------------------------------------------------------------------+
double NormalizeVolume(double vol)
  {
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   
   if(step <= 0) return minLot;
   
   double result = MathFloor(vol / step) * step;
   if(result < minLot) result = minLot;
   if(result > maxLot) result = maxLot;
   return result;
  }

double CalculateLotSize(double entry, double sl)
  {
   double riskMoney = m_account.Equity() * (InpRiskPercent / 100.0);
   
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize == 0 || tickValue == 0) return 0.0;
   
   double riskDistance = MathAbs(entry - sl);
   double riskTicks = riskDistance / tickSize;
   double riskPerLot = riskTicks * tickValue;
   
   if(riskPerLot <= 0) return 0.0;
   
   double calculatedVol = riskMoney / riskPerLot;
   return NormalizeVolume(calculatedVol);
  }

//+------------------------------------------------------------------+
//| Broker Constraints Validation                                    |
//+------------------------------------------------------------------+
bool ValidateStops(ENUM_ORDER_TYPE type, double entry, double sl, double tp)
  {
   double stopLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * m_symbol.Point();
   
   if(type == ORDER_TYPE_BUY)
     {
      if(entry - sl < stopLevel) return false;
      if(tp - entry < stopLevel) return false;
     }
   else
     {
      if(sl - entry < stopLevel) return false;
      if(entry - tp < stopLevel) return false;
     }
   return true;
  }

bool CheckMargin(ENUM_ORDER_TYPE type, double lot, double price)
  {
   double marginReq = 0;
   if(!OrderCalcMargin(type, _Symbol, lot, price, marginReq)) return false;
   return (m_account.FreeMargin() >= marginReq);
  }
//+------------------------------------------------------------------+
//| Execution Functions                                              |
//+------------------------------------------------------------------+
void PrintTradeError(string action)
  {
   PrintFormat("ERROR: %s Failed. Retcode: %d - %s", action, m_trade.ResultRetcode(), m_trade.ResultRetcodeDescription());
  }

bool OpenBuy()
  {
   if(!SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE)) return false; // Trading disabled
   
   m_symbol.RefreshRates();
   double entry = m_symbol.Ask();
   
   double sl = CalculateBuyStopLoss(entry);
   if(sl == 0.0) return false;
   
   double tp = CalculateBuyTakeProfit(entry, sl);
   
   if(!ValidateStops(ORDER_TYPE_BUY, entry, sl, tp))
     {
      if(InpEnableDebugLogs) Print("BUY Aborted: SL/TP violates broker Stop Level");
      return false;
     }

   double lot = CalculateLotSize(entry, sl);
   if(lot == 0.0) return false;

   if(!CheckMargin(ORDER_TYPE_BUY, lot, entry))
     {
      if(InpEnableDebugLogs) Print("BUY Aborted: Insufficient free margin");
      return false;
     }

   if(InpEnableDebugLogs) PrintFormat("Executing BUY | Lot: %.2f | Price: %.5f | SL: %.5f | TP: %.5f", lot, entry, sl, tp);

   if(!m_trade.Buy(lot, _Symbol, entry, sl, tp, "BB_Breakout_Buy"))
     {
      PrintTradeError("Buy Order");
      return false;
     }
   return true;
  }

bool OpenSell()
  {
   if(!SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE)) return false; // Trading disabled
   
   m_symbol.RefreshRates();
   double entry = m_symbol.Bid();
   
   double sl = CalculateSellStopLoss(entry);
   if(sl == 0.0) return false;
   
   double tp = CalculateSellTakeProfit(entry, sl);
   
   if(!ValidateStops(ORDER_TYPE_SELL, entry, sl, tp))
     {
      if(InpEnableDebugLogs) Print("SELL Aborted: SL/TP violates broker Stop Level");
      return false;
     }

   double lot = CalculateLotSize(entry, sl);
   if(lot == 0.0) return false;

   if(!CheckMargin(ORDER_TYPE_SELL, lot, entry))
     {
      if(InpEnableDebugLogs) Print("SELL Aborted: Insufficient free margin");
      return false;
     }

   if(InpEnableDebugLogs) PrintFormat("Executing SELL | Lot: %.2f | Price: %.5f | SL: %.5f | TP: %.5f", lot, entry, sl, tp);

   if(!m_trade.Sell(lot, _Symbol, entry, sl, tp, "BB_Breakout_Sell"))
     {
      PrintTradeError("Sell Order");
      return false;
     }
   return true;
  }
//+------------------------------------------------------------------+