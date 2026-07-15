"""
Strategy Analyzer Dashboard — Streamlit
Phân tích toàn diện chiến lược giao dịch từ file backtest MT5.
Usage: streamlit run strategy_analyzer.py
"""
import streamlit as st
import pandas as pd
import numpy as np
import plotly.graph_objects as go
import plotly.express as px
from plotly.subplots import make_subplots
from scipy import stats
import os, warnings, glob, io

# Monkeypatch openpyxl's CellRange row limit (1,048,576) to allow loading files with larger dimensions or merged cell ranges.
try:
    from openpyxl.worksheet.cell_range import CellRange
    CellRange.min_row.max = 100000000
    CellRange.max_row.max = 100000000
except ImportError:
    pass

try:
    from google.oauth2 import service_account
    from google.auth.transport.requests import Request
    from google_auth_oauthlib.flow import InstalledAppFlow
    from googleapiclient.discovery import build
    from googleapiclient.http import MediaIoBaseDownload, MediaFileUpload
    import pickle
    GOOGLE_DRIVE_AVAILABLE = True
except ImportError:
    GOOGLE_DRIVE_AVAILABLE = False

# ============================================================
# GOOGLE DRIVE SYNC
# ============================================================

class RawDealsWrapper:
    def __init__(self, df):
        self.df = df
    def __eq__(self, other):
        return id(self) == id(other)

def get_secret(key, default=None):
    try:
        if key in st.secrets:
            return st.secrets[key]
    except Exception:
        pass
    return default

def get_drive_service():
    if not GOOGLE_DRIVE_AVAILABLE: return None
    
    SCOPES = ['https://www.googleapis.com/auth/drive']
    creds = None

    try:
        from google.oauth2.credentials import Credentials as OAuthCredentials
        from google.auth.exceptions import RefreshError
        
        # Phương án 1: OAuth 2.0 User Flow từ Streamlit Cloud Secrets [google_oauth_token]
        oauth_secret = get_secret("google_oauth_token")
        if oauth_secret:
            try:
                creds = OAuthCredentials.from_authorized_user_info(dict(oauth_secret), SCOPES)
                if creds and creds.expired and creds.refresh_token:
                    creds.refresh(Request())
                if creds and creds.valid:
                    return build('drive', 'v3', credentials=creds)
            except RefreshError as re:
                st.sidebar.error(
                    "⚠️ **Token Google Drive trên Streamlit Cloud Secrets đã hết hạn (`invalid_grant`).**\n\n"
                    "**Nguyên nhân:** OAuth App trên Google Cloud Console đang ở chế độ `Testing` (tự hết hạn sau 7 ngày).\n\n"
                    "**Cách khắc phục vĩnh viễn:**\n"
                    "1. Vào Google Cloud Console -> **OAuth consent screen** -> bấm **PUBLISH APP**.\n"
                    "2. Chạy lại app ở máy Local để đăng nhập cấp lại `token.json` mới.\n"
                    "3. Copy nội dung `token.json` mới vào `[google_oauth_token]` trong Secrets trên Streamlit Cloud!"
                )
                return None
            except Exception as e:
                st.sidebar.warning(f"Lỗi khởi tạo Drive từ Secrets: {e}")

        # Phương án 2: OAuth 2.0 User Flow từ file local (token.json hoặc token.pickle)
        if os.path.exists('token.json'):
            creds = OAuthCredentials.from_authorized_user_file('token.json', SCOPES)
        elif os.path.exists('token.pickle'):
            with open('token.pickle', 'rb') as token:
                creds = pickle.load(token)
                
        if creds and creds.expired and creds.refresh_token:
            try:
                creds.refresh(Request())
                if os.path.exists('token.json'):
                    with open('token.json', 'w', encoding='utf-8') as f:
                        f.write(creds.to_json())
                elif os.path.exists('token.pickle'):
                    with open('token.pickle', 'wb') as token:
                        pickle.dump(creds, token)
            except Exception as e:
                # Token hết hạn 7 ngày / thu hồi -> Xóa file cũ để kích hoạt lại quy trình xác thực qua trình duyệt
                if os.path.exists('token.json'):
                    try: os.remove('token.json')
                    except Exception: pass
                if os.path.exists('token.pickle'):
                    try: os.remove('token.pickle')
                    except Exception: pass
                creds = None
        elif not creds or not creds.valid:
            pass

        if not creds or not creds.valid:
            if os.path.exists('credentials.json'):
                flow = InstalledAppFlow.from_client_secrets_file('credentials.json', SCOPES)
                creds = flow.run_local_server(port=0)
                with open('token.json', 'w', encoding='utf-8') as f:
                    f.write(creds.to_json())
                with open('token.pickle', 'wb') as token:
                    pickle.dump(creds, token)
                
        if creds and creds.valid:
            return build('drive', 'v3', credentials=creds)
            
        # Phương án 3: Service Account (Dành cho Shared Drives)
        gcp_account = get_secret("gcp_service_account")
        if gcp_account:
            creds = service_account.Credentials.from_service_account_info(
                dict(gcp_account), scopes=SCOPES
            )
            return build('drive', 'v3', credentials=creds)
            
    except Exception as e:
        st.sidebar.error(f"Lỗi khởi tạo Google Drive: {e}")
        
    return None

def sync_drive(service, folder_id, local_dir, force_upload_file=None):
    try:
        os.makedirs(local_dir, exist_ok=True)
        # Download từ Drive danh sách file hiện có (xử lý phân trang nextPageToken và chọn file mới nhất nếu trùng tên)
        drive_files = {}
        page_token = None
        while True:
            results = service.files().list(
                q=f"'{folder_id}' in parents and trashed=false", 
                fields="nextPageToken, files(id, name, modifiedTime)",
                pageSize=1000,
                pageToken=page_token,
                supportsAllDrives=True,
                includeItemsFromAllDrives=True
            ).execute()
            for item in results.get('files', []):
                name = item.get('name')
                if not name:
                    continue
                mod_time = item.get('modifiedTime', '')
                # Nếu có nhiều file trùng tên trên Drive, ưu tiên lấy bản có modifiedTime mới nhất
                if name not in drive_files or mod_time > drive_files[name].get('modifiedTime', ''):
                    drive_files[name] = {'id': item['id'], 'modifiedTime': mod_time}
            page_token = results.get('nextPageToken')
            if not page_token:
                break
        
        file_id_map = {name: info['id'] for name, info in drive_files.items()}
        
        # Ưu tiên đẩy file vừa tải lên/lưu mới (hoặc cập nhật nếu đã tồn tại tên file)
        if force_upload_file and os.path.exists(force_upload_file):
            name = os.path.basename(force_upload_file)
            media = MediaFileUpload(force_upload_file, resumable=True)
            if name in file_id_map:
                service.files().update(
                    fileId=file_id_map[name],
                    media_body=media,
                    supportsAllDrives=True
                ).execute()
            else:
                res = service.files().create(
                    body={'name': name, 'parents': [folder_id]}, 
                    media_body=media, 
                    fields='id',
                    supportsAllDrives=True
                ).execute()
                file_id_map[name] = res.get('id')
        
        # Download từ Drive về local
        critical_json_files = {"strategy_regime_registry.json", "live_watchlist.json", "live_monitor_history.json"}
        from datetime import datetime
        for name, file_id in file_id_map.items():
            local_path = os.path.join(local_dir, name)
            should_download = not os.path.exists(local_path) or os.path.getsize(local_path) == 0
            
            # Nếu file đã tồn tại cục bộ, so sánh thời gian sửa đổi của Drive với local để quyết định tải lại
            if not should_download and os.path.exists(local_path):
                try:
                    drive_mod_time_str = drive_files[name].get('modifiedTime', '').replace('Z', '+00:00')
                    drive_mtime = datetime.fromisoformat(drive_mod_time_str).timestamp()
                    local_mtime = os.path.getmtime(local_path)
                    # Nếu file trên Drive mới hơn (trên 2 giây để tránh lệch đồng hồ nhỏ), tải về cập nhật
                    if drive_mtime > local_mtime + 2:
                        should_download = True
                except Exception:
                    pass

            # Khi đồng bộ chung (force_upload_file is None), luôn tải các file cấu hình JSON quan trọng từ Drive nếu trên Drive có
            if not force_upload_file and name in critical_json_files:
                should_download = True
                
            if should_download:
                request = service.files().get_media(fileId=file_id)
                with io.FileIO(local_path, 'wb') as fh:
                    downloader = MediaIoBaseDownload(fh, request)
                    done = False
                    while not done: _, done = downloader.next_chunk()
        
        # Upload các file local mới chưa có trên Drive (loại trừ file cache tạm thời)
        for f in glob.glob(os.path.join(local_dir, "*.*")):
            name = os.path.basename(f)
            if name not in file_id_map and not name.endswith(".cache.pkl"):
                media = MediaFileUpload(f, resumable=True)
                service.files().create(
                    body={'name': name, 'parents': [folder_id]}, 
                    media_body=media, 
                    fields='id',
                    supportsAllDrives=True
                ).execute()
    except Exception as e:
        err_str = str(e)
        if "storageQuotaExceeded" in err_str or "Service Accounts do not have storage quota" in err_str:
            st.sidebar.error(
                "❌ Google Drive: Service Account không có dung lượng lưu trữ trên Google Drive cá nhân (0 bytes). "
                "Tải xuống (Download) thành công nhưng Upload bị chặn. Để khắc phục: Sử dụng 'Shared Drive' (Google Workspace) "
                "hoặc chuyển sang xác thực bằng OAuth 2.0 User Credentials."
            )
        else:
            st.sidebar.error(f"Lỗi đồng bộ Drive: {e}")

# ============================================================
# CONFIG
# ============================================================
BACKTEST_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "backtest result")

st.set_page_config(page_title="Strategy Analyzer", layout="wide", page_icon="📊")

# ============================================================
# DATA LOADING
# ============================================================
def is_ohlc_file(filepath):
    if not str(filepath).lower().endswith('.csv') or str(filepath).endswith("_regime_features.csv"):
        return False
    try:
        with open(filepath, 'r', encoding='utf-8', errors='ignore') as f:
            lines = [f.readline().lower() for _ in range(5)]
            content = " ".join(lines)
            if '<open>' in content or '\topen\t' in content or 'open,' in content or ',open' in content:
                return True
    except Exception:
        pass
    return False

def get_mt5_metric(raw_df, label_str, header_idx):
    limit = min(header_idx, 80)
    for r in range(limit):
        for c in range(len(raw_df.columns)):
            val = str(raw_df.iloc[r, c]).strip()
            if label_str.lower() in val.lower():
                for nc in range(c + 1, len(raw_df.columns)):
                    v = str(raw_df.iloc[r, nc]).strip()
                    if v not in ('nan', 'None', ''):
                        return v
    return None

# Bump when trades schema / OpenTime pairing changes — invalidates stale .cache.pkl
BACKTEST_CACHE_VERSION = 3


def _open_time_coverage(trades):
    """Fraction of rows with valid OpenTime (0..1)."""
    if trades is None or len(trades) == 0:
        return 0.0
    if 'OpenTime' not in trades.columns:
        return 0.0
    return float(pd.to_datetime(trades['OpenTime'], errors='coerce').notna().mean())


def _normalize_deals_direction(series):
    """Map MT5 Direction variants → in/out."""
    s = series.astype(str).str.strip().str.lower()
    s = s.replace({
        'in': 'in', 'out': 'out',
        'entry': 'in', 'exit': 'out',
        'enter': 'in', 'close': 'out',
        'buy': 'in', 'sell': 'out',  # rare mis-exports
        '0': 'in', '1': 'out',
    })
    return s


def _pair_open_times_onto_trades(trades, deals_df, log_progress=None):
    """
    Ensure trades has OpenTime via Order-join then FIFO volume pairing.
    deals_df must contain full IN+OUT deal stream when available.
    """
    log = log_progress or (lambda m: None)
    if trades is None or len(trades) == 0:
        return trades, 0

    out = trades.copy()
    open_matched = 0
    df = deals_df

    if df is not None and 'Direction' in df.columns:
        df = df.copy()
        df['_dir'] = _normalize_deals_direction(df['Direction'])
        if 'Order' in df.columns and 'Order' in out.columns:
            entries = df[df['_dir'] == 'in'].copy()
            if not entries.empty:
                entry_map = entries.set_index('Order')[['Time', 'Price', 'Type']].rename(
                    columns={'Time': 'OpenTime', 'Price': 'OpenPrice', 'Type': 'TradeType'})
                # drop stale OpenTime before merge
                out = out.drop(columns=[c for c in ['OpenTime', 'OpenPrice', 'TradeType'] if c in out.columns], errors='ignore')
                out = out.merge(entry_map, left_on='Order', right_index=True, how='left')
                open_matched = int(out['OpenTime'].notna().sum()) if 'OpenTime' in out.columns else 0
                log(f"🔗 Order-join OpenTime: {open_matched}/{len(out)}")

        if open_matched < max(1, int(0.95 * len(out))):
            try:
                import importlib
                import regime_analyzer as _ra
                _ra = importlib.reload(_ra)
                # Use normalized Direction for FIFO
                deals_for_fifo = df.copy()
                deals_for_fifo['Direction'] = df['_dir']
                paired = _ra.ensure_trade_open_times_from_deals(deals_for_fifo)
                if paired is not None and not paired.empty and 'OpenTime' in paired.columns:
                    key = ['Time', 'Profit'] if 'Profit' in out.columns and 'Profit' in paired.columns else ['Time']
                    keep_cols = ['OpenTime']
                    if 'OpenPrice' in paired.columns:
                        keep_cols.append('OpenPrice')
                    if 'TradeType' in paired.columns:
                        keep_cols.append('TradeType')
                    out = out.drop(columns=[c for c in keep_cols if c in out.columns], errors='ignore')
                    # avoid duplicate keys after merge
                    merge_src = paired[key + keep_cols].drop_duplicates(key, keep='first')
                    out = out.merge(merge_src, on=key, how='left')
                    open_matched = int(out['OpenTime'].notna().sum()) if 'OpenTime' in out.columns else 0
                    log(f"✅ FIFO IN/OUT OpenTime: {open_matched}/{len(out)}")
            except Exception as e:
                log(f"⚠️ FIFO OpenTime failed: {e}")

    if 'OpenTime' in out.columns:
        out['OpenTime'] = pd.to_datetime(out['OpenTime'], errors='coerce')
        if 'Time' in out.columns:
            out['Duration'] = (pd.to_datetime(out['Time'], errors='coerce') - out['OpenTime']).dt.total_seconds() / 3600.0
    return out, open_matched


