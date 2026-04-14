# Hướng dẫn Thiết lập Đầu vào (Inputs) - Monte Carlo Expected Move Distribution

Chỉ báo Định lượng **Monte Carlo Expected Move Distribution** mô phỏng hàng trăm, hàng ngàn quỹ đạo giá (Price Paths) có thể xảy ra trong tương lai dựa trên Mức độ Biến động (Volatility) và Xu hướng (Drift) ở thời điểm hiện tại.

Nhờ việc nâng cấp lên **Mô hình Chuyển động Brownian Hình học (GBM)** và thuật toán Random bằng hàm Lượng giác phi trạng thái (Stateless Hash Box-Muller), chỉ báo đã được sửa lỗi **triệt để** tình trạng nhảy múa / mở rộng dữ liệu (Repainting/Correlations) khi giá đang thay đổi trên nến live.

Bảng bên dưới hỗ trợ các kĩ sư Định lượng tối ưu hóa từng tham số một cách khoa học nhất.

---

## 🎲 Monte Carlo Simulation Settings (Cấu hình Mô phỏng Lõi)

### 1. **Simulations** (Số lượng Đường Đi Giả Lập)
- **Mặc định:** `200`
- **Tác dụng:** Xác định độ lớn của vòng lặp Monte Carlo. Mỗi lượt mô phỏng tương đương với một kịch bản di chuyển giá độc lập trong tương lai.
- **Gợi ý thiết lập:**
  - Nếu máy tính yếu hoặc dùng khung giờ bé (M1, M5): Nên để `100 - 150` nhằm giảm tải xử lý.
  - Nếu muốn độ sắc bén Định lượng tuyệt đối và dùng khung giờ to (H4, D1): Nâng lên `300 - 500` để các đường cong phân phối Box-Muller mịn và cân bằng, mang lại khoảng StdDev (+1/-1) hoàn hảo nhất.

### 2. **Projection Length** (Chiều dài Tầm nhìn Dự phóng)
- **Mặc định:** `30`
- **Tác dụng:** Số lượng cây nến (Bars) trong tương lai mà thuật toán sẽ chạy dự phóng. 
- **Gợi ý thiết lập:**
  - Con số này nên khớp với thời gian bạn dự định giữ lệnh (Holding Time). Lướt sóng nội ngày thì để `10 - 20`. Nuôi trend dài hạn thì đặt `30 - 50`.
  - **Lưu ý định lượng:** `Projection Length` càng lớn thì yếu tố Thời gian ($T$) tích lũy càng nhiều. Biến động sẽ có đà nở rộng ra rất mạnh, nên thân nón phân phối sẽ phình to ra và bẹt hơn.

### 3. **Volatility Lookback** (Chu kỳ Đoạt Biến động)
- **Mặc định:** `50`
- **Tác dụng:** Độ rộng số nến quá khứ được quét để tính ra Biến động Logarit ($\sigma$ / Log Returns) hiện tại của thị trường. Hệ thống đo biến động trong quá khứ này để ép vào cho kỳ vọng tương lai.
- **Gợi ý thiết lập:**
  - Nhanh / Nhạy bén (Scalper): Giảm xuống `20`. Nó sẽ nhanh chóng nắm bắt các nhịp xả rũ bùng nổ, khiến biên độ Expected Move lập tức dãn ra để che chắn.
  - Bền bỉ / Chắc tay (Trend Trader): Giữ quanh `50 - 100` để loại bỏ các vi nhiễu cục bộ ngắn hạn, mang lại cái nhìn bao quát về xu hướng cốt lõi.

### 4. **Include Trend (Drift)** (Tính thêm Lực Quán tính Xu hướng)
- **Mặc định:** `Bật (True)`
- **Tác dụng:** Mô phỏng sẽ quyết định có đem "Đà tăng / Đà giảm" hiện hành ($\mu$) của quá khứ vào quỹ đạo dự phóng hay không. Thuật toán có tính đến lực cản biến động (phương sai) theo *Bổ đề Ito*.
- **Gợi ý thiết lập:**
  - Ở xu hướng định hướng mạnh (Trend Follow): **BẬT**. Các khối hộp mô phỏng sẽ tịnh tiến lệch hẳn vượt lên trên hoặc xuống dưới, thuận theo phe đang thắng.
  - Giao dịch Quyền chọn / Mua bán lưới (Options / Grid Trading): **TẮT**. Ép Drift = 0 sẽ đưa kỳ vọng khối hộp về trạng thái Gaussian cân bằng lý tưởng ngay giữa mốc 0, rất phù hợp khi phỏng đoán Điểm Hòa Vốn mà rủi ro thuần túy đánh giá qua Volatility.

---

## 🎨 Distribution Visuals (Giao diện Khối lượng Hiển thị)

### 5. **Price Bins** (Độ Phân Giải Các Khe Giá Y)
- **Mặc định:** `25`
- **Tác dụng:** Trục dọc giá của đích đến được cắt ra làm bao nhiêu khấc (rãnh). Càng nhiều khấc thì lưới hộp mật độ càng mỏng manh.
- **Gợi ý thiết lập:** 
  - Khuyến cáo giúp mắt dễ nhìn nhất nằm khoảng `25 - 35`. Đừng đẩy quá 50 vì sẽ khiến các Box bị chia vụn nhỏ như sợi chỉ, rất khó quan sát tỉ trọng và chênh lệch mật độ khối.

