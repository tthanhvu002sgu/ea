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


xauusd - peperstone
20 - 26
fixed lot : 0.01
stoploss: factor 1
profit:1723
dd: 19%

xauusd - pepperstone
20 - 26
fixed lot: 0.01
stoploss: % balance
profit: 1743
dd: 14%   
=> giống với EA của Rene

input:
range: 5h - 13h
close long: 23h
close short: 18h

xauusd - mt5
20 - 26
fixed lot: 0.01
stoploss: 5 % balance 
profit: 1884
dd: 15.72%   

xauusd peperstone
20 - 26
fixed lot: 0.01
stoploss: 5 % balance 
1949
15.16%

=============

input 
range 0 - 7h30
close long: 18h
close short: 18h
fixed lot: 0.01

uj
profit: 75
dd: 17,69%

====

input
range 19h - 3h
close long: 23h
close short: 17h
fixed lot: 0.01

uj
profit: 107
dd: 21.28%
===
v2.1 bổ sung thêm tính năng cho phép xác định range và đóng lệnh qua ngày -> đã backtest với cùng thông số cho kết quả giống nhau

giả sử range start: 19h0
range end: 2h0
close long: 1h 
close short: 17h

thì hệ thống hiểu sao? 

=> close long sẽ bị lỗi vì cơ chế reset day => nhưng tốt nhất là đóng lệnh trong ngày


v2.2 đã hỗ trợ chỉ mở 1 lệnh trong ngày (backtest cùng input với v2.1 cho kết quả giống nhau)

nhưng nếu chỉ mở 1 lệnh thôi thì dd giảm và profit tăng


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
    * **Tùy chọn:** Đặt theo hệ số nhân với Range (Ví dụ: 1.0 * biên độ Range), theo số Points cố định, hoặc cắt lỗ theo **Phần trăm (%) Tài khoản** (STOP_ACCOUNT_PERCENT).
* **Take Profit (TP):** 
    * **Tỷ lệ R:R:** Chốt lời tại mức giá đạt tỷ lệ rủi ro/lợi nhuận là **1:2** (hoặc tùy cấu hình).
    * **Thời gian:** Tự động đóng vị thế tại khung giờ tùy chọn. Đã nâng cấp để có thể **phân tách khung giờ đóng lệnh Buy và Sell riêng biệt** (Ví dụ: Close Long lúc 18:00, Close Short lúc 19:00).
* **Trailing Stop:** (Chiến lược hiện tại tập trung vào chốt lời mục tiêu cố định hoặc theo thời gian để tối ưu hóa xác suất).
* **Quy mổ vị thế (Position Sizing):** 
    * **Fixed Lot:** Khối lượng cố định (Ví dụ: 0.1 Lot).
    * **Risk Money:** Tự động tính số Lot sao cho nếu chạm SL sẽ mất đúng số tiền chỉ định (Ví dụ: Rủi ro $50/lệnh).

    
2. Về việc thiết lập giờ xóa lệnh chờ (Delete Pending Orders): Cách thiết lập giờ xóa lệnh độc lập hoàn toàn với việc đóng vị thế (Close Position). Bạn điều chỉnh qua 2 tham số:

InpDeleteOrderHour (Giờ xóa lệnh)
InpDeleteOrderMinute (Phút xóa lệnh)
Không, giờ xóa lệnh không bắt buộc phải trùng với giờ đóng lệnh (Close Positions). Bảng thông số cung cấp cài đặt thời gian hoàn toàn riêng biệt:

Xóa lệnh chờ (Pending orders): Sử dụng biến InpDeleteOrderHour & InpDeleteOrderMinute.
Đóng lệnh Buy đã khớp: Sử dụng biến InpCloseLongHour & InpCloseLongMinute.
Đóng lệnh Sell đã khớp: Sử dụng biến InpCloseShortHour & InpCloseShortMinute.
Ví dụ ứng dụng cho việc không trùng giờ: Đôi khi bạn muốn xóa các vị thế lệnh CHỜ Breakout không khớp sớm vào cuối phiên Âu (vd 23h00) vì tin rằng giá sẽ không còn xung lượng Breakout nữa. Nhưng bạn vẫn muốn tiếp tục GỒNG các lệnh đang chạy (đã khớp) và chỉ đóng các lệnh đang mở này vào cuối phiên Mỹ (vd 02h00 sáng). Việc tách biệt các biến này cho phép bạn làm điều đó một cách linh hoạt.


