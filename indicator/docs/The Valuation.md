# The Valuator - Chỉ báo Định giá Dài hạn

## 1. Giới thiệu
**The Valuator** là công cụ phân tích kỹ thuật được thiết kế để xác định giá trị thực (Fair Value) và trạng thái định giá của tài sản trong dài hạn. Chỉ báo này sử dụng phương pháp **Hồi quy Mũ (Exponential Regression)** trên dữ liệu giá Logarit để tạo ra đường giá trị hợp lý, sau đó tính toán **Z-Score** để đo lường độ lệch chuẩn của giá hiện tại so với giá trị này.

Chỉ báo giúp nhà đầu tư trả lời câu hỏi: *"Giá hiện tại đang rẻ, đắt hay hợp lý so với xu hướng tăng trưởng dài hạn?"*

---

## 2. Thông số Đầu vào (Input Parameters)

### Cài đặt Cốt lõi (Core Settings)
| Tham số | Mặc định | Mô tả |
| :--- | :--- | :--- |
| **Regression Lookback** | 200 | Số lượng nến quá khứ được sử dụng để tính toán đường hồi quy tuyến tính. <br>*(Gợi ý: 200 trên khung Weekly tương đương khoảng 4 năm dữ liệu)*. |
| **EMA Period for Stats** | 52 | Chu kỳ của đường trung bình động lũy thừa (EMA) dùng để làm mượt các thống kê (Mean & StdDev) khi tính Z-Score. |

### Các Ngưỡng Định giá (Thresholds)
Các ngưỡng Z-Score được sử dụng để phân loại vùng giá:
- **Gift Zone (Món quà)**: Z < -1.5 (Cực rẻ)
- **Cheap Zone (Giá rẻ)**: Z < -0.8
- **Expensive Zone (Đắt)**: Z > 0.8
- **Bubble Zone (Bong bóng)**: Z > 1.5 (Cực đắt)

### Hiển thị (Display)
- **Show Fair Value Line**: Bật/tắt đường Giá trị hợp lý trên biểu đồ (overlay).
- **Show Info Table**: Bật/tắt bảng thông tin trạng thái ở góc màn hình.

---

## 3. Các Vùng Định giá (Valuation Zones)

Chỉ báo chia thị trường thành 5 trạng thái dựa trên Z-Score:

1.  **🟢 Gift Zone (Vùng Món Quà)** (`Z < -1.5`)
    -   **Màu sắc**: Xanh lá đậm (#00E676)
    -   **Ý nghĩa**: Giá đang bị định giá cực thấp so với xu hướng. Đây thường là cơ hội mua dài hạn tốt nhất (đáy hoảng loạn).

2.  **Uncertainty/Cheap Zone (Vùng Giá Rẻ)** (`-1.5 <= Z < -0.8`)
    -   **Màu sắc**: Xanh lá nhạt (#81C784)
    -   **Ý nghĩa**: Giá đang rẻ hơn mức trung bình, là vùng tích lũy tiềm năng.

3.  **⚪ Fair Zone (Vùng Hợp Lý)** (`-0.8 <= Z <= 0.8`)
    -   **Màu sắc**: Xám (#90A4AE)
    -   **Ý nghĩa**: Giá đang biến động quanh vùng giá trị thực. Không quá đắt cũng không quá rẻ.

4.  **🟠 Expensive Zone (Vùng Đắt)** (`0.8 < Z <= 1.5`)
    -   **Màu sắc**: Cam (#FF9800)
    -   **Ý nghĩa**: Giá bắt đầu cao hơn đáng kể so với xu hướng. Cần thận trọng hoặc cân nhắc chốt lời từng phần.

5.  **🔴 Bubble Zone (Vùng Bong Bóng)** (`Z > 1.5`)
    -   **Màu sắc**: Đỏ (#F44336)
    -   **Ý nghĩa**: Giá đang bị thổi phồng quá mức (FOMO cực đại). Rủi ro đảo chiều rất cao.

---

## 4. Công thức Tính toán (Kỹ thuật)

### Bước 1: Hồi quy Tuyến tính trên Log(Price)
Chỉ báo giả định giá tăng trưởng theo hàm mũ: $Price = e^{a + b \cdot time}$
Bằng cách lấy Logarit tự nhiên của giá, ta đưa về bài toán hồi quy tuyến tính:
$$ \ln(Price) = a + b \cdot time $$
Hệ số $a$ (tại $time=0$ là nến hiện tại) chính là `Fair Value Log`.

### Bước 2: Tính Z-Score
1.  **Độ lệch (Deviation)**: $D = \ln(Price) - \ln(FairValue)$
2.  **Trung bình động độ lệch (Rolling Mean)**: $\mu = EMA(D, period)$
3.  **Phương sai (Variance)**: $\sigma^2 = EMA((D - \mu)^2, period)$
4.  **Z-Score**: $Z = \frac{D - \mu}{\sigma}$

---

## 5. Tính năng Bổ sung

### Bảng Thông tin (Dashboard)
Hiển thị ở góc trên bên phải biểu đồ:
-   **Zone**: Trạng thái hiện tại (ví dụ: "Cheap", "Fair").
-   **Z-Score**: Giá trị chính xác của Z-Score.
-   **vs Fair Value**: Phần trăm chênh lệch giữa giá hiện tại và giá trị thực (`+` là cao hơn, `-` là thấp hơn).
-   **Fair Value**: Mức giá trị hợp lý cụ thể (ví dụ: $50,000).

### Cảnh báo (Alerts)
Hỗ trợ tạo cảnh báo trên TradingView cho các sự kiện:
-   **GIFT Zone**: Khi giá rơi vào vùng cực rẻ.
-   **BUBBLE Zone**: Khi giá đi vào vùng bong bóng.
-   **Cheap/Expensive Zone**: Khi giá đi vào các vùng tương ứng.
-   **Recovery**: Khi giá quay trở lại vùng Fair từ các vùng cực đoan.
