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
    keep = ['Open', 'High', 'Low', 'Close']
    for c in ('TickVol', 'Vol'):
        if c in df.columns:
            keep.append(c)
    df = df[keep].astype(float)
    # Prefer tick volume; if empty/zero fall back to real Vol (exchange/spot/futures)
    return ensure_activity_volume(df)

def resample_ohlc(df, timeframe='1h'):
    """Resample M1 data to higher timeframe."""
    df = ensure_activity_volume(df)
    agg = {
        'Open': 'first',
        'High': 'max',
        'Low': 'min',
        'Close': 'last',
        'TickVol': 'sum',
    }
    # Keep secondary volume cols if present (sum) for later re-resolve
    for c in ('Vol', 'RealVolume', 'Volume'):
        if c in df.columns and c not in agg:
            agg[c] = 'sum'
    out = df.resample(timeframe).agg({k: v for k, v in agg.items() if k in df.columns}).dropna(subset=['Open', 'High', 'Low', 'Close'])
    return ensure_activity_volume(out)

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

# Bump when indicator formulas change — invalidates stale .cache.pkl automatically.
INDICATOR_CACHE_VERSION = 5

# Warm-up bars before DNA features are trusted (EMA200 horizon).
DNA_WARMUP_BARS = 200

# Features used for DNA (declared early so calc_regime_indicators can warm-up/invalidate them).
# - Excludes same-bar Returns (noise / leakage).
# - Excludes Hurst by default: Python multi-lag R/S ≠ simplified MQL5 Hurst → threshold không portable.
DNA_FEATURE_COLS = ['ADX', 'ATR%', 'Choppiness', 'BB_Width', 'EMA_Dist%', 'Vol_ZScore', 'AutoCorr']

# Core DNA features that MUST be present (finite, real market data — never empty placeholders).
DNA_CORE_FEATURES = ['ADX', 'ATR%', 'Choppiness', 'BB_Width', 'EMA_Dist%', 'Vol_ZScore']

# Scale-positive features: after warm-up, value ≤ 0 means incomplete/degenerate bar (not usable).
# EMA_Dist% and Vol_ZScore may legitimately be ~0 (EMA cross / volume at mean) → only require finite.
DNA_STRICT_POSITIVE = frozenset({'ADX', 'ATR%', 'Choppiness', 'BB_Width'})

# Volume column priority for Vol_ZScore:
# 1) tick volume (MT5 tick_volume / CSV TICKVOL)
# 2) real / exchange volume (spot, futures COMEX, crypto exchange volume, Yahoo Volume, …)
_VOLUME_COL_PRIORITY = (
    'TickVol', 'tick_volume', 'TickVolume', 'TICKVOL',
    'real_volume', 'RealVolume', 'REAL_VOLUME',
    'Vol', 'Volume', 'volume', 'VOL',
)


def _series_usable_volume(s, min_nonzero=20):
    """True if series has enough non-zero finite values for rolling z-score."""
    if s is None:
        return False
    s = pd.to_numeric(s, errors='coerce')
    if int(s.notna().sum()) < min_nonzero:
        return False
    return bool((s.fillna(0.0) > 0).sum() >= min_nonzero)


def resolve_activity_volume(df):
    """
    Pick best usable activity/volume series from a frame.

    Prefer tick volume; if missing/all-zero, fall back to real/exchange volume
    from the data source (spot, futures, crypto, Yahoo/Twelve Volume, MT5 real_volume, …).

    Returns (series, source_col_name) or (None, None).
    """
    if df is None or df.empty:
        return None, None

    cols_lower = {str(c).lower(): c for c in df.columns}
    ordered, seen = [], set()

    for name in _VOLUME_COL_PRIORITY:
        actual = name if name in df.columns else cols_lower.get(name.lower())
        if actual is not None and actual not in seen:
            ordered.append(actual)
            seen.add(actual)

    # Any other *vol* column (exclude volatility-like names)
    for c in df.columns:
        if c in seen:
            continue
        cl = str(c).lower()
        if 'vol' in cl and 'volatility' not in cl and cl not in ('vix',):
            ordered.append(c)
            seen.add(c)

    for c in ordered:
        s = pd.to_numeric(df[c], errors='coerce')
        if _series_usable_volume(s):
            return s.astype(float), str(c)
    return None, None


def ensure_activity_volume(df):
    """
    Ensure df has usable `TickVol` for Vol_ZScore.

    If TickVol is empty/zero, fill from the best available volume column
    (real volume of spot/futures/crypto from the feed). Sets
    df.attrs['volume_source'] to the column name used (or None).
    """
    if df is None or (hasattr(df, 'empty') and df.empty):
        return df
    out = df.copy()
    # Preserve attrs (pandas copy usually keeps them; re-apply to be safe)
    try:
        out.attrs.update(getattr(df, 'attrs', {}) or {})
    except Exception:
        pass

    series, src = resolve_activity_volume(out)
    if series is not None:
        if series.index.equals(out.index):
            out['TickVol'] = series
        else:
            out['TickVol'] = series.reindex(out.index)
        try:
            out.attrs['volume_source'] = src
        except Exception:
            pass
    else:
        if 'TickVol' not in out.columns:
            out['TickVol'] = np.nan
        try:
            out.attrs['volume_source'] = None
        except Exception:
            pass
    return out


def _has_usable_tickvol(df):
    """True if any usable activity volume exists (tick or real/spot/futures)."""
    if df is None or df.empty:
        return False
    # Fast path: TickVol already good
    if 'TickVol' in df.columns and _series_usable_volume(df['TickVol']):
        return True
    series, _src = resolve_activity_volume(df)
    return series is not None


def dna_features_valid_mask(df):
    """
    Boolean mask: True where core DNA features are usable.
    - All DNA_CORE_FEATURES must be finite (no NaN/Inf empty stand-ins).
    - DNA_STRICT_POSITIVE must be > 0 (0 = missing/degenerate, not allowed).
    - EMA_Dist% / Vol_ZScore: 0 is allowed if finite.
    """
    if df is None or df.empty:
        return pd.Series(dtype=bool)
    mask = pd.Series(True, index=df.index)
    for col in DNA_CORE_FEATURES:
        if col not in df.columns:
            return pd.Series(False, index=df.index)
        s = pd.to_numeric(df[col], errors='coerce')
        col_ok = s.notna() & np.isfinite(s)
        if col in DNA_STRICT_POSITIVE:
            col_ok = col_ok & (s > 0)
        mask = mask & col_ok
    return mask


def validate_dna_feature_row(feat_dict):
    """
    Validate one bar/trade feature dict.
    Returns (ok: bool, issues: list[str]).
    """
    issues = []
    if not feat_dict:
        return False, ["Thiếu toàn bộ feature dict"]
    for col in DNA_CORE_FEATURES:
        if col not in feat_dict:
            issues.append(f"{col}: thiếu cột")
            continue
        try:
            val = float(feat_dict[col])
        except (TypeError, ValueError):
            issues.append(f"{col}: không phải số")
            continue
        if val != val or not np.isfinite(val):  # NaN / Inf
            issues.append(f"{col}: trống/NaN/Inf (không được dùng placeholder)")
            continue
        if col in DNA_STRICT_POSITIVE and val <= 0:
            issues.append(f"{col}={val}: ≤0 coi như chưa có dữ liệu hợp lệ")
    return (len(issues) == 0), issues


def calc_regime_indicators(df_h1, cache_path=None):
    """Calculate all regime indicators on H1 data (Extended 12+ Features) with Caching."""
    if df_h1 is not None and not df_h1.empty:
        # Resolve volume first: tick → real/spot/futures from feed
        df_h1 = ensure_activity_volume(df_h1)
        if df_h1.index.name == 'Time' or isinstance(df_h1.index, pd.DatetimeIndex):
            # Only keep weekday bars (Monday=0 to Friday=4). Drop Saturday=5, Sunday=6 to prevent weekend gaps skewing indicators.
            df_h1 = df_h1[df_h1.index.dayofweek < 5].copy()
            df_h1 = ensure_activity_volume(df_h1)

    if cache_path and os.path.exists(cache_path):
        try:
            obj = pd.read_pickle(cache_path)
            if isinstance(obj, dict) and obj.get("_version") == INDICATOR_CACHE_VERSION:
                data = obj.get("data")
                if isinstance(data, pd.DataFrame) and not data.empty:
                    return data
            # Legacy bare DataFrame cache → recompute with versioned formula set
        except Exception:
            pass

    adx, plus_di, minus_di = calc_adx(df_h1, 14)
    atr = calc_atr(df_h1, 14)
    atr_pct = atr / df_h1['Close'].replace(0, np.nan) * 100  # Normalized ATR as % of price
    chop = calc_choppiness(df_h1, 14)
    returns = df_h1['Close'].pct_change()

    # Advanced Features
    sma20 = df_h1['Close'].rolling(20).mean()
    std20 = df_h1['Close'].rolling(20).std()
    bb_width = (4 * std20) / sma20.replace(0, np.nan)

    ema50 = df_h1['Close'].ewm(span=50, adjust=False).mean()
    ema200 = df_h1['Close'].ewm(span=200, adjust=False).mean()
    ema_dist = (ema50 - ema200) / ema200.replace(0, np.nan) * 100

    # Vol_ZScore on resolved activity volume (tick OR real/spot/futures).
    # NEVER fillna(0) — missing volume stays NaN so downstream rejects empty data.
    vol_src = None
    try:
        vol_src = (getattr(df_h1, 'attrs', {}) or {}).get('volume_source')
    except Exception:
        vol_src = None
    if _has_usable_tickvol(df_h1) and 'TickVol' in df_h1.columns and _series_usable_volume(df_h1['TickVol']):
        vol_mean = df_h1['TickVol'].rolling(20).mean()
        vol_std = df_h1['TickVol'].rolling(20).std()
        vol_zscore = (df_h1['TickVol'] - vol_mean) / vol_std.replace(0, np.nan)
    else:
        vol_zscore = pd.Series(np.nan, index=df_h1.index)
        vol_src = None

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
    try:
        res_df.attrs['volume_source'] = vol_src
    except Exception:
        pass

    # Warm-up: first DNA_WARMUP_BARS are not trusted (EMA200 / ADX / roll windows immature).
    # Mark DNA training features NaN so they cannot leak as 0 placeholders.
    warmup_n = min(DNA_WARMUP_BARS, max(0, len(res_df) - 1))
    if warmup_n > 0:
        for col in DNA_FEATURE_COLS:
            if col in res_df.columns:
                res_df.iloc[:warmup_n, res_df.columns.get_loc(col)] = np.nan
        # Also invalidate strict-positive raw columns used in live snapshot
        for col in DNA_CORE_FEATURES:
            if col in res_df.columns:
                res_df.iloc[:warmup_n, res_df.columns.get_loc(col)] = np.nan

    # Degenerate scale-positive → NaN (never keep 0 as if it were real data)
    for col in DNA_STRICT_POSITIVE:
        if col in res_df.columns:
            s = res_df[col]
            res_df[col] = s.where(s > 0, np.nan)

    if cache_path:
        try:
            cache_dir = os.path.dirname(cache_path)
            if cache_dir:
                os.makedirs(cache_dir, exist_ok=True)
            pd.to_pickle({"_version": INDICATOR_CACHE_VERSION, "data": res_df}, cache_path)
        except Exception:
            pass
    return res_df

