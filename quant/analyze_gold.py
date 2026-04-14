import pandas as pd
import numpy as np
import sys
sys.stdout.reconfigure(encoding='utf-8')

# Đọc file dữ liệu
file_path = 'USDJPY_M15.csv'
try:
    df = pd.read_csv(file_path, sep='\t')
    if '<DATE>' not in df.columns:
        df = pd.read_csv(file_path, sep=',')
except Exception as e:
    df = pd.read_csv(file_path, sep=',')

# Chuẩn hóa tên cột
df.columns = [col.strip('<>') for col in df.columns]

# Xử lý datetime
df['Datetime'] = pd.to_datetime(df['DATE'] + ' ' + df['TIME'], format='%Y.%m.%d %H:%M:%S')
print("===== TÌM KIẾM KHUNG GIỜ RUN BREAKOUT HIỆU QUẢ NHẤT (MIN RANGE vs EFFECTIVE RANGE) =====")
print("Thuật toán đo tỉ lệ Reward/Risk: Tìm khung giờ có Hộp nhỏ, nhưng Momentum bùng nổ sau đó cực lớn.")

# Gom nến thành H1 để duyệt nhanh các khung giờ dài
h1_df = df.set_index('Datetime').resample('1h').agg({
    'HIGH': 'max',
    'LOW': 'min'
}).dropna()

# MFE window (số giờ theo dõi biến động bùng nổ sau khi đóng Box)
mfe_hours_list = [4, 6, 8, 10, 12, 16] # Test gồng tử 4 tiếng đến 16 tiếng

windows = []
for length in [4, 6, 8]:
    for mfe_hours in mfe_hours_list:
        # Box High, Box Low tại thời điểm t
        rolling_high = h1_df['HIGH'].rolling(window=length).max()
        rolling_low  = h1_df['LOW'].rolling(window=length).min()
        rolling_range = rolling_high - rolling_low
        
        # Post High, Post Low trong 'mfe_hours' giờ TIẾP THEO (từ t+1 đến t+mfe_hours)
        post_high = h1_df['HIGH'].rolling(window=mfe_hours).max().shift(-mfe_hours)
        post_low  = h1_df['LOW'].rolling(window=mfe_hours).min().shift(-mfe_hours)
        
        # Tính Maximum Favorable Excursion (MFE cực đại) nếu Breakout
        mfe_up   = post_high - rolling_high
        mfe_down = rolling_low - post_low
        
        # Chỉ lấy giá trị lớn hơn 0 (thực sự có phá hộp)
        mfe_up = mfe_up.clip(lower=0)
        mfe_down = mfe_down.clip(lower=0)
        
        # Lấy MFE của hướng biến động mạnh hơn (kịch bản Breakout 1 hướng tốt nhất)
        max_mfe = pd.DataFrame({'UP': mfe_up, 'DOWN': mfe_down}).max(axis=1)
        
        # Reward/Risk Ratio = Post MFE / Box Size
        # Tránh chia cho 0
        valid_range = rolling_range.replace(0, np.nan)
        ratio = max_mfe / valid_range
        
        temp = pd.DataFrame({
            'Box_Size': rolling_range,
            'Max_MFE': max_mfe,
            'Ratio': ratio
        })
        
        # Ở pandas resample('1h'), index là thời gian bắt đầu của nến H1
        # Do đó nhãn của rolling (tại dòng k) là thời gian của nến H1 cuối cùng trong chuỗi.
        temp['End_Hour'] = (temp.index.hour + 1) % 24
        temp['Start_Hour'] = (temp.index.hour - length + 1) % 24
        
        grouped = temp.groupby(['Start_Hour', 'End_Hour']).agg({
            'Box_Size': 'mean',
            'Max_MFE': 'mean',
            'Ratio': 'mean'
        }).reset_index()
        
        for _, row in grouped.iterrows():
            windows.append({
                'Khung_Gio': f"{int(row['Start_Hour']):02}h - {int(row['End_Hour']):02}h",
                'Length': length,
                'MFE_Hours': mfe_hours,
                'Box_Size_TB': row['Box_Size'],
                'MFE_TB': row['Max_MFE'],
                'Ratio_TB': row['Ratio']
            })

