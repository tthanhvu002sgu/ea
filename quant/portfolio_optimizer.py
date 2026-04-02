"""
PORTFOLIO OPTIMIZER
Tối ưu hóa phân bổ vốn giữa các strategies để maximize Sharpe Ratio

Sử dụng:
    python portfolio_optimizer.py <analysis_file.json>
"""

import json
import numpy as np
import pandas as pd
from scipy.optimize import minimize
from datetime import datetime
import sys
import os

class PortfolioOptimizer:
    def __init__(self, analysis_file):
        self.analysis_file = analysis_file
        self.strategies = []
        self.returns_matrix = None
        self.metadata = {}
        
    def load_analysis(self):
        """Load kết quả phân tích từ file JSON"""
        print(f"\n📁 Đang đọc file phân tích: {self.analysis_file}")
        
        with open(self.analysis_file, 'r', encoding='utf-8') as f:
            self.data = json.load(f)
        
        self.metadata = self.data.get('metadata', {})
        print(f"✅ Đã load dữ liệu phân tích")
        print(f"   {self.metadata.get('file', '?')}")
        
    def extract_strategies(self, min_trades=50, min_win_rate=48):
        """Trích xuất các strategies đủ điều kiện"""
        print(f"\n🔍 Đang lọc strategies (min trades: {min_trades}, min WR: {min_win_rate}%)...")
        
        strategies = []
        
        results = self.data.get('results', {})
        
        for category, category_data in results.items():
            if isinstance(category_data, dict):
                for strategy_name, strategy_data in category_data.items():
                    if isinstance(strategy_data, dict) and 'total_trades' in strategy_data:
                        
                        # Filter criteria
                        if (strategy_data['total_trades'] >= min_trades and 
                            strategy_data['win_rate'] >= min_win_rate):
                            
                            strategies.append({
                                'name': f"{category}_{strategy_name}",
                                'category': category,
                                'strategy': strategy_name,
                                'total_trades': strategy_data['total_trades'],
                                'win_rate': strategy_data['win_rate'],
                                'avg_profit': strategy_data['avg_profit'],
                                'avg_win': strategy_data.get('avg_win', 0),
                                'avg_loss': strategy_data.get('avg_loss', 0),
                                'profit_factor': strategy_data.get('profit_factor', 0),
                                'total_profit': strategy_data.get('total_profit', 0),
                                'wins': strategy_data.get('wins', 0),
                                'losses': strategy_data.get('losses', 0)
                            })
        
        self.strategies = sorted(strategies, key=lambda x: x['profit_factor'], reverse=True)
        
        print(f"✅ Tìm thấy {len(self.strategies)} strategies đủ điều kiện")
        
        # Show top strategies
        print(f"\n🏆 TOP 15 STRATEGIES:")
        print(f"{'#':<4} {'Name':<45} {'Trades':<8} {'WR%':<7} {'PF':<7} {'Avg':<8}")
        print("-" * 90)
        
        for i, s in enumerate(self.strategies[:15], 1):
            print(f"{i:<4} {s['name'][:45]:<45} {s['total_trades']:<8} "
                  f"{s['win_rate']:<7.1f} {s['profit_factor']:<7.2f} {s['avg_profit']:<8.2f}")
        
        return self.strategies
    
    def _get_pip_to_usd(self, lot_size=0.01):
        """Tính giá trị 1 pip theo USD cho lot size cho trước"""
        asset_type = self.metadata.get('asset_type', 'FOREX')
        pip_value = self.metadata.get('pip_value', 0.0001)
        
        # Approximate pip value per pip per lot_size
        # These are rough estimates - actual values depend on broker
        pip_usd_map = {
            'FOREX': 0.10,       # 0.01 lot major pair ≈ $0.10/pip
            'JPY_SILVER': 0.07,  # 0.01 lot JPY pair ≈ $0.07/pip  
            'GOLD_ETH': 0.01,    # 0.01 lot Gold ≈ $0.01/pip (1 pip = $0.01)
            'BITCOIN': 0.01,     # 0.01 lot BTC ≈ $0.01/pip
        }
        return pip_usd_map.get(asset_type, 0.10)
    
    def _get_backtest_months(self):
        """Tính số tháng dữ liệu backtest"""
        start = self.metadata.get('start_date', '')
        end = self.metadata.get('end_date', '')
        try:
            start_dt = pd.to_datetime(start)
            end_dt = pd.to_datetime(end)
            return max((end_dt - start_dt).days / 30.44, 1)
        except:
            return 12  # Default 12 months
    
    def simulate_returns(self, n_simulations=1000):
        """
        Mô phỏng returns của từng strategy dựa trên win rate và avg profit/loss
        """
        # Detect pip multiplier from metadata
        pip_mult = self.metadata.get('pip_multiplier', 100)
        print(f"\n🎲 Đang mô phỏng {n_simulations} trades cho mỗi strategy...")
        print(f"   Pip multiplier: {pip_mult}")
        
        returns_data = []
        
        for strategy in self.strategies:
            # Simulate trades based on win rate
            wins = strategy['wins']
            losses = strategy['losses']
            total_trades = wins + losses
            
            if total_trades == 0:
                continue
            
            # Create return distribution
            returns = []
            
            # Use actual avg_win and avg_loss
            avg_win = strategy['avg_win'] if strategy['avg_win'] != 0 else strategy['avg_profit'] * 2
            avg_loss = strategy['avg_loss'] if strategy['avg_loss'] != 0 else -strategy['avg_profit']
            
            # Generate simulated returns
            np.random.seed(42)
            win_prob = strategy['win_rate'] / 100
            
            for _ in range(n_simulations):
                if np.random.random() < win_prob:
                    # Win trade - add some randomness
                    ret = avg_win * np.random.uniform(0.7, 1.3)
                else:
                    # Loss trade
                    ret = avg_loss * np.random.uniform(0.7, 1.3)
                
                returns.append(ret)
            
            returns_data.append({
                'strategy': strategy['name'],
                'returns': returns,
                'mean': np.mean(returns),
                'std': np.std(returns),
                'sharpe': np.mean(returns) / np.std(returns) if np.std(returns) > 0 else 0
            })
        
        # Create returns matrix (strategies x simulations)
        self.returns_matrix = pd.DataFrame({
            r['strategy']: r['returns'] 
            for r in returns_data
        })
        
        print(f"✅ Hoàn tất mô phỏng returns")
        print(f"   Shape: {self.returns_matrix.shape}")
        
        return returns_data
    
    def calculate_portfolio_metrics(self, weights, selected_strategies=None):
        """Tính toán metrics của portfolio với weights cho trước"""
        
        if self.returns_matrix is None:
            return None
        
        # If selected_strategies provided, use only those columns
        if selected_strategies is not None:
            strategy_names = [s['name'] for s in selected_strategies]
            returns_matrix = self.returns_matrix[strategy_names]
        else:
            returns_matrix = self.returns_matrix
        
        # Portfolio returns
        portfolio_returns = (returns_matrix * weights).sum(axis=1)
        
        # Metrics
        mean_return = portfolio_returns.mean()
        std_return = portfolio_returns.std()
        sharpe_ratio = mean_return / std_return if std_return > 0 else 0
        
        # Max Drawdown
        cumulative = portfolio_returns.cumsum()
        running_max = cumulative.expanding().max()
        drawdown = cumulative - running_max
        max_drawdown = abs(drawdown.min())
        
        # Sortino Ratio (downside deviation)
        downside_returns = portfolio_returns[portfolio_returns < 0]
        downside_std = downside_returns.std() if len(downside_returns) > 0 else std_return
        sortino_ratio = mean_return / downside_std if downside_std > 0 else 0
        
        return {
            'mean_return': mean_return,
            'std_return': std_return,
            'sharpe_ratio': sharpe_ratio,
            'sortino_ratio': sortino_ratio,
            'max_drawdown': max_drawdown,
            'total_return': portfolio_returns.sum()
        }
    
    def optimize_weights(self, objective='sharpe', max_strategies=10):
        """
        Tối ưu hóa weights để maximize objective
        
        Parameters:
        -----------
        objective: str
            'sharpe' - Maximize Sharpe Ratio
            'sortino' - Maximize Sortino Ratio  
            'return' - Maximize Returns
        max_strategies: int
            Số lượng strategies tối đa trong portfolio
        """
        print(f"\n🎯 Đang tối ưu hóa portfolio (objective: {objective}, max strategies: {max_strategies})...")
        
        # Select top strategies by profit factor
        selected_strategies = self.strategies[:max_strategies]
        selected_returns = self.returns_matrix[[s['name'] for s in selected_strategies]]
        
        n_strategies = len(selected_strategies)
        
        # Objective function
        def objective_function(weights):
            portfolio_returns = (selected_returns * weights).sum(axis=1)
            mean_return = portfolio_returns.mean()
            std_return = portfolio_returns.std()
            
            if objective == 'sharpe':
                sharpe = mean_return / std_return if std_return > 0 else 0
                return -sharpe  # Negative because we minimize
            
            elif objective == 'sortino':
                downside_returns = portfolio_returns[portfolio_returns < 0]
                downside_std = downside_returns.std() if len(downside_returns) > 0 else std_return
                sortino = mean_return / downside_std if downside_std > 0 else 0
                return -sortino
            
            elif objective == 'return':
                return -mean_return
            
            else:
                return -mean_return / std_return if std_return > 0 else 0
        
        # Constraints
        constraints = [
            {'type': 'eq', 'fun': lambda w: np.sum(w) - 1}  # Weights sum to 1
        ]
        
        # Bounds (0 to 0.5 per strategy to ensure diversification)
        bounds = [(0, 0.5) for _ in range(n_strategies)]
        
        # Initial guess (equal weights)
        initial_weights = np.array([1/n_strategies] * n_strategies)
        
        # Optimize
        result = minimize(
            objective_function,
            initial_weights,
            method='SLSQP',
            bounds=bounds,
            constraints=constraints,
            options={'maxiter': 1000}
        )
        
        if result.success:
            optimal_weights = result.x
            
            # Filter out very small weights
            optimal_weights[optimal_weights < 0.01] = 0
            optimal_weights = optimal_weights / optimal_weights.sum()  # Renormalize
            
            print(f"✅ Tối ưu hóa thành công!")
            
            return {
                'weights': optimal_weights,
                'strategies': selected_strategies,
                'success': True
            }
        else:
            print(f"❌ Tối ưu hóa thất bại: {result.message}")
            return {
                'weights': initial_weights,
                'strategies': selected_strategies,
                'success': False
            }
    
    def _calculate_equity_curve(self, weights, strategies):
        """Tính equity curve từ simulated returns"""
        strategy_names = [s['name'] for s in strategies]
        returns_matrix = self.returns_matrix[strategy_names]
        portfolio_returns = (returns_matrix * weights).sum(axis=1)
        equity = portfolio_returns.cumsum()
        return portfolio_returns, equity
    
    def _calculate_streaks(self, returns_series):
        """Tính win/loss streak tối đa"""
        wins = (returns_series > 0).astype(int)
        losses = (returns_series < 0).astype(int)
        
        max_win_streak = 0
        max_loss_streak = 0
        current_win = 0
        current_loss = 0
        
        for i in range(len(returns_series)):
            if wins.iloc[i]:
                current_win += 1
                current_loss = 0
            elif losses.iloc[i]:
                current_loss += 1
                current_win = 0
            else:
                current_win = 0
                current_loss = 0
            max_win_streak = max(max_win_streak, current_win)
            max_loss_streak = max(max_loss_streak, current_loss)
        
        return max_win_streak, max_loss_streak
    
    def generate_portfolio_report(self, optimization_result, output_file='portfolio_optimization.json'):
        """Tạo báo cáo portfolio optimization"""
        print(f"\n📝 Đang tạo báo cáo portfolio...")
        
        weights = optimization_result['weights']
        strategies = optimization_result['strategies']
        
        # Portfolio metrics
        portfolio_metrics = self.calculate_portfolio_metrics(weights, strategies)
        
        # Create allocation table
        allocations = []
        for i, (weight, strategy) in enumerate(zip(weights, strategies)):
            if weight > 0.01:  # Only include meaningful allocations
                allocations.append({
                    'strategy': strategy['name'],
                    'category': strategy['category'],
                    'allocation': float(weight * 100),
                    'win_rate': strategy['win_rate'],
                    'profit_factor': strategy['profit_factor'],
                    'avg_profit': strategy['avg_profit'],
                    'total_trades': strategy['total_trades'],
                    'total_profit': strategy.get('total_profit', 0)
                })
        
        allocations = sorted(allocations, key=lambda x: x['allocation'], reverse=True)
        
        # Calculate individual strategy metrics
        individual_metrics = []
        for strategy in strategies:
            strategy_returns = self.returns_matrix[strategy['name']]
            individual_metrics.append({
                'strategy': strategy['name'],
                'sharpe_ratio': strategy_returns.mean() / strategy_returns.std() if strategy_returns.std() > 0 else 0,
                'mean_return': float(strategy_returns.mean()),
                'std_return': float(strategy_returns.std())
            })
        
        # Compare with equal weight portfolio
        equal_weights = np.array([1/len(strategies)] * len(strategies))
        equal_weight_metrics = self.calculate_portfolio_metrics(equal_weights, strategies)
        
        # === NEW: Practical USD-based metrics ===
        pip_usd = self._get_pip_to_usd()
        backtest_months = self._get_backtest_months()
        
        # Equity curve & streaks
        pf_returns, equity = self._calculate_equity_curve(weights, strategies)
        max_win_streak, max_loss_streak = self._calculate_streaks(pf_returns)
        
        # USD conversions
        mean_return_usd = portfolio_metrics['mean_return'] * pip_usd
        max_dd_usd = portfolio_metrics['max_drawdown'] * pip_usd
        total_return_pips = portfolio_metrics['total_return']
        total_return_usd = total_return_pips * pip_usd
        
        # Calmar Ratio = Annualized Return / Max Drawdown
        annualized_return_pips = (total_return_pips / backtest_months) * 12
        calmar_ratio = (annualized_return_pips / portfolio_metrics['max_drawdown'] 
                       if portfolio_metrics['max_drawdown'] > 0 else 0)
        
        # Weighted total trades across allocated strategies
        weighted_trades = sum(
            a['total_trades'] * (a['allocation'] / 100) 
            for a in allocations
        )
        
        # Individual strategy USD projections
        strategy_projections = []
        for alloc in allocations:
            s_total_profit_pips = alloc.get('total_profit', 0)
            s_total_profit_usd = s_total_profit_pips * pip_usd
            s_monthly_pips = s_total_profit_pips / backtest_months if backtest_months > 0 else 0
            s_monthly_usd = s_monthly_pips * pip_usd
            strategy_projections.append({
                'strategy': alloc['strategy'],
                'allocation_pct': alloc['allocation'],
                'total_profit_pips': s_total_profit_pips,
                'total_profit_usd': s_total_profit_usd,
                'monthly_avg_pips': s_monthly_pips,
                'monthly_avg_usd': s_monthly_usd,
                'total_trades': alloc['total_trades'],
                'win_rate': alloc['win_rate'],
                'profit_factor': alloc['profit_factor']
            })
        
        report = {
            'metadata': {
                'analysis_file': self.analysis_file,
                'total_strategies_analyzed': len(self.strategies),
                'selected_strategies': len([a for a in allocations if a['allocation'] > 0]),
                'optimization_success': optimization_result['success'],
                'backtest_period': {
                    'start': self.metadata.get('start_date', '?'),
                    'end': self.metadata.get('end_date', '?'),
                    'months': round(backtest_months, 1),
                    'timeframe': self.metadata.get('timeframe', '?')
                },
                'asset_type': self.metadata.get('asset_type', 'UNKNOWN'),
                'pip_to_usd': pip_usd,
                'lot_size': 0.01
            },
            'portfolio_allocation': allocations,
            'optimized_portfolio_metrics': {
                'sharpe_ratio': float(portfolio_metrics['sharpe_ratio']),
                'sortino_ratio': float(portfolio_metrics['sortino_ratio']),
                'mean_return_per_trade': float(portfolio_metrics['mean_return']),
                'std_return': float(portfolio_metrics['std_return']),
                'max_drawdown': float(portfolio_metrics['max_drawdown']),
                'expected_total_return': float(portfolio_metrics['total_return']),
                'calmar_ratio': float(calmar_ratio)
            },
            'usd_metrics': {
                'lot_size': 0.01,
                'pip_value_usd': pip_usd,
                'mean_return_per_trade_usd': round(mean_return_usd, 4),
                'max_drawdown_usd': round(max_dd_usd, 2),
                'total_return_usd': round(total_return_usd, 2),
                'annualized_return_usd': round(annualized_return_pips * pip_usd, 2),
                'monthly_avg_return_usd': round(total_return_usd / backtest_months, 2) if backtest_months > 0 else 0,
                'calmar_ratio': round(calmar_ratio, 3),
                'max_win_streak': max_win_streak,
                'max_loss_streak': max_loss_streak,
                'weighted_total_trades': round(weighted_trades)
            },
            'strategy_projections': strategy_projections,
            'equal_weight_portfolio_metrics': {
                'sharpe_ratio': float(equal_weight_metrics['sharpe_ratio']),
                'sortino_ratio': float(equal_weight_metrics['sortino_ratio']),
                'mean_return_per_trade': float(equal_weight_metrics['mean_return']),
                'std_return': float(equal_weight_metrics['std_return']),
                'max_drawdown': float(equal_weight_metrics['max_drawdown'])
            },
            'improvement': {
                'sharpe_improvement': float(
                    (portfolio_metrics['sharpe_ratio'] - equal_weight_metrics['sharpe_ratio']) / 
                    equal_weight_metrics['sharpe_ratio'] * 100 
                    if equal_weight_metrics['sharpe_ratio'] > 0 else 0
                ),
                'return_improvement': float(
                    (portfolio_metrics['mean_return'] - equal_weight_metrics['mean_return']) / 
                    abs(equal_weight_metrics['mean_return']) * 100
                    if equal_weight_metrics['mean_return'] != 0 else 0
                )
            },
            'individual_strategy_metrics': individual_metrics
        }
        
        with open(output_file, 'w', encoding='utf-8') as f:
            json.dump(report, f, indent=2, ensure_ascii=False)
        
        print(f"✅ Báo cáo đã lưu: {output_file}")
        
        # Print summary
        self._print_summary(report)
        
        return report
    
    def _print_summary(self, report):
        """In tóm tắt kết quả - rõ ràng, dễ hiểu"""
        metrics = report['optimized_portfolio_metrics']
        usd = report.get('usd_metrics', {})
        meta = report.get('metadata', {})
        bp = meta.get('backtest_period', {})
        projections = report.get('strategy_projections', [])
        
        print("\n" + "═"*80)
        print("📊 PORTFOLIO OPTIMIZATION SUMMARY")
        print("═"*80)
        
        # ── Context ──
        print(f"\n📅 Backtest: {bp.get('start','?')[:10]} → {bp.get('end','?')[:10]} ({bp.get('months',0):.0f} tháng)")
        print(f"📈 Timeframe: {bp.get('timeframe','?')} | Asset: {meta.get('asset_type','?')} | Lot: {meta.get('lot_size', 0.01)}")
        
        # ── Core Metrics with explanations ──
        sharpe = metrics['sharpe_ratio']
        sortino = metrics['sortino_ratio']
        calmar = metrics.get('calmar_ratio', 0)
        
        print(f"\n🎯 PORTFOLIO METRICS (mỗi giá trị nghĩa là gì):")
        print(f"┌──────────────────────────────────────────────────────────────────┐")
        
        # Sharpe
        sharpe_grade = "🟢 TỐT" if sharpe > 0.5 else "🟡 TRUNG BÌNH" if sharpe > 0.2 else "🔴 YẾU"
        print(f"│ Sharpe Ratio:  {sharpe:.3f}  {sharpe_grade}")
        print(f"│   → Lãi trung bình / Rủi ro. Trên 0.5 = tốt, trên 1.0 = xuất sắc")
        
        # Sortino  
        sortino_grade = "🟢 TỐT" if sortino > 1.0 else "🟡 TB" if sortino > 0.5 else "🔴 YẾU"
        print(f"│ Sortino Ratio: {sortino:.3f}  {sortino_grade}")
        print(f"│   → Giống Sharpe nhưng chỉ tính rủi ro khi THUA. Trên 1.0 = tốt")
        
        # Calmar
        calmar_grade = "🟢 TỐT" if calmar > 1.0 else "🟡 TB" if calmar > 0.5 else "🔴 YẾU"  
        print(f"│ Calmar Ratio:  {calmar:.3f}  {calmar_grade}")
        print(f"│   → Lãi hàng năm / Drawdown tối đa. Trên 1.0 = kiếm nhiều hơn mất")
        
        print(f"│")
        print(f"│ Mean Return:   {metrics['mean_return_per_trade']:+.2f} pips/trade")
        print(f"│   → Trung bình mỗi lệnh lãi/lỗ bao nhiêu pips")
        print(f"│ Std Deviation: {metrics['std_return']:.2f} pips")
        print(f"│   → Biên độ dao động. Càng nhỏ = càng ổn định")
        print(f"│ Max Drawdown:  {metrics['max_drawdown']:.2f} pips")
        print(f"│   → Chuỗi thua tệ nhất (từ đỉnh xuống đáy)")
        print(f"│ Win Streak:    {usd.get('max_win_streak', 0)} lệnh liên tiếp")
        print(f"│ Loss Streak:   {usd.get('max_loss_streak', 0)} lệnh liên tiếp")
        print(f"└──────────────────────────────────────────────────────────────────┘")
        
        # ── USD Projection ──
        pip_usd = usd.get('pip_value_usd', 0.10)
        total_usd = usd.get('total_return_usd', 0)
        monthly_usd = usd.get('monthly_avg_return_usd', 0)
        dd_usd = usd.get('max_drawdown_usd', 0)
        annual_usd = usd.get('annualized_return_usd', 0)
        backtest_mo = bp.get('months', 12)
        
        print(f"\n💰 GIẢ SỬ BẠN CÓ $500 (LOT 0.01):")
        print(f"┌──────────────────────────────────────────────────────────────────┐")
        print(f"│ 1 pip = ${pip_usd:.2f} (lot 0.01)")
        print(f"│")
        print(f"│ Tổng lãi backtest ({backtest_mo:.0f} tháng):  {'+' if total_usd >= 0 else ''}{total_usd:>10.2f} USD")
        print(f"│ Lãi trung bình/tháng:                {'+' if monthly_usd >= 0 else ''}{monthly_usd:>10.2f} USD")
        print(f"│ Lãi ước tính/năm:                    {'+' if annual_usd >= 0 else ''}{annual_usd:>10.2f} USD")
        print(f"│ Drawdown tối đa:                        -{dd_usd:>8.2f} USD")
        print(f"│")
        
        if dd_usd > 0:
            dd_pct = (dd_usd / 500) * 100
            print(f"│ ⚠️  Drawdown = {dd_pct:.1f}% tài khoản {'(AN TOÀN)' if dd_pct < 20 else '(RỦI RO!' if dd_pct < 50 else '(NGUY HIỂM!)'}")
        
        if monthly_usd > 0:
            monthly_pct = (monthly_usd / 500) * 100
            print(f"│ 📈 Return hàng tháng ≈ {monthly_pct:.1f}% tài khoản")
        elif monthly_usd < 0:
            print(f"│ 📉 Portfolio đang LỖ trung bình → KHÔNG NÊN dùng")
        
        print(f"└──────────────────────────────────────────────────────────────────┘")
        
        # ── Strategy Projections ──
        print(f"\n💼 CHI TIẾT TỪNG STRATEGY (lot 0.01):")
        print(f"{'Strategy':<42} {'Alloc':>6} {'Trades':>7} {'WR%':>5} {'PF':>5} {'Net Pips':>10} {'Net USD':>10} {'USD/mo':>8}")
        print("─" * 100)
        
        for sp in projections:
            print(f"{sp['strategy'][:42]:<42} {sp['allocation_pct']:>5.0f}% {sp['total_trades']:>7} "
                  f"{sp['win_rate']:>5.1f} {sp['profit_factor']:>5.2f} "
                  f"{sp['total_profit_pips']:>+10.1f} {sp['total_profit_usd']:>+10.2f} {sp['monthly_avg_usd']:>+8.2f}")
        
        # ── Totals ──
        total_trades = sum(sp['total_trades'] for sp in projections)
        total_pips = sum(sp['total_profit_pips'] * sp['allocation_pct']/100 for sp in projections)
        total_usd_proj = sum(sp['total_profit_usd'] * sp['allocation_pct']/100 for sp in projections)
        
        print("─" * 100)
        print(f"{'PORTFOLIO (weighted)':<42} {'100%':>6} {total_trades:>7} "
              f"{'':>5} {'':>5} {total_pips:>+10.1f} {total_usd_proj:>+10.2f}")
        
        # ── Comparison ──
        print(f"\n📈 SO SÁNH VỚI CHIA ĐỀU (Equal Weight):")
        print(f"   Sharpe: {report['improvement']['sharpe_improvement']:+.1f}% {'tốt hơn' if report['improvement']['sharpe_improvement'] > 0 else 'tệ hơn'}")
        print(f"   Return: {report['improvement']['return_improvement']:+.1f}% {'tốt hơn' if report['improvement']['return_improvement'] > 0 else 'tệ hơn'}")
        print(f"   → Nghĩa là: Phân bổ tối ưu {'hiệu quả hơn' if report['improvement']['sharpe_improvement'] > 0 else 'kém hơn'} so với chia đều")
        
        # ── Verdict ──
        print(f"\n{'═'*80}")
        if sharpe >= 0.5 and calmar >= 0.5 and monthly_usd > 0:
            print("✅ KẾT LUẬN: Portfolio KHẢ THI — có thể thử trên demo trước")
        elif sharpe >= 0.2 and monthly_usd > 0:
            print("🟡 KẾT LUẬN: Portfolio CÓ TIỀM NĂNG nhưng cần thêm kiểm chứng")
        else:
            print("🔴 KẾT LUẬN: Portfolio CHƯA ĐỦ TỐT — cần tìm strategy khác hoặc chờ market regime thay đổi")
        print("═"*80)


