//+------------------------------------------------------------------+
//|                                               IchimokuMaster.mq5 |
//|                                  Copyright 2024, MQL5 Developer  |
//|                                       Strict MQL5 Implementation |
//+------------------------------------------------------------------+
#property copyright "MQL5 Developer"
#property link      ""
#property version   "1.00"
#property description "Advanced Ichimoku Cloud Breakout & Bounce EA"

#include <Trade\Trade.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\AccountInfo.mqh>

//--- Enums
enum ENUM_STRATEGY_MODE
  {
   STRATEGY_BREAKOUT = 0, // Breakout Only
   STRATEGY_BOUNCE = 1,   // Bounce Only
   STRATEGY_BOTH = 2      // Breakout & Bounce
  };

enum ENUM_SL_MODE
  {
   SL_FIXED_POINTS = 0,   // Fixed Points
   SL_ATR = 1,            // ATR Based
   SL_KIJUN = 2,          // Beyond Kijun-sen
   SL_CLOUD_EXTREME = 3,  // Beyond Cloud (Kumo)
   SL_SWING = 4           // Recent Swing High/Low
  };

enum ENUM_TP_MODE
  {
   TP_FIXED_RR = 0,       // Fixed Risk/Reward Ratio
   TP_FIXED_POINTS = 1,   // Fixed Points
   TP_ATR = 2             // ATR Based
  };

enum ENUM_LOT_MODE
  {
   LOT_FIXED = 0,         // Fixed Lot Size
   LOT_RISK_PERCENT = 1   // Risk Percentage
  };

enum ENUM_TRAILING_MODE
  {
   TRAIL_OFF = 0,         // Disabled
   TRAIL_POINTS = 1,      // Fixed Points
   TRAIL_ATR = 2,         // ATR Based
   TRAIL_KIJUN = 3        // Follow Kijun-sen
  };

//--- Inputs
input group "=== Strategy Settings ==="
input ENUM_TIMEFRAMES      InpSignalTimeframe = PERIOD_H1;   // Signal Timeframe
input ENUM_STRATEGY_MODE   InpStrategy = STRATEGY_BOTH;      // Trading Strategy
input bool                 InpEnableBuy = true;              // Enable BUY Signals
input bool                 InpEnableSell = true;             // Enable SELL Signals
input int                  InpMaxOpenPositions = 1;          // Max Open Positions per Symbol
input bool                 InpOnePositionPerSymbol = true;   // Strict One Position Mode

input group "=== Ichimoku Settings ==="
input int                  InpTenkanPeriod = 9;              // Tenkan-sen Period
input int                  InpKijunPeriod = 26;              // Kijun-sen Period
input int                  InpSenkouPeriod = 52;             // Senkou Span B Period
input int                  InpDisplacement = 26;             // Displacement

input group "=== Optional Trend Filters ==="
input bool                 InpFilterTenkanKijun = true;      // Require Tenkan/Kijun Alignment
input bool                 InpFilterPriceKijun = false;      // Require Price/Kijun Alignment
input bool                 InpFilterCloudTrend = true;       // Require Future Cloud Polarity
input bool                 InpFilterChikou = false;          // Require Chikou Span Confirmation
input int                  InpBounceMaxPenetration = 30;     // Max Bounce Penetration (Points)

input group "=== Stop Loss Settings ==="
input ENUM_SL_MODE         InpSLMode = SL_CLOUD_EXTREME;     // Stop Loss Mode
input int                  InpSLPoints = 500;                // SL Points (if Fixed)
input double               InpSLATRMult = 1.5;               // SL ATR Multiplier (if ATR)
input int                  InpSLBufferPoints = 50;           // Buffer for Ichimoku/Swing SL (Points)
input int                  InpSwingLookback = 10;            // Bars to scan for Swing SL

