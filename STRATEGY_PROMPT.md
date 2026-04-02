
Hãy sáng tạo một chiến lược giao dịch tự động  hoàn toàn mới. Chỉ cần đưa ra logic, không cần code.

## BỐI CẢNH

- Loại tài sản mục tiêu: [Forex / Vàng XAUUSD / Chỉ số / Crypto / Tất cả]
- Phong cách giao dịch: [Scalping / Day Trading / Swing Trading / Position Trading]
- Khung thời gian chính: [M1 / M5 / M15 / M30 / H1 / H4 / D1]
- Nền tảng: MQL5 (MetaTrader 5)
- Mức rủi ro chấp nhận: [Thấp / Trung bình / Cao]
- Mục tiêu R:R tối thiểu: [1:1 / 1:1.5 / 1:2 / 1:3]

## YÊU CẦU BẮT BUỘC

### A. Cấu trúc Output
Chia chiến lược thành **4-6 Components**, mỗi Component giải quyết **đúng 1 phase** trong chuỗi logic tổng thể:

1. **Component 1: Phase Lọc Môi Trường (Regime Filter)**
   → Trả lời: "Thị trường hiện tại có phù hợp để giao dịch không?"
   → Phải có điều kiện ON/OFF rõ ràng (boolean).

2. **Component 2: Phase Xác Định Hướng (Directional Bias)**
   → Trả lời: "Phe nào đang kiểm soát? Buy hay Sell?"
   → Phải dựa trên chỉ báo có giá trị số học cụ thể, không dựa trên nhận định chủ quan.

3. **Component 3: Phase Chờ Đợi Vùng Giá (Value Area / Pullback)**
   → Trả lời: "Giá đã lùi về vùng có lợi thế chưa?"
   → Phải có vùng giá cụ thể (upper/lower bound) được tính bằng công thức.

4. **Component 4: Phase Kích Hoạt (Entry Trigger)**
   → Trả lời: "Chính xác lúc nào bấm nút mua/bán?"
   → Phải là điều kiện có thể kiểm tra bằng toán học (so sánh giá trị, giao cắt, v.v.).
   → KHÔNG được dùng mô tả mơ hồ như "khi thấy nến đẹp", "khi momentum mạnh".

5. **Component 5: Phase Quản Trị Rủi Ro Ban Đầu (Initial Risk)**
   → Trả lời: "Stop Loss đặt ở đâu? Xác định stop loss như thế nào? Lot Size bao nhiêu?"
   

6. **Component 6: Phase Quản Lý Lệnh Mở (Trade Management)**
   → Trả lời: "Khi nào dời SL? Khi nào chốt lời? Khi nào thoát?"
   → Phải có logic Break-even, Trailing Stop, hoặc Take Profit động.
   → Trailing phải tuân thủ quy tắc 1 chiều (chỉ dời theo hướng có lợi).

### B. Với MỖI Component, phải cung cấp đầy đủ:

| Mục | Yêu cầu |
|-----|---------|
| **Mục đích** | 1 câu giải thích Component này giải quyết vấn đề gì |
| **Chỉ báo sử dụng** | Tên chỉ báo + chu kỳ + khung thời gian |
| **Công thức toán học** | Viết rõ công thức dạng toán (LaTeX hoặc pseudocode) |
| **Điều kiện Buy** | Biểu thức boolean cụ thể cho lệnh Long |
| **Điều kiện Sell** | Biểu thức boolean cụ thể cho lệnh Short |
| **Input Parameters** | Danh sách tham số cho phép người dùng tùy chỉnh |
| **Edge Cases** | Các trường hợp biên cần xử lý (chia cho 0, thiếu dữ liệu, gap giá...) |

### C. Kiểm tra Logic (Bắt buộc)

Sau khi trình bày xong các Components, hãy tự kiểm tra:

1. **Test Mâu thuẫn**: Có tồn tại trường hợp Component 2 nói Buy nhưng Component 3 nói vùng Sell không?
2. **Test Deadlock**: Có tồn tại trường hợp tất cả điều kiện cùng TRUE nhưng không có lệnh nào được đặt không?
3. **Test Tần suất**: Ước tính mỗi ngày/tuần chiến lược tạo ra bao nhiêu tín hiệu?
4. **Test Biên**: Điều gì xảy ra khi ATR = 0, Volume = 0, hoặc đầu phiên thiếu dữ liệu?


### D. Trực quan hóa

Mô tả cách hiển thị tín hiệu trên biểu đồ:
- Mũi tên Buy/Sell tại điểm vào lệnh
- Đường SL/TP
- Highlight vùng giá trị (nếu có)
- Màu sắc phân biệt Entry vs Exit

