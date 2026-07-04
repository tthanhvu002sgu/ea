"""
Regime Analyzer — Phân tích regime thị trường trong các giai đoạn chiến lược đi ngang
Tự động load OHLC M1 + Backtest file → phát hiện sideways periods → phân tích regime chi tiết

Usage:
    python regime_analyzer.py --ohlc XAUUSD_M1_*.csv --backtest "backtest result/file.xlsx"
    python regime_analyzer.py --ohlc XAUUSD_M1_*.csv --periods "2026-03-01,2026-03-30;2026-05-01,2026-05-20"
"""
import pandas as pd
import numpy as np
import plotly.graph_objects as go
from plotly.subplots import make_subplots
import argparse
import os
import sys
import warnings

warnings.filterwarnings("ignore")

# Fix Windows console encoding for emoji/Unicode
if sys.platform == 'win32':
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    sys.stderr.reconfigure(encoding='utf-8', errors='replace')

# ============================================================
# OHLC DATA LOADING
# ============================================================
def load_ohlc(file_path):
    """Load MT5 exported OHLC CSV (tab-separated)."""
    df = pd.read_csv(file_path, sep='\t')
    df.columns = [c.strip('<>') for c in df.columns]
    df['Datetime'] = pd.to_datetime(df['DATE'] + ' ' + df['TIME'], format='%Y.%m.%d %H:%M:%S')
    df = df.rename(columns={'OPEN': 'Open', 'HIGH': 'High', 'LOW': 'Low', 'CLOSE': 'Close',
                            'TICKVOL': 'TickVol', 'VOL': 'Vol', 'SPREAD': 'Spread'})
    df = df.set_index('Datetime').sort_index()
    df = df[['Open', 'High', 'Low', 'Close', 'TickVol']].astype(float)
    return df

def resample_ohlc(df, timeframe='1h'):
    """Resample M1 data to higher timeframe."""
    return df.resample(timeframe).agg({
        'Open': 'first',
        'High': 'max',
        'Low': 'min',
        'Close': 'last',
        'TickVol': 'sum'
    }).dropna()

# ============================================================
# REGIME INDICATORS
# ============================================================
def calc_atr(df, period=14):
    """Average True Range."""
    high = df['High']
    low = df['Low']
    close = df['Close'].shift(1)
    tr = pd.concat([high - low, (high - close).abs(), (low - close).abs()], axis=1).max(axis=1)
    return tr.rolling(period).mean()

def calc_adx(df, period=14):
    """Average Directional Index."""
    high = df['High']
    low = df['Low']
    close = df['Close']

    plus_dm = high.diff()
    minus_dm = -low.diff()

    plus_dm = plus_dm.where((plus_dm > minus_dm) & (plus_dm > 0), 0.0)
    minus_dm = minus_dm.where((minus_dm > plus_dm) & (minus_dm > 0), 0.0)

    tr = pd.concat([
        high - low,
        (high - close.shift(1)).abs(),
        (low - close.shift(1)).abs()
    ], axis=1).max(axis=1)

    atr = tr.ewm(span=period, adjust=False).mean()
    plus_di = 100 * plus_dm.ewm(span=period, adjust=False).mean() / atr
    minus_di = 100 * minus_dm.ewm(span=period, adjust=False).mean() / atr

    dx = 100 * (plus_di - minus_di).abs() / (plus_di + minus_di).replace(0, np.nan)
    adx = dx.ewm(span=period, adjust=False).mean()
    return adx, plus_di, minus_di

def calc_choppiness(df, period=14):
    """Choppiness Index. 100 = perfectly choppy, 38.2 = strong trend."""
    atr = calc_atr(df, 1)  # Use TR (period 1 = raw TR)
    atr_sum = atr.rolling(period).sum()
    highest = df['High'].rolling(period).max()
    lowest = df['Low'].rolling(period).min()
    hl_range = highest - lowest
    hl_range = hl_range.replace(0, np.nan)
    chop = 100 * np.log10(atr_sum / hl_range) / np.log10(period)
    return chop

def calc_hurst(series, max_lag=20):
    """Hurst exponent via R/S analysis (rolling approximation)."""
    lags = range(2, max_lag)
    rs_list = []
    for lag in lags:
        subseries = [series[i:i + lag].values for i in range(0, len(series) - lag, lag)]
        rs_vals = []
        for s in subseries:
            if len(s) < 2:
                continue
            mean = s.mean()
            deviations = s - mean
            cumdev = np.cumsum(deviations)
            r = cumdev.max() - cumdev.min()
            std = s.std(ddof=1)
            if std > 0:
                rs_vals.append(r / std)
        if rs_vals:
            rs_list.append(np.mean(rs_vals))
        else:
            rs_list.append(np.nan)

    rs_arr = np.array(rs_list)
    lag_arr = np.array(list(lags), dtype=float)
    valid = ~np.isnan(rs_arr) & (rs_arr > 0)
    if valid.sum() < 3:
        return np.nan
    log_rs = np.log(rs_arr[valid])
    log_lag = np.log(lag_arr[valid])
    slope, _ = np.polyfit(log_lag, log_rs, 1)
    return slope

def calc_autocorr(returns, lag=1):
    """Lag-1 autocorrelation of returns."""
    return returns.autocorr(lag=lag)