giả sử range được xác định từ 0h -> 7h, người dùng tắt máy đến 7h mới mở thì?

nếu mở từ lúc 6h thì?

nếu mở từ 8h thì?

1. Nếu mở máy đúng lúc 7:00 (Ngay lúc hết Range)
Hành động của EA: Ngay khi có "Tick" giá đầu tiên lúc 7:00, EA kiểm tra điều kiện currentTime >= endTime. Nó sẽ lập tức tính toán Range từ 0h-7h.

Thực thi: EA vẽ Box lên màn hình và đặt 2 lệnh chờ Buy Stop / Sell Stop.

Kết quả: Hoàn hảo. Đây là trạng thái lý tưởng nhất.

2. Nếu mở máy lúc 6:00 (Trong khi Range đang chạy)
Hành động của EA: EA sẽ chạy hàm OnInit và báo trạng thái Waiting for Range. Vì chưa đến 7:00 (endTime), EA sẽ không làm gì cả.

Thực thi: Nó chỉ ngồi đợi. Đúng 7:00, nó mới thực hiện bước tính toán và đặt lệnh như kịch bản trên.

Kết quả: Tốt. Bạn chỉ tốn thêm tiền điện hoặc tài nguyên máy tính để EA "ngồi chơi" trong 1 tiếng.

3. Nếu mở máy lúc 8:00 (Muộn 1 tiếng so với kế hoạch)
Đây là kịch bản nguy hiểm nhất vì logic xử lý lệnh Market của EA này.

Hành động của EA: Khi bật máy lúc 8:00, EA thấy currentTime (8:00) đã lớn hơn endTime (7:00). Nó lập tức tính Range 0h-7h.

Xung đột thực tế:

Trường hợp A: Từ 7h đến 8h giá vẫn chạy trong Range. EA sẽ đặt 2 lệnh Pending như bình thường. (Vẫn ổn).

Trường hợp B: Từ 7h đến 8h giá đã bùng nổ (Breakout) và đang ở rất xa biên của Box. EA kiểm tra thấy Ask > preBuyEntry, nó sẽ thực hiện lệnh Market Buy ngay lập tức (xem hàm CheckBreakoutAndTrade).

Kết quả: Rủi ro cao. Bạn bị vào lệnh đuổi (Late Entry). Lúc này khoảng cách dừng lỗ (SL) sẽ rất xa, và tỷ lệ R:R của bạn bị hỏng hoàn toàn. Lệnh này có thể vừa khớp xong thì thị trường điều chỉnh.


1. Trả lời: Khi khớp lệnh thì có xóa lệnh ngược lại không? Vì sao?

Hiện tại trong mã nguồn, EA KHÔNG tự động xóa lệnh ngược lại khi một phía bị khớp. Khi sự kiện Breakout xảy ra, EA kiểm tra điều kiện và nếu hợp lệ, nó sẽ gửi đẩy cả 2 lệnh chờ (Buy Stop và Sell Stop) lên sàn (Broker). Khi lệnh Buy Stop khớp, lệnh Sell Stop vẫn nằm trên hệ thống của sàn chờ đến khi chạm giờ xóa lệnh (InpDeleteOrderHour).

Vì sao lại như vậy? Trong các mô hình giao dịch Range Breakout, đây thường được xem là tính năng để đối phó với Phá vỡ giả (Fakeout).

2. Trả lời thắc mắc: Giả sử Buy và Sell cùng khớp, thì đóng lệnh theo những trường hợp nào? Nếu cả 2 lệnh cùng khớp (trường hợp InpMaxTotalTrades >= 2), thì EA sẽ đóng các lệnh này qua 3 trường hợp tự động sau đây (bạn đang kể thiếu trường hợp chốt lời):

Chạm Cắt Lỗ (Stoploss): Được tính toán dựa trên InpStopMode lúc EA mới xác định Range.
Chạm Chốt Lời (Take Profit): Nếu biến InpTargetMode của bạn khác TARGET_OFF (ví dụ bạn để là TARGET_POINTS hoặc tỷ lệ R:R qua TARGET_RISK_REWARD).
Đóng theo Thời gian (Time-based Close): Khi tính năng InpClosePositions được bật bằng true, nếu giá cứ đi ngang mà không chạm SL hay TP, đến mốc InpCloseLongHour nó sẽ tự cắt lệnh thẳng tay lệnh Buy hiện có, và đến InpCloseShortHour thì cắt lệnh Sell hiện có.

