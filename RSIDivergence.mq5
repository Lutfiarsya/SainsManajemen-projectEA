//+------------------------------------------------------------------+
//|                                           RSI Divergence EA.mq5 |
//|                                    Copyright 2026, Expert Trader |
//+------------------------------------------------------------------+
#property copyright "Expert Trader"
#property link      ""
#property version   "1.00"
#property description "Regular RSI Divergence EA with ATR Stop Loss and Fixed R:R"

#include <Trade/Trade.mqh>

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                 |
//+------------------------------------------------------------------+
input group "--- Core Settings ---"
input int      Magic_Number                    = 20260918; // Magic Number

input group "--- Indicator Settings ---"
input int      RSI_Period                      = 14;       // RSI Period
input int      ATR_Period                      = 14;       // ATR Period

input group "--- Pivot Detection ---"
input int      Pivot_Left                      = 3;        // Pivot Left
input int      Pivot_Right                     = 3;        // Pivot Right
input int      Minimum_Pivot_Distance          = 5;        // Minimum Pivot Distance
input int      Maximum_Pivot_Distance          = 60;       // Maximum Pivot Distance

input group "--- Divergence Rules ---"
input double   Minimum_RSI_Difference          = 3.0;      // Minimum RSI Difference
input int      Minimum_Price_Difference_Points = 50;       // Minimum Price Difference (Points)

input group "--- Risk & Trade Settings ---"
input double   ATR_SL_Multiplier               = 2.0;      // ATR SL Multiplier
input double   Risk_Reward                     = 2.0;      // Risk/Reward Ratio
input double   Risk_Percent                    = 1.0;      // Risk Percent (%)
input int      Max_Spread_Points               = 30;       // Max Spread (Points)

//+------------------------------------------------------------------+
//| GLOBAL VARIABLES                                                 |
//+------------------------------------------------------------------+
CTrade         trade;
int            handle_rsi = INVALID_HANDLE;
int            handle_atr = INVALID_HANDLE;

datetime       last_processed_buy_pivot_time  = 0;
datetime       last_processed_sell_pivot_time = 0;

double         rsi_buffer[];
double         atr_buffer[];

// Pivot Structure
struct SPivot {
    datetime time;
    int      shift;
    double   price;
    double   rsi;
    bool     valid;
};

//+------------------------------------------------------------------+
//| INITIALIZATION FUNCTION                                          |
//+------------------------------------------------------------------+
int OnInit() {
    trade.SetExpertMagicNumber(Magic_Number);
    
    // Initialize RSI
    handle_rsi = iRSI(_Symbol, _Period, RSI_Period, PRICE_CLOSE);
    if(handle_rsi == INVALID_HANDLE) {
        Print("Failed to create RSI indicator handle.");
        return INIT_FAILED;
    }
    
    // Initialize ATR
    handle_atr = iATR(_Symbol, _Period, ATR_Period);
    if(handle_atr == INVALID_HANDLE) {
        Print("Failed to create ATR indicator handle.");
        return INIT_FAILED;
    }
    
    ArraySetAsSeries(rsi_buffer, true);
    ArraySetAsSeries(atr_buffer, true);
    
    Print("RSI Divergence EA Initialized Successfully.");
    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| DEINITIALIZATION FUNCTION                                        |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
    if(handle_rsi != INVALID_HANDLE) IndicatorRelease(handle_rsi);
    if(handle_atr != INVALID_HANDLE) IndicatorRelease(handle_atr);
    Print("RSI Divergence EA Deinitialized.");
}

//+------------------------------------------------------------------+
//| NEW BAR DETECTION                                                |
//+------------------------------------------------------------------+
bool IsNewBar() {
    static datetime last_time = 0;
    datetime current_time = iTime(_Symbol, _Period, 0);
    
    if(current_time != last_time && current_time != 0) {
        last_time = current_time;
        return true;
    }
    return false;
}

//+------------------------------------------------------------------+
//| CHECK OPEN POSITION (MAX 1 PER SYMBOL/MAGIC)                     |
//+------------------------------------------------------------------+
bool HasOpenPosition() {
    int total = PositionsTotal();
    for(int i = 0; i < total; i++) {
        ulong ticket = PositionGetTicket(i);
        if(ticket > 0) {
            if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
               PositionGetInteger(POSITION_MAGIC) == Magic_Number) {
                return true;
            }
        }
    }
    return false;
}

