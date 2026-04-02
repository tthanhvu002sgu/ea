import pandas as pd
import numpy as np

# Đọc file dữ liệu
file_path = 'XAUUSD_M1_202512172012_202604021536.csv'
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
df['Hour'] = df['Datetime'].dt.hour
df['Range'] = df['HIGH'] - df['LOW']

print("===== PHÂN TÍCH HỒ SƠ BIẾN ĐỘNG THEO GIỜ =====")
# Trung bình biến động mỗi giờ
hourly_vol = df.groupby('Hour')['Range'].mean().reset_index()
print("1. Trung bình (High - Low) cho từng giờ:")
print(hourly_vol.to_string(index=False))

# Sắp xếp các giờ có biến động thấp nhất lên đầu
hourly_vol_sorted = hourly_vol.sort_values(by='Range').reset_index(drop=True)
print("\n2. Xếp hạng 10 giờ có biến động THẤP NHẤT:")
print(hourly_vol_sorted.head(10).to_string(index=False))

# Gợi ý một số khung giờ (windows) mở rộng ghép từ nhiều giờ để có range thấp nhất
print("\n3. Các cụm giờ có biến động trung bình thấp (Ví dụ tìm khoảng thời gian từ A đến B):")
# Tính cho các chu kỳ dài 2h đến 10h
windows = []
for length in range(2, 11):
    for start in range(24):
        end = (start + length - 1) % 24
        # Tính trung bình range của các giờ trong cửa sổ này
        if start <= end:
            window_vol = hourly_vol['Range'].iloc[start:end+1].mean()
        else:
            window_vol = pd.concat([hourly_vol['Range'].iloc[start:], hourly_vol['Range'].iloc[:end+1]]).mean()
        
        windows.append({
            'Khung Giờ': f"{start:02}h - {(end+1)%24:02}h",
            'Độ dài (giờ)': length,
            'Biến động TB': window_vol
        })

df_windows = pd.DataFrame(windows)
# Lấy top 5 khung giờ biến động thấp nhất cho các độ dài từ 4 đến 8 giờ
for length in [4, 6, 8]:
    print(f"\n- Top 3 khung {length} tiếng ít biến động nhất:")
    top_w = df_windows[df_windows['Độ dài (giờ)'] == length].sort_values(by='Biến động TB').head(3)
    print(top_w[['Khung Giờ', 'Biến động TB']].to_string(index=False))


print("\n===== PHÂN TÍCH ĐIỂM CAO NHẤT VÀ THẤP NHẤT TRONG NGÀY =====")
df['Date'] = df['Datetime'].dt.date
df['TimeStr'] = df['Datetime'].dt.strftime('%H:%M')

daily_highs = df.loc[df.groupby('Date')['HIGH'].idxmax()]
daily_lows = df.loc[df.groupby('Date')['LOW'].idxmin()]

print("1. Khung giờ thường tạo Đỉnh (High) hàng ngày (Top 10 tần suất cao nhất):")
print(daily_highs['TimeStr'].value_counts().head(10))

print("\n2. Khung giờ thường tạo Đáy (Low) hàng ngày (Top 10 tần suất cao nhất):")
print(daily_lows['TimeStr'].value_counts().head(10))

print("\n(Thống kê dựa trên nhóm theo block 15 phút để thấy rõ cụm)")
daily_highs['Time15'] = daily_highs['Datetime'].dt.floor('15min').dt.strftime('%H:%M')
daily_lows['Time15'] = daily_lows['Datetime'].dt.floor('15min').dt.strftime('%H:%M')

print("\n- Đỉnh thường rơi vào chu kỳ 15 phút (Top 5):")
print(daily_highs['Time15'].value_counts().head(5))

print("\n- Đáy thường rơi vào chu kỳ 15 phút (Top 5):")
print(daily_lows['Time15'].value_counts().head(5))