# ============================================================
# SUPERVISED STRATEGY PROFILING (AI REGIME DNA)
# ============================================================

MQL5_VAR_MAP = {
    "ADX": "adx_val", "ATR%": "atr_pct_val", "Choppiness": "chop_val",
    "Returns": "ret_val", "BB_Width": "bb_width_val", "EMA_Dist%": "ema_dist_val",
    "Vol_ZScore": "vol_zscore_val", "Hurst": "hurst_val", "AutoCorr": "autocorr_val"
}


def pair_in_out_open_times(trades_df):
    """
    Ensure each closed trade has a valid OpenTime.

    MT5 deal exports often use different Order IDs for IN vs OUT, so Order-based
    joins match 0 rows and code falls back to close Time (lookahead bias).
    This FIFO volume-aware pairing recovers entry time from IN deals when present,
    or from a parallel raw deals frame stored on trades_df attrs.
    """
    if trades_df is None or trades_df.empty:
        return trades_df

    out = trades_df.copy()
    if 'OpenTime' in out.columns and out['OpenTime'].notna().sum() >= max(1, int(0.8 * len(out))):
        out['OpenTime'] = pd.to_datetime(out['OpenTime'], errors='coerce')
        return out

    # Prefer reconstructing from full deal stream if caller attached it
    raw_wrap = getattr(trades_df, 'attrs', {}).get('raw_deals')
    raw_deals = raw_wrap.df if hasattr(raw_wrap, 'df') else raw_wrap
    if raw_deals is None and {'_in_time', '_in_volume'}.issubset(out.columns):
        return out

    if raw_deals is not None and 'Direction' in raw_deals.columns:
        deals = raw_deals.copy()
        deals['Time'] = pd.to_datetime(deals['Time'], errors='coerce')
        if 'Volume' in deals.columns:
            deals['Volume'] = pd.to_numeric(deals['Volume'], errors='coerce')
        ins = deals[deals['Direction'].astype(str).str.strip().str.lower() == 'in'].sort_values('Time')
        outs = deals[deals['Direction'].astype(str).str.strip().str.lower() == 'out'].sort_values('Time')
        in_recs = ins.to_dict('records')
        used = set()
        open_times = []
        for _, o in outs.iterrows():
            best_i = None
            best = None
            o_vol = float(o['Volume']) if 'Volume' in o and pd.notna(o.get('Volume')) else None
            for i, inn in enumerate(in_recs):
                if i in used:
                    continue
                if inn['Time'] > o['Time']:
                    break
                inn_vol = float(inn['Volume']) if 'Volume' in inn and pd.notna(inn.get('Volume')) else None
                if o_vol is not None and inn_vol is not None and abs(inn_vol - o_vol) < 1e-9:
                    best, best_i = inn, i
                elif best is None:
                    best, best_i = inn, i
            if best is not None:
                used.add(best_i)
                open_times.append(best['Time'])
            else:
                open_times.append(pd.NaT)
        # Align by close time + profit if possible
        outs = outs.copy()
        outs['OpenTime'] = open_times
        # Map back onto trades_df by Time/Profit
        key_cols = ['Time']
        if 'Profit' in out.columns and 'Profit' in outs.columns:
            key_cols.append('Profit')
        merged = out.drop(columns=['OpenTime'], errors='ignore').merge(
            outs[key_cols + ['OpenTime']].drop_duplicates(key_cols),
            on=key_cols, how='left'
        )
        if merged['OpenTime'].notna().sum() > 0:
            return merged

    # Last resort: if OpenTime mostly missing, do NOT silently use close time —
    # leave NaT so caller can error clearly.
    if 'OpenTime' not in out.columns:
        out['OpenTime'] = pd.NaT
    else:
        out['OpenTime'] = pd.to_datetime(out['OpenTime'], errors='coerce')
    return out


def ensure_trade_open_times_from_deals(df_deals):
    """
    From a full MT5 Deals table (IN + OUT rows), return closed trades with OpenTime.
    FIFO volume-aware pairing — robust when Order IDs differ between IN/OUT.
    """
    if df_deals is None or df_deals.empty:
        return pd.DataFrame()

    deals = df_deals.copy()
    deals['Time'] = pd.to_datetime(deals['Time'], errors='coerce')
    deals = deals.dropna(subset=['Time'])
    for nc in ['Profit', 'Volume', 'Price', 'Balance']:
        if nc in deals.columns:
            deals[nc] = pd.to_numeric(deals[nc], errors='coerce')

    if 'Direction' not in deals.columns:
        return deals

    ins = deals[deals['Direction'].astype(str).str.strip().str.lower() == 'in'].sort_values('Time')
    outs = deals[deals['Direction'].astype(str).str.strip().str.lower() == 'out'].sort_values('Time')
    if outs.empty:
        return pd.DataFrame()

    in_recs = ins.to_dict('records')
    used = set()
    rows = []
    for _, o in outs.iterrows():
        best_i = None
        best = None
        o_vol = float(o['Volume']) if 'Volume' in o.index and pd.notna(o.get('Volume')) else None
        for i, inn in enumerate(in_recs):
            if i in used:
                continue
            if inn['Time'] > o['Time']:
                break
            inn_vol = float(inn['Volume']) if inn.get('Volume') is not None and pd.notna(inn.get('Volume')) else None
            if o_vol is not None and inn_vol is not None and abs(inn_vol - o_vol) < 1e-9:
                best, best_i = inn, i
            elif best is None:
                best, best_i = inn, i
        if best is None:
            continue
        used.add(best_i)
        row = o.to_dict()
        row['OpenTime'] = best['Time']
        row['OpenPrice'] = best.get('Price', np.nan)
        row['TradeType'] = best.get('Type', np.nan)
        rows.append(row)

    if not rows:
        return pd.DataFrame()
    result = pd.DataFrame(rows)
    result['Duration'] = (result['Time'] - result['OpenTime']).dt.total_seconds() / 3600.0
    return result.reset_index(drop=True)


def last_closed_bar_index(bar_index, t_entry):
    """Return last fully closed bar strictly before entry (no partial-bar leakage)."""
    ts = pd.Timestamp(t_entry)
    # bar_index is assumed sorted
    pos = bar_index.searchsorted(ts, side='left') - 1
    if pos < 0:
        return None
    return bar_index[pos]


def map_trades_to_candles(df_ohlc, trades_df):
    """
    Map each closed trade to the last CLOSED candle before entry time.
    Assigns label Y: +1 (Win), -1 (Loss), 0 (No trade) on candle index.
    Prefer trade-level build_trade_feature_table() for DNA training.
    """
    if df_ohlc.empty or trades_df.empty:
        return pd.Series(0, index=df_ohlc.index), pd.Series(0.0, index=df_ohlc.index)

    trade_pnl = pd.Series(0.0, index=df_ohlc.index)
    idx_sorted = df_ohlc.index

    for _, trade in trades_df.iterrows():
        t_entry = trade.get('OpenTime')
        if pd.isna(t_entry):
            # Do not fall back to close Time — that is lookahead.
            continue
        try:
            t_entry = pd.to_datetime(t_entry)
            pos = last_closed_bar_index(idx_sorted, t_entry)
            if pos is not None and pos in trade_pnl.index:
                pnl = float(trade.get('Profit', 0.0))
                trade_pnl.loc[pos] += pnl
        except Exception:
            continue

    y_series = pd.Series(np.where(trade_pnl > 0, 1, np.where(trade_pnl < 0, -1, 0)), index=df_ohlc.index)
    return y_series, trade_pnl


def build_trade_feature_table(df_h1, trades_df, indicators=None, cache_path=None):
    """
    One row per trade: regime features at last closed bar before OpenTime + PnL.
    This avoids candle-level aggregation bias and exit-time lookahead.
    """
    if indicators is None:
        indicators = calc_regime_indicators(df_h1, cache_path=cache_path)

    trades = trades_df.copy()
    if 'OpenTime' not in trades.columns or trades['OpenTime'].isna().all():
        return None, "Thiếu OpenTime — không thể map bối cảnh lúc vào lệnh (tránh lookahead). Hãy đảm bảo load_backtest ghép IN/OUT đúng."

    trades['OpenTime'] = pd.to_datetime(trades['OpenTime'], errors='coerce')
    trades = trades.dropna(subset=['OpenTime', 'Profit'] if 'Profit' in trades.columns else ['OpenTime'])
    if trades.empty:
        return None, "Không còn lệnh nào có OpenTime hợp lệ sau khi làm sạch."

    available_cols = [c for c in DNA_FEATURE_COLS if c in indicators.columns]
    missing_core = [c for c in DNA_CORE_FEATURES if c not in indicators.columns]
    if missing_core:
        return None, f"Thiếu cột DNA bắt buộc trong indicators: {missing_core}"

    rows = []
    skipped_empty = 0
    bar_index = indicators.index
    for _, tr in trades.iterrows():
        bar = last_closed_bar_index(bar_index, tr['OpenTime'])
        if bar is None or bar not in indicators.index:
            continue
        feat = indicators.loc[bar, available_cols]
        if feat.isna().any():
            skipped_empty += 1
            continue
        row = feat.to_dict()
        ok, _issues = validate_dna_feature_row(row)
        if not ok:
            # Core feature empty / ≤0 placeholder — never train on blank DNA
            skipped_empty += 1
            continue
        row['OpenTime'] = tr['OpenTime']
        row['CloseTime'] = tr.get('Time', pd.NaT)
        row['Profit'] = float(tr.get('Profit', 0.0))
        row['entry_bar'] = bar
        rows.append(row)

    if len(rows) < 10:
        hint = (
            f" (đã bỏ {skipped_empty} lệnh vì DNA feature trống/NaN/≤0 — "
            f"cần OHLC đủ warm-up ≥{DNA_WARMUP_BARS} nến + volume "
            f"(tick hoặc real/spot/futures từ feed) cho Vol_ZScore)"
            if skipped_empty else ""
        )
        return None, f"Không đủ mẫu trade-level (tìm thấy {len(rows)}, cần ≥ 10).{hint}"

    tbl = pd.DataFrame(rows).sort_values('OpenTime').reset_index(drop=True)
    return tbl, None


def _equity_metrics(pnl_series, bal0=5000.0):
    """Core metrics for filter impact evaluation."""
    pnl = np.asarray(pnl_series, dtype=float)
    if len(pnl) == 0:
        return {"n": 0, "net": 0.0, "wr": 0.0, "pf": 0.0, "maxdd": 0.0, "exp": 0.0, "recovery": 0.0}
    eq = bal0 + np.cumsum(pnl)
    peak = np.maximum.accumulate(eq)
    dd = (eq - peak) / np.where(peak == 0, np.nan, peak) * 100.0
    wins = pnl[pnl > 0].sum()
    losses = pnl[pnl < 0].sum()
    net = float(pnl.sum())
    maxdd = float(np.nanmin(dd)) if len(dd) else 0.0
    pf = float(wins / abs(losses)) if losses != 0 else 99.0
    return {
        "n": int(len(pnl)),
        "net": round(net, 2),
        "wr": round(float((pnl > 0).mean() * 100), 1),
        "pf": round(pf, 2),
        "maxdd": round(maxdd, 2),
        "exp": round(float(pnl.mean()), 2),
        "recovery": round(net / max(0.01, abs(maxdd)), 2),
    }


