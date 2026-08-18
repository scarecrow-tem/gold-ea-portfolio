//+------------------------------------------------------------------+
//|                                        GoldEA_v3.mq5              |
//|  一新版。旧バージョンで発生したロット複利暴走を防止し、             |
//|  連敗サーキットブレーカー・ADXフィルターを追加。                    |
//|                                                                    |
//|  設計思想:                                                         |
//|   - 「日利20%」のような目標は内部制約に持たない(持続不可能なため)   |
//|   - PF1.7 / 最大DD10% / RR1:3 を実運用の目安とする                  |
//|   - 必ずデモ口座で長期検証してから実弾投入すること                  |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026"
#property version   "1.00"

#include <Trade\Trade.mqh>
CTrade trade;

input group "--- 1. 資金管理・安全装置(最重要) ---"
input double   InpRiskPercent        = 0.3;    // 1トレード最大リスク(%)
input bool     InpUseFixedRiskBase   = true;    // true: 一定期間ごとに更新する固定残高でリスク計算(複利暴走防止)
input int      InpRiskBaseUpdateDays = 30;      // 固定ベース残高を更新する間隔(日)
input double   InpMaxLotAbsolute     = 1.0;     // ロット絶対上限(これは絶対に超えない)
input double   InpMaxSpreadDollar    = 0.50;    // 許容最大スプレッド($)
input double   InpDailyMaxLossPct    = 2.0;     // 1日の最大許容損失(%)
input double   InpMaxDrawdownPct     = 10.0;    // 最大DD到達でEA停止(%)
input int      InpMaxConsecutiveLoss = 6;       // この連敗数に達したら停止

input group "--- 2. ATR・ボラティリティ ---"
input int      InpATRPeriod          = 14;
input double   InpSLMultiplier       = 1.0;     // 損切りATR倍率
input double   InpTPMultiplier       = 3.0;     // 利食いATR倍率(RR1:3)
input double   InpATRMinDollar       = 1.5;     // ATR下限($) 未満は静かすぎ→見送り
input double   InpATRMaxDollar       = 12.0;    // ATR上限($) 超は過熱ボラ→見送り

input group "--- 3. 環境認識・トレンド ---"
input int      InpFastMAPeriod       = 20;
input int      InpSlowMAPeriod       = 50;
input int      InpBreakoutPeriod     = 20;
input bool     InpUseADXFilter       = true;    // ADXでトレンド強度を確認(ダマシ除去)
input int      InpADXPeriod          = 14;
input double   InpADXMinimum         = 25.0;    // これ未満はトレンド弱いとみなし見送り

input group "--- 4. セッションフィルター ---"
input int      InpMondayBlockMinutes = 60;
input int      InpFridayBlockMinutes = 60;

input group "--- 5. Pythonサーバー連携 ---"
input bool     InpUsePythonFilter    = true;    // falseならローカルロジックのみで判断(Python無しでも動作可)
input string   InpSignalURL          = "http://127.0.0.1:5000/signal";
input string   InpCloseURL           = "http://127.0.0.1:5000/close";
input int      InpWebRequestTimeoutMs= 5000;

input group "--- 6. ログ ---"
input string   InpLocalLogFileName   = "goldea_v3_trades.csv"; // Pythonが落ちていても記録される冗長ログ

input group "--- その他 ---"
input ulong    InpMagicNumber        = 20260813;

//==================== グローバル変数 ====================
datetime lastBarTime;
double   dailyStartBalance;
datetime lastDayChecked;
double   equityPeak;
bool     tradingHalted = false;
string   haltReason = "";

double   riskBaseBalance;
datetime riskBaseUpdatedAt;

int      consecutiveLosses = 0;
double   lastKnownPositionProfit = 0;