df_windows = pd.DataFrame(windows)

for length in [4, 6, 8]:
    print(f"\n--- ĐÁNH GIÁ KHUNG TÍCH LŨY {length} TIẾNG ---")
    data_len = df_windows[df_windows['Length'] == length]
    
    # Đánh giá xem gồng bao nhiêu tiếng thì Tỉ lệ RR bung mạnh nhất
    best_mfe_hour = data_len.groupby('MFE_Hours')['Ratio_TB'].mean().idxmax()
    print(f"-> Khuyến nghị gồng lệnh: {best_mfe_hour} giờ sau Breakout (cho MFE trung bình tối ưu nhất)")
    
    data_mfe = data_len[data_len['MFE_Hours'] == best_mfe_hour]
    
    # 1. Đo theo Min Range
    min_range = data_mfe.sort_values(by='Box_Size_TB').head(3)
    print(f"1. Min Range (Hộp hẹp - Rủi ro: Breakout có thể đi ngang vì thiếu thanh khoản):")
    for _, r in min_range.iterrows():
        print(f"   ► {r['Khung_Gio']} | Cỡ Hộp: {r['Box_Size_TB']:.2f} giá | MFE sau đó {best_mfe_hour}h: {r['MFE_TB']:.2f} giá | Tỉ lệ R:R = {r['Ratio_TB']:.2f}")

    # 2. Đo theo Effective Range
    effective_range = data_mfe.sort_values(by='Ratio_TB', ascending=False).head(3)
    print(f"2. EFFECTIVE RANGE (Khung bùng nổ xịn nhất - Khuyên dùng để cài EA):")
    for _, r in effective_range.iterrows():
        print(f"   ► {r['Khung_Gio']} | Cỡ Hộp: {r['Box_Size_TB']:.2f} giá | MFE sau đó {best_mfe_hour}h: {r['MFE_TB']:.2f} giá | Tỉ lệ R:R = {r['Ratio_TB']:.2f}")

print("\n===== PHÂN TÍCH ĐIỂM CAO NHẤT VÀ THẤP NHẤT TRONG NGÀY =====")
df['Date'] = df['Datetime'].dt.date

daily_highs = df.loc[df.groupby('Date')['HIGH'].idxmax()].copy()
daily_lows = df.loc[df.groupby('Date')['LOW'].idxmin()].copy()

# Gộp theo chu kỳ 30 phút để tránh loãng dữ liệu (thay vì xem từng phút lẻ)
daily_highs['Time30'] = daily_highs['Datetime'].dt.floor('30min').dt.strftime('%H:%M')
daily_lows['Time30'] = daily_lows['Datetime'].dt.floor('30min').dt.strftime('%H:%M')

print("1. Đỉnh (High) trong ngày thường rơi vào các chu kỳ 30 phút nào (Top 5):")
print(daily_highs['Time30'].value_counts().head(5))

print("\n2. Đáy (Low) trong ngày thường rơi vào các chu kỳ 30 phút nào (Top 5):")
print(daily_lows['Time30'].value_counts().head(5))

print("\n=========================================================")
print("===== MÔ PHỎNG CHIẾN LƯỢC RANGE BREAKOUT RENE =====")
import datetime

# Các tham số mô phỏng (Có thể thay đổi cho khớp với EA)
range_start_hour = 0
range_start_minute = 0
range_end_hour = 7
range_end_minute = 30

start_time = datetime.time(range_start_hour, range_start_minute)
end_time = datetime.time(range_end_hour, range_end_minute)

df['TimeObj'] = df['Datetime'].dt.time

if start_time < end_time:
    in_range = (df['TimeObj'] >= start_time) & (df['TimeObj'] < end_time)
else:
    in_range = (df['TimeObj'] >= start_time) | (df['TimeObj'] < end_time)

