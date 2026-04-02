# Reynolds Flow - Energy River Indicator
## User Guide & Documentation

---

## 📖 Giới thiệu

**Reynolds Flow** là một chỉ báo kỹ thuật độc đáo, lấy cảm hứng từ **Số Reynolds** trong vật lý thủy động học. Chỉ báo này giúp trader nhận biết trạng thái "dòng chảy" của thị trường - xác định khi nào thị trường đang trong trạng thái thuận lợi để giao dịch và khi nào nên đứng ngoài.

### 🎯 Mục đích chính
- Đo lường **động lượng tương đối** của giá so với biến động lịch sử
- Nhận diện **chế độ thị trường** (Bull/Bear/Sideway)
- Xác định **vùng giao dịch tối ưu** (Sweet Spot)
- Cảnh báo **vùng nguy hiểm** có thể đảo chiều

---

## 🧮 Công thức Tính toán

### Lớp 1: Raw Reynolds Number (Re_raw)

$$Re_{raw} = \frac{|Close - Open| \times \text{Sign}(Close - MA_{period})}{ATR_{period} + \epsilon}$$

| Thành phần | Ý nghĩa | Công thức |
|------------|---------|-----------|
| **Momentum** | Động lượng nến | \|Close - Open\| |
| **Direction** | Hướng xu hướng | +1 nếu Close > MA, -1 nếu Close < MA |
| **Volatility** | Độ biến động (ma sát) | ATR |
| **ε (epsilon)** | Tránh chia cho 0 | syminfo.mintick |

### Lớp 2: Self-Normalization (Re_norm)

$$Re_{norm} = \frac{Re_{raw}}{SMA(|Re_{raw}|, 100)}$$

**Ý nghĩa:**
- **Re_norm ≈ 1.0**: Động lượng bình thường, đúng mức trung bình lịch sử
- **Re_norm > 2.0**: Động lượng gấp đôi mức trung bình → Mạnh bất thường
- **Re_norm < 0.5**: Động lượng yếu → Thị trường tù đọng

---

## 🏛️ Chế độ Thị trường (Market Regime)

Chỉ báo tự động nhận diện 3 chế độ thị trường dựa trên **Regime Score**:

```
Regime Score = SMA(Price > MA ? 1 : 0, Regime_Period)
```

### 🐂 Bull Market (Regime Score ≥ 60%)
- **Đặc điểm:** Phe mua hưng phấn, giá thường "quá đà" (Overextended)
- **Ngưỡng Turbulent:** Percentile(90) - **Nới lỏng**
- **Lý do:** Trong Bull run, "Overbought" có thể duy trì rất lâu

### 🐻 Bear Market (Regime Score ≤ 40%)
- **Đặc điểm:** Hoảng loạn xảy ra nhanh, biến động đi kèm sập giá
- **Ngưỡng Turbulent:** Percentile(60) - **Siết chặt**
- **Lý do:** Chỉ cần một chút biến động mạnh là cấu trúc dễ vỡ

### 📊 Sideway (40% < Regime Score < 60%)
- **Đặc điểm:** Re thường rất thấp, noise nhiều
- **Xử lý:** Vùng Percentile(20-80) coi là Noise → Chuyển sang màu Xám

---

## 🌊 Vùng Dòng chảy (Flow Zones)

Chỉ báo vẽ "Dòng sông Năng lượng" (Energy River) với 3 vùng màu:

### 🟢 Laminar Flow (Dòng chảy Tầng) - XANH
| Thuộc tính | Giá trị |
|------------|---------|
| **Điều kiện** | Percentile(40) < \|Re_norm\| < Threshold_Turbulent |
| **Ý nghĩa** | Giá đi nhanh, mạnh, nhưng êm (thân nến dài, ATR thấp) |
| **Hành động** | ✅ **SWEET SPOT** - Hold lệnh, để lợi nhuận chạy |

### 🔴 Turbulent Flow (Dòng chảy Rối) - ĐỎ
| Thuộc tính | Giá trị |
|------------|---------|
| **Điều kiện** | \|Re_norm\| ≥ Threshold_Turbulent |
| **Ý nghĩa** | Nước chảy quá xiết, sắp có xoáy nước (đảo chiều/điều chỉnh) |
| **Hành động** | ⚠️ **NGUY HIỂM** - Chốt lời hoặc Siết Stoploss |

### ⚪ Viscous Flow (Dòng chảy Nhớt) - XÁM
| Thuộc tính | Giá trị |
|------------|---------|
| **Điều kiện** | \|Re_norm\| < Percentile(30) |
| **Ý nghĩa** | Nước tù, ma sát (ATR) thắng thế quán tính (Momentum) |
| **Hành động** | ⏸️ **DEAD ZONE** - Đứng ngoài, không giao dịch |

