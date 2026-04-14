# Tài Liệu Hướng Dẫn Kỹ Thuật EA: Go Long Rene (US30 Advanced Breakout)

**Go Long Rene** là một Expert Advisor (EA) thiết kế chuyên biệt cho nền tảng MT5, tập trung khai thác đà tăng trưởng của các chỉ số chứng khoán Mỹ (US30, US500, NASDAQ). Chiến lược áp dụng nguyên tắc **CHỈ MUA (Long Only)** và có hai phương pháp tiếp cận chính:
1. **Breakout (Theo xu hướng đột phá đỉnh):** Đợi giá tích lũy tạo đỉnh, sau đó vào lệnh khi đỉnh này bị phá vỡ.
2. **Time-based Buy & Hold (Khai thác Overnight Drift):** Vào lệnh khống tại một khung thời gian cụ thể (thường là cuối phiên) và giữ trạng thái qua đêm để bám theo sự kiện giá "nhảy gap" (gap-up) đặc trưng của thị trường Mỹ.

---

## 🕒 Khái niệm "Chu kỳ Thời gian" (Time Management)
Hệ thống lõi của EA quản lý thời gian trên một trục có tên **Time Window Manager** tự động kết nối liền mạch qua nửa đêm (00:00). Mỗi ngày EA chỉ thực thi một chu kỳ giao dịch và đi qua 3 cánh cửa thời gian:

1. **Observe Window (Khung giờ Theo dõi):** Kích hoạt hệ thống quét đỉnh (Session High). Đỉnh này được quét dựa trên nến `M1` và được dùng làm giới hạn Phá vỡ (Breakout) cho EA sau đó.
2. **Trading Window (Khung giờ Giao dịch):** Khung giờ cho phép mở lệnh BUY. Tùy thuộc vào thiết lập "Wait New Day High" mà EA sẽ lập tức đặt lệnh hay chờ giá phá cái Đỉnh vừa quét.
3. **Wait/Close Window (Khung giờ Đóng & Nghỉ ngơi):** Ngay khi bước sang phân đoạn này, EA ngay lập tức dọn sạch toàn bộ các lệnh BUY đang chạy để giữ tiền mặt, đồng thời tạo ra "Tường lửa" cấm mọi lệnh mới được kích hoạt cho đến kỳ theo dõi tiếp theo.

> 👉 **Tính năng thông minh:** EA phân biệt tự động: 
> - **Same-day Cycle (Chu kỳ Cùng ngày):** Giờ Mở < Giờ Đóng (Ví dụ: Mở 01:00 am -> Đóng 22:00 pm).
> - **Overnight Cycle (Chu kỳ Qua đêm):** Giờ Mở > Giờ Đóng (Ví dụ: Mở 22:00 pm -> Đóng 16:00 pm hôm sau).

---

## ⚙️ Giải thích Cài đặt Thông số (Input Parameters)

### 1. General Settings (Thiết lập Cơ bản & Quản trị Vốn)
Nhóm này chi phối hành vi Mua (Breakout vs Mua thẳng) và cách EA vào Khối lượng lệnh (Lots).

| Tham số | Mô tả và Ý nghĩa thực chiến |
|---------|---------|
| `Wait For New Day High` | Nếu đặt **`true`**, EA chạy theo dạng Breakout: Chờ giá phá lên trên Đỉnh cao nhất (Tính từ giờ Observe Start). Nếu đặt **`false`**, EA sẽ bỏ qua việc canh đỉnh và **MỞ LỆNH NGAY LẬP TỨC** khi điểm danh tới giờ "Trading Start". |
| `Trading Volume` | Chế độ đi lệnh gồm 4 tuỳ chọn: <br>• **FIXED:** Đánh khối lượng cố định (`Fixed Lots`).<br>• **MANAGED:** Đánh trượt theo số tiền gốc (`Fixed Lots Per Money`: Bỏ "X" Đôla cho mỗi "Y" Lot).<br>• **PERCENT:** Đi lệnh dựa trên `Risk Percent` (% tỷ lệ hao hụt tài khoản nếu chạm Stoploss).<br>• **MONEY:** Đi lệnh dựa trên `Risk Money` (Số USD cụ thể có thể mất đi). |
| `Risk Percent` (Cực kỳ quan trọng) | 🔥 **Lưu ý Đặc Biệt:** Nếu bạn chọn `CALC_MODE_OFF` cho StopLoss (Giao dịch kiểu Spot Hold, không cắt lỗ để chịu rung lắc mạnh): EA tính khối lượng theo trường hợp "Thị trường Sập về Điểm 0". Ví dụ bạn đặt **Risk Percent = 100**, EA sẽ đánh kích thước Lot sao cho nếu Giá trị Chỉ số về 0, bạn mất 100% số vốn (tương đương với mức dùng Đòn bẩy 1:1 trong chứng khoán cơ sở, vô cùng an toàn). |
| `Target Calc Mode` / `Stop Calc Mode` | Chọn cách đo lường TP và SL (Tính theo % sự thay đổi của Chỉ số hoặc số Points). Chuyển về **`CALC_MODE_OFF`** nếu bạn muốn thả trôi lệnh chờ đến `Close Position Hour`. |
| `Target Value` / `Stop Value` | Khoảng cách Chốt Lời / Cắt Lỗ. Cần nhập tương ứng với `Calc Mode` bạn chọn (Có thể là 5% hay 500 Point). |

