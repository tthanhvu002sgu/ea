my broker uses gmt+2 (or +3 during dst) - Rene
xauusd
stoploss: nên dùng theo % tk
fixed lot: 0.01 - vì nếu lot theo money thì không chịu được giá - cháy tk
2015 - 2026
profit: 2062
dd: 22
sharp: 2

uj cũng ngon
stoploss: theo % tk hay theo factor cũng ổn


=====
kết hơp TP + thời gian

profit giảm và dd tăng

===== 

fixed tp
1:3
dd 42
profit: 1000 

tệ hơn nhiều
-> cách tốt nhất là đóng lệnh vào khung thời gian chỉ định


# Tài liệu Chiến lược: Range Breakout Rene (Morning Range)

#### 1. Tổng quan & Triết lý (The Core Concept)
* **Tên chiến lược:** Range Breakout Rene (Morning Range Breakout).
* **Loại hình:** Breakout (Giao dịch phá vỡ vùng tích lũy).
* **Lợi thế thống kê (Edge):** Khai thác sự bùng nổ biến động sau giai đoạn tích lũy của phiên Á. Khi thị trường bước vào phiên Âu/Mỹ, dòng tiền lớn đổ vào thường đẩy giá thoát khỏi vùng giằng co đầu ngày. Chiến lược kiếm tiền bằng cách đi theo xu thế mạnh nhất ngay khi nó vừa hình thành.

#### 2. Thông số kỹ thuật (Technical Requirements)
* **Cặp tiền/Tài sản:** Vàng (XAUUSD), EURUSD, GBPUSD và các cặp tiền chính có biên độ phiên Á hẹp.
* **Khung thời gian (Timeframe):** 
    * Thu thập dữ liệu Range: **M1** (để đạt độ chính xác cao nhất).
    * Giao dịch: Theo dõi giá Tick liên tục (tương đương đa khung thời gian).
* **Công cụ/Chỉ báo:** 
    * **Range Box (Hộp giá):** Tự động xác định khung giá cao nhất/thấp nhất trong khoảng thời gian xác định.
    * **Server Time Filter:** Bộ lọc thời gian thực thi theo giờ Broker.

#### 3. Thiết lập môi trường (The Setup - Điều kiện CẦN)
* **Xác định Vùng giá:** Thị trường phải hoàn thành giai đoạn thu gọn giá (tích lũy) trong khung giờ quy định (Mặc định: 03:00 - 06:00 giờ Server).
* **Bộ lọc biên độ:** Kích thước của vùng giá (High - Low) phải nằm trong giới hạn cho phép (Ví dụ: lớn hơn 10 points và nhỏ hơn 1000 points) để loại bỏ các trường hợp phá vỡ giả do nến quá nhỏ hoặc thị trường quá biến động.

#### 4. Quy tắc vào lệnh (Entry Rules - Điều kiện ĐỦ)
* **Trigger (Điểm kích nổ):** 
    * **Lệnh BUY:** Giá **Ask** hiện tại vượt cao hơn đường **Range High**.
    * **Lệnh SELL:** Giá **Bid** hiện tại vượt thấp hơn đường **Range Low**.
* **Bộ lọc nhiễu (Filters):** 
    * **Max Total Trades:** Chỉ vào tối đa $X$ lệnh mỗi ngày (Ví dụ: 2 lệnh).
    * **Trading Window:** Chỉ vào lệnh sau khi khung giờ đo Range kết thúc và trước khi đến giờ xóa lệnh chờ (`InpDeleteOrderHour`).
    * **Directional Limit:** Giới hạn số lệnh Long/Short riêng biệt để tránh bị "quét" hai đầu liên tục.

#### 5. Thoát lệnh & Quản trị rủi ro (Exit & Risk Management)
* **Stop Loss (SL):** 
    * **Mặc định:** Đặt tại biên đối diện của Range Box (Mua ở High, SL ở Low).
    * **Tùy chọn:** Đặt theo hệ số nhân với Range (Ví dụ: 1.0 * biên độ Range) hoặc theo số Points cố định.
* **Take Profit (TP):** 
    * **Tỷ lệ R:R:** Chốt lời tại mức giá đạt tỷ lệ rủi ro/lợi nhuận là **1:2** (hoặc tùy cấu hình).
    * **Thời gian:** Tự động đóng toàn bộ vị thế tại giờ kết thúc ngày giao dịch (Mặc định: 18:00 Server).
* **Trailing Stop:** (Chiến lược hiện tại tập trung vào chốt lời mục tiêu cố định hoặc theo thời gian để tối ưu hóa xác suất).
* **Quy mổ vị thế (Position Sizing):** 
    * **Fixed Lot:** Khối lượng cố định (Ví dụ: 0.1 Lot).
    * **Risk Money:** Tự động tính số Lot sao cho nếu chạm SL sẽ mất đúng số tiền chỉ định (Ví dụ: Rủi ro $50/lệnh).
