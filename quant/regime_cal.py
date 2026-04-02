import pandas as pd
import numpy as np
import argparse
import os

# ==========================================
# 1. TÍNH TOÁN CORE METRICS
# ==========================================
def calculate_r_score_normalized(df, n=20):
    """
    FIX #1: Chuẩn hóa công thức R-Score.
    Công thức cũ: Momentum / ATR -> Giá trị quá lớn, dễ chạm ngưỡng.
    Công thức mới: Momentum / (ATR * sqrt(N)) -> Giá trị chuẩn Z-Score.
    """
    # Calculate True Range
    df['h-l'] = df['high'] - df['low']
    df['h-pc'] = abs(df['high'] - df['close'].shift(1))
    df['l-pc'] = abs(df['low'] - df['close'].shift(1))
    df['tr'] = df[['h-l', 'h-pc', 'l-pc']].max(axis=1)
    
    # ATR
    df['atr'] = df['tr'].rolling(window=n).mean()
    
    # Momentum
    df['momentum'] = df['close'] - df['close'].shift(n)
    
    # R-Score Normalized
    # Thêm np.sqrt(n) để scale giá trị về dải [-3, 3] chuẩn tắc
    df['r_score_raw'] = df['momentum'] / (df['atr'] * np.sqrt(n))
    
    return df

def apply_smoothing(df, smooth_n=5):
    """
    FIX #2: Tăng Smoothing mặc định lên 5 để loại bỏ nhiễu tốt hơn.
    """
    df['r_score'] = df['r_score_raw'].rolling(window=smooth_n).mean()
    return df

# ==========================================
# 2. PHÂN LOẠI REGIME (HYSTERESIS)
# ==========================================
def classify_regime_hysteresis(df):
    regimes = []
    current_state = 'Neutral'
    
    # Ngưỡng (Thresholds) - Dựa trên Z-Score chuẩn
    TH_BULL_ENTER = 1.0   # Cần 1 Sigma để xác nhận Trend
    TH_BULL_EXIT = 0.5    # Cho phép hồi về 0.5 Sigma vẫn coi là Trend
    TH_BEAR_ENTER = -1.0
    TH_BEAR_EXIT = -0.5
    
    # Ngưỡng Strong (Chỉ để hiển thị, không dùng để cắt Duration)
    TH_STRONG_BULL = 2.0
    TH_STRONG_BEAR = -2.0
    
    for r in df['r_score']:
        if pd.isna(r):
            regimes.append(None)
            continue
            
        # --- Logic Hysteresis ---
        if current_state == 'Neutral':
            if r > TH_BULL_ENTER:
                current_state = 'Bull'
            elif r < TH_BEAR_ENTER:
                current_state = 'Bear'
        
        elif current_state == 'Bull':
            if r < TH_BULL_EXIT:
                current_state = 'Neutral'
            # (Vẫn giữ là Bull nếu r >= 0.5)
                
        elif current_state == 'Bear':
            if r > TH_BEAR_EXIT:
                current_state = 'Neutral'
            # (Vẫn giữ là Bear nếu r <= -0.5)
        
        # --- Gán nhãn chi tiết (Sub-classification) ---
        # Lưu ý: Việc này chỉ để hiển thị độ mạnh, 
        # nhưng khi tính Duration ta sẽ gộp lại.
        final_label = current_state
        if current_state == 'Bull' and r > TH_STRONG_BULL:
            final_label = 'Strong Bull'
        elif current_state == 'Bear' and r < TH_STRONG_BEAR:
            final_label = 'Strong Bear'
            
        regimes.append(final_label)
        
    return regimes

# ==========================================
# 3. THỐNG KÊ DURATION (FIX QUAN TRỌNG)
# ==========================================
def analyze_regime_duration(df):
    """
    FIX #3: Gộp các Regime con lại trước khi đếm.
    'Strong Bull' và 'Bull' được coi là MỘT xu hướng liên tục.
    Chúng ta không muốn Reset bộ đếm khi giá chuyển từ Bull sang Strong Bull.
    """
    # Tạo cột Simplified Regime
    df['simple_regime'] = df['regime'].replace({
        'Strong Bull': 'Bull',
        'Strong Bear': 'Bear'
    })
    
    # Đếm Duration dựa trên SIMPLE REGIME
    df['regime_group'] = (df['simple_regime'] != df['simple_regime'].shift()).cumsum()
    
    durations = df.groupby(['regime_group', 'simple_regime']).size().reset_index(name='duration_bars')
    
    # Thống kê
    stats = durations.groupby('simple_regime')['duration_bars'].agg(
        Count='count',
        Mean='mean',
        Median='median',
        Max='max',
        Min='min'
    )
    
    return stats

def calculate_sampling_rate(stats):
    valid_medians = stats['Median'].dropna()
    if valid_medians.empty: return 0
    
    # Lấy Median thấp nhất làm chuẩn an toàn
    min_median = valid_medians.min()
    
    # Quarter Rule
    sampling_rate = min_median / 4.0
    return sampling_rate

# ==========================================
# MAIN EXECUTION
# ==========================================
if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument('--file', type=str, required=True)
    parser.add_argument('--n', type=int, default=20)
    parser.add_argument('--smooth', type=int, default=5) # Tăng default smooth
    args = parser.parse_args()

    # Load Data (Giữ nguyên logic load của bạn)
    try:
        df = pd.read_csv(args.file, sep=None, engine='python')
        df.columns = df.columns.str.lower().str.strip().str.replace('<', '').str.replace('>', '')
        
        print(f"Loading {args.file} | N={args.n} | Smooth={args.smooth}")
        
        # 1. Calculate
        df = calculate_r_score_normalized(df, n=args.n)
        df = apply_smoothing(df, smooth_n=args.smooth)
        df.dropna(inplace=True)
        
        # 2. Classify
        df['regime'] = classify_regime_hysteresis(df)
        
        # 3. Analyze
        stats = analyze_regime_duration(df)
        
        print("\n" + "="*50)
        print("📊 REGIME DURATION (Merged Strong/Normal)")
        print("="*50)
        print(stats.to_string())
        
        # 4. Result
        rate = calculate_sampling_rate(stats)
        
        print("\n" + "-"*50)
        print(f"💡 RECOMMENDATION:")
        print(f"   Min Median Duration: {stats['Median'].min()} bars")
        print(f"   => SAMPLING RATE: Every {max(1, int(rate))} Bars")
        print("-"*50)

    except Exception as e:
        print(f"Error: {e}")