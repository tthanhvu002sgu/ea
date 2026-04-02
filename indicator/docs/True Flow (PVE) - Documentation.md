# True Flow (PVE) Indicator

## 📊 Tổng Quan — Indicator Này Dùng Để Làm Gì?

### Vấn đề mà volume thường gặp

Khi nhìn vào biểu đồ volume thông thường, bạn chỉ thấy **"bao nhiêu người giao dịch"** — nhưng không biết:

- Cây nến đó có **thực sự di chuyển mạnh về một hướng** không? (hay chỉ giật lên giật xuống rồi đóng gần chỗ mở?)
- Volume lớn đó có **tạo ra momentum thật** không? (hay chỉ là noise?)

**Ví dụ cụ thể:**
- Nến A: Volume = 10,000. Body rất lớn (close cách xa open). → **Volume này có ý nghĩa**, phe mua/bán thống trị rõ ràng.
- Nến B: Volume = 10,000. Nhưng râu trên + râu dưới rất dài, body bé tí (Doji). → **Volume vô nghĩa**, hai phe đánh nhau kịch liệt nhưng kết quả là hòa.

Volume chart thường **không phân biệt** được 2 trường hợp này. Cả hai đều hiện cột volume giống nhau.

### True Flow giải quyết vấn đề gì?

**True Flow = Volume đã được lọc qua chất lượng nến.**

Nó trả lời câu hỏi: *"Volume trên cây nến này có đang tạo ra chuyển động giá **thực sự** không?"*

- Nến A (body lớn, ít râu, volume cao) → True Flow **rất lớn** ✅
- Nến B (Doji, volume cao) → True Flow **gần bằng 0** ❌

Nói cách khác: **True Flow đo "dòng tiền thật" — phần volume thực sự tạo ra momentum**, sau khi loại bỏ noise.

---

## 🚗 Nguyên Lý Hoạt Động — Mô Hình "Chiếc Xe"

Hãy tưởng tượng mỗi cây nến là **một chiếc xe đang chạy**:

| Thành phần | Ý nghĩa trong giao dịch | Cách tính |
|------------|--------------------------|-----------|
| ⛽ **Nhiên liệu** | Volume — năng lượng đổ vào nến | `Volume / AvgVolume` (tương đối) |
| 🚗 **Quãng đường** | Body — giá đi được bao xa | `\|Close - Open\| / ATR` (tương đối so với biến động) |
| 🌬️ **Lực cản gió** | Râu nến — lực cản ngược | `Range - Body` |
| 🧭 **Hướng đi** | Bullish (+1) hay Bearish (-1) | `Close > Open → +1, Close < Open → -1` |

### Logic:
- **Xe đổ đầy xăng + chạy thẳng một mạch** (volume cao, body lớn, ít râu) → True Flow rất lớn ✅
- **Xe đổ đầy xăng nhưng chạy vòng vòng** (volume cao, body bé, râu dài) → True Flow gần 0 ❌
- **Xe ít xăng + chạy thẳng** (volume thấp, body lớn) → True Flow trung bình ⚠️

---

## 🧮 Công Thức

```
True Flow = RelVolume × NormBody × k² × Direction
```

Trong đó:

### 1. `NormBody` — Quãng đường chuẩn hóa
```
NormBody = |Close - Open| / ATR(14)
```
- Chia cho ATR để **so sánh được giữa các cặp tiền/hàng hóa** (XAUUSD vs EURUSD).
- NormBody = 1.0 nghĩa là body bằng đúng 1 ATR (di chuyển bình thường).
- NormBody = 2.0 nghĩa là body gấp đôi biến động trung bình (rất mạnh).

### 2. `k` — Hệ Số Tinh Khiết (Purity)
```
k = Body / Range = |Close - Open| / (High - Low)
```

k cho biết **bao nhiêu phần trăm** biên độ nến thực sự tạo ra chuyển động:

| Giá trị k | Loại nến | Ý nghĩa |
|-----------|----------|---------|
| ≥ 90% | **Marubozu** ✦ | Gần như không có râu. Momentum thuần khiết. |
| 70-89% | **Strong** ● | Râu ngắn. Xu hướng rõ ràng. |
| 50-69% | **Moderate** ◐ | Tạm được, có một ít do dự. |
| 30-49% | **Weak** ○ | Nhiều râu, tín hiệu yếu. |
| < 30% | **Hollow** ◌ | Doji hoặc nến rất nhiều râu. Noise. |

> **Tại sao k² (bình phương)?**
> Để **tăng cường hình phạt** cho nến kém chất lượng:
> - k = 0.8 → k² = 0.64 (giảm 36% — chấp nhận được)
> - k = 0.5 → k² = 0.25 (giảm 75% — phạt nặng)
> - k = 0.2 → k² = 0.04 (giảm 96% — gần như loại bỏ)

### 3. `RelVolume` — Volume tương đối
```
RelVolume = Volume / SMA(Volume, 20)
```
- = 1.0: Volume bình thường
- = 2.0: Volume gấp đôi mức trung bình (chú ý!)
- = 0.5: Volume chỉ bằng nửa mức bình thường

