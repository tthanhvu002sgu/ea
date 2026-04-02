XAUUSD (filter h4 ema50)
H1
2019 -> current
profit factor: 1.3
sharp: 1.24
profit: 4053
max drawdown: 31.27%
lot: 0.02
không bị ảnh hưởng bởi giai đoạn sideway -> chỉ tăng trưởng chậm lại và nhiều lệnh thua hơn 
bùng nổ từ giai đoạn 2024


USDJPY (filter d1 ema 100)
H1
2019 -> current
profit factor: 1.4
recovery factor: 6
sharp: 2.13
profit: 1019
max drawdown: 7.94%
lot: 0.02 -> có thể tăng lên 0.05 để tăng profit


DE40
H1 (filter H4)
2019 -> current
profit factor: 1.12
recovery factor: 2.18
sharp: 0.76
profit: 679
max drawdown: 18
lot: 0.1

H1 (filter D1)
profit: 715
max drawdown: 26


US500
H1 (filter D1): hòa vốn
H4 (filter D1): hòa vốn
nhưng drawdown thấp -> có thể cải thiện thêm



vốn

XAUUSD: 500 (0.02 lot) -> mdd 50%
USDJPY: 300 (0.05 lot) -> mdd 38%



=============================

OPTIMIZATION

session filter

profit: 4000 -> 3900
dd: 31 -> 23

adx: phế


------------

session + be 
profit: 3900 -> 3500
dd: 23 -> 26

===============

session + cvd

xauusd
profit: 2394
dd: 17.69

hoạt động tốt với xauusd (giảm dd) nhưng không tốt với uj (profit thấp, dd cao)




### TÀI LIỆU CHIẾN LƯỢC: THE VOLATILITY RIDER

#### 1. Tổng quan & Triết lý (The Core Concept)
* **Tên chiến lược:** The Volatility Rider (Kẻ cưỡi sóng biến động).
* **Loại hình:** Trend Following (Theo dấu xu hướng) & Momentum Breakout (Phá vỡ động lượng).
* **Lợi thế thống kê (Edge):** Khai thác tính chất "quán tính" của thị trường. Khi giá phá vỡ đỉnh/đáy của 20 phiên gần nhất (Donchian Channel) trong một xu hướng lớn (EMA 100), xác suất giá tiếp tục di chuyển theo hướng đó cao hơn là đảo chiều. Chiến lược này không dự báo đỉnh đáy mà chấp nhận vào muộn để "ăn" đoạn giữa chắc chắn nhất.

#### 2. Thông số kỹ thuật (Technical Requirements)
* **Cặp tiền/Tài sản:** Phù hợp nhất với các cặp tiền có xu hướng rõ ràng (GBPUSD, EURJPY) hoặc Vàng (XAUUSD).
* **Khung thời gian (Timeframe):** * Lọc xu hướng: D1 (Daily).
    * Vào lệnh & Quản lý: H1 (Hourly).
* **Công cụ/Chỉ báo:** * **EMA 100:** Xác định hướng chủ đạo dài hạn.
    * **Donchian Channel (20):** Xác định vùng tích lũy và điểm phá vỡ.
    * **ATR (14):** Đo lường độ biến động để đặt chặn lỗ động.

#### 3. Thiết lập môi trường (The Setup - Điều kiện CẦN)
* **Trạng thái Bullish (Mua):** Nến ngày hôm trước đóng cửa phía trên đường EMA 100.
* **Trạng thái Bearish (Bán):** Nến ngày hôm trước đóng cửa phía dưới đường EMA 100.
* Thị trường cần có sự tích lũy (giá đi ngang trong kênh Donchian) trước khi có tín hiệu bùng nổ.

#### 4. Quy tắc vào lệnh (Entry Rules - Điều kiện ĐỦ)
* **Trigger (Điểm kích nổ):** Sử dụng lệnh chờ (Pending Order).
    * **Buy Stop:** Đặt tại mức giá cao nhất của 20 nến H1 trước đó.
    * **Sell Stop:** Đặt tại mức giá thấp nhất của 20 nến H1 trước đó.
* **Bộ lọc nhiễu (Filters):** * Chỉ đặt lệnh khi xu hướng D1 đồng nhất với hướng phá vỡ.
    * Lệnh chờ được cập nhật giá vào (Modify) tại mỗi nến H1 mới để bám sát vùng tích lũy.

#### 5. Thoát lệnh & Quản trị rủi ro (Exit & Risk Management)
* **Stop Loss (SL):** * Mua: Điểm vào - $(1.5 \times ATR)$.
    * Bán: Điểm vào + $(1.5 \times ATR)$.
* **Take Profit (TP):** Không đặt TP cố định. Chiến lược hướng tới việc gồng lời tối đa cho đến khi xu hướng đảo chiều.
* **Trailing Stop (Chandelier Exit):** * Dời SL theo nguyên tắc: $Giá cao nhất (từ khi vào lệnh) - (3.0 \times ATR)$. 
    * Chỉ dời theo hướng có lợi cho lệnh, không bao giờ dời ngược lại.
* **Quy mô vị thế (Position Sizing):** Mặc định 0.01 Lot (Có thể tùy chỉnh theo InpLotSize).

---

### Câu hỏi kiểm chứng & Phơi bày sai sót

**1. Tại sao lại dùng D1 để lọc xu hướng cho lệnh H1, liệu có quá chậm không?**
* *Trả lời:* Có, đây là sự đánh đổi. Dùng D1 giúp loại bỏ gần như toàn bộ nhiễu (noise) của các khung thời gian nhỏ, đảm bảo bạn luôn đứng về phía "cá mập" dài hạn. Tuy nhiên, khi xu hướng D1 đảo chiều, EA có thể mất vài nến H1 chịu lỗ trước khi bộ lọc này phản ứng kịp.

**2. Điều gì xảy ra nếu thị trường đi ngang (Sideway) trong biên độ rộng?**
* *Trả lời:* Đây là "khắc tinh" của EA này. Trong thị trường sideway, giá liên tục quét qua đỉnh/đáy 20 nến rồi rút chân, EA sẽ liên tục khớp Buy Stop/Sell Stop và bị dính SL hoặc Trailing Stop ngắn. Đây là giai đoạn tài khoản sẽ bị "bào" mòn dần (Drawdown).

**3. Tại sao lại dùng Trailing Stop $3.0 \times ATR$ mà không phải là một tỷ lệ R:R cố định?**
* *Trả lời:* $3.0 \times ATR$ tạo ra một "khoảng thở" đủ rộng để tránh bị quét lệnh bởi những đợt hồi giá nhẹ (retracement). Tuy nhiên, sai sót là nếu thị trường đảo chiều gắt (V-shape), bạn sẽ trả lại một phần lợi nhuận khá lớn (tương đương 3 ATR) trước khi lệnh được đóng.