def extract_mt5_deals_table(file_path):
    """Load full MT5 Deals table (IN+OUT) from backtest xlsx/csv. Returns DataFrame or None."""
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
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

    deals_mask = raw[0].astype(str).str.strip() == 'Deals'
    if not deals_mask.any():
        # fallback: any cell equals Deals
        deals_mask = raw.apply(lambda col: col.astype(str).str.strip() == 'Deals').any(axis=1)
    if not deals_mask.any():
        return None

    deals_start = raw[deals_mask].index[0]
    header_idx = deals_start + 1
    df = raw.iloc[header_idx + 1:].copy()
    df.columns = raw.iloc[header_idx].values

    col_map = {}
    for c in df.columns:
        cs = str(c).strip().lower()
        if cs == 'time': col_map[c] = 'Time'
        elif cs == 'deal': col_map[c] = 'Deal'
        elif cs == 'symbol': col_map[c] = 'Symbol'
        elif cs == 'type': col_map[c] = 'Type'
        elif cs == 'direction': col_map[c] = 'Direction'
        elif cs == 'volume': col_map[c] = 'Volume'
        elif cs == 'price': col_map[c] = 'Price'
        elif cs == 'profit': col_map[c] = 'Profit'
        elif cs == 'balance': col_map[c] = 'Balance'
        elif cs == 'swap': col_map[c] = 'Swap'
        elif cs == 'commission': col_map[c] = 'Commission'
        elif cs == 'comment': col_map[c] = 'Comment'
        elif cs == 'order': col_map[c] = 'Order'
    df.rename(columns=col_map, inplace=True)
    if 'Time' not in df.columns:
        return None
    df['Time'] = pd.to_datetime(df['Time'], errors='coerce')
    df.dropna(subset=['Time'], inplace=True)
    for nc in ['Profit', 'Balance', 'Volume', 'Price', 'Swap', 'Commission']:
        if nc in df.columns:
            df[nc] = pd.to_numeric(df[nc], errors='coerce')
    if 'Direction' in df.columns:
        df['Direction'] = _normalize_deals_direction(df['Direction'])
    # drop trailing empty / balance-only junk rows without type+direction
    if 'Direction' in df.columns:
        df = df[df['Direction'].isin(['in', 'out']) | df['Profit'].notna()].copy()
    return df.reset_index(drop=True)


def ensure_trades_have_open_time(trades, backtest_path=None, deals_df=None, log_progress=None):
    """
    Public helper for DNA train: guarantee OpenTime on trades.
    Re-reads deals from backtest_path if needed (Streamlit cache strips attrs).
    """
    log = log_progress or (lambda m: None)
    if trades is None or len(trades) == 0:
        return trades, 0.0

    cov = _open_time_coverage(trades)
    if cov >= 0.95:
        return trades, cov

    raw = deals_df
    if raw is None:
        wrap = getattr(trades, 'attrs', {}).get('raw_deals')
        raw = wrap.df if hasattr(wrap, 'df') else wrap
    if (raw is None or (hasattr(raw, 'empty') and raw.empty)) and backtest_path and os.path.exists(backtest_path):
        log(f"📥 Re-load Deals từ file để ghép OpenTime: {os.path.basename(backtest_path)}")
        raw = extract_mt5_deals_table(backtest_path)

    if raw is None or (hasattr(raw, 'empty') and raw.empty):
        log("⚠️ Không lấy được bảng Deals để ghép OpenTime.")
        return trades, cov

    paired, n_matched = _pair_open_times_onto_trades(trades, raw, log_progress=log)
    try:
        paired.attrs['raw_deals'] = RawDealsWrapper(raw)
        paired.attrs['open_time_matched'] = n_matched
        paired.attrs['open_time_total'] = len(paired)
    except Exception:
        pass
    return paired, _open_time_coverage(paired)


@st.cache_data
def load_backtest(file_path):
    import pickle
    cache_path = file_path + ".cache.pkl"

    def _cache_usable(trades_obj):
        if trades_obj is None or len(trades_obj) == 0:
            return False
        # Require OpenTime for DNA v2 (versioned cache)
        return _open_time_coverage(trades_obj) >= 0.8

    if os.path.exists(cache_path) and os.path.getmtime(cache_path) >= os.path.getmtime(file_path):
        try:
            with open(cache_path, "rb") as f:
                cached = pickle.load(f)
            if isinstance(cached, tuple) and len(cached) >= 2:
                trades, metrics = cached[0], cached[1]
                cache_ver = metrics.get('_cache_version', 0) if isinstance(metrics, dict) else 0
                if cache_ver >= BACKTEST_CACHE_VERSION and _cache_usable(trades):
                    # Re-pair if Streamlit/pickle dropped coverage edge cases
                    if _open_time_coverage(trades) < 0.95:
                        trades, _ = ensure_trades_have_open_time(trades, backtest_path=file_path)
                    return trades, metrics, None
                # stale cache (no OpenTime) → fall through rebuild
        except Exception:
            pass

    # Cache missed, start progress display
    status = None
    if hasattr(st, "status"):
        status = st.status(f"🔍 Đang phân tích file: {os.path.basename(file_path)}", expanded=True)
    else:
        status_placeholder = st.empty()

    def log_progress(msg):
        if status:
            status.write(msg)
        else:
            status_placeholder.text(msg)

    log_progress("📥 Bước 1: Đang nạp tệp dữ liệu vào bộ nhớ...")
    df = extract_mt5_deals_table(file_path)
    if df is None or df.empty:
        if status:
            status.update(label="❌ Lỗi: Không tìm thấy bảng Deals trong tệp!", state="error")
        return None, None, None

    # header metrics still need raw sheet — light re-read for metrics only
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
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
    deals_mask = raw[0].astype(str).str.strip() == 'Deals'
    if not deals_mask.any():
        deals_mask = raw.apply(lambda col: col.astype(str).str.strip() == 'Deals').any(axis=1)
    header_idx = deals_mask.idxmax() + 1 if deals_mask.any() else 0

    log_progress("📊 Bước 3: Đang trích xuất và làm sạch dữ liệu giao dịch...")
    if 'Direction' in df.columns:
        trades = df[df['Direction'].isin(['out'])].copy()
        if trades.empty:
            # fallback if direction labels unexpected
            trades = df[df['Profit'].notna() & (df['Profit'] != 0)].copy()
    else:
        trades = df[df['Profit'].notna() & (df['Profit'] != 0)].copy()

    log_progress("🔗 Bước 4: Đang đối chiếu các vị thế In/Out (khớp lệnh vào/ra)...")
    trades, open_matched = _pair_open_times_onto_trades(trades, df, log_progress=log_progress)
    cov = _open_time_coverage(trades)
    if cov < 0.95:
        log_progress(
            f"⚠️ OpenTime coverage {open_matched}/{len(trades)} ({cov*100:.1f}%) — "
            f"DNA có thể map sai nếu martingale/multi-position."
        )
    else:
        log_progress(f"✅ OpenTime OK: {open_matched}/{len(trades)} ({cov*100:.1f}%)")

    try:
        trades.attrs['raw_deals'] = RawDealsWrapper(df)
        trades.attrs['open_time_matched'] = open_matched
        trades.attrs['open_time_total'] = len(trades)
        trades.attrs['backtest_path'] = file_path
    except Exception:
        pass
    trades.reset_index(drop=True, inplace=True)

    log_progress("📈 Bước 5: Đang tổng hợp các chỉ số hiệu suất từ Header...")
    # Extract header metrics
    metrics = {}
    for label, key in [('Total Net Profit:', 'net_profit'), ('Initial Deposit:', 'init_deposit'),
                        ('Profit Factor:', 'profit_factor'), ('Sharpe Ratio:', 'sharpe'),
                        ('Recovery Factor:', 'recovery_factor'), ('Expected Payoff:', 'expected_payoff'),
                        ('Total Trades:', 'total_trades')]:
        v = get_mt5_metric(raw, label, header_idx)
        if v:
            try: metrics[key] = float(v.replace(' ', '').replace(',', ''))
            except: metrics[key] = v

    # Equity DD
    dd_str = get_mt5_metric(raw, 'Equity Drawdown Maximal:', header_idx)
    if dd_str and '(' in dd_str:
        try: metrics['max_dd_pct'] = float(dd_str.split('(')[1].split('%')[0])
        except: pass

    wr_str = get_mt5_metric(raw, 'Profit Trades (% of total):', header_idx)
    if wr_str and '(' in wr_str:
        try: metrics['win_rate'] = float(wr_str.split('(')[1].split('%')[0])
        except: pass

    metrics['_cache_version'] = BACKTEST_CACHE_VERSION
    metrics['open_time_coverage'] = round(_open_time_coverage(trades) * 100, 1)

    log_progress("💾 Bước 6: Đang lưu trữ dữ liệu đã phân giải vào bộ nhớ đệm (Cache)...")
    try:
        with open(cache_path, "wb") as f:
            # Do not pickle RawDealsWrapper (fragile); OpenTime columns are enough.
            # raw_deals re-loaded from file on DNA train if needed.
            pickle.dump((trades.copy(), metrics), f, protocol=pickle.HIGHEST_PROTOCOL)
    except Exception:
        pass

    if status:
        status.update(label="✅ Hoàn tất phân tích dữ liệu!", state="complete", expanded=False)
    else:
        status_placeholder.empty()

    return trades, metrics, df

# ============================================================
# METRICS COMPUTATION
# ============================================================
def compute_metrics(trades, mt5_metrics):
    profits = trades['Profit'].dropna()
    wins = profits[profits > 0]
    losses = profits[profits < 0]

    m = {}
    m['Total Trades'] = len(profits)
    m['Net Profit ($)'] = profits.sum()
    m['Win Rate (%)'] = mt5_metrics.get('win_rate', (len(wins)/len(profits)*100 if len(profits) > 0 else 0))
    m['Profit Factor'] = mt5_metrics.get('profit_factor', (wins.sum() / abs(losses.sum()) if len(losses) > 0 and losses.sum() != 0 else 0))
    m['Avg Win ($)'] = wins.mean() if len(wins) > 0 else 0
    m['Avg Loss ($)'] = losses.mean() if len(losses) > 0 else 0
    m['Avg R:R'] = abs(m['Avg Win ($)'] / m['Avg Loss ($)']) if m['Avg Loss ($)'] != 0 else 0
    m['Expectancy ($)'] = mt5_metrics.get('expected_payoff', profits.mean() if len(profits) > 0 else 0)
    m['Max DD (%)'] = mt5_metrics.get('max_dd_pct', 0)
    m['Sharpe Ratio'] = mt5_metrics.get('sharpe', 0)
    m['Recovery Factor'] = mt5_metrics.get('recovery_factor', 0)
    
    if 'Time' in trades.columns and not trades.empty:
        dates = trades['Time'].dt.date
        min_date = dates.min()
        max_date = dates.max()
        total_days = (max_date - min_date).days + 1
        m['Avg Trades/Day'] = len(trades) / total_days if total_days > 0 else len(trades)
        m['Days Without Trades'] = total_days - dates.nunique()
        m['Daily Return ($)'] = trades.groupby(dates)['Profit'].sum().mean()
        m['Weekly Return ($)'] = trades.groupby(trades['Time'].dt.to_period('W'))['Profit'].sum().mean()
        m['Monthly Return ($)'] = trades.groupby(trades['Time'].dt.to_period('M'))['Profit'].sum().mean()
    else:
        m['Avg Trades/Day'] = 0
        m['Days Without Trades'] = 0
        m['Daily Return ($)'] = 0
        m['Weekly Return ($)'] = 0
        m['Monthly Return ($)'] = 0

    return m

# ============================================================
# STREAK AND MONTHLY ANALYSIS COMPUTATIONS
# ============================================================
def get_streaks(profits):
    win_streaks = []
    loss_streaks = []
    
    current_win = 0
    current_loss = 0
    
    for p in profits:
        if p > 0:
            if current_loss > 0:
                loss_streaks.append(current_loss)
                current_loss = 0
            current_win += 1
        elif p < 0:
            if current_win > 0:
                win_streaks.append(current_win)
                current_win = 0
            current_loss += 1
        else: # p == 0
            # Treat exactly 0 profit as loss/flat to be conservative
            if current_win > 0:
                win_streaks.append(current_win)
                current_win = 0
            current_loss += 1
            
    if current_win > 0:
        win_streaks.append(current_win)
    if current_loss > 0:
        loss_streaks.append(current_loss)
        
    avg_win_streak = np.mean(win_streaks) if win_streaks else 0.0
    max_win_streak = np.max(win_streaks) if win_streaks else 0
    avg_loss_streak = np.mean(loss_streaks) if loss_streaks else 0.0
    max_loss_streak = np.max(loss_streaks) if loss_streaks else 0
    
    return avg_win_streak, max_win_streak, avg_loss_streak, max_loss_streak

def get_daily_streaks(trades):
    if 'Time' not in trades.columns or trades.empty:
        return 0.0, 0, 0.0, 0
    df_daily = trades.groupby(trades['Time'].dt.date)['Profit'].sum().reset_index()
    df_daily = df_daily.sort_values('Time')
    daily_profits = df_daily['Profit'].values
    
    win_days_streaks = []
    loss_days_streaks = []
    
    current_win = 0
    current_loss = 0
    
    for p in daily_profits:
        if p > 0:
            if current_loss > 0:
                loss_days_streaks.append(current_loss)
                current_loss = 0
            current_win += 1
        else: # p <= 0
            if current_win > 0:
                win_days_streaks.append(current_win)
                current_win = 0
            current_loss += 1
            
    if current_win > 0:
        win_days_streaks.append(current_win)
    if current_loss > 0:
        loss_days_streaks.append(current_loss)
        
    avg_win_days = np.mean(win_days_streaks) if win_days_streaks else 0.0
    max_win_days = np.max(win_days_streaks) if win_days_streaks else 0
    avg_loss_days = np.mean(loss_days_streaks) if loss_days_streaks else 0.0
    max_loss_days = np.max(loss_days_streaks) if loss_days_streaks else 0
    
    return avg_win_days, max_win_days, avg_loss_days, max_loss_days

def get_monthly_win_loss_ratio(trades):
    if 'Time' not in trades.columns or trades.empty:
        return 0, 0, 0.0
    df_monthly = trades.groupby(trades['Time'].dt.to_period('M'))['Profit'].sum().reset_index()
    win_months = (df_monthly['Profit'] > 0).sum()
    loss_months = (df_monthly['Profit'] < 0).sum()
    
    total_months = win_months + loss_months
    win_ratio = (win_months / total_months * 100) if total_months > 0 else 0.0
    
    return win_months, loss_months, win_ratio

def get_sideways_periods(trades, threshold_pct, min_days):
    if 'Balance' not in trades.columns or 'Time' not in trades.columns or trades.empty:
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
                'max_dd_pct': (max_b - min_b) / start_bal * 100
            })
            i = best_j + 1
        else:
            i += 1
            
    return periods

def get_longest_stagnation(trades):
    if 'Balance' not in trades.columns or 'Time' not in trades.columns or trades.empty:
        return None, None, 0
    bal = trades[['Time', 'Balance']].dropna().copy()
    if bal.empty: return None, None, 0
    
    bal = bal.sort_values('Time').reset_index(drop=True)
    bal['Peak'] = bal['Balance'].cummax()
    bal['Peak_Changed'] = bal['Peak'] != bal['Peak'].shift(1)
    bal['Peak_ID'] = bal['Peak_Changed'].cumsum()
    
    groups = bal.groupby('Peak_ID')
    max_duration = 0
    max_start = None
    max_end = None
    
    peak_ids = sorted(groups.groups.keys())
    for i, pid in enumerate(peak_ids):
        group = groups.get_group(pid)
        start_time = group['Time'].iloc[0]
        
        if i + 1 < len(peak_ids):
            next_group = groups.get_group(peak_ids[i+1])
            end_time = next_group['Time'].iloc[0]
        else:
            end_time = group['Time'].iloc[-1]
            
        duration = (end_time - start_time).days
        if duration > max_duration:
            max_duration = duration
            max_start = start_time
            max_end = end_time
                
    return max_start, max_end, max_duration

