//+------------------------------------------------------------------+
//|                               Stochastic_EMA_Trend_Reversal.mq5 |
//|                                                                  |
//|                    Strict MQL5 Implementation - 0 Errors/Warnings|
//+------------------------------------------------------------------+
#property copyright "Algorithmic Trader & MQL5 Developer"
#property link      ""
#property version   "1.00"
#property description "Stochastic + EMA Trend Reversal"

#include <Trade\Trade.mqh>

//--- Input Parameters
input group "=== Trend Filter (EMA) ==="
input int    EMA_Period = 200;            // EMA Period

input group "=== Stochastic Oscillator ==="
input int    Stoch_K = 14;                // %K Period
input int    Stoch_D = 3;                 // %D Period
input int    Stoch_Slowing = 3;           // Slowing
input double Stoch_Overbought = 80.0;     // Overbought Level
input double Stoch_Oversold = 20.0;       // Oversold Level

input group "=== Stop Loss (ATR) ==="
input int    ATR_Period = 14;             // ATR Period
input double ATR_SL_Multiplier = 2.0;     // ATR SL Multiplier

input group "=== Risk Management ==="
input double Risk_Percent = 1.0;          // Risk Percent per Trade
input double Risk_Reward = 2.0;           // Risk/Reward Ratio
input int    Max_Spread_Points = 30;      // Max Spread (Points)

input group "=== EA Settings ==="
input ulong  Magic_Number = 20260917;     // Magic Number

//--- Global Variables
CTrade         trade;
int            handle_ema;
int            handle_stoch;
int            handle_atr;
datetime       m_last_bar_time = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   //--- Set Trade Module
   trade.SetExpertMagicNumber(Magic_Number);
   
   //--- Initialize Indicators
   handle_ema = iMA(_Symbol, _Period, EMA_Period, 0, MODE_EMA, PRICE_CLOSE);
   if(handle_ema == INVALID_HANDLE)
     {
      Print("Error creating EMA indicator handle!");
      return(INIT_FAILED);
     }
     
   handle_stoch = iStochastic(_Symbol, _Period, Stoch_K, Stoch_D, Stoch_Slowing, MODE_SMA, STO_LOWHIGH);
   if(handle_stoch == INVALID_HANDLE)
     {
      Print("Error creating Stochastic indicator handle!");
      return(INIT_FAILED);
     }
     
   handle_atr = iATR(_Symbol, _Period, ATR_Period);
   if(handle_atr == INVALID_HANDLE)
     {
      Print("Error creating ATR indicator handle!");
      return(INIT_FAILED);
     }

   //--- Initialize new bar detection
   m_last_bar_time = iTime(_Symbol, _Period, 0);

   Print("Stochastic + EMA Trend Reversal EA Initialized.");
   
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   //--- Release Indicator Handles
   if(handle_ema != INVALID_HANDLE) IndicatorRelease(handle_ema);
   if(handle_stoch != INVALID_HANDLE) IndicatorRelease(handle_stoch);
   if(handle_atr != INVALID_HANDLE) IndicatorRelease(handle_atr);
   
   Print("Stochastic + EMA Trend Reversal EA Deinitialized.");
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   //--- Evaluate only once per new bar
   if(!IsNewBar()) return;

   //--- Check for active positions
   if(HasOpenPosition()) return;

   //--- Check Spread
   if(!CheckSpread())
     {
      Print("Spread is too high. Waiting for next opportunity.");
      return;
     }

   //--- Check Buy Signal
   if(CheckBuySignal())
     {
      Print("BUY Signal Detected.");
      OpenBuy();
      return; // Ensure only one action
     }

   //--- Check Sell Signal
   if(CheckSellSignal())
     {
      Print("SELL Signal Detected.");
      OpenSell();
      return;
     }
  }

