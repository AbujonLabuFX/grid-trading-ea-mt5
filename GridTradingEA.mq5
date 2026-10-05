#property strict

//+------------------------------------------------------------------+
//| Grid Trading EA (MT5)                                            |
//| ATR Adaptive Grid + Spread Filter + Risk Control                 |
//+------------------------------------------------------------------+

input double LotSize              = 0.10;      // Saiz lot awal
input int    MaxOrders            = 10;        // Maksimum jumlah posisi aktif
input int    Slippage             = 3;         // Slippage dalam points
input int    MagicNumber          = 12345;     // Magic number EA

// --- Trailing Stop per posisi ---
input bool   UseTrailingStop       = true;
input double TrailingStopPoints    = 50.0;      // Trailing stop dalam points

// --- Trailing profit close global akaun ---
input bool   Use_Trailing_Profit_Close = true;
input double Trailing_Profit_Trigger   = 30.0;   // Trigger profit (USD)
input double Trailing_Profit_Lockout   = 15.0;   // Lock profit selepas trigger (USD)

// --- Swap & Commission ---
input bool   IncludeSwapCommission = true; // Kira sekali swap & commission

// --- ATR Adaptive Grid ---
input int    ATR_Period = 14;        // Period ATR
input double ATR_Multiplier = 2.0;   // Gandaan ATR untuk grid step minimum
input double MinGridStep = 50;       // Grid step minimum (points)

// --- Spread Filter ---
input bool   EnableSpreadFilter = true;
input double MaxSpreadPoints = 30;    // Max spread dalam points

// --- Risk Control ---
input bool   UseDailyLossLimit = true;
input double DailyLossLimit   = 50.0;   // Loss harian maksimum (USD)

// --- Volatility filter ---
input bool   EnableVolatilityFilter = true;
input double MinATRPoints = 0.5;       // ATR minimum (points)
input double MaxATRPoints = 5.0;        // ATR maksimum (points)

// --- Take Profit & lot scaling ---
input bool   UseTakeProfitPerOrder = true;
input double TakeProfitPoints = 20.0;   // Take profit per order (points)
input bool   UseIncreasedLot = false;
input double LotMultiplier = 1.2;        // Multiplier lot bila order bertambah

// --- Logging ---
input bool   EnableDetailedLogging = true;

// --- Global variables ---
static double lastPrice = 0;

//+------------------------------------------------------------------+
//| Helper functions                                                 |
//+------------------------------------------------------------------+

double GetATR(string symbol, int period)
{
   double atr[];
   if(CopyBuffer(iATR(symbol, PERIOD_CURRENT, period), 0, 0, 2, atr) > 0)
      return atr[0];
   return 0.0;
}

bool IsSpreadOK()
{
   if(!EnableSpreadFilter)
      return true;

   double spread = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID)) / _Point;
   return (spread <= MaxSpreadPoints);
}

bool IsVolatilityOK()
{
   if(!EnableVolatilityFilter)
      return true;

   double atr = GetATR(_Symbol, ATR_Period);
   if(atr <= 0)
      return false;

   double atrPoints = atr / _Point;
   return (atrPoints >= MinATRPoints && atrPoints <= MaxATRPoints);
}

double GetAdaptiveGridStep()
{
   double atr = GetATR(_Symbol, ATR_Period);
   if(atr <= 0)
      return MinGridStep;

   double step = atr * ATR_Multiplier / _Point;
   if(step < MinGridStep)
      step = MinGridStep;
   return step;
}

bool IsDailyLossExceeded()
{
   if(!UseDailyLossLimit)
      return false;

   double profit = GetTotalProfit();
   return (profit <= -DailyLossLimit);
}

//+------------------------------------------------------------------+
//| Calculate total account profit                                    |
//+------------------------------------------------------------------+

double GetTotalProfit()
{
   double profit = 0.0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
      {
         profit += PositionGetDouble(POSITION_PROFIT);
         if(IncludeSwapCommission)
         {
            profit += PositionGetDouble(POSITION_SWAP);
            profit += PositionGetDouble(POSITION_COMMISSION);
         }
      }
   }
   return profit;
}

//+------------------------------------------------------------------+
//| Compute next lot size                                             |
//+------------------------------------------------------------------+

double GetOrderVolume()
{
   double vol = LotSize;
   if(!UseIncreasedLot)
      return vol;

   int total = PositionsTotal();
   if(total <= 0)
      return vol;

   vol = LotSize * MathPow(LotMultiplier, total);
   return vol;
}

//+------------------------------------------------------------------+
//| Open market order                                                 |
//+------------------------------------------------------------------+
bool OpenOrder(int type)
{
   if(!IsSpreadOK())
   {
      if(EnableDetailedLogging)
         Print("Spread terlalu tinggi, skip entry.");
      return false;
   }

   if(!IsVolatilityOK())
   {
      if(EnableDetailedLogging)
         Print("Volatility tidak sesuai, skip entry.");
      return false;
   }

   MqlTradeRequest request;
   MqlTradeResult  result;
   ZeroMemory(request);
   ZeroMemory(result);

   request.action       = TRADE_ACTION_DEAL;
   request.symbol       = _Symbol;
   request.volume       = GetOrderVolume();
   request.magic        = MagicNumber;
   request.type         = (ENUM_ORDER_TYPE)type;
   request.deviation    = Slippage;
   request.type_filling = ORDER_FILLING_IOC;

   if(type == ORDER_TYPE_BUY)
   {
      request.price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      if(UseTakeProfitPerOrder)
         request.tp = request.price + TakeProfitPoints * _Point;
   }
   else if(type == ORDER_TYPE_SELL)
   {
      request.price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      if(UseTakeProfitPerOrder)
         request.tp = request.price - TakeProfitPoints * _Point;
   }

   bool ok = OrderSend(request, result);
   if(!ok)
   {
      Print("OrderSend gagal. Retcode=", result.retcode, " Comment=", result.comment);
   }
   else
   {
      if(EnableDetailedLogging)
         Print("Order dibuka. Ticket=", result.order, " Type=", type, " Volume=", request.volume);
   }

   return ok;
}