def generate_markdown_report(file_name, m, streaks, daily_streaks, monthly,
                             loss_insights, general_insights,
                             stag_start, stag_end, stag_duration,
                             sideways_periods=None,
                             mc_data=None,
                             wfe_data=None,
                             monthly_stats_df=None,
                             hour_profit_series=None,
                             dow_profit_series=None):
    avg_win_streak, max_win_streak, avg_loss_streak, max_loss_streak = streaks
    avg_win_days, max_win_days, avg_loss_days, max_loss_days = daily_streaks
    win_months, loss_months, win_month_ratio = monthly
    
    stag_info = ""
    if stag_duration > 0 and stag_start and stag_end:
        stag_info = f"- **Thời gian phục hồi đỉnh lâu nhất**: {stag_duration} ngày (từ {stag_start.strftime('%d/%m/%Y')} đến {stag_end.strftime('%d/%m/%Y')})\n"

    sideways_info = ""
    if sideways_periods:
        sideways_info = "\n### Giai đoạn đi ngang (theo bộ lọc)\n"
        for p in sideways_periods:
            sideways_info += f"- Từ **{p['start'].strftime('%d/%m/%Y')}** đến **{p['end'].strftime('%d/%m/%Y')}**: {p['duration']} ngày, biến động {p['max_dd_pct']:.2f}%\n"

    md = f"""# Báo Cáo Phân Tích Chiến Lược Giao Dịch

- **Tệp phân tích**: {file_name}

## 1️⃣ Chỉ Số Cơ Bản (Core Metrics)
- **Tổng số lệnh (Total Trades)**: {m['Total Trades']} (Trung bình: {m.get('Avg Trades/Day', 0):.2f} lệnh/ngày)
- **Số ngày không có lệnh**: {m.get('Days Without Trades', 0)} ngày ({m.get('Days Without Trades %', 0):.1f}%)
- **Lợi nhuận ròng (Net Profit)**: ${m['Net Profit ($)']:,.2f}
- **Trung bình Lợi nhuận Hàng Ngày**: ${m.get('Daily Return ($)', 0):,.2f}
- **Trung bình Lợi nhuận Hàng Tuần**: ${m.get('Weekly Return ($)', 0):,.2f}
- **Trung bình Lợi nhuận Hàng Tháng**: ${m.get('Monthly Return ($)', 0):,.2f}
- **Tỷ lệ thắng (Win Rate)**: {m['Win Rate (%)']:.1f}%
- **Yếu tố lợi nhuận (Profit Factor)**: {m['Profit Factor']:.2f}
- **Sụt giảm vốn lớn nhất (Max DD)**: {m['Max DD (%)']:.2f}%
- **Hệ số phục hồi (Recovery Factor)**: {m.get('Recovery Factor', 0):.2f}
{stag_info}- **Hệ số Sharpe (Sharpe Ratio)**: {m['Sharpe Ratio']:.2f}
- **Kỳ vọng lệnh (Expectancy)**: ${m['Expectancy ($)']:.2f}
- **Lợi nhuận TB lệnh thắng (Avg Win)**: ${m['Avg Win ($)']:.2f}
- **Thua lỗ TB lệnh thua (Avg Loss)**: ${m['Avg Loss ($)']:.2f}
- **Tỷ lệ R:R trung bình (Avg R:R)**: {m['Avg R:R']:.2f}

## 2️⃣ Phân Tích Chuỗi Giao Dịch & Chu Kỳ Tháng
### Chuỗi lệnh liên tiếp (Trade Streaks)
- **Lãi liên tiếp trung bình**: {avg_win_streak:.1f} lệnh (Cực đại: {max_win_streak} lệnh)
- **Lỗ liên tiếp trung bình**: {avg_loss_streak:.1f} lệnh (Cực đại: {max_loss_streak} lệnh)

### Chuỗi ngày liên tiếp (Daily Streaks)
- **Ngày lãi liên tiếp trung bình**: {avg_win_days:.1f} ngày (Cực đại: {max_win_days} ngày)
- **Ngày lỗ liên tiếp trung bình**: {avg_loss_days:.1f} ngày (Cực đại: {max_loss_days} ngày)

### Kỳ tháng (Monthly Ratio)
- **Tỉ lệ tháng Lãi / Lỗ**: {win_months} tháng lãi / {loss_months} tháng lỗ
- **Phần trăm số tháng lãi**: {win_month_ratio:.1f}%
{sideways_info}
## 3️⃣ Phân Tích Cấu Trúc Lỗ (Loss Attribution)
"""
    if loss_insights:
        for ins in loss_insights:
            clean_ins = ins.replace('🔍 ', '').replace('👉 ', '').replace('📌 ', '')
            md += f"- {clean_ins}\n"
    else:
        md += "- Không phát hiện điểm yếu rõ rệt ở các chiều hoặc cấu trúc dữ liệu không đủ phân tích.\n"

    # Top 5 worst months table
    if monthly_stats_df is not None and not monthly_stats_df.empty:
        md += "\n### Top 5 Tháng Thua Lỗ Nặng Nhất\n"
        md += "| Tháng | Net Profit ($) | Số lệnh | Win Rate % | Long PnL ($) | Short PnL ($) |\n"
        md += "|-------|--------------|---------|-----------|-------------|--------------|\n"
        for _, row in monthly_stats_df.head(5).iterrows():
            md += f"| {row['YearMonth']} | {row['Net Profit']:,.0f} | {int(row['Trades'])} | {row['Win Rate %']:.1f}% | {row.get('Long PnL', 0):,.0f} | {row.get('Short PnL', 0):,.0f} |\n"

    md += "\n## 4️⃣ Phân Tích Chuyên Sâu & Tổng Kết (Quant Insights)\n"
    for ins in general_insights:
        clean_ins = ins.replace('✅ ', '').replace('❌ ', '').replace('⚠️ ', '').replace('🔴 ', '').replace('🟢 ', '')
        md += f"- {clean_ins}\n"

    # Monte Carlo section
    if mc_data:
        md += f"""\n## 5️⃣ Monte Carlo Simulation (10,000 lần)
- **Xác suất cháy tài khoản (< 50% vốn)**: {mc_data.get('risk_of_ruin', 0):.2f}%
- **Equity trung vị**: ${mc_data.get('median_eq', 0):,.0f}
- **Khoảng tin cậy 90%**: ${mc_data.get('p5', 0):,.0f} — ${mc_data.get('p95', 0):,.0f}
- **Worst Drawdown (MC)**: {mc_data.get('worst_dd', 0):.1f}%
"""

    # WFE section
    if wfe_data:
        md += f"""\n## 6️⃣ Walk-Forward Efficiency (WFE)
- **In-Sample Profit**: ${wfe_data.get('is_profit', 0):,.2f} ({wfe_data.get('is_days', 0)} ngày)
- **Out-of-Sample Profit**: ${wfe_data.get('oos_profit', 0):,.2f} ({wfe_data.get('oos_days', 0)} ngày)
- **WFE (Tuyệt đối)**: {wfe_data.get('wfe', 0)*100:.1f}%
- **WFE (Thường niên)**: {wfe_data.get('annual_wfe', 0)*100:.1f}%
"""

    # Hourly breakdown
    if hour_profit_series is not None and not hour_profit_series.empty:
        md += "\n## 7️⃣ Lợi nhuận theo Giờ (Server Time)\n"
        md += "| Giờ | Lợi nhuận ($) |\n|------|-------------|\n"
        for hour, profit in hour_profit_series.sort_index().items():
            md += f"| {hour:02d}:00 | {profit:,.2f} |\n"

    # DOW breakdown
    if dow_profit_series is not None and not dow_profit_series.empty:
        days_map = {0: 'Mon', 1: 'Tue', 2: 'Wed', 3: 'Thu', 4: 'Fri', 5: 'Sat', 6: 'Sun'}
        md += "\n## 8️⃣ Lợi nhuận theo Thứ trong Tuần\n"
        md += "| Thứ | Lợi nhuận ($) |\n|------|-------------|\n"
        for dow, profit in dow_profit_series.sort_index().items():
            md += f"| {days_map.get(dow, dow)} | {profit:,.2f} |\n"

    md += f"""\n---
*Báo cáo được xuất tự động bởi Strategy Analyzer Dashboard.*
"""
    return md

# ============================================================
# CHARTS
# ============================================================
def chart_equity_dd(trades, sideways_periods=None):
    if 'Balance' not in trades.columns: return None
    bal = trades[['Time', 'Balance']].dropna().copy()
    bal = bal.sort_values('Time')
    bal['Peak'] = bal['Balance'].cummax()
    bal['DD'] = bal['Balance'] - bal['Peak']
    bal['DD_pct'] = bal['DD'] / bal['Peak'] * 100

    fig = make_subplots(rows=2, cols=1, shared_xaxes=True, row_heights=[0.7, 0.3],
                        vertical_spacing=0.05)
    fig.add_trace(go.Scatter(x=bal['Time'], y=bal['Balance'], name='Equity',
                             line=dict(color='#00d4aa', width=2), fill='tozeroy',
                             fillcolor='rgba(0,212,170,0.1)'), row=1, col=1)
    fig.add_trace(go.Scatter(x=bal['Time'], y=bal['Peak'], name='Peak',
                             line=dict(color='#555', width=1, dash='dot')), row=1, col=1)
    fig.add_trace(go.Scatter(x=bal['Time'], y=bal['DD_pct'], name='Drawdown %',
                             fill='tozeroy', line=dict(color='#ff4757', width=1),
                             fillcolor='rgba(255,71,87,0.3)'), row=2, col=1)

    stag_start, stag_end, stag_dur = get_longest_stagnation(trades)
    if stag_dur > 0 and stag_start and stag_end:
        fig.add_vrect(x0=stag_start, x1=stag_end, fillcolor="#ff4757", opacity=0.1, line_width=1, line_dash="dash", line_color="#ff4757",
                      annotation_text="Phục hồi đỉnh lâu nhất", annotation_position="top left",
                      row=1, col=1)
        fig.add_vrect(x0=stag_start, x1=stag_end, fillcolor="#ff4757", opacity=0.1, line_width=1, line_dash="dash", line_color="#ff4757",
                      row=2, col=1)

    if sideways_periods:
        for p in sideways_periods:
            fig.add_vrect(x0=p['start'], x1=p['end'], fillcolor="#ffa502", opacity=0.15, line_width=1, line_color="#ffa502",
                          annotation_text=f"Đi ngang ({p['duration']} ngày)", annotation_position="bottom right",
                          row=1, col=1)
            fig.add_vrect(x0=p['start'], x1=p['end'], fillcolor="#ffa502", opacity=0.15, line_width=1, line_color="#ffa502",
                          row=2, col=1)

    fig.update_layout(height=500, template='plotly_dark', showlegend=True,
                      legend=dict(orientation='h', y=1.05),
                      margin=dict(l=50, r=20, t=30, b=30))
    fig.update_yaxes(title_text='Balance ($)', row=1, col=1)
    fig.update_yaxes(title_text='DD %', row=2, col=1)
    return fig

def chart_monthly_heatmap(trades):
    df = trades[['Time', 'Profit']].dropna().copy()
    df['Year'] = df['Time'].dt.year
    df['Month'] = df['Time'].dt.month
    pivot = df.groupby(['Year', 'Month'])['Profit'].sum().unstack(fill_value=0)
    months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec']
    pivot.columns = [months[m-1] for m in pivot.columns]

    fig = px.imshow(pivot.values, x=pivot.columns, y=pivot.index.astype(str),
                    color_continuous_scale=[[0.0, '#ff4757'], [0.499, '#ffa502'], [0.5, '#00d4aa'], [1.0, '#008c72']],
                    color_continuous_midpoint=0, text_auto='.0f', aspect='auto')
    fig.update_layout(height=350, template='plotly_dark', margin=dict(l=50, r=20, t=30, b=30),
                      coloraxis_colorbar=dict(title='Profit $'))
    return fig

def chart_scatter_rr(trades):
    df = trades[['Profit']].dropna().copy()
    df['Trade #'] = range(1, len(df)+1)
    df['Color'] = np.where(df['Profit'] >= 0, 'Win', 'Loss')
    fig = px.scatter(df, x='Trade #', y='Profit', color='Color',
                     color_discrete_map={'Win': '#00d4aa', 'Loss': '#ff4757'},
                     opacity=0.6)
    fig.add_hline(y=0, line_dash='dash', line_color='white', opacity=0.3)
    fig.update_layout(height=350, template='plotly_dark', margin=dict(l=50, r=20, t=30, b=30),
                      showlegend=True)
    return fig

def chart_profit_distribution(profits):
    fig = go.Figure()
    fig.add_trace(go.Histogram(x=profits, nbinsx=60, name='Profit',
                               marker_color='#00d4aa', opacity=0.7))
    mu, sigma = profits.mean(), profits.std()
    x_range = np.linspace(profits.min(), profits.max(), 200)
    pdf = stats.norm.pdf(x_range, mu, sigma) * len(profits) * (profits.max()-profits.min())/60
    fig.add_trace(go.Scatter(x=x_range, y=pdf, name='Normal Fit',
                             line=dict(color='#ffa502', width=2)))
    fig.add_vline(x=0, line_dash='dash', line_color='white', opacity=0.3)
    fig.update_layout(height=350, template='plotly_dark', margin=dict(l=50, r=20, t=30, b=30))
    return fig

def chart_hourly(trades):
    tcol = 'OpenTime' if 'OpenTime' in trades.columns and trades['OpenTime'].notna().any() else 'Time'
    if tcol not in trades.columns: return None
    df = trades[[tcol, 'Profit']].dropna(subset=[tcol, 'Profit']).copy()
    if df.empty: return None
    df['Hour'] = df[tcol].dt.hour
    grp = df.groupby('Hour')['Profit'].agg(['sum', 'count']).reset_index()
    grp.columns = ['Hour', 'Total Profit', 'Count']
    colors = ['#00d4aa' if x >= 0 else '#ff4757' for x in grp['Total Profit']]
    fig = go.Figure()
    fig.add_trace(go.Bar(x=grp['Hour'], y=grp['Total Profit'], marker_color=colors, name='Profit'))
    fig.update_layout(height=350, template='plotly_dark', margin=dict(l=50, r=20, t=30, b=30),
                      xaxis_title='Hour of Day (Server Time)', yaxis_title='Total Profit ($)')
    return fig

def chart_dow(trades):
    tcol = 'OpenTime' if 'OpenTime' in trades.columns and trades['OpenTime'].notna().any() else 'Time'
    if tcol not in trades.columns: return None
    df = trades[[tcol, 'Profit']].dropna(subset=[tcol, 'Profit']).copy()
    if df.empty: return None
    df['DOW'] = df[tcol].dt.dayofweek
    grp = df.groupby('DOW')['Profit'].agg(['sum', 'count']).reset_index()
    grp.columns = ['DOW', 'Total Profit', 'Count']
    days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun']
    grp['Day'] = grp['DOW'].map(lambda d: days[d])
    colors = ['#00d4aa' if x >= 0 else '#ff4757' for x in grp['Total Profit']]
    fig = go.Figure()
    fig.add_trace(go.Bar(x=grp['Day'], y=grp['Total Profit'], marker_color=colors))
    fig.update_layout(height=350, template='plotly_dark', margin=dict(l=50, r=20, t=30, b=30),
                      xaxis_title='Day of Week', yaxis_title='Total Profit ($)')
    return fig

def chart_duration(trades):
    if 'Duration' not in trades.columns: return None
    df = trades[['Duration', 'Profit']].dropna()
    df = df[df['Duration'] > 0]
    if df.empty: return None
    df['Color'] = np.where(df['Profit'] >= 0, 'Win', 'Loss')
    fig = px.scatter(df, x='Duration', y='Profit', color='Color',
                     color_discrete_map={'Win': '#00d4aa', 'Loss': '#ff4757'},
                     opacity=0.5, labels={'Duration': 'Duration (hours)'})
    fig.update_layout(height=350, template='plotly_dark', margin=dict(l=50, r=20, t=30, b=30))
    return fig