def main():
    if len(sys.argv) < 2:
        print("""
Usage: python portfolio_optimizer.py <analysis_file.json>

Example:
    python portfolio_optimizer.py EURUSD_M15_analysis.json

This will:
1. Load strategies from analysis file
2. Simulate returns for each strategy
3. Optimize portfolio weights to maximize Sharpe Ratio
4. Generate optimization report
        """)
        sys.exit(1)
    
    analysis_file = sys.argv[1]
    
    if not os.path.exists(analysis_file):
        print(f"❌ File not found: {analysis_file}")
        sys.exit(1)
    
    # Run optimization
    optimizer = PortfolioOptimizer(analysis_file)
    optimizer.load_analysis()
    optimizer.extract_strategies(min_trades=50, min_win_rate=48)
    optimizer.simulate_returns(n_simulations=1000)
    
    # Optimize for different objectives
    print("\n" + "="*80)
    print("OPTIMIZATION 1: Maximize Sharpe Ratio")
    print("="*80)
    result_sharpe = optimizer.optimize_weights(objective='sharpe', max_strategies=10)
    report_sharpe = optimizer.generate_portfolio_report(result_sharpe, 'portfolio_sharpe.json')
    
    print("\n" + "="*80)
    print("OPTIMIZATION 2: Maximize Sortino Ratio")
    print("="*80)
    result_sortino = optimizer.optimize_weights(objective='sortino', max_strategies=10)
    report_sortino = optimizer.generate_portfolio_report(result_sortino, 'portfolio_sortino.json')
    
    print("\n" + "="*80)
    print("✅ HOÀN TẤT PORTFOLIO OPTIMIZATION")
    print("="*80)
    print("\n📁 Files created:")
    print("   - portfolio_sharpe.json (Sharpe optimization)")
    print("   - portfolio_sortino.json (Sortino optimization)")


if __name__ == "__main__":
    main()