df_range = df[in_range].copy()

# Nhóm theo ngày để tìm High, Low của toàn bộ Box 
box_stats = df_range.groupby('Date').agg(
    Box_High=('HIGH', 'max'),
    Box_Low=('LOW', 'min')
).reset_index()

box_stats['Box_Size'] = box_stats['Box_High'] - box_stats['Box_Low']

print(f"\n1. Kích thước Range Box tổng thể (Từ {start_time.strftime('%H:%M')} đến {end_time.strftime('%H:%M')}):")
print(f"- Số ngày thống kê: {len(box_stats)}")
print(f"- Box Size Trung bình: {box_stats['Box_Size'].mean():.2f} giá")
print(f"- Box Size Nhỏ nhất (Min): {box_stats['Box_Size'].min():.2f} giá")
print(f"- Box Size Lớn nhất (Max): {box_stats['Box_Size'].max():.2f} giá")
print(f"- Box Size Trung vị (Median): {box_stats['Box_Size'].median():.2f} giá")

# ---- FIX ĐƠN VỊ: XAUUSD: 1 giá = 100 point (point = 0.01) ----
POINTS_PER_PRICE = 100
quantiles = box_stats['Box_Size'].quantile([0.1, 0.25, 0.5, 0.75, 0.9])
print(f"\n- Phân phối Box Size (đơn vị: giá XAUUSD):")
print(f"  P10={quantiles[0.1]:.2f} | P25={quantiles[0.25]:.2f} | Median={quantiles[0.5]:.2f} | P75={quantiles[0.75]:.2f} | P90={quantiles[0.9]:.2f}")
print(f"\n- Gợi ý cài đặt InpMin/MaxRangePoints (loại bỏ 10% ngày hộp quá bé hoặc quá lớn):")
print(f"  + InpMinRangePoints >= {quantiles[0.1]*POINTS_PER_PRICE:.0f}  (= {quantiles[0.1]:.2f} giá)")
print(f"  + InpMaxRangePoints <= {quantiles[0.9]*POINTS_PER_PRICE:.0f}  (= {quantiles[0.9]:.2f} giá)")

# ---- PHÂN TÍCH SAU BREAKOUT ----
print("\n2. Thống kê hành vi giá SAU KHI Breakout (Time-Series Simulation):")
post_range = (~in_range) & (df['TimeObj'] >= end_time)
df_post = df[post_range].copy()

