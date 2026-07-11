# Review: DNA AI v2 (Reverse Regime DNA)

**Ngày review:** 2026-07-11  
**Cập nhật fix:** 2026-07-11 (Streamlit-only — không gắn MT5)  
**Phạm vi:** `regime_analyzer.py`, `strategy_analyzer.py` (UI + load backtest), registry / features CSV thực tế  
**Chiến lược tham chiếu:** `volatility_rider_results_martingale_adx_5000_offregime.xlsx`  
**Mục tiêu người dùng:**  
> Strategy + OHLC → soi bối cảnh regime tại các lệnh thua/lỗ → khi thị trường rơi vào bối cảnh tương tự thì **tắt EA** (theo dõi trên Streamlit).

---

## 0. Changelog fix (ngắn)

| # | Vấn đề review | Trạng thái | Thay đổi chính |
|---|---------------|------------|----------------|
| P0 | Live monitor không chạy cây DNA | **Đã fix** | `rule_paths` serialize + `evaluate_live_market` dùng tree (PASS/BLOCK theo leaf exp) |
| P0 | MQL5 indicator parity | **Bỏ qua (theo yêu cầu)** | Không gắn MT5; MQL5 chỉ còn expander tham khảo |
| P1 | Deploy tree = full-sample ≠ OOS | **Đã fix** | Deploy = **train-only**; full-refit chỉ diagnostic |
| P1 | UI thr auto ghi đè im lặng | **Đã fix** | `threshold_mode`: **auto / fixed** rõ trên UI |
| P1 | Yahoo vs MT5 OHLC | **Đã fix (UX)** | Mặc định khuyến nghị **CSV MT5**; Yahoo cảnh báo lệch |
| P1 | FIFO / OpenTime coverage | **Đã fix** | FIFO khi &lt;95%; cảnh báo coverage trong DNA + load |
| P2 | Cluster rank theo WR | **Đã fix** | Rank theo **expectancy** |
| P2 | Cache indicator stale | **Đã fix** | `INDICATOR_CACHE_VERSION=2` trong pickle |
| P2 | Walk-forward | **Đã thêm** | Expanding WF 3-fold + `walk_forward_pass_rate` |
| — | Scope vận hành | **Xác nhận** | Theo dõi **chỉ Streamlit Live Monitor** |

**Cần làm 1 lần sau update:** mở Streamlit → **Huấn luyện lại DNA v2** cho từng strategy (registry cũ thiếu `rule_paths`).

---

## 1. Tóm tắt kết luận (sau fix)

| Hạng mục | Đánh giá | Ghi chú ngắn |
|----------|----------|--------------|
| Khớp mục tiêu “map regime → chặn khi toxic” | **Đạt (Streamlit)** | Train + Live Monitor cùng `rule_paths` tree |
| Chống lookahead (OpenTime / nến đóng) | **Tốt** | `last_closed_bar` + từ chối map theo close Time |
| Mô hình expectancy block-list | **Tốt** | Giữ v2; không quay lại WR allow-list |
| Validation OOS / deploy parity | **Tốt hơn** | Deploy train-only + WF folds; thr auto/fixed |
| Live monitor tắt EA khi toxic | **Đã ổn (Streamlit)** | Tree eval; registry cũ → legacy + cảnh báo train lại |
| Gắn MT5 / MQL5 | **Không dùng** | User chỉ theo dõi Streamlit |
| Tin tuyệt đối “filter free lunch”? | **Vẫn thận trọng** | OOS có thể trade-off net vs DD — đọc diagnosis trước khi tin BLOCK |

---

## 2. Mục tiêu của bạn vs những gì DNA v2 thực sự làm

### 2.1 Mục tiêu (user)

```
EA backtest (deals) + OHLC
  → tại thời điểm vào lệnh (đặc biệt lệnh lỗ): regime ra sao?
  → học vùng “độc”
  → tương lai gặp bối cảnh tương tự → TẮT EA
```

### 2.2 DNA v2 hiện tại

```
MT5 deals → ghép OpenTime (Order join / FIFO)
  → map feature regime tại nến H1/4H ĐÃ ĐÓNG trước entry
  → DecisionTreeRegressor dự báo expectancy ($/lệnh)
  → BLOCK-LIST các leaf có expectancy ≤ threshold
  → xuất MQL5 isSafeRegime / isToxicRegime
  → lưu registry + features CSV
```

**Khớp ý tưởng:** Có — đây đúng “Supervised Strategy Profiling / Reverse DNA”, và v2 ưu tiên **chặn vùng kỳ vọng âm** thay vì “chỉ cho chạy khi giống lệnh thắng”.