---

## ⚙️ Tham số Input

### Core Settings (Cài đặt Cốt lõi)

| Tham số | Mặc định | Mô tả | Gợi ý |
|---------|----------|-------|-------|
| `MA Period` | 20 | Chu kỳ MA xác định hướng | Tăng lên 50-100 cho swing trading |
| `ATR Period` | 14 | Chu kỳ ATR đo biến động | Giữ nguyên 14 là chuẩn |
| `Normalization Period` | 100 | Chu kỳ chuẩn hóa Re_norm | Tăng lên 200 cho độ ổn định cao hơn |
| `Percentile Lookback` | 100 | Lookback tính percentile động | Nên giữ = Normalization Period |

### Regime Detection (Nhận diện Chế độ)

| Tham số | Mặc định | Mô tả |
|---------|----------|-------|
| `Regime Detection Period` | 50 | Chu kỳ xác định regime |
| `Bull Regime Threshold` | 0.6 (60%) | Ngưỡng xác định Bull Market |
| `Bear Regime Threshold` | 0.4 (40%) | Ngưỡng xác định Bear Market |

### Flow Zones (Vùng Dòng chảy)

| Tham số | Mặc định | Mô tả |
|---------|----------|-------|
| `Turbulent Threshold (Bull)` | 90 | Percentile ngưỡng Turbulent trong Bull |
| `Turbulent Threshold (Bear)` | 60 | Percentile ngưỡng Turbulent trong Bear |
| `Laminar Lower Bound` | 40 | Percentile ngưỡng dưới Laminar |
| `Viscous Threshold` | 30 | Percentile ngưỡng Viscous (Dead Zone) |
| `Sideway Noise Lower/Upper` | 20/80 | Vùng Noise trong Sideway |

### Display (Hiển thị)

| Tham số | Mặc định | Mô tả |
|---------|----------|-------|
| `Show Energy River` | true | Hiển thị vùng màu Energy River |
| `Show Trading Signals` | true | Hiển thị tín hiệu giao dịch |
| `Show Regime Label` | true | Hiển thị nền màu theo Regime |
| `River Line Width` | 2 | Độ dày đường Re_norm |

---

## 📊 Đọc hiểu Bảng Thông tin

Bảng thông tin góc phải trên hiển thị:

| Mục | Ý nghĩa |
|-----|---------|
| **Regime** | Chế độ thị trường hiện tại (🐂 BULL / 🐻 BEAR / 📊 SIDEWAY) |
| **Re_raw** | Giá trị Reynolds thô |
| **Re_norm** | Giá trị Reynolds đã chuẩn hóa |
| **\|Re_norm\|** | Giá trị tuyệt đối (độ mạnh) |
| **Flow State** | Trạng thái dòng chảy (LAMINAR ✓ / TURBULENT ⚠️ / VISCOUS ○) |
| **Turb. Thresh** | Ngưỡng Turbulent hiện tại (động, theo regime) |
| **Direction** | Hướng xu hướng (📈 BULLISH / 📉 BEARISH) |
| **Action** | Gợi ý hành động |
| **ATR** | Giá trị ATR hiện tại |

---

## 🎯 Chiến lược Giao dịch

### Chiến lược 1: Laminar Entry (Vào lệnh Sweet Spot)

**Điều kiện LONG:**
1. Regime = Bull hoặc Sideway
2. Re_norm > 0 (hướng tăng)
3. Flow State chuyển sang LAMINAR (vừa vào vùng xanh)
4. Giá trên MA

**Điều kiện SHORT:**
1. Regime = Bear hoặc Sideway
2. Re_norm < 0 (hướng giảm)
3. Flow State chuyển sang LAMINAR (vừa vào vùng xanh)
4. Giá dưới MA

**Quản lý lệnh:**
- **SL:** Dưới đáy gần nhất (Long) / Trên đỉnh gần nhất (Short)
- **TP:** Khi vào vùng TURBULENT hoặc Re_norm đảo dấu
- **Trailing:** Siết SL khi vào vùng TURBULENT

### Chiến lược 2: Turbulent Exit (Thoát khi quá nhiệt)

**Điều kiện:**
1. Đang giữ lệnh có lời
2. Flow State chuyển sang TURBULENT (vào vùng đỏ)

**Hành động:**
- Chốt 50-100% lệnh
- Hoặc dời SL về Breakeven + buffer
- Không mở lệnh mới theo hướng cũ

### Chiến lược 3: Viscous Filter (Lọc Noise)

