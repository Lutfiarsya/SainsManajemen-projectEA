//+------------------------------------------------------------------+
//|                                       VWAP Mean Reversion EA.mq5 |
//|                                  Copyright 2026, Quantitative EA |
//|                                              https://www.mql5.com|
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Quantitative EA"
#property link      "https://www.mql5.com"
#property version   "1.00"
#property description "Session VWAP Mean Reversion Strategy"

#include <Trade/Trade.mqh>

//--- Input Parameters
input group "--- Strategy Settings ---"
input ENUM_TIMEFRAMES InpTimeframe           = PERIOD_H1;  // Timeframe
input double          InpDeviationMultiplier = 2.0;        // Deviation Multiplier
input int             InpATRPeriod           = 14;         // ATR Period
input double          InpATRMultiplier       = 2.0;        // ATR SL Multiplier

input group "--- Risk & Trade Management ---"
input double          InpRiskPercent         = 1.0;        // Risk Percent (%)
input double          InpRiskReward          = 2.0;        // Risk/Reward Ratio
input int             InpMaxSpreadPoints     = 30;         // Maximum Spread (Points)
input ulong           InpMagicNumber         = 20260919;   // Magic Number

//--- Global Variables
CTrade         trade;
int            handle_atr = INVALID_HANDLE;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetExpertMagicNumber(InpMagicNumber);
   
   handle_atr = iATR(_Symbol, InpTimeframe, InpATRPeriod);
   if(handle_atr == INVALID_HANDLE)
     {
      Print("Failed to create ATR indicator handle.");
      return(INIT_FAILED);
     }
     
   Print("VWAP Mean Reversion EA Initialized.");
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(handle_atr != INVALID_HANDLE)
     {
      IndicatorRelease(handle_atr);
     }
   Print("VWAP Mean Reversion EA Deinitialized.");
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   if(!IsNewBar())
      return;
      
   if(HasOpenPosition())
      return;
      
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double spread_points = (ask - bid) / _Point;
   
   if(spread_points > InpMaxSpreadPoints)
     {
      Print("Spread too high: ", spread_points, " points.");
      return;
     }
     
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, InpTimeframe, 0, 3, rates) < 3)
     {
      Print("Failed to copy price data.");
      return;
     }
     
   double atr_val[1];
   if(CopyBuffer(handle_atr, 0, 1, 1, atr_val) <= 0)
     {
      Print("Failed to copy ATR data.");
      return;
     }
     
   double vwap1, upper1, lower1;
   double vwap2, upper2, lower2;
   
   if(!GetVWAPAndBands(1, vwap1, upper1, lower1))
      return;
   if(!GetVWAPAndBands(2, vwap2, upper2, lower2))
      return;
      
   //--- Check Buy Signal
   if(rates[2].low <= lower2 &&
      rates[1].low <= lower1 &&
      rates[1].close > lower1 &&
      rates[1].close > rates[1].open &&
      rates[1].close < vwap1)
     {
      Print("BUY signal detected.");
      OpenBuy(ask, atr_val[0]);
     }
     
   //--- Check Sell Signal
   else if(rates[2].high >= upper2 &&
           rates[1].high >= upper1 &&
           rates[1].close < upper1 &&
           rates[1].close < rates[1].open &&
           rates[1].close > vwap1)
     {
      Print("SELL signal detected.");
      OpenSell(bid, atr_val[0]);
     }
  }