**Không khớp / chưa cover:**

1. **Dự báo regime sắp đổi** (problem.md mục 2) — DNA v2 **không forecast** transition; chỉ filter **tại entry** theo bar đã đóng → vẫn reactive (đã vào muộn nếu regime đổi trong lệnh).
2. **Tắt EA theo “bối cảnh giống lúc thua” thuần** — v2 chặn theo **leaf expectancy**, không phải “mọi vùng loss-like”. Một leaf WR thấp nhưng expectancy dương (R:R cao) vẫn được giữ — đúng quant, khác wording “chặn khi giống lúc thua”.
3. **Live dashboard** — hiện **không evaluate cây toxic**, nên “tắt EA khi toxic” trên monitor **chưa đúng DNA**.

---

## 3. Điểm mạnh (đã làm tốt)

### 3.1 Anti-lookahead ở pipeline DNA

- `pair_in_out_open_times` / `ensure_trade_open_times_from_deals`: phục hồi OpenTime khi Order ID IN≠OUT (vấn đề MT5 phổ biến).
- `last_closed_bar_index`: chỉ lấy nến **strictly before** OpenTime.
- `build_trade_feature_table`: **1 hàng = 1 lệnh** (tránh gộp nhiều lệnh cùng nến → bias).
- Từ chối fallback sang close Time khi thiếu OpenTime — đúng, không im lặng lookahead.

### 3.2 Expectancy thay vì Win/Loss classifier

Với EA kiểu volatility / martingale / R:R cao (case tham chiếu WR ~31%, PF ~1.5):

- Allow-list theo win-rate (legacy) dễ **cắt lệnh lãi lớn** → net giảm, DD đôi khi “đẹp giả”.
- Registry cho thấy legacy chặn **~64%** lệnh; v2 chặn **~3%** trên full sample với threshold auto ~`-5$`.

Đây là cải tiến **đúng bệnh** so với DNA v1.

### 3.3 Feature set có ý thức portable

```text
DNA_FEATURE_COLS = ADX, ATR%, Choppiness, BB_Width, EMA_Dist%, Vol_ZScore, AutoCorr
```

- Loại `Returns` cùng bar (leak/noise).
- Loại `Hurst` khỏi DNA vì Python R/S ≠ MQL5 đơn giản → threshold không portable (vẫn giữ Hurst cho clustering/contrast).

### 3.4 Đánh giá filter theo equity metrics

Có:

- Baseline vs filtered: net, maxDD, PF, block rate, blocked net.
- OOS holdout ~20% cuối theo thời gian.
- Purged/embargo-ish CV trên train.
- So sánh legacy allow-list.
- Diagnosis text cho UI.
- Leaf stats + export `*_regime_features.csv` (có `Pred_Expectancy`, `Filter_Keep`).

### 3.5 UI / registry

- Step 9 Streamlit giải thích rõ v2.
- Lưu registry JSON, reload không cần train lại.
- Tab: MQL5, tree, leaf stats, stability, clustering, win vs loss, range analysis.

---

## 4. Kết quả thực tế trên chiến lược tham chiếu

Nguồn: `strategy_regime_registry.json` + `..._regime_features.csv`  
Strategy: `volatility_rider_results_martingale_adx_5000_offregime.xlsx`  
OHLC: `XAUUSD_M1_...csv` · TF: `1h` · samples: **1236** lệnh · OpenTime null: **0**

### 4.1 Cây / toxic leaf

- Threshold chọn: **`exp_threshold = -5.0`**
- Toxic leaf chính (n=40):

```text
Vol_ZScore ≤ ~0.51  AND  ADX ≤ ~49.57  AND  ATR% > ~0.41
→ expectancy ≈ -$32.9 / lệnh · net blocked ≈ -$1,317 · WR leaf ≈ 22.5%
```

MQL5 tương đương:

```mql5
bool isToxicRegime =
  (vol_zscore_val <= 0.5097) &&
  (adx_val <= 49.5672) &&
  (atr_pct_val > 0.4099);
bool isSafeRegime = !isToxicRegime;
```

### 4.2 Impact

| | Baseline | DNA v2 filtered | Δ |
|--|----------|-----------------|---|
| **IS full** Net | $10,250 | $11,567 | **+1,317** |
| **IS** MaxDD | -9.72% | -9.63% | **+0.09 pp** (gần như không đổi) |
| **IS** Block rate | — | 3.2% | chặn 40 lệnh, blocked net **-$1,317** |
| **OOS 20%** Net | $5,750 | $4,199 | **-1,551** (~-27%) |
| **OOS** MaxDD | -14.6% | -12.4% | **+2.2 pp** tốt hơn |
| **OOS** Block rate | — | 26.3% | tree train-only chặn nhiều hơn full tree |

