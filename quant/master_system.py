"""
MASTER TRADING SYSTEM
Tích hợp Regime Detection + Portfolio Optimization + Strategy Analysis

Workflow hoàn chỉnh:
1. Phân tích patterns và strategies
2. Phát hiện market regime
3. Tối ưu hóa portfolio
4. Đưa ra khuyến nghị trading

Usage:
    python master_system.py EURUSD_M15.csv
"""

import sys
import os
import json
import time

# Import modules (đảm bảo các file này nằm cùng thư mục)
try:
    from pattern_analyzer import PriceActionAnalyzer
    from regime_detector import MarketRegimeDetector
    from portfolio_optimizer import PortfolioOptimizer
    from market_efficiency_index import MarketEfficiencyIndex
except ImportError as e:
    print(f"❌ Missing module: {e}")
    print("Ensure pattern_analyzer.py, regime_detector.py, portfolio_optimizer.py, market_efficiency_index.py exist.")
    sys.exit(1)

def print_header(text):
    print("\n" + "="*80)
    print(f"  {text}")
    print("="*80 + "\n")

def ensure_dir(directory):
    if not os.path.exists(directory):
        os.makedirs(directory)

def main():
    if len(sys.argv) < 2:
        print("""
╔═══════════════════════════════════════════════════════════════╗
║            MASTER TRADING SYSTEM - COMPLETE WORKFLOW          ║
╚═══════════════════════════════════════════════════════════════╝

Cách sử dụng:
    python master_system.py <file_csv>

Ví dụ:
    python master_system.py EURUSD_M15.csv

Output sẽ được lưu trong thư mục '/report'
        """)
        sys.exit(1)
    
    csv_file = sys.argv[1]
    if not os.path.exists(csv_file):
        print(f"❌ File not found: {csv_file}")
        sys.exit(1)
        
    # Setup paths
    base_name = os.path.basename(csv_file).replace('.csv', '')
    report_dir = "report"
    ensure_dir(report_dir)
    
    print_header("🎯 MASTER TRADING SYSTEM - STARTING")
    print(f"Analyzing: {csv_file}")
    print(f"Reports will be saved to: {os.path.abspath(report_dir)}")
    
    # ---------------------------------------------------------
    # STEP 1: MARKET EFFICIENCY INDEX (MEI)
    # ---------------------------------------------------------
    print_header("STEP 1/5: MARKET EFFICIENCY INDEX (MEI)")
    
    mei_report_file = os.path.join(report_dir, f"{base_name}_mei_report.json")
    mei_chart_file = os.path.join(report_dir, f"{base_name}_rolling_mei.png")
    
    try:
        mei = MarketEfficiencyIndex(csv_file)
        mei.load_data()
        mei.calculate_all_components()
        mei_score = mei.calculate_mei()
        mei.print_report()
        
        # Save Report
        mei.generate_report(mei_report_file)
        print(f"✅ MEI Report saved: {mei_report_file}")
        
        # Rolling MEI + Chart
        print("\n   Generating Rolling MEI Chart...")
        rolling_df = mei.calculate_rolling_mei(window=500, step=50)
        if rolling_df is not None:
            mei.plot_rolling_mei(mei_chart_file)
            print(f"✅ MEI Chart saved: {mei_chart_file}")
            
    except Exception as e:
        print(f"❌ Error in MEI Analysis: {e}")
        import traceback
        traceback.print_exc()

    # ---------------------------------------------------------
    # STEP 2: PATTERN & STRATEGY ANALYSIS
    # ---------------------------------------------------------
    print_header("STEP 2/5: PATTERN & STRATEGY ANALYSIS")
    
    analysis_file = os.path.join(report_dir, f"{base_name}_analysis.json")
    
    try:
        analyzer = PriceActionAnalyzer(csv_file)
        if analyzer.load_data():
            analyzer.calculate_indicators()
            analyzer.analyze_all_patterns()
            
            # Save Report (includes _print_summary inside)
            analyzer.generate_report(analysis_file)
            print(f"✅ Strategy Analysis saved: {analysis_file}")
        else:
            print("❌ Failed to load data for Pattern Analysis")
            sys.exit(1)
            
    except Exception as e:
        print(f"❌ Error in Pattern Analysis: {e}")
        sys.exit(1)

    # ---------------------------------------------------------
    # STEP 3: MARKET REGIME DETECTION
    # ---------------------------------------------------------
    print_header("STEP 3/5: MARKET REGIME DETECTION (ML)")
    
    regime_file = os.path.join(report_dir, f"{base_name}_regime_analysis.json")
    
    try:
        detector = MarketRegimeDetector(csv_file)
        detector.load_data()
        detector.calculate_regime_features()
        detector.label_regimes()
        detector.train_model()
        
        # Pass the analyzer instance to check performance by regime
        # (Re-using analyzer from Step 2 if possible, but class separation implies re-pass)
        detector.analyze_regime_performance(analyzer) 
        
        detector.generate_report(regime_file)
        print(f"✅ Regime Analysis saved: {regime_file}")
        
    except Exception as e:
        print(f"⚠️  Error in Regime Detection: {e}")
        print("   Continuing without regime-specific insights...")

    # ---------------------------------------------------------
    # STEP 4: PORTFOLIO OPTIMIZATION
    # ---------------------------------------------------------
    print_header("STEP 4/5: PORTFOLIO OPTIMIZATION")
    
    pf_sharpe_file = os.path.join(report_dir, f"{base_name}_portfolio_sharpe.json")
    pf_sortino_file = os.path.join(report_dir, f"{base_name}_portfolio_sortino.json")
    
    try:
        # Optimizer loads from the JSON file we just created
        optimizer = PortfolioOptimizer(analysis_file)
        optimizer.load_analysis()
        optimizer.extract_strategies(min_trades=50, min_win_rate=48)
        
        if len(optimizer.strategies) > 0:
            optimizer.simulate_returns(n_simulations=1000)
            
            # 1. Optimize for Sharpe
            print("\n   Optimizing for Maximum Sharpe Ratio...")
            res_sharpe = optimizer.optimize_weights(objective='sharpe', max_strategies=10)
            optimizer.generate_portfolio_report(res_sharpe, pf_sharpe_file)
            print(f"✅ Sharpe Portfolio saved: {pf_sharpe_file}")
            
            # 2. Optimize for Sortino
            print("\n   Optimizing for Maximum Sortino Ratio...")
            res_sortino = optimizer.optimize_weights(objective='sortino', max_strategies=10)
            optimizer.generate_portfolio_report(res_sortino, pf_sortino_file)
            print(f"✅ Sortino Portfolio saved: {pf_sortino_file}")
        else:
            print("⚠️  No strategies met the criteria for portfolio optimization.")
        
    except Exception as e:
        print(f"⚠️  Error in Portfolio Optimization: {e}")

    # ---------------------------------------------------------
    # STEP 5: FINAL RECOMMENDATIONS
    # ---------------------------------------------------------
    print_header("STEP 5/5: GENERATING TRADING RECOMMENDATIONS")
    
    rec_file = os.path.join(report_dir, f"{base_name}_recommendations.txt")
    
    try:
        # Generate comprehensive text recommendation
        # We need to reuse logic from original master_system or re-implement slightly
        # Since we imported modules, we can access data directly, but master_system logic 
        # for generating text was inside master_system.py itself previously.
        
        recommendations = generate_recommendations_text(
            analysis_file, regime_file, pf_sharpe_file, mei_report_file
        )
        
        with open(rec_file, 'w', encoding='utf-8') as f:
            f.write(recommendations)
            
        print(f"✅ Recommendations saved: {rec_file}")
        
        print("\n" + recommendations)
        
    except Exception as e:
        print(f"❌ Error generating recommendations: {e}")
        import traceback
        traceback.print_exc()

    print_header("✅ MASTER SYSTEM - COMPLETED")
    print(f"All reports available in: {os.path.abspath(report_dir)}")