def _paths_from_tree(tree, feature_names, leaf_predicate):
    """Collect conjunction paths for leaves where leaf_predicate(node_id) is True."""
    paths = []

    def dfs(node_id, conditions):
        left = tree.children_left[node_id]
        right = tree.children_right[node_id]
        if left == right:
            if leaf_predicate(node_id):
                paths.append(list(conditions))
            return
        feat = feature_names[tree.feature[node_id]]
        thr = tree.threshold[node_id]
        dfs(left, conditions + [f"({feat} <= {thr:.4f})"])
        dfs(right, conditions + [f"({feat} > {thr:.4f})"])

    dfs(0, [])
    return paths


def serialize_tree_rule_bundle(reg, feature_names, exp_threshold=0.0, mode="block_toxic"):
    """
    Serializable decision paths for live Streamlit evaluation (no sklearn needed at eval time).
    Each path: list of {feature, op, threshold} + leaf expectancy + leaf_id.
    """
    tree = reg.tree_
    toxic_paths, good_paths = [], []

    def leaf_value(node_id):
        return float(tree.value[node_id][0][0])

    def dfs(node_id, conditions):
        left = tree.children_left[node_id]
        right = tree.children_right[node_id]
        if left == right:
            exp = leaf_value(node_id)
            entry = {
                "conditions": list(conditions),
                "expectancy": round(exp, 4),
                "leaf_id": int(node_id),
            }
            if exp <= exp_threshold:
                toxic_paths.append(entry)
            else:
                good_paths.append(entry)
            return
        feat = feature_names[tree.feature[node_id]]
        thr = float(tree.threshold[node_id])
        dfs(left, conditions + [{"feature": feat, "op": "<=", "threshold": thr}])
        dfs(right, conditions + [{"feature": feat, "op": ">", "threshold": thr}])

    dfs(0, [])
    return {
        "mode": mode,
        "exp_threshold": float(exp_threshold),
        "feature_names": list(feature_names),
        "toxic_paths": toxic_paths,
        "good_paths": good_paths,
        "dna_version": "v2_expectancy",
    }


def _path_matches_features(conditions, feat_dict):
    for c in conditions:
        val = feat_dict.get(c["feature"])
        if val is None:
            return False
        try:
            val = float(val)
        except (TypeError, ValueError):
            return False
        if val != val:  # NaN
            return False
        thr = float(c["threshold"])
        if c["op"] == "<=":
            if not (val <= thr):
                return False
        else:  # ">"
            if not (val > thr):
                return False
    return True


def evaluate_features_against_rule_bundle(feat_dict, rule_bundle):
    """
    Apply serialized DNA tree paths to a feature dict (one closed bar).
    Returns dict: is_safe, is_toxic, pred_expectancy, leaf_id, matched_path, status, reasons.
    """
    if not rule_bundle:
        return {
            "is_safe": True, "is_toxic": False, "pred_expectancy": None,
            "leaf_id": None, "status": "CAUTION", "eval_mode": "none",
            "reasons": ["⚠️ Chưa có rule_paths trong registry — hãy huấn luyện lại DNA v2."],
            "match_pct": 50.0,
        }

    thr = float(rule_bundle.get("exp_threshold", 0.0))
    mode = rule_bundle.get("mode", "block_toxic")
    all_paths = list(rule_bundle.get("toxic_paths") or []) + list(rule_bundle.get("good_paths") or [])

    matched = None
    for p in all_paths:
        if _path_matches_features(p.get("conditions") or [], feat_dict):
            matched = p
            break

    if matched is None:
        return {
            "is_safe": True, "is_toxic": False, "pred_expectancy": None,
            "leaf_id": None, "status": "CAUTION", "eval_mode": "tree",
            "reasons": ["⚠️ Không khớp leaf nào (thiếu feature hoặc rule cũ). Coi như CAUTION."],
            "match_pct": 50.0,
            "matched_path": None,
        }

    exp = float(matched["expectancy"])
    is_toxic = exp <= thr
    if mode == "allow_good":
        is_safe = exp > thr
    else:
        is_safe = not is_toxic

    if is_safe:
        status = "PASS"
        match_pct = 100.0 if exp > thr + abs(thr) * 0.1 + 1 else 75.0
    else:
        status = "BLOCK"
        match_pct = 0.0

    # Near-threshold toxic: soft caution
    if is_safe and exp <= thr + 2.0 and thr < 0:
        status = "CAUTION"
        match_pct = 45.0

    cond_str = " AND ".join(
        f"{c['feature']} {c['op']} {c['threshold']:.4f}" for c in (matched.get("conditions") or [])
    ) or "(root)"
    reasons = [
        f"🌳 **Tree DNA** leaf `{matched.get('leaf_id')}` | pred exp **${exp:.2f}**/lệnh "
        f"(threshold ≤ ${thr:.2f})",
        f"{'🔴 TOXIC → KHÓA' if is_toxic else '🟢 SAFE → CHO PHÉP'} | path: `{cond_str}`",
    ]
    # Feature snapshot for top DNA features present
    for fn in (rule_bundle.get("feature_names") or [])[:6]:
        if fn in feat_dict and feat_dict[fn] == feat_dict[fn]:
            reasons.append(f"· `{fn}` = {float(feat_dict[fn]):.4f}")

    return {
        "is_safe": is_safe,
        "is_toxic": is_toxic,
        "pred_expectancy": round(exp, 4),
        "leaf_id": matched.get("leaf_id"),
        "status": status,
        "eval_mode": "tree",
        "reasons": reasons,
        "match_pct": match_pct,
        "matched_path": matched,
        "path_text": cond_str,
    }


def tree_to_mql5_expectancy(reg, feature_names, exp_threshold=0.0, mode="block_toxic"):
    """
    Convert expectancy DecisionTreeRegressor into MQL5 filter.

    mode='block_toxic': isSafeRegime = NOT (toxic leaf paths)  [recommended]
    mode='allow_good':  isSafeRegime = good leaf paths only
    """
    tree = reg.tree_

    def leaf_value(node_id):
        # sklearn regressor: value shape (n_outputs,)
        return float(tree.value[node_id][0][0])

    toxic_paths = _paths_from_tree(tree, feature_names, lambda n: leaf_value(n) <= exp_threshold)
    good_paths = _paths_from_tree(tree, feature_names, lambda n: leaf_value(n) > exp_threshold)

    def to_mql(paths, join_or=True):
        if not paths:
            return None
        rules = [" && ".join(p) for p in paths]
        body = rules[0] if len(rules) == 1 else " || \n    ".join([f"({r})" for r in rules])
        for k, v in MQL5_VAR_MAP.items():
            body = body.replace(k, v)
        return body

    if mode == "allow_good":
        body = to_mql(good_paths)
        if not body:
            return "// AI không tìm thấy vùng expectancy dương với ngưỡng hiện tại."
        cond = f"bool isSafeRegime = {body};"
        logic_note = "ALLOW-LIST: chỉ vào lệnh khi rơi vào leaf expectancy > threshold"
    else:
        body = to_mql(toxic_paths)
        if not body:
            # No toxic leaves — always safe
            cond = "bool isSafeRegime = true; // Không có leaf độc (exp <= threshold)"
            logic_note = "Không chặn vùng nào — mọi leaf có expectancy > threshold"
        else:
            cond = f"bool isToxicRegime = {body};\nbool isSafeRegime = !isToxicRegime;"
            logic_note = "BLOCK-LIST: chỉ chặn leaf có expectancy <= threshold (giữ phần lớn lệnh lãi)"

    mql5_code = f"""// --- AI Regime DNA v2 (Expectancy Block-List) ---
// Mục tiêu: giảm drawdown bằng cách CHẶN vùng expectancy âm, không cố đoán win/loss.
// {logic_note}
// exp_threshold = {exp_threshold:.4f}
// Cần tính trên nến H1 ĐÃ ĐÓNG (shift=1): ADX, ATR%, Chop, BB_Width, EMA_Dist%, Vol_ZScore, Hurst, AutoCorr

input int RegimeFilterMode = 0; // 0: Block All | 1: Shadow Mode (giảm lot)

{cond}

if (!isSafeRegime) {{
    if (RegimeFilterMode == 0) {{
        Print("[DNA v2] Toxic regime (expectancy thap) -> BLOCK entry.");
        return;
    }} else if (RegimeFilterMode == 1) {{
        Print("[DNA v2] Toxic regime -> SHADOW MODE.");
        // lot_size = InpShadowLotSize;
    }}
}}"""
    return mql5_code


def tree_to_mql5(clf, feature_names):
    """Legacy classifier → MQL5 (win-majority allow-list). Kept for backward compat."""
    tree = clf.tree_
    win_paths = []

    def dfs(node_id, current_conditions):
        if tree.children_left[node_id] == tree.children_right[node_id]:
            val = tree.value[node_id][0]
            if len(val) > 1 and val[1] > val[0]:
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
    code_body = full_cond
    for k, v in MQL5_VAR_MAP.items():
        code_body = code_body.replace(k, v)

    return f"""// --- AI Supervised Regime Filter (LEGACY Win/Loss Allow-List) ---
// CẢNH BÁO: Allow-list theo win-rate thường cắt lệnh lãi lớn (R:R cao) → giảm profit, DD không giảm.
// Khuyến nghị dùng DNA v2 Expectancy Block-List.

input int RegimeFilterMode = 1;

bool isWinningRegime = {code_body};

if (!isWinningRegime) {{
    if (RegimeFilterMode == 0) {{
        return;
    }}
}}"""

def compute_range_analysis(X, y_pnl, top_features):
    """
    Quantile range analysis with win-rate AND expectancy (mean PnL) per bin.
    """
    range_stats = {}
    y_pnl = pd.Series(y_pnl).reset_index(drop=True)
    for col in top_features.keys():
        if col not in X.columns:
            continue
        series = X[col].reset_index(drop=True)
        try:
            bins = pd.qcut(series, q=3, duplicates='drop')
        except Exception:
            try:
                bins = pd.cut(series, bins=3)
            except Exception:
                continue
        df_temp = pd.DataFrame({'bin': bins.astype(str), 'pnl': y_pnl})
        stats = []
        for bin_name, group in df_temp.groupby('bin', observed=False):
            total = len(group)
            if total == 0:
                continue
            wins = int((group['pnl'] > 0).sum())
            stats.append({
                "range": bin_name,
                "total_trades": int(total),
                "win_count": wins,
                "win_rate": round(wins / total * 100, 1),
                "expectancy": round(float(group['pnl'].mean()), 2),
                "net_pnl": round(float(group['pnl'].sum()), 2),
            })
        range_stats[col] = stats
    return range_stats