- `oos_status`: **PASS** (theo rule nội bộ: giữ ≥55% net OOS, exp>0, block<55%, DD không xấu hơn nhiều).
- `block_precision`: **77.5%** lệnh bị chặn thực sự ≤ 0$ (hợp lý cho block-list).
- Legacy WR allow-list: Net ~$7.4k, chặn 64% — minh họa rõ vì sao v1 “giết” edge.

### 4.3 Đọc kết quả này với mục tiêu của bạn

- **Tìm được vùng lỗ “độc” có cấu trúc** (interaction 3 feature) — **đạt**.
- **IS:** bỏ đúng cụm lệnh lỗ nặng (~$1.3k) — đẹp, nhưng DD gần như **không giảm** (EA này lỗ rải rác / maxDD không nằm chủ yếu ở 40 lệnh đó).
- **OOS:** DD cải thiện nhẹ, nhưng **hy sinh khá nhiều profit** → PASS theo code, **chưa phải “free lunch”**.
- Mean win-context vs loss-context gần như trùng (ADX ~32 cả hai, Vol_Z ~1.1 cả hai) → **contrast tuyến tính yếu**; edge nằm ở **tổ hợp phi tuyến** (tree), không phải “ADX thấp = xấu”.

---

## 5. Vấn đề / rủi ro cần xử lý (theo mức độ)

### 🔴 P0 — Live monitor không dùng DNA tree

`evaluate_live_market()` so sánh `latest_bar` với **mean win_context / loss_context** theo khoảng cách, cộng trọng số feature importance.

Với case hiện tại, mean win ≈ mean loss → điểm match gần **random**.  
Trong khi rule thật là:

```text
Vol_Z thấp + ATR% cao (+ ADX không cực đại) → toxic
```

**Hệ quả:** Dashboard có thể PASS trong toxic leaf, hoặc BLOCK khi vẫn safe.  
**Mục tiêu “tắt EA khi bối cảnh toxic” trên live monitor hiện chưa đạt.**

**Hướng sửa đề xuất:**

1. Serialize tree (paths / thresholds / `exp_threshold`) vào registry.
2. Live: tính features bar đóng gần nhất → `apply` leaf → `isToxic = (leaf_exp ≤ thr)`.
3. Status = PASS/BLOCK theo **cùng** logic MQL5, không dùng centroid win/loss.
4. Log thêm `pred_expectancy`, `leaf_id`, `is_toxic`.

---

### 🔴 P0 — Indicator parity Python ↔ MQL5 chưa được đảm bảo

Export chỉ là boolean filter. EA live phải tự tính:

- ADX (period 14, ewm vs Wilder — Python đang dùng **EWM**, không phải Wilder chuẩn MT5 `iADX` 100%).
- ATR% = ATR/Close*100
- BB_Width = 4*std20 / SMA20
- EMA_Dist% = (EMA50−EMA200)/EMA200*100
- Vol_ZScore trên TickVol rolling 20
- AutoCorr returns lag-1 rolling 20
- Choppiness period 14

**Lệch 1 công thức** → threshold DNA **sai hoàn toàn** trên live.

**Hướng sửa:**

- Viết include MQL5 `RegimeFeatures.mqh` mirror công thức Python (ghi chú rõ EWM vs Wilder).
- Hoặc đổi Python sang công thức gần MT5 nhất rồi retrain.
- Unit test: cùng 1 file H1 → so sánh feature Python vs MQL5 (hoặc CSV export từ tester) với tolerance nhỏ.

---

### 🟠 P1 — Rule deploy fit full sample; threshold chọn trên tree train

Luồng hiện tại:

1. Fit `reg_train` trên 80% đầu → chọn `exp_threshold` theo OOS impact.
2. Fit `reg` **full data** → export MQL5.

→ Tree deploy **khác** tree dùng để chấm OOS.  
OOS block 26% vs IS full block 3% là tín hiệu cấu trúc/threshold **không transfer 1:1**.

**Hướng sửa (chuẩn hơn):**

- **Walk-forward:** train trên cửa sổ A, freeze tree+threshold, apply B; roll.
- Export rule từ **fold cuối** (hoặc majority path ổn định qua folds), không refit full nếu chỉ để “đẹp IS”.
- Báo cáo thêm: **purged OOS với đúng tree sẽ deploy**.