**Quy tắc:**
- **KHÔNG** mở lệnh khi Flow State = VISCOUS
- Đây là vùng Dead Zone, momentum không đủ mạnh
- Chờ đến khi vào lại vùng LAMINAR

---

## 🔔 Cài đặt Alert

Indicator cung cấp các alert sau:

| Alert | Ý nghĩa | Hành động gợi ý |
|-------|---------|-----------------|
| `Laminar Long Entry` | Vào vùng Sweet Spot hướng tăng | Chuẩn bị/Vào lệnh Long |
| `Laminar Short Entry` | Vào vùng Sweet Spot hướng giảm | Chuẩn bị/Vào lệnh Short |
| `Turbulent Warning` | Vào vùng nguy hiểm | Chốt lời/Siết SL |
| `Viscous Dead Zone` | Động lượng chết | Đứng ngoài |
| `Bull Regime Started` | Chuyển sang chế độ Bull | Ưu tiên Long |
| `Bear Regime Started` | Chuyển sang chế độ Bear | Ưu tiên Short |

**Cách tạo Alert trong TradingView:**
1. Click chuột phải lên chart → "Add Alert"
2. Condition: Chọn "Reynolds Flow - Energy River"
3. Chọn condition từ dropdown
4. Set notification (popup, email, webhook, etc.)

---

## 💡 Mẹo Sử dụng

### ✅ Nên làm:
1. **Kết hợp với Price Action:** Chờ xác nhận từ pattern nến tại vùng quan trọng
2. **Theo Regime:** Long trong Bull, Short trong Bear, cẩn thận trong Sideway
3. **Chờ Laminar:** Kiên nhẫn chờ vào vùng xanh trước khi vào lệnh
4. **Respect Turbulent:** Luôn siết SL hoặc chốt lời khi vào vùng đỏ
5. **Multi-timeframe:** Xem Regime ở TF lớn, Entry ở TF nhỏ

### ❌ Không nên làm:
1. **Trade trong Viscous:** Đây là vùng Death Zone, tránh xa
2. **Counter-trend trong Turbulent:** Momentum quá mạnh, dễ bị cuốn
3. **Bỏ qua Regime:** Bull và Bear có ngưỡng khác nhau - hãy tôn trọng
4. **Overfit parameters:** Đừng optimize quá mức, giữ default là tốt nhất

---

## 📈 Ví dụ Thực tế

### Ví dụ 1: Entry Long trong Bull Market

```
Bước 1: Kiểm tra Regime = 🐂 BULL
Bước 2: Chờ Re_norm > 0 và Flow State = LAMINAR ✓
Bước 3: Xác nhận giá trên MA20
Bước 4: Entry Long khi có tín hiệu △ (triangle up)
Bước 5: SL dưới swing low gần nhất
Bước 6: Hold cho đến khi Flow State = TURBULENT ⚠️
Bước 7: Chốt lời 50%, dời SL về Breakeven
```

### Ví dụ 2: Thoát lệnh khi Turbulent

```
Đang hold lệnh Long có lời
→ Flow State chuyển từ LAMINAR sang TURBULENT
→ Bảng hiện: ⚠️ Take Profit / Tighten SL
→ Action: Chốt 50% position, dời SL lên Breakeven
→ Nếu giá tiếp tục tăng rồi quay về, SL sẽ bảo vệ phần còn lại
```

---

## 🔧 Troubleshooting

### Q: Chỉ báo không hiển thị đúng trên timeframe nhỏ?
**A:** Các tham số mặc định tối ưu cho H1-D1. Với M15 trở xuống, giảm `Normalization Period` xuống 50-70.

### Q: Vùng Energy River quá rộng/hẹp?
**A:** Điều chỉnh `Laminar Lower Bound` và `Viscous Threshold` để mở rộng/thu hẹp các vùng.

### Q: Không thấy tín hiệu chuyển vùng?
**A:** Đảm bảo `Show Trading Signals = true`. Tín hiệu chỉ xuất hiện tại thời điểm chuyển đổi (transition).

### Q: Regime liên tục thay đổi trong Sideway?
**A:** Tăng `Regime Detection Period` lên 100 để giảm độ nhạy.

---

## 📜 Changelog

### Version 1.0 (2026-02-05)
- Initial release
- Core Reynolds Flow calculation
- 3-zone Energy River visualization
- Adaptive regime detection (Bull/Bear/Sideway)
- Dynamic percentile thresholds
- Information table display
- 6 alert conditions

---

## 📞 Support

Nếu có câu hỏi hoặc đề xuất cải tiến, vui lòng liên hệ qua:
- GitHub Issues
- TradingView Private Message

---

*"Trade with the flow, not against it."* 🌊