//+------------------------------------------------------------------+
//| Function: Check New Bar                                          |
//+------------------------------------------------------------------+
bool IsNewBar()
  {
   datetime current_time = iTime(_Symbol, _Period, 0);
   if(current_time != m_last_bar_time)
     {
      m_last_bar_time = current_time;
      return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Function: Check Open Positions for this EA                       |
//+------------------------------------------------------------------+
bool HasOpenPosition()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
        {
         string pos_symbol = PositionGetString(POSITION_SYMBOL);
         ulong  pos_magic  = PositionGetInteger(POSITION_MAGIC);
         
         if(pos_symbol == _Symbol && pos_magic == Magic_Number)
           {
            return true;
           }
        }
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Function: Check Spread                                           |
//+------------------------------------------------------------------+
bool CheckSpread()
  {
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   
   if(point == 0.0) return false;
   
   double spread_points = (ask - bid) / point;
   
   if(spread_points > Max_Spread_Points) return false;
   
   return true;
  }

//+------------------------------------------------------------------+
//| Function: Check Buy Signal                                       |
//+------------------------------------------------------------------+
bool CheckBuySignal()
  {
   MqlRates rates[];
   if(CopyRates(_Symbol, _Period, 1, 2, rates) != 2) return false;
   // rates[0] = shift 2, rates[1] = shift 1

   double ema[];
   if(CopyBuffer(handle_ema, 0, 1, 2, ema) != 2) return false;
   // ema[0] = shift 2, ema[1] = shift 1

   double stoch_k[], stoch_d[];
   if(CopyBuffer(handle_stoch, 0, 1, 2, stoch_k) != 2) return false;
   if(CopyBuffer(handle_stoch, 1, 1, 2, stoch_d) != 2) return false;
   // [0] = shift 2, [1] = shift 1

   // 1. Bullish Trend Filter
   if(rates[1].close <= ema[1]) return false;

   // 2. Stochastic was oversold (shift 2)
   if(stoch_k[0] > Stoch_Oversold) return false;

   // 3. Stochastic crossover configuration before signal (shift 2)
   if(stoch_k[0] > stoch_d[0]) return false;

   // 4. Stochastic confirmed bullish crossover (shift 1)
   if(stoch_k[1] <= stoch_d[1]) return false;

   // 5. Stochastic exiting oversold area (shift 1)
   if(stoch_k[1] <= Stoch_Oversold) return false;

   // 6. Bullish signal candle
   if(rates[1].close <= rates[1].open) return false;

   return true;
  }

//+------------------------------------------------------------------+
//| Function: Check Sell Signal                                      |
//+------------------------------------------------------------------+
bool CheckSellSignal()
  {
   MqlRates rates[];
   if(CopyRates(_Symbol, _Period, 1, 2, rates) != 2) return false;
   // rates[0] = shift 2, rates[1] = shift 1

   double ema[];
   if(CopyBuffer(handle_ema, 0, 1, 2, ema) != 2) return false;
   // ema[0] = shift 2, ema[1] = shift 1

   double stoch_k[], stoch_d[];
   if(CopyBuffer(handle_stoch, 0, 1, 2, stoch_k) != 2) return false;
   if(CopyBuffer(handle_stoch, 1, 1, 2, stoch_d) != 2) return false;
   // [0] = shift 2, [1] = shift 1

   // 1. Bearish Trend Filter
   if(rates[1].close >= ema[1]) return false;

   // 2. Stochastic was overbought (shift 2)
   if(stoch_k[0] < Stoch_Overbought) return false;

   // 3. Stochastic crossover configuration before signal (shift 2)
   if(stoch_k[0] < stoch_d[0]) return false;

   // 4. Stochastic confirmed bearish crossover (shift 1)
   if(stoch_k[1] >= stoch_d[1]) return false;

   // 5. Stochastic exiting overbought area (shift 1)
   if(stoch_k[1] >= Stoch_Overbought) return false;

   // 6. Bearish signal candle
   if(rates[1].close >= rates[1].open) return false;

   return true;
  }

//+------------------------------------------------------------------+
//| Function: Execute Buy Order                                      |
//+------------------------------------------------------------------+
void OpenBuy()
  {
   double atr[];
   if(CopyBuffer(handle_atr, 0, 1, 1, atr) != 1)
     {
      Print("Failed to copy ATR data.");
      return;
     }

   double entry = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   
   double sl = entry - (atr[0] * ATR_SL_Multiplier);
   double risk = entry - sl;
   double tp = entry + (risk * Risk_Reward);

   entry = NormalizeDouble(entry, digits);
   sl    = NormalizeDouble(sl, digits);
   tp    = NormalizeDouble(tp, digits);

   if(!ValidateStops(ORDER_TYPE_BUY, entry, sl, tp))
     {
      Print("Buy Error: Stops violate broker minimum distance requirements.");
      return;
     }

   double lot = CalculateLotSize(MathAbs(entry - sl));
   if(lot <= 0.0)
     {
      Print("Buy Error: Calculated lot size is invalid.");
      return;
     }

   if(!CheckMargin(ORDER_TYPE_BUY, lot, entry))
     {
      Print("Buy Error: Insufficient free margin.");
      return;
     }

   if(trade.Buy(lot, _Symbol, entry, sl, tp, "Stoch EMA Buy"))
     {
      PrintFormat("BUY executed -> Lot: %.2f | Entry: %f | SL: %f | TP: %f", lot, entry, sl, tp);
     }
   else
     {
      PrintFormat("BUY failed -> Retcode: %d | Desc: %s | Entry: %f | SL: %f | TP: %f",
                  trade.ResultRetcode(), trade.ResultRetcodeDescription(), entry, sl, tp);
     }
  }

//+------------------------------------------------------------------+
//| Function: Execute Sell Order                                     |
//+------------------------------------------------------------------+
void OpenSell()
  {
   double atr[];
   if(CopyBuffer(handle_atr, 0, 1, 1, atr) != 1)
     {
      Print("Failed to copy ATR data.");
      return;
     }

   double entry = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   
   double sl = entry + (atr[0] * ATR_SL_Multiplier);
   double risk = sl - entry;
   double tp = entry - (risk * Risk_Reward);

   entry = NormalizeDouble(entry, digits);
   sl    = NormalizeDouble(sl, digits);
   tp    = NormalizeDouble(tp, digits);

   if(!ValidateStops(ORDER_TYPE_SELL, entry, sl, tp))
     {
      Print("Sell Error: Stops violate broker minimum distance requirements.");
      return;
     }

   double lot = CalculateLotSize(MathAbs(entry - sl));
   if(lot <= 0.0)
     {
      Print("Sell Error: Calculated lot size is invalid.");
      return;
     }

   if(!CheckMargin(ORDER_TYPE_SELL, lot, entry))
     {
      Print("Sell Error: Insufficient free margin.");
      return;
     }

   if(trade.Sell(lot, _Symbol, entry, sl, tp, "Stoch EMA Sell"))
     {
      PrintFormat("SELL executed -> Lot: %.2f | Entry: %f | SL: %f | TP: %f", lot, entry, sl, tp);
     }
   else
     {
      PrintFormat("SELL failed -> Retcode: %d | Desc: %s | Entry: %f | SL: %f | TP: %f",
                  trade.ResultRetcode(), trade.ResultRetcodeDescription(), entry, sl, tp);
     }
  }

//+------------------------------------------------------------------+
//| Function: Validate Stop Loss & Take Profit Levels                |
//+------------------------------------------------------------------+
bool ValidateStops(ENUM_ORDER_TYPE type, double entry, double sl, double tp)
  {
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double stop_level = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * point;
   double freeze_level = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL) * point;
   
   double min_dist = MathMax(stop_level, freeze_level);
   
   if(type == ORDER_TYPE_BUY)
     {
      if((entry - sl) < min_dist) return false;
      if((tp - entry) < min_dist) return false;
     }
   else if(type == ORDER_TYPE_SELL)
     {
      if((sl - entry) < min_dist) return false;
      if((entry - tp) < min_dist) return false;
     }
     
   return true;
  }

//+------------------------------------------------------------------+
//| Function: Calculate Risk-Based Lot Size                          |
//+------------------------------------------------------------------+
double CalculateLotSize(double sl_distance)
  {
   if(Risk_Percent <= 0.0 || sl_distance <= 0.0) return 0.0;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double risk_money = equity * (Risk_Percent / 100.0);

   double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);

   if(tick_size <= 0.0 || tick_value <= 0.0) return 0.0;

   double risk_ticks = sl_distance / tick_size;
   double loss_per_lot = risk_ticks * tick_value;

   if(loss_per_lot <= 0.0) return 0.0;

   double lot = risk_money / loss_per_lot;

   // Normalize Volume
   double min_vol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double max_vol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step_vol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   
   if(step_vol <= 0.0) return 0.0;
   
   // Determine precision digits based on volume step
   int vol_digits = 0;
   double temp_step = step_vol;
   while(temp_step < 1.0 && vol_digits < 8)
     {
      temp_step *= 10.0;
      vol_digits++;
     }

   lot = NormalizeDouble(MathFloor(lot / step_vol) * step_vol, vol_digits);

   if(lot < min_vol) lot = min_vol;
   if(lot > max_vol) lot = max_vol;

   return lot;
  }

//+------------------------------------------------------------------+
//| Function: Check Margin Requirements                              |
//+------------------------------------------------------------------+
bool CheckMargin(ENUM_ORDER_TYPE type, double lot, double price)
  {
   double margin = 0.0;
   if(!OrderCalcMargin(type, _Symbol, lot, price, margin))
     {
      Print("Error calculating required margin.");
      return false;
     }
     
   if(AccountInfoDouble(ACCOUNT_MARGIN_FREE) < margin)
     {
      return false;
     }
     
   return true;
  }
//+------------------------------------------------------------------+