input group "=== Take Profit Settings ==="
input ENUM_TP_MODE         InpTPMode = TP_FIXED_RR;          // Take Profit Mode
input double               InpTPRiskReward = 2.0;            // Risk/Reward Ratio
input int                  InpTPPoints = 1000;               // TP Points (if Fixed)
input double               InpTPATRMult = 3.0;               // TP ATR Multiplier (if ATR)

input group "=== Position Sizing ==="
input ENUM_LOT_MODE        InpLotMode = LOT_RISK_PERCENT;    // Lot Sizing Mode
input double               InpRiskPercent = 1.0;             // Risk Percent (%)
input double               InpFixedLot = 0.01;               // Fixed Lot Size

input group "=== Management Settings ==="
input bool                 InpEnableBreakEven = true;        // Enable Break-Even
input int                  InpBreakEvenTrigger = 200;        // BE Trigger Profit (Points)
input int                  InpBreakEvenBuffer = 20;          // BE SL Buffer (Points)
input ENUM_TRAILING_MODE   InpTrailingMode = TRAIL_OFF;      // Trailing Stop Mode
input int                  InpTrailingPoints = 150;          // Trail Points
input double               InpTrailingATRMult = 2.0;         // Trail ATR Multiplier

input group "=== Session & Filters ==="
input bool                 InpEnableTradingHours = false;    // Enable Session Filter
input int                  InpStartHour = 8;                 // Start Hour
input int                  InpStartMinute = 0;               // Start Minute
input int                  InpEndHour = 20;                  // End Hour
input int                  InpEndMinute = 0;                 // End Minute
input bool                 InpEnableSpreadFilter = true;     // Enable Spread Filter
input int                  InpMaxSpreadPoints = 30;          // Max Spread (Points)

input group "=== Misc Settings ==="
input ulong                InpMagicNumber = 777888;          // Magic Number
input string               InpTradeComment = "IchiMaster";   // Trade Comment
input int                  InpATRPeriod = 14;                // ATR Period (for SL/TP/Trailing)
input bool                 InpEnableDebugLogs = false;       // Enable Debug Logs

//--- Global Variables
CTrade         trade;
CSymbolInfo    symInfo;
CPositionInfo  posInfo;
CAccountInfo   accInfo;

int            h_ichimoku = INVALID_HANDLE;
int            h_atr = INVALID_HANDLE;
datetime       last_bar_time = 0;

//--- Arrays for Indicator Data
double         tenkan_buf[];
double         kijun_buf[];
double         senkou_a_buf[];
double         senkou_b_buf[];
double         atr_buf[];
MqlRates       rates[];

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   // Initialize Symbol
   if(!symInfo.Name(_Symbol))
     {
      Print("Error initializing symbol info!");
      return(INIT_FAILED);
     }
   symInfo.Refresh();

   // Initialize Trade Settings
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetMarginMode();
   trade.SetTypeFillingBySymbol(_Symbol);

   // Create Indicator Handles
   h_ichimoku = iIchimoku(_Symbol, InpSignalTimeframe, InpTenkanPeriod, InpKijunPeriod, InpSenkouPeriod);
   if(h_ichimoku == INVALID_HANDLE)
     {
      Print("Failed to create Ichimoku handle! Error: ", GetLastError());
      return(INIT_FAILED);
     }

   h_atr = iATR(_Symbol, InpSignalTimeframe, InpATRPeriod);
   if(h_atr == INVALID_HANDLE)
     {
      Print("Failed to create ATR handle! Error: ", GetLastError());
      return(INIT_FAILED);
     }

   // Initialize arrays as series (index 0 is current bar)
   ArraySetAsSeries(tenkan_buf, true);
   ArraySetAsSeries(kijun_buf, true);
   ArraySetAsSeries(senkou_a_buf, true);
   ArraySetAsSeries(senkou_b_buf, true);
   ArraySetAsSeries(atr_buf, true);
   ArraySetAsSeries(rates, true);

   Print("Ichimoku Master EA Successfully Initialized.");
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(h_ichimoku != INVALID_HANDLE) IndicatorRelease(h_ichimoku);
   if(h_atr != INVALID_HANDLE) IndicatorRelease(h_atr);
   Print("Ichimoku Master EA Deinitialized.");
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   symInfo.RefreshRates();

   // Handle Stop Loss trailing and break-even every tick
   ManageBreakEven();
   ManageTrailingStop();

   // Process Strategy Only on New Bar
   if(IsNewBar(InpSignalTimeframe))
     {
      // 1. Data Validation & Updates
      if(!UpdateData()) return;

      // 2. Position Limit & Session Validation
      if(CountOpenPositions() >= InpMaxOpenPositions || (InpOnePositionPerSymbol && HasPositionOnSymbol()))
         return;

      if(InpEnableTradingHours && !IsTradingSessionActive())
         return;

      if(InpEnableSpreadFilter && GetSpreadPoints() > InpMaxSpreadPoints)
        {
         if(InpEnableDebugLogs) Print("Spread too high! Current: ", GetSpreadPoints(), " Max: ", InpMaxSpreadPoints);
         return;
        }

      // 3. Evaluate Signals
      int signal = EvaluateSignals();

      // 4. Execute Trades
      if(signal == 1 && InpEnableBuy)
         ExecuteTrade(ORDER_TYPE_BUY);
      else if(signal == -1 && InpEnableSell)
         ExecuteTrade(ORDER_TYPE_SELL);
     }
  }