### 6. Bối cảnh là then chốt (Khi nào chiến lược này sụp đổ?)

Mọi dự đoán đều dựa trên một tập hợp các giả định. Khi môi trường hoặc dữ liệu thay đổi, mô hình có thể sụp đổ. Nhà định lượng luôn đặt câu hỏi về điều kiện biên mà tại đó kết quả không còn đúng nữa. Vậy đâu là bối cảnh mà tại đó chiến lược Morning Range Breakout sẽ sụp đổ hoặc tạo ra chuỗi thua lỗ (Drawdown) lớn?

Dưới đây là các bối cảnh "độc hại" cần nhận diện để tránh giao dịch (hoặc giảm thiểu rủi ro):

**1. Biên độ phiên Á quá rộng (Exhausted Range):**
* **Hiện tượng:** Khoảng cách giữa High và Low của phiên Á lớn hơn mức bình thường (ví dụ: lớn hơn 70% ATR trung bình của ngày). 
* **Hệ quả:** Nghĩa là lực lượng mua/bán đã "tiêu hao" hết động lượng ngay trong phiên Á. Khi breakout xảy ra ở phiên Âu, giá không còn "năng lượng" (động lượng) để đi tiếp, dẫn đến phá vỡ giả (False Breakout) và quay đầu chạm Stop Loss.
* **Cách phòng tránh:** Cài đặt thông số `Max Range` (Biên độ hộp tối đa). Nếu Range > ngưỡng này -> Không giao dịch.

**2. Biên độ phiên Á quá hẹp (Micro Range):**
* **Hiện tượng:** Range dao động cực kỳ hẹp.
* **Hệ quả:** Dễ sinh ra nhiễu (Noise). Một đợt giãn Spread hoặc một lệnh lớn ngẫu nhiên cũng đủ kích hoạt Entry (kích hoạt Breakout), sau đó giá lập tức chui lại vào hộp.
* **Cách phòng tránh:** Set up thông số `Min Range`. Nếu Range < ngưỡng này -> Dừng hệ thống.

**3. Ngày có tin tức vĩ mô lớn (NFP, CPI, FOMC):**
* **Hiện tượng:** Thị trường nín thở chờ tin, tạo ra Range hoàn hảo ở phiên Á và đầu Âu. Nhưng khi ra tin, giá quét mạnh cả 2 đầu (Whipsaw).
* **Hệ quả:** EA sẽ dính Stop Loss cả lệnh Buy và Sell trong chớp mắt vì trượt giá (Slippage) và biến động cực đoan.
* **Cách phòng tránh:** Kết hợp bộ lọc tin tức (News Filter). Tự động tắt máy sớm hoặc đóng các lệnh chờ trước thời điểm ra tin đỏ 30 phút.

**4. Chế độ thị trường chuyển sang Sideway diện rộng (Range-bound Market):**
* **Hiện tượng:** Thay vì một ngày có xu hướng (Trending day), thị trường bước vào pha đi ngang tính bằng tuần. 
* **Hệ quả:** Các chiến lược Breakout sẽ liên tục mua ở đỉnh hộp lớn và bán ở đáy hộp lớn, dẫn đến chuỗi Loss liên tiếp (Drawdown kéo dài).
* **Cách phòng tránh:** Sử dụng bộ lọc xu hướng lớn hơn mạnh mẽ. Ví dụ: Dùng ADX trên khung Daily hoặc Weekly (như đã thêm ADX Weekly > 20) để đảm bảo thị trường ở cấp độ Vĩ mô/Dài hạn đang CÓ XU HƯỚNG. Nếu ADX quá thấp -> Đứng ngoài.

**5. Thanh khoản yếu (Lễ tết, Cuối năm, Cuối tháng):**
* **Hiện tượng:** Các định chế lớn nghỉ lễ, dòng tiền mỏng.
* **Hệ quả:** Điểm Breakout không có dòng tiền Fomo hỗ trợ đẩy giá tiếp. Spread cũng giãn nở mạnh khiến việc bị "quét" Stop Loss diễn ra thường xuyên hơn.
* **Cách phòng tránh:** Quy định cứng các ngày trong năm/tháng không được phép cho EA chạy (Tháng 12, Tuần lễ tạ ơn, etc).