def evaluate_feature_stability_over_time(X, y_pnl, available_cols, max_depth=3, n_periods=4):
    """
    Time-decay stability using expectancy regressor (not win/loss classifier).
    """
    try:
        from sklearn.tree import DecisionTreeRegressor
    except ImportError:
        return {"error": "Thiếu thư viện scikit-learn."}

    y_pnl = pd.Series(y_pnl).reset_index(drop=True)
    X = X.reset_index(drop=True)

    if len(X) < 40:
        return {"error": "Không đủ số lượng mẫu lệnh (cần tối thiểu 40 lệnh) để chia chu kỳ thời gian."}

    chunk_size = len(X) // n_periods
    period_results = []
    feature_appearance = {col: 0 for col in available_cols}
    feature_weights_sum = {col: 0.0 for col in available_cols}

    for p in range(n_periods):
        start_idx = p * chunk_size
        end_idx = (p + 1) * chunk_size if p < n_periods - 1 else len(X)
        X_sub = X.iloc[start_idx:end_idx]
        y_sub = y_pnl.iloc[start_idx:end_idx]
        if len(y_sub) < 15:
            continue

        min_leaf = max(5, int(len(y_sub) * 0.08))
        reg_sub = DecisionTreeRegressor(max_depth=max_depth, min_samples_leaf=min_leaf, random_state=42)
        reg_sub.fit(X_sub, y_sub)
        pred = reg_sub.predict(X_sub)
        # Rank correlation / sign accuracy of expectancy
        sign_acc = float(((pred > 0) == (y_sub > 0)).mean()) if len(y_sub) else 0.0

        imp_sub = pd.Series(reg_sub.feature_importances_, index=available_cols)
        top_sub = imp_sub[imp_sub > 0].to_dict()
        for f, w in top_sub.items():
            feature_appearance[f] += 1
            feature_weights_sum[f] += float(w)

        t_start = str(X_sub.index[0]) if not hasattr(X_sub.index[0], 'strftime') else str(X_sub.index[0])[:10]
        # Prefer OpenTime column if present in attrs — use positional range
        period_results.append({
            "period_idx": p + 1,
            "time_range": f"chunk {p + 1}/{n_periods}",
            "sample_count": len(y_sub),
            "win_rate": round(float((y_sub > 0).mean() * 100), 1),
            "expectancy": round(float(y_sub.mean()), 2),
            "accuracy": round(sign_acc * 100, 1),
            "top_features": top_sub
        })

    valid_periods = len(period_results)
    if valid_periods == 0:
        return {"error": "Không thể phân tích ổn định do các chu kỳ quá mỏng."}

    stability_summary = []
    robust_features = []
    drift_warnings = []
    for f in available_cols:
        count = feature_appearance[f]
        if count == 0:
            continue
        consistency_pct = round(count / valid_periods * 100, 1)
        avg_weight = round(feature_weights_sum[f] / valid_periods, 3)
        status = (
            "🟢 Robust DNA (Ổn định cao)" if consistency_pct >= 70
            else ("🟡 Moderate (Ổn định trung bình)" if consistency_pct >= 40
                  else "🔴 Concept Drift (Nguy cơ thoái hóa)")
        )
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


def _leaf_table(reg, X, y_pnl):
    """Per-leaf expectancy stats for a fitted regressor."""
    leaves = reg.apply(X)
    df = pd.DataFrame({"leaf": leaves, "pnl": np.asarray(y_pnl, dtype=float)})
    rows = []
    for leaf, g in df.groupby("leaf"):
        rows.append({
            "leaf": int(leaf),
            "n": int(len(g)),
            "net_pnl": round(float(g["pnl"].sum()), 2),
            "expectancy": round(float(g["pnl"].mean()), 2),
            "win_rate": round(float((g["pnl"] > 0).mean() * 100), 1),
            "tree_value": round(float(reg.tree_.value[leaf][0][0]), 2),
        })
    return sorted(rows, key=lambda r: r["expectancy"])


def simulate_filter_impact(y_pnl, keep_mask, bal0=5000.0):
    """Compare baseline vs filtered equity metrics."""
    y_pnl = pd.Series(y_pnl).reset_index(drop=True)
    keep_mask = np.asarray(keep_mask, dtype=bool)
    base = _equity_metrics(y_pnl, bal0)
    filt = _equity_metrics(y_pnl[keep_mask], bal0)
    blocked = y_pnl[~keep_mask]
    return {
        "baseline": base,
        "filtered": filt,
        "blocked_n": int((~keep_mask).sum()),
        "blocked_net_pnl": round(float(blocked.sum()), 2) if len(blocked) else 0.0,
        "blocked_avg_pnl": round(float(blocked.mean()), 2) if len(blocked) else 0.0,
        "delta_net": round(filt["net"] - base["net"], 2),
        "delta_maxdd": round(filt["maxdd"] - base["maxdd"], 2),  # positive = DD improved (less negative)
        "delta_pf": round(filt["pf"] - base["pf"], 2),
        "block_rate_pct": round(float((~keep_mask).mean() * 100), 1),
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

    # Use DNA v2's entry-bar mapping to avoid lookahead
    tbl, err = build_trade_feature_table(df_h1, trades_df)
    
    trade_cluster_stats = []
    best_cluster_name = ""
    best_exp = -1e18
    best_wr = -1.0

    if tbl is not None and not tbl.empty and 'entry_bar' in tbl.columns:
        # Map each trade to the cluster of its entry bar
        tbl = tbl[tbl['entry_bar'].isin(df_cluster.index)].copy()
        tbl['Cluster'] = df_cluster.loc[tbl['entry_bar'], 'Cluster'].values
        
        for c in range(n_clusters):
            c_trades = tbl[tbl['Cluster'] == c]
            total_t = len(c_trades)
            if total_t == 0:
                continue
                
            c_pnl = c_trades['Profit']
            wins = (c_pnl > 0).sum()
            losses = (c_pnl <= 0).sum()
            wr = round(wins / total_t * 100, 1)
            net_pnl = round(float(c_pnl.sum()), 2)
            avg_pnl = round(net_pnl / total_t, 2) if total_t > 0 else 0.0

            # Rank by expectancy (avg PnL), not win-rate — aligns with DNA v2
            if avg_pnl > best_exp and total_t >= 10:
                best_exp = avg_pnl
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
                "avg_pnl": avg_pnl,
                "expectancy": avg_pnl,
            })

    return {
        "success": True,
        "n_clusters": n_clusters,
        "cluster_profiles": list(cluster_profiles.values()),
        "trade_cluster_stats": trade_cluster_stats,
        "best_cluster_name": best_cluster_name,
        "best_win_rate": best_wr,
        "best_expectancy": round(best_exp, 2) if best_exp > -1e17 else None,
        "rank_metric": "expectancy",
    }

