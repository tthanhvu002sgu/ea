"""
QUICK START - Phân tích nhanh file CSV

Chạy script này để phân tích nhanh mà không cần config gì:
    python quick_start.py EURUSD_M15.csv
"""

import sys
import os

def main():
    if len(sys.argv) < 2:
        print("""
╔═══════════════════════════════════════════════════════════════╗
║        PRICE ACTION PATTERN ANALYZER - QUICK START            ║
╚═══════════════════════════════════════════════════════════════╝

Cách sử dụng:
    python quick_start.py <file_csv>

Ví dụ:
    python quick_start.py EURUSD_M15.csv
    python quick_start.py GBPUSD_M5.csv
    python quick_start.py XAUUSD_H1.csv

Yêu cầu:
    - File CSV format MT4/MT5
    - Các cột: DATE, TIME, OPEN, HIGH, LOW, CLOSE, TICKVOL

Output:
    - Báo cáo JSON với tất cả kết quả
    - Top 10 chiến lược tốt nhất
    - Win rate, Profit Factor, Total Profit
        """)
        sys.exit(1)
    
    csv_file = sys.argv[1]
    
    if not os.path.exists(csv_file):
        print(f"❌ Không tìm thấy file: {csv_file}")
        sys.exit(1)
    
    # Import analyzer
    try:
        from pattern_analyzer import PriceActionAnalyzer
    except ImportError:
        print("❌ Không tìm thấy pattern_analyzer.py")
        print("Đảm bảo file pattern_analyzer.py cùng thư mục với quick_start.py")
        sys.exit(1)
    
    print("""
╔═══════════════════════════════════════════════════════════════╗
║              BẮT ĐẦU PHÂN TÍCH QUY LUẬT GIÁ                  ║
╚═══════════════════════════════════════════════════════════════╝
    """)
    
    # Run analysis
    analyzer = PriceActionAnalyzer(csv_file)
    
    if not analyzer.load_data():
        sys.exit(1)
    
    analyzer.calculate_indicators()
    analyzer.analyze_all_patterns()
    
    # Tạo báo cáo
    base_name = os.path.basename(csv_file).replace('.csv', '')
    report_file = f'{base_name}_analysis.json'
    analyzer.generate_report(report_file)
    
    print(f"""
╔═══════════════════════════════════════════════════════════════╗
║                    HOÀN TẤT PHÂN TÍCH                         ║
╚═══════════════════════════════════════════════════════════════╝

📊 Kết quả đã lưu: {report_file}

📖 Cách đọc kết quả:

1. TOP STRATEGIES: Xem 3 bảng xếp hạng ở trên
   - Win Rate cao nhất (> 55% là tốt)
   - Profit Factor cao nhất (> 1.5 là tốt)
   - Total Profit cao nhất

2. FILE JSON: Chứa toàn bộ chi tiết
   - metadata: Thông tin file
   - results: Kết quả từng nhóm quy luật

3. CHIẾN LƯỢC TỐT NHẤT thường là:
   - buy_swing_low (Mua tại support)
   - sell_swing_high (Bán tại resistance)
   - Các chuỗi reversal 5-6 nến

4. CHIẾN LƯỢC YẾU thường là:
   - Breakout thuần túy
   - Candlestick patterns đơn lẻ
   - Volume strategies

💡 Khuyến nghị tiếp theo:

1. Kiểm tra file JSON để xem chi tiết
2. Chạy custom_strategy_test.py để test thêm chiến lược
3. Kết hợp nhiều yếu tố để tạo edge
4. Forward test trên demo trước khi real

⚠️  Lưu ý:
   - Backtest ≠ Forward test
   - Luôn dùng Stop Loss
   - Position Sizing quan trọng
   - Market regime có thể thay đổi
    """)


if __name__ == "__main__":
    main()