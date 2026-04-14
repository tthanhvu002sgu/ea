# Tài liệu Hướng dẫn: Trend-Quality Indicator (Q-Indicator / B-Indicator)

Tài liệu này giải thích chi tiết về logic, các thành phần và cách thức hoạt động của mã nguồn `q-indicator.pine`.

## 1. Tổng quan
Đây là một chỉ báo (indicator) hiển thị ở dạng dao động (oscillator) nằm dưới biểu đồ chính (vì `overlay=false`). Mục tiêu của chỉ báo này là **đánh giá chất lượng của xu hướng hiện tại** bằng cách so sánh sự thay đổi giá thuần túy (Trend) với độ nhiễu loạn của thị trường (Noise).

Chỉ báo tính toán và vẽ hai thông số chính:
1. **Q-Indicator (TQ):** Đo lường chất lượng xu hướng theo hai chiều (dương báo hiệu xu hướng tăng, âm báo hiệu xu hướng giảm).
2. **B-Indicator (TNB - Trend Noise Balance):** Thể hiện phần trăm độ mạnh của xu hướng so với tổng thể (bao gồm cả xu hướng và nhiễu). Giá trị dao động từ 0 đến 100.

---

## 2. Các thông số đầu vào (Inputs)
Người dùng có thể tùy chỉnh các cài đặt sau:
- **Hiển thị (Toggles):** `showQ` và `showB` để bật/tắt vẽ hai sóng này trên biểu đồ.
- **Fast Length (Mặc định: 7) & Slow Length (Mặc định: 15):** Chiều dài của hai đường chéo cắt trung bình động (EMA) dùng để định hướng xu hướng chính (Tăng/Giảm).
- **Trend Length (Mặc định: 4):** Xác định hệ số làm mịn mượt (Smoothing Factor - `smf`) cho đường xu hướng.
- **Noise Type (Mặc định: "LINEAR"):** Phương pháp tính toán "nhiễu". Có hai loại:
  - `LINEAR`: Dựa trên đường trung bình thường (SMA) của khoảng cách bù trừ.
  - `SQUARED`: Dựa trên bình phương trung bình gốc (kiểu Root Mean Square - RMS), nhấn mạnh vào các đoạn nhiễu lớn.
- **Noise Length (Mặc định: 250):** Chu kỳ để tính trung bình cho độ nhiễu.
- **Correction Factor (Mặc định: 2):** Hệ số nhân để phóng đại độ nhiễu lên nhằm làm nổi bật tín hiệu xu hướng thực sự.

---

## 3. Logic tính toán bên trong 

### Bước 1: Xác định chiều Xu hướng
Hệ thống sử dụng đường EMA nhanh (`emaFast`) và EMA chậm (`emaSlow`):
- `reversal`: Mang giá trị `+1` nếu `emaFast > emaSlow` (đang có đà tăng), và `-1` nếu ngược lại.

### Bước 2: Tính toán Giá trị Xu hướng (Trend)
- `cpc` (Cumulative Price Change): Là biến tích lũy thay đổi giá (`close - close[1]`). Nó sẽ được cộng dồn liên tục miễn là trend vẫn chưa đổi chiều (`reversal == reversal[1]`). Nếu trend đổi chiều, `cpc` reset về `0`.
- `trend`: Được làm mịn từ `cpc` dựa trên công thức hàm trung bình động lũy thừa (EMA-like) với chu kỳ là `lenTrend`.

### Bước 3: Tính toán Độ nhiễu (Noise)
- `diff`: Là sự khác biệt tuyệt đối (`math.abs`) giữa thay đổi giá lũy kế thật (`cpc`) và đường xu hướng đã được làm mượt (`trend`). Mức độ khác biệt này chính là biểu hiện của độ nhiễu.
- `noise`: Nếu dùng "LINEAR", hàm sẽ lấy đường SMA của chuỗi `diff` trong `lenNoise` kỳ. Sau đó, nhân giá trị này cho `correctionFactor` để điều chỉnh độ nhạy.

### Bước 4: Tính toán Chỉ báo Đầu ra
1. **indicatorQ:** 
   `indicatorQ = trend / noise`
   » Giá trị dương cho biết xu hướng tăng đang mạnh hơn nhiễu bao nhiêu lần.
   » Giá trị âm cho biết xu hướng giảm đang mạnh hơn nhiễu bao nhiêu lần.
   
2. **indicatorB:**
   `indicatorB = (math.abs(trend) / (math.abs(trend) + noise)) * 100`
   » Thể hiện phần trăm thống trị của lực "Trend" trong tổng thể "Trend + Noise". Nếu bằng 100, tức là thị trường đi rất mượt, gần như không có độ nhiễu.

---

## 4. Hiển thị đồ họa (Plots & Colors)

### Màu sắc Q-Indicator (ColorQ)
Chỉ báo `TQ` được vẽ dưới dạng các **cột (columns)** với màu sắc dựa trên độ mạnh, cụ thể:
- **$\ge$ 5 (Tăng cực mạnh):** Xanh lá cây (Green)
- **Từ 2 đến < 5 (Tăng khá):** Xanh lam (Blue)
- **Từ 1 đến < 2 (Tăng yếu):** Vàng (Yellow)
- **Từ -2 đến -1 (Giảm yếu):** Vàng (Yellow)
- **Từ -5 đến < -2 (Giảm khá):** Cam (Orange)
- **$\le$ -5 (Giảm cực mạnh):** Đỏ (Red)
- Chỉ số dao động quanh mốc 0 (-1 đến 1): Xám (Gray) - Biểu thị thị trường chưa rõ ràng/nhiều nhiễu loạn.

### Màu sắc B-Indicator (ColorB)
Chỉ báo `TNB` được vẽ dưới dạng một **đường (line)**:
- **$\ge$ 80% (Xu hướng cực rõ rệt):** Xanh lá cây (Green)
- **Từ 65% đến < 80% (Xu hướng tốt):** Xanh lam (Blue)
- **Từ 50% đến < 65% (Xu hướng vừa phải):** Vàng (Yellow)
- **Dưới 50% (Độ nhiễu lấn át):** Xám (Gray)

**Đường tham chiếu:** 
- Q-Indicator có một Zero Line (Đường số 0) màu đỏ.
- B-Indicator có một Half Line (Đường 50) màu đỏ.
