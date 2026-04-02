"""
PRICE ACTION PATTERN ANALYZER
Phân tích quy luật hành động giá từ file CSV MT4/MT5

Cách sử dụng:
    python pattern_analyzer.py <file_csv>
    
Ví dụ:
    python pattern_analyzer.py EURUSD_M15.csv
"""

import pandas as pd
import numpy as np
import json
from datetime import datetime
import sys
import os

class PriceActionAnalyzer:
    def __init__(self, csv_file, spread_cost=0.70):
        """Khởi tạo analyzer với file CSV
        
        Parameters:
        -----------
        csv_file : str
            Path to CSV file
        spread_cost : float
            Total spread + commission cost per round-trip trade in USD
            Default: $0.70 (typical for XAUUSD 0.01 lot)
        """
        self.csv_file = csv_file
        self.df = None
        self.results = {}
        self.spread_cost = spread_cost
        
        # Auto-detected after loading data
        self.asset_type = 'FOREX'
        self.pip_value = 0.0001
        self.pip_multiplier = 10000
        
    def load_data(self):
        """Đọc dữ liệu từ CSV"""
        print(f"\n📁 Đang đọc file: {self.csv_file}")
        try:
            self.df = pd.read_csv(self.csv_file, sep='\t')
            self.df.columns = self.df.columns.str.strip('<>').str.strip()
            
            # Tạo datetime
            self.df['datetime'] = pd.to_datetime(self.df['DATE'] + ' ' + self.df['TIME'])
            self.df = self.df.sort_values('datetime').reset_index(drop=True)
            
            print(f"✅ Đã đọc {len(self.df):,} nến")
            print(f"📅 Từ {self.df['datetime'].min()} đến {self.df['datetime'].max()}")
            return True
        except Exception as e:
            print(f"❌ Lỗi đọc file: {e}")
            return False
    
    def _detect_asset_type(self):
        """Auto-detect loại tài sản dựa trên mức giá trung bình"""
        avg_price = self.df['CLOSE'].mean()
        
        if avg_price > 10000:
            # Bitcoin (BTC): ~30,000-100,000
            self.asset_type = 'BITCOIN'
            self.pip_value = 1.0
            self.pip_multiplier = 1
            contract_units = 0.01    # 0.01 lot = 0.01 BTC
        elif avg_price > 500:
            # Gold (XAUUSD ~2000-4000), Ethereum (ETH ~1500-4000)
            self.asset_type = 'GOLD_ETH'
            self.pip_value = 0.01
            self.pip_multiplier = 100
            contract_units = 1       # 0.01 lot Gold = 1 oz
        elif avg_price > 50:
            # JPY pairs (USDJPY ~150), Silver (XAGUSD ~25-30)
            self.asset_type = 'JPY_SILVER'
            self.pip_value = 0.01
            self.pip_multiplier = 100
            contract_units = 1000    # 0.01 lot JPY = 1000 units
        else:
            # Standard Forex (EURUSD ~1.1, GBPUSD ~1.3)
            self.asset_type = 'FOREX'
            self.pip_value = 0.0001
            self.pip_multiplier = 10000
            contract_units = 1000    # 0.01 lot = 1000 units
        
        # Convert spread from USD to price terms
        # e.g. $0.70 / 1000 units = 0.0007 price for Forex (~7 pips?? too high)
        # For Forex: typical spread = 1-2 pips = 0.0001-0.0002 price
        # $0.70 is typical for Gold 0.01 lot, not Forex
        # Better: use typical spread per asset type
        typical_spread_pips = {
            'FOREX': 1.5,        # 1.5 pips for major pairs
            'JPY_SILVER': 2.0,   # 2 pips for JPY/Silver
            'GOLD_ETH': 3.0,     # 30 cents for Gold
            'BITCOIN': 50.0      # $50 for BTC
        }
        self.spread_in_price = typical_spread_pips.get(self.asset_type, 2.0) * self.pip_value
        spread_pips = self.spread_in_price * self.pip_multiplier
        
        print(f"\n🔍 Auto-detected asset type: {self.asset_type}")
        print(f"   Average price: {avg_price:.2f}")
        print(f"   Pip value: {self.pip_value}")
        print(f"   Pip multiplier: {self.pip_multiplier}")
        print(f"   Spread: {spread_pips:.1f} pips ({self.spread_in_price:.6f} price)")
    
    def calculate_indicators(self):
        """Tính toán các chỉ báo kỹ thuật"""
        # Auto-detect asset type first
        self._detect_asset_type()
        
        print("\n🔧 Đang tính toán chỉ báo...")
        
        df = self.df
        
        # Candle metrics
        df['body'] = df['CLOSE'] - df['OPEN']
        df['range'] = df['HIGH'] - df['LOW']
        df['upper_wick'] = df['HIGH'] - df[['OPEN', 'CLOSE']].max(axis=1)
        df['lower_wick'] = df[['OPEN', 'CLOSE']].min(axis=1) - df['LOW']
        df['body_pct'] = (df['body'].abs() / df['range'] * 100).fillna(0)
        
        # Candle types
        df['is_bullish'] = df['CLOSE'] > df['OPEN']
        df['is_bearish'] = df['CLOSE'] < df['OPEN']
        df['is_doji'] = df['body'].abs() < (df['range'] * 0.1)
        
        # Moving Averages
        df['sma_20'] = df['CLOSE'].rolling(20).mean()
        df['sma_50'] = df['CLOSE'].rolling(50).mean()
        df['sma_200'] = df['CLOSE'].rolling(200).mean()
        df['ema_12'] = df['CLOSE'].ewm(span=12).mean()
        df['ema_26'] = df['CLOSE'].ewm(span=26).mean()
        
        # Trend
        df['trend'] = 'sideways'
        df.loc[df['CLOSE'] > df['sma_20'], 'trend'] = 'uptrend'
        df.loc[df['CLOSE'] < df['sma_20'], 'trend'] = 'downtrend'
        
        # RSI
        delta = df['CLOSE'].diff()
        gain = (delta.where(delta > 0, 0)).rolling(window=14).mean()
        loss = (-delta.where(delta < 0, 0)).rolling(window=14).mean()
        rs = gain / loss
        df['rsi'] = 100 - (100 / (1 + rs))
        
        # ATR
        df['tr'] = df[['HIGH', 'CLOSE']].max(axis=1) - df[['LOW', 'CLOSE']].min(axis=1)
        df['atr_14'] = df['tr'].rolling(14).mean()
        
        # Bollinger Bands
        df['bb_middle'] = df['CLOSE'].rolling(20).mean()
        bb_std = df['CLOSE'].rolling(20).std()
        df['bb_upper'] = df['bb_middle'] + (bb_std * 2)
        df['bb_lower'] = df['bb_middle'] - (bb_std * 2)
        
        # MACD
        df['macd'] = df['ema_12'] - df['ema_26']
        df['macd_signal'] = df['macd'].ewm(span=9).mean()
        df['macd_histogram'] = df['macd'] - df['macd_signal']
        
        # Sessions
        df['hour'] = df['datetime'].dt.hour
        df['session'] = 'other'
        df.loc[(df['hour'] >= 8) & (df['hour'] < 16), 'session'] = 'london'
        df.loc[(df['hour'] >= 13) & (df['hour'] < 21), 'session'] = 'newyork'
        df.loc[(df['hour'] >= 0) & (df['hour'] < 8), 'session'] = 'asian'
        
        # Support/Resistance
        df['swing_high'] = (df['HIGH'] > df['HIGH'].shift(1)) & (df['HIGH'] > df['HIGH'].shift(-1))
        df['swing_low'] = (df['LOW'] < df['LOW'].shift(1)) & (df['LOW'] < df['LOW'].shift(-1))
        
        # Breakout
        df['breakout_high'] = df['HIGH'] > df['HIGH'].rolling(20).max().shift(1)
        df['breakout_low'] = df['LOW'] < df['LOW'].rolling(20).min().shift(1)
        
        # Candlestick Patterns
        self._detect_patterns()
        
        print("✅ Hoàn tất tính toán chỉ báo")
        
    def _detect_patterns(self):
        """Phát hiện các mẫu hình nến"""
        df = self.df
        
        # Hammer
        df['hammer'] = ((df['lower_wick'] > df['body'].abs() * 2) & 
                        (df['upper_wick'] < df['body'].abs() * 0.5) & 
                        (df['body'].abs() > 0))
        
        # Shooting Star
        df['shooting_star'] = ((df['upper_wick'] > df['body'].abs() * 2) & 
                               (df['lower_wick'] < df['body'].abs() * 0.5) & 
                               (df['body'].abs() > 0))
        
        # Engulfing
        df['bullish_engulfing'] = ((df['is_bullish']) & 
                                   (df['is_bearish'].shift(1)) & 
                                   (df['OPEN'] < df['CLOSE'].shift(1)) & 
                                   (df['CLOSE'] > df['OPEN'].shift(1)))
        
        df['bearish_engulfing'] = ((df['is_bearish']) & 
                                   (df['is_bullish'].shift(1)) & 
                                   (df['OPEN'] > df['CLOSE'].shift(1)) & 
                                   (df['CLOSE'] < df['OPEN'].shift(1)))
        
        # Doji Star
        df['doji_star'] = df['is_doji'] & (df['is_bullish'].shift(1) | df['is_bearish'].shift(1))
        
        # Pin Bar (Long wick one side)
        df['bullish_pin'] = ((df['lower_wick'] > df['range'] * 0.6) & 
                             (df['upper_wick'] < df['range'] * 0.2))
        
        df['bearish_pin'] = ((df['upper_wick'] > df['range'] * 0.6) & 
                             (df['lower_wick'] < df['range'] * 0.2))
    
    def test_strategy(self, entry_condition, direction='long', hold_candles=5, 
                     stop_loss_pips=None, take_profit_pips=None):
        """
        Test một chiến lược giao dịch (Realistic Backtester)
        
        Fixes applied:
        - Auto-detected pip multiplier (Gold/Forex/BTC/ETH)
        - SL checked before TP; random when both hit same bar
        - Spread cost deducted from each trade
        - Only 1 trade at a time (no overlapping)
        
        Parameters:
        -----------
        entry_condition : pandas.Series (boolean)
            Điều kiện vào lệnh (True = có tín hiệu)
        direction : str
            'long' hoặc 'short'
        hold_candles : int
            Số nến giữ lệnh
        stop_loss_pips : float
            Stop loss (pips), None = không dùng SL
        take_profit_pips : float
            Take profit (pips), None = không dùng TP
        
        Returns:
        --------
        dict : Kết quả backtest
        """
        df = self.df
        pip_val = self.pip_value
        pip_mult = self.pip_multiplier
        spread = self.spread_in_price  # Spread in price terms (converted from pips)
        
        signals = df[entry_condition].copy()
        
        if len(signals) == 0:
            return {
                'total_trades': 0,
                'win_rate': 0,
                'avg_profit': 0,
                'profit_factor': 0,
                'max_drawdown': 0
            }
        
        results = []
        next_available_idx = 0  # FIX #4: chỉ cho 1 trade tại 1 thời điểm
        
        for idx in signals.index:
            # FIX #4: Skip if still in previous trade
            if idx < next_available_idx:
                continue
            
            if idx + hold_candles >= len(df):
                continue
            
            entry_price = df.loc[idx, 'CLOSE']
            exit_idx = idx + hold_candles  # Default: exit after hold_candles
            
            # Calculate SL/TP price levels using correct pip value (FIX #1)
            if direction == 'long':
                exit_price = df.loc[idx + hold_candles, 'CLOSE']
                
                sl_price = entry_price - stop_loss_pips * pip_val if stop_loss_pips else None
                tp_price = entry_price + take_profit_pips * pip_val if take_profit_pips else None
                
                if sl_price is not None or tp_price is not None:
                    for i in range(1, hold_candles + 1):
                        if idx + i >= len(df):
                            break
                        
                        high = df.loc[idx + i, 'HIGH']
                        low = df.loc[idx + i, 'LOW']
                        
                        sl_hit = sl_price is not None and low <= sl_price
                        tp_hit = tp_price is not None and high >= tp_price
                        
                        # FIX #2: Khi cả SL và TP đều bị chạm trong cùng 1 nến
                        if sl_hit and tp_hit:
                            # Random 50/50 - không biết cái nào chạm trước
                            if np.random.random() < 0.5:
                                exit_price = sl_price
                            else:
                                exit_price = tp_price
                            exit_idx = idx + i
                            break
                        elif sl_hit:
                            # SL checked FIRST (FIX #2)
                            exit_price = sl_price
                            exit_idx = idx + i
                            break
                        elif tp_hit:
                            exit_price = tp_price
                            exit_idx = idx + i
                            break
                
                # FIX #3: Trừ spread cost (in price terms)
                profit_price = (exit_price - entry_price) - spread
                profit_pips = profit_price * pip_mult
                
            else:  # short
                exit_price = df.loc[idx + hold_candles, 'CLOSE']
                
                sl_price = entry_price + stop_loss_pips * pip_val if stop_loss_pips else None
                tp_price = entry_price - take_profit_pips * pip_val if take_profit_pips else None
                
                if sl_price is not None or tp_price is not None:
                    for i in range(1, hold_candles + 1):
                        if idx + i >= len(df):
                            break
                        
                        high = df.loc[idx + i, 'HIGH']
                        low = df.loc[idx + i, 'LOW']
                        
                        sl_hit = sl_price is not None and high >= sl_price
                        tp_hit = tp_price is not None and low <= tp_price
                        
                        # FIX #2: Random khi cả 2 đều hit
                        if sl_hit and tp_hit:
                            if np.random.random() < 0.5:
                                exit_price = sl_price
                            else:
                                exit_price = tp_price
                            exit_idx = idx + i
                            break
                        elif sl_hit:
                            exit_price = sl_price
                            exit_idx = idx + i
                            break
                        elif tp_hit:
                            exit_price = tp_price
                            exit_idx = idx + i
                            break
                
                # FIX #3: Trừ spread cost
                profit_price = (entry_price - exit_price) - spread
                profit_pips = profit_price * pip_mult
            
            # FIX #4: Mark next available index (trade must finish before new one)
            next_available_idx = exit_idx + 1
            
            results.append({
                'entry_idx': idx,
                'exit_idx': exit_idx,
                'entry_price': entry_price,
                'exit_price': exit_price,
                'profit_pips': profit_pips,
                'profit_usd': profit_price,  # Raw USD profit
                'win': profit_pips > 0
            })
        
        # Tính toán metrics
        if len(results) == 0:
            return {
                'total_trades': 0,
                'win_rate': 0,
                'avg_profit': 0,
                'profit_factor': 0,
                'max_drawdown': 0
            }
        
        results_df = pd.DataFrame(results)
        
        wins = results_df[results_df['win'] == True]
        losses = results_df[results_df['win'] == False]
        
        win_rate = len(wins) / len(results_df) * 100 if len(results_df) > 0 else 0
        avg_profit = results_df['profit_pips'].mean()
        
        total_profit = wins['profit_pips'].sum() if len(wins) > 0 else 0
        total_loss = abs(losses['profit_pips'].sum()) if len(losses) > 0 else 1
        profit_factor = total_profit / total_loss if total_loss > 0 else 0
        
        # Max Drawdown
        cumulative = results_df['profit_pips'].cumsum()
        running_max = cumulative.expanding().max()
        drawdown = cumulative - running_max
        max_drawdown = abs(drawdown.min())
        
        return {
            'total_trades': len(results_df),
            'wins': len(wins),
            'losses': len(losses),
            'win_rate': win_rate,
            'avg_profit': avg_profit,
            'avg_win': wins['profit_pips'].mean() if len(wins) > 0 else 0,
            'avg_loss': losses['profit_pips'].mean() if len(losses) > 0 else 0,
            'profit_factor': profit_factor,
            'total_profit': results_df['profit_pips'].sum(),
            'max_drawdown': max_drawdown,
            'sharpe_ratio': results_df['profit_pips'].mean() / results_df['profit_pips'].std() if results_df['profit_pips'].std() > 0 else 0
        }
    
    def analyze_all_patterns(self):
        """Phân tích tất cả các quy luật"""
        print("\n" + "="*80)
        print("BẮT ĐẦU PHÂN TÍCH CÁC QUY LUẬT")
        print("="*80)
        
        self.results = {}
        
        # 1. Consecutive Candles
        print("\n1️⃣  PHÂN TÍCH CHUỖI NẾN LIÊN TIẾP")
        print("-" * 80)
        self.results['consecutive_candles'] = self._analyze_consecutive_candles()
        
        # 2. Candlestick Patterns
        print("\n2️⃣  PHÂN TÍCH CANDLESTICK PATTERNS")
        print("-" * 80)
        self.results['candlestick_patterns'] = self._analyze_candlestick_patterns()
        
        # 3. RSI Extremes
        print("\n3️⃣  PHÂN TÍCH RSI EXTREMES")
        print("-" * 80)
        self.results['rsi_extremes'] = self._analyze_rsi_extremes()
        
        # 4. Breakout
        print("\n4️⃣  PHÂN TÍCH BREAKOUT")
        print("-" * 80)
        self.results['breakout'] = self._analyze_breakout()
        
        # 5. Session Analysis
        print("\n5️⃣  PHÂN TÍCH THEO PHIÊN GIAO DỊCH")
        print("-" * 80)
        self.results['session_analysis'] = self._analyze_sessions()
        
        # 6. Trend Following
        print("\n6️⃣  PHÂN TÍCH TREND FOLLOWING")
        print("-" * 80)
        self.results['trend_following'] = self._analyze_trend_following()
        
        # 7. Mean Reversion
        print("\n7️⃣  PHÂN TÍCH MEAN REVERSION")
        print("-" * 80)
        self.results['mean_reversion'] = self._analyze_mean_reversion()
        
        # 8. Support/Resistance
        print("\n8️⃣  PHÂN TÍCH SUPPORT/RESISTANCE")
        print("-" * 80)
        self.results['support_resistance'] = self._analyze_support_resistance()
        
        # 9. Volume Analysis
        print("\n9️⃣  PHÂN TÍCH VOLUME")
        print("-" * 80)
        self.results['volume_analysis'] = self._analyze_volume()
        
        # 10. MACD Strategies
        print("\n🔟 PHÂN TÍCH MACD STRATEGIES")
        print("-" * 80)
        self.results['macd_strategies'] = self._analyze_macd()
        
        # 11. Combined Strategies
        print("\n1️⃣1️⃣  PHÂN TÍCH CHIẾN LƯỢC KẾT HỢP")
        print("-" * 80)
        self.results['combined_strategies'] = self._analyze_combined_strategies()
        
        print("\n" + "="*80)
        print("✅ HOÀN TẤT PHÂN TÍCH")
        print("="*80)
    
    def _analyze_consecutive_candles(self):
        """Phân tích chuỗi nến liên tiếp"""
        df = self.df
        results = {}
        
        # Tính consecutive (optimized with numpy)
        is_bull = df['is_bullish'].values
        is_bear = df['is_bearish'].values
        n = len(df)
        
        cons_bull = np.zeros(n, dtype=int)
        cons_bear = np.zeros(n, dtype=int)
        
        b_streak = 0
        s_streak = 0
        for i in range(n):
            if is_bull[i]:
                b_streak += 1
                s_streak = 0
            elif is_bear[i]:
                s_streak += 1
                b_streak = 0
            else:
                b_streak = 0
                s_streak = 0
            cons_bull[i] = b_streak
            cons_bear[i] = s_streak
        
        df['consecutive_bull'] = cons_bull
        df['consecutive_bear'] = cons_bear
        
        # Test từng độ dài chuỗi
        for length in range(2, 8):
            # Sau chuỗi tăng
            condition = df['consecutive_bull'] == length
            result = self.test_strategy(condition, direction='short', hold_candles=5)
            
            print(f"Sau {length} nến tăng → SHORT:")
            print(f"  Trades: {result['total_trades']:,} | Win Rate: {result['win_rate']:.1f}% | Avg: {result['avg_profit']:.2f} pips")
            
            results[f'bull_streak_{length}'] = result
            
            # Sau chuỗi giảm
            condition = df['consecutive_bear'] == length
            result = self.test_strategy(condition, direction='long', hold_candles=5)
            
            print(f"Sau {length} nến giảm → LONG:")
            print(f"  Trades: {result['total_trades']:,} | Win Rate: {result['win_rate']:.1f}% | Avg: {result['avg_profit']:.2f} pips")
            
            results[f'bear_streak_{length}'] = result
        
        return results
    
    def _analyze_candlestick_patterns(self):
        """Phân tích các mẫu hình nến"""
        df = self.df
        results = {}
        
        patterns = {
            'hammer': ('long', 'Hammer'),
            'shooting_star': ('short', 'Shooting Star'),
            'bullish_engulfing': ('long', 'Bullish Engulfing'),
            'bearish_engulfing': ('short', 'Bearish Engulfing'),
            'bullish_pin': ('long', 'Bullish Pin Bar'),
            'bearish_pin': ('short', 'Bearish Pin Bar')
        }
        
        for pattern_col, (direction, pattern_name) in patterns.items():
            if pattern_col in df.columns:
                condition = df[pattern_col] == True
                result = self.test_strategy(condition, direction=direction, hold_candles=5)
                
                print(f"{pattern_name}:")
                print(f"  Trades: {result['total_trades']:,} | Win Rate: {result['win_rate']:.1f}% | Avg: {result['avg_profit']:.2f} pips")
                
                results[pattern_col] = result
        
        return results
    
    def _analyze_rsi_extremes(self):
        """Phân tích RSI cực đoan"""
        df = self.df
        results = {}
        
        # RSI Oversold
        for threshold in [20, 25, 30]:
            condition = df['rsi'] < threshold
            result = self.test_strategy(condition, direction='long', hold_candles=5)
            
            print(f"RSI < {threshold} → LONG:")
            print(f"  Trades: {result['total_trades']:,} | Win Rate: {result['win_rate']:.1f}% | Avg: {result['avg_profit']:.2f} pips")
            
            results[f'rsi_oversold_{threshold}'] = result
        
        # RSI Overbought
        for threshold in [70, 75, 80]:
            condition = df['rsi'] > threshold
            result = self.test_strategy(condition, direction='short', hold_candles=5)
            
            print(f"RSI > {threshold} → SHORT:")
            print(f"  Trades: {result['total_trades']:,} | Win Rate: {result['win_rate']:.1f}% | Avg: {result['avg_profit']:.2f} pips")
            
            results[f'rsi_overbought_{threshold}'] = result
        
        return results
    
    def _analyze_breakout(self):
        """Phân tích breakout"""
        df = self.df
        results = {}
        
        # Breakout High
        condition = df['breakout_high'] == True
        result = self.test_strategy(condition, direction='long', hold_candles=10)
        
        print(f"Breakout High → LONG:")
        print(f"  Trades: {result['total_trades']:,} | Win Rate: {result['win_rate']:.1f}% | Avg: {result['avg_profit']:.2f} pips")
        
        results['breakout_high'] = result
        
        # Breakout Low
        condition = df['breakout_low'] == True
        result = self.test_strategy(condition, direction='short', hold_candles=10)
        
        print(f"Breakout Low → SHORT:")
        print(f"  Trades: {result['total_trades']:,} | Win Rate: {result['win_rate']:.1f}% | Avg: {result['avg_profit']:.2f} pips")
        
        results['breakout_low'] = result
        
        # Breakout với Volume cao
        condition = (df['breakout_high']) & (df['TICKVOL'] > df['TICKVOL'].rolling(20).mean())
        result = self.test_strategy(condition, direction='long', hold_candles=10)
        
        print(f"Breakout High + Volume → LONG:")
        print(f"  Trades: {result['total_trades']:,} | Win Rate: {result['win_rate']:.1f}% | Avg: {result['avg_profit']:.2f} pips")
        
        results['breakout_high_volume'] = result
        
        return results
    
    def _analyze_sessions(self):
        """Phân tích theo phiên"""
        df = self.df
        results = {}
        
        for session in ['asian', 'london', 'newyork']:
            session_df = df[df['session'] == session]
            
            if len(session_df) == 0:
                continue
            
            # Range statistics
            avg_range = session_df['range'].mean() * 10000
            avg_volume = session_df['TICKVOL'].mean()
            
            # Test buy at open
            condition = df['session'] == session
            result_long = self.test_strategy(condition, direction='long', hold_candles=4)
            result_short = self.test_strategy(condition, direction='short', hold_candles=4)
            
            print(f"\n{session.upper()}:")
            print(f"  Avg Range: {avg_range:.2f} pips | Avg Volume: {avg_volume:.0f}")
            print(f"  LONG - Trades: {result_long['total_trades']:,} | Win Rate: {result_long['win_rate']:.1f}% | Avg: {result_long['avg_profit']:.2f} pips")
            print(f"  SHORT - Trades: {result_short['total_trades']:,} | Win Rate: {result_short['win_rate']:.1f}% | Avg: {result_short['avg_profit']:.2f} pips")
            
            results[session] = {
                'avg_range_pips': avg_range,
                'avg_volume': avg_volume,
                'long': result_long,
                'short': result_short
            }
        
        return results
    
    def _analyze_trend_following(self):
        """Phân tích trend following"""
        df = self.df
        results = {}
        
        # Price > SMA20 (Uptrend)
        condition = (df['CLOSE'] > df['sma_20']) & (df['CLOSE'].shift(1) <= df['sma_20'].shift(1))
        result = self.test_strategy(condition, direction='long', hold_candles=20)
        
        print(f"Price crosses above SMA20 → LONG:")
        print(f"  Trades: {result['total_trades']:,} | Win Rate: {result['win_rate']:.1f}% | Avg: {result['avg_profit']:.2f} pips")
        
        results['cross_above_sma20'] = result
        
        # Price < SMA20 (Downtrend)
        condition = (df['CLOSE'] < df['sma_20']) & (df['CLOSE'].shift(1) >= df['sma_20'].shift(1))
        result = self.test_strategy(condition, direction='short', hold_candles=20)
        
        print(f"Price crosses below SMA20 → SHORT:")
        print(f"  Trades: {result['total_trades']:,} | Win Rate: {result['win_rate']:.1f}% | Avg: {result['avg_profit']:.2f} pips")
        
        results['cross_below_sma20'] = result
        
        # Golden Cross
        condition = (df['ema_12'] > df['ema_26']) & (df['ema_12'].shift(1) <= df['ema_26'].shift(1))
        result = self.test_strategy(condition, direction='long', hold_candles=50)
        
        print(f"Golden Cross (EMA12 > EMA26) → LONG:")
        print(f"  Trades: {result['total_trades']:,} | Win Rate: {result['win_rate']:.1f}% | Avg: {result['avg_profit']:.2f} pips")
        
        results['golden_cross'] = result
        
        # Death Cross
        condition = (df['ema_12'] < df['ema_26']) & (df['ema_12'].shift(1) >= df['ema_26'].shift(1))
        result = self.test_strategy(condition, direction='short', hold_candles=50)
        
        print(f"Death Cross (EMA12 < EMA26) → SHORT:")
        print(f"  Trades: {result['total_trades']:,} | Win Rate: {result['win_rate']:.1f}% | Avg: {result['avg_profit']:.2f} pips")
        
        results['death_cross'] = result
        
        return results
    
    def _analyze_mean_reversion(self):
        """Phân tích mean reversion"""
        df = self.df
        results = {}
        
        # Price touches lower Bollinger Band
        condition = df['CLOSE'] <= df['bb_lower']
        result = self.test_strategy(condition, direction='long', hold_candles=10)
        
        print(f"Price touches BB Lower → LONG:")
        print(f"  Trades: {result['total_trades']:,} | Win Rate: {result['win_rate']:.1f}% | Avg: {result['avg_profit']:.2f} pips")
        
        results['bb_lower_touch'] = result
        
        # Price touches upper Bollinger Band
        condition = df['CLOSE'] >= df['bb_upper']
        result = self.test_strategy(condition, direction='short', hold_candles=10)
        
        print(f"Price touches BB Upper → SHORT:")
        print(f"  Trades: {result['total_trades']:,} | Win Rate: {result['win_rate']:.1f}% | Avg: {result['avg_profit']:.2f} pips")
        
        results['bb_upper_touch'] = result
        
        # Deviation from SMA
        df['deviation_from_sma'] = ((df['CLOSE'] - df['sma_20']) / df['sma_20'] * 100).abs()
        
        condition = (df['CLOSE'] < df['sma_20']) & (df['deviation_from_sma'] > 0.5)
        result = self.test_strategy(condition, direction='long', hold_candles=10)
        
        print(f"Price far below SMA20 (>0.5%) → LONG:")
        print(f"  Trades: {result['total_trades']:,} | Win Rate: {result['win_rate']:.1f}% | Avg: {result['avg_profit']:.2f} pips")
        
        results['far_below_sma'] = result
        
        return results
    
    def _analyze_support_resistance(self):
        """Phân tích support/resistance"""
        df = self.df
        results = {}
        
        # Buy at Swing Low
        condition = df['swing_low'] == True
        result = self.test_strategy(condition, direction='long', hold_candles=10)
        
        print(f"Buy at Swing Low → LONG:")
        print(f"  Trades: {result['total_trades']:,} | Win Rate: {result['win_rate']:.1f}% | Avg: {result['avg_profit']:.2f} pips")
        
        results['buy_swing_low'] = result
        
        # Sell at Swing High
        condition = df['swing_high'] == True
        result = self.test_strategy(condition, direction='short', hold_candles=10)
        
        print(f"Sell at Swing High → SHORT:")
        print(f"  Trades: {result['total_trades']:,} | Win Rate: {result['win_rate']:.1f}% | Avg: {result['avg_profit']:.2f} pips")
        
        results['sell_swing_high'] = result
        
        return results
    
    def _analyze_volume(self):
        """Phân tích volume"""
        df = self.df
        results = {}
        
        # High volume + bullish candle
        condition = (df['TICKVOL'] > df['TICKVOL'].rolling(20).mean() * 1.5) & (df['is_bullish'])
        result = self.test_strategy(condition, direction='long', hold_candles=5)
        
        print(f"High Volume + Bullish → LONG:")
        print(f"  Trades: {result['total_trades']:,} | Win Rate: {result['win_rate']:.1f}% | Avg: {result['avg_profit']:.2f} pips")
        
        results['high_volume_bullish'] = result
        
        # High volume + bearish candle
        condition = (df['TICKVOL'] > df['TICKVOL'].rolling(20).mean() * 1.5) & (df['is_bearish'])
        result = self.test_strategy(condition, direction='short', hold_candles=5)
        
        print(f"High Volume + Bearish → SHORT:")
        print(f"  Trades: {result['total_trades']:,} | Win Rate: {result['win_rate']:.1f}% | Avg: {result['avg_profit']:.2f} pips")
        
        results['high_volume_bearish'] = result
        
        return results
    
    def _analyze_macd(self):
        """Phân tích các chiến lược dựa trên MACD"""
        df = self.df
        results = {}
        
        # 1. MACD Signal Crossover (Bullish)
        condition = ((df['macd'] > df['macd_signal']) & 
                     (df['macd'].shift(1) <= df['macd_signal'].shift(1)))
        result = self.test_strategy(condition, direction='long', hold_candles=10)
        
        print(f"MACD Cross Above Signal → LONG:")
        print(f"  Trades: {result['total_trades']:,} | Win Rate: {result['win_rate']:.1f}% | Avg: {result['avg_profit']:.2f} pips")
        
        results['macd_cross_bullish'] = result
        
        # 2. MACD Signal Crossover (Bearish)
        condition = ((df['macd'] < df['macd_signal']) & 
                     (df['macd'].shift(1) >= df['macd_signal'].shift(1)))
        result = self.test_strategy(condition, direction='short', hold_candles=10)
        
        print(f"MACD Cross Below Signal → SHORT:")
        print(f"  Trades: {result['total_trades']:,} | Win Rate: {result['win_rate']:.1f}% | Avg: {result['avg_profit']:.2f} pips")
        
        results['macd_cross_bearish'] = result
        
        # 3. MACD Zero-Line Cross (Bullish)
        condition = ((df['macd'] > 0) & (df['macd'].shift(1) <= 0))
        result = self.test_strategy(condition, direction='long', hold_candles=15)
        
        print(f"MACD Crosses Above Zero → LONG:")
        print(f"  Trades: {result['total_trades']:,} | Win Rate: {result['win_rate']:.1f}% | Avg: {result['avg_profit']:.2f} pips")
        
        results['macd_zero_cross_up'] = result
        
        # 4. MACD Zero-Line Cross (Bearish)
        condition = ((df['macd'] < 0) & (df['macd'].shift(1) >= 0))
        result = self.test_strategy(condition, direction='short', hold_candles=15)
        
        print(f"MACD Crosses Below Zero → SHORT:")
        print(f"  Trades: {result['total_trades']:,} | Win Rate: {result['win_rate']:.1f}% | Avg: {result['avg_profit']:.2f} pips")
        
        results['macd_zero_cross_down'] = result
        
        # 5. MACD Histogram Reversal (Bullish: histogram turns from negative to positive)
        condition = ((df['macd_histogram'] > 0) & 
                     (df['macd_histogram'].shift(1) <= 0) &
                     (df['macd'] < 0))  # Below zero = early reversal
        result = self.test_strategy(condition, direction='long', hold_candles=10)
        
        print(f"MACD Histogram Reversal (below zero) → LONG:")
        print(f"  Trades: {result['total_trades']:,} | Win Rate: {result['win_rate']:.1f}% | Avg: {result['avg_profit']:.2f} pips")
        
        results['macd_histogram_reversal_bull'] = result
        
        # 6. MACD Histogram Reversal (Bearish)
        condition = ((df['macd_histogram'] < 0) & 
                     (df['macd_histogram'].shift(1) >= 0) &
                     (df['macd'] > 0))
        result = self.test_strategy(condition, direction='short', hold_candles=10)
        
        print(f"MACD Histogram Reversal (above zero) → SHORT:")
        print(f"  Trades: {result['total_trades']:,} | Win Rate: {result['win_rate']:.1f}% | Avg: {result['avg_profit']:.2f} pips")
        
        results['macd_histogram_reversal_bear'] = result
        
        # 7. MACD + Trend (Price > SMA200 + MACD crossover)
        if 'sma_200' in df.columns:
            condition = ((df['CLOSE'] > df['sma_200']) &
                         (df['macd'] > df['macd_signal']) & 
                         (df['macd'].shift(1) <= df['macd_signal'].shift(1)) &
                         (df['macd'] < 0))  # Cross while below zero = strongest signal
            result = self.test_strategy(condition, direction='long', hold_candles=15,
                                       stop_loss_pips=20, take_profit_pips=40)
            
            print(f"\nMACD Cross + above SMA200 + MACD<0 → LONG:")
            print(f"  Trades: {result['total_trades']:,} | Win Rate: {result['win_rate']:.1f}%")
            print(f"  Avg: {result['avg_profit']:.2f} pips | PF: {result['profit_factor']:.2f}")
            
            results['macd_trend_combo_long'] = result
            
            # Bearish version
            condition = ((df['CLOSE'] < df['sma_200']) &
                         (df['macd'] < df['macd_signal']) & 
                         (df['macd'].shift(1) >= df['macd_signal'].shift(1)) &
                         (df['macd'] > 0))
            result = self.test_strategy(condition, direction='short', hold_candles=15,
                                       stop_loss_pips=20, take_profit_pips=40)
            
            print(f"MACD Cross + below SMA200 + MACD>0 → SHORT:")
            print(f"  Trades: {result['total_trades']:,} | Win Rate: {result['win_rate']:.1f}%")
            print(f"  Avg: {result['avg_profit']:.2f} pips | PF: {result['profit_factor']:.2f}")
            
            results['macd_trend_combo_short'] = result
        
        return results
    
    def _analyze_combined_strategies(self):
        """Phân tích chiến lược kết hợp"""
        df = self.df
        results = {}
        
        # Strategy 1: Trend + RSI + Pattern
        condition = ((df['CLOSE'] > df['sma_20']) & 
                    (df['rsi'] < 50) & 
                    (df['bullish_engulfing'] | df['hammer']))
        result = self.test_strategy(condition, direction='long', hold_candles=10, 
                                   stop_loss_pips=15, take_profit_pips=30)
        
        print(f"Uptrend + RSI<50 + Bullish Pattern → LONG:")
        print(f"  Trades: {result['total_trades']:,} | Win Rate: {result['win_rate']:.1f}%")
        print(f"  Avg: {result['avg_profit']:.2f} pips | PF: {result['profit_factor']:.2f}")
        
        results['trend_rsi_pattern_long'] = result
        
        # Strategy 2: Mean Reversion + Volume
        condition = ((df['CLOSE'] <= df['bb_lower']) & 
                    (df['rsi'] < 30) & 
                    (df['TICKVOL'] > df['TICKVOL'].rolling(20).mean()))
        result = self.test_strategy(condition, direction='long', hold_candles=10,
                                   stop_loss_pips=20, take_profit_pips=30)
        
        print(f"\nBB Lower + RSI<30 + Volume → LONG:")
        print(f"  Trades: {result['total_trades']:,} | Win Rate: {result['win_rate']:.1f}%")
        print(f"  Avg: {result['avg_profit']:.2f} pips | PF: {result['profit_factor']:.2f}")
        
        results['mean_reversion_volume'] = result
        
        # Strategy 3: Breakout + Trend + Volume
        condition = ((df['breakout_high']) & 
                    (df['CLOSE'] > df['sma_50']) & 
                    (df['TICKVOL'] > df['TICKVOL'].rolling(20).mean() * 1.5))
        result = self.test_strategy(condition, direction='long', hold_candles=15,
                                   stop_loss_pips=20, take_profit_pips=40)
        
        print(f"\nBreakout + Uptrend + High Volume → LONG:")
        print(f"  Trades: {result['total_trades']:,} | Win Rate: {result['win_rate']:.1f}%")
        print(f"  Avg: {result['avg_profit']:.2f} pips | PF: {result['profit_factor']:.2f}")
        
        results['breakout_trend_volume'] = result
        
        # Strategy 4: Consecutive + RSI
        condition = ((df['consecutive_bull'] >= 5) & (df['rsi'] > 70))
        result = self.test_strategy(condition, direction='short', hold_candles=10,
                                   stop_loss_pips=15, take_profit_pips=25)
        
        print(f"\n5+ Bull Candles + RSI>70 → SHORT:")
        print(f"  Trades: {result['total_trades']:,} | Win Rate: {result['win_rate']:.1f}%")
        print(f"  Avg: {result['avg_profit']:.2f} pips | PF: {result['profit_factor']:.2f}")
        
        results['consecutive_rsi_reversal'] = result
        
        # Strategy 5: Asian Range Breakout
        condition = ((df['session'] == 'asian') & 
                    (df['breakout_high']) & 
                    (df['hour'].isin([7, 8])))  # End of Asian session
        result = self.test_strategy(condition, direction='long', hold_candles=8,
                                   stop_loss_pips=12, take_profit_pips=20)
        
        print(f"\nAsian Range Breakout (7-8h) → LONG:")
        print(f"  Trades: {result['total_trades']:,} | Win Rate: {result['win_rate']:.1f}%")
        print(f"  Avg: {result['avg_profit']:.2f} pips | PF: {result['profit_factor']:.2f}")
        
        results['asian_breakout'] = result
        
        return results
    
    def generate_report(self, output_file='analysis_report.json'):
        """Tạo báo cáo JSON"""
        print(f"\n📝 Đang tạo báo cáo...")
        
        # Chuyển đổi results để có thể serialize
        def convert_to_serializable(obj):
            if isinstance(obj, (np.integer, np.floating)):
                return float(obj)
            elif isinstance(obj, np.ndarray):
                return obj.tolist()
            elif isinstance(obj, dict):
                return {k: convert_to_serializable(v) for k, v in obj.items()}
            elif isinstance(obj, list):
                return [convert_to_serializable(item) for item in obj]
            return obj
        
        serializable_results = convert_to_serializable(self.results)
        
        # Detect timeframe from data
        if len(self.df) >= 2:
            time_diff = (self.df['datetime'].iloc[1] - self.df['datetime'].iloc[0]).total_seconds()
            if time_diff <= 60:
                timeframe = 'M1'
            elif time_diff <= 300:
                timeframe = 'M5'
            elif time_diff <= 900:
                timeframe = 'M15'
            elif time_diff <= 1800:
                timeframe = 'M30'
            elif time_diff <= 3600:
                timeframe = 'H1'
            elif time_diff <= 14400:
                timeframe = 'H4'
            elif time_diff <= 86400:
                timeframe = 'D1'
            else:
                timeframe = 'W1'
        else:
            timeframe = 'UNKNOWN'
        
        report = {
            'metadata': {
                'file': self.csv_file,
                'total_candles': len(self.df),
                'start_date': str(self.df['datetime'].min()),
                'end_date': str(self.df['datetime'].max()),
                'analysis_date': str(datetime.now()),
                'asset_type': self.asset_type,
                'pip_value': self.pip_value,
                'pip_multiplier': self.pip_multiplier,
                'timeframe': timeframe
            },
            'results': serializable_results
        }
        
        with open(output_file, 'w', encoding='utf-8') as f:
            json.dump(report, f, indent=2, ensure_ascii=False)
        
        print(f"✅ Báo cáo đã lưu: {output_file}")
        
        # Tạo summary
        self._print_summary()
    
    def _print_summary(self):
        """In tóm tắt kết quả tốt nhất"""
        print("\n" + "="*80)
        print("🏆 TOP 10 CHIẾN LƯỢC TỐT NHẤT (theo Win Rate)")
        print("="*80)
        
        all_strategies = []
        
        for category, strategies in self.results.items():
            if isinstance(strategies, dict):
                for strategy_name, result in strategies.items():
                    if isinstance(result, dict) and 'win_rate' in result and result['total_trades'] >= 50:
                        all_strategies.append({
                            'category': category,
                            'name': strategy_name,
                            'win_rate': result['win_rate'],
                            'total_trades': result['total_trades'],
                            'avg_profit': result['avg_profit'],
                            'profit_factor': result.get('profit_factor', 0),
                            'total_profit': result.get('total_profit', 0)
                        })
        
        # Sort by win rate
        all_strategies.sort(key=lambda x: x['win_rate'], reverse=True)
        
        print(f"\n{'Rank':<6} {'Strategy':<40} {'Trades':<10} {'Win%':<10} {'Avg':<12} {'PF':<8}")
        print("-" * 90)
        
        for i, strategy in enumerate(all_strategies[:10], 1):
            print(f"{i:<6} {strategy['name'][:40]:<40} {strategy['total_trades']:<10} "
                  f"{strategy['win_rate']:<10.1f} {strategy['avg_profit']:<12.2f} {strategy['profit_factor']:<8.2f}")
        
        print("\n" + "="*80)
        print("🏆 TOP 10 CHIẾN LƯỢC TỐT NHẤT (theo Profit Factor)")
        print("="*80)
        
        all_strategies.sort(key=lambda x: x['profit_factor'], reverse=True)
        
        print(f"\n{'Rank':<6} {'Strategy':<40} {'Trades':<10} {'PF':<10} {'Avg':<12} {'Win%':<8}")
        print("-" * 90)
        
        for i, strategy in enumerate(all_strategies[:10], 1):
            print(f"{i:<6} {strategy['name'][:40]:<40} {strategy['total_trades']:<10} "
                  f"{strategy['profit_factor']:<10.2f} {strategy['avg_profit']:<12.2f} {strategy['win_rate']:<8.1f}")
        
        print("\n" + "="*80)
        print("💰 TOP 10 CHIẾN LƯỢC TỐT NHẤT (theo Total Profit)")
        print("="*80)
        
        all_strategies.sort(key=lambda x: x['total_profit'], reverse=True)
        
        print(f"\n{'Rank':<6} {'Strategy':<40} {'Trades':<10} {'Total':<12} {'Avg':<12} {'Win%':<8}")
        print("-" * 90)
        
        for i, strategy in enumerate(all_strategies[:10], 1):
            print(f"{i:<6} {strategy['name'][:40]:<40} {strategy['total_trades']:<10} "
                  f"{strategy['total_profit']:<12.1f} {strategy['avg_profit']:<12.2f} {strategy['win_rate']:<8.1f}")


def main():
    if len(sys.argv) < 2:
        print("Usage: python pattern_analyzer.py <csv_file>")
        print("Example: python pattern_analyzer.py EURUSD_M15.csv")
        sys.exit(1)
    
    csv_file = sys.argv[1]
    
    if not os.path.exists(csv_file):
        print(f"❌ File not found: {csv_file}")
        sys.exit(1)
    
    # Khởi tạo analyzer
    analyzer = PriceActionAnalyzer(csv_file)
    
    # Load dữ liệu
    if not analyzer.load_data():
        sys.exit(1)
    
    # Tính toán indicators
    analyzer.calculate_indicators()
    
    # Phân tích tất cả patterns
    analyzer.analyze_all_patterns()
    
    # Tạo báo cáo - lưu vào thư mục hiện tại
    base_name = os.path.basename(csv_file).replace('.csv', '')
    report_file = f'{base_name}_analysis.json'
    analyzer.generate_report(report_file)
    
    print(f"\n✅ Hoàn tất! Kết quả đã lưu tại: {report_file}")


if __name__ == "__main__":
    main()