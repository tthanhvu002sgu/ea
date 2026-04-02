# Symbiotic Flow Cycle (SFC) - Tài Liệu Kỹ Thuật

**Symbiotic Flow Cycle (SFC)** là một chỉ báo (indicator) phân tích động lượng chuyên sâu, kết hợp các thành phần theo dõi dòng tiền thông minh (Smart Money), hành vi của nhà đầu tư nhỏ lẻ (Retail), sự tương quan giữa 2 nhóm này, cùng một hệ thống đánh giá bằng Neural Softmax để nhận diện 3 pha của chu kỳ thị trường.

---

## 1. Thành Phần Cốt Lõi

### A. Smart Money Catalyst (SMC) - Định vị Dòng Tiền Lớn

Thành phần này đo lường mức độ can thiệp của "Cá mập" (Smart money) dựa trên thanh khoản đi kèm chất lượng hành động giá.

* **Logic cốt lõi:** Dựa vào `volume` có điều chỉnh theo tỷ lệ thân nến (`body_ratio`). Thân nến càng đặc, lực của volume càng được xác nhận.
* **Cơ chế Shock & Memory:**
  * Sử dụng Z-Score để lọc các đợt bùng nổ khối lượng cực đại (Volume shock).
  * Khi xuất hiện Shock, giá trị được cộng dồn (tích lũy) thay vì xoá đè. Dòng tiền này sẽ hao mòn dần theo hệ số `smc_decay` ở các nến sau, tạo ra một **hiệu ứng nhớ** giúp chỉ báo mượt mà.
* **Chuẩn hoá (Normalization):** Dữ liệu được đoạt lại vào thang điểm (0-100) theo chu kỳ `length_smc * 3` để ngăn chặn hiệu ứng 1 cây nến outlier làm bẹp giá trị của toàn bộ phần còn lại.

### B. Retail Validation Index (RVI) - Đo lường Sự Hưng Phấn/Kiệt Sức Nhỏ Lẻ

Biểu diễn mức độ tham gia, bị mắc kẹt, hoặc hưng phấn cực độ của nhà đầu tư nhỏ lẻ (Retail/Dumb money).

* **Logic cốt lõi:** Kết hợp trung bình khối lượng (`mean_vol`) và tính nguyên lý **Information Entropy** (Độ hỗn loạn/Tính ngẫu nhiên của chuỗi giá).
* **Entropy calculation:** Dựa vào xác suất nến Up, nến Down và nến Tĩnh (Flat). Khi giá đi một chiều liên tục, Entropy rơi xuống thấp (thị trường mất tính ngẫu nhiên, rơi vào FOMO).
* Khi khối lượng cao nhưng Entropy cực thấp -> RVI tăng vọt (dấu hiệu Retail bị vắt kiệt - Exhaustion). RVI cũng được chuẩn hoá thang (0-100) tương tự SMC.

### C. Symbiotic Alignment Oscillator (SAO) - Bộ Dao Động Tương Quan

Đo lường mối tương quan (Correlation) giữa hành vi của SMC (Cá mập) và RVI (Nhỏ lẻ) để xem hai thế lực này đang cùng hướng hay đối đầu.

* **Logic cốt lõi:** Kết hợp tương quan đồng thời tại nến hiện tại (`corr_0`) và tương quan có độ trễ (`corr_n`) để nhận biết trước độ lệch pha.
* **Ý nghĩa SAO (Dải từ -1.0 đến +1.0):**
  * `> 0.3`: Đồng Pha (Symbiotic) - Nhỏ lẻ ngoan ngoãn đi theo sự dẫn dắt của Cá mập.
  * `< -0.3`: Phân Kỳ (Divergence/Trap) - Cá mập và nhỏ lẻ đang đi ngược chiều (Cá mập úp bô/gom hàng từ tay nhỏ lẻ).
  * `Gần 0`: Hai phe không có tính liên kết rõ ràng.

---

## 2. Hệ Thống Chu Kỳ (Softmax Neural Engine)

