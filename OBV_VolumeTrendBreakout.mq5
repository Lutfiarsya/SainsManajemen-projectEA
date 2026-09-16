//+------------------------------------------------------------------+
//|                                     OBV Volume Breakout Trend EA |
//|                                  Copyright 2026, Quantitative EA |
//|                                              https://www.mql5.com|
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Quantitative EA"
#property link      "https://www.mql5.com"
#property version   "1.00"
#property description "OBV Volume Breakout + EMA Trend Confirmation"

#include <Trade/Trade.mqh>

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                 |
//+------------------------------------------------------------------+
input group "--- Core Settings ---"
input ENUM_TIMEFRAMES InpTimeframe               = PERIOD_H1;  // Timeframe
input int             InpEMAPeriod               = 200;        // EMA Period
input int             InpOBVLookback             = 20;         // OBV Lookback
input int             InpATRPeriod               = 14;         // ATR Period
input double          InpATRMultiplier           = 2.0;        // ATR Stop Multiplier

input group "--- Risk & Trade Management ---"
input double          InpRiskPercent             = 1.0;        // Risk Percent (%)
input double          InpRiskReward              = 2.0;        // Risk/Reward Ratio
input double          InpOBVMinimumBreakout      = 0.0;        // Minimum OBV Breakout Distance
input int             InpPriceBreakoutBufferPoints = 0;        // Minimum Price Breakout Buffer (Points)
input int             InpMaxSpreadPoints         = 30;         // Maximum Spread (Points)
input ulong           InpMagicNumber             = 20260920;   // Magic Number

//+------------------------------------------------------------------+
//| GLOBAL VARIABLES                                                 |
//+------------------------------------------------------------------+
CTrade         trade;
int            handle_ema = INVALID_HANDLE;
int            handle_obv = INVALID_HANDLE;
int            handle_atr = INVALID_HANDLE;

//+------------------------------------------------------------------+
//| INITIALIZATION FUNCTION                                          |
//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetExpertMagicNumber(InpMagicNumber);
   
   // Initialize EMA Handle
   handle_ema = iMA(_Symbol, InpTimeframe, InpEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if(handle_ema == INVALID_HANDLE)
     {
      Print("Error: Failed to create EMA indicator handle.");
      return(INIT_FAILED);
     }
     
   // Initialize OBV Handle
   handle_obv = iOBV(_Symbol, InpTimeframe, VOLUME_TICK);
   if(handle_obv == INVALID_HANDLE)
     {
      Print("Error: Failed to create OBV indicator handle.");
      return(INIT_FAILED);
     }
     
   // Initialize ATR Handle
   handle_atr = iATR(_Symbol, InpTimeframe, InpATRPeriod);
   if(handle_atr == INVALID_HANDLE)
     {
      Print("Error: Failed to create ATR indicator handle.");
      return(INIT_FAILED);
     }
     
   Print("OBV Volume Breakout Trend EA Initialized Successfully.");
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| DEINITIALIZATION FUNCTION                                        |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(handle_ema != INVALID_HANDLE) IndicatorRelease(handle_ema);
   if(handle_obv != INVALID_HANDLE) IndicatorRelease(handle_obv);
   if(handle_atr != INVALID_HANDLE) IndicatorRelease(handle_atr);
   
   Print("OBV Volume Breakout Trend EA Deinitialized.");
  }

//+------------------------------------------------------------------+
//| NEW BAR DETECTION                                                |
//+------------------------------------------------------------------+
bool IsNewBar()
  {
   static datetime last_bar_time = 0;
   datetime current_bar_time = iTime(_Symbol, InpTimeframe, 0);
   
   if(current_bar_time == 0) return false;
   
   if(current_bar_time != last_bar_time)
     {
      last_bar_time = current_bar_time;
      return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//| OPEN POSITION CHECK                                              |
//+------------------------------------------------------------------+
bool HasOpenPosition()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
        {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
            PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
           {
            return true;
           }
        }
     }
   return false;
  }