//+------------------------------------------------------------------+
//| Trailing stop per order                                           |
//+------------------------------------------------------------------+
void ManageTrailingStop()
{
   if(!UseTrailingStop)
      return;

   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket))
         continue;

      string symbol = PositionGetString(POSITION_SYMBOL);
      int    type   = (int)PositionGetInteger(POSITION_TYPE);
      double sl     = PositionGetDouble(POSITION_SL);
      double tp     = PositionGetDouble(POSITION_TP);
      double volume = PositionGetDouble(POSITION_VOLUME);

      MqlTradeRequest req;
      MqlTradeResult  res;
      ZeroMemory(req);
      ZeroMemory(res);

      req.action = TRADE_ACTION_SLTP;
      req.symbol = symbol;
      req.position = ticket;
      req.volume = volume;
      req.tp = tp;

      if(type == POSITION_TYPE_BUY)
      {
         double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
         double newSL = bid - TrailingStopPoints * _Point;
         if(newSL > sl)
         {
            req.sl = newSL;
            OrderSend(req, res);
         }
      }
      else if(type == POSITION_TYPE_SELL)
      {
         double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
         double newSL = ask + TrailingStopPoints * _Point;
         if(sl == 0 || newSL < sl)
         {
            req.sl = newSL;
            OrderSend(req, res);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Close all positions                                                |
//+------------------------------------------------------------------+
void CloseAllOrders()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket))
         continue;

      MqlTradeRequest req;
      MqlTradeResult  res;
      ZeroMemory(req);
      ZeroMemory(res);

      req.action = TRADE_ACTION_DEAL;
      req.position = ticket;
      req.symbol = PositionGetString(POSITION_SYMBOL);
      req.volume = PositionGetDouble(POSITION_VOLUME);
      req.deviation = Slippage;
      req.magic = MagicNumber;

      int posType = (int)PositionGetInteger(POSITION_TYPE);
      if(posType == POSITION_TYPE_BUY)
      {
         req.type = ORDER_TYPE_SELL;
         req.price = SymbolInfoDouble(req.symbol, SYMBOL_BID);
      }
      else
      {
         req.type = ORDER_TYPE_BUY;
         req.price = SymbolInfoDouble(req.symbol, SYMBOL_ASK);
      }

      if(OrderSend(req, res))
      {
         if(EnableDetailedLogging)
            Print("Order ", ticket, " ditutup.");
      }
      else
      {
         Print("Gagal tutup order ", ticket, ". Retcode=", res.retcode);
      }
   }

   lastPrice = 0.0;
}

//+------------------------------------------------------------------+
//| OnTick                                                            |
//+------------------------------------------------------------------+
void OnTick()
{
   ManageTrailingStop();

   // --- Trailing Profit Close global account ---
   static double maxProfit = 0.0;
   double totalProfit = GetTotalProfit();

   if(Use_Trailing_Profit_Close)
   {
      if(totalProfit > Trailing_Profit_Trigger)
      {
         if(totalProfit > maxProfit)
            maxProfit = totalProfit;

         if(totalProfit <= (maxProfit - Trailing_Profit_Lockout))
         {
            Print("Trailing Profit Close triggered. Profit=", totalProfit);
            CloseAllOrders();
            maxProfit = 0.0;
            return;
         }
      }
   }

   // --- Daily loss limit ---
   if(IsDailyLossExceeded())
   {
      Print("Daily loss limit tercapai. EA dihentikan sementara.");
      CloseAllOrders();
      return;
   }

   // --- Grid logic ---
   int totalOrders = PositionsTotal();
   if(totalOrders < MaxOrders)
   {
      double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double adaptiveStep = GetAdaptiveGridStep();

      if(lastPrice == 0.0)
         lastPrice = price;

      if(MathAbs(price - lastPrice) >= adaptiveStep * _Point)
      {
         if(price > lastPrice)
         {
            OpenOrder(ORDER_TYPE_BUY);
         }
         else
         {
            OpenOrder(ORDER_TYPE_SELL);
         }

         lastPrice = price;
      }
   }
}

//+------------------------------------------------------------------+
//| OnInit                                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   if(UseTakeProfitPerOrder)
      Print("Take Profit per order aktif. TP = ", TakeProfitPoints, " points");

   if(EnableSpreadFilter)
      Print("Spread filter aktif. Max spread = ", MaxSpreadPoints, " points");

   if(EnableVolatilityFilter)
      Print("Volatility filter aktif. ATR range = ", MinATRPoints, " - ", MaxATRPoints, " points");

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| OnDeinit                                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Print("EA ditutup. Reason=", reason);
}
//+------------------------------------------------------------------+
