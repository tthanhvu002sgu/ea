# Tài liệu Chiến lược: Market Structure MTF Strategy

#### 1. Tổng quan & Triết lý (The Core Concept)
* **Tên chiến lược:** Market Structure MTF Strategy (Vùng cấu trúc đa khung thời gian).
* **Loại hình:** Trend Following (Theo xu hướng) kết hợp Cấu trúc thị trường (Zones).
* **Lợi thế thống kê (Edge):** Khai thác tính chu kỳ và sự tôn trọng các vùng đỉnh/đáy (Pivot) trong quá khứ. Chiến lược chỉ giao dịch thuận chiều với xu hướng dài hạn (D1) và tìm điểm vào lệnh tối ưu khi giá hồi quy (Retracement) về các vùng cấu trúc quan trọng, giúp đạt tỷ lệ Winrate ổn định và bảo vệ vốn tốt qua cơ chế quản lý lệnh theo từng vùng riêng biệt (DCA per Zone).

#### 2. Thông số kỹ thuật (Technical Requirements)
* **Cặp tiền/Tài sản:** Mọi cặp tiền có cấu trúc rõ ràng (Vàng, EURUSD, GBPUSD...).
* **Khung thời gian (Timeframe):** 
    * **Xác định xu hướng chính:** D1 (Đồ thị ngày).
    * **Xác định vùng vào lệnh:** Khung thời gian hiện tại (H1, H4, M15...).
* **Công cụ/Chỉ báo:** 
    * **EMA 30 (D1):** Làm bộ lọc xu hướng chủ đạo.
    * **Pivot High/Low (Swing):** Thuật toán tự động quét lịch sử nến (Lookback) để xác định các đỉnh/đáy thực sự.

#### 3. Thiết lập môi trường (The Setup - Điều kiện CẦN)
* **Xác định Xu hướng lớn (EMA D1 Filter):**
    * Chỉ tìm kiếm lệnh **BUY** khi giá đóng cửa nến D1 nằm **TRÊN** đường EMA 30.
    * Chỉ tìm kiếm lệnh **SELL** khi giá đóng cửa nến D1 nằm **DƯỚI** đường EMA 30.
* **Xây dựng Vùng vùng (Build Zones):** Hệ thống tự động xác định các vùng Hỗ trợ (Support) từ các Pivot Low và vùng Kháng cự (Resistance) từ các Pivot High gần nhất.

#### 4. Quy tắc vào lệnh (Entry Rules - Điều kiện ĐỦ)
* **Trigger (Điểm kích nổ):** 
    * **BUY:** Vào lệnh Market ngay khi giá hồi về chạm ngưỡng **Entry Level** của vùng Hỗ trợ (Tính toán: `pivotLow + 50.0% * Biên độ tham chiếu`).
    * **SELL:** Vào lệnh Market ngay khi giá hồi về chạm ngưỡng **Entry Level** của vùng Kháng cự (Tính toán: `pivotHigh - 50.0% * Biên độ tham chiếu`).
* **Bộ lọc nhiễu (Filters):** 
    * **DCA per Zone:** Mỗi vùng Support/Resistance chỉ được mở tối đa **1 lệnh** duy nhất. Nếu lệnh tại vùng đó vẫn đang mở, hệ thống sẽ không vào thêm.
    * **Max Positions:** Tổng số lệnh đang mở trên toàn hệ thống không vượt quá giới hạn (Mặc định: 2 lệnh).
    * **New Bar Execution:** Chỉ quét tín hiệu và kiểm tra điều kiện khi nến mới được hình thành.

#### 5. Thoát lệnh & Quản trị rủi ro (Exit & Risk Management)
* **Stop Loss (SL):** 
    * Lệnh BUY: Đặt phía dưới giá thấp nhất của Pivot Low + một khoảng đệm (Buffer).
    * Lệnh SELL: Đặt phía trên giá cao nhất của Pivot High + một khoảng đệm (Buffer).
* **Take Profit (TP):** 
    * Chốt lời theo tỷ lệ Risk:Reward cố định (Mặc định **1:1.25**). Khoảng cách TP được tính tự động dựa trên độ rộng của Stop Loss.
* **Trailing Stop:** Không sử dụng (Hệ thống ưu tiên kết thúc lệnh tại TP/SL cố định).
* **Quy mổ vị thế (Position Sizing):** 
    * Sử dụng khối lượng cố định (**Fixed Lot**) cho mỗi lệnh giao dịch (Mặc định 0.01 Lot).