//+------------------------------------------------------------------+
//| LOAD INDICATOR DATA                                              |
//+------------------------------------------------------------------+
bool LoadIndicatorData() {
    int copy_count = Maximum_Pivot_Distance + Pivot_Left + Pivot_Right + 10;
    
    if(CopyBuffer(handle_rsi, 0, 0, copy_count, rsi_buffer) < copy_count) {
        Print("Error copying RSI data.");
        return false;
    }
    
    if(CopyBuffer(handle_atr, 0, 1, 1, atr_buffer) < 1) { // Shift 1 (last closed candle)
        Print("Error copying ATR data.");
        return false;
    }
    
    return true;
}

//+------------------------------------------------------------------+
//| SWING LOW DETECTION                                              |
//+------------------------------------------------------------------+
bool IsSwingLow(int index) {
    double pivot_price = iLow(_Symbol, _Period, index);
    
    // Check older candles (Pivot_Left)
    for(int i = 1; i <= Pivot_Left; i++) {
        if(iLow(_Symbol, _Period, index + i) <= pivot_price) return false;
    }
    
    // Check newer candles (Pivot_Right)
    for(int i = 1; i <= Pivot_Right; i++) {
        if(iLow(_Symbol, _Period, index - i) < pivot_price) return false;
    }
    
    return true;
}

//+------------------------------------------------------------------+
//| SWING HIGH DETECTION                                             |
//+------------------------------------------------------------------+
bool IsSwingHigh(int index) {
    double pivot_price = iHigh(_Symbol, _Period, index);
    
    // Check older candles (Pivot_Left)
    for(int i = 1; i <= Pivot_Left; i++) {
        if(iHigh(_Symbol, _Period, index + i) >= pivot_price) return false;
    }
    
    // Check newer candles (Pivot_Right)
    for(int i = 1; i <= Pivot_Right; i++) {
        if(iHigh(_Symbol, _Period, index - i) > pivot_price) return false;
    }
    
    return true;
}

//+------------------------------------------------------------------+
//| FIND LATEST CONFIRMED LOW PIVOTS                                 |
//+------------------------------------------------------------------+
bool GetLatestLowPivots(SPivot &p1, SPivot &p2) {
    int found = 0;
    int max_scan = Maximum_Pivot_Distance + Pivot_Left + Pivot_Right + 5;
    
    for(int i = Pivot_Right + 1; i < max_scan; i++) { // +1 ensures Pivot_Right candles are fully CLOSED
        if(IsSwingLow(i)) {
            if(found == 0) {
                p2.shift = i;
                p2.time  = iTime(_Symbol, _Period, i);
                p2.price = iLow(_Symbol, _Period, i);
                p2.rsi   = rsi_buffer[i];
                p2.valid = true;
                found++;
            } else if(found == 1) {
                p1.shift = i;
                p1.time  = iTime(_Symbol, _Period, i);
                p1.price = iLow(_Symbol, _Period, i);
                p1.rsi   = rsi_buffer[i];
                p1.valid = true;
                found++;
                return true;
            }
        }
    }
    return false;
}

//+------------------------------------------------------------------+
//| FIND LATEST CONFIRMED HIGH PIVOTS                                |
//+------------------------------------------------------------------+
bool GetLatestHighPivots(SPivot &p1, SPivot &p2) {
    int found = 0;
    int max_scan = Maximum_Pivot_Distance + Pivot_Left + Pivot_Right + 5;
    
    for(int i = Pivot_Right + 1; i < max_scan; i++) { // +1 ensures Pivot_Right candles are fully CLOSED
        if(IsSwingHigh(i)) {
            if(found == 0) {
                p2.shift = i;
                p2.time  = iTime(_Symbol, _Period, i);
                p2.price = iHigh(_Symbol, _Period, i);
                p2.rsi   = rsi_buffer[i];
                p2.valid = true;
                found++;
            } else if(found == 1) {
                p1.shift = i;
                p1.time  = iTime(_Symbol, _Period, i);
                p1.price = iHigh(_Symbol, _Period, i);
                p1.rsi   = rsi_buffer[i];
                p1.valid = true;
                found++;
                return true;
            }
        }
    }
    return false;
}