def extract_strategy_dna(df_h1, trades_df, max_depth=3, cache_path=None, strategy_name=None,
                         exp_threshold=None, filter_mode="block_toxic", bal0=5000.0,
                         hard_toxic_exp=-5.0, threshold_mode="auto"):
    """
    Supervised Strategy Profiling v2 — Expectancy DNA (anti-lookahead + DD-aware).

    Key design changes vs v1:
    1. Trade-level samples at ENTRY (last closed bar before OpenTime) — no exit-time leakage.
    2. DecisionTreeRegressor on PnL (expectancy), not Win/Loss classifier.
    3. BLOCK-LIST toxic leaves; threshold_mode='auto'|'fixed'.
    4. Deploy tree = train-only (not full-sample refit) so Streamlit live rules match OOS validation.
    5. Serializes rule_paths for live tree evaluation (no MQL5 required).

    threshold_mode:
      - 'auto': pick best thr among candidates via OOS score (default)
      - 'fixed': use exp_threshold exactly (default 0.0 if None)
    """
    try:
        from sklearn.tree import DecisionTreeRegressor, DecisionTreeClassifier, export_text
    except ImportError:
        return {"error": "Thiếu thư viện scikit-learn. Vui lòng chạy `pip install scikit-learn`."}

    warnings_list = []

    # Repair OpenTime if Order-join failed (common with MT5 deal exports)
    trades_work = trades_df.copy()
    if 'OpenTime' in trades_work.columns:
        trades_work['OpenTime'] = pd.to_datetime(trades_work['OpenTime'], errors='coerce')
    need_pair = (
        'OpenTime' not in trades_work.columns
        or trades_work['OpenTime'].isna().mean() > 0.2
    )
    if need_pair:
        raw_wrap = getattr(trades_df, 'attrs', {}).get('raw_deals')
        raw = raw_wrap.df if hasattr(raw_wrap, 'df') else raw_wrap
        # Also accept plain DataFrame attached under attrs
        if raw is None:
            raw = getattr(trades_df, 'attrs', {}).get('deals_df')
        if raw is not None and not (hasattr(raw, 'empty') and raw.empty):
            repaired = ensure_trade_open_times_from_deals(raw)
            if repaired is not None and not repaired.empty and 'OpenTime' in repaired.columns:
                # Prefer repaired rows; keep original columns if merge possible
                if 'Time' in trades_work.columns and 'Time' in repaired.columns:
                    key = ['Time', 'Profit'] if 'Profit' in trades_work.columns and 'Profit' in repaired.columns else ['Time']
                    keep = ['OpenTime'] + [c for c in ['OpenPrice', 'TradeType'] if c in repaired.columns]
                    tmp = trades_work.drop(columns=[c for c in keep if c in trades_work.columns], errors='ignore')
                    trades_work = tmp.merge(
                        repaired[key + keep].drop_duplicates(key), on=key, how='left'
                    )
                else:
                    trades_work = repaired
                trades_work['OpenTime'] = pd.to_datetime(trades_work['OpenTime'], errors='coerce')

        still_bad = (
            'OpenTime' not in trades_work.columns
            or trades_work['OpenTime'].isna().all()
            or trades_work['OpenTime'].isna().mean() > 0.5
        )
        if still_bad:
            return {
                "error": (
                    "Không có OpenTime hợp lệ. DNA v2 từ chối map theo Time đóng lệnh (lookahead). "
                    "Streamlit sẽ tự ghép lại từ file Deals — hãy bấm Train lại sau khi app đã reload. "
                    "Nếu vẫn lỗi: xóa `*.cache.pkl` cạnh file backtest, clear cache Streamlit (C menu), "
                    "rồi chọn lại strategy."
                )
            }

    # OpenTime coverage diagnostic (FIFO / Order-join quality)
    if 'OpenTime' in trades_work.columns:
        open_cov = float(pd.to_datetime(trades_work['OpenTime'], errors='coerce').notna().mean())
    else:
        open_cov = 0.0
    if open_cov < 0.95:
        warnings_list.append(
            f"⚠️ OpenTime coverage chỉ {open_cov*100:.1f}% — FIFO/Order-join có thể gán nhầm "
            f"(martingale/multi-position). Kiểm tra lại file deals."
        )

    tbl, err = build_trade_feature_table(df_h1, trades_work, cache_path=cache_path)
    if err:
        return {"error": err}

    available_cols = [c for c in DNA_FEATURE_COLS if c in tbl.columns]
    X = tbl[available_cols].copy()
    y_pnl = tbl['Profit'].astype(float)
    y_cls = np.where(y_pnl > 0, 1, -1)

    if len(np.unique(y_cls)) < 2:
        val = "THẮNG" if y_cls[0] > 0 else "THUA"
        return {"error": f"Toàn bộ {len(y_pnl)} lệnh đều là {val}. Cần cả Thắng và Thua."}

    # Time-ordered OOS holdout (last 20%)
    oos_size = max(5, int(len(y_pnl) * 0.20)) if len(y_pnl) >= 25 else 0
    if oos_size > 0:
        X_train, y_train = X.iloc[:-oos_size], y_pnl.iloc[:-oos_size]
        X_oos, y_oos = X.iloc[-oos_size:], y_pnl.iloc[-oos_size:]
    else:
        X_train, y_train = X, y_pnl
        X_oos, y_oos = X, y_pnl
        warnings_list.append("ℹ️ Mẫu ít — không tách OOS 20%; threshold/score dùng full train.")

    min_leaf = max(15, int(len(y_train) * 0.04))
    # DEPLOY tree = train-only (matches OOS validation; used for Streamlit live + export)
    reg = DecisionTreeRegressor(max_depth=max_depth, min_samples_leaf=min_leaf, random_state=42)
    reg.fit(X_train, y_train)

    threshold_mode = (threshold_mode or "auto").lower().strip()
    if threshold_mode not in ("auto", "fixed"):
        threshold_mode = "auto"

    if threshold_mode == "fixed":
        thr_candidates = [float(exp_threshold) if exp_threshold is not None else 0.0]
    else:
        thr_candidates = []
        if exp_threshold is not None:
            thr_candidates.append(float(exp_threshold))
        thr_candidates.extend([hard_toxic_exp, -10.0, -5.0, -2.0, 0.0])
        seen = set()
        thr_candidates = [t for t in thr_candidates if not (t in seen or seen.add(t))]

    def _score_oos(imp):
        """Higher is better: reward DD improvement + keep most OOS profit."""
        b, f = imp["baseline"], imp["filtered"]
        if f["n"] < 10:
            return -1e9
        dd_gain = f["maxdd"] - b["maxdd"]  # positive = better
        net_ratio = f["net"] / b["net"] if abs(b["net"]) > 1e-6 else 0.0
        if net_ratio < 0.5 or imp["block_rate_pct"] > 55:
            return -1e6 + net_ratio * 100
        return dd_gain * 3.0 + net_ratio * 10.0 - imp["block_rate_pct"] * 0.05

    best_thr = thr_candidates[0]
    best_score = -1e18
    best_oos_imp = None
    thr_score_table = []
    y_eval = y_oos if oos_size > 0 else y_train
    X_eval = X_oos if oos_size > 0 else X_train
    pred_eval_base = reg.predict(X_eval)
    for thr_try in thr_candidates:
        imp_try = simulate_filter_impact(y_eval, pred_eval_base > thr_try, bal0)
        sc = _score_oos(imp_try)
        thr_score_table.append({
            "threshold": thr_try,
            "score": round(sc, 3),
            "block_rate_pct": imp_try["block_rate_pct"],
            "delta_net": imp_try["delta_net"],
            "delta_maxdd": imp_try["delta_maxdd"],
        })
        if sc > best_score:
            best_score = sc
            best_thr = thr_try
            best_oos_imp = imp_try

    exp_threshold = float(best_thr)
    recommended_threshold = exp_threshold
    oos_impact = best_oos_imp

    # Purged time-series CV on filter quality with selected threshold
    cv_folds = min(5, len(y_train) // 40) if len(y_train) >= 80 else 0
    cv_scores = []
    cv_dd_improve = []
    if cv_folds >= 2:
        fold_size = len(y_train) // cv_folds
        embargo = max(2, int(len(y_train) * 0.02))
        for f in range(cv_folds):
            vs, ve = f * fold_size, (f + 1) * fold_size if f < cv_folds - 1 else len(y_train)
            tr_idx = [i for i in range(len(y_train)) if i < vs - embargo or i >= ve + embargo]
            va_idx = list(range(vs, ve))
            if len(tr_idx) < 30 or len(va_idx) < 10:
                continue
            reg_f = DecisionTreeRegressor(max_depth=max_depth, min_samples_leaf=min_leaf, random_state=42)
            reg_f.fit(X_train.iloc[tr_idx], y_train.iloc[tr_idx])
            pred_va = reg_f.predict(X_train.iloc[va_idx])
            keep = pred_va > exp_threshold
            if keep.sum() < 5:
                continue
            base_m = _equity_metrics(y_train.iloc[va_idx])
            filt_m = _equity_metrics(y_train.iloc[va_idx][keep])
            cv_scores.append(1.0 if filt_m["maxdd"] >= base_m["maxdd"] and filt_m["exp"] >= 0 else 0.0)
            cv_dd_improve.append(filt_m["maxdd"] - base_m["maxdd"])
    cv_acc = float(np.mean(cv_scores)) if cv_scores else 0.0
    cv_avg_dd_delta = float(np.mean(cv_dd_improve)) if cv_dd_improve else 0.0

    # Expanding walk-forward (train prefix → test next chunk) — toxic-path stability signal
    walk_forward = []
    if len(X) >= 120:
        n_wf = 3
        chunk = len(X) // (n_wf + 1)
        for i in range(1, n_wf + 1):
            tr_end = chunk * i
            te_end = chunk * (i + 1) if i < n_wf else len(X)
            if tr_end < 40 or te_end - tr_end < 15:
                continue
            reg_wf = DecisionTreeRegressor(max_depth=max_depth, min_samples_leaf=min_leaf, random_state=42)
            reg_wf.fit(X.iloc[:tr_end], y_pnl.iloc[:tr_end])
            pred_te = reg_wf.predict(X.iloc[tr_end:te_end])
            y_te = y_pnl.iloc[tr_end:te_end]
            imp_wf = simulate_filter_impact(y_te, pred_te > exp_threshold, bal0)
            walk_forward.append({
                "fold": i,
                "train_n": int(tr_end),
                "test_n": int(te_end - tr_end),
                "block_rate_pct": imp_wf["block_rate_pct"],
                "delta_net": imp_wf["delta_net"],
                "delta_maxdd": imp_wf["delta_maxdd"],
                "filtered_exp": imp_wf["filtered"]["exp"],
                "pass": bool(
                    imp_wf["filtered"]["exp"] > 0
                    and imp_wf["block_rate_pct"] < 55
                    and imp_wf["filtered"]["net"] >= imp_wf["baseline"]["net"] * 0.5
                ),
            })
    wf_pass_rate = (
        round(sum(1 for w in walk_forward if w["pass"]) / len(walk_forward) * 100, 1)
        if walk_forward else None
    )

    oos_ok = (
        oos_impact["filtered"]["maxdd"] >= oos_impact["baseline"]["maxdd"] - 1.0
        and oos_impact["filtered"]["exp"] > 0
        and oos_impact["filtered"]["net"] >= oos_impact["baseline"]["net"] * 0.55
        and oos_impact["block_rate_pct"] < 55
    )
    oos_status = (
        "PASS (OOS: giữ edge + DD ổn)" if oos_ok
        else ("CAUTION (OOS yếu)" if oos_impact["filtered"]["exp"] > 0 else "FAIL (OOS phá edge)")
    )
    if walk_forward and wf_pass_rate is not None and wf_pass_rate < 50:
        oos_status = "CAUTION (walk-forward yếu)" if oos_ok else oos_status
        warnings_list.append(
            f"⚠️ Walk-forward pass rate {wf_pass_rate}% — rule có thể không ổn định theo thời gian."
        )

    # Legacy classifier for comparison only (full sample — diagnostic)
    clf = DecisionTreeClassifier(
        max_depth=max_depth, min_samples_leaf=min_leaf, class_weight='balanced', random_state=42
    )
    clf.fit(X, y_cls)
    pred_cls = clf.predict(X)
    legacy_impact = simulate_filter_impact(y_pnl, pred_cls == 1, bal0)

    # Apply DEPLOY tree (train-only) to full series for honest IS impact + live parity
    pred_exp = reg.predict(X)
    keep_mask = pred_exp > exp_threshold
    impact = simulate_filter_impact(y_pnl, keep_mask, bal0)

    # Optional: full-refit tree impact for comparison only (not deployed)
    reg_full = DecisionTreeRegressor(max_depth=max_depth, min_samples_leaf=min_leaf, random_state=42)
    reg_full.fit(X, y_pnl)
    full_impact = simulate_filter_impact(y_pnl, reg_full.predict(X) > exp_threshold, bal0)

    imp = pd.Series(reg.feature_importances_, index=available_cols).sort_values(ascending=False)
    top_features = imp[imp > 0].to_dict()

    tree_text = export_text(reg, feature_names=available_cols)
    mql5_code = tree_to_mql5_expectancy(reg, available_cols, exp_threshold=exp_threshold, mode=filter_mode)
    mql5_legacy = tree_to_mql5(clf, available_cols)
    rule_paths = serialize_tree_rule_bundle(reg, available_cols, exp_threshold=exp_threshold, mode=filter_mode)

    # Leaf stats: map deploy-tree leaves onto full-sample PnL (honest)
    leaf_stats = _leaf_table(reg, X, y_pnl)
    toxic_leaves = [L for L in leaf_stats if L["expectancy"] <= exp_threshold]
    good_leaves = [L for L in leaf_stats if L["expectancy"] > exp_threshold]

    win_mask = y_pnl > 0
    win_context = X[win_mask].mean().to_dict()
    loss_context = X[~win_mask].mean().to_dict()

    features_csv_rel = ""
    if strategy_name:
        try:
            base_name = os.path.splitext(strategy_name)[0]
            out_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "backtest result")
            os.makedirs(out_dir, exist_ok=True)
            features_csv_path = os.path.join(out_dir, f"{base_name}_regime_features.csv")
            export_df = X.copy()
            export_df['OpenTime'] = tbl['OpenTime'].values
            export_df['Profit'] = y_pnl.values
            export_df['Regime_Label'] = np.where(y_pnl > 0, 'WIN', 'LOSS')
            export_df['Pred_Expectancy'] = pred_exp
            export_df['Filter_Keep'] = keep_mask
            export_df.to_csv(features_csv_path, index_label="trade_idx")
            features_csv_rel = f"backtest result/{base_name}_regime_features.csv"
        except Exception as e:
            print("Error exporting features CSV:", e)

    stability_res = evaluate_feature_stability_over_time(X, y_pnl, available_cols, max_depth=max_depth)
    clustering_res = unsupervised_regime_clustering(df_h1, trades_work, n_clusters=3)

    blocked = y_pnl[~keep_mask]
    block_precision = float((blocked <= 0).mean()) if len(blocked) else 0.0
    try:
        from scipy.stats import spearmanr
        spearman = float(spearmanr(pred_exp, y_pnl).correlation)
    except Exception:
        spearman = float(np.corrcoef(pred_exp, y_pnl)[0, 1]) if len(y_pnl) > 2 else 0.0

    diagnosis = _build_dna_diagnosis(impact, oos_impact, legacy_impact)
    diagnosis.append(
        f"Deploy tree: **train-only** (n={len(y_train)}) · threshold_mode=**{threshold_mode}** "
        f"· thr=**{exp_threshold}** · rule_paths toxic={len(rule_paths.get('toxic_paths') or [])}"
    )
    if threshold_mode == "auto":
        diagnosis.append(
            f"Auto threshold đã chọn **{exp_threshold}** (OOS score {best_score:.2f}). "
            f"Full-refit IS (không deploy) Δnet={full_impact['delta_net']:+.0f} — chỉ để so sánh."
        )
    if wf_pass_rate is not None:
        diagnosis.append(f"Walk-forward pass rate: **{wf_pass_rate}%** ({len(walk_forward)} folds).")
    diagnosis.extend(warnings_list)

    return {
        "success": True,
        "dna_version": "v2_expectancy",
        "sample_count": int(len(y_pnl)),
        "win_count": int((y_pnl > 0).sum()),
        "loss_count": int((y_pnl <= 0).sum()),
        "accuracy": float(block_precision) if len(blocked) else float((pred_exp > 0).mean()),
        "cv_accuracy": float(cv_acc),
        "oos_accuracy": float(
            (oos_impact["filtered"]["maxdd"] - oos_impact["baseline"]["maxdd"] + 10) / 20
        ),
        "oos_sample_count": int(oos_size),
        "oos_status": oos_status,
        "min_samples_leaf": min_leaf,
        "exp_threshold": float(exp_threshold),
        "recommended_threshold": float(recommended_threshold),
        "threshold_mode": threshold_mode,
        "threshold_candidates_scored": thr_score_table,
        "filter_mode": filter_mode,
        "deploy_tree_source": "train_only",
        "train_sample_count": int(len(y_train)),
        "open_time_coverage": round(open_cov * 100, 1),
        "spearman_exp_pnl": round(spearman, 3) if spearman == spearman else 0.0,
        "block_precision": round(block_precision * 100, 1),
        "cv_avg_dd_delta": round(cv_avg_dd_delta, 2),
        "walk_forward": walk_forward,
        "walk_forward_pass_rate": wf_pass_rate,
        "top_features": top_features,
        "tree_text": tree_text,
        "rule_paths": rule_paths,
        "mql5_code": mql5_code,
        "mql5_legacy_code": mql5_legacy,
        "win_context": win_context,
        "loss_context": loss_context,
        "features_csv_path": features_csv_rel,
        "range_analysis": compute_range_analysis(X, y_pnl, top_features),
        "feature_stability_analysis": stability_res,
        "unsupervised_clustering_analysis": clustering_res,
        "leaf_stats": leaf_stats,
        "toxic_leaves": toxic_leaves,
        "good_leaves": good_leaves,
        "filter_impact": impact,
        "filter_impact_oos": oos_impact,
        "filter_impact_full_refit_diag": full_impact,
        "legacy_winrate_filter_impact": legacy_impact,
        "warnings": warnings_list,
        "diagnosis": diagnosis,
    }