# ============================================================
# ADVANCED ANALYSIS
# ============================================================
def run_ks_test(profits):
    p_clean = np.asarray(profits.dropna(), dtype=float)
    if len(p_clean) < 3:
        return 0.0, 1.0
    mean_val = float(np.mean(p_clean))
    std_val = float(np.std(p_clean))
    if std_val == 0:
        std_val = 1e-9
    try:
        stat, pval = stats.kstest(p_clean, stats.norm(loc=mean_val, scale=std_val).cdf)
        return float(stat), float(pval)
    except Exception:
        return 0.0, 1.0

def run_monte_carlo(profits, n_sims=10000, init_balance=5000):
    results = []
    profit_arr = profits.values
    n = len(profit_arr)
    for _ in range(n_sims):
        shuffled = np.random.choice(profit_arr, size=n, replace=True)
        equity = init_balance + np.cumsum(shuffled)
        peak = np.maximum.accumulate(equity)
        dd = (equity - peak) / peak
        max_dd = dd.min()
        final = equity[-1]
        results.append({'final_equity': final, 'max_dd_pct': max_dd * 100})
    return pd.DataFrame(results)

# ============================================================
# REGIME DNA TAB RENDERER (UI Helper)
# ============================================================
def render_dna_tabs(data_dict):
    ver = data_dict.get("dna_version", "v1")
    thr_mode = data_dict.get("threshold_mode", "auto")
    deploy_src = data_dict.get("deploy_tree_source", "train_only")
    st.markdown(
        f"**DNA `{ver}`** | **Mẫu**: `{data_dict.get('sample_count', 0)}` lệnh "
        f"({data_dict.get('win_count', 0)} Thắng / {data_dict.get('loss_count', 0)} Thua) | "
        f"**OOS**: `{data_dict.get('oos_status', 'N/A')}` | "
        f"**thr** `{data_dict.get('exp_threshold', 0)}` (`{thr_mode}`) | "
        f"**deploy**: `{deploy_src}` | "
        f"**Block precision**: `{data_dict.get('block_precision', 0)}%` | "
        f"**OpenTime**: `{data_dict.get('open_time_coverage', 'N/A')}%`"
    )
    if data_dict.get("walk_forward_pass_rate") is not None:
        st.caption(f"Walk-forward pass rate: **{data_dict['walk_forward_pass_rate']}%**")

    for w in (data_dict.get("warnings") or []):
        st.warning(w)

    # Diagnosis + filter impact (core of v2)
    if data_dict.get("diagnosis"):
        st.markdown("### 🩺 Chẩn đoán Filter Impact")
        for line in data_dict["diagnosis"]:
            st.markdown(f"- {line}")

    impact = data_dict.get("filter_impact")
    if impact:
        c1, c2, c3, c4 = st.columns(4)
        base, filt = impact["baseline"], impact["filtered"]
        c1.metric("Net (sau filter)", f"${filt['net']:,.0f}", f"{impact['delta_net']:+.0f}")
        c2.metric("MaxDD (sau filter)", f"{filt['maxdd']:.1f}%", f"{impact['delta_maxdd']:+.1f}pp")
        c3.metric("Profit Factor", f"{filt['pf']}", f"{impact['delta_pf']:+.2f}")
        c4.metric("Tỷ lệ chặn", f"{impact['block_rate_pct']}%", f"blocked net ${impact['blocked_net_pnl']:,.0f}")

    if data_dict.get("legacy_winrate_filter_impact"):
        leg = data_dict["legacy_winrate_filter_impact"]
        with st.expander("⚠️ So sánh với filter cũ (Win/Loss Allow-List) — thường là nguyên nhân profit giảm mà DD không giảm"):
            st.write(leg)

    if data_dict.get("features_csv_path"):
        st.markdown(f"📂 **Features CSV**: `{data_dict['features_csv_path']}`")
    if data_dict.get("rule_paths"):
        n_tox = len((data_dict["rule_paths"] or {}).get("toxic_paths") or [])
        st.success(f"🌳 Đã lưu **rule_paths** ({n_tox} toxic path) — Live Monitor Streamlit dùng **cùng cây DNA**.")

    p_tab1, p_tab2, p_tab3, p_tab4, p_tab5, p_tab6, p_tab7 = st.tabs([
        "🌳 Rule Paths (Live)",
        "📊 Cây Expectancy",
        "🍃 Leaf Stats",
        "⏳ Ổn Định Theo Thời Gian",
        "🔍 Phân Cụm Không Giám Sát",
        "⚖️ Đối Chiếu Thắng vs Thua",
        "📏 Phân Vùng Lãi/Lỗ",
    ])

    with p_tab1:
        st.markdown(
            "**Theo dõi chính trên Streamlit Live Monitor** (cùng `rule_paths` bên dưới). "
            "Không bắt buộc gắn MQL5/MT5."
        )
        rp = data_dict.get("rule_paths") or {}
        if rp:
            st.json({
                "mode": rp.get("mode"),
                "exp_threshold": rp.get("exp_threshold"),
                "feature_names": rp.get("feature_names"),
                "toxic_paths": rp.get("toxic_paths"),
                "good_paths_count": len(rp.get("good_paths") or []),
            })
        else:
            st.info("Chưa có rule_paths — huấn luyện lại DNA v2.")
        with st.expander("Tham khảo MQL5 (tuỳ chọn — không bắt buộc)"):
            st.code(data_dict.get("mql5_code", ""), language="mql5")
            if data_dict.get("mql5_legacy_code"):
                st.caption("Legacy WR allow-list (không khuyến nghị)")
                st.code(data_dict["mql5_legacy_code"], language="mql5")
        if data_dict.get("walk_forward"):
            with st.expander("Walk-forward folds"):
                st.dataframe(pd.DataFrame(data_dict["walk_forward"]), hide_index=True)
        if data_dict.get("threshold_candidates_scored"):
            with st.expander("Bảng score threshold (auto)"):
                st.dataframe(pd.DataFrame(data_dict["threshold_candidates_scored"]), hide_index=True)

    with p_tab2:
        st.caption("Cây hồi quy PnL (expectancy). Giá trị leaf = $ kỳ vọng / lệnh.")
        st.text(data_dict.get("tree_text", ""))
        if data_dict.get("top_features"):
            st.markdown("**Feature Importances (Expectancy model):**")
            imp_df = pd.DataFrame(
                list(data_dict["top_features"].items()), columns=["Chỉ số", "Tầm quan trọng"]
            ).sort_values("Tầm quan trọng", ascending=False)
            st.dataframe(imp_df, hide_index=True)

    with p_tab3:
        leaves = data_dict.get("leaf_stats") or []
        if leaves:
            st.markdown(
                f"Ngưỡng chặn: **exp ≤ {data_dict.get('exp_threshold', 0)}**. "
                f"Toxic leaves: **{len(data_dict.get('toxic_leaves') or [])}** | "
                f"Safe leaves: **{len(data_dict.get('good_leaves') or [])}**"
            )
            lf = pd.DataFrame(leaves)
            st.dataframe(
                lf.style.background_gradient(subset=["expectancy", "net_pnl"], cmap="RdYlGn"),
                hide_index=True,
            )
        else:
            st.info("Chưa có leaf stats — hãy huấn luyện lại DNA v2.")

    with p_tab4:
        stab_data = data_dict.get("feature_stability_analysis", {})
        if stab_data and "error" not in stab_data:
            st.markdown(
                f"**Độ ổn định qua {stab_data.get('valid_periods', 0)} chu kỳ "
                f"(Expectancy regressor):**"
            )
            if stab_data.get("robust_features"):
                st.success(f"🟢 **Robust DNA**: `{', '.join(stab_data['robust_features'])}`")
            if stab_data.get("drift_warnings"):
                st.warning(
                    f"🔴 **Concept Drift**: `{', '.join(stab_data['drift_warnings'])}`"
                )
            st_df = pd.DataFrame(stab_data.get("stability_summary", []))
            if not st_df.empty:
                st_df = st_df.rename(columns={
                    "feature": "Chỉ số", "appearance_count": "Tần suất",
                    "consistency_pct": "Độ ổn định (%)", "avg_importance": "Trọng số TB",
                    "status": "Trạng thái",
                })
                st.dataframe(
                    st_df.style.background_gradient(subset=["Độ ổn định (%)"], cmap="RdYlGn"),
                    hide_index=True,
                )
            with st.expander("Chi tiết theo chu kỳ"):
                p_df = pd.DataFrame(stab_data.get("period_details", []))
                if not p_df.empty:
                    p_df = p_df.drop(columns=["top_features"], errors="ignore")
                    st.dataframe(p_df, hide_index=True)
        else:
            st.info(stab_data.get("error", "Chưa có dữ liệu ổn định. Huấn luyện lại."))

    with p_tab5:
        clus_data = data_dict.get("unsupervised_clustering_analysis", {})
        if clus_data and "error" not in clus_data:
            be = clus_data.get("best_expectancy")
            be_txt = f"${be}" if be is not None else "N/A"
            st.info(
                f"🏆 Cụm tốt nhất (theo **expectancy**): **`{clus_data.get('best_cluster_name', '')}`** "
                f"(exp {be_txt}/lệnh · WR {clus_data.get('best_win_rate', 0)}%)"
            )
            tc_df = pd.DataFrame(clus_data.get("trade_cluster_stats", []))
            if not tc_df.empty:
                tc_df = tc_df.rename(columns={
                    "cluster_name": "Cụm", "total_trades": "Tổng lệnh",
                    "win_count": "Thắng", "loss_count": "Thua", "win_rate": "Win Rate (%)",
                    "net_pnl": "Net PnL ($)", "avg_pnl": "Expectancy ($)",
                    "expectancy": "Exp ($)",
                }).drop(columns=["cluster_id"], errors="ignore")
                grad_cols = [c for c in ["Win Rate (%)", "Net PnL ($)", "Expectancy ($)"] if c in tc_df.columns]
                st.dataframe(
                    tc_df.style.background_gradient(subset=grad_cols, cmap="RdYlGn") if grad_cols else tc_df,
                    hide_index=True,
                )
        else:
            st.info("Chưa có dữ liệu phân cụm.")

    with p_tab6:
        w_ctx = data_dict.get("win_context", {})
        l_ctx = data_dict.get("loss_context", {})
        if w_ctx:
            contrast_df = pd.DataFrame({
                "Chỉ số Bối Cảnh": list(w_ctx.keys()),
                "Khi EA THẮNG (Mean)": list(w_ctx.values()),
                "Khi EA THUA (Mean)": [l_ctx.get(k, 0) for k in w_ctx.keys()],
            })
            contrast_df["Chênh Lệch"] = (
                contrast_df["Khi EA THẮNG (Mean)"] - contrast_df["Khi EA THUA (Mean)"]
            )
            st.dataframe(
                contrast_df.style.background_gradient(subset=["Chênh Lệch"], cmap="RdYlGn"),
                hide_index=True,
            )

    with p_tab7:
        range_data = data_dict.get("range_analysis", {})
        if range_data:
            st.markdown("Phân vùng theo **Win Rate + Expectancy ($)** — đừng chỉ nhìn WR:")
            for feat_name, zones in range_data.items():
                st.markdown(f"**🔹 `{feat_name}`**")
                z_df = pd.DataFrame(zones).rename(columns={
                    "range": "Vùng", "total_trades": "Số lệnh",
                    "win_count": "Thắng", "win_rate": "WR (%)",
                    "expectancy": "Expectancy ($)", "net_pnl": "Net ($)",
                })
                cols = [c for c in ["WR (%)", "Expectancy ($)", "Net ($)"] if c in z_df.columns]
                st.dataframe(
                    z_df.style.background_gradient(subset=cols, cmap="RdYlGn") if cols else z_df,
                    hide_index=True,
                )
        else:
            st.info("Chưa có dữ liệu phân vùng.")

