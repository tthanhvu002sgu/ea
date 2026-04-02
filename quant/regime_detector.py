"""
MARKET REGIME DETECTOR
Phát hiện chế độ thị trường (Trending, Ranging, Volatile) bằng Machine Learning

Sử dụng:
    python regime_detector.py EURUSD_M15.csv
"""

import pandas as pd
import numpy as np
from sklearn.ensemble import RandomForestClassifier
from sklearn.preprocessing import StandardScaler
from sklearn.model_selection import train_test_split
import json
import sys
import os

class MarketRegimeDetector:
    def __init__(self, csv_file):
        self.csv_file = csv_file
        self.df = None
        self.model = None
        self.scaler = StandardScaler()
        self.regimes = {
            0: 'RANGING',
            1: 'TRENDING_UP', 
            2: 'TRENDING_DOWN',
            3: 'VOLATILE'
        }
        
    def load_data(self):
        """Load dữ liệu từ CSV"""
        print(f"\n📁 Đang đọc file: {self.csv_file}")
        
        self.df = pd.read_csv(self.csv_file, sep='\t')
        self.df.columns = self.df.columns.str.strip('<>').str.strip()
        self.df['datetime'] = pd.to_datetime(self.df['DATE'] + ' ' + self.df['TIME'])
        self.df = self.df.sort_values('datetime').reset_index(drop=True)
        
        print(f"✅ Đã đọc {len(self.df):,} nến")
        
    def calculate_regime_features(self):
        """Tính toán các features để phát hiện regime"""
        print("\n🔧 Đang tính toán regime features...")
        
        df = self.df
        
        # Price features
        df['returns'] = df['CLOSE'].pct_change()
        df['log_returns'] = np.log(df['CLOSE'] / df['CLOSE'].shift(1))
        
        # Volatility features
        df['volatility_10'] = df['returns'].rolling(10).std()
        df['volatility_20'] = df['returns'].rolling(20).std()
        df['volatility_50'] = df['returns'].rolling(50).std()
        
        # Trend features
        df['sma_10'] = df['CLOSE'].rolling(10).mean()
        df['sma_20'] = df['CLOSE'].rolling(20).mean()
        df['sma_50'] = df['CLOSE'].rolling(50).mean()
        df['sma_200'] = df['CLOSE'].rolling(200).mean()
        
        # ADX (Average Directional Index) - Đo trend strength
        high = df['HIGH']
        low = df['LOW']
        close = df['CLOSE']
        
        plus_dm = high.diff()
        minus_dm = -low.diff()
        
        plus_dm[plus_dm < 0] = 0
        minus_dm[minus_dm < 0] = 0
        
        tr1 = pd.DataFrame(high - low)
        tr2 = pd.DataFrame(abs(high - close.shift(1)))
        tr3 = pd.DataFrame(abs(low - close.shift(1)))
        frames = [tr1, tr2, tr3]
        tr = pd.concat(frames, axis=1, join='inner').max(axis=1)
        atr = tr.rolling(14).mean()
        
        plus_di = 100 * (plus_dm.rolling(14).mean() / atr)
        minus_di = 100 * (minus_dm.rolling(14).mean() / atr)
        
        dx = (abs(plus_di - minus_di) / abs(plus_di + minus_di)) * 100
        df['adx'] = dx.rolling(14).mean()
        df['plus_di'] = plus_di
        df['minus_di'] = minus_di
        
        # ATR
        df['atr'] = atr
        df['atr_pct'] = (df['atr'] / df['CLOSE']) * 100
        
        # Range features
        df['range'] = df['HIGH'] - df['LOW']
        df['range_pct'] = (df['range'] / df['CLOSE']) * 100
        
        # Bollinger Bands
        df['bb_middle'] = df['CLOSE'].rolling(20).mean()
        bb_std = df['CLOSE'].rolling(20).std()
        df['bb_upper'] = df['bb_middle'] + (bb_std * 2)
        df['bb_lower'] = df['bb_middle'] - (bb_std * 2)
        df['bb_width'] = (df['bb_upper'] - df['bb_lower']) / df['bb_middle']
        df['bb_position'] = (df['CLOSE'] - df['bb_lower']) / (df['bb_upper'] - df['bb_lower'])
        
        # Price position relative to MAs
        df['price_vs_sma20'] = (df['CLOSE'] - df['sma_20']) / df['sma_20'] * 100
        df['price_vs_sma50'] = (df['CLOSE'] - df['sma_50']) / df['sma_50'] * 100
        
        # MA slopes
        df['sma20_slope'] = df['sma_20'].pct_change(5)
        df['sma50_slope'] = df['sma_50'].pct_change(10)
        
        # Higher highs / Lower lows count
        df['hh_count'] = 0
        df['ll_count'] = 0
        
        for i in range(20, len(df)):
            recent_highs = df['HIGH'].iloc[i-20:i]
            recent_lows = df['LOW'].iloc[i-20:i]
            
            hh = sum(recent_highs > recent_highs.shift(1))
            ll = sum(recent_lows < recent_lows.shift(1))
            
            df.loc[i, 'hh_count'] = hh
            df.loc[i, 'll_count'] = ll
        
        # Hurst Exponent (trend persistence)
        df['hurst'] = 0.0
        for i in range(100, len(df)):
            prices = df['CLOSE'].iloc[i-100:i].values
            lags = range(2, 20)
            tau = []
            for lag in lags:
                std = np.std(np.subtract(prices[lag:], prices[:-lag]))
                tau.append(std)
            
            if len(tau) > 0 and all(t > 0 for t in tau):
                reg = np.polyfit(np.log(lags), np.log(tau), 1)
                df.loc[i, 'hurst'] = reg[0]
        
        print("✅ Hoàn tất tính toán features")
        
    def label_regimes(self):
        """Gán nhãn regime cho từng candle (supervised learning)"""
        print("\n🏷️  Đang gán nhãn regime...")
        
        df = self.df
        df['regime'] = 0  # Default: RANGING
        
        # Rule-based labeling (để train model)
        for i in range(50, len(df)):
            adx = df.loc[i, 'adx']
            volatility = df.loc[i, 'volatility_20']
            price_vs_sma = df.loc[i, 'price_vs_sma20']
            sma_slope = df.loc[i, 'sma20_slope']
            hurst = df.loc[i, 'hurst']
            bb_width = df.loc[i, 'bb_width']
            
            # VOLATILE: High volatility + wide BB
            if volatility > df['volatility_20'].quantile(0.8) and bb_width > df['bb_width'].quantile(0.8):
                df.loc[i, 'regime'] = 3  # VOLATILE
            
            # TRENDING_UP: Strong uptrend
            elif (adx > 25 and 
                  df.loc[i, 'plus_di'] > df.loc[i, 'minus_di'] and
                  price_vs_sma > 0.1 and 
                  sma_slope > 0 and
                  hurst > 0.55):
                df.loc[i, 'regime'] = 1  # TRENDING_UP
            
            # TRENDING_DOWN: Strong downtrend  
            elif (adx > 25 and 
                  df.loc[i, 'minus_di'] > df.loc[i, 'plus_di'] and
                  price_vs_sma < -0.1 and 
                  sma_slope < 0 and
                  hurst > 0.55):
                df.loc[i, 'regime'] = 2  # TRENDING_DOWN
            
            # RANGING: Low ADX, mean reverting
            else:
                df.loc[i, 'regime'] = 0  # RANGING
        
        # Statistics
        regime_counts = df['regime'].value_counts().sort_index()
        print("\nPhân bố Regime:")
        for regime_id, count in regime_counts.items():
            regime_name = self.regimes[regime_id]
            pct = count / len(df) * 100
            print(f"  {regime_name}: {count:,} ({pct:.1f}%)")
        
        return df
        
    def train_model(self):
        """Train Random Forest model để dự đoán regime"""
        print("\n🤖 Đang train Machine Learning model...")
        
        df = self.df
        
        # Features cho model
        feature_cols = [
            'adx', 'plus_di', 'minus_di',
            'volatility_10', 'volatility_20', 'volatility_50',
            'atr_pct', 'bb_width', 'bb_position',
            'price_vs_sma20', 'price_vs_sma50',
            'sma20_slope', 'sma50_slope',
            'hh_count', 'll_count',
            'hurst', 'range_pct'
        ]
        
        # Prepare data
        df_clean = df.dropna(subset=feature_cols + ['regime'])
        
        X = df_clean[feature_cols]
        y = df_clean['regime']
        
        # Split train/test
        X_train, X_test, y_train, y_test = train_test_split(
            X, y, test_size=0.3, random_state=42, stratify=y
        )
        
        # Scale features
        X_train_scaled = self.scaler.fit_transform(X_train)
        X_test_scaled = self.scaler.transform(X_test)
        
        # Train Random Forest
        self.model = RandomForestClassifier(
            n_estimators=100,
            max_depth=10,
            min_samples_split=50,
            min_samples_leaf=20,
            random_state=42,
            n_jobs=-1
        )
        
        self.model.fit(X_train_scaled, y_train)
        
        # Evaluate
        train_score = self.model.score(X_train_scaled, y_train)
        test_score = self.model.score(X_test_scaled, y_test)
        
        print(f"\n📊 Model Performance:")
        print(f"  Training Accuracy: {train_score*100:.1f}%")
        print(f"  Testing Accuracy: {test_score*100:.1f}%")
        
        # Feature importance
        feature_importance = pd.DataFrame({
            'feature': feature_cols,
            'importance': self.model.feature_importances_
        }).sort_values('importance', ascending=False)
        
        print(f"\n🎯 Top 10 Most Important Features:")
        for idx, row in feature_importance.head(10).iterrows():
            print(f"  {row['feature']:<20}: {row['importance']:.4f}")
        
        return feature_cols
        
    def predict_regime(self, features):
        """Dự đoán regime cho một candle"""
        features_scaled = self.scaler.transform([features])
        regime_id = self.model.predict(features_scaled)[0]
        regime_proba = self.model.predict_proba(features_scaled)[0]
        
        return {
            'regime': self.regimes[regime_id],
            'regime_id': int(regime_id),
            'confidence': float(regime_proba[regime_id]),
            'probabilities': {
                self.regimes[i]: float(p) 
                for i, p in enumerate(regime_proba)
            }
        }
        
    def analyze_regime_performance(self, analyzer):
        """Phân tích performance của các strategies theo regime"""
        print("\n" + "="*80)
        print("📊 PHÂN TÍCH PERFORMANCE THEO REGIME")
        print("="*80)
        
        df = self.df
        adf = analyzer.df
        
        # Transfer regime labels from detector.df to analyzer.df by index alignment
        # Both DataFrames loaded from same CSV so row indices should match
        # But lengths may differ due to different dropna/filtering
        # Use the minimum overlapping index range
        common_idx = adf.index.intersection(df.index)
        
        if len(common_idx) == 0:
            print("⚠️  Cannot align regime labels with analyzer data.")
            return {}
        
        # Add regime column to analyzer DataFrame
        adf['regime'] = np.nan
        adf.loc[common_idx, 'regime'] = df.loc[common_idx, 'regime'].values
        adf['regime'] = adf['regime'].fillna(0).astype(int)
        
        # Test strategies trong từng regime
        results = {}
        
        for regime_id, regime_name in self.regimes.items():
            print(f"\n{'='*80}")
            print(f"REGIME: {regime_name}")
            print(f"{'='*80}")
            
            # Build condition from analyzer.df (correct length)
            regime_mask = adf['regime'] == regime_id
            regime_count = regime_mask.sum()
            
            if regime_count < 100:
                print(f"  ⚠️  Không đủ dữ liệu ({regime_count} nến)")
                continue
            
            results[regime_name] = {}
            
            # Test swing high (sell) - condition on analyzer.df
            swing_high_condition = (
                regime_mask & 
                (adf['HIGH'] > adf['HIGH'].shift(1)) & 
                (adf['HIGH'] > adf['HIGH'].shift(-1))
            )
            
            if swing_high_condition.sum() > 10:
                result = analyzer.test_strategy(swing_high_condition, 'short', 10)
                print(f"\n  Sell at Swing High:")
                print(f"    Trades: {result['total_trades']:,} | Win Rate: {result['win_rate']:.1f}% | Avg: {result['avg_profit']:.2f} pips")
                results[regime_name]['sell_swing_high'] = result
            
            # Test RSI oversold (buy)
            if 'rsi' in adf.columns:
                rsi_condition = regime_mask & (adf['rsi'] < 30)
                
                if rsi_condition.sum() > 10:
                    result = analyzer.test_strategy(rsi_condition, 'long', 5)
                    print(f"\n  RSI < 30 LONG:")
                    print(f"    Trades: {result['total_trades']:,} | Win Rate: {result['win_rate']:.1f}% | Avg: {result['avg_profit']:.2f} pips")
                    results[regime_name]['rsi_oversold'] = result
            
            # Test breakout high
            if 'breakout_high' in adf.columns:
                breakout_condition = regime_mask & (adf['breakout_high'] == True)
                
                if breakout_condition.sum() > 10:
                    result = analyzer.test_strategy(breakout_condition, 'long', 10)
                    print(f"\n  Breakout High:")
                    print(f"    Trades: {result['total_trades']:,} | Win Rate: {result['win_rate']:.1f}% | Avg: {result['avg_profit']:.2f} pips")
                    results[regime_name]['breakout_high'] = result
        
        return results
        
    def generate_report(self, output_file='regime_analysis.json'):
        """Tạo báo cáo regime detection"""
        print(f"\n📝 Đang tạo báo cáo...")
        
        df = self.df
        
        # Regime transitions
        df['regime_change'] = df['regime'] != df['regime'].shift(1)
        transitions = df[df['regime_change']].copy()
        
        regime_durations = []
        for i in range(1, len(transitions)):
            start_idx = transitions.index[i-1]
            end_idx = transitions.index[i]
            duration = end_idx - start_idx
            regime = df.loc[start_idx, 'regime']
            
            regime_durations.append({
                'regime': self.regimes[regime],
                'duration_candles': int(duration),
                'duration_hours': float(duration * 0.25)  # M15 = 0.25 hours
            })
        
        # Average duration per regime
        avg_durations = {}
        for regime_id, regime_name in self.regimes.items():
            durations = [r['duration_candles'] for r in regime_durations if r['regime'] == regime_name]
            if durations:
                avg_durations[regime_name] = {
                    'avg_duration_candles': float(np.mean(durations)),
                    'avg_duration_hours': float(np.mean(durations) * 0.25),
                    'max_duration_candles': int(np.max(durations)),
                    'min_duration_candles': int(np.min(durations))
                }
        
        # Current regime (last candle)
        last_regime_id = int(df['regime'].iloc[-1])
        current_regime = self.regimes[last_regime_id]
        
        # Dominant regime (most frequent)
        dominant_regime_id = int(df['regime'].mode().iloc[0])
        dominant_regime = self.regimes[dominant_regime_id]
        
        report = {
            'metadata': {
                'file': self.csv_file,
                'total_candles': len(df),
                'model_accuracy': float(self.model.score(
                    self.scaler.transform(df.dropna()[self.feature_cols]),
                    df.dropna()['regime']
                )) if hasattr(self, 'feature_cols') else None
            },
            'current_regime': current_regime,
            'dominant_regime': dominant_regime,
            'regime_distribution': {
                self.regimes[i]: int(count) 
                for i, count in df['regime'].value_counts().sort_index().items()
            },
            'average_regime_durations': avg_durations,
            'total_transitions': len(transitions),
            'recommendations': self._generate_recommendations()
        }
        
        with open(output_file, 'w', encoding='utf-8') as f:
            json.dump(report, f, indent=2, ensure_ascii=False)
        
        print(f"✅ Báo cáo đã lưu: {output_file}")
        
        return report
        
    def _generate_recommendations(self):
        """Tạo khuyến nghị strategies cho từng regime"""
        return {
            'RANGING': {
                'best_strategies': [
                    'Mean Reversion (RSI + BB)',
                    'Support/Resistance bounce',
                    'Fade breakouts'
                ],
                'avoid': [
                    'Trend following',
                    'Breakout trading'
                ],
                'parameters': {
                    'hold_time': 'Short (3-8 candles)',
                    'TP_SL_ratio': '1.5:1 to 2:1',
                    'indicators': 'RSI, BB, Support/Resistance'
                }
            },
            'TRENDING_UP': {
                'best_strategies': [
                    'Pullback to MA',
                    'Breakout continuation',
                    'Higher lows entry'
                ],
                'avoid': [
                    'Counter-trend trades',
                    'Selling at resistance'
                ],
                'parameters': {
                    'hold_time': 'Long (15-30 candles)',
                    'TP_SL_ratio': '2:1 to 3:1',
                    'indicators': 'MA, ADX, MACD'
                }
            },
            'TRENDING_DOWN': {
                'best_strategies': [
                    'Pullback to MA (short)',
                    'Lower highs entry',
                    'Breakdown continuation'
                ],
                'avoid': [
                    'Buying dips',
                    'Counter-trend longs'
                ],
                'parameters': {
                    'hold_time': 'Long (15-30 candles)',
                    'TP_SL_ratio': '2:1 to 3:1',
                    'indicators': 'MA, ADX, MACD'
                }
            },
            'VOLATILE': {
                'best_strategies': [
                    'Reduce position size',
                    'Widen stops',
                    'Wait for consolidation'
                ],
                'avoid': [
                    'Scalping',
                    'Tight stops',
                    'High frequency trading'
                ],
                'parameters': {
                    'hold_time': 'Variable',
                    'TP_SL_ratio': 'Wider stops (1:1)',
                    'indicators': 'ATR, Volatility bands'
                }
            }
        }


def main():
    if len(sys.argv) < 2:
        print("Usage: python regime_detector.py <csv_file>")
        print("Example: python regime_detector.py EURUSD_M15.csv")
        sys.exit(1)
    
    csv_file = sys.argv[1]
    
    if not os.path.exists(csv_file):
        print(f"❌ File not found: {csv_file}")
        sys.exit(1)
    
    # Initialize detector
    detector = MarketRegimeDetector(csv_file)
    detector.load_data()
    detector.calculate_regime_features()
    detector.label_regimes()
    feature_cols = detector.train_model()
    detector.feature_cols = feature_cols
    
    # Generate report
    report = detector.generate_report()
    
    print("\n" + "="*80)
    print("✅ HOÀN TẤT PHÂN TÍCH REGIME")
    print("="*80)
    
    print("\n📊 KHUYẾN NGHỊ STRATEGIES:")
    for regime, rec in report['recommendations'].items():
        print(f"\n{regime}:")
        print(f"  ✅ Best: {', '.join(rec['best_strategies'])}")
        print(f"  ❌ Avoid: {', '.join(rec['avoid'])}")


if __name__ == "__main__":
    main()