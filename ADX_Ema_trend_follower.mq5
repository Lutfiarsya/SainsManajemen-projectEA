//+------------------------------------------------------------------+
//|                                        ADX_EMA_TrendFollower.mq5 |
//|                                  Copyright 2026, Algorithmic EA  |
//|                                       Strict MQL5 Implementation |
//+------------------------------------------------------------------+
#property copyright "Algorithmic EA Developer"
#property link      ""
#property version   "1.00"
#property description "ADX + EMA Trend Following Strategy"

#include <Trade\Trade.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\AccountInfo.mqh>

//--- Input Parameters
input group "=== Strategy Core ==="
input ENUM_TIMEFRAMES InpSignalTimeframe = PERIOD_H1;       // Signal Timeframe
input int             InpMaximumPositionsPerSymbol = 1;     // Maximum Positions Per Symbol
input long            InpMagicNumber = 20260915;            // Magic Number

input group "=== Trend Indicators ==="
input int             InpFastEMAPeriod = 50;                // Fast EMA Period
input int             InpSlowEMAPeriod = 200;               // Slow EMA Period

input group "=== Strength Filter ==="
input int             InpADXPeriod = 14;                    // ADX Period
input double          InpMinimumADX = 20.0;                 // Minimum ADX Value

input group "=== Risk & Target ==="
input int             InpATRPeriod = 14;                    // ATR Period
input double          InpATRMultiplier = 2.0;               // ATR Multiplier for SL
input double          InpRiskPercent = 1.0;                 // Risk Percent per Trade
input double          InpRiskRewardRatio = 2.0;             // Risk/Reward Ratio

input group "=== Filters & Safety ==="
input bool            InpUseSpreadFilter = true;            // Use Spread Filter
input double          InpMaxSpreadPoints = 30.0;            // Maximum Spread (Points)
input bool            InpEnableDebugLog = false;            // Enable Debug Log

//--- Global Objects & Variables
CTrade         m_trade;
CSymbolInfo    m_symbol;
CPositionInfo  m_position;
CAccountInfo   m_account;

int            h_ema50  = INVALID_HANDLE;
int            h_ema200 = INVALID_HANDLE;
int            h_adx    = INVALID_HANDLE;
int            h_atr    = INVALID_HANDLE;

datetime       m_last_bar_time = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   // Initialize Symbol
   if(!m_symbol.Name(_Symbol))
     {
      Print("Error initializing SymbolInfo");
      return(INIT_FAILED);
     }
   m_symbol.Refresh();

   // Initialize Trade Object
   m_trade.SetExpertMagicNumber(InpMagicNumber);
   m_trade.SetMarginMode();
   m_trade.SetTypeFillingBySymbol(_Symbol);
   m_trade.SetDeviationInPoints(10);

   // Create Indicator Handles
   h_ema50  = iMA(_Symbol, InpSignalTimeframe, InpFastEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   h_ema200 = iMA(_Symbol, InpSignalTimeframe, InpSlowEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   h_adx    = iADX(_Symbol, InpSignalTimeframe, InpADXPeriod);
   h_atr    = iATR(_Symbol, InpSignalTimeframe, InpATRPeriod);

   // Validate Handles
   if(h_ema50 == INVALID_HANDLE || h_ema200 == INVALID_HANDLE || h_adx == INVALID_HANDLE || h_atr == INVALID_HANDLE)
     {
      Print("Error creating indicator handles. Initialization failed.");
      return(INIT_FAILED);
     }

   Print("ADX + EMA Trend Follower Initialized Successfully.");
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(h_ema50 != INVALID_HANDLE)  IndicatorRelease(h_ema50);
   if(h_ema200 != INVALID_HANDLE) IndicatorRelease(h_ema200);
   if(h_adx != INVALID_HANDLE)    IndicatorRelease(h_adx);
   if(h_atr != INVALID_HANDLE)    IndicatorRelease(h_atr);
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   if(!IsNewBar()) return;
   
   if(HasOpenPosition()) return;

   if(InpUseSpreadFilter && !IsSpreadAcceptable()) return;

   // Evaluate Signals
   if(CheckBuySignal())
     {
      ExecuteTrade(ORDER_TYPE_BUY);
      return;
     }

   if(CheckSellSignal())
     {
      ExecuteTrade(ORDER_TYPE_SELL);
      return;
     }
  }

//+------------------------------------------------------------------+
//| Helper: New Bar Detection                                        |
//+------------------------------------------------------------------+
bool IsNewBar()
  {
   datetime time[1];
   if(CopyTime(_Symbol, InpSignalTimeframe, 0, 1, time) <= 0) return false;
   
   // Handle initialization mid-bar
   if(m_last_bar_time == 0)
     {
      m_last_bar_time = time[0];
      return false;
     }
     
   if(time[0] != m_last_bar_time)
     {
      m_last_bar_time = time[0];
      return true;
     }
     
   return false;
  }

//+------------------------------------------------------------------+
//| Helper: Check Existing Positions                                 |
//+------------------------------------------------------------------+
bool HasOpenPosition()
  {
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(m_position.SelectByIndex(i))
        {
         if(m_position.Symbol() == _Symbol && m_position.Magic() == InpMagicNumber)
           {
            count++;
           }
        }
     }
   return (count >= InpMaximumPositionsPerSymbol);
  }