def generate_recommendations_text(analysis_path, regime_path, portfolio_path, mei_path):
    """Tổng hợp thông tin từ 4 nguồn để đưa ra khuyến nghị"""
    
    # Load Data
    try:
        with open(analysis_path, 'r', encoding='utf-8') as f: analysis = json.load(f)
    except: analysis = {}
        
    try:
        with open(regime_path, 'r', encoding='utf-8') as f: regime = json.load(f)
    except: regime = {}
        
    try:
        with open(portfolio_path, 'r', encoding='utf-8') as f: portfolio = json.load(f)
    except: portfolio = {}

    try:
        with open(mei_path, 'r', encoding='utf-8') as f: mei = json.load(f)
    except: mei = {}

    timestamp = time.strftime("%Y-%m-%d %H:%M:%S")
    
    # === 1. MEI ===
    mei_score = mei.get('mei_score', 0)
    mei_class = mei.get('classification', {}).get('class', 'UNKNOWN')
    mei_rec = mei.get('classification', {}).get('recommendation', 'N/A')
    
    # === 2. Top Strategies (filter min 50 trades) ===
    strategies = []
    if 'results' in analysis:
        for group, group_res in analysis['results'].items():
            if isinstance(group_res, dict):
                for name, res in group_res.items():
                    if isinstance(res, dict) and 'win_rate' in res:
                        if res.get('total_trades', 0) >= 50:
                            strategies.append({
                                'name': name,
                                'group': group,
                                **res
                            })
    
    # Sort by Profit Factor (more meaningful than win rate alone)
    top_strategies = sorted(strategies, key=lambda x: x.get('profit_factor', 0), reverse=True)[:5]
    
    # === 3. Regime data ===
    current_regime = regime.get('current_regime', 'UNKNOWN')
    dominant_regime = regime.get('dominant_regime', 'UNKNOWN')
    regime_dist = regime.get('regime_distribution', {})
    regime_durations = regime.get('average_regime_durations', {})
    regime_recommendations = regime.get('recommendations', {})
    total_candles = sum(regime_dist.values()) if regime_dist else 1
    
    # === 4. Portfolio ===
    allocation = portfolio.get('portfolio_allocation', [])
    usd_metrics = portfolio.get('usd_metrics', {})
    pf_metrics = portfolio.get('optimized_portfolio_metrics', {})
    bp = portfolio.get('metadata', {}).get('backtest_period', {})
    
    # ═══════════════════════════════════
    # BUILD REPORT
    # ═══════════════════════════════════
    lines = []
    lines.append(f"{'═'*70}")
    lines.append(f"  TRADING RECOMMENDATIONS REPORT")
    lines.append(f"  Generated: {timestamp}")
    lines.append(f"{'═'*70}")
    
    # ─── 1. MEI ───
    lines.append(f"\n{'─'*70}")
    lines.append(f"1. MARKET EFFICIENCY INDEX (MEI)")
    lines.append(f"{'─'*70}")
    lines.append(f"   Score: {mei_score:.1f}/100 ({mei_class})")
    lines.append(f"   Recommendation: {mei_rec}")
    if mei_score > 70:
        lines.append(f"   ⚠️  WARNING: Thị trường RẤT HIỆU QUẢ. Strategies đơn giản sẽ thua.")
        lines.append(f"   → Chỉ trade khi Rolling MEI chart cho thấy window inefficient.")
    elif mei_score > 50:
        lines.append(f"   ⚠️  CAUTION: Thị trường khá hiệu quả. Cần chọn strategy kỹ.")
    else:
        lines.append(f"   ✅ Thị trường có tín hiệu không hiệu quả → có cơ hội exploit.")
    
    # ─── 2. REGIME ANALYSIS (ENHANCED) ───
    lines.append(f"\n{'─'*70}")
    lines.append(f"2. MARKET REGIME ANALYSIS")
    lines.append(f"{'─'*70}")
    lines.append(f"   Current:  {current_regime}")
    lines.append(f"   Dominant: {dominant_regime}")
    
    # Regime distribution
    lines.append(f"\n   📊 Phân bổ thời gian:")
    for reg_name, reg_count in sorted(regime_dist.items(), key=lambda x: x[1], reverse=True):
        pct = (reg_count / total_candles) * 100
        bar = '█' * int(pct / 2)  # Visual bar
        lines.append(f"      {reg_name:<15} {pct:>5.1f}%  {bar}")
    
    # Regime durations
    if regime_durations:
        lines.append(f"\n   ⏱️  Thời gian trung bình mỗi đợt regime:")
        for reg_name, dur in regime_durations.items():
            avg_h = dur.get('avg_duration_hours', 0)
            max_c = dur.get('max_duration_candles', 0)
            if avg_h >= 24:
                dur_str = f"{avg_h/24:.1f} ngày"
            else:
                dur_str = f"{avg_h:.1f} giờ"
            lines.append(f"      {reg_name:<15} TB: {dur_str:<12} (dài nhất: {max_c} nến)")
    
    # Regime-specific recommendations
    current_rec = regime_recommendations.get(current_regime, {})
    if current_rec:
        lines.append(f"\n   🎯 Khuyến nghị cho regime {current_regime} hiện tại:")
        
        best_strats = current_rec.get('best_strategies', [])
        if best_strats:
            lines.append(f"      ✅ NÊN dùng:")
            for s in best_strats:
                lines.append(f"         • {s}")
        
        avoid = current_rec.get('avoid', [])
        if avoid:
            lines.append(f"      ❌ NÊN TRÁNH:")
            for a in avoid:
                lines.append(f"         • {a}")
        
        params = current_rec.get('parameters', {})
        if params:
            lines.append(f"      ⚙️  Tham số gợi ý:")
            lines.append(f"         Hold time: {params.get('hold_time', '?')}")
            lines.append(f"         TP/SL:     {params.get('TP_SL_ratio', '?')}")
            lines.append(f"         Indicator: {params.get('indicators', '?')}")
    
    # Strategy focus based on regime
    if 'TREND' in current_regime:
        lines.append(f"\n   → Focus: TREND FOLLOWING (theo trend, đừng chống lại)")
    elif 'RANGING' in current_regime:
        lines.append(f"\n   → Focus: MEAN REVERSION (mua đáy bán đỉnh, trade trong range)")
    elif 'VOLATILE' in current_regime:
        lines.append(f"\n   → Focus: GIẢM SIZE + WIDEN STOP (biến động cao, rủi ro lớn)")
    
    # ─── 3. TOP STRATEGIES ───
    lines.append(f"\n{'─'*70}")
    lines.append(f"3. TOP PERFORMING STRATEGIES (by Profit Factor)")
    lines.append(f"{'─'*70}")
    for i, s in enumerate(top_strategies, 1):
        lines.append(f"   {i}. {s['name']:<30} | WR: {s['win_rate']:.1f}% | PF: {s.get('profit_factor',0):.2f} | Net: {s.get('total_profit',0):+.1f} pips | Trades: {s.get('total_trades',0)}")
    
    # ─── 4. PORTFOLIO ───
    lines.append(f"\n{'─'*70}")
    lines.append(f"4. RECOMMENDED PORTFOLIO")
    lines.append(f"{'─'*70}")
    
    if allocation:
        for item in allocation:
            alloc_pct = item.get('allocation', 0)
            if alloc_pct > 0.5:
                lines.append(f"   • {item['strategy']:<38} {alloc_pct:>5.1f}%  (WR: {item.get('win_rate',0):.1f}%, PF: {item.get('profit_factor',0):.2f})")
        
        # USD metrics if available
        if usd_metrics:
            lines.append(f"\n   💰 Ước tính với $500, lot 0.01:")
            lines.append(f"      Lãi/tháng:     ${usd_metrics.get('monthly_avg_return_usd', 0):+.2f}")
            lines.append(f"      Drawdown max:  ${usd_metrics.get('max_drawdown_usd', 0):.2f}")
            lines.append(f"      Calmar Ratio:  {pf_metrics.get('calmar_ratio', 0):.3f}")
            lines.append(f"      Sharpe Ratio:  {pf_metrics.get('sharpe_ratio', 0):.3f}")
    else:
        lines.append("   ⚠️  Không tìm được portfolio có lãi.")
    
    # ─── 5. ACTION PLAN ───
    lines.append(f"\n{'═'*70}")
    lines.append(f"ACTION PLAN:")
    lines.append(f"{'═'*70}")
    
    if mei_score < 50 and len([a for a in allocation if a.get('allocation',0) > 0]) > 0:
        calmar = pf_metrics.get('calmar_ratio', 0)
        lines.append(f"✅ GO: Thị trường không hiệu quả + có portfolio tốt.")
        lines.append(f"   1. Chạy trên DEMO trước ít nhất 1 tháng")
        lines.append(f"   2. Dùng lot 0.01 với tài khoản $500")
        if 'RANGING' in current_regime:
            lines.append(f"   3. Ưu tiên Mean Reversion strategies (regime = RANGING)")
        elif 'TREND' in current_regime:
            lines.append(f"   3. Ưu tiên Trend Following strategies (regime = TRENDING)")
        if calmar >= 0.5:
            lines.append(f"   4. Calmar {calmar:.2f} — rủi ro chấp nhận được")
        else:
            lines.append(f"   4. ⚠️ Calmar {calmar:.2f} < 0.5 — cân nhắc giảm lot size")
    elif mei_score < 50:
        lines.append(f"🟡 CÓ THỂ: Thị trường có cơ hội nhưng portfolio chưa tối ưu.")
        lines.append(f"   → Chọn 1-2 strategy tốt nhất từ danh sách trên.")
        lines.append(f"   → Trade thủ công, paper trade trước.")
    else:
        lines.append(f"🛑 DỪNG: Thị trường hiệu quả (MEI = {mei_score:.0f}).")
        lines.append(f"   → Không trade hoặc chỉ paper trade.")
        lines.append(f"   → Theo dõi Rolling MEI chart để chờ window tốt.")
        lines.append(f"   → Xem xét các instrument/timeframe khác.")

    return "\n".join(lines)

if __name__ == "__main__":
    main()