def _build_dna_diagnosis(impact, oos_impact, legacy_impact):
    """Human-readable diagnosis comparing v2 block-list vs legacy allow-list."""
    lines = []
    base, filt = impact["baseline"], impact["filtered"]
    lines.append(
        f"Baseline: Net ${base['net']:,.0f} | MaxDD {base['maxdd']:.1f}% | PF {base['pf']} | "
        f"n={base['n']} | Exp ${base['exp']}"
    )
    lines.append(
        f"DNA v2 (block toxic): Net ${filt['net']:,.0f} (Δ {impact['delta_net']:+.0f}) | "
        f"MaxDD {filt['maxdd']:.1f}% (Δ DD {impact['delta_maxdd']:+.1f}pp) | "
        f"PF {filt['pf']} | chặn {impact['block_rate_pct']}% lệnh "
        f"(blocked net ${impact['blocked_net_pnl']:,.0f})"
    )
    leg = legacy_impact["filtered"]
    lines.append(
        f"Legacy WR allow-list: Net ${leg['net']:,.0f} | MaxDD {leg['maxdd']:.1f}% | "
        f"PF {leg['pf']} | chặn {legacy_impact['block_rate_pct']}% "
        f"(thường cắt cả lệnh lãi lớn → profit giảm, DD không cải thiện)"
    )
    oos_b, oos_f = oos_impact["baseline"], oos_impact["filtered"]
    lines.append(
        f"OOS holdout: baseline Net ${oos_b['net']:,.0f} / DD {oos_b['maxdd']:.1f}% → "
        f"filtered Net ${oos_f['net']:,.0f} / DD {oos_f['maxdd']:.1f}% "
        f"(block {oos_impact['block_rate_pct']}%)"
    )
    if impact["delta_maxdd"] > 0.5 and impact["delta_net"] >= -abs(base["net"]) * 0.25:
        lines.append("✅ v2 đạt mục tiêu: DD giảm (hoặc không xấu hơn nhiều) mà không phá phần lớn profit.")
    elif impact["delta_net"] < -abs(base["net"]) * 0.3 and impact["delta_maxdd"] < 1:
        lines.append("⚠️ Filter vẫn đang cắt quá nhiều edge. Nới exp_threshold (vd -2 hoặc -5) hoặc giảm max_depth.")
    else:
        lines.append("ℹ️ Kiểm tra OOS: nếu OOS FAIL thì chưa deploy live — concept drift / overfit.")
    return lines


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
            "dna_version": dna_res.get("dna_version", "v2_expectancy"),
            "accuracy": dna_res.get("accuracy", 0),
            "cv_accuracy": dna_res.get("cv_accuracy", 0),
            "oos_accuracy": dna_res.get("oos_accuracy", 0),
            "oos_status": dna_res.get("oos_status", "N/A"),
            "sample_count": dna_res.get("sample_count", 0),
            "win_count": dna_res.get("win_count", 0),
            "loss_count": dna_res.get("loss_count", 0),
            "exp_threshold": dna_res.get("exp_threshold", 0),
            "threshold_mode": dna_res.get("threshold_mode", "auto"),
            "deploy_tree_source": dna_res.get("deploy_tree_source", "train_only"),
            "train_sample_count": dna_res.get("train_sample_count", 0),
            "open_time_coverage": dna_res.get("open_time_coverage", 100),
            "block_precision": dna_res.get("block_precision", 0),
            "walk_forward": dna_res.get("walk_forward", []),
            "walk_forward_pass_rate": dna_res.get("walk_forward_pass_rate"),
            "threshold_candidates_scored": dna_res.get("threshold_candidates_scored", []),
            "top_features": dna_res.get("top_features", {}),
            "tree_text": dna_res.get("tree_text", ""),
            "rule_paths": dna_res.get("rule_paths", {}),
            "mql5_code": dna_res.get("mql5_code", ""),
            "mql5_legacy_code": dna_res.get("mql5_legacy_code", ""),
            "win_context": dna_res.get("win_context", {}),
            "loss_context": dna_res.get("loss_context", {}),
            "features_csv_path": dna_res.get("features_csv_path", ""),
            "range_analysis": dna_res.get("range_analysis", {}),
            "feature_stability_analysis": dna_res.get("feature_stability_analysis", {}),
            "unsupervised_clustering_analysis": dna_res.get("unsupervised_clustering_analysis", {}),
            "leaf_stats": dna_res.get("leaf_stats", []),
            "toxic_leaves": dna_res.get("toxic_leaves", []),
            "good_leaves": dna_res.get("good_leaves", []),
            "filter_impact": dna_res.get("filter_impact", {}),
            "filter_impact_oos": dna_res.get("filter_impact_oos", {}),
            "filter_impact_full_refit_diag": dna_res.get("filter_impact_full_refit_diag", {}),
            "legacy_winrate_filter_impact": dna_res.get("legacy_winrate_filter_impact", {}),
            "warnings": dna_res.get("warnings", []),
            "diagnosis": dna_res.get("diagnosis", []),
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
                data = json.load(f)
                if isinstance(data, list):
                    for item in data:
                        if isinstance(item, dict) and item.get("symbol") == "GC=F":
                            item["symbol"] = "XAUUSD=X"
                return data
    except Exception:
        pass
    return [{"symbol": "XAU/USD", "source": SOURCE_TWELVE, "timeframe": "1h"}]

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
            
        latest_bar = eval_res.get("latest_bar") or {}

        def _finite_or_none(key):
            v = latest_bar.get(key)
            try:
                fv = float(v)
            except (TypeError, ValueError):
                return None
            return fv if np.isfinite(fv) else None

        record = {
            "timestamp_logged": datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
            "latest_time": latest_time,
            "symbol": symbol,
            "timeframe": timeframe,
            # None when missing — never invent 0/0.5/50 as fake indicator data
            "adx": _finite_or_none("ADX"),
            "hurst": _finite_or_none("Hurst"),
            "choppiness": _finite_or_none("Choppiness"),
            "bb_width": _finite_or_none("BB_Width"),
            "atr_pct": _finite_or_none("ATR%"),
            "vol_zscore": _finite_or_none("Vol_ZScore"),
            "ema_dist": _finite_or_none("EMA_Dist%"),
            "dna_features_ok": bool(eval_res.get("dna_features_ok", False)),
            "evaluations": {
                k: {
                    "status": v.get("status"),
                    "match_pct": v.get("match_pct"),
                    "eval_mode": v.get("eval_mode"),
                    "pred_expectancy": v.get("pred_expectancy"),
                    "is_toxic": v.get("is_toxic"),
                    "leaf_id": v.get("leaf_id"),
                }
                for k, v in eval_res.get("evaluations", {}).items()
            }
        }
        history.append(record)
        save_live_monitor_history(history)
        return True
    except Exception as e:
        print("Error logging monitor eval:", e)
        return False



# Yahoo often has NO liquid "XAUUSD=X" quote. Gold proxy = COMEX futures GC=F.
_YAHOO_GOLD_ALIASES = {
    "XAUUSD", "XAUUSD=X", "XAUUSDM", "XAUUSD.A", "XAUUSD.M", "XAUUSD.I",
    "XAU", "XAU=X", "GOLD", "GOLD=X", "XAUEUR", "XAUUSD#",
}

# Twelve Data uses BASE/QUOTE form, e.g. XAU/USD (spot gold), EUR/USD
_TWELVE_GOLD_ALIASES = {
    "XAUUSD", "XAUUSD=X", "XAUUSDM", "XAUUSD.A", "XAUUSD.M", "XAUUSD.I",
    "XAU", "XAU=X", "GOLD", "GOLD=X", "GC=F", "GCF", "GC", "MGC=F", "XAUUSD#",
}
_TWELVE_FOREX_BASES = (
    "EURUSD", "GBPUSD", "USDJPY", "AUDUSD", "USDCAD", "NZDUSD", "USDCHF",
    "EURGBP", "EURJPY", "GBPJPY", "EURCHF", "AUDJPY", "EURAUD",
)

SOURCE_TWELVE = "Twelve Data API (XAU/USD spot)"
SOURCE_YAHOO = "Yahoo Finance API (REST API)"
SOURCE_MT5 = "MetaTrader 5 (Direct Terminal Bridge)"


def get_twelvedata_api_key(explicit=None):
    """Resolve API key: argument → env → Streamlit secrets."""
    if explicit and str(explicit).strip():
        return str(explicit).strip()
    for env_k in ("TWELVE_DATA_API_KEY", "TWELVEDATA_API_KEY", "TWELVE_DATA_KEY"):
        v = os.environ.get(env_k)
        if v and str(v).strip():
            return str(v).strip()
    try:
        import streamlit as st
        for sk in ("TWELVE_DATA_API_KEY", "TWELVEDATA_API_KEY", "twelve_data_api_key"):
            try:
                if sk in st.secrets and st.secrets[sk]:
                    return str(st.secrets[sk]).strip()
            except Exception:
                continue
    except Exception:
        pass
    return None


def resolve_twelvedata_symbol(symbol):
    """
    Normalize user symbol → Twelve Data ticker (e.g. XAU/USD, EUR/USD, BTC/USD).
    """
    raw = (symbol or "").strip()
    if not raw:
        return "XAU/USD"

    # Already BASE/QUOTE
    if "/" in raw:
        return raw.upper().replace(" ", "")

    u = raw.upper().replace(" ", "")
    for suf in (".M", ".I", ".A", ".PRO", ".RAW", "#", "=X", "=F"):
        if u.endswith(suf.upper()) or u.endswith(suf):
            # handle =X =F carefully
            pass
    u = u.replace("=X", "").replace("=F", "").replace("#", "")
    for suf in (".M", ".I", ".A", ".PRO", ".RAW"):
        if u.endswith(suf):
            u = u[: -len(suf)]

    if u in _TWELVE_GOLD_ALIASES or u.startswith("XAU"):
        return "XAU/USD"
    if u in ("BTC", "BTCUSD", "BITCOIN", "BTC-USD"):
        return "BTC/USD"
    if u in ("ETH", "ETHUSD", "ETH-USD"):
        return "ETH/USD"
    if u in _TWELVE_FOREX_BASES or (len(u) == 6 and u.isalpha()):
        return f"{u[:3]}/{u[3:]}"
    # fallback: insert slash if 6 letters
    if len(u) == 6:
        return f"{u[:3]}/{u[3:]}"
    return raw