### 4. `Direction` — Hướng
```
Bullish: +1 (Close > Open)
Bearish: -1 (Close < Open)
Doji:    +1 nếu Close > Close[1], -1 nếu ngược lại
```
> Doji không bị gán = 0 nữa. Thay vào đó, chỉ báo nhìn vào **close so với close cây trước** để xác định hướng.

---

## 📈 Cách Đọc Chỉ Báo

### Histogram (cột)
| Màu | Ý nghĩa |
|-----|---------|
| 🔵 **Xanh dương** | True Flow dương → Áp lực mua mạnh, momentum tăng thực sự |
| 🔴 **Đỏ** | True Flow âm → Áp lực bán mạnh, momentum giảm thực sự |
| ⚪ **Xám** | Không đủ tiêu chuẩn purity (dưới ngưỡng `MinPurity`) |

### Signal Line (SMA14 — đường vàng Gold)
- Trung bình True Flow 14 kỳ
- Dùng để **xác nhận xu hướng** và **phát hiện crossover**

### Đọc nhanh:
```
Cột XANH cao + liên tục     = Phe mua đang thống trị → Uptrend mạnh
Cột ĐỎ cao + liên tục       = Phe bán đang thống trị → Downtrend mạnh
Cột thấp dần / xen kẽ màu   = Momentum suy yếu → Cẩn thận đảo chiều
```

---

## 🎯 Tín Hiệu Giao Dịch

### 1. Crossover với Signal Line
```
⬆ BUY:  Histogram cắt LÊN Signal Line → Momentum mua tăng tốc
⬇ SELL: Histogram cắt XUỐNG Signal Line → Momentum bán tăng tốc
```

### 2. Crossover với đường Zero
```
BULLISH: True Flow vượt lên trên 0 → Chuyển sang vùng momentum mua
BEARISH: True Flow xuống dưới 0 → Chuyển sang vùng momentum bán
```

### 3. Divergence (phân kỳ)
- **Bullish Divergence**: Giá tạo đáy thấp hơn, True Flow tạo đáy cao hơn → Đà giảm đang cạn → Sắp tăng
- **Bearish Divergence**: Giá tạo đỉnh cao hơn, True Flow tạo đỉnh thấp hơn → Đà tăng đang cạn → Sắp giảm

### 4. Exhaustion (cạn kiệt momentum)
```
Sau đợt tăng mạnh: Cột xanh THU NHỎ dần → Phe mua đang hết lực
Sau đợt giảm mạnh: Cột đỏ THU NHỎ dần  → Phe bán đang hết lực
```

---

## ⚙️ Tham Số Input

| Tham số | Mặc định | Mô tả |
|---------|----------|-------|
| `Signal Line Period` | 14 | Chu kỳ SMA cho Signal Line |
| `Smooth Period` | 1 | Làm mượt histogram. **1 = off**. Dùng 3-5 cho M1-M15 để giảm noise. |
| `Min Purity Threshold` | 0.0 | Ngưỡng k tối thiểu. Nến dưới ngưỡng bị loại (= 0). Thử 0.3-0.5 để lọc mạnh. |
| `Normalize Volume` | **true** | Chuẩn hóa Volume theo trung bình. **Nên để ON** để ổn định. |
| `Volume Norm Period` | 20 | Số nến để tính trung bình Volume |

---

## 💡 Ứng Dụng Thực Tế

### Xác nhận breakout
```
Breakout thật = Giá phá vỡ + True Flow cột rất cao (k ≥ 0.7, RelVolume ≥ 1.5)
Breakout giả = Giá phá vỡ + True Flow cột thấp (nến nhiều râu, volume thấp)
```

### Lọc tín hiệu vào lệnh
```
Chỉ vào lệnh khi: k ≥ 0.5 (nến có chất lượng trung bình trở lên)
Bỏ qua khi:       k < 0.3 (quá nhiều râu, tín hiệu không đáng tin)
```

### Kết hợp với các chỉ báo khác
- **EMA/MA**: True Flow xác nhận xu hướng mà EMA chỉ ra
- **Supply/Demand**: Vào zone + True Flow cột cao = zone phản ứng mạnh
- **Price Action**: Nến pin bar/engulfing + True Flow xác nhận = tín hiệu tin cậy cao

---

## 🔔 Alerts (TradingView)

1. **Bullish Cross** — Histogram vượt lên Signal Line
2. **Bearish Cross** — Histogram xuống dưới Signal Line
3. **Turned Positive** — True Flow chuyển sang dương
4. **Turned Negative** — True Flow chuyển sang âm
5. **High Quality Move** — Nến k ≥ 80% với True Flow mạnh hơn trung bình

---

## 📁 Files

| File | Nền tảng |
|------|----------|
| `True Flow (PVE).mql5` | MetaTrader 5 |
| `True Flow (PVE).pine` | TradingView (PineScript v5) |

---

## 📝 Ghi Chú

- **Timeframe**: Hoạt động trên mọi khung thời gian. TF thấp (M1-M5) nên bật Smooth = 3-5.
- **Best for**: Xác nhận breakout, phát hiện exhaustion, lọc noise, đánh giá chất lượng momentum.
- **Kết hợp với**: EMA, Supply/Demand, Price Action.
- **Lưu ý**: Đây là indicator xác nhận (confirmation), KHÔNG phải indicator timing. Dùng kết hợp với hệ thống entry riêng.

---

*© True Flow Indicator — The Quality Vector*
