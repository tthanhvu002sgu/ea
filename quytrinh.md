# QUY TRÌNH PHÁT TRIỂN & TỐI ƯU HÓA EA CHUYÊN NGHIỆP CÙNG AI

Quy trình 4 bước hiện tại của bạn (Hỏi ý tưởng -> Code -> Backtest -> Tối ưu) là một sự khởi đầu rất tốt và hợp lý. Tuy nhiên, để biến một ý tưởng thành một **hệ thống giao dịch có thể kiếm tiền thực tế (live trading)** và **tránh được bẫy curve-fitting (tối ưu hóa quá mức)**, chúng ta cần một quy trình chuẩn hóa mang tính định lượng (quantitative) và khắt khe hơn.

Dưới đây là **Quy trình 7 Bước Chuyên Nghiệp** dành cho Algo Trader khi làm việc với AI (Gemini & Antigravity), kèm theo các **Prompt Chuẩn** để bạn copy-paste.

---

## BƯỚC 1: HÌNH THÀNH Ý TƯỞNG & TÌM KIẾM LỢI THẾ (HYPOTHESIS)
*Thay vì hỏi AI "Cho tôi một chiến lược", hãy yêu cầu AI phân tích một sự mất cân bằng của thị trường (market inefficiency).*

**Mục tiêu:** Xác định rõ Edge (Lợi thế thống kê) của chiến lược trước khi viết code. Chiến lược này kiếm tiền từ đâu? (Sự hoảng loạn của phe bán? Cú nén phá vỡ phiên Á? Đảo chiều do quá bán?)

📌 **Prompt cho Gemini:**
> "Tôi đang tìm kiếm một lợi thế thống kê (statistical edge) trên cặp [XAUUSD / EURUSD] ở khung thời gian [H1 / M15]. Hãy đóng vai là một Quant Trader chuyên nghiệp, đề xuất 3 ý tưởng chiến lược dựa trên [Giao dịch theo phiên / Đảo chiều trung bình / Vận tốc xu hướng]. Với mỗi ý tưởng, hãy giải thích rõ: 
> 1. Logic cốt lõi: Tại sao nó hoạt động về mặt tâm lý thị trường?
> 2. Bộ lọc nhiễu (Filter) lý tưởng nhất để tránh tín hiệu giả.
> 3. Rủi ro lớn nhất của chiến lược này trong thực tế là gì?"

---

## BƯỚC 2: CHUẨN HÓA LOGIC THÀNH QUY LUẬT CƠ HỌC (MECHANICAL RULES)
*Không đưa một ý tưởng mơ hồ cho AI Coder (Antigravity). Bạn phải ép AI mô tả chi tiết từng luồng xử lý trước khi code.*

**Mục tiêu:** Lấy ý tưởng tốt nhất từ Bước 1 và yêu cầu Gemini viết dưới dạng Pseudo-code rõ ràng.

📌 **Prompt cho Gemini:**
> "Tôi chọn ý tưởng số [X]. Bây giờ, hãy trình bày chiến lược này dưới dạng các quy luật cơ học (Mechanical Rules) rõ ràng, tuyệt đối không dùng cảm tính, để tôi đưa cho lập trình viên MT5:
> 1. Setup (Điều kiện môi trường ).
> 2. Trigger (Kích hoạt lệnh ).
> 3. Stoploss ban đầu (Dựa trên ATR / Đỉnh Đáy gần nhất / Giá trị Tĩnh).
> 4. Take Profit & Trailing Stop (Cách bảo vệ lợi nhuận).
> 5. Cài đặt bổ sung (Khung giờ giao dịch giới hạn trong ngày, spread tối đa).
> Hãy trình bày thật ngắn gọn, gạch đầu dòng rõ ràng theo cấu trúc trên."

---

## BƯỚC 3: CODE EA VỚI ANTIGRAVITY (AI CODER)
*Sử dụng Antigravity để chuyển đổi bộ luật thành code MQL5. Luôn yêu cầu AI code theo chuẩn modular để dễ tối ưu (Optimize).*

**Mục tiêu:** Tạo ra một EA ít lỗi, nhẹ về hiệu năng backtest, và phơi bày toàn bộ tham số quan trọng ra ngoài Input 

📌 **Prompt cho Antigravity:**
> "Hãy lập trình một EA MT5 (MQL5) chuyên nghiệp dựa trên các quy luật giao dịch sau:
 
> **Yêu cầu kỹ thuật thiết kế bắt buộc:**
> 1. Khai báo TẤT CẢ các thông số bằng từ khóa `input group` để tôi có thể Optimize trong MT5.
> 2. Sử dụng thư viện `#include <Trade\Trade.mqh>`.
> 3. Tối ưu hóa hiệu năng: Các toán tử logic nặng chỉ được chạy 1 lần khi có nến mới hình thành (sử dụng hàm kiểm tra New Bar), không chạy trên mỗi tick.
> 4. Tránh lỗi OrderSend Error: Thêm logic kiểm tra xem cấu hình Stoploss có vi phạm SYMBOL_TRADE_STOPS_LEVEL của sàn không.
> 5. Hãy in Print log chi tiết ở các mốc quan trọng (Ví dụ: 'Bỏ qua tín hiệu mua vì ngoài giờ giao dịch' hoặc 'Trend đang báo Sell, bỏ qua Buy') để tôi dễ dàng debug quá trình EA ra quyết định."

---

