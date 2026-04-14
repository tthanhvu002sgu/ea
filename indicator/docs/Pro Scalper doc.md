Viewed Pro%20Scalper.pine:1-306

Chào bạn, trong mã nguồn `Pro Scalper.pine`, các "bong bóng" (Bubbles) được thiết kế để phát hiện và đánh dấu các vị trí có **khối lượng giao dịch bất thường kết hợp với lực mua/bán (Delta)**.

Dưới đây là chi tiết cách hệ thống xác định và vẽ ra các bong bóng này, chia thành 3 bước chính:

### Bước 1: Tính toán `Delta Proxy` (Lực Mua / Lực Bán)
Script không chỉ dùng volume (khối lượng) bình thường mà còn tính toán một giá trị `delta` để biết nến đó bị chi phối bởi phe mua hay phe bán. Có 3 chế độ người dùng có thể chọn để tính (nằm ở dòng 14-22):

1. **RangeWeighted (Mặc định)**: `volume * (close - open) / range`
   » Khối lượng được nhân với tỷ lệ giữa thân nến `(close - open)` và toàn bộ chiều dài của nến `(high - low)`. Nếu nến đóng cửa cao hơn mở cửa, lực này mang số Dương. Nếu đóng cửa thấp hơn mở cửa, mang số Âm.
2. **CloseVsPrev**: 
   » Nếu giá đóng cửa hiện tại $\ge$ giá đóng cửa nến trước -> Lấy Dương Volume. Ngược lại -> Âm Volume.
3. **CloseVsOpen**: 
   » Nếu giá đóng cửa $\ge$ giá mở cửa -> Lấy Dương Volume. Ngược lại -> Âm Volume.

Sau đó, script sẽ lấy **giá trị tuyệt đối của Delta (`absDel`)** để làm thước đo mức độ đột biến bất kể là sức mua hay sức bán.

### Bước 2: Xác định Ngưỡng đột biến (Threshold bằng Bách phân vị)
Để quyết định xem một khối lượng có đủ lớn để vẽ bubble hay không, đoạn mã tự động tạo ra một **ngưỡng động (Dynamic Threshold)** thay vì số cố định (dòng 27-31):

- Dùng hàm `ta.percentile_linear_interpolation` để xét lại lịch sử của `200 nến gần nhất` (`qbLen`).
- Từ lịch sử đó, nó lấy ra mốc **bách phân vị thứ 85** (`qbPct = 85`).
- **Ý nghĩa:** `absDel` ở nến hiện tại phải **lớn hơn 85%** các giá trị delta của 200 nến trước đó (tương đương lọt top 15% nến có volume mạnh nhất) thì mới đủ chuẩn là một đột biến. Giá trị ngưỡng này được lưu trong biến `thrBub`.

### Bước 3: Đánh giá độ mạnh và Vẽ Bubble (dòng 33 - 50)
Nếu điều kiện đột biến thỏa mãn (`absDel >= thrBub`), script sẽ tiến hành tính toán các thông số biểu diễn:

1. **Tính Độ Tương Đối (Ratio):**
   `ratio = absDel / thrBub`
   Script xem thử lực hiện tại lớn _gấp bao nhiêu lần_ so với cái ngưỡng đột biến kia (Ví dụ: vừa chạm ngưỡng thì ratio là 1, gấp đôi ngưỡng thì ratio là 2).
   
2. **Kích thước Bubble:** Dựa vào cái `ratio` phía trên, hàm `bubbleSize(r)` sẽ xác định kích thước:
   - Nếu tỷ lệ $\ge$ 3 ($>$ gấp 3 lần ngưỡng): Size **Khổng lồ (Huge)**
   - Nếu tỷ lệ $\ge$ 2.25: Size **Lớn (Large)**
   - Nếu tỷ lệ $\ge$ 1.6: Size **Vừa (Normal)**
   - Nếu tỷ lệ $\ge$ 1.1: Size **Nhỏ (Small)**
   - Mặc định vừa chạm ngưỡng: Size **Siêu nhỏ (Tiny)**

3. **Màu sắc và Độ Mờ:**
   - **Màu cơ bản:** Nếu `delta` dương (Lực mua mạnh) $\rightarrow$ Màu xanh lá (`color.lime`). Nếu `delta` âm (Lực bán mạnh) $\rightarrow$ Màu đỏ (`color.red`).
   - **Độ mờ:** Bong bóng càng mạnh (ratio càng lớn) thì màu sẽ càng rực rỡ và đâm (bớt mờ). Tính toán minh bạch ở công thức độ trong suốt: `85 - int(math.min(60.0, (ratio-1.0)*30.0))`.

4. **Vị trí Vẽ trên Chart:**
   - Nếu là bóng **Mua (Xanh)**: Bubble được vẽ nằm đè ở **đáy của cây nến hiện tại** (`low`).
   - Nếu là bóng **Bán (Đỏ)**: Bubble được vẽ nằm đè ở **đỉnh của cây nến hiện tại** (`high`).
   - Cuối cùng vẽ trên biểu đồ bằng hàm `label.new` với phong cách `label.style_circle` (hình tròn, không có text).

**Tóm lại:** Mỗi bong bóng xuất hiện trên biểu đồ tương ứng với một cú xả hàng hoặc gom hàng rất mạnh ("Đột biến lọt top 15% của 200 nến gần nhất"). Bong bóng càng to và màu càng đậm thì cú nổ volume tại vùng giá đó càng quyết liệt.