def calc_regime_indicators(df_h1, cache_path=None):
    """Calculate all regime indicators on H1 data (Extended 12+ Features) with Caching."""
    if cache_path and os.path.exists(cache_path):
        try:
            return pd.read_pickle(cache_path)
        except Exception:
            pass

    adx, plus_di, minus_di = calc_adx(df_h1, 14)
    atr = calc_atr(df_h1, 14)
    atr_pct = atr / df_h1['Close'] * 100  # Normalized ATR as % of price
    chop = calc_choppiness(df_h1, 14)
    returns = df_h1['Close'].pct_change()

    # Advanced Features
    sma20 = df_h1['Close'].rolling(20).mean()
    std20 = df_h1['Close'].rolling(20).std()
    bb_width = (4 * std20) / sma20.replace(0, np.nan)

    ema50 = df_h1['Close'].ewm(span=50, adjust=False).mean()
    ema200 = df_h1['Close'].ewm(span=200, adjust=False).mean()
    ema_dist = (ema50 - ema200) / ema200.replace(0, np.nan) * 100

    vol_mean = df_h1['TickVol'].rolling(20).mean() if 'TickVol' in df_h1 else pd.Series(0, index=df_h1.index)
    vol_std = df_h1['TickVol'].rolling(20).std() if 'TickVol' in df_h1 else pd.Series(1, index=df_h1.index)
    vol_zscore = (df_h1['TickVol'] - vol_mean) / vol_std.replace(0, np.nan) if 'TickVol' in df_h1 else pd.Series(0, index=df_h1.index)

    autocorr = returns.rolling(20).apply(lambda x: pd.Series(x).autocorr(lag=1), raw=False)

    # Rolling Hurst approximation (sampled for performance)
    n = len(df_h1)
    hurst_s = pd.Series(np.nan, index=df_h1.index)
    close_vals = df_h1['Close'].values
    if n >= 50:
        step = max(1, n // 500)
        indices = list(range(50, n, step))
        if (n-1) not in indices: indices.append(n-1)
        for idx in indices:
            start_i = max(0, idx - 100)
            hurst_s.iloc[idx] = calc_hurst(pd.Series(close_vals[start_i:idx+1]))
        hurst_s = hurst_s.ffill().bfill()

    res_df = pd.DataFrame({
        'ADX': adx,
        '+DI': plus_di,
        '-DI': minus_di,
        'ATR': atr,
        'ATR%': atr_pct,
        'Choppiness': chop,
        'Returns': returns,
        'BB_Width': bb_width,
        'EMA_Dist%': ema_dist,
        'Vol_ZScore': vol_zscore,
        'Hurst': hurst_s,
        'AutoCorr': autocorr,
    }, index=df_h1.index)

    if cache_path:
        try:
            os.makedirs(os.path.dirname(cache_path), exist_ok=True)
            res_df.to_pickle(cache_path)
        except Exception:
            pass
    return res_df

# ============================================================
# SUPERVISED STRATEGY PROFILING (AI REGIME DNA)
# ============================================================
def map_trades_to_candles(df_ohlc, trades_df):
    """
    Map each closed trade to candle on df_ohlc based on entry time (OpenTime or Time).
    Assigns label Y: +1 (Win), -1 (Loss), 0 (No trade).
    """
    if df_ohlc.empty or trades_df.empty:
        return pd.Series(0, index=df_ohlc.index), pd.Series(0.0, index=df_ohlc.index)

    trade_pnl = pd.Series(0.0, index=df_ohlc.index)
    idx_sorted = df_ohlc.index

    for _, trade in trades_df.iterrows():
        t_entry = trade.get('OpenTime')
        if pd.isna(t_entry):
            t_entry = trade.get('Time')
        if pd.isna(t_entry):
            continue

        try:
            t_entry = pd.to_datetime(t_entry)
            pos = idx_sorted.asof(t_entry)
            if pd.notna(pos):
                pnl = float(trade.get('Profit', 0.0))
                trade_pnl.loc[pos] += pnl
        except Exception:
            continue

    y_series = pd.Series(np.where(trade_pnl > 0, 1, np.where(trade_pnl < 0, -1, 0)), index=df_ohlc.index)
    return y_series, trade_pnl

def tree_to_mql5(clf, feature_names):
    """Convert fitted DecisionTree into MQL5 boolean filter rule."""
    tree = clf.tree_
    win_paths = []

    def dfs(node_id, current_conditions):
        if tree.children_left[node_id] == tree.children_right[node_id]:
            val = tree.value[node_id][0]
            if len(val) > 1 and val[1] > val[0]:  # Majority Win
                win_paths.append(list(current_conditions))
            return

        feat_name = feature_names[tree.feature[node_id]]
        thresh = tree.threshold[node_id]

        dfs(tree.children_left[node_id], current_conditions + [f"({feat_name} <= {thresh:.3f})"])
        dfs(tree.children_right[node_id], current_conditions + [f"({feat_name} > {thresh:.3f})"])

    dfs(0, [])

    if not win_paths:
        return "// AI không tìm thấy luật thắng rõ ràng với độ sâu hiện tại."

    rules_str = [" && ".join(path) for path in win_paths]
    full_cond = rules_str[0] if len(rules_str) == 1 else " || \n    ".join([f"({r})" for r in rules_str])

    mql5_var_map = {
        "ADX": "adx_val", "ATR%": "atr_pct_val", "Choppiness": "chop_val",
        "Returns": "ret_val", "BB_Width": "bb_width_val", "EMA_Dist%": "ema_dist_val",
        "Vol_ZScore": "vol_zscore_val", "Hurst": "hurst_val", "AutoCorr": "autocorr_val"
    }

    code_body = full_cond
    for k, v in mql5_var_map.items():
        code_body = code_body.replace(k, v)

    mql5_code = f"""// --- AI Supervised Regime Filter (Reverse Strategy DNA) ---
// Định nghĩa các chỉ số bối cảnh tại thời điểm nến hiện tại:
// double adx_val = ...;
// double chop_val = ...;
// double hurst_val = ...;

input int RegimeFilterMode = 1; // 0: Block All (Khóa tín hiệu), 1: Shadow Mode (Canary Testing - 0.01 Lot)

bool isWinningRegime = {code_body};

if (!isWinningRegime) {{
    if (RegimeFilterMode == 0) {{
        Print("[Regime Filter] Bối cảnh thị trường không phù hợp -> KHÓA TÍN HIỆU (Block All).");
        return; // Đứng ngoài hoàn toàn
    }} else if (RegimeFilterMode == 1) {{
        Print("[Regime Filter] Bối cảnh xấu -> Chuyển sang SHADOW MODE (Canary Testing). Giảm Volume về tối thiểu 0.01 lot hoặc ghi log lệnh ảo.");
        // Ví dụ áp dụng trong EA của bạn:
        // lot_size = 0.01;
        // is_shadow_trade = true;
    }}
}}"""
    return mql5_code

def compute_range_analysis(X, y, top_features):
    """
    Computes quantile/binned range analysis for top features to avoid point-split overfitting.
    Returns dictionary of zones and their win rates.
    """
    range_stats = {}
    for col in top_features.keys():
        if col not in X.columns:
            continue
        series = X[col]
        try:
            bins = pd.qcut(series, q=3, duplicates='drop')
        except Exception:
            try:
                bins = pd.cut(series, bins=3)
            except Exception:
                continue
        df_temp = pd.DataFrame({'bin': bins.astype(str), 'y': y})
        grouped = df_temp.groupby('bin', observed=False)
        stats = []
        for bin_name, group in grouped:
            total = len(group)
            if total == 0:
                continue
            wins = (group['y'] == 1).sum()
            wr = round(wins / total * 100, 1)
            stats.append({
                "range": bin_name,
                "total_trades": int(total),
                "win_count": int(wins),
                "win_rate": wr
            })
        range_stats[col] = stats
    return range_stats

def evaluate_feature_stability_over_time(X, y, available_cols, max_depth=3, n_periods=4):
    """
    Phân tích độ ổn định ADN theo thời gian (Time-Decay / Yearly Stability Analysis).
    Chia lịch sử giao dịch thành n_periods chu kỳ thời gian liên tiếp để xem luật lọc có bị Concept Drift không.
    """
    try:
        from sklearn.tree import DecisionTreeClassifier
    except ImportError:
        return {"error": "Thiếu thư viện scikit-learn."}

    if len(X) < 40 or len(y) < 40:
        return {"error": "Không đủ số lượng mẫu lệnh (cần tối thiểu 40 lệnh) để chia chu kỳ thời gian."}

    chunk_size = len(X) // n_periods
    period_results = []
    feature_appearance = {col: 0 for col in available_cols}
    feature_weights_sum = {col: 0.0 for col in available_cols}

    for p in range(n_periods):
        start_idx = p * chunk_size
        end_idx = (p + 1) * chunk_size if p < n_periods - 1 else len(X)
        
        X_sub = X.iloc[start_idx:end_idx]
        y_sub = y.iloc[start_idx:end_idx]
        
        if len(y_sub.unique()) < 2:
            continue
            
        min_leaf = max(2, int(len(y_sub) * 0.05))
        clf_sub = DecisionTreeClassifier(max_depth=max_depth, min_samples_leaf=min_leaf, class_weight='balanced', random_state=42)
        clf_sub.fit(X_sub, y_sub)
        acc_sub = clf_sub.score(X_sub, y_sub)
        
        imp_sub = pd.Series(clf_sub.feature_importances_, index=available_cols)
        top_sub = imp_sub[imp_sub > 0].to_dict()
        
        for f, w in top_sub.items():
            feature_appearance[f] += 1
            feature_weights_sum[f] += float(w)
            
        t_start = str(X_sub.index[0])[:10]
        t_end = str(X_sub.index[-1])[:10]
        
        period_results.append({
            "period_idx": p + 1,
            "time_range": f"{t_start} -> {t_end}",
            "sample_count": len(y_sub),
            "win_rate": round((y_sub == 1).sum() / len(y_sub) * 100, 1),
            "accuracy": round(float(acc_sub) * 100, 1),
            "top_features": top_sub
        })

    valid_periods = len(period_results)
    if valid_periods == 0:
        return {"error": "Không thể phân tích ổn định do các chu kỳ bị lệch nhãn."}

    stability_summary = []
    robust_features = []
    drift_warnings = []

    for f in available_cols:
        count = feature_appearance[f]
        if count == 0:
            continue
        consistency_pct = round(count / valid_periods * 100, 1)
        avg_weight = round(feature_weights_sum[f] / valid_periods, 3)
        
        status = "🟢 Robust DNA (Ổn định cao)" if consistency_pct >= 70 else ("🟡 Moderate (Ổn định trung bình)" if consistency_pct >= 40 else "🔴 Concept Drift (Nguy cơ thoái hóa)")
        
        if consistency_pct >= 70:
            robust_features.append(f)
        elif consistency_pct <= 35:
            drift_warnings.append(f)
            
        stability_summary.append({
            "feature": f,
            "appearance_count": f"{count}/{valid_periods} chu kỳ",
            "consistency_pct": consistency_pct,
            "avg_importance": avg_weight,
            "status": status
        })

    stability_summary = sorted(stability_summary, key=lambda x: x["consistency_pct"], reverse=True)

    return {
        "valid_periods": valid_periods,
        "period_details": period_results,
        "stability_summary": stability_summary,
        "robust_features": robust_features,
        "drift_warnings": drift_warnings
    }

def unsupervised_regime_clustering(df_h1, trades_df, n_clusters=3):
    """
    Phân cụm không giám sát (Unsupervised Regime Clustering) bằng K-Means.
    Để thị trường tự động chia thành các cụm trạng thái tự nhiên, sau đó đo lường Win Rate của EA trên từng cụm.
    Đối chứng kép với kết quả Supervised Decision Tree.
    """
    try:
        from sklearn.cluster import KMeans
        from sklearn.preprocessing import StandardScaler
    except ImportError:
        return {"error": "Thiếu thư viện scikit-learn."}

    indicators = calc_regime_indicators(df_h1)
    cluster_cols = ['ADX', 'ATR%', 'Choppiness', 'BB_Width', 'Hurst']
    available_cols = [c for c in cluster_cols if c in indicators.columns]
    
    df_cluster = indicators[available_cols].dropna()
    if len(df_cluster) < 50:
        return {"error": "Không đủ số lượng nến H1 (cần tối thiểu 50 nến) để phân cụm."}

    scaler = StandardScaler()
    X_scaled = scaler.fit_transform(df_cluster)

    kmeans = KMeans(n_clusters=n_clusters, random_state=42, n_init=10)
    clusters = kmeans.fit_predict(X_scaled)
    df_cluster['Cluster'] = clusters

    cluster_profiles = {}
    for c in range(n_clusters):
        sub_c = df_cluster[df_cluster['Cluster'] == c]
        adx_m = sub_c['ADX'].mean()
        atr_m = sub_c['ATR%'].mean()
        chop_m = sub_c['Choppiness'].mean()
        hurst_m = sub_c['Hurst'].mean()
        bb_m = sub_c['BB_Width'].mean() if 'BB_Width' in sub_c else 0
        
        if chop_m > 55 and adx_m < 22:
            name = f"Cụm {c}: Sideways / Ranging (Chop cao, ADX thấp)"
        elif adx_m >= 25 and chop_m < 48:
            name = f"Cụm {c}: Strong Trend (ADX cao, Chop thấp)"
        elif atr_m > df_cluster['ATR%'].mean() * 1.2:
            name = f"Cụm {c}: High Volatility / Turbulence (Biến động mạnh)"
        else:
            name = f"Cụm {c}: Mixed / Transitional (Chuyển tiếp)"

        cluster_profiles[c] = {
            "name": name,
            "candle_count": len(sub_c),
            "pct_time": round(len(sub_c) / len(df_cluster) * 100, 1),
            "adx_mean": round(adx_m, 1),
            "atr_pct_mean": round(atr_m, 3),
            "chop_mean": round(chop_m, 1),
            "hurst_mean": round(hurst_m, 2),
            "bb_width_mean": round(bb_m, 3)
        }

    y_series, trade_pnl = map_trades_to_candles(df_cluster, trades_df)
    trade_mask = y_series != 0
    
    trade_cluster_stats = []
    best_cluster_name = ""
    best_wr = -1.0

    for c in range(n_clusters):
        c_mask = (df_cluster['Cluster'] == c) & trade_mask
        c_trades = y_series[c_mask]
        c_pnl = trade_pnl[c_mask]
        
        total_t = len(c_trades)
        if total_t == 0:
            continue
            
        wins = (c_trades == 1).sum()
        losses = (c_trades == -1).sum()
        wr = round(wins / total_t * 100, 1)
        net_pnl = round(float(c_pnl.sum()), 2)
        
        if wr > best_wr and total_t >= 10:
            best_wr = wr
            best_cluster_name = cluster_profiles[c]["name"]

        trade_cluster_stats.append({
            "cluster_id": c,
            "cluster_name": cluster_profiles[c]["name"],
            "total_trades": int(total_t),
            "win_count": int(wins),
            "loss_count": int(losses),
            "win_rate": wr,
            "net_pnl": net_pnl,
            "avg_pnl": round(net_pnl / total_t, 2) if total_t > 0 else 0
        })

    return {
        "success": True,
        "n_clusters": n_clusters,
        "cluster_profiles": list(cluster_profiles.values()),
        "trade_cluster_stats": trade_cluster_stats,
        "best_cluster_name": best_cluster_name,
        "best_win_rate": best_wr
    }

def extract_strategy_dna(df_h1, trades_df, max_depth=3, cache_path=None, strategy_name=None):
    """
    Supervised Strategy Profiling with Anti-Overfitting (Regularization + Purged CV + OOS Holdout).
    Trains DecisionTree to classify Win (+1) vs Loss (-1) candles based on context features.
    """
    try:
        from sklearn.tree import DecisionTreeClassifier, export_text
        from sklearn.model_selection import cross_val_score
    except ImportError:
        return {"error": "Thiếu thư viện scikit-learn. Vui lòng chạy `pip install scikit-learn`."}

    indicators = calc_regime_indicators(df_h1, cache_path=cache_path)
    y_series, _ = map_trades_to_candles(indicators, trades_df)

    trade_mask = y_series != 0
    if trade_mask.sum() < 10:
        return {"error": f"Không đủ mẫu giao dịch khớp với chuỗi OHLC (tìm thấy {trade_mask.sum()} lệnh, cần tối thiểu 10)."}

    feature_cols = ['ADX', 'ATR%', 'Choppiness', 'Returns', 'BB_Width', 'EMA_Dist%', 'Vol_ZScore', 'Hurst', 'AutoCorr']
    available_cols = [c for c in feature_cols if c in indicators.columns]

    X = indicators.loc[trade_mask, available_cols].dropna()
    y = y_series.loc[X.index]

    if len(y.unique()) < 2:
        val = "THẮNG" if y.iloc[0] > 0 else "THUA"
        return {"error": f"Toàn bộ {len(y)} lệnh khớp đều là lệnh {val}. Cần cả lệnh Thắng và Thua để phân tích đối chiếu."}

    # ── ITEM 1: Strict Out-of-Sample (OOS) Holdout & Purged CV ──
    oos_size = max(5, int(len(y) * 0.20)) if len(y) >= 25 else 0
    if oos_size > 0:
        X_train = X.iloc[:-oos_size]
        y_train = y.iloc[:-oos_size]
        X_oos = X.iloc[-oos_size:]
        y_oos = y.iloc[-oos_size:]
    else:
        X_train, y_train = X, y
        X_oos, y_oos = X, y

    min_leaf = max(3, int(len(y_train) * 0.03))
    clf_train = DecisionTreeClassifier(max_depth=max_depth, min_samples_leaf=min_leaf, class_weight='balanced', random_state=42)
    clf_train.fit(X_train, y_train)

    train_acc = clf_train.score(X_train, y_train)
    oos_acc = clf_train.score(X_oos, y_oos) if oos_size > 0 else train_acc

    # Purged / Embargo Time-Series CV on X_train to prevent rolling window leakage
    cv_folds = min(5, len(y_train) // 5)
    if cv_folds >= 2:
        purged_scores = []
        fold_size = len(y_train) // cv_folds
        embargo_gap = max(2, int(len(y_train) * 0.03))
        for f in range(cv_folds):
            val_start = f * fold_size
            val_end = (f + 1) * fold_size if f < cv_folds - 1 else len(y_train)
            
            train_idx = [i for i in range(len(y_train)) if i < val_start - embargo_gap or i > val_end + embargo_gap]
            val_idx = list(range(val_start, val_end))
            
            if len(train_idx) < 10 or len(val_idx) < 2:
                continue
            clf_fold = DecisionTreeClassifier(max_depth=max_depth, min_samples_leaf=min_leaf, class_weight='balanced', random_state=42)
            clf_fold.fit(X_train.iloc[train_idx], y_train.iloc[train_idx])
            purged_scores.append(clf_fold.score(X_train.iloc[val_idx], y_train.iloc[val_idx]))
        cv_acc = float(np.mean(purged_scores)) if purged_scores else float(train_acc)
    else:
        cv_acc = float(train_acc)

    # Fit final tree on full X for MQL5 code generation
    clf = DecisionTreeClassifier(max_depth=max_depth, min_samples_leaf=min_leaf, class_weight='balanced', random_state=42)
    clf.fit(X, y)

    imp = pd.Series(clf.feature_importances_, index=available_cols).sort_values(ascending=False)
    top_features = imp[imp > 0].to_dict()

    tree_text = export_text(clf, feature_names=available_cols)
    mql5_code = tree_to_mql5(clf, available_cols)

    win_context = X[y == 1].mean().to_dict()
    loss_context = X[y == -1].mean().to_dict()

    features_csv_rel = ""
    if strategy_name:
        try:
            base_name = os.path.splitext(strategy_name)[0]
            out_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "backtest result")
            os.makedirs(out_dir, exist_ok=True)
            features_csv_path = os.path.join(out_dir, f"{base_name}_regime_features.csv")
            
            export_df = X.copy()
            export_df['Regime_Label'] = y.map({1: 'WIN', -1: 'LOSS'})
            export_df.to_csv(features_csv_path, index_label="Time")
            features_csv_rel = f"backtest result/{base_name}_regime_features.csv"
        except Exception as e:
            print("Error exporting features CSV:", e)

    stability_res = evaluate_feature_stability_over_time(X, y, available_cols, max_depth=max_depth)
    clustering_res = unsupervised_regime_clustering(df_h1, trades_df, n_clusters=3)

    return {
        "success": True,
        "sample_count": len(y),
        "win_count": int((y == 1).sum()),
        "loss_count": int((y == -1).sum()),
        "accuracy": float(train_acc),
        "cv_accuracy": float(cv_acc),
        "oos_accuracy": float(oos_acc),
        "oos_sample_count": int(oos_size),
        "oos_status": "PASS (OOS >= 58%)" if oos_acc >= 0.58 else ("CAUTION (OOS 50-58%)" if oos_acc >= 0.50 else "FAIL (< 50% - Overfit)"),
        "min_samples_leaf": min_leaf,
        "top_features": top_features,
        "tree_text": tree_text,
        "mql5_code": mql5_code,
        "win_context": win_context,
        "loss_context": loss_context,
        "features_csv_path": features_csv_rel,
        "range_analysis": compute_range_analysis(X, y, top_features),
        "feature_stability_analysis": stability_res,
        "unsupervised_clustering_analysis": clustering_res
    }


# ============================================================
# REGIME PERSISTENT REGISTRY (Lưu trữ ADN chiến lược)
# ============================================================
import json
REGISTRY_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "backtest result", "strategy_regime_registry.json")