//+------------------------------------------------------------------+
//| New Bar Detection                                                |
//+------------------------------------------------------------------+
bool IsNewBar(ENUM_TIMEFRAMES tf)
  {
   datetime time[];
   if(CopyTime(_Symbol, tf, 0, 1, time) <= 0) return false;

   if(time[0] != last_bar_time)
     {
      if(last_bar_time != 0) 
        {
         last_bar_time = time[0];
         return true;
        }
      last_bar_time = time[0];
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Update Indicator & Price Data Arrays                             |
//+------------------------------------------------------------------+
bool UpdateData()
  {
   if(CopyBuffer(h_ichimoku, 0, 0, 3, tenkan_buf) <= 0) return false;
   if(CopyBuffer(h_ichimoku, 1, 0, 3, kijun_buf) <= 0) return false;
   if(CopyBuffer(h_ichimoku, 2, 0, 3, senkou_a_buf) <= 0) return false;
   if(CopyBuffer(h_ichimoku, 3, 0, 3, senkou_b_buf) <= 0) return false;
   if(CopyBuffer(h_atr, 0, 0, 3, atr_buf) <= 0) return false;
   if(CopyRates(_Symbol, InpSignalTimeframe, 0, InpSwingLookback + 5, rates) <= 0) return false;
   return true;
  }

//+------------------------------------------------------------------+
//| Evaluate Buy/Sell Signals                                        |
//+------------------------------------------------------------------+
int EvaluateSignals()
  {
   // Index 1 = Last closed candle. Index 2 = Previous closed candle.
   double close1 = rates[1].close;
   double close2 = rates[2].close;
   double open1 = rates[1].open;
   double high1 = rates[1].high;
   double low1 = rates[1].low;

   double cloudTop1 = MathMax(senkou_a_buf[1], senkou_b_buf[1]);
   double cloudBot1 = MathMin(senkou_a_buf[1], senkou_b_buf[1]);
   double cloudTop2 = MathMax(senkou_a_buf[2], senkou_b_buf[2]);
   double cloudBot2 = MathMin(senkou_a_buf[2], senkou_b_buf[2]);

   bool isBuyBreakout = false, isSellBreakout = false;
   bool isBuyBounce = false, isSellBounce = false;

   // --- Breakout Logic ---
   if(InpStrategy == STRATEGY_BREAKOUT || InpStrategy == STRATEGY_BOTH)
     {
      // Bullish Breakout: Prev close was inside/below cloud, current close is above
      if(close2 <= cloudTop2 && close1 > cloudTop1)
         isBuyBreakout = true;

      // Bearish Breakout: Prev close was inside/above cloud, current close is below
      if(close2 >= cloudBot2 && close1 < cloudBot1)
         isSellBreakout = true;
     }

   // --- Bounce Logic ---
   if(InpStrategy == STRATEGY_BOUNCE || InpStrategy == STRATEGY_BOTH)
     {
      double maxPenetration = InpBounceMaxPenetration * symInfo.Point();

      // Bullish Bounce: Rejects upper boundary of cloud
      // Touches or penetrates slightly, but doesn't go below bottom, closes above top
      if(low1 <= cloudTop1 && low1 >= (cloudTop1 - maxPenetration) && close1 > cloudTop1 && open1 > cloudBot1)
         isBuyBounce = true;

      // Bearish Bounce: Rejects lower boundary of cloud
      // Touches or penetrates slightly, but doesn't go above top, closes below bottom
      if(high1 >= cloudBot1 && high1 <= (cloudBot1 + maxPenetration) && close1 < cloudBot1 && open1 < cloudTop1)
         isSellBounce = true;
     }

   // Base Signals
   bool rawBuySignal = isBuyBreakout || isBuyBounce;
   bool rawSellSignal = isSellBreakout || isSellBounce;

   if(!rawBuySignal && !rawSellSignal) return 0;

   // --- Apply Trend Filters ---
   if(rawBuySignal)
     {
      if(InpFilterTenkanKijun && tenkan_buf[1] <= kijun_buf[1]) return 0;
      if(InpFilterPriceKijun && close1 <= kijun_buf[1]) return 0;
      if(InpFilterCloudTrend && !IsFutureCloudBullish()) return 0;
      if(InpFilterChikou && !IsChikouBullish()) return 0;
      
      if(InpEnableDebugLogs) Print("Valid BUY Signal generated.");
      return 1;
     }

   if(rawSellSignal)
     {
      if(InpFilterTenkanKijun && tenkan_buf[1] >= kijun_buf[1]) return 0;
      if(InpFilterPriceKijun && close1 >= kijun_buf[1]) return 0;
      if(InpFilterCloudTrend && !IsFutureCloudBearish()) return 0;
      if(InpFilterChikou && !IsChikouBearish()) return 0;
      
      if(InpEnableDebugLogs) Print("Valid SELL Signal generated.");
      return -1;
     }

   return 0;
  }

//+------------------------------------------------------------------+
//| Future Cloud Checking Functions (Handling Displacement)          |
//+------------------------------------------------------------------+
bool IsFutureCloudBullish()
  {
   // In MT5, CopyBuffer with negative shift reads values plotted in the future
   double fut_senkouA[], fut_senkouB[];
   if(CopyBuffer(h_ichimoku, 2, -InpDisplacement, 1, fut_senkouA) > 0 &&
      CopyBuffer(h_ichimoku, 3, -InpDisplacement, 1, fut_senkouB) > 0)
     {
      return fut_senkouA[0] > fut_senkouB[0];
     }
   return false;
  }

bool IsFutureCloudBearish()
  {
   double fut_senkouA[], fut_senkouB[];
   if(CopyBuffer(h_ichimoku, 2, -InpDisplacement, 1, fut_senkouA) > 0 &&
      CopyBuffer(h_ichimoku, 3, -InpDisplacement, 1, fut_senkouB) > 0)
     {
      return fut_senkouA[0] < fut_senkouB[0];
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Chikou Span Checking Functions                                   |
//+------------------------------------------------------------------+
bool IsChikouBullish()
  {
   // Chikou is Current Close plotted InpDisplacement bars back.
   // To be bullish, current Close[1] must be higher than the Close[1 + InpDisplacement]
   int idx = 1 + InpDisplacement;
   if(idx < ArraySize(rates))
      return rates[1].close > rates[idx].close;
   return false;
  }

bool IsChikouBearish()
  {
   int idx = 1 + InpDisplacement;
   if(idx < ArraySize(rates))
      return rates[1].close < rates[idx].close;
   return false;
  }

//+------------------------------------------------------------------+
//| Execute Trade                                                    |
//+------------------------------------------------------------------+
void ExecuteTrade(ENUM_ORDER_TYPE type)
  {
   double entryPrice = (type == ORDER_TYPE_BUY) ? symInfo.Ask() : symInfo.Bid();
   
   // 1. Calculate Stop Loss
   double slPrice = CalculateStopLoss(type, entryPrice);
   
   // Validate Stop Level
   double stoplevel = symInfo.StopsLevel() * symInfo.Point();
   if(MathAbs(entryPrice - slPrice) < stoplevel)
     {
      slPrice = (type == ORDER_TYPE_BUY) ? entryPrice - stoplevel : entryPrice + stoplevel;
     }

   // 2. Calculate Lot Size
   double slDistancePoints = MathAbs(entryPrice - slPrice) / symInfo.Point();
   double volume = CalculateLotSize(slDistancePoints);

   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   if(volume < minLot || volume > maxLot)
     {
      if(InpEnableDebugLogs) Print("Invalid lot size calculated: ", volume);
      return;
     }

   // 3. Calculate Take Profit
   double tpPrice = CalculateTakeProfit(type, entryPrice, slDistancePoints);

   // Normalize Prices
   slPrice = symInfo.NormalizePrice(slPrice);
   tpPrice = symInfo.NormalizePrice(tpPrice);
   entryPrice = symInfo.NormalizePrice(entryPrice); // informative

   // 4. Send Order
   if(type == ORDER_TYPE_BUY)
     {
      if(trade.Buy(volume, _Symbol, entryPrice, slPrice, tpPrice, InpTradeComment))
        {
         if(InpEnableDebugLogs) Print("BUY executed. Vol: ", volume, " SL: ", slPrice, " TP: ", tpPrice);
        }
      else
         Print("BUY Error: ", trade.ResultRetcode(), " - ", trade.ResultRetcodeDescription());
     }
   else
     {
      if(trade.Sell(volume, _Symbol, entryPrice, slPrice, tpPrice, InpTradeComment))
        {
         if(InpEnableDebugLogs) Print("SELL executed. Vol: ", volume, " SL: ", slPrice, " TP: ", tpPrice);
        }
      else
         Print("SELL Error: ", trade.ResultRetcode(), " - ", trade.ResultRetcodeDescription());
     }
  }

//+------------------------------------------------------------------+
//| Calculate Stop Loss Location                                     |
//+------------------------------------------------------------------+
double CalculateStopLoss(ENUM_ORDER_TYPE type, double entryPrice)
  {
   double sl = 0.0;
   double buffer = InpSLBufferPoints * symInfo.Point();

   if(type == ORDER_TYPE_BUY)
     {
      switch(InpSLMode)
        {
         case SL_FIXED_POINTS:
            sl = entryPrice - (InpSLPoints * symInfo.Point());
            break;
         case SL_ATR:
            sl = entryPrice - (atr_buf[1] * InpSLATRMult);
            break;
         case SL_KIJUN:
            sl = kijun_buf[1] - buffer;
            break;
         case SL_CLOUD_EXTREME:
            sl = MathMin(senkou_a_buf[1], senkou_b_buf[1]) - buffer;
            break;
         case SL_SWING:
            sl = GetSwingLow(1, InpSwingLookback) - buffer;
            break;
        }
     }
   else
     {
      switch(InpSLMode)
        {
         case SL_FIXED_POINTS:
            sl = entryPrice + (InpSLPoints * symInfo.Point());
            break;
         case SL_ATR:
            sl = entryPrice + (atr_buf[1] * InpSLATRMult);
            break;
         case SL_KIJUN:
            sl = kijun_buf[1] + buffer;
            break;
         case SL_CLOUD_EXTREME:
            sl = MathMax(senkou_a_buf[1], senkou_b_buf[1]) + buffer;
            break;
         case SL_SWING:
            sl = GetSwingHigh(1, InpSwingLookback) + buffer;
            break;
        }
     }
   return sl;
  }

//+------------------------------------------------------------------+
//| Calculate Take Profit Location                                   |
//+------------------------------------------------------------------+
double CalculateTakeProfit(ENUM_ORDER_TYPE type, double entryPrice, double slDistancePoints)
  {
   double tp = 0.0;
   
   if(type == ORDER_TYPE_BUY)
     {
      switch(InpTPMode)
        {
         case TP_FIXED_RR:
            tp = entryPrice + (slDistancePoints * symInfo.Point() * InpTPRiskReward);
            break;
         case TP_FIXED_POINTS:
            tp = entryPrice + (InpTPPoints * symInfo.Point());
            break;
         case TP_ATR:
            tp = entryPrice + (atr_buf[1] * InpTPATRMult);
            break;
        }
     }
   else
     {
      switch(InpTPMode)
        {
         case TP_FIXED_RR:
            tp = entryPrice - (slDistancePoints * symInfo.Point() * InpTPRiskReward);
            break;
         case TP_FIXED_POINTS:
            tp = entryPrice - (InpTPPoints * symInfo.Point());
            break;
         case TP_ATR:
            tp = entryPrice - (atr_buf[1] * InpTPATRMult);
            break;
        }
     }
   return tp;
  }

//+------------------------------------------------------------------+
//| Calculate Lot Size depending on Risk Management Settings         |
//+------------------------------------------------------------------+
double CalculateLotSize(double slDistancePoints)
  {
   if(InpLotMode == LOT_FIXED)
      return NormalizeVolume(InpFixedLot);

   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   if(slDistancePoints <= 0) return minLot;

   double riskMoney = accInfo.Balance() * (InpRiskPercent / 100.0);
   double pointValue = symInfo.TickValue() * (symInfo.Point() / symInfo.TickSize());
   double riskPerLot = slDistancePoints * pointValue;
   
   if(riskPerLot <= 0) return minLot;
   
   double calculatedLot = riskMoney / riskPerLot;
   return NormalizeVolume(calculatedLot);
  }

//+------------------------------------------------------------------+
//| Position Management - Break Even                                 |
//+------------------------------------------------------------------+
void ManageBreakEven()
  {
   if(!InpEnableBreakEven) return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(posInfo.SelectByIndex(i))
        {
         if(posInfo.Symbol() == _Symbol && posInfo.Magic() == InpMagicNumber)
           {
            double entry = posInfo.PriceOpen();
            double sl = posInfo.StopLoss();
            double currentPrice = posInfo.PriceCurrent();
            double stoplevel = symInfo.StopsLevel() * symInfo.Point();
            double beTrigger = InpBreakEvenTrigger * symInfo.Point();
            double beBuffer = InpBreakEvenBuffer * symInfo.Point();

            if(posInfo.PositionType() == POSITION_TYPE_BUY)
              {
               if(currentPrice - entry >= beTrigger && sl < entry)
                 {
                  double newSL = symInfo.NormalizePrice(entry + beBuffer);
                  if(currentPrice - newSL > stoplevel && newSL > sl)
                     trade.PositionModify(posInfo.Ticket(), newSL, posInfo.TakeProfit());
                 }
              }
            else if(posInfo.PositionType() == POSITION_TYPE_SELL)
              {
               if(entry - currentPrice >= beTrigger && (sl > entry || sl == 0.0))
                 {
                  double newSL = symInfo.NormalizePrice(entry - beBuffer);
                  if(newSL - currentPrice > stoplevel && (newSL < sl || sl == 0.0))
                     trade.PositionModify(posInfo.Ticket(), newSL, posInfo.TakeProfit());
                 }
              }
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Position Management - Trailing Stop                              |
//+------------------------------------------------------------------+
void ManageTrailingStop()
  {
   if(InpTrailingMode == TRAIL_OFF) return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(posInfo.SelectByIndex(i))
        {
         if(posInfo.Symbol() == _Symbol && posInfo.Magic() == InpMagicNumber)
           {
            double sl = posInfo.StopLoss();
            double currentPrice = posInfo.PriceCurrent();
            double newSL = sl;
            double stoplevel = symInfo.StopsLevel() * symInfo.Point();

            // Calculate potential New SL based on Mode
            if(posInfo.PositionType() == POSITION_TYPE_BUY)
              {
               if(InpTrailingMode == TRAIL_POINTS)
                  newSL = currentPrice - (InpTrailingPoints * symInfo.Point());
               else if(InpTrailingMode == TRAIL_ATR)
                  newSL = currentPrice - (atr_buf[0] * InpTrailingATRMult);
               else if(InpTrailingMode == TRAIL_KIJUN)
                  newSL = kijun_buf[1];

               newSL = symInfo.NormalizePrice(newSL);

               if(newSL > sl && currentPrice - newSL > stoplevel)
                  trade.PositionModify(posInfo.Ticket(), newSL, posInfo.TakeProfit());
              }
            else if(posInfo.PositionType() == POSITION_TYPE_SELL)
              {
               if(InpTrailingMode == TRAIL_POINTS)
                  newSL = currentPrice + (InpTrailingPoints * symInfo.Point());
               else if(InpTrailingMode == TRAIL_ATR)
                  newSL = currentPrice + (atr_buf[0] * InpTrailingATRMult);
               else if(InpTrailingMode == TRAIL_KIJUN)
                  newSL = kijun_buf[1];

               newSL = symInfo.NormalizePrice(newSL);

               if((newSL < sl || sl == 0.0) && newSL - currentPrice > stoplevel)
                  trade.PositionModify(posInfo.Ticket(), newSL, posInfo.TakeProfit());
              }
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Helpers                                                          |
//+------------------------------------------------------------------+
int CountOpenPositions()
  {
   int count = 0;
   for(int i = 0; i < PositionsTotal(); i++)
     {
      if(posInfo.SelectByIndex(i))
         if(posInfo.Magic() == InpMagicNumber)
            count++;
     }
   return count;
  }

bool HasPositionOnSymbol()
  {
   for(int i = 0; i < PositionsTotal(); i++)
     {
      if(posInfo.SelectByIndex(i))
         if(posInfo.Symbol() == _Symbol && posInfo.Magic() == InpMagicNumber)
            return true;
     }
   return false;
  }

bool IsTradingSessionActive()
  {
   MqlDateTime dt;
   TimeCurrent(dt);
   int currentMin = dt.hour * 60 + dt.min;
   int startMin = InpStartHour * 60 + InpStartMinute;
   int endMin = InpEndHour * 60 + InpEndMinute;

   if(startMin < endMin)
      return (currentMin >= startMin && currentMin < endMin);
   else // crosses midnight
      return (currentMin >= startMin || currentMin < endMin);
  }

int GetSpreadPoints()
  {
   return (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
  }

double NormalizeVolume(double vol)
  {
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   
   if(stepLot <= 0) return minLot; // Safeguard menghindari division by zero
   
   double cleanVol = MathFloor(vol / stepLot) * stepLot;
   if(cleanVol < minLot) cleanVol = minLot;
   if(cleanVol > maxLot) cleanVol = maxLot;
   return cleanVol;
  }
  
double GetSwingHigh(int startIdx, int count)
  {
   double high = 0;
   for(int i = startIdx; i < startIdx + count && i < ArraySize(rates); i++)
     {
      if(rates[i].high > high) high = rates[i].high;
     }
   return high;
  }

double GetSwingLow(int startIdx, int count)
  {
   double low = 9999999;
   for(int i = startIdx; i < startIdx + count && i < ArraySize(rates); i++)
     {
      if(rates[i].low < low) low = rates[i].low;
     }
   return low;
  }
//+------------------------------------------------------------------+