results = []
# Lặp qua từng ngày để mô phỏng Time-Series thứ tự MFE/MAE
for index, row in box_stats.iterrows():
    day_date = row['Date']
    box_high = row['Box_High']
    box_low = row['Box_Low']
    box_size = row['Box_Size']
    
    day_df = df_post[df_post['Date'] == day_date].sort_values('Datetime')
    
    buy_triggered = False
    sell_triggered = False
    
    buy_mfe = 0
    buy_mae = 0
    buy_sl_hit = False
    
    sell_mfe = 0
    sell_mae = 0
    sell_sl_hit = False
    
    # Lưu P/L theo từng giờ (để tìm giờ đóng lệnh tốt nhất)
    buy_hourly = {}
    sell_hourly = {}
    
    for _, candle in day_df.iterrows():
        hour = candle['Datetime'].hour
        high = candle['HIGH']
        low = candle['LOW']
        close = candle['CLOSE']
        
        # --- BUY LOGIC ---
        if not buy_triggered:
            if high > box_high: # Breakout UP
                buy_triggered = True
                buy_mfe = max(0, high - box_high)
                buy_mae = max(0, box_high - low)
                if low <= box_low:
                    buy_sl_hit = True
        else:
            if not buy_sl_hit: # Chỉ cập nhật MFE nếu CHƯA chạm đáy hộp (chưa chạm SL)
                buy_mfe = max(buy_mfe, high - box_high)
                buy_mae = max(buy_mae, box_high - low)
                if low <= box_low:
                    buy_sl_hit = True
                
        # Ghi lại diễn biến Profit/Loss cho BUY
        if buy_triggered:
            if hour not in buy_hourly:
                buy_hourly[hour] = []
            if buy_sl_hit:
                buy_hourly[hour].append(-box_size) # Đã dính SL (fix cứng mất 1 box size)
            else:
                buy_hourly[hour].append(close - box_high) # Đang thả nổi
                
        # --- SELL LOGIC ---
        if not sell_triggered:
            if low < box_low: # Breakout DOWN
                sell_triggered = True
                sell_mfe = max(0, box_low - low)
                sell_mae = max(0, high - box_low)
                if high >= box_high:
                    sell_sl_hit = True
        else:
            if not sell_sl_hit:
                sell_mfe = max(sell_mfe, box_low - low)
                sell_mae = max(sell_mae, high - box_low)
                if high >= box_high:
                    sell_sl_hit = True
                    
        # Ghi lại diễn biến Profit/Loss cho SELL
        if sell_triggered:
            if hour not in sell_hourly:
                sell_hourly[hour] = []
            if sell_sl_hit:
                sell_hourly[hour].append(-box_size)
            else:
                sell_hourly[hour].append(box_low - close)

    # Tính mean P/L của giờ đó trong ngày
    buy_hr_mean = {h: np.mean(vals) for h, vals in buy_hourly.items()}
    sell_hr_mean = {h: np.mean(vals) for h, vals in sell_hourly.items()}

    results.append({
        'Date': day_date,
        'Box_High': box_high,
        'Box_Low': box_low,
        'Box_Size': box_size,
        'Breakout_Up': buy_triggered,
        'MFE_Up': buy_mfe,
        'MAE_Buy': buy_mae,
        'Buy_SL_Hit': buy_sl_hit,
        'Buy_Hour_Profits': buy_hr_mean,
        
        'Breakout_Down': sell_triggered,
        'MFE_Down': sell_mfe,
        'MAE_Sell': sell_mae,
        'Sell_SL_Hit': sell_sl_hit,
        'Sell_Hour_Profits': sell_hr_mean
    })

sim_df = pd.DataFrame(results)

total_days      = len(sim_df)
days_break_up   = sim_df['Breakout_Up'].sum()
days_break_down = sim_df['Breakout_Down'].sum()
days_break_both = (sim_df['Breakout_Up'] & sim_df['Breakout_Down']).sum()

print(f"- Số ngày giá phá vỡ cạnh TRÊN (Kích hoạt Buy):  {days_break_up}/{total_days} ngày ({days_break_up/total_days*100:.1f}%)")
print(f"- Số ngày giá phá vỡ cạnh DƯỚI (Kích hoạt Sell): {days_break_down}/{total_days} ngày ({days_break_down/total_days*100:.1f}%)")
print(f"- CẢNH BÁO: Giá quét CẢ HAI đầu trong cùng 1 ngày: {days_break_both}/{total_days} ngày ({days_break_both/total_days*100:.1f}%)")

print("\n3. MFE (Maximum Favorable Excursion) TRƯỚC KHI CHẠM SL — Gợi ý InpTargetValue:")
mfe_up   = sim_df.loc[sim_df['Breakout_Up'],   'MFE_Up']
mfe_down = sim_df.loc[sim_df['Breakout_Down'], 'MFE_Down']
print(f"- BUY:  TB={mfe_up.mean():.2f}  | Median={mfe_up.median():.2f}  | Max={mfe_up.max():.2f} giá")
print(f"- SELL: TB={mfe_down.mean():.2f} | Median={mfe_down.median():.2f} | Max={mfe_down.max():.2f} giá")
print(f"  → Nếu dùng TARGET_POINTS, gợi ý TP ~{mfe_up.median()*POINTS_PER_PRICE:.0f} pts (Buy) / ~{mfe_down.median()*POINTS_PER_PRICE:.0f} pts (Sell)")

