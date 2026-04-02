"""
MARKET EFFICIENCY INDEX (MEI)
Đo độ hiệu quả của thị trường để xác định khả năng profit của algo trading

Lý thuyết:
- Thị trường hiệu quả = Random walk = Khó kiếm lợi
- Thị trường kém hiệu quả = Có patterns = Dễ kiếm lợi

MEI Score: 0-100
- 0-30: Inefficient (Tốt cho algo trading)
- 30-60: Semi-efficient (Moderate opportunity)
- 60-100: Highly efficient (Khó kiếm lợi)

Sử dụng:
    python market_efficiency_index.py EURUSD_M15.csv
"""

import pandas as pd
import numpy as np
from math import factorial
import json
import sys
import os
import matplotlib
matplotlib.use('Agg')  # Non-interactive backend
import matplotlib.pyplot as plt
import matplotlib.dates as mdates

class MarketEfficiencyIndex:
    def __init__(self, csv_file):
        self.csv_file = csv_file
        self.df = None
        self.mei_score = 0
        self.components = {}
        
    def load_data(self):
        """Load dữ liệu"""
        print(f"\n📁 Đang đọc: {self.csv_file}")
        
        self.df = pd.read_csv(self.csv_file, sep='\t')
        self.df.columns = self.df.columns.str.strip('<>').str.strip()
        self.df['datetime'] = pd.to_datetime(self.df['DATE'] + ' ' + self.df['TIME'])
        self.df = self.df.sort_values('datetime').reset_index(drop=True)
        
        # Auto-detect timeframe
        self._detect_timeframe()
        
        print(f"✅ Đã load {len(self.df):,} nến")
    
    def _detect_timeframe(self):
        """Detect timeframe từ tên file (format: PAIR_TF.csv)"""
        tf_bars = {
            'M1': 1440,
            'M5': 288,
            'M15': 96,
            'M30': 48,
            'H1': 24,
            'H4': 6,
            'D1': 1,
        }
        
        # Lấy tên file không có extension
        base_name = os.path.basename(self.csv_file).replace('.csv', '')
        
        # Tách phần timeframe (phần cuối sau dấu _)
        parts = base_name.upper().split('_')
        tf_found = None
        
        for part in reversed(parts):
            if part in tf_bars:
                tf_found = part
                break
        
        if tf_found:
            self.timeframe_name = tf_found
            self.bars_per_day = tf_bars[tf_found]
        else:
            print(f"⚠️  Không tìm thấy timeframe trong tên file '{base_name}'")
            print(f"   Định dạng yêu cầu: PAIR_TF.csv (VD: XAUUSD_M15.csv)")
            print(f"   Timeframe hỗ trợ: {', '.join(tf_bars.keys())}")
            print(f"   → Mặc định sử dụng M15")
            self.timeframe_name = 'M15'
            self.bars_per_day = 96
        
        self.annualization_factor = np.sqrt(252 * self.bars_per_day)
        
        print(f"🔍 Timeframe: {self.timeframe_name} ({self.bars_per_day} bars/day)")
        print(f"   Annualization factor: {self.annualization_factor:.1f}")
        
    def calculate_all_components(self):
        """Tính toán tất cả components của MEI"""
        print("\n🔧 Đang tính toán Market Efficiency Index...")
        
        df = self.df
        
        # Returns
        df['returns'] = df['CLOSE'].pct_change()
        df['log_returns'] = np.log(df['CLOSE'] / df['CLOSE'].shift(1))
        
        # 1. HURST EXPONENT (40% weight)
        print("\n1️⃣  Hurst Exponent...")
        self.components['hurst'] = self._calculate_hurst()
        
        # 2. AUTOCORRELATION (20% weight)
        print("2️⃣  Autocorrelation...")
        self.components['autocorr'] = self._calculate_autocorrelation()
        
        # 3. VARIANCE RATIO TEST (15% weight)
        print("3️⃣  Variance Ratio Test...")
        self.components['variance_ratio'] = self._calculate_variance_ratio()
        
        # 4. RUNS TEST (10% weight)
        print("4️⃣  Runs Test...")
        self.components['runs_test'] = self._calculate_runs_test()
        
        # 5. ENTROPY (10% weight)
        print("5️⃣  Entropy...")
        self.components['entropy'] = self._calculate_entropy()
        
        # 6. PREDICTABILITY (5% weight)
        print("6️⃣  Predictability Score...")
        self.components['predictability'] = self._calculate_predictability()
        
        print("\n✅ Hoàn tất tính toán components")
        
    def _calculate_hurst(self):
        """
        Hurst Exponent: Đo xu hướng trending/mean-reverting
        
        H < 0.5: Mean reverting (Inefficient - Tốt)
        H = 0.5: Random walk (Efficient - Xấu)
        H > 0.5: Trending (Có thể exploit - Tốt)
        
        Return: Score 0-100 (100 = most efficient)
        """
        prices = self.df['CLOSE'].values[-5000:]  # Use 5000 candles
        
        lags = range(2, 100)
        tau = []
        
        for lag in lags:
            std = np.std(np.subtract(prices[lag:], prices[:-lag]))
            tau.append(std)
        
        reg = np.polyfit(np.log(lags), np.log(tau), 1)
        hurst = reg[0]
        
        # Convert to efficiency score
        # H = 0.5 → Score = 100 (most efficient)
        # H far from 0.5 → Score = 0 (inefficient)
        efficiency_score = 100 - (abs(hurst - 0.5) * 200)
        efficiency_score = max(0, min(100, efficiency_score))
        
        return {
            'value': float(hurst),
            'score': float(efficiency_score),
            'interpretation': self._interpret_hurst(hurst)
        }
    
    def _interpret_hurst(self, h):
        """Giải thích Hurst exponent"""
        if h < 0.4:
            return "Strong Mean Reversion (Good for reversal strategies)"
        elif h < 0.45:
            return "Moderate Mean Reversion (Moderately inefficient)"
        elif h < 0.55:
            return "Random Walk (Highly efficient - Hard to profit)"
        elif h < 0.6:
            return "Moderate Trending (Moderately inefficient)"
        else:
            return "Strong Trending (Good for trend strategies)"
    
    def _calculate_autocorrelation(self):
        """
        Autocorrelation: Đo mức độ returns phụ thuộc vào quá khứ
        
        AC ≈ 0: Random (Efficient)
        AC ≠ 0: Có patterns (Inefficient)
        
        Return: Score 0-100
        """
        returns = self.df['returns'].dropna().values[-5000:]
        
        # Calculate autocorrelation cho lags 1-10
        autocorrs = []
        for lag in range(1, 11):
            ac = np.corrcoef(returns[:-lag], returns[lag:])[0, 1]
            autocorrs.append(abs(ac))
        
        avg_autocorr = np.mean(autocorrs)
        
        # Convert to efficiency score
        # AC = 0 → Score = 100 (efficient)
        # AC high → Score = 0 (inefficient)
        efficiency_score = 100 - (avg_autocorr * 1000)
        efficiency_score = max(0, min(100, efficiency_score))
        
        return {
            'value': float(avg_autocorr),
            'lags': {f'lag_{i+1}': float(ac) for i, ac in enumerate(autocorrs)},
            'score': float(efficiency_score),
            'interpretation': "High serial correlation - Inefficient" if avg_autocorr > 0.05 
                            else "Low serial correlation - Efficient"
        }
    
    def _calculate_variance_ratio(self):
        """
        Variance Ratio Test (Lo-MacKinlay): So sánh variance ngắn hạn vs dài hạn
        
        Sử dụng LOG RETURNS (additive property) thay vì pct_change
        
        VR = 1: Random walk (Efficient)
        VR ≠ 1: Có patterns (Inefficient)
        
        Return: Score 0-100
        """
        # FIX #3: Dùng log returns thay vì pct_change
        log_returns = self.df['log_returns'].dropna().values[-5000:]
        
        q = 10  # Aggregation period
        
        # Variance of 1-period log returns
        var_1 = np.var(log_returns, ddof=1)
        
        # Variance of q-period log returns (log returns CAN be summed)
        n = len(log_returns)
        log_returns_q = []
        for i in range(0, n - q, q):
            log_ret_q = np.sum(log_returns[i:i+q])
            log_returns_q.append(log_ret_q)
        
        var_q = np.var(log_returns_q, ddof=1) / q  # Normalize by period
        
        # Variance ratio
        vr = var_q / var_1 if var_1 > 0 else 1
        
        # Z-statistic for significance
        nq = len(log_returns_q)
        z_stat = (vr - 1) / np.sqrt(2 * (q - 1) / (nq * q)) if nq > 0 else 0
        
        # Convert to efficiency score
        # VR = 1 → Score = 100 (efficient)
        # VR far from 1 → Score = 0 (inefficient)
        efficiency_score = 100 - (abs(vr - 1) * 50)
        efficiency_score = max(0, min(100, efficiency_score))
        
        return {
            'value': float(vr),
            'z_statistic': float(z_stat),
            'significant': bool(abs(z_stat) > 1.96),
            'score': float(efficiency_score),
            'interpretation': "Random walk" if abs(z_stat) < 1.96 
                            else "Mean reversion" if vr < 1 
                            else "Momentum/Trending"
        }
    
    def _calculate_runs_test(self):
        """
        Runs Test: Đo tính random của chuỗi +/-
        
        Too few/many runs → Có patterns (Inefficient)
        Expected runs → Random (Efficient)
        
        Return: Score 0-100
        """
        returns = self.df['returns'].dropna().values[-5000:]
        
        # Convert to +/- sequence
        signs = np.sign(returns)
        signs = signs[signs != 0]  # Remove zeros
        
        # Count runs
        runs = 1
        for i in range(1, len(signs)):
            if signs[i] != signs[i-1]:
                runs += 1
        
        # Expected runs under random walk
        n_pos = np.sum(signs > 0)
        n_neg = np.sum(signs < 0)
        n = len(signs)
        
        expected_runs = (2 * n_pos * n_neg / n) + 1
        
        # Standard deviation
        std_runs = np.sqrt((2 * n_pos * n_neg * (2 * n_pos * n_neg - n)) / 
                          (n**2 * (n - 1)))
        
        # Z-score
        z_score = (runs - expected_runs) / std_runs if std_runs > 0 else 0
        
        # Convert to efficiency score
        # z near 0 → Random → Score = 100 (efficient)
        # z far from 0 → Patterns → Score = 0 (inefficient)
        efficiency_score = 100 - (abs(z_score) * 30)
        efficiency_score = max(0, min(100, efficiency_score))
        
        return {
            'actual_runs': int(runs),
            'expected_runs': float(expected_runs),
            'z_score': float(z_score),
            'score': float(efficiency_score),
            'interpretation': "Random sequence" if abs(z_score) < 1.96 
                            else "Too few runs (trending)" if z_score < -1.96
                            else "Too many runs (mean reverting)"
        }
    
    def _calculate_entropy(self):
        """
        Permutation Entropy: Đo complexity thực sự của chuỗi thời gian
        
        Thay vì Shannon Entropy trên histogram (luôn cao do bell curve),
        dùng Permutation Entropy đo thứ tự (ordinal patterns) trong chuỗi giá.
        
        High PE → Random → Efficient
        Low PE → Predictable patterns → Inefficient
        
        Return: Score 0-100
        """
        prices = self.df['CLOSE'].values[-5000:]
        
        # Permutation Entropy parameters
        order = 4       # Embedding dimension (pattern length)
        delay = 1       # Time delay
        
        n = len(prices)
        
        # Count ordinal patterns
        pattern_counts = {}
        total_patterns = 0
        
        for i in range(n - (order - 1) * delay):
            # Extract subsequence
            subseq = [prices[i + j * delay] for j in range(order)]
            # Convert to ordinal pattern (rank order)
            pattern = tuple(sorted(range(order), key=lambda k: subseq[k]))
            pattern_counts[pattern] = pattern_counts.get(pattern, 0) + 1
            total_patterns += 1
        
        # Calculate probabilities
        probs = np.array(list(pattern_counts.values())) / total_patterns
        
        # Permutation entropy
        pe = -np.sum(probs * np.log2(probs))
        
        # Max entropy = log2(order!)
        max_pe = np.log2(factorial(order))
        
        # Normalized permutation entropy (0 = deterministic, 1 = random)
        normalized_pe = pe / max_pe
        
        # Number of distinct patterns found vs possible
        possible_patterns = factorial(order)
        found_patterns = len(pattern_counts)
        
        # Convert to efficiency score
        # High PE → Score = 100 (efficient/random)
        efficiency_score = normalized_pe * 100
        
        return {
            'value': float(pe),
            'normalized': float(normalized_pe),
            'patterns_found': found_patterns,
            'patterns_possible': possible_patterns,
            'score': float(efficiency_score),
            'interpretation': "Highly random (efficient)" if normalized_pe > 0.95
                            else "Mostly random" if normalized_pe > 0.85
                            else "Some predictable patterns" if normalized_pe > 0.7
                            else "Significant predictable patterns (inefficient)"
        }
    
    def _calculate_predictability(self):
        """
        Predictability Score: Test simple strategies
        
        Nếu simple strategies work → Inefficient
        Nếu không work → Efficient
        
        Return: Score 0-100
        """
        df = self.df.copy()
        
        # Test 1: Moving Average Crossover
        df['sma_5'] = df['CLOSE'].rolling(5).mean()
        df['sma_20'] = df['CLOSE'].rolling(20).mean()
        df['signal_ma'] = (df['sma_5'] > df['sma_20']).astype(int)
        df['returns'] = df['CLOSE'].pct_change()
        df['strategy_returns_ma'] = df['signal_ma'].shift(1) * df['returns']
        
        # Test 2: RSI Mean Reversion
        # FIX #1: RSI < 30 → BUY (signal=+1), RSI > 70 → SELL (signal=-1)
        delta = df['CLOSE'].diff()
        gain = (delta.where(delta > 0, 0)).rolling(14).mean()
        loss = (-delta.where(delta < 0, 0)).rolling(14).mean()
        rs = gain / loss
        df['rsi'] = 100 - (100 / (1 + rs))
        df['signal_rsi'] = 0
        df.loc[df['rsi'] < 30, 'signal_rsi'] = 1    # Oversold → BUY
        df.loc[df['rsi'] > 70, 'signal_rsi'] = -1   # Overbought → SELL
        df['strategy_returns_rsi'] = df['signal_rsi'].shift(1) * df['returns']
        
        # Test 3: Momentum
        df['momentum'] = df['CLOSE'] - df['CLOSE'].shift(10)
        df['signal_mom'] = (df['momentum'] > 0).astype(int)
        df['strategy_returns_mom'] = df['signal_mom'].shift(1) * df['returns']
        
        # Calculate Sharpe ratios
        sharpe_ma = self._calculate_sharpe(df['strategy_returns_ma'])
        sharpe_rsi = self._calculate_sharpe(df['strategy_returns_rsi'])
        sharpe_mom = self._calculate_sharpe(df['strategy_returns_mom'])
        
        avg_sharpe = np.mean([sharpe_ma, sharpe_rsi, sharpe_mom])
        
        # Convert to efficiency score
        # High Sharpe → Strategies work → Inefficient → Score = 0
        # Low Sharpe → Strategies fail → Efficient → Score = 100
        efficiency_score = 100 - (max(0, avg_sharpe) * 50)
        efficiency_score = max(0, min(100, efficiency_score))
        
        return {
            'ma_sharpe': float(sharpe_ma),
            'rsi_sharpe': float(sharpe_rsi),
            'momentum_sharpe': float(sharpe_mom),
            'avg_sharpe': float(avg_sharpe),
            'score': float(efficiency_score),
            'interpretation': "Simple strategies work (Inefficient)" if avg_sharpe > 0.5
                            else "Simple strategies fail (Efficient)"
        }
    
    def _calculate_sharpe(self, returns):
        """Calculate Sharpe ratio (auto-annualized based on detected timeframe)"""
        returns = returns.dropna()
        if len(returns) == 0 or returns.std() == 0:
            return 0
        # FIX #2: Dùng annualization factor auto-detected thay vì hardcode M15
        return returns.mean() / returns.std() * self.annualization_factor
    
    def calculate_mei(self):
        """
        Tính Market Efficiency Index tổng hợp
        
        Weighted average của các components:
        - Hurst: 40%
        - Autocorrelation: 20%
        - Variance Ratio: 15%
        - Runs Test: 10%
        - Entropy: 10%
        - Predictability: 5%
        """
        weights = {
            'hurst': 0.40,
            'autocorr': 0.20,
            'variance_ratio': 0.15,
            'runs_test': 0.10,
            'entropy': 0.10,
            'predictability': 0.05
        }
        
        mei_score = 0
        for component, weight in weights.items():
            score = self.components[component]['score']
            mei_score += score * weight
        
        self.mei_score = mei_score
        
        return mei_score
    
    def get_classification(self):
        """Phân loại thị trường dựa trên MEI"""
        score = self.mei_score
        
        if score < 30:
            return {
                'class': 'INEFFICIENT',
                'color': '🟢',
                'description': 'Excellent for algo trading',
                'recommendation': 'TRADE AGGRESSIVELY',
                'strategies': [
                    'Mean reversion',
                    'Pattern recognition',
                    'Statistical arbitrage',
                    'High frequency trading'
                ]
            }
        elif score < 50:
            return {
                'class': 'SEMI-EFFICIENT',
                'color': '🟡',
                'description': 'Moderate opportunities',
                'recommendation': 'TRADE SELECTIVELY',
                'strategies': [
                    'Selective pattern trading',
                    'Regime-based strategies',
                    'Combine multiple factors',
                    'Longer holding periods'
                ]
            }
        elif score < 70:
            return {
                'class': 'EFFICIENT',
                'color': '🟠',
                'description': 'Difficult to profit',
                'recommendation': 'TRADE CAUTIOUSLY',
                'strategies': [
                    'Focus on execution quality',
                    'Reduce trading frequency',
                    'Risk management priority',
                    'Consider other markets'
                ]
            }
        else:
            return {
                'class': 'HIGHLY EFFICIENT',
                'color': '🔴',
                'description': 'Very hard to profit',
                'recommendation': 'AVOID OR MINIMIZE',
                'strategies': [
                    'Market making only',
                    'Ultra HFT strategies',
                    'Find other markets',
                    'Focus on fundamentals'
                ]
            }
    
    def generate_report(self, output_file='market_efficiency_report.json'):
        """Tạo báo cáo chi tiết"""
        classification = self.get_classification()
        
        report = {
            'metadata': {
                'file': self.csv_file,
                'total_candles': len(self.df),
                'analysis_date': str(pd.Timestamp.now())
            },
            'mei_score': float(self.mei_score),
            'classification': classification,
            'components': self.components,
            'summary': self._generate_summary()
        }
        
        with open(output_file, 'w') as f:
            json.dump(report, f, indent=2)
        
        return report
    
    def _generate_summary(self):
        """Tạo summary insights"""
        h = self.components['hurst']['value']
        ac = self.components['autocorr']['value']
        vr = self.components['variance_ratio']['value']
        
        insights = []
        
        # Hurst insights
        if h < 0.45:
            insights.append("Market shows mean-reverting behavior - good for reversal strategies")
        elif h > 0.55:
            insights.append("Market shows trending behavior - good for momentum strategies")
        else:
            insights.append("Market behaves like random walk - very efficient")
        
        # Autocorrelation insights
        if ac > 0.05:
            insights.append("Significant autocorrelation detected - patterns exist")
        else:
            insights.append("Low autocorrelation - market is efficient")
        
        # Variance ratio insights
        if abs(vr - 1) > 0.3:
            insights.append("Variance ratio deviates from 1 - market is not purely random")
        
        return insights
    
    def print_report(self):
        """In báo cáo ra console"""
        print("\n" + "="*80)
        print("📊 MARKET EFFICIENCY INDEX REPORT")
        print("="*80)
        
        classification = self.get_classification()
        
        print(f"\n{classification['color']} OVERALL MEI SCORE: {self.mei_score:.1f}/100")
        print(f"   Classification: {classification['class']}")
        print(f"   {classification['description']}")
        
        print(f"\n💡 RECOMMENDATION: {classification['recommendation']}")
        
        print("\n" + "="*80)
        print("📈 COMPONENT SCORES")
        print("="*80)
        
        components_display = [
            ('Hurst Exponent', 'hurst', 40),
            ('Autocorrelation', 'autocorr', 20),
            ('Variance Ratio', 'variance_ratio', 15),
            ('Runs Test', 'runs_test', 10),
            ('Entropy', 'entropy', 10),
            ('Predictability', 'predictability', 5)
        ]
        
        for name, key, weight in components_display:
            comp = self.components[key]
            score = comp['score']
            bar = self._create_progress_bar(score)
            
            print(f"\n{name} ({weight}% weight):")
            print(f"  Score: {score:.1f}/100 {bar}")
            
            # Some components don't have 'value' key
            if 'value' in comp:
                print(f"  Value: {comp['value']:.4f}")
            
            print(f"  {comp['interpretation']}")
        
        print("\n" + "="*80)
        print("🎯 RECOMMENDED STRATEGIES")
        print("="*80)
        
        for i, strategy in enumerate(classification['strategies'], 1):
            print(f"{i}. {strategy}")
        
        print("\n" + "="*80)
        print("💡 KEY INSIGHTS")
        print("="*80)
        
        summary = self._generate_summary()
        for i, insight in enumerate(summary, 1):
            print(f"{i}. {insight}")
        
        print("\n" + "="*80)
        print("📊 INTERPRETATION GUIDE")
        print("="*80)
        
        print("""
MEI Score Ranges:
├── 0-30:   🟢 INEFFICIENT - Excellent for algo trading
├── 30-50:  🟡 SEMI-EFFICIENT - Moderate opportunities
├── 50-70:  🟠 EFFICIENT - Difficult to profit
└── 70-100: 🔴 HIGHLY EFFICIENT - Very hard to profit

Component Meanings:
├── Hurst < 0.5:  Mean reverting (patterns exist)
├── Hurst = 0.5:  Random walk (efficient)
├── Hurst > 0.5:  Trending (exploitable)
├── Low AC:       No serial correlation (efficient)
├── High AC:      Predictable from past (inefficient)
├── VR = 1:       Random walk (efficient)
└── VR ≠ 1:       Non-random patterns (inefficient)
        """)
    
    def _create_progress_bar(self, score, width=30):
        """Tạo progress bar"""
        filled = int(score / 100 * width)
        bar = '█' * filled + '░' * (width - filled)
        
        if score < 30:
            color = '🟢'
        elif score < 50:
            color = '🟡'
        elif score < 70:
            color = '🟠'
        else:
            color = '🔴'
        
        return f"{color} [{bar}]"
    
    # ================================================================
    # ROLLING MEI
    # ================================================================
    
    def calculate_rolling_mei(self, window=500, step=50):
        """
        Tính Rolling MEI trên toàn bộ dữ liệu.
        
        Sử dụng 4 components nhanh (bỏ Predictability vì quá chậm):
        - Hurst Exponent (45%)
        - Autocorrelation (25%)
        - Variance Ratio (15%)
        - Runs Test (15%)
        
        Parameters:
        -----------
        window : int
            Số nến trong mỗi window (default: 500)
        step : int
            Bước nhảy giữa các windows (default: 50)
        
        Returns:
        --------
        pd.DataFrame : columns = ['datetime', 'price', 'mei_score', 
                                   'hurst', 'autocorr', 'var_ratio', 'runs']
        """
        df = self.df
        n = len(df)
        
        if n < window:
            print(f"⚠️  Dữ liệu quá ít ({n} nến < window {window})")
            return None
        
        # Precompute returns & log returns
        prices = df['CLOSE'].values
        returns = np.diff(prices) / prices[:-1]  # pct_change
        log_returns = np.log(prices[1:] / prices[:-1])
        
        results = []
        total_steps = (n - window) // step + 1
        
        print(f"\n📊 Tính Rolling MEI (window={window}, step={step})...")
        print(f"   Tổng số windows: {total_steps:,}")
        
        for i, start in enumerate(range(0, n - window + 1, step)):
            end = start + window
            
            # Progress
            if (i + 1) % 100 == 0 or i == 0 or i == total_steps - 1:
                pct = (i + 1) / total_steps * 100
                print(f"   [{pct:5.1f}%] Window {i+1}/{total_steps}", end='\r')
            
            w_prices = prices[start:end]
            w_returns = returns[start:end-1]  # returns is 1 shorter than prices
            w_log_returns = log_returns[start:end-1]
            
            # Fast Hurst
            h_score, h_val = self._fast_hurst(w_prices)
            
            # Fast Autocorrelation
            ac_score, ac_val = self._fast_autocorr(w_returns)
            
            # Fast Variance Ratio
            vr_score, vr_val = self._fast_variance_ratio(w_log_returns)
            
            # Fast Runs Test
            rt_score, rt_val = self._fast_runs_test(w_returns)
            
            # Weighted MEI (redistributed weights without Predictability)
            mei = (h_score * 0.45 + ac_score * 0.25 + 
                   vr_score * 0.15 + rt_score * 0.15)
            
            results.append({
                'datetime': df.loc[end - 1, 'datetime'],
                'price': w_prices[-1],
                'mei_score': mei,
                'hurst': h_val,
                'autocorr': ac_val,
                'var_ratio': vr_val,
                'runs_z': rt_val
            })
        
        print(f"   ✅ Hoàn tất {len(results):,} windows                    ")
        
        self.rolling_df = pd.DataFrame(results)
        return self.rolling_df
    
    def _fast_hurst(self, prices):
        """Fast Hurst Exponent cho rolling window"""
        lags = range(2, min(50, len(prices) // 4))
        tau = []
        for lag in lags:
            std = np.std(prices[lag:] - prices[:-lag])
            if std > 0:
                tau.append(std)
            else:
                tau.append(1e-10)
        
        if len(tau) < 2:
            return 50.0, 0.5
        
        reg = np.polyfit(np.log(list(lags)[:len(tau)]), np.log(tau), 1)
        hurst = reg[0]
        
        score = 100 - (abs(hurst - 0.5) * 200)
        score = max(0, min(100, score))
        return score, hurst
    
    def _fast_autocorr(self, returns):
        """Fast Autocorrelation cho rolling window"""
        if len(returns) < 12:
            return 100.0, 0.0
        
        autocorrs = []
        for lag in range(1, 6):  # Only lags 1-5 for speed
            if len(returns) > lag:
                ac = np.corrcoef(returns[:-lag], returns[lag:])[0, 1]
                if not np.isnan(ac):
                    autocorrs.append(abs(ac))
        
        if not autocorrs:
            return 100.0, 0.0
        
        avg_ac = np.mean(autocorrs)
        score = 100 - (avg_ac * 1000)
        score = max(0, min(100, score))
        return score, avg_ac
    
    def _fast_variance_ratio(self, log_returns):
        """Fast Variance Ratio cho rolling window"""
        if len(log_returns) < 20:
            return 100.0, 1.0
        
        q = 10
        var_1 = np.var(log_returns, ddof=1)
        if var_1 == 0:
            return 100.0, 1.0
        
        lr_q = []
        for i in range(0, len(log_returns) - q, q):
            lr_q.append(np.sum(log_returns[i:i+q]))
        
        if len(lr_q) < 2:
            return 100.0, 1.0
        
        var_q = np.var(lr_q, ddof=1) / q
        vr = var_q / var_1
        
        score = 100 - (abs(vr - 1) * 50)
        score = max(0, min(100, score))
        return score, vr
    
    def _fast_runs_test(self, returns):
        """Fast Runs Test cho rolling window"""
        signs = np.sign(returns)
        signs = signs[signs != 0]
        
        if len(signs) < 10:
            return 50.0, 0.0
        
        # Count runs
        runs = 1 + np.sum(signs[1:] != signs[:-1])
        
        n_pos = np.sum(signs > 0)
        n_neg = np.sum(signs < 0)
        n = len(signs)
        
        if n_pos == 0 or n_neg == 0:
            return 50.0, 0.0
        
        expected = (2 * n_pos * n_neg / n) + 1
        denom = n**2 * (n - 1)
        if denom == 0:
            return 50.0, 0.0
        
        std_runs = np.sqrt((2 * n_pos * n_neg * (2 * n_pos * n_neg - n)) / denom)
        
        if std_runs == 0:
            return 50.0, 0.0
        
        z = (runs - expected) / std_runs
        
        score = 100 - (abs(z) * 30)
        score = max(0, min(100, score))
        return score, float(z)
    
    # ================================================================
    # CHART VISUALIZATION
    # ================================================================
    
    def plot_rolling_mei(self, output_file=None):
        """
        Vẽ chart 2 panel:
        - Trên: Price chart
        - Dưới: Rolling MEI với vùng tô màu
        
        Parameters:
        -----------
        output_file : str
            Path file .png output. None = auto-generate từ csv_file
        """
        if not hasattr(self, 'rolling_df') or self.rolling_df is None:
            print("⚠️  Chưa tính Rolling MEI. Gọi calculate_rolling_mei() trước.")
            return
        
        rdf = self.rolling_df
        
        if output_file is None:
            base = os.path.basename(self.csv_file).replace('.csv', '')
            output_file = f'{base}_rolling_mei.png'
        
        # Setup figure
        fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(20, 10), 
                                        height_ratios=[2, 1],
                                        sharex=True)
        fig.patch.set_facecolor('#1a1a2e')
        
        # ─── Panel 1: Price Chart ───
        ax1.set_facecolor('#16213e')
        ax1.plot(rdf['datetime'], rdf['price'], 
                color='#e94560', linewidth=0.8, alpha=0.9)
        ax1.set_ylabel('Price', color='#eee', fontsize=12)
        ax1.tick_params(colors='#aaa')
        ax1.grid(True, alpha=0.15, color='#444')
        ax1.spines['top'].set_visible(False)
        ax1.spines['right'].set_visible(False)
        ax1.spines['left'].set_color('#444')
        ax1.spines['bottom'].set_color('#444')
        
        # Title
        base_name = os.path.basename(self.csv_file).replace('.csv', '')
        ax1.set_title(f'{base_name} — Rolling Market Efficiency Index', 
                     color='#eee', fontsize=16, fontweight='bold', pad=15)
        
        # ─── Panel 2: Rolling MEI ───
        ax2.set_facecolor('#16213e')
        
        mei_vals = rdf['mei_score'].values
        datetimes = rdf['datetime'].values
        
        # Background zones
        ax2.axhspan(0, 30, alpha=0.12, color='#00ff88', label='Inefficient (Trade)')  
        ax2.axhspan(30, 50, alpha=0.10, color='#ffdd57', label='Semi-efficient')
        ax2.axhspan(50, 100, alpha=0.10, color='#ff4444', label='Efficient (Avoid)')
        
        # Zone boundaries
        ax2.axhline(y=30, color='#00ff88', linewidth=0.5, linestyle='--', alpha=0.5)
        ax2.axhline(y=50, color='#ff4444', linewidth=0.5, linestyle='--', alpha=0.5)
        
        # MEI line - color segments based on value
        for i in range(len(mei_vals) - 1):
            val = mei_vals[i]
            if val < 30:
                color = '#00ff88'  # Green - Inefficient (good)
            elif val < 50:
                color = '#ffdd57'  # Yellow
            else:
                color = '#ff4444'  # Red - Efficient (bad)
            ax2.plot(datetimes[i:i+2], mei_vals[i:i+2], 
                    color=color, linewidth=1.2)
        
        # Moving average overlay
        if len(mei_vals) > 20:
            ma = pd.Series(mei_vals).rolling(20, min_periods=1).mean()
            ax2.plot(datetimes, ma, color='white', linewidth=1.5, 
                    alpha=0.7, linestyle='-', label='MA(20)')
        
        ax2.set_ylabel('MEI Score', color='#eee', fontsize=12)
        ax2.set_xlabel('Time', color='#eee', fontsize=12)
        ax2.set_ylim(0, 100)
        ax2.tick_params(colors='#aaa')
        ax2.grid(True, alpha=0.15, color='#444')
        ax2.spines['top'].set_visible(False)
        ax2.spines['right'].set_visible(False)
        ax2.spines['left'].set_color('#444')
        ax2.spines['bottom'].set_color('#444')
        
        # Legend
        ax2.legend(loc='upper right', fontsize=9, 
                  facecolor='#1a1a2e', edgecolor='#444', labelcolor='#eee')
        
        # X-axis formatting
        ax2.xaxis.set_major_formatter(mdates.DateFormatter('%Y-%m-%d'))
        fig.autofmt_xdate(rotation=30)
        
        # Stats annotation
        avg_mei = np.mean(mei_vals)
        min_mei = np.min(mei_vals)
        max_mei = np.max(mei_vals)
        pct_inefficient = np.sum(mei_vals < 30) / len(mei_vals) * 100
        pct_semi = np.sum((mei_vals >= 30) & (mei_vals < 50)) / len(mei_vals) * 100
        pct_efficient = np.sum(mei_vals >= 50) / len(mei_vals) * 100
        
        stats_text = (f'Avg: {avg_mei:.1f}  |  Min: {min_mei:.1f}  |  Max: {max_mei:.1f}\n'
                     f'[GREEN] Inefficient: {pct_inefficient:.1f}%  |  '
                     f'[YELLOW] Semi: {pct_semi:.1f}%  |  '
                     f'[RED] Efficient: {pct_efficient:.1f}%')
        
        ax2.text(0.01, 0.95, stats_text, transform=ax2.transAxes,
                fontsize=9, color='#eee', verticalalignment='top',
                bbox=dict(boxstyle='round,pad=0.4', facecolor='#1a1a2e', 
                         edgecolor='#444', alpha=0.9))
        
        plt.tight_layout()
        plt.savefig(output_file, dpi=150, bbox_inches='tight', 
                   facecolor=fig.get_facecolor())
        plt.close()
        
        print(f"\n📈 Chart saved: {output_file}")
        print(f"   Average MEI: {avg_mei:.1f}")
        print(f"   🟢 Inefficient windows: {pct_inefficient:.1f}%")
        print(f"   🟡 Semi-efficient windows: {pct_semi:.1f}%")
        print(f"   🔴 Efficient windows: {pct_efficient:.1f}%")
        
        return output_file


def main():
    if len(sys.argv) < 2:
        print("""
╔═══════════════════════════════════════════════════════════════╗
║           MARKET EFFICIENCY INDEX (MEI) CALCULATOR            ║
╚═══════════════════════════════════════════════════════════════╝

Đo độ hiệu quả của thị trường để xác định khả năng profit

Usage:
    python market_efficiency_index.py <csv_file>

Example:
    python market_efficiency_index.py EURUSD_M15.csv

Output:
    - MEI Score (0-100)
    - Classification (Inefficient/Semi/Efficient/Highly Efficient)
    - Component analysis
    - Strategy recommendations
    - JSON report

Lý thuyết:
    - Score 0-30:   Inefficient → Tốt cho algo trading
    - Score 30-50:  Semi-efficient → Cơ hội vừa phải
    - Score 50-70:  Efficient → Khó kiếm lợi
    - Score 70-100: Highly efficient → Rất khó kiếm lợi
        """)
        sys.exit(1)
    
    csv_file = sys.argv[1]
    
    if not os.path.exists(csv_file):
        print(f"❌ File not found: {csv_file}")
        sys.exit(1)
    
    # Run analysis
    mei = MarketEfficiencyIndex(csv_file)
    mei.load_data()
    mei.calculate_all_components()
    mei_score = mei.calculate_mei()
    
    # Print report
    mei.print_report()
    
    # Save JSON
    base_name = os.path.basename(csv_file).replace('.csv', '')
    output_file = f'{base_name}_efficiency_report.json'
    mei.generate_report(output_file)
    print(f"\n✅ Report saved: {output_file}")
    
    # Rolling MEI + Chart
    print("\n" + "="*80)
    print("📊 ROLLING MEI ANALYSIS")
    print("="*80)
    
    rolling_df = mei.calculate_rolling_mei(window=500, step=50)
    if rolling_df is not None:
        chart_file = mei.plot_rolling_mei()
        
        # Save rolling data to CSV
        rolling_csv = f'{base_name}_rolling_mei.csv'
        rolling_df.to_csv(rolling_csv, index=False)
        print(f"📄 Rolling data saved: {rolling_csv}")
    
    print(f"\n✅ Hoàn tất tất cả phân tích!\n")


if __name__ == "__main__":
    main()