def load_regime_registry(strategy_name=None):
    try:
        if os.path.exists(REGISTRY_FILE):
            with open(REGISTRY_FILE, "r", encoding="utf-8") as f:
                data = json.load(f)
            if strategy_name:
                return data.get(strategy_name)
            return data
    except Exception:
        pass
    return None if strategy_name else {}

def save_regime_registry(strategy_name, dna_res, symbol_ohlc, timeframe):
    try:
        os.makedirs(os.path.dirname(REGISTRY_FILE), exist_ok=True)
        data = {}
        if os.path.exists(REGISTRY_FILE):
            try:
                with open(REGISTRY_FILE, "r", encoding="utf-8") as f:
                    data = json.load(f)
            except Exception:
                data = {}
        import datetime
        entry = {
            "last_updated": datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
            "symbol_ohlc": symbol_ohlc,
            "timeframe": timeframe,
            "accuracy": dna_res.get("accuracy", 0),
            "cv_accuracy": dna_res.get("cv_accuracy", 0),
            "oos_accuracy": dna_res.get("oos_accuracy", 0),
            "oos_status": dna_res.get("oos_status", "N/A"),
            "sample_count": dna_res.get("sample_count", 0),
            "win_count": dna_res.get("win_count", 0),
            "loss_count": dna_res.get("loss_count", 0),
            "top_features": dna_res.get("top_features", {}),
            "tree_text": dna_res.get("tree_text", ""),
            "mql5_code": dna_res.get("mql5_code", ""),
            "win_context": dna_res.get("win_context", {}),
            "loss_context": dna_res.get("loss_context", {}),
            "features_csv_path": dna_res.get("features_csv_path", ""),
            "range_analysis": dna_res.get("range_analysis", {}),
            "feature_stability_analysis": dna_res.get("feature_stability_analysis", {}),
            "unsupervised_clustering_analysis": dna_res.get("unsupervised_clustering_analysis", {})
        }
        data[strategy_name] = entry
        with open(REGISTRY_FILE, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
        return True
    except Exception as e:
        print("Error saving registry:", e)
        return False


WATCHLIST_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "backtest result", "live_watchlist.json")

