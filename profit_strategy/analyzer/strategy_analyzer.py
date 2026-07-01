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
        # Phương án 1: OAuth 2.0 User Flow (Dùng cho Google Drive cá nhân)
        if os.path.exists('token.pickle'):
            with open('token.pickle', 'rb') as token:
                creds = pickle.load(token)
                
        if os.path.exists('credentials.json') and (not creds or not creds.valid):
            if creds and creds.expired and creds.refresh_token:
                creds.refresh(Request())
            else:
                flow = InstalledAppFlow.from_client_secrets_file('credentials.json', SCOPES)
                creds = flow.run_local_server(port=0)
            with open('token.pickle', 'wb') as token:
                pickle.dump(creds, token)
                
        if creds and creds.valid:
            return build('drive', 'v3', credentials=creds)
            
        # Phương án 2: Service Account (Dành cho Shared Drives)
        gcp_account = get_secret("gcp_service_account")
        if gcp_account:
            creds = service_account.Credentials.from_service_account_info(
                gcp_account, scopes=SCOPES
            )
            return build('drive', 'v3', credentials=creds)
            
    except Exception as e:
        st.sidebar.error(f"Lỗi khởi tạo Google Drive: {e}")
        
    return None

def sync_drive(service, folder_id, local_dir, force_upload_file=None):
    try:
        os.makedirs(local_dir, exist_ok=True)
        # Download từ Drive danh sách file hiện có
        results = service.files().list(
            q=f"'{folder_id}' in parents and trashed=false", 
            fields="files(id, name)",
            supportsAllDrives=True,
            includeItemsFromAllDrives=True
        ).execute()
        drive_files = {item['name']: item['id'] for item in results.get('files', [])}
        
        # Ưu tiên đẩy file vừa tải lên (hoặc cập nhật nếu đã tồn tại tên file)
        if force_upload_file and os.path.exists(force_upload_file):
            name = os.path.basename(force_upload_file)
            media = MediaFileUpload(force_upload_file, resumable=True)
            if name in drive_files:
                service.files().update(
                    fileId=drive_files[name],
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
                drive_files[name] = res.get('id')
        
        # Download từ Drive về local nếu chưa có
        for name, file_id in drive_files.items():
            local_path = os.path.join(local_dir, name)
            if not os.path.exists(local_path):
                request = service.files().get_media(fileId=file_id)
                with io.FileIO(local_path, 'wb') as fh:
                    downloader = MediaIoBaseDownload(fh, request)
                    done = False
                    while not done: _, done = downloader.next_chunk()
        
        # Upload các file local mới chưa có trên Drive (loại trừ file cache tạm thời)
        for f in glob.glob(os.path.join(local_dir, "*.*")):
            name = os.path.basename(f)
            if name not in drive_files and not name.endswith(".cache.pkl"):
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

@st.cache_data
def load_backtest(file_path):
    import pickle
    cache_path = file_path + ".cache.pkl"
    if os.path.exists(cache_path) and os.path.getmtime(cache_path) >= os.path.getmtime(file_path):
        try:
            with open(cache_path, "rb") as f:
                trades, metrics = pickle.load(f)
            return trades, metrics, None
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
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        if file_path.lower().endswith('.csv'):
            try: raw = pd.read_csv(file_path, header=None, encoding='utf-16le', sep='\t')
            except: raw = pd.read_csv(file_path, header=None)
        else:
            try:
                raw = pd.read_excel(file_path, engine='calamine', header=None)
            except Exception:
                raw = pd.read_excel(file_path, engine='openpyxl', header=None)

    log_progress("🔎 Bước 2: Đang quét cấu trúc báo cáo MT5 để tìm bảng Deals...")
    # Find Deals table
    deals_mask = raw[0].astype(str).str.strip() == 'Deals'
    if deals_mask.any():
        deals_start = raw[deals_mask].index[0]
    else:
        if status:
            status.update(label="❌ Lỗi: Không tìm thấy bảng Deals trong tệp!", state="error")
        return None, None, None

    log_progress("📊 Bước 3: Đang trích xuất và làm sạch dữ liệu giao dịch...")
    header_idx = deals_start + 1
    df = raw.iloc[header_idx + 1:].copy()
    df.columns = raw.iloc[header_idx].values

    # Clean columns
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

    df['Time'] = pd.to_datetime(df['Time'], errors='coerce')
    df.dropna(subset=['Time'], inplace=True)

    for nc in ['Profit', 'Balance', 'Volume', 'Price', 'Swap', 'Commission']:
        if nc in df.columns:
            df[nc] = pd.to_numeric(df[nc], errors='coerce')

    # Filter only closed trades (direction=out or has profit != 0)
    if 'Direction' in df.columns:
        trades = df[df['Direction'].astype(str).str.strip().str.lower() == 'out'].copy()
    else:
        trades = df[df['Profit'].notna() & (df['Profit'] != 0)].copy()

    log_progress("🔗 Bước 4: Đang đối chiếu các vị thế In/Out (khớp lệnh vào/ra)...")
    # Build entry info: match each "out" deal to its "in" deal via Order
    if 'Direction' in df.columns and 'Order' in df.columns:
        entries = df[df['Direction'].astype(str).str.strip().str.lower() == 'in'].copy()
        entry_map = entries.set_index('Order')[['Time', 'Price', 'Type']].rename(
            columns={'Time': 'OpenTime', 'Price': 'OpenPrice', 'Type': 'TradeType'})
        # Some orders may not exist, use left join
        if 'Order' in trades.columns:
            trades = trades.merge(entry_map, left_on='Order', right_index=True, how='left')

    # Duration
    if 'OpenTime' in trades.columns:
        trades['Duration'] = (trades['Time'] - trades['OpenTime']).dt.total_seconds() / 3600.0
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

    log_progress("💾 Bước 6: Đang lưu trữ dữ liệu đã phân giải vào bộ nhớ đệm (Cache)...")
    try:
        with open(cache_path, "wb") as f:
            pickle.dump((trades, metrics), f, protocol=pickle.HIGHEST_PROTOCOL)
    except Exception:
        pass

    if status:
        status.update(label="✅ Hoàn tất phân tích dữ liệu!", state="complete", expanded=False)
    else:
        status_placeholder.empty()

    return trades, metrics, raw

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
    
    app_mode = st.sidebar.radio("🧭 Chế độ hiển thị", ["📊 Phân Tích & Tối Ưu DNA", "📡 Giám Sát Bối Cảnh Realtime (Live Monitor)"])
    if app_mode == "📡 Giám Sát Bối Cảnh Realtime (Live Monitor)":
        st.header("📡 Live Regime Monitor (Giám Sát Bối Cảnh Thời Gian Thực)")
        st.markdown("Hệ thống tự động bốc tách chỉ số thị trường realtime và hiển thị trực quan mức độ phù hợp với các chiến lược EA đã phân tích.")
        
        import regime_analyzer
        registry_data = regime_analyzer.load_regime_registry()
        
        if not registry_data:
            st.warning("⚠️ Chưa có chiến lược nào được giải mã Regime DNA trong hệ thống. Vui lòng chuyển sang chế độ **📊 Phân Tích & Tối Ưu DNA** để huấn luyện AI trước.")
            return
            
        watchlist = regime_analyzer.load_live_watchlist()
        workspace_dir = os.path.dirname(os.path.abspath(__file__))
        ohlc_files = sorted(glob.glob(os.path.join(workspace_dir, "*M1*.csv")) + glob.glob(os.path.join(workspace_dir, "*H1*.csv")))
        ohlc_names = [f"File CSV: {os.path.basename(f)}" for f in ohlc_files]
        src_options = ["Yahoo Finance API (REST API)", "MetaTrader 5 (Direct Terminal Bridge)"] + ohlc_names
        
        with st.expander("➕ Quản Lý Danh Sách Theo Dõi (Watchlist)", expanded=False):
            st.markdown("Thêm cặp tiền / mã giao dịch vào danh sách để hệ thống tự động quét mỗi khi vào trang:")
            col_w1, col_w2, col_w3, col_w4 = st.columns([2, 1, 1, 1])
            new_src = col_w1.selectbox("🌐 Nguồn dữ liệu:", src_options, key="w_src")
            def_sym = "GC=F" if "Yahoo" in new_src else ("XAUUSD" if "Meta" in new_src else "")
            new_sym = col_w2.text_input("Mã (Symbol):", value=def_sym, disabled=new_src.startswith("File CSV"), key="w_sym")
            new_tf = col_w3.selectbox("⏱️ Khung:", ["1h", "4h", "15m", "5m"], index=0, key="w_tf")
            
            if col_w4.button("➕ Thêm ngay", type="secondary"):
                sym_val = new_src.replace("File CSV: ", "") if new_src.startswith("File CSV") else new_sym
                if not sym_val:
                    st.error("Vui lòng nhập mã Symbol!")
                else:
                    if not any(w['symbol'] == sym_val and w['source'] == new_src and w['timeframe'] == new_tf for w in watchlist):
                        watchlist.append({"symbol": sym_val, "source": new_src, "timeframe": new_tf})
                        regime_analyzer.save_live_watchlist(watchlist)
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
                target_sym = os.path.join(workspace_dir, sym) if src.startswith("File CSV") else sym
                with st.spinner(f"Đang kéo dữ liệu live & tính toán bối cảnh cho {sym}..."):
                    df_live, err_msg = regime_analyzer.fetch_live_ohlc(src, target_sym, tf)
                
                if err_msg or df_live is None or df_live.empty:
                    st.error(f"❌ Lỗi kết nối lấy dữ liệu cho `{sym}`: {err_msg or 'Không có dữ liệu nến.'}")
                    st.markdown("---")
                    continue
                    
                eval_res = regime_analyzer.evaluate_live_market(df_live, registry_data)
                latest_bar = eval_res.get("latest_bar", {})
                latest_time = eval_res.get("latest_time", "N/A")
                
                st.caption(f"⏱️ Cập nhật nến gần nhất: `{latest_time}`")
                g_cols = st.columns(4)
                g_cols[0].metric("ADX (Xu hướng)", f"{latest_bar.get('ADX', 0):.1f}", "Mạnh" if latest_bar.get('ADX', 0) > 25 else "Yếu")
                hurst_val = latest_bar.get('Hurst', 0.5)
                h_desc = "Trending" if hurst_val > 0.53 else ("Sideways" if hurst_val < 0.47 else "Random")
                g_cols[1].metric("Hurst Exponent", f"{hurst_val:.2f}", h_desc)
                g_cols[2].metric("Choppiness", f"{latest_bar.get('Choppiness', 50):.1f}")
                g_cols[3].metric("BB Width", f"{latest_bar.get('BB_Width', 0):.3f}")
                
                evals = eval_res.get("evaluations", {})
                for s_name, s_info in evals.items():
                    st_code = s_info["status"]
                    if st_code == "PASS":
                        badge = "🟢 BẬT EA (PHÙ HỢP TỐT)"
                        border_color = "#00d4aa"
                    elif st_code == "CAUTION":
                        badge = "🟡 CẨN TRỌNG (THEO DÕI SÁT)"
                        border_color = "#ffa502"
                    else:
                        badge = "🔴 KHÓA LỆNH / ĐỨNG NGOÀI"
                        border_color = "#ff4757"
                        
                    st.markdown(f"""
                    <div style="border-left: 5px solid {border_color}; padding: 12px; background: #1a1a2e; margin: 8px 0; border-radius: 6px;">
                        <span style="font-size: 16px; font-weight: bold; color: {border_color};">{badge}</span> | <span style="color: white; font-weight: bold; font-size: 16px;">{s_name}</span> (Độ khớp: {s_info['match_pct']}%)
                    </div>
                    """, unsafe_allow_html=True)
                    with st.expander(f"🔍 Lý do khuyến nghị cho {s_name} (Độ chính xác Train {s_info['accuracy']*100:.1f}% | CV {s_info['cv_accuracy']*100:.1f}%)"):
                        for r in s_info["reasons"]:
                            st.markdown(f"- {r}")
                st.markdown("---")
                
        if auto_refresh:
            import time
            time.sleep(60)
            st.rerun()
        return
    
    # ── GOOGLE DRIVE SYNC ──
    service = get_drive_service()
    drive_folder_id = get_secret("drive_folder_id")
    
    if service and drive_folder_id:
        # Tự động đồng bộ từ Google Drive về local container ngay lần đầu khởi động phiên
        if not st.session_state.get("auto_synced_drive", False):
            with st.spinner("☁️ Đang tự động đồng bộ dữ liệu từ Google Drive..."):
                sync_drive(service, drive_folder_id, BACKTEST_DIR)
            st.session_state["auto_synced_drive"] = True

        if st.sidebar.button("🔄 Đồng bộ dữ liệu với Drive"):
            with st.spinner("Đang đồng bộ 2 chiều..."):
                sync_drive(service, drive_folder_id, BACKTEST_DIR)
            st.sidebar.success("Đồng bộ hoàn tất!")
            st.rerun()
    
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
    files = sorted(glob.glob(os.path.join(BACKTEST_DIR, "*.xlsx")) +
                   glob.glob(os.path.join(BACKTEST_DIR, "*.xls")) +
                   glob.glob(os.path.join(BACKTEST_DIR, "*.csv")), reverse=True)
    
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

    # ── STEP 1: CORE METRICS ─────────────────────────────────
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

    stag_start, stag_end, stag_duration = get_longest_stagnation(trades)
    if stag_duration > 0:
        st.info(f"🐢 **Thời gian phục hồi đỉnh lâu nhất (Longest Drawdown Duration)**: Kéo dài **{stag_duration} ngày**, từ **{stag_start.strftime('%d/%m/%Y')}** đến **{stag_end.strftime('%d/%m/%Y')}**. "
                f"Đây là khoảng thời gian chiến lược bị chôn vốn, không tạo ra đỉnh lợi nhuận mới.")

    # ── Phân tích chuỗi lệnh & ngày liên tiếp ──
    st.markdown("### 📈 Phân Tích Chuỗi Giao Gịch & Chu Kỳ Tháng")
    
    # Calculate streaks
    avg_win_streak, max_win_streak, avg_loss_streak, max_loss_streak = get_streaks(profits)
    avg_win_days, max_win_days, avg_loss_days, max_loss_days = get_daily_streaks(trades)
    win_months, loss_months, win_month_ratio = get_monthly_win_loss_ratio(trades)
    
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

    sideways_periods = get_sideways_periods(trades, stag_threshold, stag_min_days)
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

    # Hourly / DOW profit series for export
    tcol_h = 'OpenTime' if 'OpenTime' in trades.columns and trades['OpenTime'].notna().any() else 'Time'
    hour_profit_export = None
    dow_profit_export = None
    if tcol_h in trades.columns:
        _hdf = trades[[tcol_h, 'Profit']].dropna(subset=[tcol_h, 'Profit']).copy()
        if not _hdf.empty:
            hour_profit_export = _hdf.groupby(_hdf[tcol_h].dt.hour)['Profit'].sum()
            dow_profit_export = _hdf.groupby(_hdf[tcol_h].dt.dayofweek)['Profit'].sum()

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

    # ── STEP 7: WFE ANALYSIS ─────────────────────────
    st.header("7️⃣ Đánh Giá Walk-Forward Efficiency (WFE)")
    wfe_data = None  # Will be populated from tab1
    st.markdown("""
    Đánh giá độ ổn định của chiến lược trong tương lai (Out-of-Sample) so với quá trình tối ưu (In-Sample).
    
    Công thức:
    $$WFE = \\frac{\\text{Lợi nhuận thực tế (Out-of-Sample)}}{\\text{Lợi nhuận kỳ vọng từ Backtest (In-Sample)}}$$
    """)
    
    wfe_tab1, wfe_tab2 = st.tabs(["🕒 Chia IS/OOS theo thời gian", "📝 Nhập thủ công In-Sample Profit"])
    
    with wfe_tab1:
        if 'Time' in trades.columns and len(trades) > 0:
            min_date = trades['Time'].min().date()
            max_date = trades['Time'].max().date()
            
            if min_date < max_date:
                split_date = st.slider(
                    "Chọn ngày bắt đầu Out-of-Sample", 
                    min_value=min_date, 
                    max_value=max_date, 
                    value=min_date + (max_date - min_date)//2
                )
                
                is_trades = trades[trades['Time'].dt.date < split_date]
                oos_trades = trades[trades['Time'].dt.date >= split_date]
                
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
    st.header("9️⃣ 🧬 AI Strategy Profiling (Reverse Regime DNA)")
    st.markdown("""
    Giải mã "ADN bối cảnh" của chiến lược: Học máy (Decision Tree) đối chiếu bối cảnh lúc Thắng vs Thua để tự động bốc tách ra luật lọc MQL5 gắn ngược lại vào EA.
    """)

    import regime_analyzer
    saved_profile = regime_analyzer.load_regime_registry(selected)
    
    if saved_profile:
        st.success(f"💾 **Đã tìm thấy Hồ sơ Regime DNA lưu trữ trong Registry** (Cập nhật: `{saved_profile.get('last_updated', 'N/A')}` | Khung: `{saved_profile.get('timeframe', '1h')}`). Bạn không cần tốn thời gian chạy lại!")
        with st.expander("⚡ Xem ngay Hồ sơ Regime DNA đã lưu cho chiến lược này", expanded=True):
            st.markdown(f"**Độ chính xác Train**: `{saved_profile.get('accuracy', 0)*100:.1f}%` | **Độ chính xác Cross-Validation (Chống Overfit)**: `{saved_profile.get('cv_accuracy', 0)*100:.1f}%` | **Mẫu**: `{saved_profile.get('sample_count', 0)}` lệnh ({saved_profile.get('win_count', 0)} Thắng / {saved_profile.get('loss_count', 0)} Thua)")
            if saved_profile.get('cv_accuracy', 0) >= 0.65:
                st.info("🛡️ **Anti-Overfitting Verified**: Điểm số kiểm định chéo Stratified Cross-Validation đạt mức cao và ổn định, chứng tỏ bộ lọc không bị overfit (quá khớp) vào dữ liệu nhiễu.")
            if saved_profile.get("features_csv_path") and os.path.exists(saved_profile["features_csv_path"]):
                st.markdown(f"📂 **Bảng dữ liệu chỉ số bối cảnh từng lệnh đã lưu sẵn**: `{saved_profile['features_csv_path']}`")
            
            p_tab1, p_tab2, p_tab3, p_tab4 = st.tabs(["💻 Code MQL5 Bộ Lọc", "📊 Cây Quyết Định (Text)", "⚖️ Đối Chiếu Thắng vs Thua", "📏 Phân Vùng Lãi/Lỗ (Range Analysis)"])
            with p_tab1:
                st.code(saved_profile.get("mql5_code", ""), language="mql5")
            with p_tab2:
                st.text(saved_profile.get("tree_text", ""))
                if saved_profile.get("top_features"):
                    imp_df = pd.DataFrame(list(saved_profile["top_features"].items()), columns=["Chỉ số", "Tầm quan trọng"]).sort_values("Tầm quan trọng", ascending=False)
                    st.dataframe(imp_df, hide_index=True)
            with p_tab3:
                w_ctx = saved_profile.get("win_context", {})
                l_ctx = saved_profile.get("loss_context", {})
                if w_ctx:
                    contrast_df = pd.DataFrame({
                        "Chỉ số Bối Cảnh": list(w_ctx.keys()),
                        "Khi EA THẮNG (Mean)": list(w_ctx.values()),
                        "Khi EA THUA (Mean)": [l_ctx.get(k, 0) for k in w_ctx.keys()]
                    })
                    contrast_df["Chênh Lệch"] = contrast_df["Khi EA THẮNG (Mean)"] - contrast_df["Khi EA THUA (Mean)"]
                    st.dataframe(contrast_df.style.background_gradient(subset=["Chênh Lệch"], cmap="RdYlGn"), hide_index=True)
            with p_tab4:
                range_data = saved_profile.get("range_analysis", {})
                if range_data:
                    st.markdown("Phân rã các chỉ số quan trọng thành từng vùng (Range/Bin) để tránh overfit vào một ngưỡng cắt duy nhất:")
                    for feat_name, zones in range_data.items():
                        st.markdown(f"**🔹 Chỉ số: `{feat_name}`**")
                        z_df = pd.DataFrame(zones)
                        z_df = z_df.rename(columns={"range": "Vùng giá trị (Bin)", "total_trades": "Tổng số lệnh", "win_count": "Số lệnh Thắng", "win_rate": "Tỷ lệ Thắng (%)"})
                        st.dataframe(z_df.style.background_gradient(subset=["Tỷ lệ Thắng (%)"], cmap="RdYlGn"), hide_index=True)
                else:
                    st.info("Chưa có dữ liệu phân vùng cho chiến lược này. Vui lòng chạy lại huấn luyện DNA bên dưới để cập nhật.")

    workspace_dir = os.path.dirname(os.path.abspath(__file__))
    
    ohlc_upload = st.file_uploader("📥 Tải lên file dữ liệu giá OHLC (.csv) từ máy của bạn:", type=["csv"])
    if ohlc_upload is not None:
        save_ohlc_path = os.path.join(workspace_dir, ohlc_upload.name)
        with open(save_ohlc_path, "wb") as f:
            f.write(ohlc_upload.getbuffer())
        st.success(f"Đã lưu file OHLC lên server: `{ohlc_upload.name}`")
        
    ohlc_files = sorted(glob.glob(os.path.join(workspace_dir, "*M1*.csv")) + glob.glob(os.path.join(workspace_dir, "*H1*.csv")) + glob.glob(os.path.join(workspace_dir, "XAUUSD*.csv")))
    ohlc_names = [os.path.basename(f) for f in ohlc_files]
    
    ohlc_source_mode = st.radio("🔌 Nguồn lấy lịch sử giá OHLC để soi bối cảnh:", ["🌐 Tải từ Yahoo Finance API (Tự động & Khuyên dùng)", "📂 Chọn file CSV (Đã tải lên hoặc có sẵn)"], horizontal=True)
    
    ohlc_ref_name = ""
    sel_ohlc = None
    
    if ohlc_source_mode == "🌐 Tải từ Yahoo Finance API (Tự động & Khuyên dùng)":
        col_ps1, col_ps2 = st.columns([2, 1])
        prof_symbol = col_ps1.text_input("Nhập mã giao dịch (Symbol trên Yahoo Finance):", value="GC=F", help="Ví dụ: GC=F (Vàng Futures), EURUSD=X (Forex EURUSD), BTC-USD")
        prof_period = col_ps2.selectbox("Thời gian lịch sử:", ["2y", "1y", "5y", "60d"], index=0, help="Nên chọn 2y hoặc 5y để khớp tốt nhất với lịch sử backtest")
        ohlc_ref_name = f"Yahoo_{prof_symbol}_{prof_period}"
    else:
        if not ohlc_names:
            st.warning("⚠️ Chưa có file CSV nào trên server. Vui lòng sử dụng tính năng tải lên file CSV ở trên.")
        else:
            sel_ohlc = st.selectbox("📥 Chọn file CSV có sẵn trên hệ thống:", ohlc_names)
            ohlc_ref_name = sel_ohlc
            
    prof_col3, prof_col4 = st.columns([1, 2])
    max_depth_input = prof_col3.number_input("Độ sâu cây AI (Max Depth)", min_value=1, max_value=5, value=3)
    timeframe_sel = prof_col4.selectbox("Khung thời gian soi bối cảnh", ["1h", "4h"], index=0)
    
    if st.button("🚀 Huấn luyện AI & Bốc tách Luật Regime DNA", type="primary"):
        with st.spinner("Đang chuẩn bị dữ liệu lịch sử giá & tính toán 12+ chỉ số bối cảnh..."):
            try:
                if ohlc_source_mode == "🌐 Tải từ Yahoo Finance API (Tự động & Khuyên dùng)":
                    df_tf, err_msg = regime_analyzer.fetch_historical_ohlc(prof_symbol, timeframe=timeframe_sel, period=prof_period)
                    if err_msg or df_tf is None or df_tf.empty:
                        st.error(f"❌ Lỗi tải dữ liệu từ Yahoo Finance: {err_msg or 'Không có dữ liệu.'}")
                        return
                else:
                    if not sel_ohlc:
                        st.error("❌ Vui lòng chọn hoặc tải lên file CSV trước.")
                        return
                    ohlc_path = ohlc_files[ohlc_names.index(sel_ohlc)]
                    df_m1 = regime_analyzer.load_ohlc(ohlc_path)
                    df_tf = regime_analyzer.resample_ohlc(df_m1, timeframe_sel)
                
                cache_p = os.path.join(BACKTEST_DIR, f"{ohlc_ref_name}_{timeframe_sel}_indicators.cache.pkl")
                dna_res = regime_analyzer.extract_strategy_dna(df_tf, trades, max_depth=max_depth_input, cache_path=cache_p, strategy_name=selected)
                
                if "error" in dna_res:
                    st.error(dna_res["error"])
                else:
                    regime_analyzer.save_regime_registry(selected, dna_res, ohlc_ref_name, timeframe_sel)
                    st.success(f"✅ Giải mã thành công & đã tự động lưu vào Registry! Độ chính xác Train: **{dna_res['accuracy']*100:.1f}%** | Cross-Validation: **{dna_res.get('cv_accuracy', 0)*100:.1f}%** (Dựa trên {dna_res['sample_count']} nến giao dịch).")
                    if dna_res.get('cv_accuracy', 0) >= 0.65:
                        st.info("🛡️ **Anti-Overfitting Verified**: Điểm kiểm định chéo K-Fold đạt mức cao và ổn định, bộ lọc đảm bảo không bị overfit vào dữ liệu nhiễu ngẫu nhiên.")
                    if dna_res.get("features_csv_path"):
                        st.info(f"💾 Đã xuất toàn bộ bảng chỉ số bối cảnh cho từng lệnh ra file CSV: `{dna_res['features_csv_path']}`")
                    
                    dna_tab1, dna_tab2, dna_tab3, dna_tab4 = st.tabs(["💻 Code MQL5 Bộ Lọc", "📊 Cây Quyết Định (Text)", "⚖️ Đối Chiếu Thắng vs Thua", "📏 Phân Vùng Lãi/Lỗ (Range Analysis)"])
                    
                    with dna_tab1:
                        st.markdown("Copy toàn bộ câu lệnh điều kiện dưới đây gắn vào đầu hàm `OnTick()` của EA trên MT5:")
                        st.code(dna_res["mql5_code"], language="mql5")
                        
                    with dna_tab2:
                        st.text(dna_res["tree_text"])
                        if dna_res.get("top_features"):
                            st.markdown("**Các Đặc Trưng Quan Trọng Nhất (Feature Importances):**")
                            imp_df = pd.DataFrame(list(dna_res["top_features"].items()), columns=["Chỉ số", "Tầm quan trọng"]).sort_values("Tầm quan trọng", ascending=False)
                            st.dataframe(imp_df, hide_index=True)
                            
                    with dna_tab3:
                        st.markdown("**Bảng Đối Chiếu Trung Bình Đặc Trưng Thị Trường:**")
                        contrast_df = pd.DataFrame({
                            "Chỉ số Bối Cảnh": list(dna_res["win_context"].keys()),
                            "Khi EA THẮNG (Mean)": list(dna_res["win_context"].values()),
                            "Khi EA THUA (Mean)": [dna_res["loss_context"].get(k, 0) for k in dna_res["win_context"].keys()]
                        })
                        contrast_df["Chênh Lệch"] = contrast_df["Khi EA THẮNG (Mean)"] - contrast_df["Khi EA THUA (Mean)"]
                        st.dataframe(contrast_df.style.background_gradient(subset=["Chênh Lệch"], cmap="RdYlGn"), hide_index=True)
                        
                    with dna_tab4:
                        range_data = dna_res.get("range_analysis", {})
                        if range_data:
                            st.markdown("Phân rã các chỉ số quan trọng thành từng vùng (Range/Bin) để tránh overfit vào một ngưỡng cắt duy nhất:")
                            for feat_name, zones in range_data.items():
                                st.markdown(f"**🔹 Chỉ số: `{feat_name}`**")
                                z_df = pd.DataFrame(zones)
                                z_df = z_df.rename(columns={"range": "Vùng giá trị (Bin)", "total_trades": "Tổng số lệnh", "win_count": "Số lệnh Thắng", "win_rate": "Tỷ lệ Thắng (%)"})
                                st.dataframe(z_df.style.background_gradient(subset=["Tỷ lệ Thắng (%)"], cmap="RdYlGn"), hide_index=True)
                        else:
                            st.info("Không có thông tin phân vùng cho chiến lược này.")
            except Exception as e:
                st.error(f"Lỗi khi giải mã DNA: {e}")

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