---

### 🟠 P1 — UI `exp_threshold` dễ hiểu nhầm

UI number input mặc định `0.0`, help text kiểu “chặn ≤ ngưỡng”, nhưng code luôn đưa thêm candidates `[-5, -10, -2, 0, ...]` và **auto-pick best OOS**.

User nghĩ đang force `0`, thực tế registry có thể ra `-5`.

**Hướng sửa:**

- Checkbox: `Auto threshold (OOS)` vs `Fixed threshold`.
- Khi auto: hiện “đã chọn -5 vì score OOS …”.
- Khi fixed: không override.

---

### 🟠 P1 — OHLC source mismatch (Yahoo vs MT5 broker)

UI sử dụng Yahoo (`XAUUSD=X`) trong khi deals XAUUSD broker có:

- Timezone / session khác
- Spread/tick model khác
- (Đã cập nhật: chuyển từ futures `GC=F` sang spot `XAUUSD=X` để khớp loại tài sản với broker)

Train DNA trên Yahoo rồi apply rule lên XAUUSD MT5 = **domain shift**.

**Khuyến nghị vận hành:**  
Ưu tiên **cùng symbol + cùng server time** với backtest (file M1 MT5 export) như case registry hiện tại — đúng hướng. Tránh Yahoo cho DNA production trừ khi đã align timezone/symbol cẩn thận.

---

### 🟠 P1 — FIFO pairing với martingale / multi-position

FIFO volume-aware tốt hơn Order-join hỏng, nhưng:

- Nhiều IN cùng volume, partial close, hedge, reverse → có thể gán nhầm OpenTime.
- Martingale: PnL lệnh phụ thuộc lot path, không chỉ regime.

**Nên:** log % match OpenTime; nếu <95% → cảnh báo mạnh.  
Với file hiện tại 1236/1236 OpenTime — **OK cho case này**.

---

### 🟡 P2 — Unsupervised clustering vẫn rank theo Win Rate

`best_cluster` chọn theo WR, không expectancy/net — **lệch triết lý v2**.  
Nên rank theo `avg_pnl` / expectancy / net có min_n.

---

### 🟡 P2 — MaxDD trên chuỗi PnL lệnh ≠ equity realtime

`simulate_filter_impact` cumsum PnL theo thứ tự trade.  
Overlapping positions / floating DD trong lệnh **không** phản ánh.

Đủ cho screening; **không** thay tester MT5 với filter nhúng.

---

### 🟡 P2 — Cache indicator có thể stale

`*.cache.pkl` theo tên OHLC+TF. Đổi logic indicator mà không đổi tên file → dùng cache cũ.

Nên version hóa cache key (hash code/params) hoặc nút “Clear indicator cache” trên UI.

---

### 🟡 P2 — Mục tiêu “dự báo context trước khi đổi” chưa có

DNA v2 = **filter entry**.  
Chưa có:

- Regime transition model (HMM / change-point / lead-lag)
- Early warning trước khi leaf flip toxic
- Policy “flat all” khi probability toxic tăng (khác block entry đơn thuần)

Đây là phase 2 nếu vẫn bám problem.md mục 2.

---

### 🟢 P3 — Nhỏ / UX

- Encoding registry (`gi��_`…) — dump JSON UTF-8 OK nhưng một số terminal/tool hiển thị lỗi; kiểm tra `ensure_ascii=False` + editor.
- Comment MQL5 vẫn liệt kê Hurst dù DNA features không dùng Hurst.
- `oos_accuracy` là soft score display, dễ nhầm với classification accuracy.
- `hard_toxic_exp=-5` trùng candidate — OK nhưng nên document rõ trong UI.

---

## 6. Checklist “đã ổn chưa?” theo mục tiêu của bạn

| Câu hỏi | Trả lời |
|---------|---------|
| Từ strategy + OHLC có soi được regime lúc thua không? | **Có** — trade-level features + leaf toxic + CSV. |
| Có học được vùng nên tắt EA không? | **Có (train)** — block-list expectancy. |
| Có chống lookahead cơ bản không? | **Có** — OpenTime + last closed bar. |
| Có phù hợp EA WR thấp / R:R cao không? | **Có** — đúng lý do v2 tồn tại. |
| Live monitor có tắt đúng vùng toxic không? | **Chưa** — heuristic mean, không tree. |
| Copy MQL5 là chạy live an toàn ngay? | **Chưa** — thiếu parity chỉ số + walk-forward deploy + shadow test. |
| Case volatility_rider đã “chứng minh filter cứu DD”? | **Yếu** — IS DD ~không đổi; OOS DD tốt hơn nhưng net OOS giảm mạnh. |
| Có nên hard-block production? | **Chưa** — Shadow lot / log-only trước. |