### 6. **Max Distribution Width** (Giới hạn Ngang Trục X)
- **Mặc định:** `20`
- **Tác dụng:** Độ rộng tính bằng số lượng Nến của đồ thị đồi nằm ngang, kéo lùi từ `Projection target bar` về phía trái.
- **Gợi ý thiết lập:**
  - Nếu `Projection Length` đặt là 30, thì `Width` để tầm khoảng **15 - 20** là đẹp tỷ lệ cân mắt. Tức là `Width` khoảng $\frac{2}{3}$ của `Projection Length`.
  - Hộp tụ tập nhiều mô phỏng nhất (Giá có xác suất cao nhất) sẽ được vươn dài nhất chạm tới mép trần `Max Width` này. Còn giá ở đuôi (Fat tails cực đoan) xác suất bé thì sẽ dẹt lùi lại phía sau, tự động tạo thành đường cong Bell Curve hình quả chuông tuyệt đẹp.

---

> 💡 **Khuyến cáo từ Kỹ sư (Pro-tips):** <br>
> Bản vá định lượng cấu trúc này sẽ tự động phân tích và in hình kết quả 1 lần duy nhất ngay lúc đóng chốt nến gốc cuối cùng (`islastconfirmedhistory`). Với cơ chế tính điểm ngẫu nhiên bằng **Toán học Phi Tuyến Lượng Giác (Stateless Pseudo-Random)** thay thế cho `math.random` nguyên thủy, các hộp màu sẽ TUYỆT ĐỐI cố định, không hề xảy ra hiện tượng chớp nháy (flicker) hay lệch biên dạng. Bạn hoàn toàn có thể an tâm bật cả ngày để giao dịch trên MT4/MT5.

---

## 📖 Hướng dẫn Đọc Hiểu Kết Quả Chỉ Báo

Khi thuật toán quét xong và in ra biểu đồ, bạn sẽ thấy 3 đường kẻ ngang (Dashed Lines) cùng một hệ thống các khối màu (Histogram). Đây chính là bản đồ xác suất hoàn chỉnh của bạn:

### 1. **Dải Băng Phân Phối Cốt Lõi (Vùng Hộp Màu Sáng - Tháp Trung Tâm)**
Toàn bộ các khối hộp (Boxes) có màu sáng trong trẻo nằm giữa đường `+1 SD` và `-1 SD` biểu thị vùng giá có **tỷ lệ 68,2%** chắc chắn sẽ xảy ra trong tương lai (Chuẩn theo quy tắc Gaussian 1-Sigma).
- **Ứng dụng:** Nếu bạn đánh lệnh Dài hạn (Hold/Swing), Stop Loss (SL) của bạn TUYỆT ĐỐI không được đặt lọt thỏm bên trong vùng hộp sáng này. Bởi vì giá có giật lên nảy xuống trong khe này thì rốt cuộc cũng chỉ là nhiễu động ngẫu nhiên tất yếu (Noise/Random Walk), chưa hề bị phá vỡ cấu trúc và sẽ dính Cắt lỗ oan uổng.

### 2. **Đường đứt nét Xanh Lá: Exp. Upper (+1 SD)**
Đây là mức giới hạn kỳ vọng Di chuyển Tăng (Upside Expected Move).
- **Ứng dụng:** Là vùng **Chốt lời (Take Profit)** cực kỳ tuyệt vời cho các lệnh Buy (Long). Điểm giá này cảnh báo rằng đà tăng đã vắt cạn kiệt phần lớn các xung lực tự nhiên, muốn phá vỡ để đi lên tiếp, phe Mua (Bulls) bắt buộc phải có Tin Tức Vĩ Mô (News) cực mạnh kích hoạt dòng tiền mới.

### 3. **Đường đứt nét Xám: Median Outcome (Mức Trung Vị)**
Đây là mức giá cân bằng nhất, nơi số lượng mô phỏng đi qua đông đặc nhất (Đỉnh của quả chuông).
- **Ứng dụng:** Hoạt động như một "Lực hút nam châm". Trong một thị trường sideway nhạt nhẽo phi tin tức, giá rốt cuộc sẽ luôn bị từ tính hút trôi dạt về chạm sát vào đường Median này tại mốc thời gian vạch đích. Rất thích hợp làm Target ăn ngắn cho phe Scalping.

### 4. **Đường đứt nét Đỏ: Exp. Lower (-1 SD)**
Đây là giới hạn kỳ vọng Di chuyển Giảm (Downside Expected Move).
- **Ứng dụng:** Nơi tốt nhất để "Bắt dao rơi" (Catch knives) râu gài ở đáy trong một Uptrend, hoặc là vạch Cắt Lỗ Cứng (Hard Stop Loss) an toàn cho lệnh Mua. Nếu giá thực tế đâm xuyên thủng `-1 SD` với những cây nến Momentum đỏ đặc, nó xác nhận chuông phân phối chuẩn đã vỡ toang, thị trường bước vào hố đen bán tháo (Fat tail risk), bạn cần đảo view sang phe Bán (Short) ngay lập tức không chần chừ.

### 5. **Các hộp đuôi xám mờ (Fat Tails / Vùng > 1 SD)**
Các hộp màu xám mờ rải rác vươn ra ngoài biên Giới hạn +1 SD và -1 SD đại diện cho những xác suất cực đoan (Chỉ chiếm < 32%).
- **Ứng dụng Định lượng:** Khu vực nhạy cảm này thường được các Quỹ giao dịch Tùy chọn (Options Trader) săn đón để rải đinh thu phí bảo hiểm khống (Bán phương pháp Iron Condor) bằng cách cược rằng "Dù thị trường có điên rồ đến mấy, giá cũng sẽ không thể liếm được các hộp xám mờ ở tít ngoài này trước mốc đáo hạn".
