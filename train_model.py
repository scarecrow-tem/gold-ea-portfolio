"""
train_model.py
Gold (XAUUSD) EA 向けエントリー判定モデルの学習スクリプト

前提:
- 履歴データ(1分足 or 5分足)をCSVで用意
  カラム: time, open, high, low, close, tick_volume, spread
  (MT5の「表示 > シンボルボックス > ヒストリーセンター」または
   スクリプトでエクスポートしたものを想定)
- ATRベースのトリプルバリア法でラベル付け (TP=RR*ATR, SL=1*ATR)
- 目的: 「今エントリーしたらTPが先に来るか」を2値分類

重要:
このモデルは「日利20%」を狙うものではありません。
複利で日利20%を続けると数か月で天文学的な資産になり、現実的にあり得ません。
ここでは PF>1.7 / 最大DD<10% を目安に、質の良いエントリーだけを
選別するフィルターとして設計しています。過学習(カーブフィッティング)に
注意し、必ず未見期間(Walk-Forward)で検証してください。
"""

import numpy as np
import pandas as pd
from sklearn.model_selection import TimeSeriesSplit
from sklearn.ensemble import GradientBoostingClassifier
from sklearn.metrics import classification_report, roc_auc_score
import joblib

RR = 3.0              # Reward:Risk = 1:3 (ご指定の条件)
ATR_PERIOD = 14
LOOKAHEAD_BARS = 200   # ラベル確定までに待つ最大バー数
SPREAD_COST = 0.5      # 最低でも必ずかかる想定スプレッドコスト($、往復分)
                        # ヒストリカルデータは通常mid価格なので、これを引かないと
                        # 実際には勝てないケースまで「勝ち」ラベルになってしまう


def load_data(path: str) -> pd.DataFrame:
    df = pd.read_csv(path, parse_dates=["time"])
    return df.sort_values("time").reset_index(drop=True)


def compute_atr(df: pd.DataFrame, period: int = ATR_PERIOD) -> pd.Series:
    high, low, close = df["high"], df["low"], df["close"]
    tr = pd.concat(
        [
            high - low,
            (high - close.shift()).abs(),
            (low - close.shift()).abs(),
        ],
        axis=1,
    ).max(axis=1)
    return tr.rolling(period).mean()


def compute_rsi(close: pd.Series, period: int = 14) -> pd.Series:
    delta = close.diff()
    gain = delta.clip(lower=0).rolling(period).mean()
    loss = (-delta.clip(upper=0)).rolling(period).mean()
    rs = gain / loss.replace(0, np.nan)
    return 100 - (100 / (1 + rs))


def compute_features(df: pd.DataFrame) -> pd.DataFrame:
    df = df.copy()
    df["atr"] = compute_atr(df)
    df["returns_1"] = df["close"].pct_change(1)
    df["returns_5"] = df["close"].pct_change(5)
    df["volatility_20"] = df["returns_1"].rolling(20).std()
    df["sma_20"] = df["close"].rolling(20).mean()
    df["sma_50"] = df["close"].rolling(50).mean()
    df["sma_ratio"] = df["sma_20"] / df["sma_50"]
    df["rsi_14"] = compute_rsi(df["close"], 14)
    df["hour"] = df["time"].dt.hour
    df["dow"] = df["time"].dt.dayofweek
    df["atr_pct"] = df["atr"] / df["close"]
    return df


def triple_barrier_label(df: pd.DataFrame, rr: float = RR, lookahead: int = LOOKAHEAD_BARS,
                          spread_cost: float = SPREAD_COST) -> np.ndarray:
    """
    各バーでBUY方向を仮定し、ATR*rrの利確とATR*1の損切りの
    どちらが先に到達するかでラベル付け。
    1 = 利確が先(勝ち) / 0 = 損切りが先、またはどちらも未達

    ヒストリカルデータはmid価格想定のため、実際に払う最低スプレッドコストを
    利確ラインに上乗せする(spread_cost分だけ余計に伸びないと「勝ち」にしない)。
    これをしないと、現実には利益にならない小さい値幅の到達まで
    「勝ち」としてカウントしてしまい、モデルが過度に楽観的になる。
    """
    n = len(df)
    labels = np.full(n, np.nan)
    close = df["close"].values
    high = df["high"].values
    low = df["low"].values
    atr = df["atr"].values

    for i in range(n - lookahead):
        if np.isnan(atr[i]) or atr[i] <= 0:
            continue
        entry = close[i]
        tp = entry + atr[i] * rr + spread_cost   # スプレッドコスト分を上乗せ
        sl = entry - atr[i]
        outcome = 0
        for j in range(i + 1, i + 1 + lookahead):
            if high[j] >= tp:
                outcome = 1
                break
            if low[j] <= sl:
                outcome = 0
                break
        labels[i] = outcome
    return labels


FEATURE_COLS = [
    "atr_pct", "returns_1", "returns_5", "volatility_20",
    "sma_ratio", "rsi_14", "hour", "dow",
]


def main():
    df = load_data("xauusd_history.csv")  # ← 自分のヒストリーCSVパスに置き換え
    df = compute_features(df)
    df["label"] = triple_barrier_label(df)
    df = df.dropna().reset_index(drop=True)

    X = df[FEATURE_COLS]
    y = df["label"]

    # 時系列split(ランダムsplitは未来データがリークするため使わない)
    tscv = TimeSeriesSplit(n_splits=5)
    model = GradientBoostingClassifier(
        n_estimators=200, max_depth=3, learning_rate=0.05, subsample=0.8
    )

    for fold, (train_idx, test_idx) in enumerate(tscv.split(X)):
        X_train, X_test = X.iloc[train_idx], X.iloc[test_idx]
        y_train, y_test = y.iloc[train_idx], y.iloc[test_idx]
        model.fit(X_train, y_train)
        preds = model.predict(X_test)
        proba = model.predict_proba(X_test)[:, 1]
        print(f"--- Fold {fold} ---")
        print(classification_report(y_test, preds))
        print("AUC:", roc_auc_score(y_test, proba))

    # 最終モデルは全データで再学習して保存
    model.fit(X, y)
    joblib.dump({"model": model, "features": FEATURE_COLS}, "goldea_model.pkl")
    print("モデルを保存しました -> goldea_model.pkl")


if __name__ == "__main__":
    main()