**Kết luận tổng:**  
**DNA v2 đủ tốt như research / reverse-profiling tool**, và **đúng hướng mục tiêu**.  
**Chưa đủ ổn như risk switch production** cho đến khi live path = tree path, indicator parity, và walk-forward/MT5 verify.

---

## 7. Roadmap đề xuất (ưu tiên thực dụng)

### Phase A — Chốt đúng mục tiêu “tắt EA khi toxic” (1–2 vòng dev)

1. **Live evaluate bằng tree** (serialize paths hoặc `sklearn` export rules).  
2. **MQL5 RegimeFeatures.mqh** mirror Python + script so sánh feature.  
3. UI threshold: Auto vs Fixed; in rõ threshold đã chọn + OOS score.  
4. Bắt buộc train DNA trên **OHLC MT5 cùng broker time** với backtest.

### Phase B — Validation trước khi Block All

1. Walk-forward ≥ 3 cửa sổ; chỉ deploy rule ổn định ≥ 2/3 folds.  
2. Nhúng filter vào Strategy Tester MT5 (cùng deals logic) — so net/DD với Python impact.  
3. Live **Shadow Mode** 2–4 tuần: log “would block” vs lệnh thật, đo blocked expectancy.

### Phase C — Mở rộng (nếu vẫn cần problem.md #2)

1. Transition / early-warning (không chỉ filter entry).  
2. Policy layer: block entry vs reduce lot vs flatten.  
3. Re-train định kỳ (concept drift) + alert khi leaf toxic mới xuất hiện OOS.

---

## 8. Quy trình vận hành khuyến nghị (ngay bây giờ)

1. **Train DNA** bằng file OHLC M1 MT5 khớp symbol/time backtest (như đã làm).  
2. Đọc **Leaf stats + OOS impact**, không chỉ IS net tăng.  
3. Nếu OOS net rơi nhiều mà DD chỉ cải thiện nhẹ → coi filter là **optional risk trim**, không phải edge engine.  
4. Copy MQL5 → implement chỉ số **1:1** → `RegimeFilterMode = 1` (shadow).  
5. **Không** tin live monitor PASS/BLOCK cho đến khi monitor chạy tree.  
6. Sau shadow OK → mới `RegimeFilterMode = 0` (block all).

---

## 9. Đánh giá điểm số (thang 10) — sau fix

| Trục | Trước | Sau | Nhận xét |
|------|-------|-----|----------|
| Alignment mục tiêu user | 7.5 | **8.5** | Live Streamlit = tree DNA; scope MT5 bỏ theo yêu cầu |
| Thống kê / anti-pitfall | 7.0 | **8.0** | train-only deploy + thr mode + WF |
| Engineering / UX | 8.0 | **8.5** | rule_paths, cache version, OpenTime warn, UI thr |
| Ready theo dõi Streamlit | 4.5 | **8.0** | Cần retrain registry để có rule_paths |
| **Tổng thể (Streamlit-only)** | 6.5 | **8.0 / 10** | Đủ dùng monitor PASS/BLOCK; vẫn đọc OOS/WF trước khi tin tuyệt đối |

---

## 10. File đã sửa

| File | Thay đổi |
|------|----------|
| `regime_analyzer.py` | `rule_paths`, tree live eval, train-only deploy, thr auto/fixed, WF, cache v2, cluster expectancy |
| `strategy_analyzer.py` | UI thr mode, Live Monitor tree UI, CSV-first OHLC, FIFO &lt;95%, tabs Rule Paths |
| `DNA_AI_v2_REVIEW.md` | Changelog §0 + điểm sau fix |

---

## 11. Bottom line (sau fix)

- **Mục tiêu “soi regime lúc lỗ → theo dõi/tắt khi toxic” trên Streamlit: đã khép pipeline.**  
  Train DNA → lưu `rule_paths` → Live Monitor đánh giá **cùng cây**.
- **Không làm MQL5/MT5 link** (đúng yêu cầu).
- **Việc bạn cần ngay:** train lại DNA v2 cho strategy đang dùng (registry cũ không có `rule_paths`).
- **Vẫn đọc** OOS status + walk-forward + diagnosis: filter có thể hy sinh net để giảm toxic — không phải lúc nào cũng “free edge”.
)