def load_live_watchlist():
    try:
        if os.path.exists(WATCHLIST_FILE):
            with open(WATCHLIST_FILE, "r", encoding="utf-8") as f:
                return json.load(f)
    except Exception:
        pass
    return [{"symbol": "GC=F", "source": "Yahoo Finance API (REST API)", "timeframe": "1h"}]

def save_live_watchlist(watchlist):
    try:
        os.makedirs(os.path.dirname(WATCHLIST_FILE), exist_ok=True)
        with open(WATCHLIST_FILE, "w", encoding="utf-8") as f:
            json.dump(watchlist, f, ensure_ascii=False, indent=2)
        return True
    except Exception as e:
        print("Error saving watchlist:", e)
        return False


MONITOR_HISTORY_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "backtest result", "live_monitor_history.json")

def load_live_monitor_history(limit=100):
    try:
        if os.path.exists(MONITOR_HISTORY_FILE):
            with open(MONITOR_HISTORY_FILE, "r", encoding="utf-8") as f:
                history = json.load(f)
                return history[-limit:] if isinstance(history, list) else []
    except Exception:
        pass
    return []

def save_live_monitor_history(history):
    try:
        os.makedirs(os.path.dirname(MONITOR_HISTORY_FILE), exist_ok=True)
        if len(history) > 1000:
            history = history[-1000:]
        with open(MONITOR_HISTORY_FILE, "w", encoding="utf-8") as f:
            json.dump(history, f, ensure_ascii=False, indent=2)
        return True
    except Exception as e:
        print("Error saving monitor history:", e)
        return False

