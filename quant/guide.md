# 🚀 HƯỚNG DẪN SỬ DỤNG NHANH

## 📥 Cài đặt

```bash
# Cài đặt thư viện cần thiết
pip install pandas numpy --break-system-packages
```

## 🎯 Cách dùng cơ bản

### Bước 1: Chuẩn bị file CSV

Export dữ liệu từ MT4/MT5 theo format:
- Timeframe: M1, M5, M15, H1, H4, D1...
- Columns: DATE, TIME, OPEN, HIGH, LOW, CLOSE, TICKVOL

### Bước 2: Chạy phân tích

```bash
# Cách 1: Quick Start (Khuyến nghị cho người mới)
python quick_start.py EURUSD_M15.csv

# Cách 2: Full Analysis
python pattern_analyzer.py EURUSD_M15.csv

# Cách 3: Custom Strategies
python custom_strategy_test.py EURUSD_M15.csv
```

### Bước 3: Xem kết quả

Mở file JSON được tạo ra:
- `EURUSD_M15_analysis.json` - Kết quả đầy đủ
- Xem console để thấy Top 10 strategies

## 📊 Các quy luật được test

✅ **10 nhóm quy luật chính:**

1. **Chuỗi nến liên tiếp** (2-7 nến)
2. **Candlestick patterns** (Hammer, Engulfing, Pin Bar...)
3. **RSI extremes** (Overbought/Oversold)
4. **Breakout** (Đột phá high/low)
5. **Session analysis** (Asian/London/NY)
6. **Trend following** (MA crossover)
7. **Mean reversion** (Bollinger Bands)
8. **Support/Resistance** (Swing points)
9. **Volume analysis** (High volume signals)
10. **Combined strategies** (Kết hợp nhiều yếu tố)

## 🏆 Kết quả mẫu (EUR/USD M15)

### TOP 3 Chiến lược tốt nhất:

| Chiến lược | Win Rate | Avg Profit | Profit Factor |
|------------|----------|------------|---------------|
| Buy Swing Low | 57.3% | 2.28 pips | 1.56 |
| Sell Swing High | 55.0% | 1.80 pips | 1.41 |
| Reversal 6 nến giảm | 55.8% | 1.24 pips | 1.38 |

### Insights chính:

✅ **Hoạt động tốt:**
- Support/Resistance (Swing points)
- Mean Reversion (RSI + BB)
- Reversal sau 5+ nến liên tiếp

❌ **Hoạt động kém:**
- Breakout đơn thuần
- Candlestick patterns riêng lẻ
- Volume signals đơn thuần

## 🔧 Tùy chỉnh chiến lược

### Ví dụ: Test chiến lược của bạn

```python
from pattern_analyzer import PriceActionAnalyzer

# Load data
analyzer = PriceActionAnalyzer('EURUSD_M15.csv')
analyzer.load_data()
analyzer.calculate_indicators()

df = analyzer.df

# Tạo điều kiện entry
condition = (
    (df['CLOSE'] > df['sma_20']) &      # Uptrend
    (df['rsi'] < 40) &                  # RSI pullback
    (df['hammer'] | df['bullish_engulfing'])  # Reversal pattern
)

# Test
result = analyzer.test_strategy(
    entry_condition=condition,
    direction='long',
    hold_candles=10,
    stop_loss_pips=15,
    take_profit_pips=30
)

# Xem kết quả
print(f"Win Rate: {result['win_rate']:.1f}%")
print(f"Profit Factor: {result['profit_factor']:.2f}")
print(f"Total Profit: {result['total_profit']:.1f} pips")
```

## 📈 Chỉ số đánh giá

- **Win Rate**: Tỷ lệ thắng (> 50% = tốt)
- **Profit Factor**: Lợi nhuận/Lỗ (> 1.5 = rất tốt)
- **Total Profit**: Tổng lợi nhuận tích lũy
- **Avg Profit**: Lợi nhuận trung bình mỗi trade
- **Sharpe Ratio**: Lợi nhuận/Rủi ro (> 1.0 = tốt)

## 💡 Tips quan trọng

### 1. Đọc hiểu kết quả
- Win rate cao không đủ → Cần profit factor > 1
- Nhiều trades (>100) mới đáng tin
- Total profit cho biết tích lũy dài hạn

### 2. Tránh overfitting
- Đừng tối ưu hóa quá nhiều parameters
- Test trên nhiều cặp tiền khác nhau
- Test trên nhiều khung thời gian

### 3. Forward testing
- Backtest ≠ Forward test
- Chạy demo ít nhất 1-2 tháng
- Theo dõi drawdown thực tế

### 4. Risk Management
- Luôn dùng Stop Loss
- Position sizing: 1-2% account mỗi trade
- Tính cả spread và slippage

## 🎓 Học từ kết quả

### Phát hiện từ EUR/USD M15:

1. **Thị trường mean reverting**
   - Hurst exponent = 0.49
   - → Chiến lược reversal tốt hơn trend following

2. **Phiên giao dịch quan trọng**
   - New York: Volatility cao (8.5 pips)
   - Asian: Volatility thấp (4.4 pips)
   - → Trade theo phiên phù hợp

3. **Patterns đơn lẻ không đủ**
   - Win rate ~50% cho tất cả patterns
   - → Phải kết hợp nhiều yếu tố

4. **Support/Resistance mạnh nhất**
   - Swing low/high: 55-57% win rate
   - → Focus vào S/R quan trọng

## 📚 File structure

```
.
├── pattern_analyzer.py          # Script chính
├── custom_strategy_test.py      # Test chiến lược tùy chỉnh
├── quick_start.py               # Quick start
├── README.md                    # Tài liệu đầy đủ
├── HUONG_DAN.md                 # File này
└── example_analysis.json        # Ví dụ kết quả
```

## ❓ FAQ

### Q: Mất bao lâu để chạy?
A: 1-2 phút cho 50k nến (tùy máy)

### Q: File CSV cần format gì?
A: MT4/MT5 standard export, tab-separated

### Q: Có thể test nhiều cặp tiền?
A: Có, chạy từng file CSV riêng

### Q: Kết quả có đáng tin?
A: Backtest chỉ là bước đầu, cần forward test

### Q: Làm sao biết chiến lược tốt?
A: Win rate > 52%, Profit Factor > 1.3, Trades > 100

### Q: Code có thể sửa?
A: Có, hoàn toàn open source

## 🔗 Liên hệ & Support

- Đọc kỹ README.md để hiểu sâu hơn
- Xem example_analysis.json để thấy output mẫu
- Thử custom_strategy_test.py để học cách tùy chỉnh

## ⚠️ Disclaimer

**Công cụ này chỉ phục vụ nghiên cứu, KHÔNG phải lời khuyên đầu tư.**

- Giao dịch Forex có rủi ro cao
- Có thể mất toàn bộ vốn
- Quá khứ không đảm bảo tương lai
- Luôn test demo trước khi real
- Chỉ trade với tiền bạn có thể mất

---

**Good luck & Trade safe! 🚀**