### 2. Time Settings (Thiết lập Thời gian)
Kiểm soát Chu kỳ và luồng giao dịch. (Thời gian chạy theo giờ Server của phần mềm MT5).

| Tham số | Mô tả và Ý nghĩa thực chiến |
|---------|---------|
| `Observe Start Hour/Min` | Thời điểm kích hoạt máy quét Đỉnh (Phiên Á, Phiên Âu...). |
| `Trading Start Hour/Min` | Thời điểm lệnh Mua (Long) được bung ra. *Khuyến nghị để khai thác Overnight Drift: Đặt ngay sát trước cuối phiên Mỹ (Ví dụ: 22:45).* |
| `Close Positions` | Công tắc: `true` sẽ chốt toàn bộ lệnh khi hết giờ. `false` EA giữ lệnh qua hàng năm trời không đóng. |
| `Close Position Hour/Min`| Thời gian kết thúc. *Khuyến nghị cho Overnight Drift: 16:00 (Khi phiên thanh khoản Âu Mỹ sáng hôm sau chạy được 1 lúc).* |

### 3. Trailing Stop Settings (Thiết lập Khóa Lợi Nhuận)
Do thị trường phá vỡ thường có tốc độ rút nến điên cuồng, Bot có 2 công cụ dời lỗ (Hoạt động hoàn toàn độc lập với nhau).

| Tham số | Mô tả |
|---------|---------|
| **Break-Even (BE Stop)** | Công cụ bảo hiểm rủi ro: Khi giá dương một khoảng **`BE Trigger`** thì hệ thống kéo mức StopLoss (cắt lỗ) chạy thẳng lên điểm Hòa Vốn (hoàn gốc), công thêm một ít khoảng dư **`BE Buffer`** để bù trừ phí môi giới. |
| **Trailing Stop (TSL)** | Công cụ dí lệnh đuổi theo lợi nhuận. Khi giá đi dương vượt qua đoạn **`TSL Trigger`**, giá dứt khoát đẩy Mức Khóa Vốn bám theo sau giá ở vị trí **`TSL Value`**. Mỗi khi giá tiến thêm một nấc đủ một khoảng **`TSL Step Value`**, Mốc Khóa lợi nhuận lại đi lên một nấc chống quay đầu rớt giá ngược. |

---

## 🎯 Cấu hình Đặc Thể Khuyến Nghị (Configurations)

Dưới đây là thiết lập cho phong cách **Intraday Buy & Hold** chuyên bắt đà qua đêm của Index Mỹ. (Bỏ qua Breakout và sử dụng Đòn bẩy thật 1:1 không có SL để chịu được mọi rung lắc trong đêm):

1. `Wait For New Day High`: **`false`** (Bắt buộc)
2. `Trading Volume`: **`VOLUME_PERCENT`**
3. `Risk Percent`: **`100.0`** (Mức gánh rủi ro tối đa Index rớt về 0)
4. `Stop Calc Mode`: **`CALC_MODE_OFF`**
5. `Target Calc Mode`: *(Tùy chọn, nếu không muốn chốt non thì để OFF)*
6. `Trading Start Hour`: **`22:00`** (Gần cuối phiên thanh khoản cao)
7. `Close Position Hour`: **`16:00`** (Đầu phiên Mỹ chiều ngày hôm sau, hoặc chốt tùy hỉ trước khi swap phát sinh do margin broker).