Dữ liệu từ 3 mũi nhọn (SMC, RVI, SAO) kết hợp cùng Động lượng Xu hướng `Trend Proxy` (nghịch đảo của phân phối CHOP Index) sẽ được đưa vào các hàm chấm điểm (Score).

Sau đó, áp dụng hàm **Softmax (e^x / sum(e^x))** để chuyển đổi điểm số thành xác suất `%` cho 3 pha thị trường. Khác với các điều kiện True/False thông thường, Softmax cung cấp xác suất mượt mà hơn để biết pha nào đang chiếm ưu thế.

**3 Pha Thị Trường bao gồm:**

* **PHA 1 (Symbiotic Growth):**
  * **Đặc tính:** Thị trường có xu hướng mạnh, SAO dương (Nhỏ lẻ đi theo cá mập), dòng tiền SMC mạnh, RVI đang gia tăng mạnh.
  * **Hành động:** 🟢 **MUA** (Đợi Pullback / Breakout).

* **PHA 2 (Retail Exhaustion):**
  * **Đặc tính:** Xu hướng vẫn mạnh nhưng có sự chuyển giao khối lượng. SAO âm nặng (Phân kỳ), SMC đang sụt giảm (Cá rụt vòi) nhưng RVI lại cực kỳ cao (Nhỏ lẻ vẫn đang FOMO). Điển hình cho quá trình phân phối đỉnh / đáy.
  * **Hành động:** 🔴 **BÁN** (Tìm kiếm nền giá Exhaustion hoặc Phân kỳ).

* **PHA 3 (Contraction):**
  * **Đặc tính:** Phá vỡ xu hướng (Vào vùng đi ngang - Range bound). Kháng cự/hỗ trợ hẹp, SAO mất kết nối, cá mập nằm im (SMC thấp), nhỏ lẻ cạn kiệt (RVI thấp).
  * **Hành động:** ⚪ **ĐỨNG NGOÀI** (Không có tín hiệu rõ rệt).

* **Bộ Lọc Chuyển Pha (Phase Smoothing):**
Pha hoạt động (`active_phase`) chỉ thay đổi khi xác suất của một pha vượt quá **50% (0.5)**. Nếu các pha không rõ ràng, hệ thống sẽ bảo lưu ghi nhận của pha cũ, ngăn chặn nhấp nháy chỉ báo.

---

## 3. Giao Diện (Super Dashboard & Background Alert)

1. **Hiển thị Bảng Điều Khiển (HUD) ở góc trái:**
   Thiết kế ma trận tinh gọn trình bày các luồng thông tin:
   * **Cá mập (SMC)**: Bơm bạo lực / Mồi lửa / Nằm im.
   * **Nhỏ lẻ (RVI)**: Cực hưng phấn / Đang nhập cuộc / Mất phương hướng.
   * **Tương quan (SAO)**: Đồng pha / Phân kỳ / Mất kết nối.
   * **Trạng thái hành động**: Nhận diện tức thời Pha 1, 2, 3 và đưa ra kết luận (Mua/Bán/Đứng ngoài).

2. **Cảnh Báo Nền (Background Color):**
   * Tuỳ chọn `show_bg` đổi màu phông nền biểu đồ giá dựa trên Pha được bốc tách.
   * **Độ sáng (Opacity)**: Được neo trực tiếp vào `current_max_prob`. Màu càng rực rỡ thì chỉ báo càng khẳng định độ chắc chắn cho pha hiện tại và ngược lại, màu mờ nhạt báo hiệu sự lưỡng lự.

---

## Hướng Dẫn Tinh Chỉnh

* **Khi bị xê dịch nhiều do tin tức (News Spike):** Có thể chỉnh `SMC Memory Decay` cao hơn (`0.90`) để hiệu ứng volume giữ được lâu hơn sau các đợt sốc thanh khoản.
* **Kết quả bị trễ:** Giảm `CHOP Lookback` hoặc `RVI Lookback` để bắt nhịp nhạy hơn ở các khung M1, M5.
* **Cần độ tương quan chắc chắn hơn:** Nâng `Lag (n)` để xác nhận hiện tượng xả hàng trước đó của Cá mập ảnh hưởng thế nào đến dòng hành vi hiện tại của Retail.
