# 📐 The Fractal Cone [Advanced Probability]

## Hướng Dẫn Sử Dụng Chi Tiết

> **Phiên bản**: 1.0  
> **Ngày cập nhật**: 2026-02-24  
> **Nền tảng**: TradingView (PineScript v5)

---

## 📋 Mục Lục

1. [Tổng Quan](#1-tổng-quan)
2. [Tại Sao Cần Chỉ Báo Này?](#2-tại-sao-cần-chỉ-báo-này)
3. [Cơ Sở Toán Học](#3-cơ-sở-toán-học)
4. [Cài Đặt & Cấu Hình](#4-cài-đặt--cấu-hình)
5. [Cách Đọc Chỉ Báo](#5-cách-đọc-chỉ-báo)
6. [Chiến Lược Áp Dụng Thực Tế](#6-chiến-lược-áp-dụng-thực-tế)
7. [Ví Dụ Cụ Thể](#7-ví-dụ-cụ-thể)
8. [FAQ - Câu Hỏi Thường Gặp](#8-faq---câu-hỏi-thường-gặp)
9. [Hạn Chế & Lưu Ý](#9-hạn-chế--lưu-ý)
10. [Bảng Tham Khảo Nhanh](#10-bảng-tham-khảo-nhanh)

---

## 1. Tổng Quan

### Chỉ báo này là gì?

**The Fractal Cone** là một chỉ báo xác suất tiên tiến, vẽ một **"phễu" (cone)** mở rộng từ giá hiện tại vào tương lai. Nó dự đoán **vùng giá có xác suất cao** mà giá sẽ nằm trong đó sau N nến nữa.

### Trực quan hóa

```
                                    ╱  ← Biên trên (Kháng cự xác suất)
                                  ╱
                               ╱
     Giá hiện tại →  ●------╱--------  ← Đường trung tâm (Mean Path)
                              ╲
                                ╲
                                  ╲  ← Biên dưới (Hỗ trợ xác suất)

     ← Hiện tại                 Tương lai →
     (Chắc chắn)               (Bất định cao)
```

### Điểm khác biệt so với Support/Resistance truyền thống

| Phương pháp truyền thống | The Fractal Cone |
|---------------------------|------------------|
| Vẽ đường ngang cố định (Static) | Vẽ phễu mở rộng theo thời gian |
| Không xét biến động hiện tại | Tự điều chỉnh theo Volatility |
| Không phân biệt Trending/Ranging | Tự nhận diện chế độ thị trường |
| Giả định phân phối chuẩn | Điều chỉnh cho Đuôi béo (Fat Tails) |

---

## 2. Tại Sao Cần Chỉ Báo Này?

### ❌ Nỗi Đau Khi KHÔNG Có Công Cụ Xác Suất

1. **Đặt TP hoang đường**: Kỳ vọng XAUUSD tăng 50 pip trong 5 phút khi volatility chỉ cho phép 15 pip/5min.
2. **SL quá chật**: Đặt SL 5 pip trong khi biến động trung bình 1 nến là 10 pip → bị quét SL liên tục.
3. **Không biết thời gian chờ**: "TP 100 pip liệu có đạt trong 1 giờ hay cần 1 ngày?"
4. **Bỏ qua chế độ thị trường**: Dùng cùng TP/SL cho cả thị trường đang trending lẫn sideway.

### ✅ Chỉ Báo Này Giải Quyết Bằng Cách

- Cho biết **vùng giá hợp lý** mà giá có thể đạt trong N nến tới.
- Tự động **co/giãn** theo biến động thực tế.
- Phân biệt **xu hướng vs dao động** để dự phóng chính xác hơn.
- Cảnh báo khi kỳ vọng TP nằm ngoài vùng xác suất cao.

---

## 3. Cơ Sở Toán Học

### 3.1 Kiến Trúc 4 Tầng

Chỉ báo kết hợp 4 thành phần toán học:

```
┌─────────────────────────────────────────────┐
│           CONE WIDTH (Độ rộng phễu)         │
│                                              │
│    Width = Z_adj × σ_ewma × t^H             │
│                                              │
│  ┌─────────┐  ┌─────────┐  ┌────────────┐  │
│  │Kurtosis │  │  EWMA   │  │   Hurst    │  │
│  │→ Z_adj  │  │→ σ_ewma │  │→ t^H       │  │
│  │(Đuôi béo)│ │(Biến    │  │(Co/giãn    │  │
│  │         │  │  động)  │  │  thời gian)│  │
│  └────┬────┘  └────┬────┘  └─────┬──────┘  │
│       │            │              │          │
│  ┌────┴────────────┴──────────────┴────┐    │
│  │      MEAN PATH (Đường trung tâm)    │    │
│  │  Trending → Linear Drift            │    │
│  │  Ranging  → Ornstein-Uhlenbeck      │    │
│  └─────────────────────────────────────┘    │
└─────────────────────────────────────────────┘
```

### 3.2 Giải Thích Từng Công Thức

#### A. EWMA Volatility (σ_ewma)
```
σ_ewma = EMA(True Range, len_vol)
```
- **True Range** = max(High-Low, |High-Close[1]|, |Low-Close[1]|)
- **EMA** cho trọng số lớn hơn cho biến động gần đây.
- **Ý nghĩa thực tế**: Nếu 10 nến gần nhất biến động mạnh, nón sẽ mở rộng; nếu thị trường im ắng, nón sẽ thu hẹp.

#### B. Kurtosis → Z-Score Điều Chỉnh
```
K = M₄ / M₂²           (K = 3 cho phân phối chuẩn)
Z_adj = Z_base × (1 + excess_kurtosis × 0.1)
```
- Thị trường tài chính KHÔNG tuân theo phân phối chuẩn → có "đuôi béo" (fat tails).
- Khi Kurtosis > 3 (thường 5-10 cho intraday), Z-score được nới rộng → nón mở rộng thêm.
- **Ý nghĩa**: Trong giai đoạn thị trường "hoang dã" (high kurtosis), vùng 95% sẽ rộng hơn bình thường vì xác suất có sự kiện cực đoan cao hơn.

#### C. Hurst Exponent (H) → Fractal Time Scaling
```
H = log(σ_n / σ_1) / log(n)
time_scaled = t^H
```
- **H = 0.5**: Random Walk → Width tăng theo √t (chuẩn).
- **H > 0.5**: Trending → Width tăng NHANH hơn √t (nón mở rộng nhanh).
- **H < 0.5**: Mean-Reverting → Width tăng CHẬM hơn √t (nón mở rộng chậm).

| Hurst | Ý nghĩa | Nón |
|-------|---------|-----|
| 0.3 | Mạnh mean-reverting | Thu hẹp, giá khó đi xa |
| 0.5 | Random walk | Mở rộng chuẩn |
| 0.7 | Mạnh trending | Mở rộng nhanh, giá có thể đi xa |

#### D. Mean Path (Đường Trung Tâm)

**Khi H > 0.55 (Trending)**:
```
Mean(t) = Price + Drift_rate × t
```
Giá tiếp tục theo hướng hiện tại.

**Khi H ≤ 0.55 (Mean-Reverting)**:
```
Mean(t) = EMA_target + (Price - EMA_target) × e^(-κt)
```
Giá dần quay về EMA (mô hình Ornstein-Uhlenbeck).

---

## 4. Cài Đặt & Cấu Hình

### 4.1 Thêm Vào Chart

1. Mở TradingView → Pine Editor
2. Copy mã nguồn vào Pine Editor
3. Nhấn **"Add to Chart"**
4. Chỉ báo sẽ hiện trực tiếp trên chart (overlay)

### 4.2 Tham Số Đầu Vào

#### Nhóm CỐT LÕI (Core)

| Tham số | Mặc định | Mô tả | Khuyến nghị |
|---------|----------|-------|-------------|
| **Kurtosis Length** | 30 | Số bar để tính kurtosis | 20-50. Ngắn hơn = nhạy hơn |
| **Hurst Length** | 50 | Số bar để tính Hurst exponent | 50-100. Dài hơn = ổn định hơn |
| **EMA Target Length** | 50 | Chu kỳ EMA cho mean-reversion | Phù hợp với phong cách: 20 (ngắn), 50 (trung), 200 (dài) |
| **EWMA Volatility Length** | 10 | Chu kỳ đo biến động | 5-20. Ngắn = nhạy, Dài = mượt |

#### Nhóm DỰ PHÓNG TƯƠNG LAI

| Tham số | Mặc định | Mô tả | Khuyến nghị |
|---------|----------|-------|-------------|
| **Số nến tương lai** | 20 | Dự phóng bao xa | 10-50 tùy khung thời gian |
| **Z-Score Cơ bản** | 2.0 | Mức tin cậy cơ bản (≈95%) | 1.0=68%, 2.0=95%, 3.0=99.7% |

### 4.3 Cấu Hình Theo Khung Thời Gian

| Khung | Kurtosis | Hurst | EMA | Vol Length | Nến tương lai |
|-------|----------|-------|-----|------------|----------------|
| **M5** | 20 | 30 | 20 | 5 | 12 (= 1 giờ) |
| **M15** | 25 | 40 | 30 | 8 | 16 (= 4 giờ) |
| **H1** | 30 | 50 | 50 | 10 | 24 (= 1 ngày) |
| **H4** | 40 | 60 | 50 | 12 | 30 (= 5 ngày) |
| **D1** | 50 | 100 | 50 | 15 | 20 (= 1 tháng) |

---

## 5. Cách Đọc Chỉ Báo

### 5.1 Ba Thành Phần Trên Chart

```
🔴 Đường đỏ (Upper Bound)  → Biên trên xác suất
⚪ Đường xám chấm (Mean)    → Đường trung tâm dự phóng
🟢 Đường xanh lá (Lower)    → Biên dưới xác suất
```

### 5.2 Cách Diễn Giải

#### Kịch bản 1: Nón Mở Rộng Đều Đặn
```
           ╱
        ╱
     ●-----
        ╲
           ╲
```
**Ý nghĩa**: Thị trường đang ở trạng thái Random Walk (H ≈ 0.5).  
**Hành động**: TP/SL framework chuẩn, không thiên lệch.

#### Kịch bản 2: Nón Mở Rộng Nhanh + Mean Path Nghiêng Lên
```
                    ╱╱
                 ╱╱
     ●------╱╱-------
              ╲
               ╲
```
**Ý nghĩa**: Thị trường đang trend mạnh (H > 0.6). Giá có thể đi RẤT XA.  
**Hành động**: TP có thể đặt xa hơn bình thường. SL nên rộng hơn. Trailing stop hiệu quả.

#### Kịch bản 3: Nón Mở Rộng Chậm + Mean Path Cong Về EMA
```
         ╱
     ●---------- ← nón hẹp
         ╲
```
**Ý nghĩa**: Thị trường đang mean-reverting (H < 0.5). Giá bị "kéo" về EMA.  
**Hành động**: TP nên gần, target quanh EMA. SL chặt. Chiến lược reversal hiệu quả.

#### Kịch bản 4: Nón Cực Rộng
```
                          ╱╱╱
                     ╱╱╱
     ●----------╱╱╱------
               ╲╲╲
                    ╲╲╲
```
**Ý nghĩa**: Volatility RẤT CAO + có thể kết hợp fat tails (K > 5).  
**Hành động**: **GIẢM SIZE hoặc KHÔNG GIAO DỊCH**. Rủi ro quá lớn.

---

## 6. Chiến Lược Áp Dụng Thực Tế

### 6.1 Đặt Take Profit Có Cơ Sở

**Nguyên tắc**: TP nên nằm **TRONG** biên trên/dưới của nón.

```
Ví dụ: Bạn muốn Buy
- Giá hiện tại: 2000
- Biên trên sau 10 nến: 2025
- Biên dưới sau 10 nến: 1985

→ TP hợp lý: 2010 - 2020 (nằm trong nón)
→ TP hoang đường: 2050 (nằm ngoài nón xa → sự kiện <5%)
```

**Quy tắc ngón tay cái**:
- TP **bảo thủ**: khoảng 50% khoảng cách từ giá tới biên (tỷ lệ thành công cao).
- TP **trung lập**: khoảng 70-80% khoảng cách tới biên.
- TP **tham vọng**: gần biên → chỉ nên dùng khi Hurst > 0.6.

### 6.2 Đặt Stop Loss Có Cơ Sở

**Nguyên tắc**: SL nên nằm **BÊN NGOÀI** biên ngược hướng.

```
Ví dụ: Bạn muốn Buy
- Biên dưới sau 3 nến: 1992

→ SL hợp lý: 1990 (ngay dưới biên 3-bar)
→ SL quá chật: 1998 (bên trong nón → dễ bị quét)
```

### 6.3 Lọc Tín Hiệu Từ Indicator/EA Khác

Kết hợp với EA Mean Reversion, MACD Cross, hoặc breakout strategy:

```
Bước 1: EA/Indicator cho tín hiệu BUY
Bước 2: Kiểm tra Probability Cone:
   - TP mong muốn có nằm trong biên trên không?
   - Nếu KHÔNG → Giảm TP hoặc bỏ lệnh
   - Nếu CÓ → Tiến hành vào lệnh
```

### 6.4 Đánh Giá Risk/Reward Thực Tế

```
R:R thực tế = (Khoảng cách tới TP) / (Khoảng cách tới SL)

Nhưng nên xét thêm:
R:R xác suất = (TP trong nón?) × (SL ngoài nón?)

Ví dụ:
  TP = +20 pip (trong nón 10 bar) → Xác suất đạt: ~60-70%
  SL = -10 pip (ngoài nón 3 bar)  → Xác suất bị quét: ~10-15%
  → Trade có kỳ vọng dương ✅
```

### 6.5 Quản Lý Thời Gian Giữ Lệnh

Nón cho biết **sau bao lâu** giá có thể đạt target:

| Nến tương lai | Ý nghĩa (M15) | Ý nghĩa (H1) | Ý nghĩa (D1) |
|----------------|----------------|---------------|---------------|
| 4 nến | 1 giờ | 4 giờ | 4 ngày |
| 12 nến | 3 giờ | 12 giờ | ~2.5 tuần |
| 24 nến | 6 giờ | 1 ngày | ~1 tháng |

**Ứng dụng**: Nếu TP chỉ đạt được ở biên nón bar 50 trở lên → trade cần holding time rất dài → cân nhắc swap cost, overnight risk.

---

## 7. Ví Dụ Cụ Thể

### Ví dụ 1: XAUUSD - H1

**Tình huống**: Giá vàng đang ở 2650. Bạn muốn Buy.

```
📊 Đọc Probability Cone:
- Hurst = 0.62 → TRENDING
- Đường Mean nghiêng lên
- Biên trên bar 10: 2670 (+20 pip)
- Biên dưới bar 10: 2635 (-15 pip)
- Biên trên bar 20: 2695 (+45 pip)

📋 Kế hoạch giao dịch:
- Entry: 2650 (giá hiện tại)
- TP1: 2665 (70% biên trên 10-bar) → Conservative
- TP2: 2680 (biên trên 15-bar) → Neutral
- SL: 2633 (dưới biên dưới 10-bar)
- R:R = 15/17 ≈ 1:1 (TP1) hoặc 30/17 ≈ 1.76:1 (TP2)
```

### Ví dụ 2: EURUSD - M15 (Sideway)

**Tình huống**: EUR/USD đang ở 1.0850. Chỉ báo cho thấy H = 0.35 (mean-reverting).

```
📊 Đọc Probability Cone:
- Hurst = 0.35 → MEAN REVERTING
- Nón mở rộng CHẬM
- Đường Mean cong về EMA (1.0842)
- Biên trên bar 10: 1.0860 (+10 pip)
- Biên dưới bar 10: 1.0838 (-12 pip)

📋 Kế hoạch giao dịch (Sell):
- Entry: 1.0850 (giá trên EMA → sẽ kéo về)
- TP: 1.0843 (gần EMA target) → -7 pip
- SL: 1.0862 (trên biên trên) → +12 pip
- R:R = 7/12 ≈ 0.58:1 NHƯNG xác suất thành công cao (~68%)
```

### Ví dụ 3: TP Hoang Đường

**Tình huống**: Trader muốn Buy XAUUSD với TP +100 pip trong 1 giờ (M15, 4 nến).

```
📊 Kiểm tra Probability Cone:
- Biên trên bar 4: +18 pip (1 Sigma/68%)
- Biên trên bar 4 (2 Sigma/95%): +36 pip

📋 Phán định:
- TP +100 pip nằm ở đâu? → Khoảng 5.5 Sigma!
- Xác suất xảy ra: < 0.00001% (gần như không thể)
- ❌ KHÔNG NÊN đặt TP này

📋 TP hợp lý:
- TP = +15 pip (trong 1 Sigma) → Xác suất ~68%
- TP = +30 pip (gần 2 Sigma) → Xác suất ~20-25%
- TP = +100 pip → Cần ít nhất 20-30 nến (5-7.5 giờ)
```

---

## 8. FAQ - Câu Hỏi Thường Gặp

### Q1: Nón có dự đoán hướng giá không?
**Không trực tiếp**. Đường Mean (xám) cho thấy xu hướng trung tâm (bias), nhưng nón chủ yếu cho biết **VÙNG** giá có thể đạt, không phải hướng đi chính xác.

### Q2: Tại sao nón đôi khi rất rộng?
Nón rộng = Volatility cao + có thể fat tails (Kurtosis lớn) + có thể trending mạnh (Hurst cao). Đây là tín hiệu **giảm size** hoặc **không giao dịch**.

### Q3: Nón chỉ vẽ 1 mức (Z=2). Làm sao biết vùng 68%?
Thay đổi tham số **Z-Score Cơ bản** thành `1.0` để vẽ vùng 68% (1 Sigma). Bạn có thể thêm chỉ báo 2 lần: 1 lần Z=1 (68%), 1 lần Z=2 (95%).

### Q4: Chỉ báo có hoạt động tốt trên tất cả cặp tiền?
Hoạt động tốt nhất trên các cặp **có volatility ổn định** (XAUUSD, EURUSD, GBPUSD). Trên crypto hoặc cặp exotic (kurtosis rất cao), nón có thể rất rộng → ít hữu ích hơn.

### Q5: Nên sử dụng kết hợp với chỉ báo nào?
- **Trend indicators** (EMA, MACD): Xác định hướng → Cone xác nhận vùng TP hợp lý.
- **Volume indicators**: Xác nhận breakout khỏi cone.
- **Support/Resistance**: So sánh S/R cố định với biên nón.

### Q6: Tại sao đường Mean đôi khi cong?
Đó là khi Hurst < 0.55 → thị trường mean-reverting → đường trung tâm cong về EMA target (mô hình Ornstein-Uhlenbeck).

### Q7: Kappa = 0.1 ảnh hưởng thế nào?
Kappa là tốc độ mean-reversion. Kappa nhỏ (0.05) = giá quay về chậm, Kappa lớn (0.3) = giá quay về nhanh. Giá trị mặc định 0.1 là moderate.

---

## 9. Hạn Chế & Lưu Ý

### ⚠️ Hạn Chế Toán Học

1. **Hurst Exponent xấp xỉ**: Phương pháp single-scale, không chính xác bằng multi-scale DFA. Có thể nhiễu trên data ngắn.
2. **Kappa hardcode**: Tốc độ mean-reversion cố định = 0.1, không tự calibrate theo thị trường.
3. **Drift rate nhạy cảm**: Sử dụng chênh lệch giá đơn giản, có thể bị ảnh hưởng bởi spike.
4. **Giả định liên tục**: Mô hình giả định giá liên tục, không xét gap (overnight, weekend).

### ⚠️ Hạn Chế Thực Tế

1. **Không phải dự đoán**: Nón là **ước lượng xác suất**, không đảm bảo giá sẽ ở trong nón.
2. **Sự kiện bất ngờ (Black Swan)**: Tin tức lớn (NFP, Fed) có thể đẩy giá vượt mọi mức Sigma.
3. **Thay đổi chế độ**: Thị trường có thể chuyển từ trending sang ranging đột ngột.
4. **Overfitting tham số**: Tối ưu hóa quá mức tham số cho lịch sử không đảm bảo tương lai.

### ⚠️ Khi Nào KHÔNG Nên Tin Vào Nón

- 🔴 **Trước news lớn** (NFP, FOMC, CPI): Volatility sẽ thay đổi đột ngột.
- 🔴 **Thị trường mỏng** (tối thứ 6, đầu thứ 2): Spread rộng có thể phá nón.
- 🔴 **Flash crash/spike**: Kurtosis chưa kịp cập nhật cho sự kiện "thiên nga đen".

---

## 10. Bảng Tham Khảo Nhanh

### Z-Score → Xác Suất

| Z-Score | Xác suất nằm trong nón | Tên gọi |
|---------|------------------------|---------|
| 1.0 | 68.27% | 1 Sigma |
| 1.5 | 86.64% | 1.5 Sigma |
| 2.0 | 95.45% | 2 Sigma |
| 2.5 | 98.76% | 2.5 Sigma |
| 3.0 | 99.73% | 3 Sigma |

### Hurst → Chế Độ Thị Trường

| Hurst | Chế Độ | Mô tả | Chiến lược |
|-------|--------|-------|------------|
| 0.1 - 0.35 | Strong Mean-Reversion | Giá bị kéo mạnh về trung bình | Fade (bán đỉnh/mua đáy) |
| 0.35 - 0.45 | Mild Mean-Reversion | Giá dao động quanh trung bình | Range trading |
| 0.45 - 0.55 | Random Walk | Không có xu hướng rõ | Tránh hoặc scalp |
| 0.55 - 0.65 | Mild Trending | Xu hướng nhẹ | Follow trend + tight TP |
| 0.65 - 0.9 | Strong Trending | Giá đi rất xa | Trail stop, TP xa |

### Kurtosis → Mức Rủi Ro Đuôi Béo

| Kurtosis (K) | Tình trạng | Hành động |
|--------------|------------|-----------|
| K < 3 | Platykurtic (đuôi mỏng) | Nón chuẩn là đủ |
| K = 3 | Mesokurtic (phân phối chuẩn) | Normal |
| K = 3-5 | Leptokurtic nhẹ | Z tăng 10-20% |
| K = 5-10 | Leptokurtic vừa | Z tăng 20-70%, **cẩn thận** |
| K > 10 | Fat-tailed cực mạnh | **Giảm size, phòng thủ** |

---

## 📌 Checklist Sử Dụng Nhanh

```
□ 1. Nhìn hình dạng nón: Rộng? Hẹp? Nghiêng?
□ 2. Kiểm tra TP mong muốn có nằm TRONG nón không?
□ 3. Kiểm tra SL có nằm NGOÀI biên ngược hướng không?
□ 4. Đánh giá Hurst: Trending hay Mean-reverting?
□ 5. Nón quá rộng? → Giảm size hoặc không giao dịch
□ 6. Có news sắp ra không? → Nón có thể không chính xác
□ 7. Kết hợp với tín hiệu khác (MACD, EMA, S/R)
```

---

> **Ghi nhớ**: Probability Cone không phải là "Oracle" (tiên tri). Nó là công cụ **quản trị kỳ vọng** — giúp bạn biết điều gì **hợp lý** và điều gì **hoang đường** trước khi đặt lệnh.

---

*Tài liệu được tạo bởi ea Agent — Phiên bản 1.0*