int      atrHandle = INVALID_HANDLE;
int      fastMAHandle = INVALID_HANDLE;
int      slowMAHandle = INVALID_HANDLE;
int      adxHandle = INVALID_HANDLE;

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   lastBarTime = 0;

   dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   lastDayChecked = TimeCurrent();
   equityPeak = AccountInfoDouble(ACCOUNT_EQUITY);

   riskBaseBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   riskBaseUpdatedAt = TimeCurrent();

   atrHandle    = iATR(_Symbol, _Period, InpATRPeriod);
   fastMAHandle = iMA(_Symbol, _Period, InpFastMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   slowMAHandle = iMA(_Symbol, _Period, InpSlowMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if(InpUseADXFilter)
      adxHandle = iADX(_Symbol, _Period, InpADXPeriod);

   if(atrHandle == INVALID_HANDLE || fastMAHandle == INVALID_HANDLE || slowMAHandle == INVALID_HANDLE)
   {
      Print("GoldEA_v3: インジケーターハンドル作成失敗");
      return(INIT_FAILED);
   }

   InitLocalLog();
   Print("GoldEA_v3 初期化完了。riskBaseBalance=", riskBaseBalance);
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   if(atrHandle != INVALID_HANDLE)    IndicatorRelease(atrHandle);
   if(fastMAHandle != INVALID_HANDLE) IndicatorRelease(fastMAHandle);
   if(slowMAHandle != INVALID_HANDLE) IndicatorRelease(slowMAHandle);
   if(adxHandle != INVALID_HANDLE)    IndicatorRelease(adxHandle);
}

//+------------------------------------------------------------------+
void OnTick()
{
   UpdateRiskBase();
   UpdateDrawdownGuard();
   if(tradingHalted) return;

   // --- 日次サーキットブレーカー ---
   MqlDateTime dt, lastDt;
   TimeToStruct(TimeCurrent(), dt);
   TimeToStruct(lastDayChecked, lastDt);
   if(dt.day != lastDt.day)
   {
      dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      lastDayChecked = TimeCurrent();
   }
   double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   if((dailyStartBalance - currentBalance) >= (dailyStartBalance * (InpDailyMaxLossPct / 100.0)))
      return;

   // --- 連敗サーキットブレーカー ---
   if(consecutiveLosses >= InpMaxConsecutiveLoss)
   {
      if(!tradingHalted)
      {
         tradingHalted = true;
         haltReason = StringFormat("連敗数(%d)が上限に到達", consecutiveLosses);
         Print("GoldEA_v3: ", haltReason, " EAを停止します。");
      }
      return;
   }

   // --- 新しい確定足のみ判定 ---
   datetime currentBarTime = iTime(_Symbol, _Period, 0);
   if(currentBarTime == lastBarTime) return;

   if(PositionsTotal() > 0) return;

   if(!IsSessionAllowed()) { lastBarTime = currentBarTime; return; }

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double spread = ask - bid;
   if(spread > InpMaxSpreadDollar) { lastBarTime = currentBarTime; return; }

   double atr = GetIndicatorValue(atrHandle, 0);
   if(atr <= 0) return;
   if(atr < InpATRMinDollar || atr > InpATRMaxDollar) { lastBarTime = currentBarTime; return; }

   double fastMA0 = GetIndicatorValue(fastMAHandle, 0);
   double fastMA1 = GetIndicatorValue(fastMAHandle, 1);
   double slowMA0 = GetIndicatorValue(slowMAHandle, 0);

   bool isUpTrend   = (fastMA0 > slowMA0) && (fastMA0 > fastMA1);
   bool isDownTrend = (fastMA0 < slowMA0) && (fastMA0 < fastMA1);

   if(InpUseADXFilter)
   {
      double adxVal = GetIndicatorValue(adxHandle, 0); // メインバッファ(ADX本体)
      if(adxVal < InpADXMinimum) { lastBarTime = currentBarTime; return; }
   }

   // --- ブレイクアウト判定: 確定足の終値で確認 ---
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, _Period, 0, InpBreakoutPeriod + 1, rates) < InpBreakoutPeriod + 1) return;

   double highestHigh = rates[1].high;
   double lowestLow   = rates[1].low;
   for(int i = 2; i <= InpBreakoutPeriod; i++)
   {
      if(rates[i].high > highestHigh) highestHigh = rates[i].high;
      if(rates[i].low  < lowestLow)   lowestLow  = rates[i].low;
   }

   bool breakoutUp   = rates[0].close > highestHigh;
   bool breakoutDown = rates[0].close < lowestLow;

   bool candidateBuy  = isUpTrend   && breakoutUp;
   bool candidateSell = isDownTrend && breakoutDown;

   lastBarTime = currentBarTime;

   if(!candidateBuy && !candidateSell) return;
   string action = candidateBuy ? "BUY" : "SELL";

   // --- Pythonへ問い合わせ(任意) ---
   bool go = true;
   double confidence = 0.5;
   if(InpUsePythonFilter)
   {
      if(!AskPythonGo(action, ask, bid, atr, fastMA0, slowMA0, spread, go, confidence))
      {
         Print("GoldEA_v3: Pythonサーバー応答なし。今回は見送り。");
         return;
      }
      if(!go)
      {
         Print("GoldEA_v3: Python判定 NO-GO (conf=", DoubleToString(confidence,2), ")");
         return;
      }
   }

   double slDist = atr * InpSLMultiplier;
   double lot = CalculateLot(slDist);
   if(lot <= 0) return;

   ulong ticket = 0;
   if(action == "BUY")
   {
      double sl = ask - slDist;
      double tp = ask + atr * InpTPMultiplier;
      if(trade.Buy(lot, _Symbol, ask, sl, tp, "GoldEA_v3_BUY"))
      {
         ticket = trade.ResultOrder();
         LogLocalOpen(action, ask, sl, tp, lot, atr, confidence, ticket);
      }
   
---------------------------------------------------------------+
//|                                        GoldEA_v3.mq5              |
//|  一新版。旧バージョンで発生したロット複利暴走を防止し、             |
//|  連敗サーキットブレーカー・ADXフィルターを追加。                    |
//|                                                                    |
//|  設計思想:                                                         |
//|   - 「日利20%」のような目標は内部制約に持たない(持続不可能なため)   |
//|   - PF1.7 / 最大DD10% / RR1:3 を実運