def _twelve_interval(timeframe):
    m = {
        "1m": "1min", "1min": "1min",
        "5m": "5min", "5min": "5min",
        "15m": "15min", "15min": "15min",
        "30m": "30min", "30min": "30min",
        "1h": "1h", "h1": "1h",
        "2h": "2h",
        "4h": "4h", "h4": "4h",
        "1d": "1day", "d1": "1day", "1day": "1day",
    }
    return m.get((timeframe or "1h").lower(), "1h")


def fetch_twelvedata_ohlc(symbol="XAU/USD", timeframe="1h", outputsize=500,
                          api_key=None, start_date=None, end_date=None):
    """
    Fetch OHLC from Twelve Data /time_series.
    Returns (df, err) with columns Open/High/Low/Close/TickVol, DatetimeIndex.
    """
    try:
        import requests
    except ImportError:
        return None, "Thiếu gói requests. Chạy: pip install requests"

    key = get_twelvedata_api_key(api_key)
    if not key:
        return None, (
            "Chưa có Twelve Data API key. Đặt một trong các cách:\n"
            "• Streamlit secrets: TWELVE_DATA_API_KEY = \"...\"\n"
            "• Biến môi trường: TWELVE_DATA_API_KEY\n"
            "• Đăng ký free: https://twelvedata.com"
        )

    td_symbol = resolve_twelvedata_symbol(symbol)
    interval = _twelve_interval(timeframe)
    # Free plan caps outputsize; 5000 is max on many paid tiers — clamp safely
    out_n = int(max(10, min(int(outputsize or 500), 5000)))

    params = {
        "symbol": td_symbol,
        "interval": interval,
        "outputsize": out_n,
        "apikey": key,
        "format": "JSON",
        "dp": 5,
    }
    if start_date:
        params["start_date"] = str(start_date)[:10]
    if end_date:
        params["end_date"] = str(end_date)[:10]

    url = "https://api.twelvedata.com/time_series"
    try:
        resp = requests.get(url, params=params, timeout=30)
        data = resp.json()
    except Exception as e:
        return None, f"Lỗi kết nối Twelve Data: {e}"

    if not isinstance(data, dict):
        return None, f"Twelve Data trả về dữ liệu không hợp lệ: {type(data)}"

    # Error payloads: {"code":401,"message":"...","status":"error"} — no "values"
    if data.get("status") == "error" or (data.get("code") and int(data.get("code") or 0) >= 400):
        msg = data.get("message") or data.get("status") or str(data)[:200]
        return None, f"Twelve Data lỗi cho `{td_symbol}`: {msg}"

    values = data.get("values") or []
    if not values:
        return None, (
            f"Twelve Data không có nến cho `{td_symbol}` (interval={interval}). "
            f"Thử XAU/USD, EUR/USD. Message: {data.get('message', '')}"
        )

    df = pd.DataFrame(values)
    # columns: datetime, open, high, low, close, volume
    colmap = {c: c.lower() for c in df.columns}
    df.columns = [colmap[c] for c in df.columns]
    if "datetime" not in df.columns:
        return None, "Twelve Data response thiếu cột datetime."

    df["datetime"] = pd.to_datetime(df["datetime"], errors="coerce")
    df = df.dropna(subset=["datetime"]).sort_values("datetime")
    for c in ("open", "high", "low", "close", "volume"):
        if c in df.columns:
            df[c] = pd.to_numeric(df[c], errors="coerce")

    out = pd.DataFrame({
        "Open": df["open"],
        "High": df["high"],
        "Low": df["low"],
        "Close": df["close"],
    })
    # Keep feed volume as Volume; ensure_activity_volume maps to TickVol if usable
    if "volume" in df.columns:
        out["Volume"] = df["volume"]
    out.index = pd.DatetimeIndex(df["datetime"])
    out.index.name = "Time"
    out = out.dropna(subset=["Open", "High", "Low", "Close"])
    out = ensure_activity_volume(out)

    try:
        out.attrs["twelvedata_symbol"] = td_symbol
        out.attrs["twelvedata_interval"] = interval
        out.attrs["data_source"] = "twelvedata"
    except Exception:
        pass

    if out.empty:
        return None, f"Twelve Data: parse xong nhưng rỗng (`{td_symbol}`)."
    return out, None


def resolve_yahoo_symbol(symbol):
    """
    Normalize user symbol → Yahoo ticker(s) to try (primary first, then fallbacks).
    Returns list of candidate tickers.
    """
    raw = (symbol or "").strip()
    if not raw:
        return ["GC=F"]

    u = raw.upper().replace(" ", "")
    # Strip common broker suffixes
    for suf in (".M", ".I", ".A", ".PRO", ".RAW", "#"):
        if u.endswith(suf):
            u = u[: -len(suf)]

    candidates = []

    # Gold / XAU → GC=F (COMEX continuous). XAUUSD=X is frequently empty/404 on Yahoo.
    if u in _YAHOO_GOLD_ALIASES or u.startswith("XAU") or u in ("GC", "GCF", "GC=F"):
        candidates = ["GC=F", "MGC=F"]
    elif u in ("EURUSD", "GBPUSD", "USDJPY", "AUDUSD", "USDCAD", "NZDUSD", "USDCHF",
               "EURGBP", "EURJPY", "GBPJPY"):
        candidates = [f"{u}=X"]
    elif u.endswith("=X") or u.endswith("=F") or "-USD" in u or u.endswith("-USD"):
        candidates = [raw if raw == u or "=" in raw or "-" in raw else u]
        # If user still typed XAUUSD=X, replace with gold futures
        if u in ("XAUUSD=X", "XAU=X"):
            candidates = ["GC=F", "MGC=F"]
    elif u in ("BTC", "BTCUSD", "BITCOIN"):
        candidates = ["BTC-USD"]
    elif u in ("ETH", "ETHUSD"):
        candidates = ["ETH-USD"]
    else:
        # Try as-is, then =X forex style
        candidates = [raw, u, f"{u}=X"]

    # de-dupe preserve order
    seen = set()
    out = []
    for c in candidates:
        if c and c not in seen:
            seen.add(c)
            out.append(c)
    return out or ["GC=F"]


def _yf_history_first_ok(candidates, period, interval):
    """Try Yahoo tickers in order; return (df, used_symbol) or (empty, None)."""
    import yfinance as yf
    last_err = None
    for sym in candidates:
        try:
            df = yf.Ticker(sym).history(period=period, interval=interval)
            if df is not None and not df.empty:
                return df, sym
        except Exception as e:
            last_err = e
            continue
    return pd.DataFrame(), None


def fetch_live_ohlc(source_type, symbol="GC=F", timeframe="1h", limit=500, api_key=None):
    """
    Fetches real-time OHLC data from live APIs or MetaTrader 5 terminal.
    Sources: Twelve Data (XAU/USD spot), Yahoo (GC=F proxy), MT5 bridge, File CSV.
    """
    # Normalize source name (allow short labels)
    src = (source_type or "").strip()
    if src in ("Twelve Data", "twelvedata", "TwelveData", SOURCE_TWELVE) or src.startswith("Twelve Data"):
        outsize = max(50, min(int(limit or 500), 5000))
        df, err = fetch_twelvedata_ohlc(
            symbol=symbol or "XAU/USD",
            timeframe=timeframe,
            outputsize=outsize,
            api_key=api_key,
        )
        if err or df is None:
            return None, err
        return df.tail(limit), None

    if source_type == "Yahoo Finance API (REST API)" or src.startswith("Yahoo"):
        try:
            import yfinance as yf  # noqa: F401
        except ImportError:
            return None, "Thiếu gói yfinance. Vui lòng chạy `pip install yfinance`."

        interval_map = {"1h": "1h", "4h": "1h", "15m": "15m", "5m": "5m", "1d": "1d"}
        yf_interval = interval_map.get(timeframe, "1h")
        # Yahoo limits: 1h ~ 730d max in practice; use 60d for live monitor buffer
        if yf_interval in ("15m", "5m"):
            period = "60d"
        elif yf_interval == "1h":
            period = "60d"
        else:
            period = "1y"

        candidates = resolve_yahoo_symbol(symbol)
        try:
            df, used = _yf_history_first_ok(candidates, period=period, interval=yf_interval)
            if df.empty or used is None:
                return None, (
                    f"Không lấy được dữ liệu Yahoo cho `{symbol}` "
                    f"(đã thử: {', '.join(candidates)}). "
                    f"Gợi ý vàng: **GC=F**. Forex: EURUSD=X. BTC: BTC-USD. "
                    f"Hoặc dùng **File CSV MT5** cho khớp DNA."
                )

            # Keep Yahoo Volume as real/exchange volume (futures GC=F, crypto, equities).
            # ensure_activity_volume → TickVol if usable (forex =X often has 0 → stays unusable).
            if "Volume" not in df.columns and "volume" in df.columns:
                df = df.rename(columns={"volume": "Volume"})
            df.index.name = "Time"
            if df.index.tz is not None:
                df.index = df.index.tz_localize(None)
            df = ensure_activity_volume(df)

            if timeframe == "4h" and yf_interval == "1h":
                df = resample_ohlc(df, "4h")
            # Attach used symbol for UI (optional consumers)
            try:
                df.attrs["yahoo_symbol_used"] = used
                df.attrs["yahoo_symbol_requested"] = symbol
            except Exception:
                pass
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

        # Try broker variants for gold
        mt5_candidates = [symbol]
        su = (symbol or "").upper()
        if su in ("XAUUSD", "XAUUSD=X", "GC=F", "GOLD"):
            mt5_candidates = ["XAUUSD", "XAUUSDm", "XAUUSD.m", "XAUUSD.i", "GOLD", "XAUUSD#"]

        rates = None
        used_sym = symbol
        for s in mt5_candidates:
            rates = mt5.copy_rates_from_pos(s, mt5_tf, 0, limit)
            if rates is not None and len(rates) > 0:
                used_sym = s
                break
        mt5.shutdown()

        if rates is None or len(rates) == 0:
            return None, f"Không lấy được dữ liệu MT5 cho mã {symbol}. Kiểm tra Market Watch (XAUUSD / XAUUSDm…)."

        df = pd.DataFrame(rates)
        df['Time'] = pd.to_datetime(df['time'], unit='s')
        rename = {
            'open': 'Open', 'high': 'High', 'low': 'Low', 'close': 'Close',
            'tick_volume': 'TickVol', 'real_volume': 'RealVolume',
        }
        df = df.rename(columns=rename)
        keep = ['Open', 'High', 'Low', 'Close']
        for c in ('TickVol', 'RealVolume'):
            if c in df.columns:
                keep.append(c)
        df = df.set_index('Time')[keep]
        # Prefer tick_volume; if broker fills real_volume only, fall back automatically
        df = ensure_activity_volume(df)
        try:
            df.attrs["mt5_symbol_used"] = used_sym
        except Exception:
            pass
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


