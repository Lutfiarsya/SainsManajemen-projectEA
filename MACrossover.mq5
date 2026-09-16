//+------------------------------------------------------------------+
//|                                                  MACrossover.mq5 |
//|                                       Expert Algorithmic Trader  |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Expert Algorithmic Trader"
#property link      ""
#property version   "1.00"

#include <Trade\Trade.mqh>

//--- ENUMS ---
enum ENUM_RISK_TYPE
  {
   RISK_PERCENT = 0, // Risk % of Account Balance
   RISK_MONEY   = 1  // Fixed Monetary Risk
  };

enum ENUM_REVERSAL_MODE
  {
   REVERSAL_ON  = 0, // Close existing position and reverse
   REVERSAL_OFF = 1  // Close existing position without opening a new one
  };

//--- INPUT PARAMETERS ---
sinput string              GUI_General     = "=== General Settings ===";
input ulong                InpMagicNumber  = 123456;         // Magic Number

sinput string              GUI_MA          = "=== Moving Average Settings ===";
input ENUM_TIMEFRAMES      InpTimeframe    = PERIOD_CURRENT; // Timeframe for MA
input int                  InpFastMA       = 10;             // Fast MA Period
input int                  InpSlowMA       = 20;             // Slow MA Period
input ENUM_MA_METHOD       InpMAMethod     = MODE_SMA;       // MA Method
input ENUM_APPLIED_PRICE   InpAppliedPrice = PRICE_CLOSE;    // Applied Price

sinput string              GUI_Logic       = "=== Trading Logic ===";
input ENUM_REVERSAL_MODE   InpReversal     = REVERSAL_ON;    // Opposite Signal Action

sinput string              GUI_Risk        = "=== Risk & Money Management ===";
input ENUM_RISK_TYPE       InpRiskType     = RISK_PERCENT;   // Risk Calculation Method
input double               InpRiskValue    = 1.0;            // Risk Value (% or Money Amount)
input int                  InpStopLoss     = 500;            // Stop Loss (in Points)
input int                  InpTakeProfit   = 1000;           // Take Profit (in Points, 0 = disabled)
input ulong                InpSlippage     = 30;             // Max Slippage (in Points)

//--- GLOBAL VARIABLES ---
CTrade         trade;
int            handleFastMA = INVALID_HANDLE;
int            handleSlowMA = INVALID_HANDLE;
datetime       lastExecutionBarTime = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   // Validate inputs
   if(InpFastMA <= 0 || InpSlowMA <= 0)
     {
      Print("Error: Moving Average periods must be greater than zero.");
      return(INIT_PARAMETERS_INCORRECT);
     }

   if(InpFastMA >= InpSlowMA)
     {
      Print("Warning: Fast MA period should ideally be smaller than Slow MA period.");
     }

   if(InpStopLoss <= 0)
     {
      Print("Error: Stop Loss in points must be greater than zero for risk-based lot calculation.");
      return(INIT_PARAMETERS_INCORRECT);
     }

   // Configure trade execution object
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippage);

   // Initialize Indicator Handles
   handleFastMA = iMA(_Symbol, InpTimeframe, InpFastMA, 0, InpMAMethod, InpAppliedPrice);
   handleSlowMA = iMA(_Symbol, InpTimeframe, InpSlowMA, 0, InpMAMethod, InpAppliedPrice);

   if(handleFastMA == INVALID_HANDLE || handleSlowMA == INVALID_HANDLE)
     {
      Print("Error initializing Moving Average handles.");
      return(INIT_FAILED);
     }

   Print("MA Crossover EA initialized successfully.");
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   // Release indicator handles to free memory
   if(handleFastMA != INVALID_HANDLE) IndicatorRelease(handleFastMA);
   if(handleSlowMA != INVALID_HANDLE) IndicatorRelease(handleSlowMA);
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   // Get time of the last completed candle (Bar 1)
   datetime barTime[];
   ArraySetAsSeries(barTime, true);
   if(CopyTime(_Symbol, InpTimeframe, 1, 1, barTime) <= 0)
      return;

   // Prevent multiple trades/evaluations on the same bar
   if(barTime[0] == lastExecutionBarTime)
      return;

   // Copy MA values for confirmed completed candles (Shift 1 & Shift 2)
   double fastMA[];
   double slowMA[];
   ArraySetAsSeries(fastMA, true);
   ArraySetAsSeries(slowMA, true);

   if(CopyBuffer(handleFastMA, 0, 0, 3, fastMA) < 3 ||
      CopyBuffer(handleSlowMA, 0, 0, 3, slowMA) < 3)
     {
      return; // Insufficient bar data loaded yet
     }

   // Detect Crossover signals on confirmed candles
   // fastMA[1] = Shift 1, fastMA[2] = Shift 2
   bool buy_signal  = (fastMA[1] > slowMA[1] && fastMA[2] <= slowMA[2]);
   bool sell_signal = (fastMA[1] < slowMA[1] && fastMA[2] >= slowMA[2]);

   if(!buy_signal && !sell_signal)
      return;

   // Restore state / Check server positions for this Symbol and Magic Number
   ENUM_POSITION_TYPE posType;
   ulong posTicket = 0;
   int totalPositions = GetOpenPosition(posType, posTicket);

   // --- BUY SIGNAL LOGIC ---
   if(buy_signal)
     {
      if(totalPositions > 0 && posType == POSITION_TYPE_SELL)
        {
         if(trade.PositionClose(posTicket))
           {
            Print("Closed SELL position on opposite Buy crossover signal.");
            lastExecutionBarTime = barTime[0];
            if(InpReversal == REVERSAL_ON)
              {
               OpenBuyPosition();
              }
           }
        }
      else if(totalPositions == 0)
        {
         OpenBuyPosition();
         lastExecutionBarTime = barTime[0];
        }
     }
   // --- SELL SIGNAL LOGIC ---
   else if(sell_signal)
     {
      if(totalPositions > 0 && posType == POSITION_TYPE_BUY)
        {
         if(trade.PositionClose(posTicket))
           {
            Print("Closed BUY position on opposite Sell crossover signal.");
            lastExecutionBarTime = barTime[0];
            if(InpReversal == REVERSAL_ON)
              {
               OpenSellPosition();
              }
           }
        }
      else if(totalPositions == 0)
        {
         OpenSellPosition();
         lastExecutionBarTime = barTime[0];
        }
     }
  }