//+------------------------------------------------------------------+
//| Helper: Check Spread                                             |
//+------------------------------------------------------------------+
bool IsSpreadAcceptable()
  {
   m_symbol.RefreshRates();
   double spreadPoints = (m_symbol.Ask() - m_symbol.Bid()) / m_symbol.Point();
   
   if(spreadPoints > InpMaxSpreadPoints)
     {
      if(InpEnableDebugLog) PrintFormat("Spread %.1f exceeds Max Allowed %.1f", spreadPoints, InpMaxSpreadPoints);
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Helper: Buy Signal Logic                                         |
//+------------------------------------------------------------------+
bool CheckBuySignal()
  {
   MqlRates rates[1];
   double ema50[1], ema200[1], adx[1];

   // Copy data for Shift 1
   if(CopyRates(_Symbol, InpSignalTimeframe, 1, 1, rates) != 1) return false;
   if(CopyBuffer(h_ema50, 0, 1, 1, ema50) != 1) return false;
   if(CopyBuffer(h_ema200, 0, 1, 1, ema200) != 1) return false;
   if(CopyBuffer(h_adx, 0, 1, 1, adx) != 1) return false; // 0 = MAIN_LINE

   // Rule 1: Bullish EMA structure
   if(ema50[0] <= ema200[0]) return false;

   // Rule 2: Price above EMA 200
   if(rates[0].close <= ema200[0]) return false;

   // Rule 3: Sufficient trend strength
   if(adx[0] < InpMinimumADX) return false;

   // Rule 4: Bullish confirmation candle
   if(rates[0].close <= rates[0].open) return false;

   if(InpEnableDebugLog) 
      PrintFormat("BUY SIGNAL: EMA50:%.5f | EMA200:%.5f | ADX:%.2f | Close:%.5f", ema50[0], ema200[0], adx[0], rates[0].close);

   return true;
  }

//+------------------------------------------------------------------+
//| Helper: Sell Signal Logic                                        |
//+------------------------------------------------------------------+
bool CheckSellSignal()
  {
   MqlRates rates[1];
   double ema50[1], ema200[1], adx[1];

   // Copy data for Shift 1
   if(CopyRates(_Symbol, InpSignalTimeframe, 1, 1, rates) != 1) return false;
   if(CopyBuffer(h_ema50, 0, 1, 1, ema50) != 1) return false;
   if(CopyBuffer(h_ema200, 0, 1, 1, ema200) != 1) return false;
   if(CopyBuffer(h_adx, 0, 1, 1, adx) != 1) return false;

   // Rule 1: Bearish EMA structure
   if(ema50[0] >= ema200[0]) return false;

   // Rule 2: Price below EMA 200
   if(rates[0].close >= ema200[0]) return false;

   // Rule 3: Sufficient trend strength
   if(adx[0] < InpMinimumADX) return false;

   // Rule 4: Bearish confirmation candle
   if(rates[0].close >= rates[0].open) return false;

   if(InpEnableDebugLog) 
      PrintFormat("SELL SIGNAL: EMA50:%.5f | EMA200:%.5f | ADX:%.2f | Close:%.5f", ema50[0], ema200[0], adx[0], rates[0].close);

   return true;
  }

//+------------------------------------------------------------------+
//| Execute Trade                                                    |
//+------------------------------------------------------------------+
void ExecuteTrade(ENUM_ORDER_TYPE type)
  {
   m_symbol.RefreshRates();
   
   double atr[1];
   if(CopyBuffer(h_atr, 0, 1, 1, atr) != 1) return;

   double entry = (type == ORDER_TYPE_BUY) ? m_symbol.Ask() : m_symbol.Bid();
   double sl = 0.0, tp = 0.0, risk_dist = 0.0;

   // Calculate SL & TP
   if(type == ORDER_TYPE_BUY)
     {
      sl = m_symbol.NormalizePrice(entry - (atr[0] * InpATRMultiplier));
      risk_dist = entry - sl;
      tp = m_symbol.NormalizePrice(entry + (risk_dist * InpRiskRewardRatio));
     }
   else
     {
      sl = m_symbol.NormalizePrice(entry + (atr[0] * InpATRMultiplier));
      risk_dist = sl - entry;
      tp = m_symbol.NormalizePrice(entry - (risk_dist * InpRiskRewardRatio));
     }

   // Validation checks
   if(!ValidateStops(type, entry, sl, tp))
     {
      if(InpEnableDebugLog) Print("Trade aborted: SL or TP violates broker Stop Level.");
      return;
     }

   double lot = CalculateLotSize(risk_dist);
   if(lot <= 0)
     {
      if(InpEnableDebugLog) Print("Trade aborted: Calculated lot size is invalid.");
      return;
     }

   if(!CheckMargin(type, lot, entry))
     {
      if(InpEnableDebugLog) Print("Trade aborted: Insufficient free margin.");
      return;
     }

   if(InpEnableDebugLog)
      PrintFormat("Executing %s | Entry:%.5f | SL:%.5f | TP:%.5f | Lot:%.2f", EnumToString(type), entry, sl, tp, lot);

   // Send Order
   bool res = false;
   if(type == ORDER_TYPE_BUY)
      res = m_trade.Buy(lot, _Symbol, entry, sl, tp, "ADX_EMA_Buy");
   else
      res = m_trade.Sell(lot, _Symbol, entry, sl, tp, "ADX_EMA_Sell");

   if(!res) PrintTradeError();
  }

//+------------------------------------------------------------------+
//| Calculate Normalized Risk-Based Lot Size                         |
//+------------------------------------------------------------------+
double CalculateLotSize(double risk_distance)
  {
   double risk_money = m_account.Equity() * (InpRiskPercent / 100.0);
   
   double tick_size  = m_symbol.TickSize();
   double tick_value = m_symbol.TickValue();
   
   if(tick_size == 0 || tick_value == 0 || risk_distance <= 0) return 0.0;
   
   double loss_ticks = risk_distance / tick_size;
   double risk_per_lot = loss_ticks * tick_value;
   
   if(risk_per_lot <= 0) return 0.0;
   
   double lot = risk_money / risk_per_lot;
   
   // Normalize Lot Volume
   double min_lot = m_symbol.LotsMin();
   double max_lot = m_symbol.LotsMax();
   double step    = m_symbol.LotsStep();
   
   lot = MathFloor(lot / step) * step;
   
   if(lot < min_lot) lot = min_lot;
   if(lot > max_lot) lot = max_lot;
   
   return lot;
  }

//+------------------------------------------------------------------+
//| Validate SL & TP against Broker Limits                           |
//+------------------------------------------------------------------+
bool ValidateStops(ENUM_ORDER_TYPE type, double entry, double sl, double tp)
  {
   double stop_level = m_symbol.StopsLevel() * m_symbol.Point();
   
   if(type == ORDER_TYPE_BUY)
     {
      if((entry - sl) < stop_level) return false;
      if((tp - entry) < stop_level) return false;
     }
   else
     {
      if((sl - entry) < stop_level) return false;
      if((entry - tp) < stop_level) return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Verify Sufficient Margin Requirements                            |
//+------------------------------------------------------------------+
bool CheckMargin(ENUM_ORDER_TYPE type, double lot, double price)
  {
   double margin_req = 0.0;
   if(!OrderCalcMargin(type, _Symbol, lot, price, margin_req)) return false;
   
   return (m_account.FreeMargin() >= margin_req);
  }

//+------------------------------------------------------------------+
//| Print Standardized Trade Error Logs                              |
//+------------------------------------------------------------------+
void PrintTradeError()
  {
   PrintFormat("Trade Error: %s (Retcode: %d)", m_trade.ResultRetcodeDescription(), m_trade.ResultRetcode());
  }
//+------------------------------------------------------------------+