print("\n4. MAE (Maximum Adverse Excursion) — Ước lượng rủi ro chạm SL:")
# MAE cho thấy giá đi ngược bao xa so với điểm vào
buy_sl_hit = sim_df['Buy_SL_Hit'].sum()
sell_sl_hit = sim_df['Sell_SL_Hit'].sum()
days_buy = days_break_up if days_break_up > 0 else 1
days_sell = days_break_down if days_break_down > 0 else 1

print(f"- Ngày BUY kích hoạt: giá sập ngược lại chạm đáy Box = {buy_sl_hit}/{days_break_up} ngày ({buy_sl_hit/days_buy*100:.1f}%) → Tỉ lệ tạch kèo Buy (nếu để SL = STOP_OFF)")
print(f"- Ngày SELL kích hoạt: giá vọt ngược lại chạm đỉnh Box = {sell_sl_hit}/{days_break_down} ngày ({sell_sl_hit/days_sell*100:.1f}%) → Tỉ lệ tạch kèo Sell (nếu để SL = STOP_OFF)")

print(f"\n- Phân phối MAE (Độ trượt ngược của giá tính bằng Giá XAUUSD, MAE lớn là rủi ro cao):")
mae_buy_vals = sim_df.loc[sim_df['Breakout_Up'], 'MAE_Buy']
print(f"  Ngày BUY: P25={mae_buy_vals.quantile(0.25):.2f} | Median={mae_buy_vals.median():.2f} | P75={mae_buy_vals.quantile(0.75):.2f} | Max={mae_buy_vals.max():.2f}")
print(f"  → Gợi ý SL Factor (STOP_FACTOR): Nếu cài < 1.0 sẽ rất hay bị cắn SL sớm do râu nến nhiễu, khuyến cáo 1.0 ~ 1.5")

print("\n5. Giờ đóng lệnh tốt nhất (InpCloseLongHour / InpCloseShortHour):")
print("   Trung bình Profit (Giá) tại từng khung giờ nếu vẫn GỒNG lệnh đang mở:")

buy_hourly_agg = {}
sell_hourly_agg = {}

for _, row in sim_df.iterrows():
    if row['Breakout_Up']:
        for h, v in row['Buy_Hour_Profits'].items():
            if h not in buy_hourly_agg: buy_hourly_agg[h] = []
            buy_hourly_agg[h].append(v)
            
    if row['Breakout_Down']:
        for h, v in row['Sell_Hour_Profits'].items():
            if h not in sell_hourly_agg: sell_hourly_agg[h] = []
            sell_hourly_agg[h].append(v)

buy_hourly_res = {h: np.mean(vals) for h, vals in sorted(buy_hourly_agg.items())}
sell_hourly_res = {h: np.mean(vals) for h, vals in sorted(sell_hourly_agg.items())}

# Định dạng in để dễ nhìn (chia theo 4 cột/hàng hoặc cuộn)
buy_str = " | ".join([f"{h:02d}h: {m_val:+.2f}" for h, m_val in buy_hourly_res.items()])
sell_str = " | ".join([f"{h:02d}h: {m_val:+.2f}" for h, m_val in sell_hourly_res.items()])

import textwrap
print("\n- Lợi nhuận gồng (giá) tại từng giờ nếu BUY (đã trừ hạch toán các ngày bị cắn SL):")
for line in textwrap.wrap(buy_str, width=80): print(f"  {line}")

print("\n- Lợi nhuận gồng (giá) tại từng giờ nếu SELL (đã trừ hạch toán các ngày bị cắn SL):")
for line in textwrap.wrap(sell_str, width=80): print(f"  {line}")

if buy_hourly_res:
    best_buy_h = max(buy_hourly_res, key=buy_hourly_res.get)
    print(f"\n  → Gợi ý InpCloseLongHour  = {best_buy_h:02d}:00")

if sell_hourly_res:
    best_sell_h = max(sell_hourly_res, key=sell_hourly_res.get)
    print(f"  → Gợi ý InpCloseShortHour = {best_sell_h:02d}:00")

print("\n=========================================================")