def fetch_historical_ohlc(symbol="GC=F", timeframe="1h", period="2y",
                          source="yahoo", api_key=None):
    """
    Historical OHLC for DNA profiling.
    source: 'yahoo' | 'twelvedata' (or full UI labels).
    """
    src = (source or "yahoo").strip().lower()
    if src.startswith("twelve") or src == "td":
        # Map period → start_date
        period = (period or "2y").lower()
        days_map = {"60d": 60, "1y": 365, "2y": 730, "5y": 365 * 5, "1mo": 30, "3mo": 90}
        days = days_map.get(period, 730)
        # Free tier often limited — request max bars then rely on outputsize
        # 1h * 730d ≈ 5000+ bars; clamp outputsize to plan max
        outsize = 5000
        if timeframe in ("15m", "5m", "5min", "15min"):
            outsize = 5000
            # twelve free may only allow short history on low TF
        end = pd.Timestamp.now(tz="UTC").tz_convert(None)
        start = end - pd.Timedelta(days=days)
        df, err = fetch_twelvedata_ohlc(
            symbol=symbol or "XAU/USD",
            timeframe=timeframe,
            outputsize=outsize,
            api_key=api_key,
            start_date=start.strftime("%Y-%m-%d"),
            end_date=end.strftime("%Y-%m-%d"),
        )
        if err:
            # retry without date range (outputsize only) — more free-tier friendly
            df2, err2 = fetch_twelvedata_ohlc(
                symbol=symbol or "XAU/USD",
                timeframe=timeframe,
                outputsize=min(outsize, 5000),
                api_key=api_key,
            )
            if err2:
                return None, err
            df = df2
        if df is None or df.empty:
            return None, err or "Twelve Data historical rỗng."
        return df, None

    # --- Yahoo path ---
    try:
        import yfinance as yf  # noqa: F401
    except ImportError:
        return None, "Thiếu gói yfinance."

    interval_map = {"1h": "1h", "4h": "1h", "15m": "15m", "5m": "5m", "1d": "1d"}
    yf_interval = interval_map.get(timeframe, "1h")

    if yf_interval in ["15m", "5m"]:
        period = "60d"
    elif yf_interval == "1h" and period in ("5y", "max"):
        period = "2y"

    candidates = resolve_yahoo_symbol(symbol)
    try:
        df, used = _yf_history_first_ok(candidates, period=period, interval=yf_interval)
        if df.empty or used is None:
            return None, (
                f"Không lấy được dữ liệu Yahoo cho `{symbol}` (thử: {', '.join(candidates)}). "
                f"Thử **Twelve Data** (XAU/USD) hoặc CSV MT5."
            )

        if "Volume" not in df.columns and "volume" in df.columns:
            df = df.rename(columns={"volume": "Volume"})
        df.index.name = "Time"
        if df.index.tz is not None:
            df.index = df.index.tz_localize(None)
        df = ensure_activity_volume(df)

        if timeframe == "4h" and yf_interval == "1h":
            df = resample_ohlc(df, "4h")
        try:
            df.attrs["yahoo_symbol_used"] = used
        except Exception:
            pass
        return df, None
    except Exception as e:
        return None, f"Lỗi Yahoo Finance: {str(e)}"



def evaluate_live_market(df_h1, registry_data):
    """
    Evaluate latest CLOSED bar against each strategy DNA in registry.

    DNA v2: uses serialized rule_paths (same tree as train/OOS deploy) — not win/loss centroids.
    Legacy v1 profiles without rule_paths: fall back to centroid heuristic with a warning.
    Uses iloc[-2] when possible so the bar is fully closed (avoids partial live candle leakage).

    Core DNA features (ADX, ATR%, Chop, BB_Width, EMA_Dist%, Vol_ZScore) MUST be finite
    and scale-positive where required — never evaluate on empty/0 placeholders.
    """
    if df_h1 is None or (hasattr(df_h1, 'empty') and df_h1.empty) or not registry_data:
        return {}

    tickvol_ok = _has_usable_tickvol(df_h1)
    ind_df = calc_regime_indicators(df_h1)
    if ind_df.empty:
        return {
            "latest_bar": {},
            "latest_time": None,
            "dna_features_ok": False,
            "error": "Không tính được indicators (OHLC rỗng).",
            "evaluations": {},
        }

    # Only bars with complete core DNA (ADX, ATR%, Chop, BB_Width, EMA_Dist%, Vol_Z)
    # AutoCorr is optional at live eval time (often sparse); tree paths that need it still check per-condition.
    valid_mask = dna_features_valid_mask(ind_df)
    ind_valid = ind_df.loc[valid_mask]
    if ind_valid.empty:
        reason_parts = [
            f"DNA features không đủ dữ liệu trên nến đóng gần nhất "
            f"(cần finite; ADX/ATR%/Chop/BB_Width > 0; warm-up ≥{DNA_WARMUP_BARS} nến)."
        ]
        if not tickvol_ok:
            reason_parts.append(
                "Volume thiếu/toàn 0 → Vol_ZScore = NaN. "
                "Cần tick volume (MT5) hoặc real volume từ nguồn (futures GC=F, spot/crypto exchange, Twelve/Yahoo Volume)."
            )
        err_msg = " ".join(reason_parts)
        results = {}
        for strat_name, profile in registry_data.items():
            results[strat_name] = {
                "status": "NO_DATA",
                "match_pct": 0.0,
                "reasons": [f"⛔ {err_msg}", "Không đánh giá DNA khi feature trống — coi như CHƯA CÓ TÍN HIỆU."],
                "latest_time": None,
                "timeframe": profile.get("timeframe", "1h"),
                "accuracy": profile.get("accuracy", 0),
                "cv_accuracy": profile.get("cv_accuracy", 0),
                "pred_expectancy": None,
                "is_toxic": None,
                "is_safe": False,
                "leaf_id": None,
                "eval_mode": "no_data",
                "oos_status": profile.get("oos_status", "N/A"),
                "block_precision": profile.get("block_precision", 0),
            }
        return {
            "latest_bar": {},
            "latest_time": None,
            "dna_features_ok": False,
            "error": err_msg,
            "evaluations": results,
        }

    # Use last bar with finite DNA features
    latest_bar = ind_valid.iloc[-1].to_dict()
    latest_time = str(ind_valid.index[-1])
    ok, issues = validate_dna_feature_row(latest_bar)
    if not ok:
        err_msg = "Feature không hợp lệ: " + "; ".join(issues)
        results = {
            s: {
                "status": "NO_DATA",
                "match_pct": 0.0,
                "reasons": [f"⛔ {err_msg}"],
                "latest_time": latest_time,
                "timeframe": (registry_data[s] or {}).get("timeframe", "1h"),
                "pred_expectancy": None,
                "is_toxic": None,
                "is_safe": False,
                "eval_mode": "no_data",
            }
            for s in registry_data
        }
        return {
            "latest_bar": latest_bar,
            "latest_time": latest_time,
            "dna_features_ok": False,
            "error": err_msg,
            "evaluations": results,
        }

    results = {}
    for strat_name, profile in registry_data.items():
        rule_paths = profile.get("rule_paths")
        is_v2 = profile.get("dna_version") == "v2_expectancy" or bool(rule_paths)

        if rule_paths and (rule_paths.get("toxic_paths") is not None or rule_paths.get("good_paths") is not None):
            tree_res = evaluate_features_against_rule_bundle(latest_bar, rule_paths)
            results[strat_name] = {
                "status": tree_res["status"],
                "match_pct": tree_res["match_pct"],
                "reasons": tree_res["reasons"],
                "latest_time": latest_time,
                "timeframe": profile.get("timeframe", "1h"),
                "accuracy": profile.get("accuracy", 0),
                "cv_accuracy": profile.get("cv_accuracy", 0),
                "exp_threshold": profile.get("exp_threshold", rule_paths.get("exp_threshold")),
                "pred_expectancy": tree_res.get("pred_expectancy"),
                "is_toxic": tree_res.get("is_toxic"),
                "is_safe": tree_res.get("is_safe"),
                "leaf_id": tree_res.get("leaf_id"),
                "path_text": tree_res.get("path_text"),
                "eval_mode": "tree",
                "oos_status": profile.get("oos_status", "N/A"),
                "block_precision": profile.get("block_precision", 0),
            }
            continue

        # Legacy centroid fallback (v1 or old registry without rule_paths)
        top_feats = profile.get("top_features", {}) or {}
        win_ctx = profile.get("win_context", {}) or {}
        loss_ctx = profile.get("loss_context", {}) or {}
        reasons = [
            "⚠️ Registry thiếu `rule_paths` — đang dùng heuristic mean win/loss (không chính xác). "
            "Hãy **huấn luyện lại DNA v2** trong Streamlit."
        ]
        score = 0.0
        total_weight = 0.0
        for feat, weight in top_feats.items():
            if feat not in latest_bar or feat not in win_ctx:
                continue
            val = latest_bar[feat]
            if val != val:
                continue
            w_mean = win_ctx[feat]
            l_mean = loss_ctx.get(feat, w_mean)
            dist_win = abs(val - w_mean)
            dist_loss = abs(val - l_mean)
            total_weight += float(weight)
            win_label = "Lãi" if is_v2 else "Thắng"
            loss_label = "Lỗ" if is_v2 else "Thua"
            if dist_win <= dist_loss:
                score += float(weight)
                reasons.append(f"🟢 `{feat}` = {val:.2f} (gần vùng {win_label} ~{w_mean:.2f})")
            else:
                reasons.append(f"🔴 `{feat}` = {val:.2f} (gần vùng {loss_label} ~{l_mean:.2f})")

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
            "cv_accuracy": profile.get("cv_accuracy", 0),
            "pred_expectancy": None,
            "is_toxic": status == "BLOCK",
            "is_safe": status == "PASS",
            "leaf_id": None,
            "eval_mode": "legacy_centroid",
            "oos_status": profile.get("oos_status", "N/A"),
            "block_precision": profile.get("block_precision", 0),
        }

    return {
        "latest_bar": latest_bar,
        "latest_time": latest_time,
        "dna_features_ok": True,
        "evaluations": results,
    }



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
    parser.add_argument('--live', default=None, help='Symbol to monitor live (e.g. XAUUSD=X, XAUUSD)')
    parser.add_argument('--source', default='Yahoo Finance API (REST API)', help='Live source: Yahoo Finance API (REST API) or MetaTrader 5 (Direct Terminal Bridge)')
    parser.add_argument('--timeframe', default='1h', help='Timeframe for live evaluation (default: 1h)')
    parser.add_argument('--backtest', default=None, help='Path to backtest result file (xlsx/csv)')
    parser.add_argument('--periods', default=None, help='Manual periods: "start1,end1;start2,end2" (YYYY-MM-DD)')
    parser.add_argument('--threshold', type=float, default=5.0, help='Sideways threshold %% (default: 5.0)')
    parser.add_argument('--min-days', type=int, default=15, help='Minimum sideways duration in days (default: 15)')
    parser.add_argument('--output', default=None, help='Output directory (default: ./regime_output)')
    args = parser.parse_args()

    if args.live or not args.ohlc:
        sym = args.live or "XAUUSD=X"
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