def log_live_monitor_eval(symbol, timeframe, eval_res):
    try:
        import datetime
        history = load_live_monitor_history(limit=1000)
        latest_time = eval_res.get("latest_time", datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"))
        
        if history and history[-1].get("symbol") == symbol and history[-1].get("timeframe") == timeframe and history[-1].get("latest_time") == latest_time:
            return False
            
        record = {
            "timestamp_logged": datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
            "latest_time": latest_time,
            "symbol": symbol,
            "timeframe": timeframe,
            "adx": eval_res.get("latest_bar", {}).get("ADX", 0),
            "hurst": eval_res.get("latest_bar", {}).get("Hurst", 0.5),
            "choppiness": eval_res.get("latest_bar", {}).get("Choppiness", 50),
            "bb_width": eval_res.get("latest_bar", {}).get("BB_Width", 0),
            "evaluations": {
                k: {"status": v["status"], "match_pct": v["match_pct"]}
                for k, v in eval_res.get("evaluations", {}).items()
            }
        }
        history.append(record)
        save_live_monitor_history(history)
        return True
    except Exception as e:
        print("Error logging monitor eval:", e)
        return False



def fetch_live_ohlc(source_type, symbol="XAUUSD=X", timeframe="1h", limit=500):
    """
    Fetches real-time OHLC data from live APIs or MetaTrader 5 terminal.
    """
    if source_type == "Yahoo Finance API (REST API)":
        try:
            import yfinance as yf
        except ImportError:
            return None, "Thiếu gói yfinance. Vui lòng chạy `pip install yfinance`."
        
        interval_map = {"1h": "1h", "4h": "1h", "15m": "15m", "5m": "5m", "1d": "1d"}
        yf_interval = interval_map.get(timeframe, "1h")
        period = "1mo" if yf_interval in ["1h", "15m", "5m"] else "3mo"
        
        try:
            ticker = yf.Ticker(symbol)
            df = ticker.history(period=period, interval=yf_interval)
            if df.empty:
                return None, f"Không lấy được dữ liệu từ Yahoo Finance cho mã {symbol}. Vui lòng kiểm tra lại mã (ví dụ: XAUUSD=X, GC=F, EURUSD=X, BTC-USD)."
            
            df = df.rename(columns={"Volume": "TickVol"})
            df.index.name = "Time"
            if df.index.tz is not None:
                df.index = df.index.tz_localize(None)
            
            if timeframe == "4h" and yf_interval == "1h":
                df = resample_ohlc(df, "4h")
            return df.tail(limit), None
        except Exception as e:
            return None, f"Lỗi kết nối Yahoo Finance API: {str(e)}"

    elif source_type == "MetaTrader 5 (Direct Terminal Bridge)":
        try:
            import MetaTrader5 as mt5
        except ImportError:
            return None, "Thiếu gói MetaTrader5. Vui lòng chạy `pip install MetaTrader5`."
            
        if not mt5.initialize():
            err = mt5.last_error()
            return None, f"Không thể kết nối đến terminal MetaTrader 5 đang chạy. Lỗi: {err}. Hãy đảm bảo MT5 đang mở trên máy tính."
            
        tf_map = {"1m": mt5.TIMEFRAME_M1, "5m": mt5.TIMEFRAME_M5, "15m": mt5.TIMEFRAME_M15, "1h": mt5.TIMEFRAME_H1, "4h": mt5.TIMEFRAME_H4, "1d": mt5.TIMEFRAME_D1}
        mt5_tf = tf_map.get(timeframe, mt5.TIMEFRAME_H1)
        
        rates = mt5.copy_rates_from_pos(symbol, mt5_tf, 0, limit)
        mt5.shutdown()
        
        if rates is None or len(rates) == 0:
            return None, f"Không lấy được dữ liệu MT5 cho mã {symbol}. Kiểm tra lại tên mã trong Market Watch MT5 (ví dụ: XAUUSD, XAUUSD.m, EURUSD)."
            
        df = pd.DataFrame(rates)
        df['Time'] = pd.to_datetime(df['time'], unit='s')
        df = df.rename(columns={'open': 'Open', 'high': 'High', 'low': 'Low', 'close': 'Close', 'tick_volume': 'TickVol'})
        df = df.set_index('Time')[['Open', 'High', 'Low', 'Close', 'TickVol']]
        return df, None

    elif source_type.startswith("File CSV"):
        target = symbol
        if not os.path.exists(target):
            alt_target = os.path.join(os.path.dirname(os.path.abspath(__file__)), "backtest result", os.path.basename(symbol))
            if os.path.exists(alt_target):
                target = alt_target
            else:
                return None, f"File {symbol} không tồn tại."
        df_m1 = load_ohlc(target)
        df = resample_ohlc(df_m1, timeframe)
        return df.tail(limit), None
        
    return None, "Nguồn dữ liệu không hợp lệ."


def fetch_historical_ohlc(symbol="XAUUSD=X", timeframe="1h", period="2y"):
    """
    Fetches historical OHLC data from Yahoo Finance for strategy profiling.
    """
    try:
        import yfinance as yf
    except ImportError:
        return None, "Thiếu gói yfinance."
    
    interval_map = {"1h": "1h", "4h": "1h", "15m": "15m", "5m": "5m", "1d": "1d"}
    yf_interval = interval_map.get(timeframe, "1h")
    
    if yf_interval in ["15m", "5m"]:
        period = "60d"
        
    try:
        ticker = yf.Ticker(symbol)
        df = ticker.history(period=period, interval=yf_interval)
        if df.empty:
            return None, f"Không lấy được dữ liệu từ Yahoo Finance cho mã {symbol}."
        
        df = df.rename(columns={"Volume": "TickVol"})
        df.index.name = "Time"
        if df.index.tz is not None:
            df.index = df.index.tz_localize(None)
        
        if timeframe == "4h" and yf_interval == "1h":
            df = resample_ohlc(df, "4h")
        return df, None
    except Exception as e:
        return None, f"Lỗi Yahoo Finance: {str(e)}"



def evaluate_live_market(df_h1, registry_data):
    """
    Evaluates current live market regime (latest candle) against saved strategies in registry.
    """
    if df_h1.empty or not registry_data:
        return {}
    
    ind_df = calc_regime_indicators(df_h1)
    latest_bar = ind_df.iloc[-1].to_dict()
    latest_time = str(ind_df.index[-1])
    
    results = {}
    for strat_name, profile in registry_data.items():
        top_feats = profile.get("top_features", {})
        win_ctx = profile.get("win_context", {})
        loss_ctx = profile.get("loss_context", {})
        
        status = "PASS"
        reasons = []
        score = 0
        total_weight = 0
        
        for feat, weight in top_feats.items():
            if feat not in latest_bar or feat not in win_ctx:
                continue
            val = latest_bar[feat]
            w_mean = win_ctx[feat]
            l_mean = loss_ctx.get(feat, w_mean)
            
            dist_win = abs(val - w_mean)
            dist_loss = abs(val - l_mean)
            
            total_weight += weight
            if dist_win <= dist_loss:
                score += weight
                reasons.append(f"🟢 `{feat}` = {val:.2f} (Khớp vùng Thắng ~{w_mean:.2f})")
            else:
                reasons.append(f"🔴 `{feat}` = {val:.2f} (Lệch sang vùng Thua ~{l_mean:.2f})")
        
        match_pct = round((score / total_weight * 100), 1) if total_weight > 0 else 50.0
        if match_pct >= 60.0:
            status = "PASS"
        elif match_pct >= 40.0:
            status = "CAUTION"
        else:
            status = "BLOCK"
            
        results[strat_name] = {
            "status": status,
            "match_pct": match_pct,
            "reasons": reasons,
            "latest_time": latest_time,
            "timeframe": profile.get("timeframe", "1h"),
            "accuracy": profile.get("accuracy", 0),
            "cv_accuracy": profile.get("cv_accuracy", 0)
        }
    return {"latest_bar": latest_bar, "latest_time": latest_time, "evaluations": results}



# ============================================================
# SIDEWAYS PERIOD DETECTION (from backtest)
# ============================================================
def detect_sideways_from_backtest(file_path, threshold_pct=5.0, min_days=15):
    """Re-use the same logic from strategy_analyzer."""
    try:
        from openpyxl.worksheet.cell_range import CellRange
        CellRange.min_row.max = 100000000
        CellRange.max_row.max = 100000000
    except ImportError:
        pass

    if file_path.lower().endswith('.csv'):
        try:
            raw = pd.read_csv(file_path, header=None, encoding='utf-16le', sep='\t')
        except Exception:
            raw = pd.read_csv(file_path, header=None)
    else:
        try:
            raw = pd.read_excel(file_path, engine='calamine', header=None)
        except Exception:
            raw = pd.read_excel(file_path, engine='openpyxl', header=None)

    # Find Deals table
    deals_mask = raw[0].astype(str).str.strip() == 'Deals'
    if not deals_mask.any():
        print("ERROR: Không tìm thấy bảng Deals trong file backtest.")
        return []

    deals_start = raw[deals_mask].index[0]
    header_idx = deals_start + 1
    df = raw.iloc[header_idx + 1:].copy()
    df.columns = raw.iloc[header_idx].values

    col_map = {}
    for c in df.columns:
        cs = str(c).strip().lower()
        if cs == 'time': col_map[c] = 'Time'
        elif cs == 'direction': col_map[c] = 'Direction'
        elif cs == 'profit': col_map[c] = 'Profit'
        elif cs == 'balance': col_map[c] = 'Balance'
    df.rename(columns=col_map, inplace=True)

    df['Time'] = pd.to_datetime(df['Time'], errors='coerce')
    df.dropna(subset=['Time'], inplace=True)
    for nc in ['Profit', 'Balance']:
        if nc in df.columns:
            df[nc] = pd.to_numeric(df[nc], errors='coerce')

    if 'Direction' in df.columns:
        trades = df[df['Direction'].astype(str).str.strip().str.lower() == 'out'].copy()
    else:
        trades = df[df['Profit'].notna() & (df['Profit'] != 0)].copy()

    if 'Balance' not in trades.columns or trades.empty:
        return []

    bal = trades[['Time', 'Balance']].dropna().sort_values('Time').reset_index(drop=True)
    periods = []
    n = len(bal)
    i = 0
    while i < n:
        start_bal = bal['Balance'].iloc[i]
        start_time = bal['Time'].iloc[i]
        j = i
        max_b = start_bal
        min_b = start_bal
        best_j = i
        while j < n:
            b = bal['Balance'].iloc[j]
            if b > max_b: max_b = b
            if b < min_b: min_b = b
            if (max_b - min_b) / start_bal > (threshold_pct / 100.0):
                break
            best_j = j
            j += 1
        end_time = bal['Time'].iloc[best_j]
        duration = (end_time - start_time).days
        if duration >= min_days:
            periods.append({
                'start': start_time,
                'end': end_time,
                'duration': duration,
                'range_pct': (max_b - min_b) / start_bal * 100
            })
            i = best_j + 1
        else:
            i += 1
    return periods

# ============================================================
# REGIME CLASSIFICATION
# ============================================================
def classify_regime(adx_mean, atr_pct_mean, chop_mean, hurst, autocorr):
    """Classify the market regime based on indicator values."""
    tags = []
    label = ""

    # ADX-based
    if adx_mean < 20:
        tags.append("No Trend")
    elif adx_mean < 30:
        tags.append("Weak Trend")
    else:
        tags.append("Strong Trend")

    # Choppiness-based
    if chop_mean > 61.8:
        tags.append("Choppy")
    elif chop_mean < 38.2:
        tags.append("Trending")
    else:
        tags.append("Transitional")

    # Hurst-based
    if not np.isnan(hurst):
        if hurst < 0.45:
            tags.append("Mean-Reverting")
        elif hurst > 0.55:
            tags.append("Persistent/Trending")
        else:
            tags.append("Random Walk")

    # ATR-based volatility
    if atr_pct_mean < 0.15:
        tags.append("Low Vol")
    elif atr_pct_mean > 0.35:
        tags.append("High Vol")
    else:
        tags.append("Normal Vol")

    # Autocorrelation
    if not np.isnan(autocorr):
        if autocorr < -0.1:
            tags.append("Anti-Persistent")
        elif autocorr > 0.1:
            tags.append("Momentum")

    # Composite label
    if adx_mean < 20 and chop_mean > 55:
        if atr_pct_mean < 0.2:
            label = "A: Sideways Narrow Range"
        else:
            label = "B: High Vol Choppy"
    elif adx_mean >= 20 and chop_mean < 50:
        label = "D: Trending"
    elif adx_mean < 25 and chop_mean > 45:
        label = "C: Slow Drift / Weak Trend"
    else:
        label = "E: Mixed / Transitional"

    return label, tags

# ============================================================
# ANALYSIS & VISUALIZATION
# ============================================================
def analyze_period(df_m1, period, period_idx, output_dir):
    """Full regime analysis for a single sideways period."""
    start = period['start']
    end = period['end']

    # Slice OHLC data for this period
    mask = (df_m1.index >= start) & (df_m1.index <= end)
    segment = df_m1[mask]

    if segment.empty or len(segment) < 100:
        return None

    # Resample to H1 and H4
    h1 = resample_ohlc(segment, '1h')
    h4 = resample_ohlc(segment, '4h')

    if len(h1) < 20:
        return None

    # Calculate indicators on H1
    indicators = calc_regime_indicators(h1)

    # Statistics
    adx_mean = indicators['ADX'].dropna().mean()
    atr_pct_mean = indicators['ATR%'].dropna().mean()
    chop_mean = indicators['Choppiness'].dropna().mean()
    returns = indicators['Returns'].dropna()
    hurst = calc_hurst(h1['Close'].dropna())
    autocorr = calc_autocorr(returns)

    label, tags = classify_regime(adx_mean, atr_pct_mean, chop_mean, hurst, autocorr)

    result = {
        'period_idx': period_idx,
        'start': start,
        'end': end,
        'duration': period['duration'],
        'range_pct': period.get('range_pct', 0),
        'regime_label': label,
        'regime_tags': tags,
        'adx_mean': adx_mean,
        'adx_median': indicators['ADX'].dropna().median(),
        'atr_pct_mean': atr_pct_mean,
        'chop_mean': chop_mean,
        'chop_median': indicators['Choppiness'].dropna().median(),
        'hurst': hurst,
        'autocorr': autocorr,
        'return_mean': returns.mean(),
        'return_std': returns.std(),
        'price_start': segment['Close'].iloc[0],
        'price_end': segment['Close'].iloc[-1],
        'price_high': segment['High'].max(),
        'price_low': segment['Low'].min(),
        'total_bars_h1': len(h1),
    }

    # ── Generate interactive chart ──
    fig = make_subplots(
        rows=4, cols=1, shared_xaxes=True,
        row_heights=[0.45, 0.18, 0.18, 0.19],
        vertical_spacing=0.03,
        subplot_titles=[
            f"XAUUSD H1 — Giai đoạn {period_idx+1}: {start.strftime('%d/%m/%Y')} → {end.strftime('%d/%m/%Y')} ({period['duration']} ngày)",
            "ADX & Directional Index",
            "Choppiness Index",
            "ATR % (Normalized Volatility)"
        ]
    )

    # Candlestick
    fig.add_trace(go.Candlestick(
        x=h1.index, open=h1['Open'], high=h1['High'], low=h1['Low'], close=h1['Close'],
        name='OHLC H1', increasing_line_color='#00d4aa', decreasing_line_color='#ff4757'
    ), row=1, col=1)

    # Bollinger Bands on H1
    sma20 = h1['Close'].rolling(20).mean()
    std20 = h1['Close'].rolling(20).std()
    fig.add_trace(go.Scatter(x=h1.index, y=sma20, name='SMA20', line=dict(color='#ffa502', width=1)), row=1, col=1)
    fig.add_trace(go.Scatter(x=h1.index, y=sma20 + 2*std20, name='BB Upper', line=dict(color='#888', width=1, dash='dot')), row=1, col=1)
    fig.add_trace(go.Scatter(x=h1.index, y=sma20 - 2*std20, name='BB Lower', line=dict(color='#888', width=1, dash='dot'),
                             fill='tonexty', fillcolor='rgba(136,136,136,0.08)'), row=1, col=1)

    # ADX panel
    fig.add_trace(go.Scatter(x=indicators.index, y=indicators['ADX'], name='ADX', line=dict(color='#7c4dff', width=2)), row=2, col=1)
    fig.add_trace(go.Scatter(x=indicators.index, y=indicators['+DI'], name='+DI', line=dict(color='#00d4aa', width=1, dash='dot')), row=2, col=1)
    fig.add_trace(go.Scatter(x=indicators.index, y=indicators['-DI'], name='-DI', line=dict(color='#ff4757', width=1, dash='dot')), row=2, col=1)
    fig.add_hline(y=20, line_dash='dash', line_color='yellow', opacity=0.5, row=2, col=1)
    fig.add_hline(y=30, line_dash='dash', line_color='orange', opacity=0.3, row=2, col=1)

    # Choppiness panel
    fig.add_trace(go.Scatter(x=indicators.index, y=indicators['Choppiness'], name='CHOP', line=dict(color='#ff6348', width=2),
                             fill='tozeroy', fillcolor='rgba(255,99,72,0.1)'), row=3, col=1)
    fig.add_hline(y=61.8, line_dash='dash', line_color='red', opacity=0.5, row=3, col=1, annotation_text="Choppy >61.8")
    fig.add_hline(y=38.2, line_dash='dash', line_color='green', opacity=0.5, row=3, col=1, annotation_text="Trend <38.2")

    # ATR% panel
    fig.add_trace(go.Scatter(x=indicators.index, y=indicators['ATR%'], name='ATR%', line=dict(color='#1e90ff', width=2),
                             fill='tozeroy', fillcolor='rgba(30,144,255,0.1)'), row=4, col=1)

    # Layout
    fig.update_layout(
        height=1000, template='plotly_dark',
        showlegend=True,
        legend=dict(orientation='h', y=-0.05, font=dict(size=10)),
        margin=dict(l=60, r=30, t=50, b=50),
        xaxis_rangeslider_visible=False,
    )
    fig.update_xaxes(type='category', nticks=30, row=1, col=1)
    for r in range(1, 5):
        fig.update_xaxes(type='category', nticks=30, row=r, col=1)

    # Add regime label annotation
    fig.add_annotation(
        text=f"<b>Regime: {label}</b><br>ADX={adx_mean:.1f} | CHOP={chop_mean:.1f} | ATR%={atr_pct_mean:.3f} | Hurst={hurst:.2f}",
        xref="paper", yref="paper", x=0.01, y=0.98,
        showarrow=False, font=dict(size=13, color='#ffa502'),
        bgcolor='rgba(0,0,0,0.7)', bordercolor='#ffa502', borderwidth=1,
    )

    chart_path = os.path.join(output_dir, f"regime_period_{period_idx+1}.html")
    fig.write_html(chart_path, include_plotlyjs='cdn')
    result['chart_path'] = chart_path

    return result

def analyze_non_sideways(df_m1, sideways_periods):
    """Calculate regime indicators for the 'good' periods (when EA is profitable)."""
    if not sideways_periods:
        return None

    good_mask = pd.Series(True, index=df_m1.index)
    for p in sideways_periods:
        good_mask &= ~((df_m1.index >= p['start']) & (df_m1.index <= p['end']))

    good_segment = df_m1[good_mask]
    if good_segment.empty or len(good_segment) < 200:
        return None

    h1 = resample_ohlc(good_segment, '1h')
    if len(h1) < 20:
        return None

    indicators = calc_regime_indicators(h1)
    returns = indicators['Returns'].dropna()

    return {
        'adx_mean': indicators['ADX'].dropna().mean(),
        'atr_pct_mean': indicators['ATR%'].dropna().mean(),
        'chop_mean': indicators['Choppiness'].dropna().mean(),
        'hurst': calc_hurst(h1['Close'].dropna()),
        'autocorr': calc_autocorr(returns),
    }

# ============================================================
# REPORT GENERATION
# ============================================================
def generate_report(results, comparison, output_dir):
    """Generate comprehensive Markdown report."""
    md = "# 🔬 Regime Analysis Report — Phân Tích Regime Các Giai Đoạn Đi Ngang\n\n"
    md += f"Số giai đoạn phân tích: **{len(results)}**\n\n"

    # ── Summary table ──
    md += "## 📊 Tổng Quan Regime Từng Giai Đoạn\n\n"
    md += "| # | Từ | Đến | Ngày | Regime | ADX | CHOP | ATR% | Hurst | AutoCorr |\n"
    md += "|---|-----|------|------|--------|-----|------|------|-------|----------|\n"
    for r in results:
        h = r['hurst']
        ac = r['autocorr']
        md += (f"| {r['period_idx']+1} | {r['start'].strftime('%d/%m/%y')} | {r['end'].strftime('%d/%m/%y')} "
               f"| {r['duration']} | {r['regime_label']} "
               f"| {r['adx_mean']:.1f} | {r['chop_mean']:.1f} | {r['atr_pct_mean']:.3f} "
               f"| {h:.2f} | {ac:.3f} |\n")

    # ── Comparison with good periods ──
    if comparison:
        md += "\n## 🆚 So Sánh Regime: Giai Đoạn Đi Ngang vs Giai Đoạn Sinh Lời\n\n"
        md += "| Chỉ Số | Giai đoạn đi ngang (TB) | Giai đoạn sinh lời | Chênh lệch |\n"
        md += "|--------|------------------------|-------------------|------------|\n"

        avg_sideways = {
            'ADX': np.mean([r['adx_mean'] for r in results]),
            'CHOP': np.mean([r['chop_mean'] for r in results]),
            'ATR%': np.mean([r['atr_pct_mean'] for r in results]),
            'Hurst': np.nanmean([r['hurst'] for r in results]),
            'AutoCorr': np.nanmean([r['autocorr'] for r in results]),
        }

        for key, val in avg_sideways.items():
            comp_key = key.lower().replace('%', '_pct').replace(' ', '_')
            comp_val = comparison.get(f"{comp_key}_mean", comparison.get(comp_key, np.nan))
            diff = val - comp_val if not np.isnan(comp_val) else np.nan
            diff_str = f"{diff:+.3f}" if not np.isnan(diff) else "N/A"
            md += f"| {key} | {val:.3f} | {comp_val:.3f} | {diff_str} |\n"

    # ── Detailed per-period analysis ──
    md += "\n## 📋 Chi Tiết Từng Giai Đoạn\n\n"
    for r in results:
        md += f"### Giai đoạn {r['period_idx']+1}: {r['start'].strftime('%d/%m/%Y')} → {r['end'].strftime('%d/%m/%Y')}\n\n"
        md += f"- **Regime**: {r['regime_label']}\n"
        md += f"- **Tags**: {', '.join(r['regime_tags'])}\n"
        md += f"- **Kéo dài**: {r['duration']} ngày ({r['total_bars_h1']} nến H1)\n"
        md += f"- **Giá**: {r['price_start']:.2f} → {r['price_end']:.2f} (Low: {r['price_low']:.2f}, High: {r['price_high']:.2f})\n"
        md += f"- **ADX trung bình**: {r['adx_mean']:.1f} (Median: {r['adx_median']:.1f})\n"
        md += f"- **Choppiness trung bình**: {r['chop_mean']:.1f} (Median: {r['chop_median']:.1f})\n"
        md += f"- **ATR% (Normalized)**: {r['atr_pct_mean']:.4f}\n"
        md += f"- **Hurst Exponent**: {r['hurst']:.3f}\n"
        md += f"- **Autocorrelation (lag-1)**: {r['autocorr']:.4f}\n"
        md += f"- **Return trung bình H1**: {r['return_mean']*100:.4f}%\n"
        md += f"- **Return std H1**: {r['return_std']*100:.4f}%\n"

        # Interpretation
        md += "\n**Nhận định:**\n"
        if 'Sideways Narrow Range' in r['regime_label']:
            md += ("> Thị trường dao động trong biên độ cực hẹp, không có xu hướng. "
                   "EA bị whipsaw liên tục do giá cắn SL rồi quay đầu ngay. "
                   "**Giải pháp**: Tắt EA khi ADX < 20 & Choppiness > 60.\n\n")
        elif 'High Vol Choppy' in r['regime_label']:
            md += ("> Biên độ lớn nhưng không có hướng đi rõ ràng. "
                   "EA bị stop loss do những cú swing ngược mạnh. "
                   "**Giải pháp**: Thu hẹp lot size hoặc mở rộng SL khi ATR% > ngưỡng.\n\n")
        elif 'Slow Drift' in r['regime_label']:
            md += ("> Thị trường trôi chậm theo một hướng nhưng ADX chưa đủ mạnh để xác nhận trend. "
                   "EA liên tục vào sai chiều. "
                   "**Giải pháp**: Thêm bộ lọc EMA dài hạn (200) để cấm trade ngược trend.\n\n")
        elif 'Trending' in r['regime_label']:
            md += ("> Thị trường có xu hướng mạnh. Nếu EA vẫn đi ngang, vấn đề nằm ở logic EA "
                   "(có thể cắt lời quá sớm hoặc counter-trend). "
                   "**Giải pháp**: Review TP/SL logic và trailing stop.\n\n")
        else:
            md += ("> Giai đoạn chuyển tiếp giữa các regime. Cần theo dõi thêm "
                   "các chỉ báo Choppiness breakout và ADX cross.\n\n")

        if 'chart_path' in r:
            md += f"📈 [Xem biểu đồ chi tiết]({os.path.basename(r['chart_path'])})\n\n"
        md += "---\n\n"

    # ── Common patterns ──
    md += "## 🎯 Điểm Chung Giữa Các Giai Đoạn Đi Ngang\n\n"
    if len(results) >= 2:
        labels = [r['regime_label'] for r in results]
        from collections import Counter
        label_counts = Counter(labels)
        most_common = label_counts.most_common(1)[0]
        md += f"- **Regime phổ biến nhất**: {most_common[0]} (xuất hiện {most_common[1]}/{len(results)} lần)\n"

        all_tags = []
        for r in results:
            all_tags.extend(r['regime_tags'])
        tag_counts = Counter(all_tags)
        md += f"- **Tags phổ biến**: {', '.join([f'{t} ({c}x)' for t, c in tag_counts.most_common(5)])}\n"

        avg_adx = np.mean([r['adx_mean'] for r in results])
        avg_chop = np.mean([r['chop_mean'] for r in results])
        avg_atr = np.mean([r['atr_pct_mean'] for r in results])
        avg_hurst = np.nanmean([r['hurst'] for r in results])

        md += f"\n### ⚠️ Phân Loại Insights Theo Logic EA (Regime Filter)\n"
        md += f"Dựa trên trung bình các giai đoạn đi ngang, ngưỡng (ADX < {avg_adx:.0f} và Choppiness > {avg_chop:.0f}) đại diện cho trạng thái thị trường đi ngang/nhiễu. Tuy nhiên, cách áp dụng phụ thuộc hoàn toàn vào **loại chiến lược (Logic EA)** của bạn:\n\n"
        
        md += f"#### 1. Nếu EA đánh Breakout (VD: Volatility Rider)\n"
        md += f"❌ **KHÔNG NÊN** dùng bộ lọc này để chặn (Skip) lệnh chờ (Stop/Limit). Nếu chặn, EA sẽ không đặt bẫy trong lúc đi ngang, dẫn đến việc lỡ nhịp khi giá vừa bứt phá. Khi ADX tăng cao thì giá đã đi quá xa, dẫn đến việc EA mua đuổi ở đỉnh.\n"
        md += f"✅ **Nên làm**: Cho phép đặt lệnh chờ trong vùng Choppy. Dùng bộ lọc ATR (tránh mua khi ATR nến hiện tại > 1.5x ATR trung bình) để tránh mua đuổi khi có nến spike.\n\n"
        
        md += f"#### 2. Nếu EA đánh Trend-Following (Pullback/Trend Continuation)\n"
        md += f"✅ **Nên làm**: Có thể dùng bộ lọc này để tạm ngưng vào lệnh mới khi thị trường không có xu hướng.\n"
        md += f"```mql5\n"
        md += f"// Regime Filter cho Trend EA\n"
        md += f"bool isSideways = (iADX(_, PERIOD_H1, 14, PRICE_CLOSE, MODE_MAIN, 0) < {avg_adx:.0f})\n"
        md += f"               && (ChoppinessIndex(14) > {avg_chop:.0f});\n"
        md += f"if (isSideways) return; // Không vào lệnh mới\n"
        md += f"```\n\n"
        
        md += f"#### 3. Nếu EA đánh Mean-Reversion / Grid / Martingale hai chiều\n"
        md += f"✅ **Nên làm**: Đây chính là 'thiên đường' của EA dạng này. Hãy giao dịch mạnh tay trong vùng đi ngang này. Ngược lại, hãy **TẮT EA** khi thị trường có xu hướng mạnh (Breakout).\n"
        md += f"```mql5\n"
        md += f"// Regime Filter cho Mean-Reversion EA\n"
        md += f"bool isStrongTrend = (iADX(_, PERIOD_H1, 14, PRICE_CLOSE, MODE_MAIN, 0) > {comparison['adx_mean'] if comparison else 45:.0f});\n"
        md += f"if (isStrongTrend) return; // Tắt EA, tránh bị kẹt Martingale/Grid\n"
        md += f"```\n\n"
    else:
        md += "- Chỉ có 1 giai đoạn đi ngang, không đủ dữ liệu để rút ra điểm chung.\n\n"

    md += "---\n*Báo cáo được xuất tự động bởi Regime Analyzer.*\n"

    report_path = os.path.join(output_dir, "regime_analysis_report.md")
    with open(report_path, 'w', encoding='utf-8') as f:
        f.write(md)

    return report_path

# ============================================================
# MAIN
# ============================================================
def main():
    parser = argparse.ArgumentParser(description='Regime Analyzer — Phân tích bối cảnh và giám sát realtime')
    parser.add_argument('--ohlc', required=False, default=None, help='Path to OHLC M1 CSV file (MT5 export)')
    parser.add_argument('--live', default=None, help='Symbol to monitor live (e.g. GC=F, XAUUSD=X)')
    parser.add_argument('--source', default='Yahoo Finance API (REST API)', help='Live source: Yahoo Finance API (REST API) or MetaTrader 5 (Direct Terminal Bridge)')
    parser.add_argument('--timeframe', default='1h', help='Timeframe for live evaluation (default: 1h)')
    parser.add_argument('--backtest', default=None, help='Path to backtest result file (xlsx/csv)')
    parser.add_argument('--periods', default=None, help='Manual periods: "start1,end1;start2,end2" (YYYY-MM-DD)')
    parser.add_argument('--threshold', type=float, default=5.0, help='Sideways threshold %% (default: 5.0)')
    parser.add_argument('--min-days', type=int, default=15, help='Minimum sideways duration in days (default: 15)')
    parser.add_argument('--output', default=None, help='Output directory (default: ./regime_output)')
    args = parser.parse_args()

    if args.live or not args.ohlc:
        sym = args.live or "GC=F"
        print(f"\n📡 [Realtime Regime Monitor] Đang kết nối {args.source} lấy dữ liệu mã {sym} khung {args.timeframe}...")
        df_live, err = fetch_live_ohlc(args.source, sym, args.timeframe)
        if err or df_live is None:
            print(f"❌ Lỗi: {err}")
            sys.exit(1)
        registry = load_regime_registry()
        if not registry:
            print("⚠️ Chưa có hồ sơ chiến lược nào được lưu trong Registry. Vui lòng chạy Streamlit để phân tích trước.")
            sys.exit(0)
        eval_res = evaluate_live_market(df_live, registry)
        latest = eval_res.get("latest_bar", {})
        print(f"⚡ Thời điểm nến mới nhất: {eval_res.get('latest_time')} | ADX: {latest.get('ADX',0):.1f} | Hurst: {latest.get('Hurst',0):.2f} | Chop: {latest.get('Choppiness',0):.1f}\n")
        print("🤖 KHUYẾN NGHỊ HOẠT ĐỘNG EA:")
        for s_name, info in eval_res.get("evaluations", {}).items():
            badge = "🟢 BẬT EA" if info['status'] == 'PASS' else ("🟡 CẨN TRỌNG" if info['status'] == 'CAUTION' else "🔴 KHÓA LỆNH")
            print(f"   [{badge}] {s_name} (Độ khớp: {info['match_pct']}%)")
            for r in info['reasons']: print(f"        {r}")
        sys.exit(0)

    output_dir = args.output or os.path.join(os.path.dirname(os.path.abspath(args.ohlc)), 'regime_output')
    os.makedirs(output_dir, exist_ok=True)

    # ── Load OHLC ──
    print(f"📥 Loading OHLC data: {args.ohlc}")
    df_m1 = load_ohlc(args.ohlc)
    print(f"   ✅ Loaded {len(df_m1):,} bars M1 | {df_m1.index[0]} → {df_m1.index[-1]}")

    # ── Get sideways periods ──
    periods = []
    if args.periods:
        for chunk in args.periods.split(';'):
            parts = chunk.strip().split(',')
            if len(parts) == 2:
                s = pd.Timestamp(parts[0].strip())
                e = pd.Timestamp(parts[1].strip())
                periods.append({'start': s, 'end': e, 'duration': (e - s).days, 'range_pct': 0})
        print(f"📝 Loaded {len(periods)} periods from manual input")
    elif args.backtest:
        print(f"📊 Detecting sideways periods from backtest: {args.backtest}")
        periods = detect_sideways_from_backtest(args.backtest, args.threshold, args.min_days)
        print(f"   ✅ Found {len(periods)} sideways periods (threshold={args.threshold}%, min_days={args.min_days})")
    else:
        print("❌ Cần cung cấp --backtest hoặc --periods. Dùng --help để xem hướng dẫn.")
        sys.exit(1)

    if not periods:
        print("⚠️ Không tìm thấy giai đoạn đi ngang nào. Thử giảm --threshold hoặc --min-days.")
        sys.exit(0)

    for i, p in enumerate(periods):
        print(f"   [{i+1}] {p['start'].strftime('%Y-%m-%d')} → {p['end'].strftime('%Y-%m-%d')} ({p['duration']} ngày)")

    # ── Analyze each period ──
    print(f"\n🔬 Analyzing {len(periods)} periods...")
    results = []
    for i, p in enumerate(periods):
        print(f"   [{i+1}/{len(periods)}] {p['start'].strftime('%d/%m/%Y')} → {p['end'].strftime('%d/%m/%Y')} ...", end=' ')
        result = analyze_period(df_m1, p, i, output_dir)
        if result:
            results.append(result)
            print(f"✅ {result['regime_label']}")
        else:
            print("⚠️ Không đủ dữ liệu OHLC cho giai đoạn này")

    if not results:
        print("\n❌ Không có kết quả. Kiểm tra lại phạm vi thời gian của file OHLC.")
        sys.exit(1)

    # ── Analyze non-sideways periods for comparison ──
    print("\n📈 Calculating comparison baseline (non-sideways periods)...")
    comparison = analyze_non_sideways(df_m1, periods)
    if comparison:
        print(f"   ✅ Baseline: ADX={comparison['adx_mean']:.1f}, CHOP={comparison['chop_mean']:.1f}, "
              f"ATR%={comparison['atr_pct_mean']:.3f}, Hurst={comparison['hurst']:.2f}")
    else:
        print("   ⚠️ Không đủ dữ liệu non-sideways để so sánh")

    # ── Generate report ──
    report_path = generate_report(results, comparison, output_dir)
    print(f"\n{'='*60}")
    print(f"✅ HOÀN TẤT!")
    print(f"   📄 Báo cáo: {report_path}")
    print(f"   📊 Biểu đồ: {output_dir}/regime_period_*.html")
    print(f"{'='*60}")

    # ── Print quick summary ──
    print(f"\n📋 TÓM TẮT NHANH:")
    for r in results:
        print(f"   [{r['period_idx']+1}] {r['regime_label']} | ADX={r['adx_mean']:.1f} CHOP={r['chop_mean']:.1f} "
              f"ATR%={r['atr_pct_mean']:.3f} Hurst={r['hurst']:.2f}")

if __name__ == '__main__':
    main()