//+------------------------------------------------------------------+
//| SPREAD CHECK                                                     |
//+------------------------------------------------------------------+
bool CheckSpread(double ask, double bid)
  {
   double spread_points = (ask - bid) / _Point;
   if(spread_points > InpMaxSpreadPoints)
     {
      PrintFormat("Trade rejected: Spread too high (%.1f > %d).", spread_points, InpMaxSpreadPoints);
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| LOT SIZE CALCULATION                                             |
//+------------------------------------------------------------------+
double CalculateLotSize(double risk_distance)
  {
   if(risk_distance <= 0) return 0.0;
   
   double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   
   if(tick_size == 0.0 || tick_value == 0.0)
     {
      Print("Error: Invalid tick size or tick value.");
      return 0.0;
     }
     
   double risk_money = AccountInfoDouble(ACCOUNT_EQUITY) * (InpRiskPercent / 100.0);
   double loss_ticks = risk_distance / tick_size;
   double loss_per_lot = loss_ticks * tick_value;
   
   if(loss_per_lot == 0.0) return 0.0;
   
   double volume = risk_money / loss_per_lot;
   
   double min_vol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double max_vol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step_vol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   
   volume = MathFloor(volume / step_vol) * step_vol;
   
   if(volume < min_vol)
     {
      PrintFormat("Trade rejected: Calculated volume (%.2f) is below broker minimum (%.2f).", volume, min_vol);
      return 0.0;
     }
   if(volume > max_vol)
     {
      volume = max_vol;
     }
     
   return volume;
  }

//+------------------------------------------------------------------+
//| STOP LEVEL VALIDATION                                            |
//+------------------------------------------------------------------+
bool ValidateStops(ENUM_ORDER_TYPE type, double entry, double sl, double tp)
  {
   long stop_level = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long freeze_level = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   double min_dist = MathMax(stop_level, freeze_level) * _Point;
   
   if(type == ORDER_TYPE_BUY)
     {
      if((entry - sl) < min_dist || (tp - entry) < min_dist)
        {
         PrintFormat("Trade rejected: Stops violate minimum distance (%.5f).", min_dist);
         return false;
        }
     }
   else if(type == ORDER_TYPE_SELL)
     {
      if((sl - entry) < min_dist || (entry - tp) < min_dist)
        {
         PrintFormat("Trade rejected: Stops violate minimum distance (%.5f).", min_dist);
         return false;
        }
     }
   return true;
  }

//+------------------------------------------------------------------+
//| MARGIN CHECK                                                     |
//+------------------------------------------------------------------+
bool CheckMargin(ENUM_ORDER_TYPE type, double volume, double price)
  {
   double margin_required = 0.0;
   if(!OrderCalcMargin(type, _Symbol, volume, price, margin_required))
     {
      Print("Error: Failed to calculate required margin.");
      return false;
     }
     
   if(AccountInfoDouble(ACCOUNT_MARGIN_FREE) < margin_required)
     {
      PrintFormat("Trade rejected: Insufficient free margin. Required: %.2f", margin_required);
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| MAIN TICK FUNCTION                                               |
//+------------------------------------------------------------------+
void OnTick()
  {
   // 1. Only evaluate on new bar
   if(!IsNewBar()) return;
   
   // 2. Data requirement check
   int required_bars = MathMax(InpEMAPeriod, InpOBVLookback + 5);
   if(iBars(_Symbol, InpTimeframe) < required_bars)
     {
      Print("Insufficient historical data.");
      return;
     }
     
   // 3. Prevent duplicate positions
   if(HasOpenPosition()) return;
   
   // 4. Data Arrays Setup
   int copy_count = InpOBVLookback + 5;
   
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, InpTimeframe, 0, copy_count, rates) < copy_count)
     {
      Print("Error: Failed to copy historical price rates.");
      return;
     }
     
   double ema[];
   ArraySetAsSeries(ema, true);
   if(CopyBuffer(handle_ema, 0, 0, copy_count, ema) < copy_count)
     {
      Print("Error: Failed to copy EMA data.");
      return;
     }
     
   double obv[];
   ArraySetAsSeries(obv, true);
   if(CopyBuffer(handle_obv, 0, 0, copy_count, obv) < copy_count)
     {
      Print("Error: Failed to copy OBV data.");
      return;
     }
     
   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(handle_atr, 0, 0, copy_count, atr) < copy_count)
     {
      Print("Error: Failed to copy ATR data.");
      return;
     }
     
   // 5. Calculate lookback highs and lows (Shift 2 to InpOBVLookback + 1)
   double prev_obv_high = -DBL_MAX;
   double prev_obv_low = DBL_MAX;
   double prev_price_high = -DBL_MAX;
   double prev_price_low = DBL_MAX;
   
   for(int i = 2; i <= InpOBVLookback + 1; i++)
     {
      if(obv[i] > prev_obv_high) prev_obv_high = obv[i];
      if(obv[i] < prev_obv_low)  prev_obv_low = obv[i];
      
      if(rates[i].high > prev_price_high) prev_price_high = rates[i].high;
      if(rates[i].low < prev_price_low)   prev_price_low = rates[i].low;
     }
     
   // 6. Signal Evaluation
   bool buy_signal = false;
   bool sell_signal = false;
   
   double price_breakout_buffer = InpPriceBreakoutBufferPoints * _Point;
   
   // --- Evaluate BUY Condition ---
   if(rates[1].close > ema[1]) // EMA Trend Confirmation
     {
      if(obv[2] <= prev_obv_high && obv[1] > (prev_obv_high + InpOBVMinimumBreakout)) // OBV Breakout
        {
         if(rates[1].close > (prev_price_high + price_breakout_buffer) && rates[1].close > rates[1].open) // Price Breakout
           {
            buy_signal = true;
           }
        }
     }
     
   // --- Evaluate SELL Condition ---
   if(rates[1].close < ema[1]) // EMA Trend Confirmation
     {
      if(obv[2] >= prev_obv_low && obv[1] < (prev_obv_low - InpOBVMinimumBreakout)) // OBV Breakout
        {
         if(rates[1].close < (prev_price_low - price_breakout_buffer) && rates[1].close < rates[1].open) // Price Breakout
           {
            sell_signal = true;
           }
        }
     }
     
   if(!buy_signal && !sell_signal) return;
   
   // 7. Pre-Trade Checks
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   if(!CheckSpread(ask, bid)) return;
   
   double atr_val = atr[1];
   if(atr_val <= 0) return;
   
   // 8. Order Execution Routing
   if(buy_signal)
     {
      ExecuteBuy(ask, atr_val);
     }
   else if(sell_signal)
     {
      ExecuteSell(bid, atr_val);
     }
  }

//+------------------------------------------------------------------+
//| EXECUTE BUY                                                      |
//+------------------------------------------------------------------+
void ExecuteBuy(double entry_price, double atr_value)
  {
   double sl = NormalizeDouble(entry_price - (atr_value * InpATRMultiplier), _Digits);
   double risk_distance = entry_price - sl;
   double tp = NormalizeDouble(entry_price + (risk_distance * InpRiskReward), _Digits);
   
   if(!ValidateStops(ORDER_TYPE_BUY, entry_price, sl, tp)) return;
   
   double volume = CalculateLotSize(risk_distance);
   if(volume == 0.0) return;
   
   if(!CheckMargin(ORDER_TYPE_BUY, volume, entry_price)) return;
   
   PrintFormat("Executing BUY: Entry=%.5f, SL=%.5f, TP=%.5f, Volume=%.2f", entry_price, sl, tp, volume);
   
   if(trade.Buy(volume, _Symbol, entry_price, sl, tp, "OBV Trend BUY"))
     {
      PrintFormat("BUY order successful: Ticket %d", trade.ResultOrder());
     }
   else
     {
      PrintFormat("BUY order failed: Retcode %d (%s)", trade.ResultRetcode(), trade.ResultRetcodeDescription());
     }
  }

//+------------------------------------------------------------------+
//| EXECUTE SELL                                                     |
//+------------------------------------------------------------------+
void ExecuteSell(double entry_price, double atr_value)
  {
   double sl = NormalizeDouble(entry_price + (atr_value * InpATRMultiplier), _Digits);
   double risk_distance = sl - entry_price;
   double tp = NormalizeDouble(entry_price - (risk_distance * InpRiskReward), _Digits);
   
   if(!ValidateStops(ORDER_TYPE_SELL, entry_price, sl, tp)) return;
   
   double volume = CalculateLotSize(risk_distance);
   if(volume == 0.0) return;
   
   if(!CheckMargin(ORDER_TYPE_SELL, volume, entry_price)) return;
   
   PrintFormat("Executing SELL: Entry=%.5f, SL=%.5f, TP=%.5f, Volume=%.2f", entry_price, sl, tp, volume);
   
   if(trade.Sell(volume, _Symbol, entry_price, sl, tp, "OBV Trend SELL"))
     {
      PrintFormat("SELL order successful: Ticket %d", trade.ResultOrder());
     }
   else
     {
      PrintFormat("SELL order failed: Retcode %d (%s)", trade.ResultRetcode(), trade.ResultRetcodeDescription());
     }
  }
//+------------------------------------------------------------------+