## BƯỚC 4: INITIAL BACKTEST (КИỂM THỬ BAN ĐẦU - IN-SAMPLE)
*Tuyệt đối không sử dụng tính năng Optimization ngay lập tức. Hãy chạy test để xác nhận logic code.*

**Hành động trên MT5:**
1. **Chia dữ liệu:** Lấy dữ liệu từ (ví dụ) 2018 - 2022 làm dữ liệu test (In-Sample). TUYỆT ĐỐI GIẤU dữ liệu 2023 - 2024 không cho EA thấy vào thời điểm này.
2. Mode test: Chọn `Every tick based on real ticks` (bắt buộc với các EA scalping hoặc giao dịch phiên).
3. Đặt **Spread tự do (Custom)** ở mức cao hơn điều kiện bình thường khoảng 20% để mô phỏng trượt giá.
4. **Đánh giá sơ bộ:** EA có đang vào lệnh đúng những gì mình nghĩ không? (Nhìn bằng chế độ Visual Mode). Nếu đường đồ thị In-sample đi xuống cắm đầu liên tục, hãy quay lại Bước 1.

---

## BƯỚC 5: PARAMETER OPTIMIZATION (TỐI ƯU HÓA) - BƯỚC QUAN TRỌNG NHẤT
*Đây là nơi 99% trader mắc lỗi Curve-fitting (EA mông má cho đẹp trên quá khứ nhưng tạch ở tương lai).*

**Kỹ thuật chuẩn:**
1. **Rào cản tự do:** Đừng cho MT5 tối ưu hóa *mọi* tham số. Hãy cố định các thông số có tính bản chất (như giờ mở cửa phiên Âu), chỉ tối ưu biến số linh hoạt như Chu kỳ MA (20 đến 100) hoặc Hệ số ATR (1.0 đến 3.0).
2. **Tab Optimization:** Chọn chế độ `Fast (Genetic algorithm)`.
3. **Tiêu chí chọn (Custom Max):** KHÔNG BAO GIỜ chọn thông số có Lợi nhuận cao nhất.
   - Hãy chọn kết quả có **Recovery Factor > 3.0** (Tỉ lệ phục hồi).
   - Tỉ lệ rớt vốn **Max Drawdown < 15%**.
   - **Số lượng giao dịch (Trades) > 300 lệnh**. (Nếu EA chỉ vào 20 lệnh suốt 5 năm, kết quả đó là do may mắn, không phải xác suất).
4. Phân tích cụm (Neighborhood check): Sử dụng tab 2D/3D Optimization Graph. Nếu MA=50 lãi lớn, nhưng MA=49 và MA=51 lại lỗ nặng -> Vứt bỏ thông số đó ngay. Một thông số tốt phải nằm giữa một vùng "đồi xanh" bằng phẳng.

---

## BƯỚC 6: OUT-OF-SAMPLE & WALK-FORWARD (KIỂM THỬ THỰC TẾ TRÊN DỮ LIỆU MÙ)
*Giờ khắc sự thật: Liệu bộ thông số vừa tìm được có dự đoán được tương lai?*

**Hành động:**
1. Lấy thông số tối ưu tốt nhất từ Bước 5 áp vào EA.
2. Chạy Backtest với bộ dữ liệu đã giấu đi ở Bước 4 (Năm 2023 - 2024).
3. **Đánh giá:**
   - Đồ thị ở giai đoạn 2023-2024 có tiếp tục đi lên với góc nghiêng tương đương giai đoạn 2018-2022 không?
   - Max Drawdown có giữ được loanh quanh mức cũ không?
   - 👉 **Nếu CÓ:** Chúc mừng bạn, bạn đang cầm trong tay một EA "sống".
   - 👉 **Nếu ĐỒ THỊ GÃY / TÀI KHOẢN CHÁY:** Lợi thế thống kê của bạn đã chết, hoặc bạn đã bị Curve-fitting ở Bước 5. Không được quyền chỉnh sửa thông số để nó đẹp lại. **Vứt EA đi, làm lại từ Bước 1.**

---

## BƯỚC 7: PAPER TRADING & MONITORING (CHẠY DEMO & THEO DÕI)
*Thị trường thật có slippage (trượt giá), latency (độ trễ VPS), và swap (phí qua đêm) biến động.*

**Hành động:**
1. Triển khai EA lên tài khoản Demo (hoặc tài khoản Live siêu nhỏ/Cent) chạy 24/7 trên VPS.
2. Để nó chạy trong ít nhất 4 tuần.
3. So sánh các lệnh do tài khoản Real/Demo đánh với lệnh trong Backtest (ở đúng khoảng thời gian 4 tuần đó). Có lệnh nào backtest vào nhưng thực tế không vào? Lệnh nào chốt lời/cắt lỗ lệch giá nhau nghiêm trọng?

📌 **Prompt cho Antigravity (Bảo trì & Gỡ Lỗi):**
> "Trong quá trình đưa EA chạy thực tế (Live), tôi phát hiện ra EA gặp vấn đề: [Mô tả vấn đề - ví dụ: Xảy ra trượt giá lớn khiến lệnh bị kẹt / EA bắn 3 lệnh liên tiếp cùng một lúc / Nó không chịu dời Stoploss]. 
> Đây là đoạn trích xuất từ log MT5 (Journal tab): 
> [DÁN TEXT LOG VÀO ĐÂY]
> Hãy giúp tôi phân tích nguyên nhân tại sao EA hành xử như vậy ở môi trường Live, và cập nhật lại file mã nguồn để xử lý dứt điểm trường hợp này (thêm timeout, kiểm tra slippage, v.v.)."
