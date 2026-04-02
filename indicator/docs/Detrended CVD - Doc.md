Cách chỉ báo này hoạt động:

Raw CVD vẫn cộng dồn liên tục không ngừng từ ngày đầu tiên. Nó không bị reset (Bảo toàn ký ức gốc).

Mean CVD (SMA 100) đóng vai trò là "Đường xu hướng cốt lõi". Nó đại diện cho dòng chảy vĩ mô.

Phép trừ (Raw - Mean) bóc tách xu hướng dài hạn ra khỏi dữ liệu hiện tại (Detrending).

Phép chia cho Độ lệch chuẩn (StDev) ép toàn bộ sự giật lag của CVD về một tỷ lệ chuẩn mực (Thường nằm gọn trong khoảng từ -3 đến +3). Bất kỳ mức nào vượt quá +2 hoặc -2 đều là sự nỗ lực thao túng bất thường của dòng tiền.

3. Khi thị trường bước vào một xu hướng định hướng siêu mạnh kéo dài (Parabolic Trend), Z-Score CVD có gặp lỗi "Kẹt trần/Kẹt sàn" (Pegging) như RSI không?
Trả lời: Có. Trong một xu hướng tăng bùng nổ mà phe Mua liên tục mua đuổi trong nhiều ngày, Raw CVD sẽ dốc lên theo đường thẳng. Lúc này, Z-Score CVD sẽ liên tục đóng ở mức > +2.0 (thậm chí +3.0) và duy trì hàng chục nến. Nó gây ra hiện tượng mù tín hiệu phân kỳ. Trader có thể lầm tưởng là "quá mua dòng tiền" (Overbought) và liên tục bán chặn đầu (Fade), dẫn đến thua lỗ nặng. Z-Score CVD chỉ phát huy tối đa sức mạnh trong thị trường sideway biên độ rộng hoặc các nhịp pullback cấu trúc.


🛑 Setup 1: Điểm Kiệt Sức (Exhaustion) Tại Biên Range (Reversal/Fakeout)

Bối cảnh: Giá chạm vùng Kháng cự/Hỗ trợ (Upper/Lower Boundary) của một Trading Range đã được xác nhận (ít nhất 2 lần chạm trước đó).
Logic thuật toán: "Nỗ lực cực đại nhưng Kết quả bằng 0" -> Phe tấn công bị phe phòng thủ dùng lệnh Limit hấp thụ (Absorption).
Quy tắc Cò súng (Entry Criteria - Lệnh Short/Bán tại Kháng cự):
Vị trí: Giá High của nến chọc thủng hoặc chạm biên trên của Range.
Nỗ lực (Z-Score CVD): Bắn phá cực đại. Z-Score CVD > +2.0 (Thậm chí +3.0). Phe mua FOMO đẩy lệnh Market liên tục.
Kết quả (True Flow PVE): Thất bại thảm hại. Cột True Flow chuyển sang màu Xám (Neutral) hoặc giá trị cực thấp (gần 0). Cây nến đóng cửa tạo râu dài phía trên (Pinbar/Doji), hệ số $k^2$ triệt tiêu Volume.
Xác nhận (Trigger): Nến đóng cửa (Close) nằm dưới biên trên của Range. Bóp cò Short.

🚀 Setup 2: Breakout Hợp Lưu (Confirmed Breakout)
Bối cảnh: Giá nén chặt và chuẩn bị phá vỡ biên của Trading Range. Bạn cần lọc Fakeout.
Logic thuật toán: "Nỗ lực lớn sinh ra Kết quả tương xứng" -> Dòng tiền mạnh xuyên thủng mọi lệnh Limit cản đường.
Quy tắc Cò súng (Entry Criteria - Lệnh Long/Mua):
Vị trí: Nến đóng cửa (Close) vượt dứt khoát lên trên biên Kháng cự.
Nỗ lực (Z-Score CVD): Gia tăng mạnh mẽ và bền vững. +1.0 < Z-Score CVD < +2.0 (Ghi chú: Nếu > +2.5 ngay tại nến Breakout, cẩn thận đây là nến FOMO kiệt sức. Z-Score tăng đẹp nhưng chưa quá mức cực đoan là tốt nhất).
Kết quả (True Flow PVE): Bùng nổ. Cột True Flow Xanh (Blue) cao vượt trội so với trung bình 14 nến trước. Hệ số $k$ tiến sát 1 (Nến Marubozu đặc ruột, không râu).
Xác nhận (Trigger): Mua ngay khi nến Breakout đóng cửa, hoặc mua tại nhịp Retest đầu tiên với True Flow của nến Retest bằng 0 (Cạn cung).

📉 Setup 3: Cạn Kiệt Nguồn Cung (No Supply Pullback)
Bối cảnh: Thị trường đang trong Trend Tăng rõ ràng (Ví dụ: Nằm trên SMA 50). Giá có nhịp điều chỉnh (Pullback) nhẹ.Logic thuật toán: "Sự điều chỉnh không có Nỗ lực và không có Kết quả" -> Bọn tay yếu (Weak hands) chốt lời, cá mập không hề xả hàng.
Quy tắc Cò súng (Entry Criteria - Lệnh Long/Mua thuận xu hướng):
Vị trí: Giá hồi về chạm các vùng hỗ trợ động (VWAP, KAMA, hoặc EMA 20).
Nỗ lực (Z-Score CVD): Z-Score CVD giảm nhưng chỉ lơ lửng quanh mốc 0 đến -1.0 (Không có sự bán tháo hoảng loạn).
Kết quả (True Flow PVE): Các nến giảm giá có cột True Flow Đỏ (Red) nhưng cực kỳ lùn hoặc toàn màu Xám. (Nến giảm thân nhỏ, Volume thấp).
Xác nhận (Trigger): Xuất hiện cây nến Xanh đầu tiên có True Flow bùng nổ trở lại + Z-Score CVD cắt lên trên 0. Mua.