//+------------------------------------------------------------------+
//| Check if a new bar has formed                                    |
//+------------------------------------------------------------------+
bool IsNewBar()
  {
   static datetime last_time = 0;
   datetime current_time = iTime(_Symbol, InpTimeframe, 0);
   
   if(current_time == 0)
      return false;
      
   if(current_time != last_time)
     {
      last_time = current_time;
      return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Check if an open position exists for this symbol and magic       |
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
//| Calculate Volume Weighted Average Price and Standard Deviation   |
//+------------------------------------------------------------------+
bool GetVWAPAndBands(int target_shift, double &vwap, double &upper, double &lower)
  {
   datetime target_time = iTime(_Symbol, InpTimeframe, target_shift);
   if(target_time == 0)
      return false;
      
   MqlDateTime dt;
   TimeToStruct(target_time, dt);
   dt.hour = 0;
   dt.min = 0;
   dt.sec = 0;
   datetime start_time = StructToTime(dt);
   
   MqlRates session_rates[];
   int copied = CopyRates(_Symbol, InpTimeframe, start_time, target_time, session_rates);
   
   if(copied <= 0)
     {
      Print("Insufficient session data for VWAP calculation.");
      return false;
     }
     
   double sum_pv = 0.0;
   double sum_v = 0.0;
   
   for(int i = 0; i < copied; i++)
     {
      double v = (session_rates[i].real_volume > 0) ? (double)session_rates[i].real_volume : (double)session_rates[i].tick_volume;
      double tp = (session_rates[i].high + session_rates[i].low + session_rates[i].close) / 3.0;
      
      sum_pv += tp * v;
      sum_v += v;
     }
     
   if(sum_v <= 0)
     {
      Print("Zero volume detected in session, cannot calculate VWAP.");
      return false;
     }
     
   vwap = sum_pv / sum_v;
   
   double variance_sum = 0.0;
   for(int i = 0; i < copied; i++)
     {
      double v = (session_rates[i].real_volume > 0) ? (double)session_rates[i].real_volume : (double)session_rates[i].tick_volume;
      double tp = (session_rates[i].high + session_rates[i].low + session_rates[i].close) / 3.0;
      variance_sum += v * MathPow(tp - vwap, 2);
     }
     
   double variance = variance_sum / sum_v;
   double sd = MathSqrt(variance);
   
   upper = vwap + (sd * InpDeviationMultiplier);
   lower = vwap - (sd * InpDeviationMultiplier);
   
   return true;
  }

//+------------------------------------------------------------------+
//| Calculate Lot Size Based on Risk                                 |
//+------------------------------------------------------------------+
double CalculateLotSize(double risk_distance_points)
  {
   if(risk_distance_points <= 0)
      return 0.0;
      
   double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   
   if(tick_size == 0.0 || tick_value == 0.0)
     {
      Print("Invalid tick size or tick value.");
      return 0.0;
     }
     
   double risk_money = AccountInfoDouble(ACCOUNT_EQUITY) * (InpRiskPercent / 100.0);
   double loss_ticks = risk_distance_points / tick_size;
   double loss_per_lot = loss_ticks * tick_value;
   
   if(loss_per_lot == 0.0)
      return 0.0;
      
   double volume = risk_money / loss_per_lot;
   
   double min_vol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double max_vol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step_vol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   
   volume = MathFloor(volume / step_vol) * step_vol;
   
   if(volume < min_vol)
     {
      Print("Calculated volume below broker minimum. Trade rejected.");
      return 0.0;
     }
   if(volume > max_vol)
      volume = max_vol;
      
   return volume;
  }

//+------------------------------------------------------------------+
//| Validate Broker Stop Level and Freeze Level                      |
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
         Print("Invalid stops for BUY. Minimum distance: ", min_dist);
         return false;
        }
     }
   else if(type == ORDER_TYPE_SELL)
     {
      if((sl - entry) < min_dist || (entry - tp) < min_dist)
        {
         Print("Invalid stops for SELL. Minimum distance: ", min_dist);
         return false;
        }
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Verify Sufficient Margin                                         |
//+------------------------------------------------------------------+
bool CheckMargin(ENUM_ORDER_TYPE type, double volume, double price)
  {
   double margin_required = 0.0;
   if(!OrderCalcMargin(type, _Symbol, volume, price, margin_required))
     {
      Print("Failed to calculate margin.");
      return false;
     }
     
   if(AccountInfoDouble(ACCOUNT_MARGIN_FREE) < margin_required)
     {
      Print("Insufficient margin. Required: ", margin_required);
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Open Buy Position                                                |
//+------------------------------------------------------------------+
void OpenBuy(double entry_price, double atr_value)
  {
   double sl = NormalizeDouble(entry_price - (atr_value * InpATRMultiplier), _Digits);
   double risk_distance = entry_price - sl;
   double tp = NormalizeDouble(entry_price + (risk_distance * InpRiskReward), _Digits);
   
   if(!ValidateStops(ORDER_TYPE_BUY, entry_price, sl, tp))
      return;
      
   double volume = CalculateLotSize(risk_distance);
   if(volume == 0.0)
      return;
      
   if(!CheckMargin(ORDER_TYPE_BUY, volume, entry_price))
      return;
      
   if(trade.Buy(volume, _Symbol, entry_price, sl, tp, "VWAP Mean Reversion BUY"))
     {
      PrintFormat("BUY order successful: Vol=%f, Entry=%f, SL=%f, TP=%f", volume, entry_price, sl, tp);
     }
   else
     {
      Print("BUY order failed: retcode = ", trade.ResultRetcode(), ", description = ", trade.ResultRetcodeDescription());
     }
  }

//+------------------------------------------------------------------+
//| Open Sell Position                                               |
//+------------------------------------------------------------------+
void OpenSell(double entry_price, double atr_value)
  {
   double sl = NormalizeDouble(entry_price + (atr_value * InpATRMultiplier), _Digits);
   double risk_distance = sl - entry_price;
   double tp = NormalizeDouble(entry_price - (risk_distance * InpRiskReward), _Digits);
   
   if(!ValidateStops(ORDER_TYPE_SELL, entry_price, sl, tp))
      return;
      
   double volume = CalculateLotSize(risk_distance);
   if(volume == 0.0)
      return;
      
   if(!CheckMargin(ORDER_TYPE_SELL, volume, entry_price))
      return;
      
   if(trade.Sell(volume, _Symbol, entry_price, sl, tp, "VWAP Mean Reversion SELL"))
     {
      PrintFormat("SELL order successful: Vol=%f, Entry=%f, SL=%f, TP=%f", volume, entry_price, sl, tp);
     }
   else
     {
      Print("SELL order failed: retcode = ", trade.ResultRetcode(), ", description = ", trade.ResultRetcodeDescription());
     }
  }
//+------------------------------------------------------------------+