//+------------------------------------------------------------------+
//| Execute Buy Position                                             |
//+------------------------------------------------------------------+
void OpenBuyPosition()
  {
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(ask <= 0) return;

   double sl = (InpStopLoss > 0) ? ask - (InpStopLoss * _Point) : 0.0;
   double tp = (InpTakeProfit > 0) ? ask + (InpTakeProfit * _Point) : 0.0;

   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   sl = NormalizeDouble(sl, digits);
   tp = NormalizeDouble(tp, digits);

   double lotSize = CalculateLotSize(InpStopLoss);

   if(trade.Buy(lotSize, _Symbol, ask, sl, tp, "MA Cross Buy"))
     {
      Print("BUY position opened successfully. Ticket: ", trade.ResultOrder(), " Lots: ", lotSize);
     }
   else
     {
      Print("BUY position failed. Code: ", trade.ResultRetcodeDescription());
     }
  }

//+------------------------------------------------------------------+
//| Execute Sell Position                                            |
//+------------------------------------------------------------------+
void OpenSellPosition()
  {
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(bid <= 0) return;

   double sl = (InpStopLoss > 0) ? bid + (InpStopLoss * _Point) : 0.0;
   double tp = (InpTakeProfit > 0) ? bid - (InpTakeProfit * _Point) : 0.0;

   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   sl = NormalizeDouble(sl, digits);
   tp = NormalizeDouble(tp, digits);

   double lotSize = CalculateLotSize(InpStopLoss);

   if(trade.Sell(lotSize, _Symbol, bid, sl, tp, "MA Cross Sell"))
     {
      Print("SELL position opened successfully. Ticket: ", trade.ResultOrder(), " Lots: ", lotSize);
     }
   else
     {
      Print("SELL position failed. Code: ", trade.ResultRetcodeDescription());
     }
  }

//+------------------------------------------------------------------+
//| Filter Open Positions by Magic Number & Symbol (State Recovery) |
//+------------------------------------------------------------------+
int GetOpenPosition(ENUM_POSITION_TYPE &type, ulong &ticket)
  {
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong posTicket = PositionGetTicket(i);
      if(posTicket > 0)
        {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
            PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
           {
            type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
            ticket = posTicket;
            count++;
           }
        }
     }
   return count;
  }

//+------------------------------------------------------------------+
//| Dynamic Lot Size Calculation based on Financial Risk & SL Points|
//+------------------------------------------------------------------+
double CalculateLotSize(double sl_points)
  {
   if(sl_points <= 0)
      return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double moneyRisk = 0.0;

   if(InpRiskType == RISK_PERCENT)
      moneyRisk = balance * (InpRiskValue / 100.0);
   else
      moneyRisk = InpRiskValue;

   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);

   if(tickSize <= 0 || tickValue <= 0 || _Point <= 0)
      return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   // Calculate loss per 1.0 standard lot
   double slDistance = sl_points * _Point;
   double slTicks = slDistance / tickSize;
   double riskPerLot = slTicks * tickValue;

   if(riskPerLot <= 0)
      return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   double rawLot = moneyRisk / riskPerLot;

   // Clamp volume to broker limits and steps
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   double normalizedLot = MathFloor(rawLot / stepLot) * stepLot;

   if(normalizedLot < minLot) normalizedLot = minLot;
   if(normalizedLot > maxLot) normalizedLot = maxLot;

   return NormalizeDouble(normalizedLot, 2);
  }
//+------------------------------------------------------------------+