//+------------------------------------------------------------------+
//| RESTART-SAFE DIVERGENCE HISTORY CHECK                            |
//+------------------------------------------------------------------+
bool IsDivergenceProcessed(datetime pivot_time, ENUM_POSITION_TYPE type) {
    if(type == POSITION_TYPE_BUY && pivot_time <= last_processed_buy_pivot_time) return true;
    if(type == POSITION_TYPE_SELL && pivot_time <= last_processed_sell_pivot_time) return true;
    
    if(HistorySelect(pivot_time, TimeCurrent() + 86400)) {
        int total = HistoryDealsTotal();
        for(int i = total - 1; i >= 0; i--) {
            ulong ticket = HistoryDealGetTicket(i);
            if(ticket > 0) {
                if(HistoryDealGetInteger(ticket, DEAL_MAGIC) == Magic_Number &&
                   HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol &&
                   HistoryDealGetInteger(ticket, DEAL_ENTRY) == DEAL_ENTRY_IN) {
                   
                    long deal_type = HistoryDealGetInteger(ticket, DEAL_TYPE);
                    if((type == POSITION_TYPE_BUY && deal_type == DEAL_TYPE_BUY) ||
                       (type == POSITION_TYPE_SELL && deal_type == DEAL_TYPE_SELL)) {
                        
                        if(type == POSITION_TYPE_BUY) last_processed_buy_pivot_time = pivot_time;
                        if(type == POSITION_TYPE_SELL) last_processed_sell_pivot_time = pivot_time;
                        return true;
                    }
                }
            }
        }
    }
    return false;
}

//+------------------------------------------------------------------+
//| VALIDATE STOPS/FREEZE LEVELS                                     |
//+------------------------------------------------------------------+
bool ValidateStops(double entry, double sl, double tp, ENUM_POSITION_TYPE type) {
    long stops_level = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
    long freeze_level = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
    double min_dist = MathMax(stops_level, freeze_level) * _Point;
    
    if(type == POSITION_TYPE_BUY) {
        if((entry - sl) <= min_dist || (tp - entry) <= min_dist) {
            Print("Trade rejected: SL or TP violates broker Stops/Freeze level.");
            return false;
        }
    } else {
        if((sl - entry) <= min_dist || (entry - tp) <= min_dist) {
            Print("Trade rejected: SL or TP violates broker Stops/Freeze level.");
            return false;
        }
    }
    return true;
}

//+------------------------------------------------------------------+
//| CALCULATE RISK-BASED LOT SIZE                                    |
//+------------------------------------------------------------------+
double CalculateLotSize(double risk_distance) {
    if(risk_distance <= 0) return 0;
    
    double equity = AccountInfoDouble(ACCOUNT_EQUITY);
    double risk_money = equity * (Risk_Percent / 100.0);
    
    double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    
    if(tick_size == 0 || tick_value == 0) return 0;
    
    double loss_ticks = risk_distance / tick_size;
    double loss_per_lot = loss_ticks * tick_value;
    
    if(loss_per_lot == 0) return 0;
    
    double volume = risk_money / loss_per_lot;
    
    double min_vol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double max_vol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    double step_vol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    
    volume = MathFloor(volume / step_vol) * step_vol;
    
    if(volume < min_vol) {
        Print("Trade rejected: Calculated volume (", volume, ") is below broker minimum (", min_vol, ").");
        return 0;
    }
    if(volume > max_vol) {
        volume = max_vol;
    }
    
    return volume;
}