# ============================================================
# MAIN APP
# ============================================================
def main():
    st.markdown("""
    <style>
    .metric-card {background: linear-gradient(135deg, #1a1a2e, #16213e); border-radius: 12px;
        padding: 16px; text-align: center; border: 1px solid #333;}
    .metric-value {font-size: 28px; font-weight: bold; color: #00d4aa;}
    .metric-label {font-size: 13px; color: #888; margin-top: 4px;}
    .neg {color: #ff4757 !important;}
    </style>
    """, unsafe_allow_html=True)

    st.title("📊 Strategy Analyzer Dashboard")
    st.caption("Phân tích toàn diện chiến lược giao dịch từ file backtest MT5")

    # Ensure the directory exists
    os.makedirs(BACKTEST_DIR, exist_ok=True)
    
    # ── GOOGLE DRIVE SYNC (Tự động tải về ngay khi khởi động) ──
    service = get_drive_service()
    drive_folder_id = get_secret("drive_folder_id")
    
    if service and drive_folder_id:
        if not st.session_state.get("auto_synced_drive", False):
            with st.spinner("☁️ Đang tự động đồng bộ dữ liệu từ Google Drive..."):
                sync_drive(service, drive_folder_id, BACKTEST_DIR)
            st.session_state["auto_synced_drive"] = True

        if st.sidebar.button("🔄 Đồng bộ dữ liệu với Drive"):
            with st.spinner("Đang đồng bộ 2 chiều..."):
                sync_drive(service, drive_folder_id, BACKTEST_DIR)
            st.sidebar.success("Đồng bộ hoàn tất!")
            st.rerun()
    else:
        st.sidebar.warning("☁️ Google Drive chưa được cấu hình. Vui lòng thêm drive_folder_id và gcp_service_account vào Streamlit Secrets để đồng bộ dữ liệu.")

    
    # ── URL QUERY PARAMS ROUTING SYNC (Chế độ hiển thị) ──
    route_options = [
        "📊 Phân Tích & Tối Ưu DNA",
        "📡 Giám Sát Bối Cảnh Realtime (Live Monitor)"
    ]
    route_keys = {
        "📊 Phân Tích & Tối Ưu DNA": "dna",
        "📡 Giám Sát Bối Cảnh Realtime (Live Monitor)": "live"
    }
    rev_route_keys = {v: k for k, v in route_keys.items()}
    
    current_url_route = st.query_params.get("route", "dna")
    default_route_idx = 0
    if current_url_route in rev_route_keys:
        default_route_idx = route_options.index(rev_route_keys[current_url_route])

    def on_app_mode_change():
        selected_mode = st.session_state.app_mode_radio
        route_k = route_keys.get(selected_mode, "dna")
        st.query_params["route"] = route_k
        if route_k == "live" and "page" in st.query_params:
            del st.query_params["page"]

    app_mode = st.sidebar.radio(
        "🧭 Chế độ hiển thị (Route)",
        route_options,
        index=default_route_idx,
        key="app_mode_radio",
        on_change=on_app_mode_change
    )
    st.query_params["route"] = route_keys.get(app_mode, "dna")
    if app_mode == "📡 Giám Sát Bối Cảnh Realtime (Live Monitor)":
        st.header("📡 Live Regime Monitor (Giám Sát Bối Cảnh Thời Gian Thực)")
        st.markdown(
            "Đánh giá **cùng cây DNA v2** (`rule_paths`) đã train — **BLOCK = toxic leaf**, "
            "không còn heuristic mean win/loss. Chỉ theo dõi trên Streamlit (không cần MT5)."
        )
        
        import importlib
        import regime_analyzer
        regime_analyzer = importlib.reload(regime_analyzer)
        registry_data = regime_analyzer.load_regime_registry()
        
        if not registry_data:
            st.warning("⚠️ Chưa có chiến lược nào được giải mã Regime DNA trong hệ thống. Vui lòng chuyển sang chế độ **📊 Phân Tích & Tối Ưu DNA** để huấn luyện AI trước.")
            return

        missing_rules = [k for k, v in registry_data.items() if not (v or {}).get("rule_paths")]
        if missing_rules:
            st.warning(
                f"⚠️ {len(missing_rules)} strategy trong registry **chưa có rule_paths** "
                f"(registry cũ). Hãy **huấn luyện lại DNA v2** để Live Monitor dùng đúng cây: "
                f"`{', '.join(missing_rules[:5])}`" + ("…" if len(missing_rules) > 5 else "")
            )
        # Auto-pull updates from Google Drive (e.g. live CSVs from VPS MT5)
        if service and drive_folder_id:
            try:
                sync_drive(service, drive_folder_id, BACKTEST_DIR)
            except Exception:
                pass

        watchlist = regime_analyzer.load_live_watchlist()
        workspace_dir = os.path.dirname(os.path.abspath(__file__))
        raw_ohlc = sorted(list(set(glob.glob(os.path.join(workspace_dir, "*.csv")) + glob.glob(os.path.join(BACKTEST_DIR, "*.csv")))))
        ohlc_files = [f for f in raw_ohlc if is_ohlc_file(f)]
        ohlc_names = [f"File CSV: {os.path.basename(f)}" for f in ohlc_files]
        # Prefer CSV / Twelve Data (XAU/USD) / MT5; Yahoo GC=F is last-resort proxy
        src_options = ohlc_names + [
            regime_analyzer.SOURCE_TWELVE,
            "Yahoo Finance API (REST API)",
            "MetaTrader 5 (Direct Terminal Bridge)",
        ]

        td_key = regime_analyzer.get_twelvedata_api_key(get_secret("TWELVE_DATA_API_KEY"))
        if not td_key:
            st.info(
                "🔑 **Twelve Data:** đặt API key trong Streamlit secrets "
                "`TWELVE_DATA_API_KEY = \"...\"` hoặc biến môi trường cùng tên. "
                "Đăng ký free: https://twelvedata.com"
            )
        else:
            st.caption("🔑 Twelve Data API key: đã cấu hình.")
        
        with st.expander("➕ Quản Lý Danh Sách Theo Dõi (Watchlist)", expanded=False):
            st.markdown(
                "Thêm mã theo dõi. **Online không cần MT5:** Twelve Data `XAU/USD`. "
                "**Khớp DNA broker:** File CSV MT5."
            )
            col_w1, col_w2, col_w3, col_w4 = st.columns([2, 1, 1, 1])
            new_src = col_w1.selectbox("🌐 Nguồn dữ liệu:", src_options, key="w_src")
            if "Twelve" in new_src:
                def_sym = "XAU/USD"
                sym_help = "Twelve: XAU/USD, EUR/USD, BTC/USD (hoặc XAUUSD → tự map)."
            elif "Yahoo" in new_src:
                def_sym = "GC=F"
                sym_help = "Yahoo vàng: GC=F. Forex: EURUSD=X."
            elif "Meta" in new_src:
                def_sym = "XAUUSD"
                sym_help = "MT5 Market Watch: XAUUSD / XAUUSDm…"
            else:
                def_sym = ""
                sym_help = "File CSV OHLC."
            new_sym = col_w2.text_input(
                "Mã (Symbol):",
                value=def_sym,
                disabled=new_src.startswith("File CSV"),
                key="w_sym",
                help=sym_help,
            )
            new_tf = col_w3.selectbox("⏱️ Khung:", ["1h", "4h", "15m", "5m"], index=0, key="w_tf")
            
            if col_w4.button("➕ Thêm ngay", type="secondary"):
                sym_val = new_src.replace("File CSV: ", "") if new_src.startswith("File CSV") else new_sym
                if not sym_val:
                    st.error("Vui lòng nhập mã Symbol!")
                else:
                    if not any(w['symbol'] == sym_val and w['source'] == new_src and w['timeframe'] == new_tf for w in watchlist):
                        watchlist.append({"symbol": sym_val, "source": new_src, "timeframe": new_tf})
                        regime_analyzer.save_live_watchlist(watchlist)
                        if service and drive_folder_id:
                            sync_drive(service, drive_folder_id, BACKTEST_DIR, force_upload_file=regime_analyzer.WATCHLIST_FILE)
                        st.success(f"Đã thêm `{sym_val}` ({new_tf}) vào Watchlist!")
                        st.rerun()
                    else:
                        st.warning("Mã này đã có trong Watchlist!")
            
            if len(watchlist) > 0:
                st.markdown("**Danh sách hiện tại:**")
                del_cols = st.columns(min(len(watchlist), 4))
                for idx, w_item in enumerate(watchlist):
                    c_idx = idx % 4
                    with del_cols[c_idx]:
                        if st.button(f"🗑️ Xóa {w_item['symbol']} ({w_item['timeframe']})", key=f"del_{idx}"):
                            watchlist.pop(idx)
                            regime_analyzer.save_live_watchlist(watchlist)
                            if service and drive_folder_id:
                                sync_drive(service, drive_folder_id, BACKTEST_DIR, force_upload_file=regime_analyzer.WATCHLIST_FILE)
                            st.rerun()

        st.markdown("---")
        
        if not watchlist:
            st.info("👋 Watchlist đang trống. Vui lòng mở mục **➕ Quản Lý Danh Sách Theo Dõi** ở trên để thêm mã giao dịch!")
            return
            
        st.subheader("🔄 Trạng Thái Giám Sát Trực Tuyến Tự Động")
        col_r1, col_r2 = st.columns([1, 2])
        if col_r1.button("🔄 Cập nhật Watchlist ngay", type="primary"):
            st.rerun()
        auto_refresh = col_r2.checkbox("⏱️ Tự động cập nhật 24/7 mỗi 60 giây", value=False)
            
        for item in watchlist:
            sym = item['symbol']
            src = item['source']
            tf = item['timeframe']
            
            with st.container():
                st.markdown(f"### 📡 Mã: `{sym}` | Khung: `{tf}` | Nguồn: `{src}`")
                target_sym = sym
                if src.startswith("File CSV"):
                    p_work = os.path.join(workspace_dir, sym)
                    p_back = os.path.join(BACKTEST_DIR, sym)
                    target_sym = p_work if os.path.exists(p_work) else p_back
                with st.spinner(f"Đang kéo dữ liệu live & tính toán bối cảnh cho {sym}..."):
                    df_live, err_msg = regime_analyzer.fetch_live_ohlc(
                        src, target_sym, tf, api_key=td_key
                    )
                
                if err_msg or df_live is None or df_live.empty:
                    st.error(f"❌ Lỗi kết nối lấy dữ liệu cho `{sym}`: {err_msg or 'Không có dữ liệu nến.'}")
                    if "Yahoo" in src:
                        st.info("💡 Yahoo vàng: **`GC=F`**, hoặc chuyển nguồn **Twelve Data `XAU/USD`** / CSV MT5.")
                    if "Twelve" in src:
                        st.info("💡 Kiểm tra API key + symbol dạng **XAU/USD**. Free plan có giới hạn credit/ngày.")
                    st.markdown("---")
                    continue

                used_yf = getattr(df_live, "attrs", {}).get("yahoo_symbol_used")
                used_td = getattr(df_live, "attrs", {}).get("twelvedata_symbol")
                if used_yf and used_yf != sym:
                    st.caption(f"ℹ️ Yahoo resolve `{sym}` → **`{used_yf}`**")
                if used_td:
                    st.caption(f"ℹ️ Twelve Data symbol: **`{used_td}`** · nến: {len(df_live)}")
                    
                eval_res = regime_analyzer.evaluate_live_market(df_live, registry_data)
                logged = regime_analyzer.log_live_monitor_eval(sym, tf, eval_res)
                if logged and service and drive_folder_id:
                    sync_drive(service, drive_folder_id, BACKTEST_DIR, force_upload_file=regime_analyzer.MONITOR_HISTORY_FILE)
                latest_bar = eval_res.get("latest_bar", {}) or {}
                latest_time = eval_res.get("latest_time", "N/A")
                dna_ok = bool(eval_res.get("dna_features_ok", False))
                dna_err = eval_res.get("error")

                st.caption(f"⏱️ Nến đã đóng gần nhất (DNA features): `{latest_time}`")
                if not dna_ok:
                    st.error(
                        "⛔ DNA features chưa đủ dữ liệu — không hiển thị 0 giả. "
                        + (str(dna_err) if dna_err else
                           "Cần OHLC đủ warm-up + volume (tick hoặc real/spot/futures từ feed).")
                    )
                vol_src = getattr(df_live, "attrs", {}).get("volume_source")
                if vol_src:
                    st.caption(f"📊 Volume source cho Vol_Z: **`{vol_src}`**")
                else:
                    st.caption("📊 Volume source: *(không có — TickVol/Vol/RealVolume đều trống hoặc = 0)*")

                def _fmt_dna(key, nd):
                    v = latest_bar.get(key)
                    try:
                        fv = float(v)
                    except (TypeError, ValueError):
                        return "N/A"
                    if fv != fv:  # NaN
                        return "N/A"
                    # Strict-positive DNA: 0 = empty placeholder
                    if key in getattr(regime_analyzer, "DNA_STRICT_POSITIVE", set()) and fv <= 0:
                        return "N/A"
                    return f"{fv:.{nd}f}"

                g_cols = st.columns(6)
                g_cols[0].metric("ADX", _fmt_dna("ADX", 1))
                g_cols[1].metric("ATR%", _fmt_dna("ATR%", 3))
                g_cols[2].metric("Vol_Z", _fmt_dna("Vol_ZScore", 2))
                g_cols[3].metric("Chop", _fmt_dna("Choppiness", 1))
                g_cols[4].metric("BB Width", _fmt_dna("BB_Width", 3))
                g_cols[5].metric("EMA_Dist%", _fmt_dna("EMA_Dist%", 3))
                
                evals = eval_res.get("evaluations", {})
                for s_name, s_info in evals.items():
                    st_code = s_info.get("status", "CAUTION")
                    eval_mode = s_info.get("eval_mode", "legacy_centroid")
                    pred_exp = s_info.get("pred_expectancy")
                    if st_code == "PASS":
                        badge = "🟢 BẬT EA (SAFE)"
                        border_color = "#00d4aa"
                    elif st_code == "CAUTION":
                        badge = "🟡 CẨN TRỌNG"
                        border_color = "#ffa502"
                    elif st_code == "NO_DATA":
                        badge = "⛔ THIẾU DỮ LIỆU DNA"
                        border_color = "#747d8c"
                    else:
                        badge = "🔴 KHÓA LỆNH (TOXIC)"
                        border_color = "#ff4757"
                    exp_txt = f"${pred_exp:.2f}" if pred_exp is not None else "N/A"
                    mode_txt = "🌳 Tree DNA" if eval_mode == "tree" else "⚠️ Legacy centroid"
                    st.markdown(f"""
                    <div style="border-left: 5px solid {border_color}; padding: 12px; background: #1a1a2e; margin: 8px 0; border-radius: 6px;">
                        <span style="font-size: 16px; font-weight: bold; color: {border_color};">{badge}</span>
                        | <span style="color: white; font-weight: bold; font-size: 16px;">{s_name}</span>
                        | pred exp <b style="color:{border_color}">{exp_txt}</b>
                        | {mode_txt}
                    </div>
                    """, unsafe_allow_html=True)
                    bp = s_info.get("block_precision", 0) or 0
                    acc = s_info.get("accuracy", 0) or 0
                    acc_pct = acc * 100 if acc <= 1 else acc
                    with st.expander(
                        f"🔍 Chi tiết {s_name} | leaf={s_info.get('leaf_id')} | "
                        f"OOS={s_info.get('oos_status', 'N/A')} | block_prec={bp}% | train_acc~{acc_pct:.0f}%"
                    ):
                        if s_info.get("path_text"):
                            st.code(s_info["path_text"])
                        for r in s_info.get("reasons") or []:
                            st.markdown(f"- {r}")
                st.markdown("---")
                
        history_records = regime_analyzer.load_live_monitor_history(limit=100)
        if history_records:
            with st.expander("📜 Lịch Sử Quét & Cảnh Báo Bối Cảnh (100 Lần Quét Gần Nhất)", expanded=False):
                h_rows = []
                for rec in reversed(history_records):
                    row_dict = {
                        "Thời gian nến": rec.get("latest_time", ""),
                        "Thời gian quét": rec.get("timestamp_logged", ""),
                        "Mã": rec.get("symbol", ""),
                        "Khung": rec.get("timeframe", ""),
                        "ADX": f"{rec.get('adx'):.1f}" if rec.get('adx') is not None else "N/A",
                        "Hurst": f"{rec.get('hurst'):.2f}" if rec.get('hurst') is not None else "N/A",
                        "Choppiness": f"{rec.get('choppiness'):.1f}" if rec.get('choppiness') is not None else "N/A",
                        "BB Width": f"{rec.get('bb_width'):.3f}" if rec.get('bb_width') is not None else "N/A"
                    }
                    for ea_name, ea_data in rec.get("evaluations", {}).items():
                        st_icon = "🟢" if ea_data.get("status") == "PASS" else ("🟡" if ea_data.get("status") == "CAUTION" else "🔴")
                        pe = ea_data.get("pred_expectancy")
                        pe_s = f" exp${pe:.1f}" if pe is not None else ""
                        mode = ea_data.get("eval_mode") or ""
                        row_dict[f"EA {ea_name}"] = f"{st_icon} {ea_data.get('status')}{pe_s} [{mode}]"
                    h_rows.append(row_dict)
                st.dataframe(pd.DataFrame(h_rows), use_container_width=True)
                
                col_h1, _ = st.columns([1, 4])
                if col_h1.button("🗑️ Xóa lịch sử Monitor"):
                    regime_analyzer.save_live_monitor_history([])
                    if service and drive_folder_id:
                        sync_drive(service, drive_folder_id, BACKTEST_DIR, force_upload_file=regime_analyzer.MONITOR_HISTORY_FILE)
                    st.rerun()

        if auto_refresh:
            import time
            time.sleep(60)
            st.rerun()
        return
    
    st.sidebar.header("📥 Thêm Dữ Liệu Mới")
    uploaded_file = st.sidebar.file_uploader("Tải lên file Backtest (CSV, XLSX)", type=['csv', 'xlsx', 'xls'])
    if uploaded_file is not None:
        file_key = f"{uploaded_file.name}_{uploaded_file.size}"
        if st.session_state.get("last_uploaded_key") != file_key:
            save_path = os.path.join(BACKTEST_DIR, uploaded_file.name)
            with open(save_path, "wb") as f:
                f.write(uploaded_file.getbuffer())
            st.sidebar.success(f"Đã lưu thành công: {uploaded_file.name}")
            # Tự động đẩy file vừa tải lên sang Google Drive (cập nhật nếu đã có)
            if service and drive_folder_id:
                with st.spinner("☁️ Đang lưu trữ lên Google Drive..."):
                    sync_drive(service, drive_folder_id, BACKTEST_DIR, force_upload_file=save_path)
            st.session_state["last_uploaded_key"] = file_key

    st.sidebar.markdown("---")
    st.sidebar.header("⚙️ Bộ Lọc Giai Đoạn Đi Ngang")
    stag_threshold = st.sidebar.number_input("Biên độ dao động tối đa (%)", min_value=0.1, value=5.0, step=0.5, help="Biến động giữa mức vốn cao nhất và thấp nhất trong chu kỳ.")
    stag_min_days = st.sidebar.number_input("Thời gian đi ngang tối thiểu (Ngày)", min_value=1, value=30, step=1)
    
    st.sidebar.markdown("---")

    # File selector
    raw_files = sorted(glob.glob(os.path.join(BACKTEST_DIR, "*.xlsx")) +
                       glob.glob(os.path.join(BACKTEST_DIR, "*.xls")) +
                       glob.glob(os.path.join(BACKTEST_DIR, "*.csv")), reverse=True)
    files = [f for f in raw_files if not is_ohlc_file(f) and not f.endswith("_regime_features.csv")]
    
    if not files:
        st.info("👋 Chào mừng bạn! Hệ thống chưa có dữ liệu.\n\n👉 Vui lòng sử dụng thanh công cụ bên trái (Sidebar) để **Tải lên file Backtest** (MT5 Report dạng Excel/CSV) và bắt đầu phân tích.")
        return

    file_names = [os.path.basename(f) for f in files]
    # Default to the newly uploaded file if there is one, else the first file
    default_idx = 0
    if uploaded_file is not None and uploaded_file.name in file_names:
        default_idx = file_names.index(uploaded_file.name)

    selected = st.selectbox("🗂️ Chọn file backtest để phân tích", file_names, index=default_idx)
    file_path = files[file_names.index(selected)]

    trades, mt5_metrics, raw_df = load_backtest(file_path)
    if trades is None or trades.empty:
        st.error("Không đọc được dữ liệu từ file. Kiểm tra lại định dạng.")
        return

    profits = trades['Profit'].dropna()
    m = compute_metrics(trades, mt5_metrics)
    init_bal = mt5_metrics.get('init_deposit', 5000)

    # ── PRE-COMPUTE SHARED METRICS FOR REPORT & ALL PAGES ──────────────────
    stag_start, stag_end, stag_duration = get_longest_stagnation(trades)
    avg_win_streak, max_win_streak, avg_loss_streak, max_loss_streak = get_streaks(profits)
    avg_win_days, max_win_days, avg_loss_days, max_loss_days = get_daily_streaks(trades)
    win_months, loss_months, win_month_ratio = get_monthly_win_loss_ratio(trades)
    sideways_periods = get_sideways_periods(trades, stag_threshold, stag_min_days)

    mc_data = None
    wfe_data = None
    tcol_h = 'OpenTime' if 'OpenTime' in trades.columns and trades['OpenTime'].notna().any() else 'Time'
    hour_profit_export = None
    dow_profit_export = None
    if tcol_h in trades.columns:
        _hdf = trades[[tcol_h, 'Profit']].dropna(subset=[tcol_h, 'Profit']).copy()
        if not _hdf.empty:
            hour_profit_export = _hdf.groupby(_hdf[tcol_h].dt.hour)['Profit'].sum()
            dow_profit_export = _hdf.groupby(_hdf[tcol_h].dt.dayofweek)['Profit'].sum()

    insights = []
    if isinstance(m.get('Profit Factor'), (int, float)) and m['Profit Factor'] >= 2.0:
        insights.append(f"🟢 **Profit Factor xuất sắc ({m['Profit Factor']:.2f})**: Chiến lược có lợi thế kỳ vọng rất cao.")
    if isinstance(m.get('Max DD (%)'), (int, float)) and m['Max DD (%)'] <= 10.0:
        insights.append(f"🟢 **Quản trị rủi ro tốt (Max DD {m['Max DD (%)']:.2f}%)**: Sụt giảm vốn thấp.")

    insights_loss = []
    if 'Type' in trades.columns and 'Close Time' in trades.columns:
        trades_copy = trades.copy()
        trades_copy['Month'] = trades_copy['Close Time'].dt.to_period('M')
        _mstats = trades_copy.groupby('Month').apply(lambda df: pd.Series({
            'Net Profit $': df['Profit'].sum(),
            'Trades': len(df),
            'Win Rate %': (df['Profit'] > 0).mean() * 100 if len(df) > 0 else 0
        })).reset_index()
        _losers = _mstats[_mstats['Net Profit $'] < 0]
        if not _losers.empty:
            _top_losers = _losers.sort_values('Net Profit $').head(10)
            insights_loss.append(f"🔍 **Phân tích tổng quan các tháng rủi ro nhất:** Tổng mức sụt giảm trong {len(_top_losers)} tháng tệ nhất là **${_top_losers['Net Profit $'].sum():,.0f}**.")

    # ── ROUTE PHÂN TRANG BÁO CÁO (SYNC WITH URL QUERY PARAMS) ──
    sub_page_options = [
        "📄 Tất Cả Báo Cáo (1️⃣ - 9️⃣)",
        "📊 1️⃣ - 4️⃣: Chỉ Số Cơ Bản & Biểu Đồ",
        "🔬 5️⃣ - 8️⃣: Quant Insights & WFE",
        "🧬 9️⃣: AI Strategy Profiling (DNA v2)"
    ]
    sub_page_keys = {
        "📄 Tất Cả Báo Cáo (1️⃣ - 9️⃣)": "all",
        "📊 1️⃣ - 4️⃣: Chỉ Số Cơ Bản & Biểu Đồ": "core_charts",
        "🔬 5️⃣ - 8️⃣: Quant Insights & WFE": "quant_wfe",
        "🧬 9️⃣: AI Strategy Profiling (DNA v2)": "dna_ai"
    }
    rev_sub_page_keys = {v: k for k, v in sub_page_keys.items()}
    
    current_url_subpage = st.query_params.get("page", "all")
    default_subpage_idx = 0
    if current_url_subpage in rev_sub_page_keys:
        default_subpage_idx = sub_page_options.index(rev_sub_page_keys[current_url_subpage])

    def on_subpage_change():
        selected_sp = st.session_state.subpage_radio
        st.query_params["page"] = sub_page_keys.get(selected_sp, "all")

    st.sidebar.markdown("---")
    st.sidebar.header("📑 Route Phân Trang")
    sub_page = st.sidebar.radio(
        "Chọn phân trang báo cáo:",
        sub_page_options,
        index=default_subpage_idx,
        key="subpage_radio",
        on_change=on_subpage_change
    )
    st.query_params["page"] = sub_page_keys.get(sub_page, "all")
    current_sub_route = sub_page_keys.get(sub_page, "all")

    # Hiển thị nhanh thanh phân trang ở đầu báo cáo
    sub_top_cols = st.columns([1, 4])
    with sub_top_cols[0]:
        st.markdown("### 📑 Phân Trang:")
    with sub_top_cols[1]:
        def on_top_subpage_change():
            top_val = st.session_state.subpage_radio_top
            st.session_state.subpage_radio = top_val
            st.query_params["page"] = sub_page_keys.get(top_val, "all")

        st.radio(
            "Chọn phân trang nhanh:",
            sub_page_options,
            index=default_subpage_idx,
            key="subpage_radio_top",
            horizontal=True,
            on_change=on_top_subpage_change,
            label_visibility="collapsed"
        )
    st.markdown("---")

    # ── STEP 1: CORE METRICS ─────────────────────────────────
    if current_sub_route in ["all", "core_charts"]:
        st.header("1️⃣ Chỉ Số Cơ Bản (Core Metrics)")
        cols = st.columns(6)
        items = [
            ("Net Profit", f"${m['Net Profit ($)']:,.2f}", m['Net Profit ($)'] >= 0),
            ("Win Rate", f"{m['Win Rate (%)']:.1f}%", m['Win Rate (%)'] >= 50),
            ("Profit Factor", f"{m['Profit Factor']:.2f}" if isinstance(m['Profit Factor'], float) else str(m['Profit Factor']), True),
            ("Max DD", f"{m['Max DD (%)']:.2f}%", False),
            ("Sharpe", f"{m['Sharpe Ratio']:.2f}" if isinstance(m['Sharpe Ratio'], float) else str(m['Sharpe Ratio']), True),
            ("Expectancy", f"${m['Expectancy ($)']:.2f}" if isinstance(m['Expectancy ($)'], float) else str(m['Expectancy ($)']), True),
        ]
        for col, (label, value, is_pos) in zip(cols, items):
            css = "" if is_pos else " neg"
            col.markdown(f"""<div class="metric-card">
                <div class="metric-value{css}">{value}</div>
                <div class="metric-label">{label}</div></div>""", unsafe_allow_html=True)

        cols2 = st.columns(4)
        items2 = [
            ("Total Trades", f"{m['Total Trades']}"),
            ("Avg Win", f"${m['Avg Win ($)']:.2f}"),
            ("Avg Loss", f"${m['Avg Loss ($)']:.2f}"),
            ("Avg R:R", f"{m['Avg R:R']:.2f}"),
        ]
        for col, (label, value) in zip(cols2, items2):
            col.metric(label, value)

        st.markdown("---")
        st.subheader("Hoạt Động & Hiệu Suất Định Kỳ")
        cols_extra = st.columns(5)
        cols_extra[0].metric("Lệnh / Ngày", f"{m.get('Avg Trades/Day', 0):.2f}")
        cols_extra[1].metric("Ngày Không Lệnh", f"{m.get('Days Without Trades', 0)} ({m.get('Days Without Trades %', 0):.1f}%)")
        cols_extra[2].metric("Daily Return", f"${m.get('Daily Return ($)', 0):.2f}")
        cols_extra[3].metric("Weekly Return", f"${m.get('Weekly Return ($)', 0):.2f}")
        cols_extra[4].metric("Monthly Return", f"${m.get('Monthly Return ($)', 0):.2f}")

        if stag_duration > 0:
            st.info(f"🐢 **Thời gian phục hồi đỉnh lâu nhất (Longest Drawdown Duration)**: Kéo dài **{stag_duration} ngày**, từ **{stag_start.strftime('%d/%m/%Y')}** đến **{stag_end.strftime('%d/%m/%Y')}**. "
                    f"Đây là khoảng thời gian chiến lược bị chôn vốn, không tạo ra đỉnh lợi nhuận mới.")

        # ── Phân tích chuỗi lệnh & ngày liên tiếp ──
        st.markdown("### 📈 Phân Tích Chuỗi Giao Gịch & Chu Kỳ Tháng")
        
        cols3 = st.columns(3)
        with cols3[0]:
            st.markdown(f"""
            <div class="metric-card">
                <div style="font-size: 14px; color: #888; font-weight: bold; margin-bottom: 8px;">Chuỗi Lệnh Liên Tiếp (Avg / Max)</div>
                <div style="font-size: 18px; font-weight: bold; color: #00d4aa; text-align: left;">🟢 Lãi liên tiếp: {avg_win_streak:.1f} lệnh <span style="font-size: 12px; color: #888;">(Cực đại: {max_win_streak})</span></div>
                <div style="font-size: 18px; font-weight: bold; color: #ff4757; text-align: left; margin-top: 4px;">🔴 Lỗ liên tiếp: {avg_loss_streak:.1f} lệnh <span style="font-size: 12px; color: #888;">(Cực đại: {max_loss_streak})</span></div>
            </div>
            """, unsafe_allow_html=True)
            
        with cols3[1]:
            st.markdown(f"""
            <div class="metric-card">
                <div style="font-size: 14px; color: #888; font-weight: bold; margin-bottom: 8px;">Chuỗi Ngày Liên Tiếp (Avg / Max)</div>
                <div style="font-size: 18px; font-weight: bold; color: #00d4aa; text-align: left;">🟢 Ngày lãi liên tiếp: {avg_win_days:.1f} ngày <span style="font-size: 12px; color: #888;">(Cực đại: {max_win_days})</span></div>
                <div style="font-size: 18px; font-weight: bold; color: #ff4757; text-align: left; margin-top: 4px;">🔴 Ngày lỗ liên tiếp: {avg_loss_days:.1f} ngày <span style="font-size: 12px; color: #888;">(Cực đại: {max_loss_days})</span></div>
            </div>
            """, unsafe_allow_html=True)
            
        with cols3[2]:
            st.markdown(f"""
            <div class="metric-card">
                <div style="font-size: 14px; color: #888; font-weight: bold; margin-bottom: 8px;">Tỉ Lệ Tháng Lãi / Lỗ</div>
                <div style="font-size: 20px; font-weight: bold; color: #ffa502; text-align: left; margin-top: 4px;">📅 {win_months} tháng Lãi / {loss_months} tháng Lỗ</div>
                <div style="font-size: 16px; font-weight: bold; color: #888; text-align: left; margin-top: 4px;">Tỷ lệ: {win_month_ratio:.1f}% tháng lãi</div>
            </div>
            """, unsafe_allow_html=True)
            
        st.markdown("<br>", unsafe_allow_html=True)

        if sideways_periods:
            periods_str = ", ".join([f"{p['duration']} ngày (từ {p['start'].strftime('%d/%m/%y')})" for p in sideways_periods])
            st.info(f"📏 **Phát hiện {len(sideways_periods)} Giai đoạn đi ngang (Biến động < {stag_threshold}%, kéo dài > {stag_min_days} ngày)**: {periods_str}")

        # ── STEP 2: EQUITY & DRAWDOWN ────────────────────────────
        st.header("2️⃣ Đường Cong Vốn & Drawdown")
        fig_eq = chart_equity_dd(trades, sideways_periods)
        if fig_eq: st.plotly_chart(fig_eq, width='stretch')

        # ── Monthly Heatmap + Scatter ─────────────────────────────
        st.header("3️⃣ Trực Quan Hóa (Visualization)")
        c1, c2 = st.columns(2)
        with c1:
            st.subheader("📅 Heatmap Lợi Nhuận Tháng/Năm")
            st.plotly_chart(chart_monthly_heatmap(trades), width='stretch')
        with c2:
            st.subheader("🎯 Scatter Plot Lệnh")
            st.plotly_chart(chart_scatter_rr(trades), width='stretch')

        # ── Time Analysis ─────────────────────────────────────────
        st.header("4️⃣ Phân Tích Thời Gian (Time-Series)")
        c1, c2 = st.columns(2)
        with c1:
            st.subheader("⏰ Lợi nhuận theo Giờ")
            fig_h = chart_hourly(trades)
            if fig_h: st.plotly_chart(fig_h, width='stretch')
        with c2:
            st.subheader("📆 Lợi nhuận theo Thứ")
            fig_d = chart_dow(trades)
            if fig_d: st.plotly_chart(fig_d, width='stretch')

        # ── Duration Analysis ─────────────────────────────────────
        fig_dur = chart_duration(trades)
        if fig_dur:
            st.subheader("⏱️ Thời gian giữ lệnh vs Profit")
            st.plotly_chart(fig_dur, width='stretch')

    # ── STEP 3: ADVANCED QUANT ────────────────────────────────
    if current_sub_route in ["all", "quant_wfe"]:
        st.header("5️⃣ Phân Tích Chuyên Sâu (Quant Insights)")

        # Distribution + KS Test
        c1, c2 = st.columns(2)
        with c1:
            st.subheader("📊 Phân Phối Lợi Nhuận & KS Test")
            st.plotly_chart(chart_profit_distribution(profits), width='stretch')
            ks_stat, ks_pval = run_ks_test(profits)
            if ks_pval < 0.05:
                st.warning(f"**KS Test**: D={ks_stat:.4f}, p={ks_pval:.4e} → Phân phối **KHÔNG phải Normal**. "
                           f"Chiến lược có thể phụ thuộc vào các lệnh \"duôi béo\" (fat-tail).")
            else:
                st.success(f"**KS Test**: D={ks_stat:.4f}, p={ks_pval:.4e} → Phân phối gần Normal. "
                           f"Lợi nhuận đều đặn, ít phụ thuộc vào lệnh lớn bất thường.")

        # Monte Carlo
        with c2:
            st.subheader("🎲 Monte Carlo Simulation")
            with st.spinner("Đang chạy 10,000 mô phỏng..."):
                mc = run_monte_carlo(profits, n_sims=10000, init_balance=init_bal)

            fig_mc = go.Figure()
            fig_mc.add_trace(go.Histogram(x=mc['final_equity'], nbinsx=80, marker_color='#7c4dff', opacity=0.7))
            fig_mc.add_vline(x=init_bal, line_dash='dash', line_color='#ff4757',
                             annotation_text=f'Vốn ban đầu: ${init_bal:,.0f}')
            fig_mc.update_layout(height=350, template='plotly_dark',
                                 xaxis_title='Final Equity ($)', yaxis_title='Count',
                                 margin=dict(l=50, r=20, t=30, b=30))
            st.plotly_chart(fig_mc, width='stretch')

            risk_of_ruin = (mc['final_equity'] <= init_bal * 0.5).mean() * 100
            median_eq = mc['final_equity'].median()
            p5 = mc['final_equity'].quantile(0.05)
            p95 = mc['final_equity'].quantile(0.95)
            worst_dd = mc['max_dd_pct'].min()

            mc_cols = st.columns(3)
            mc_cols[0].metric("Xác suất cháy TK (< 50% vốn)", f"{risk_of_ruin:.2f}%")
            mc_cols[1].metric("Equity trung vị", f"${median_eq:,.0f}")
            mc_cols[2].metric("Worst DD (MC)", f"{worst_dd:.1f}%")
            st.caption(f"📌 Khoảng tin cậy 90%: **${p5:,.0f}** — **${p95:,.0f}**")

        mc_data = {'risk_of_ruin': risk_of_ruin, 'median_eq': median_eq, 'p5': p5, 'p95': p95, 'worst_dd': worst_dd}

        # ── STEP 6: REGIME & LOSS ATTRIBUTION ─────────────────────────
        st.header("6️⃣ Phân Tích Cấu Trúc Lỗ (Loss Attribution)")
        insights_loss = []
        
        if 'Type' in trades.columns:
            c1, c2 = st.columns(2)
            trades['RawType'] = trades['Type'].astype(str).str.lower().str.strip()
            
            if 'Direction' in trades.columns:
                buy_mask = trades['RawType'].isin(['sell', '1'])
                sell_mask = trades['RawType'].isin(['buy', '0'])
            else:
                buy_mask = trades['RawType'].isin(['buy', '0'])
                sell_mask = trades['RawType'].isin(['sell', '1'])
            
            long_trades = trades[buy_mask]
            short_trades = trades[sell_mask]
            
            long_profit = long_trades['Profit'].sum()
            short_profit = short_trades['Profit'].sum()
            
            fig_dir = go.Figure()
            fig_dir.add_trace(go.Bar(name='Long (Buy)', x=['Lợi nhuận'], y=[long_profit], marker_color='#00d4aa' if long_profit >= 0 else '#ff4757'))
            fig_dir.add_trace(go.Bar(name='Short (Sell)', x=['Lợi nhuận'], y=[short_profit], marker_color='#00d4aa' if short_profit >= 0 else '#ff4757'))
            
            fig_dir.update_layout(height=350, template='plotly_dark', barmode='group',
                                  title='Lợi Nhuận Theo Hướng Giao Dịch', margin=dict(l=50, r=20, t=40, b=30))
            with c1:
                st.plotly_chart(fig_dir, width='stretch')
                
            # Monthly Regime Analysis
            df_monthly = trades.copy()
            df_monthly['YearMonth'] = df_monthly['Time'].dt.to_period('M')
            
            def regime_stats(g):
                wins = (g['Profit'] > 0).sum()
                total = len(g)
                wr = wins / total * 100 if total > 0 else 0
                
                if 'Direction' in trades.columns:
                    buy_pnl = g[g['RawType'].isin(['sell', '1'])]['Profit'].sum()
                    sell_pnl = g[g['RawType'].isin(['buy', '0'])]['Profit'].sum()
                else:
                    buy_pnl = g[g['RawType'].isin(['buy', '0'])]['Profit'].sum()
                    sell_pnl = g[g['RawType'].isin(['sell', '1'])]['Profit'].sum()
                    
                return pd.Series({
                    'Net Profit': g['Profit'].sum(),
                    'Trades': total,
                    'Win Rate %': wr,
                    'Long PnL': buy_pnl,
                    'Short PnL': sell_pnl
                })
                
            monthly_stats = df_monthly.groupby('YearMonth').apply(regime_stats, include_groups=False).reset_index()
            monthly_stats['YearMonth'] = monthly_stats['YearMonth'].astype(str)
            monthly_stats = monthly_stats.sort_values('Net Profit')
            
            with c2:
                st.markdown("**Top 5 Tháng Thua Lỗ Nặng Nhất (Phân Rã Cấu Trúc)**")
                st.dataframe(monthly_stats.head(5).style.background_gradient(cmap='RdYlGn', subset=['Net Profit', 'Win Rate %']), height=280)
                
            losing_months = monthly_stats[monthly_stats['Net Profit'] < 0]
            if len(losing_months) > 0:
                top_losers = losing_months.head(5)
                
                # Aggregate stats
                total_loss = top_losers['Net Profit'].sum()
                long_loss_sum = top_losers['Long PnL'].sum()
                short_loss_sum = top_losers['Short PnL'].sum()
                
                avg_trades_all = monthly_stats['Trades'].mean()
                avg_trades_losers = top_losers['Trades'].mean()
                
                insights_loss.append(f"🔍 **Phân tích tổng quan các tháng rủi ro nhất:** Tổng mức sụt giảm trong {len(top_losers)} tháng tệ nhất là **${total_loss:,.0f}**.")
                
                # Directional Bias Insight
                if long_loss_sum < 0 and short_loss_sum > 0:
                    insights_loss.append(f"👉 **Điểm yếu ở chiều Buy**: Gần như toàn bộ thiệt hại đến từ các lệnh Long (Lỗ ${long_loss_sum:,.0f} so với mức Lãi ${short_loss_sum:,.0f} của lệnh Short). Điều này chứng tỏ EA rất nhạy cảm với các đợt sập giá mạnh (Downtrend regime). Khuyến nghị: **Tăng cường bộ lọc xu hướng giảm** (ví dụ cấm Buy khi giá nằm dưới EMA khung lớn).")
                elif short_loss_sum < 0 and long_loss_sum > 0:
                    insights_loss.append(f"👉 **Điểm yếu ở chiều Sell**: Hầu hết thiệt hại đến từ các lệnh Short (Lỗ ${short_loss_sum:,.0f} so với mức Lãi ${long_loss_sum:,.0f} của lệnh Buy). EA đang chịu đòn nặng khi thị trường có nhịp tăng phi mã (Uptrend regime). Khuyến nghị: **Tránh bắt đỉnh** khi cấu trúc thị trường đang thể hiện lực nén tăng mạnh.")
                elif long_loss_sum < 0 and short_loss_sum < 0:
                    if long_loss_sum < short_loss_sum * 2:
                        insights_loss.append(f"👉 **Điểm yếu đa chiều (Thiên về Buy)**: EA lỗ cả 2 đầu nhưng lệnh Buy mất tiền nhiều hơn gấp đôi lệnh Sell. Hệ thống thường xuyên vào lệnh sai nhịp ở các giai đoạn giảm giá.")
                    elif short_loss_sum < long_loss_sum * 2:
                        insights_loss.append(f"👉 **Điểm yếu đa chiều (Thiên về Sell)**: EA lỗ cả 2 đầu nhưng lệnh Sell mất tiền nhiều hơn gấp đôi lệnh Buy.")
                    else:
                        insights_loss.append(f"👉 **Điểm yếu đa chiều (Cân bằng)**: Các tháng lỗ phân bổ đều ở cả chiều Buy và Sell. Cấu trúc thị trường lúc này hoàn toàn không phù hợp với logic của EA, cắn Stop Loss cả hai bên.")

                # Volatility / Choppiness Insight
                if avg_trades_losers > avg_trades_all * 1.3:
                    insights_loss.append(f"👉 **Nhận diện Regime (Whipsaw/Choppy)**: Số lượng lệnh trong các tháng lỗ cao bất thường (Trung bình {avg_trades_losers:.0f} lệnh/tháng so với mức trung bình {avg_trades_all:.0f} bình thường). Đây là dấu hiệu của thị trường dao động nhiễu, đi ngang biên độ hẹp cắn Stop Loss liên tục. Khuyến nghị: Thêm bộ lọc **ADX < 20** hoặc **ATR hẹp** để ngừng giao dịch.")
                elif avg_trades_losers < avg_trades_all * 0.7:
                    insights_loss.append(f"👉 **Nhận diện Regime (Trend Expansion)**: Số lượng lệnh cực kỳ ít nhưng lỗ lại sâu. Nghĩa là thị trường chạy một mạch ngược hướng kỳ vọng, không có nhịp hồi để EA thoát lệnh. Khuyến nghị: Sử dụng bộ lọc động lượng (Momentum) để né các cú breakout giả hoặc cắt lỗ sớm.")
                else:
                    insights_loss.append(f"👉 **Nhận diện Regime**: Tần suất giao dịch không thay đổi nhiều so với bình thường. Nguyên nhân lỗ chủ yếu do tỷ lệ Win Rate giảm mạnh trong các tháng này (trung bình chỉ đạt {(top_losers['Win Rate %'].mean()):.1f}%). Cần xem lại khoảng cách cắt lỗ (SL) có đang quá hẹp khiến giá dễ chạm tới hay không.")

        for ins in insights_loss:
            st.info(ins)

        # ── STEP 7: WFE ANALYSIS ──────────────────────────────────
        st.header("7️⃣ Phân Tích Độ Bền (WFE - Walk Forward Efficiency)")
        wfe_tab1, wfe_tab2 = st.tabs(["📊 Tính từ dữ liệu backtest (Split)", "✏️ Nhập thủ công"])
        with wfe_tab1:
            if 'Time' in trades.columns:
                min_date = trades['Time'].min()
                max_date = trades['Time'].max()
                split_date = min_date + (max_date - min_date) * 0.7
                st.write(f"Chia dữ liệu tại: {split_date.strftime('%d/%m/%Y')}")
                
                is_trades = trades[trades['Time'] <= split_date]
                oos_trades = trades[trades['Time'] > split_date]
                
                is_profit = is_trades['Profit'].sum()
                oos_profit = oos_trades['Profit'].sum()
                
                is_days = (split_date - min_date).days
                oos_days = (max_date - split_date).days
                
                wfe = oos_profit / is_profit if is_profit > 0 else 0
                
                wc1, wc2, wc3, wc4 = st.columns(4)
                wc1.metric("Lợi nhuận In-Sample (IS)", f"${is_profit:,.2f}", f"{len(is_trades)} lệnh ({is_days} ngày)")
                wc2.metric("Lợi nhuận Out-of-Sample (OOS)", f"${oos_profit:,.2f}", f"{len(oos_trades)} lệnh ({oos_days} ngày)")
                
                if is_days > 0 and oos_days > 0 and is_profit > 0:
                    is_annual = is_profit / is_days * 365
                    oos_annual = oos_profit / oos_days * 365
                    annual_wfe = oos_annual / is_annual
                    wc3.metric("WFE (Tuyệt đối)", f"{wfe*100:.1f}%")
                    wc4.metric("WFE (Thường niên - Annualized)", f"{annual_wfe*100:.1f}%")
                    final_wfe = annual_wfe
                    wfe_data = {'is_profit': is_profit, 'oos_profit': oos_profit,
                                'is_days': is_days, 'oos_days': oos_days,
                                'wfe': wfe, 'annual_wfe': annual_wfe}
                else:
                    wc3.metric("WFE (Tuyệt đối)", f"{wfe*100:.1f}%")
                    final_wfe = wfe
                    wfe_data = {'is_profit': is_profit, 'oos_profit': oos_profit,
                                'is_days': is_days, 'oos_days': oos_days,
                                'wfe': wfe, 'annual_wfe': wfe}
                
                if is_profit > 0:
                    if final_wfe >= 0.5:
                        st.success("✅ **WFE Khả quan (>= 50%)**: Chiến lược duy trì được lợi thế giao dịch trong tập dữ liệu Out-of-Sample. Ít có rủi ro Overfitting.")
                    elif final_wfe > 0:
                        st.warning("⚠️ **WFE Thấp (< 50%)**: Lợi nhuận OOS sụt giảm mạnh so với IS. Dấu hiệu của việc Curve-fitting (Quá khớp dữ liệu quá khứ).")
                    else:
                        st.error("❌ **WFE Âm**: Chiến lược thua lỗ trong giai đoạn Out-of-Sample. Hệ thống đã phá vỡ hoàn toàn và không nên giao dịch thực tế.")
                else:
                    st.info("Vui lòng đảm bảo Lợi nhuận In-Sample > 0 để tính toán WFE hợp lệ.")
            else:
                st.info("Dữ liệu không đủ số ngày để chia In-Sample và Out-of-Sample.")
                
    with wfe_tab2:
        st.info("Sử dụng lựa chọn này nếu file đang load là file kết quả Out-of-Sample, và bạn đã biết mức lợi nhuận của giai đoạn In-Sample trước đó.")
        expected_is_profit = st.number_input("Lợi nhuận kỳ vọng từ Backtest (In-Sample) ($)", min_value=0.0, value=1000.0, step=100.0)
        actual_oos_profit = m['Net Profit ($)']
        
        manual_wfe = actual_oos_profit / expected_is_profit if expected_is_profit > 0 else 0
        
        mc1, mc2, mc3 = st.columns(3)
        mc1.metric("In-Sample Profit (Kỳ vọng)", f"${expected_is_profit:,.2f}")
        mc2.metric("Out-of-Sample Profit (Thực tế từ file)", f"${actual_oos_profit:,.2f}")
        mc3.metric("WFE", f"{manual_wfe*100:.1f}%")
        
        if expected_is_profit > 0:
            if manual_wfe >= 0.5:
                st.success("✅ **WFE Khả quan (>= 50%)**: Chiến lược hoạt động tốt trên tập dữ liệu chưa từng thấy.")
            elif manual_wfe > 0:
                st.warning("⚠️ **WFE Thấp (< 50%)**: Hiệu suất giảm đáng kể. Cần cẩn trọng rủi ro Overfitting.")
            else:
                st.error("❌ **WFE Âm**: Chiến lược thua lỗ trong OOS.")

    # ── INSIGHTS SUMMARY ──────────────────────────────────────
    if current_sub_route in ["all", "quant_wfe"]:
        st.header("8️⃣ 💡 Tổng Kết Hiệu Suất")
        insights = []
        if isinstance(m['Profit Factor'], float) and m['Profit Factor'] > 1.5:
            insights.append("✅ **Profit Factor > 1.5**: Chiến lược có lợi thế rõ ràng.")
        elif isinstance(m['Profit Factor'], float) and m['Profit Factor'] < 1.0:
            insights.append("❌ **Profit Factor < 1.0**: Chiến lược đang THUA ròng. Cần xem lại logic.")
        if m['Max DD (%)'] > 30:
            insights.append("⚠️ **Max DD > 30%**: Rủi ro sụt giảm vốn quá cao. Cân nhắc giảm lot hoặc thêm filter.")
        if m['Avg R:R'] > 1.5:
            insights.append("✅ **R:R trung bình > 1.5**: Chiến lược cho phép win rate thấp mà vẫn có lãi.")
        elif m['Avg R:R'] < 1.0:
            insights.append("⚠️ **R:R < 1.0**: Mỗi lệnh thua lớn hơn lệnh thắng. Cần win rate cao để bù đắp.")
        if risk_of_ruin > 5:
            insights.append(f"🔴 **Risk of Ruin = {risk_of_ruin:.1f}%**: Xác suất cháy tài khoản đáng lo ngại.")
        else:
            insights.append(f"🟢 **Risk of Ruin = {risk_of_ruin:.1f}%**: Xác suất cháy tài khoản thấp.")
        if ks_pval < 0.05:
            insights.append("📊 **Fat-tail detected**: Profit phụ thuộc vào một số lệnh lớn bất thường. "
                            "Nếu mất các lệnh này, hiệu suất sẽ giảm đáng kể.")

        # Time insights
        tcol = 'OpenTime' if 'OpenTime' in trades.columns and trades['OpenTime'].notna().any() else 'Time'
        if tcol in trades.columns:
            tdf = trades[[tcol, 'Profit']].dropna(subset=[tcol, 'Profit']).copy()
            tdf['Hour'] = tdf[tcol].dt.hour
            hour_profit = tdf.groupby('Hour')['Profit'].sum()
            if not hour_profit.empty:
                worst_hour = hour_profit.idxmin()
                best_hour = hour_profit.idxmax()
                if hour_profit[worst_hour] < 0:
                    insights.append(f"⏰ **Giờ thua lỗ nhiều nhất**: {worst_hour}:00 (${hour_profit[worst_hour]:,.0f}). "
                                   f"Cân nhắc tạo bộ lọc thời gian để tránh phiên này.")
                insights.append(f"⏰ **Giờ lãi nhiều nhất**: {best_hour}:00 (${hour_profit[best_hour]:,.0f}).")

        for ins in insights:
            st.markdown(ins)

    # ── STEP 9: AI STRATEGY PROFILING (REGIME DNA) ────────────────
    if current_sub_route in ["all", "dna_ai"]:
        st.header("9️⃣ 🧬 AI Strategy Profiling (Reverse Regime DNA v2)")
        st.markdown("""
        **DNA v2 (Expectancy Block-List)** — theo dõi **trên Streamlit Live Monitor** (không cần gắn MT5):
        1. Map regime tại **OpenTime** (nến đã đóng) — chống lookahead.
        2. Học **expectancy ($/lệnh)** → **block-list leaf toxic**.
        3. Deploy tree = **train-only** (khớp OOS); Live Monitor chạy **cùng `rule_paths`**.
        """)

        import importlib
        import regime_analyzer
        # Streamlit keeps modules in memory — reload so DNA signature/fixes always apply
        regime_analyzer = importlib.reload(regime_analyzer)
        saved_profile = regime_analyzer.load_regime_registry(selected)
        
        if saved_profile:
            has_rules = bool(saved_profile.get("rule_paths"))
            msg = (
                f"💾 **Hồ sơ DNA** (cập nhật: `{saved_profile.get('last_updated', 'N/A')}` | "
                f"TF: `{saved_profile.get('timeframe', '1h')}`)"
            )
            if has_rules:
                st.success(msg + " · có **rule_paths** cho Live Monitor.")
            else:
                st.warning(msg + " · **thiếu rule_paths** (registry cũ) — nên train lại.")
            with st.expander("⚡ Xem ngay Hồ sơ Regime DNA đã lưu cho chiến lược này", expanded=True):
                render_dna_tabs(saved_profile)

        workspace_dir = os.path.dirname(os.path.abspath(__file__))
        
        ohlc_upload = st.file_uploader("📥 Tải lên file dữ liệu giá OHLC (.csv) từ máy của bạn:", type=["csv"])
        if ohlc_upload is not None:
            file_key_ohlc = f"{ohlc_upload.name}_{ohlc_upload.size}"
            if st.session_state.get("last_ohlc_key") != file_key_ohlc:
                save_ohlc_path = os.path.join(BACKTEST_DIR, ohlc_upload.name)
                with open(save_ohlc_path, "wb") as f:
                    f.write(ohlc_upload.getbuffer())
                with open(os.path.join(workspace_dir, ohlc_upload.name), "wb") as f:
                    f.write(ohlc_upload.getbuffer())
                st.success(f"Đã lưu file OHLC lên server: `{ohlc_upload.name}`")
                if service and drive_folder_id:
                    with st.spinner("☁️ Đang đồng bộ file OHLC sang Google Drive..."):
                        sync_drive(service, drive_folder_id, BACKTEST_DIR, force_upload_file=save_ohlc_path)
                st.session_state["last_ohlc_key"] = file_key_ohlc
            
        raw_ohlc = sorted(list(set(glob.glob(os.path.join(workspace_dir, "*.csv")) + glob.glob(os.path.join(BACKTEST_DIR, "*.csv")))))
        ohlc_files = [f for f in raw_ohlc if is_ohlc_file(f)]
        ohlc_names = [os.path.basename(f) for f in ohlc_files]
        
        ohlc_source_mode = st.radio(
            "🔌 Nguồn OHLC để soi bối cảnh:",
            [
                "📂 Chọn file CSV MT5 (Khuyến nghị — cùng clock với backtest)",
                "🟣 Twelve Data API (XAU/USD spot — không cần MT5)",
                "🌐 Yahoo Finance API (GC=F futures — có thể lệch)",
            ],
            horizontal=True,
        )
        
        ohlc_ref_name = ""
        sel_ohlc = None
        prof_symbol = "XAU/USD"
        prof_period = "2y"
        hist_source = "csv"
        
        if ohlc_source_mode.startswith("🟣"):
            hist_source = "twelvedata"
            st.caption(
                "Twelve Data: **XAU/USD** spot (gần CFD hơn Yahoo GC=F). "
                "Vẫn có thể lệch nhẹ vs broker — free plan giới hạn nến/credit."
            )
            td_key_dna = regime_analyzer.get_twelvedata_api_key(get_secret("TWELVE_DATA_API_KEY"))
            if not td_key_dna:
                st.warning("⚠️ Chưa thấy `TWELVE_DATA_API_KEY` trong secrets/env.")
            col_ps1, col_ps2 = st.columns([2, 1])
            prof_symbol = col_ps1.text_input(
                "Symbol Twelve Data:",
                value="XAU/USD",
                help="XAU/USD, EUR/USD, BTC/USD — hoặc XAUUSD (tự map).",
            )
            prof_period = col_ps2.selectbox("Period:", ["2y", "1y", "60d", "5y"], index=0)
            ohlc_ref_name = f"Twelve_{prof_symbol.replace('/', '')}_{prof_period}"
        elif ohlc_source_mode.startswith("🌐"):
            hist_source = "yahoo"
            st.caption(
                "⚠️ Yahoo vàng: **`GC=F`** (futures). DNA production nên CSV MT5."
            )
            col_ps1, col_ps2 = st.columns([2, 1])
            prof_symbol = col_ps1.text_input(
                "Symbol Yahoo:",
                value="GC=F",
                help="Vàng: GC=F | Forex: EURUSD=X | Crypto: BTC-USD.",
            )
            prof_period = col_ps2.selectbox("Period:", ["2y", "1y", "5y", "60d"], index=0)
            ohlc_ref_name = f"Yahoo_{prof_symbol}_{prof_period}"
        else:
            hist_source = "csv"
            if not ohlc_names:
                st.warning("⚠️ Chưa có file CSV. Tải lên OHLC MT5 export ở trên.")
            else:
                sel_ohlc = st.selectbox("📥 File CSV OHLC:", ohlc_names)
                ohlc_ref_name = sel_ohlc
            
        prof_col3, prof_col4, prof_col5, prof_col6 = st.columns([1, 1, 1, 1])
        max_depth_input = prof_col3.number_input("Độ sâu cây AI (Max Depth)", min_value=1, max_value=5, value=3)
        timeframe_sel = prof_col4.selectbox("Khung soi bối cảnh", ["1h", "4h"], index=0)
        thr_mode_ui = prof_col5.selectbox(
            "Chế độ ngưỡng thr",
            ["auto (OOS pick)", "fixed"],
            index=0,
            help="auto: chọn thr tối ưu theo OOS. fixed: dùng đúng số bên cạnh.",
        )
        exp_thr_input = prof_col6.number_input(
            "Ngưỡng expectancy ($)",
            min_value=-20.0, max_value=20.0, value=-5.0, step=1.0,
            help="fixed: chặn leaf exp ≤ giá trị này. auto: giá trị này là 1 candidate + các mốc -10/-5/-2/0.",
        )

        if st.button("🚀 Huấn luyện AI & Bốc tách Luật Regime DNA", type="primary"):
            with st.spinner("Đang map OpenTime + tính chỉ số bối cảnh tại ENTRY + train expectancy tree..."):
                try:
                    if hist_source == "twelvedata":
                        td_key_dna = regime_analyzer.get_twelvedata_api_key(get_secret("TWELVE_DATA_API_KEY"))
                        df_tf, err_msg = regime_analyzer.fetch_historical_ohlc(
                            prof_symbol,
                            timeframe=timeframe_sel,
                            period=prof_period,
                            source="twelvedata",
                            api_key=td_key_dna,
                        )
                        if err_msg or df_tf is None or df_tf.empty:
                            st.error(f"❌ Lỗi Twelve Data: {err_msg or 'Không có dữ liệu.'}")
                            return
                        st.caption(
                            f"Twelve Data: {len(df_tf)} nến · "
                            f"`{getattr(df_tf, 'attrs', {}).get('twelvedata_symbol', prof_symbol)}`"
                        )
                    elif hist_source == "yahoo":
                        df_tf, err_msg = regime_analyzer.fetch_historical_ohlc(
                            prof_symbol, timeframe=timeframe_sel, period=prof_period, source="yahoo"
                        )
                        if err_msg or df_tf is None or df_tf.empty:
                            st.error(f"❌ Lỗi Yahoo Finance: {err_msg or 'Không có dữ liệu.'}")
                            return
                    else:
                        if not sel_ohlc:
                            st.error("❌ Vui lòng chọn hoặc tải lên file CSV trước.")
                            return
                        ohlc_path = ohlc_files[ohlc_names.index(sel_ohlc)]
                        df_m1 = regime_analyzer.load_ohlc(ohlc_path)
                        df_tf = regime_analyzer.resample_ohlc(df_m1, timeframe_sel)

                    # Always ensure OpenTime before DNA (st.cache_data / old .cache.pkl often strip pairing)
                    def _dna_log(msg):
                        st.caption(msg)

                    trades_for_dna, ot_cov = ensure_trades_have_open_time(
                        trades, backtest_path=file_path, log_progress=_dna_log
                    )
                    if ot_cov < 0.5:
                        st.error(
                            f"❌ OpenTime coverage chỉ {ot_cov*100:.1f}% — không thể train DNA "
                            f"(tránh lookahead). Kiểm tra file backtest có bảng Deals với Direction in/out."
                        )
                        return
                    if ot_cov < 0.95:
                        st.warning(f"⚠️ OpenTime coverage {ot_cov*100:.1f}% < 95% — pairing một phần.")
                    else:
                        st.info(f"✅ OpenTime sẵn sàng: {ot_cov*100:.1f}% lệnh có thời điểm vào lệnh.")

                    cache_p = os.path.join(BACKTEST_DIR, f"{ohlc_ref_name}_{timeframe_sel}_indicators.cache.pkl")
                    thr_mode = "fixed" if thr_mode_ui.startswith("fixed") else "auto"
                    dna_res = regime_analyzer.extract_strategy_dna(
                        df_tf, trades_for_dna,
                        max_depth=max_depth_input,
                        cache_path=cache_p,
                        strategy_name=selected,
                        exp_threshold=float(exp_thr_input),
                        filter_mode="block_toxic",
                        threshold_mode=thr_mode,
                    )

                    if "error" in dna_res:
                        st.error(dna_res["error"])
                    else:
                        regime_analyzer.save_regime_registry(selected, dna_res, ohlc_ref_name, timeframe_sel)
                        if service and drive_folder_id:
                            sync_drive(service, drive_folder_id, BACKTEST_DIR, force_upload_file=regime_analyzer.REGISTRY_FILE)
                        st.success(
                            f"✅ DNA v2 OK · thr={dna_res.get('exp_threshold')} ({dna_res.get('threshold_mode')}) · "
                            f"toxic paths={len((dna_res.get('rule_paths') or {}).get('toxic_paths') or [])} · "
                            f"đã lưu Registry cho Live Monitor"
                        )
                        render_dna_tabs(dna_res)
                except Exception as e:
                    st.error(f"Lỗi khi giải mã DNA: {e}")
                    import traceback
                    st.code(traceback.format_exc())

    # ── SIDEBAR EXPORT BUTTON ──
    st.sidebar.markdown("---")
    st.sidebar.header("📤 Xuất Báo Cáo Markdown")
    
    streaks = (avg_win_streak, max_win_streak, avg_loss_streak, max_loss_streak)
    daily_streaks = (avg_win_days, max_win_days, avg_loss_days, max_loss_days)
    monthly = (win_months, loss_months, win_month_ratio)
    
    stag_start, stag_end, stag_duration = get_longest_stagnation(trades)

    # monthly_stats for report — may not exist if Type col is absent
    monthly_stats_export = monthly_stats if 'monthly_stats' in dir() else None

    report_md = generate_markdown_report(
        selected, m, streaks, daily_streaks, monthly,
        insights_loss, insights,
        stag_start, stag_end, stag_duration,
        sideways_periods=sideways_periods,
        mc_data=mc_data if 'mc_data' in dir() else None,
        wfe_data=wfe_data if 'wfe_data' in dir() else None,
        monthly_stats_df=monthly_stats_export,
        hour_profit_series=hour_profit_export if 'hour_profit_export' in dir() else None,
        dow_profit_series=dow_profit_export if 'dow_profit_export' in dir() else None,
    )
    
    # Download button for browser download
    st.sidebar.download_button(
        label="📥 Tải Báo Cáo (.md)",
        data=report_md,
        file_name=f"{os.path.splitext(selected)[0]}_report.md",
        mime="text/markdown"
    )
    
    # Save button to write directly to workspace backtest result folder
    if st.sidebar.button("💾 Lưu báo cáo vào thư mục"):
        report_filename = f"{os.path.splitext(selected)[0]}_report.md"
        report_path = os.path.join(BACKTEST_DIR, report_filename)
        try:
            with open(report_path, "w", encoding="utf-8") as f:
                f.write(report_md)
            st.sidebar.success(f"Đã lưu báo cáo tại: `backtest result/{report_filename}`")
        except Exception as e:
            st.sidebar.error(f"Lỗi khi lưu báo cáo: {e}")

if __name__ == '__main__':
    from streamlit.runtime import exists
    if not exists():
        import sys
        import subprocess
        print("Starting Streamlit app...")
        subprocess.run([sys.executable, "-m", "streamlit", "run", sys.argv[0]] + sys.argv[1:])
    else:
        main()
