"""
CUSTOM STRATEGY TESTER
Test các chiến lược tùy chỉnh của bạn

Ví dụ sử dụng:
    python custom_strategy_test.py EURUSD_M15.csv
"""

import sys
import os
from pattern_analyzer import PriceActionAnalyzer

def test_my_strategies(csv_file):
    """Test các chiến lược tùy chỉnh"""
    
    # Khởi tạo
    analyzer = PriceActionAnalyzer(csv_file)
    analyzer.load_data()
    analyzer.calculate_indicators()
    
    df = analyzer.df
    
    print("\n" + "="*80)
    print("CUSTOM STRATEGIES TESTING")
    print("="*80)
    
    # ========== CHIẾN LƯỢC 1: SCALPING PHIÊN ASIAN ==========
    print("\n1️⃣  SCALPING PHIÊN ASIAN")
    print("-" * 80)
    
    # Điều kiện: Phiên Asian, Range nhỏ, RSI neutral
    condition = ((df['session'] == 'asian') & 
                 (df['range'] < df['atr_14'] * 0.8) &
                 (df['rsi'] > 45) & (df['rsi'] < 55) &
                 (df['is_bullish']))
    
    result = analyzer.test_strategy(
        condition,
        direction='long',
        hold_candles=3,  # Hold 45 phút (3 x M15)
        stop_loss_pips=8,
        take_profit_pips=12
    )
    
    print(f"Asian Scalping LONG:")
    print(f"  Trades: {result['total_trades']:,}")
    print(f"  Win Rate: {result['win_rate']:.1f}%")
    print(f"  Avg Profit: {result['avg_profit']:.2f} pips")
    print(f"  Profit Factor: {result['profit_factor']:.2f}")
    print(f"  Total Profit: {result['total_profit']:.1f} pips")
    
    # ========== CHIẾN LƯỢC 2: LONDON BREAKOUT ==========
    print("\n2️⃣  LONDON BREAKOUT")
    print("-" * 80)
    
    # Điều kiện: Đầu phiên London, breakout range Asian, volume cao
    condition = ((df['hour'].isin([8, 9])) &  # 8-9am London open
                 (df['breakout_high']) &
                 (df['TICKVOL'] > df['TICKVOL'].rolling(20).mean() * 1.5) &
                 (df['CLOSE'] > df['sma_50']))
    
    result = analyzer.test_strategy(
        condition,
        direction='long',
        hold_candles=12,  # Hold 3 giờ
        stop_loss_pips=20,
        take_profit_pips=40
    )
    
    print(f"London Breakout:")
    print(f"  Trades: {result['total_trades']:,}")
    print(f"  Win Rate: {result['win_rate']:.1f}%")
    print(f"  Avg Profit: {result['avg_profit']:.2f} pips")
    print(f"  Profit Factor: {result['profit_factor']:.2f}")
    print(f"  Total Profit: {result['total_profit']:.1f} pips")
    
    # ========== CHIẾN LƯỢC 3: RSI DIVERGENCE REVERSAL ==========
    print("\n3️⃣  RSI EXTREME REVERSAL")
    print("-" * 80)
    
    # Điều kiện: RSI extreme + Pattern reversal + Volume
    condition = ((df['rsi'] < 25) &
                 (df['bullish_engulfing'] | df['hammer'] | df['bullish_pin']) &
                 (df['TICKVOL'] > df['TICKVOL'].rolling(10).mean()))
    
    result = analyzer.test_strategy(
        condition,
        direction='long',
        hold_candles=8,
        stop_loss_pips=15,
        take_profit_pips=25
    )
    
    print(f"RSI Extreme Reversal LONG:")
    print(f"  Trades: {result['total_trades']:,}")
    print(f"  Win Rate: {result['win_rate']:.1f}%")
    print(f"  Avg Profit: {result['avg_profit']:.2f} pips")
    print(f"  Profit Factor: {result['profit_factor']:.2f}")
    print(f"  Total Profit: {result['total_profit']:.1f} pips")
    
    # ========== CHIẾN LƯỢC 4: TREND + PULLBACK ==========
    print("\n4️⃣  TREND PULLBACK")
    print("-" * 80)
    
    # Điều kiện: Strong uptrend, pullback về SMA20, RSI không oversold
    df['pullback_to_sma'] = ((df['LOW'] <= df['sma_20']) & 
                             (df['LOW'].shift(1) > df['sma_20'].shift(1)) &
                             (df['CLOSE'] > df['sma_20']))
    
    condition = ((df['pullback_to_sma']) &
                 (df['sma_20'] > df['sma_50']) &  # Uptrend
                 (df['rsi'] > 40) & (df['rsi'] < 60))
    
    result = analyzer.test_strategy(
        condition,
        direction='long',
        hold_candles=16,  # Hold 4 giờ
        stop_loss_pips=18,
        take_profit_pips=35
    )
    
    print(f"Trend Pullback:")
    print(f"  Trades: {result['total_trades']:,}")
    print(f"  Win Rate: {result['win_rate']:.1f}%")
    print(f"  Avg Profit: {result['avg_profit']:.2f} pips")
    print(f"  Profit Factor: {result['profit_factor']:.2f}")
    print(f"  Total Profit: {result['total_profit']:.1f} pips")
    
    # ========== CHIẾN LƯỢC 5: BOLLINGER SQUEEZE BREAKOUT ==========
    print("\n5️⃣  BOLLINGER SQUEEZE BREAKOUT")
    print("-" * 80)
    
    # Điều kiện: BB squeeze (thị trường tích lũy), sau đó breakout
    df['bb_width'] = (df['bb_upper'] - df['bb_lower']) / df['bb_middle']
    df['bb_squeeze'] = df['bb_width'] < df['bb_width'].rolling(50).quantile(0.2)
    
    condition = ((df['bb_squeeze'].shift(1)) &
                 (df['CLOSE'] > df['bb_upper']) &
                 (df['is_bullish']) &
                 (df['TICKVOL'] > df['TICKVOL'].rolling(20).mean()))
    
    result = analyzer.test_strategy(
        condition,
        direction='long',
        hold_candles=12,
        stop_loss_pips=20,
        take_profit_pips=35
    )
    
    print(f"BB Squeeze Breakout:")
    print(f"  Trades: {result['total_trades']:,}")
    print(f"  Win Rate: {result['win_rate']:.1f}%")
    print(f"  Avg Profit: {result['avg_profit']:.2f} pips")
    print(f"  Profit Factor: {result['profit_factor']:.2f}")
    print(f"  Total Profit: {result['total_profit']:.1f} pips")
    
    # ========== CHIẾN LƯỢC 6: MACD MOMENTUM ==========
    print("\n6️⃣  MACD MOMENTUM")
    print("-" * 80)
    
    # Điều kiện: MACD histogram tăng, price > SMA
    df['macd_increasing'] = df['macd_histogram'] > df['macd_histogram'].shift(1)
    df['macd_positive'] = df['macd_histogram'] > 0
    
    condition = ((df['macd_increasing']) &
                 (df['macd_histogram'].shift(1) < 0) &  # Cross from negative
                 (df['macd_histogram'] > 0) &
                 (df['CLOSE'] > df['sma_20']))
    
    result = analyzer.test_strategy(
        condition,
        direction='long',
        hold_candles=20,
        stop_loss_pips=25,
        take_profit_pips=45
    )
    
    print(f"MACD Momentum:")
    print(f"  Trades: {result['total_trades']:,}")
    print(f"  Win Rate: {result['win_rate']:.1f}%")
    print(f"  Avg Profit: {result['avg_profit']:.2f} pips")
    print(f"  Profit Factor: {result['profit_factor']:.2f}")
    print(f"  Total Profit: {result['total_profit']:.1f} pips")
    
    # ========== CHIẾN LƯỢC 7: SUPPORT BOUNCE ==========
    print("\n7️⃣  SUPPORT BOUNCE (SWING LOW)")
    print("-" * 80)
    
    # Điều kiện: Swing low + bullish reversal + không trong downtrend mạnh
    condition = ((df['swing_low']) &
                 (df['bullish_engulfing'] | df['hammer']) &
                 (df['CLOSE'] >= df['sma_50']))  # Not in strong downtrend
    
    result = analyzer.test_strategy(
        condition,
        direction='long',
        hold_candles=12,
        stop_loss_pips=18,
        take_profit_pips=30
    )
    
    print(f"Support Bounce:")
    print(f"  Trades: {result['total_trades']:,}")
    print(f"  Win Rate: {result['win_rate']:.1f}%")
    print(f"  Avg Profit: {result['avg_profit']:.2f} pips")
    print(f"  Profit Factor: {result['profit_factor']:.2f}")
    print(f"  Total Profit: {result['total_profit']:.1f} pips")
    
    # ========== CHIẾN LƯỢC 8: NEWS SPIKE FADE ==========
    print("\n8️⃣  VOLATILITY SPIKE FADE")
    print("-" * 80)
    
    # Điều kiện: Range đột ngột lớn hơn 2x ATR, sau đó fade
    condition = ((df['range'] > df['atr_14'] * 2.5) &
                 (df['is_bullish']) &
                 (df['rsi'] > 70))
    
    result = analyzer.test_strategy(
        condition,
        direction='short',  # Fade the spike
        hold_candles=6,
        stop_loss_pips=20,
        take_profit_pips=25
    )
    
    print(f"Volatility Spike Fade:")
    print(f"  Trades: {result['total_trades']:,}")
    print(f"  Win Rate: {result['win_rate']:.1f}%")
    print(f"  Avg Profit: {result['avg_profit']:.2f} pips")
    print(f"  Profit Factor: {result['profit_factor']:.2f}")
    print(f"  Total Profit: {result['total_profit']:.1f} pips")
    
    # ========== CHIẾN LƯỢC 9: 3 DUCK STRATEGY ==========
    print("\n9️⃣  THREE DUCKS (Multi-Timeframe Trend)")
    print("-" * 80)
    
    # Điều kiện: All EMAs aligned (simple multi-TF simulation)
    condition = ((df['ema_12'] > df['ema_26']) &
                 (df['CLOSE'] > df['sma_20']) &
                 (df['sma_20'] > df['sma_50']) &
                 (df['CLOSE'] > df['OPEN']) &
                 (df['CLOSE'].shift(1) > df['OPEN'].shift(1)))
    
    result = analyzer.test_strategy(
        condition,
        direction='long',
        hold_candles=20,
        stop_loss_pips=25,
        take_profit_pips=50
    )
    
    print(f"Three Ducks (Trend Alignment):")
    print(f"  Trades: {result['total_trades']:,}")
    print(f"  Win Rate: {result['win_rate']:.1f}%")
    print(f"  Avg Profit: {result['avg_profit']:.2f} pips")
    print(f"  Profit Factor: {result['profit_factor']:.2f}")
    print(f"  Total Profit: {result['total_profit']:.1f} pips")
    
    # ========== CHIẾN LƯỢC 10: END OF DAY MOMENTUM ==========
    print("\n🔟 END OF DAY MOMENTUM")
    print("-" * 80)
    
    # Điều kiện: Cuối phiên NY, nếu trend mạnh thì hold overnight
    condition = ((df['hour'].isin([20, 21])) &  # End of NY session
                 (df['CLOSE'] > df['sma_20']) &
                 (df['sma_20'] > df['sma_50']) &
                 (df['macd_histogram'] > 0) &
                 (df['rsi'] > 55))
    
    result = analyzer.test_strategy(
        condition,
        direction='long',
        hold_candles=24,  # Hold 6 giờ (qua đêm)
        stop_loss_pips=30,
        take_profit_pips=50
    )
    
    print(f"End of Day Momentum:")
    print(f"  Trades: {result['total_trades']:,}")
    print(f"  Win Rate: {result['win_rate']:.1f}%")
    print(f"  Avg Profit: {result['avg_profit']:.2f} pips")
    print(f"  Profit Factor: {result['profit_factor']:.2f}")
    print(f"  Total Profit: {result['total_profit']:.1f} pips")
    
    print("\n" + "="*80)
    print("✅ HOÀN TẤT TEST CUSTOM STRATEGIES")
    print("="*80)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python custom_strategy_test.py <csv_file>")
        print("Example: python custom_strategy_test.py EURUSD_M15.csv")
        sys.exit(1)
    
    csv_file = sys.argv[1]
    
    if not os.path.exists(csv_file):
        print(f"❌ File not found: {csv_file}")
        sys.exit(1)
    
    test_my_strategies(csv_file)