//+------------------------------------------------------------------+
//| CHECK BUY SIGNAL (BULLISH DIVERGENCE)                            |
//+------------------------------------------------------------------+
void CheckBuySignal(SPivot &p1, SPivot &p2) {
    int distance = p1.shift - p2.shift;
    
    if(distance < Minimum_Pivot_Distance || distance > Maximum_Pivot_Distance) return;
    if(p2.price >= p1.price) return; 
    if(p2.rsi <= p1.rsi) return;     
    if((p2.rsi - p1.rsi) < Minimum_RSI_Difference) return;
    if((p1.price - p2.price) < Minimum_Price_Difference_Points * _Point) return;
    
    if(IsDivergenceProcessed(p2.time, POSITION_TYPE_BUY)) return;
    
    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double spread_points = (ask - bid) / _Point;
    
    if(spread_points > Max_Spread_Points) {
        Print("BUY Divergence detected but rejected: Spread ", spread_points, " > Max ", Max_Spread_Points);
        return;
    }
    
    double atr_val = atr_buffer[0];
    double sl_distance = atr_val * ATR_SL_Multiplier;
    double sl = ask - sl_distance;
    double risk = ask - sl;
    double tp = ask + (risk * Risk_Reward);
    
    if(!ValidateStops(ask, sl, tp, POSITION_TYPE_BUY)) return;
    
    double volume = CalculateLotSize(risk);
    if(volume == 0) return;
    
    if(trade.Buy(volume, _Symbol, ask, sl, tp, "Bullish Div")) {
        Print("==================================================");
        Print("Confirmed Bullish Divergence: BUY Executed.");
        Print("Price Low 1 = ", p1.price, ", Price Low 2 = ", p2.price);
        Print("RSI 1 = ", p1.rsi, ", RSI 2 = ", p2.rsi, ", Pivot Distance = ", distance);
        Print("Entry: ", ask, ", SL: ", sl, ", TP: ", tp, ", Vol: ", volume);
        Print("Result Retcode: ", trade.ResultRetcode(), " (", trade.ResultRetcodeDescription(), ")");
        Print("==================================================");
        last_processed_buy_pivot_time = p2.time;
    } else {
        Print("BUY execution failed. Retcode: ", trade.ResultRetcode(), " (", trade.ResultRetcodeDescription(), ")");
    }
}

//+------------------------------------------------------------------+
//| CHECK SELL SIGNAL (BEARISH DIVERGENCE)                           |
//+------------------------------------------------------------------+
void CheckSellSignal(SPivot &p1, SPivot &p2) {
    int distance = p1.shift - p2.shift;
    
    if(distance < Minimum_Pivot_Distance || distance > Maximum_Pivot_Distance) return;
    if(p2.price <= p1.price) return; 
    if(p2.rsi >= p1.rsi) return;     
    if((p1.rsi - p2.rsi) < Minimum_RSI_Difference) return;
    if((p2.price - p1.price) < Minimum_Price_Difference_Points * _Point) return;
    
    if(IsDivergenceProcessed(p2.time, POSITION_TYPE_SELL)) return;
    
    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double spread_points = (ask - bid) / _Point;
    
    if(spread_points > Max_Spread_Points) {
        Print("SELL Divergence detected but rejected: Spread ", spread_points, " > Max ", Max_Spread_Points);
        return;
    }
    
    double atr_val = atr_buffer[0];
    double sl_distance = atr_val * ATR_SL_Multiplier;
    double sl = bid + sl_distance;
    double risk = sl - bid;
    double tp = bid - (risk * Risk_Reward);
    
    if(!ValidateStops(bid, sl, tp, POSITION_TYPE_SELL)) return;
    
    double volume = CalculateLotSize(risk);
    if(volume == 0) return;
    
    if(trade.Sell(volume, _Symbol, bid, sl, tp, "Bearish Div")) {
        Print("==================================================");
        Print("Confirmed Bearish Divergence: SELL Executed.");
        Print("Price High 1 = ", p1.price, ", Price High 2 = ", p2.price);
        Print("RSI 1 = ", p1.rsi, ", RSI 2 = ", p2.rsi, ", Pivot Distance = ", distance);
        Print("Entry: ", bid, ", SL: ", sl, ", TP: ", tp, ", Vol: ", volume);
        Print("Result Retcode: ", trade.ResultRetcode(), " (", trade.ResultRetcodeDescription(), ")");
        Print("==================================================");
        last_processed_sell_pivot_time = p2.time;
    } else {
        Print("SELL execution failed. Retcode: ", trade.ResultRetcode(), " (", trade.ResultRetcodeDescription(), ")");
    }
}

//+------------------------------------------------------------------+
//| MAIN TICK FUNCTION                                               |
//+------------------------------------------------------------------+
void OnTick() {
    if(!IsNewBar()) return;
    
    int min_bars_required = Maximum_Pivot_Distance + Pivot_Left + Pivot_Right + MathMax(RSI_Period, ATR_Period) + 10;
    if(iBars(_Symbol, _Period) <= min_bars_required) {
        Print("Insufficient historical bars to calculate strategy.");
        return;
    }
    
    if(HasOpenPosition()) return;
    
    if(!LoadIndicatorData()) return;
    
    SPivot low1, low2;
    if(GetLatestLowPivots(low1, low2)) {
        CheckBuySignal(low1, low2);
    }
    
    SPivot high1, high2;
    if(GetLatestHighPivots(high1, high2)) {
        CheckSellSignal(high1, high2);
    }
}
//+------------------------------------------------------------------+