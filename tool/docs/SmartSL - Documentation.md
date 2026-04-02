# 🛡️ Smart StopLoss Tool — Documentation

## Vấn Đề: Tại Sao Đặt SL Thường Bị Quét?

Hầu hết trader đặt SL theo 1 cách duy nhất:
- **Fixed pips**: "Luôn SL 100 pips" → Không thích ứng với thị trường
- **ATR**: "SL = 1.5 × ATR" → Thích ứng biến động nhưng bỏ qua cấu trúc giá
- **Swing point**: "SL dưới đáy gần nhất" → Đáy gần nhất có thể quá yếu hoặc quá gần
- **Round number**: "SL tại 2900.00" → Đây chính là nơi **market maker hay quét SL**

**Kết quả**: SL thường bị:
1. **Quét do noise** (đặt quá gần, trong vùng nhiễu ATR)
2. **Stop hunting** (đặt tại mức tâm lý rõ ràng mà mọi người đều đặt)
3. **Slippage** (khi biến động mạnh, SL thật bị trượt giá)

---

## 💡 Giải Pháp: Multi-Factor Scoring + Virtual SL

### Ý tưởng cốt lõi

Thay vì chọn SL theo 1 yếu tố, tool này **chấm điểm** nhiều ứng viên SL và chọn vị trí 
có **điểm hội tụ cao nhất** — nơi mà:

1. ✅ Có **cấu trúc bảo vệ** (swing high/low — "bức tường" giá phải phá)
2. ✅ **Ngoài vùng nhiễu** (xa hơn ATR × multiplier — không bị quét bởi dao động bình thường)
3. ✅ **Có volume backing** (swing point được hỗ trợ bởi volume lớn — mức cản thật)
4. ✅ **Tránh liquidity trap** (tránh xa round numbers — mức tâm lý bị hunt)
5. ✅ **Đa timeframe** (swing point trùng với cấu trúc H1/H4 — bội xác nhận)

### Biểu đồ minh họa logic

```
BUY Entry ═══════════════════ ← Giá vào lệnh
         │
         │  ATR noise zone (KHÔNG đặt SL ở đây!)
         │
         ├─── Swing Low A ─── Score: 45/100 ← Quá gần, volume thấp
         │
         ├─── Swing Low B ─── Score: 82/100 ← WINNER! Xa đủ, volume cao, 
         │                                     không gần round number,
         │                                     trùng H1 structure
         │
         ├─── 2900.00 ──────  (Round number — TRÁNH!)
         │
         └─── Swing Low C ─── Score: 55/100 ← Quá xa, nằm sát round number
```

---

## 📊 Hệ Thống Chấm Điểm (0-100)

| Yếu tố | Trọng số | Ý nghĩa |
|---------|----------|---------|
| **Structure Score** | 0-35 | Swing point có nổi bật không? (depth so với ATR) |
| **ATR Distance** | 0-25 | SL có ngoài vùng nhiễu? (phải > ATR × multiplier) |
| **Volume Backing** | 0-20 | Swing đó có volume lớn? (volume/avgVol) |
| **Recency** | 0-10 | Swing gần đây hơn → đáng tin hơn |
| **Confluence MTF** | 0/+10 | Có trùng với H1/H4 swing? → Bonus! |
| **Round Number** | 0/-15 | Gần round number? → Penalty nặng! |

### Chi tiết từng yếu tố:

#### 1. Structure Score (0-35 điểm)
```
depth = khoảng cách từ swing đến giá xung quanh
structureScore = min(depth / ATR × 35, 35)
```
- Swing shallow (depth < 0.3 ATR): ~10 điểm
- Swing moderate (depth = 0.5-1.0 ATR): ~20 điểm
- Swing deep (depth > 1.0 ATR): 35 điểm (max)

#### 2. ATR Distance Score (0-25 điểm)
```
distance = |entry - SL candidate|
ratio = distance / (ATR × multiplier)
```
- Quá gần (ratio < 0.8): 0 điểm → **LOẠI**
- Vừa đủ (ratio 0.8-1.0): 10 điểm
- Tốt (ratio 1.0-1.5): 20 điểm
- Lý tưởng (ratio 1.5-2.0): 25 điểm
- Quá xa (ratio > 3.0): giảm dần → SL quá xa cũng không tối ưu

#### 3. Volume Backing (0-20 điểm)
```
relVol = volume_at_swing / SMA(volume, 20)
```
- relVol < 0.5: 0 điểm (swing với volume thấp → yếu)
- relVol 0.5-1.0: 5-10 điểm
- relVol 1.0-2.0: 10-15 điểm
- relVol > 2.0: 20 điểm (swing với volume cực cao → rất mạnh)

#### 4. Recency (0-10 điểm)
```
recency = 1.0 - (bars_ago / lookback)
score = recency × 10
```
- Swing 5 bar trước: ~9 điểm
- Swing 50 bar trước: ~5 điểm
- Swing 100 bar trước: ~0 điểm

#### 5. MTF Confluence (+10 bonus)
- Kiểm tra trên H1/H4: có swing point nào gần vị trí này không?
- Nếu có → +10 điểm bonus (mức cản đa khung thời gian = rất mạnh)

#### 6. Round Number Penalty (-15)
- Kiểm tra: SL candidate có gần mức 00, 50, 000 không?
- Nếu khoảng cách < RoundNumberBuffer → -15 điểm
- Lý do: đây là nơi stop hunting xảy ra nhiều nhất

---

## 🔒 Virtual StopLoss — Tránh Slippage

### Tại sao cần Virtual SL?

**SL thật (gửi lên broker)**:
- ✅ An toàn — luôn thực thi dù mất mạng
- ❌ Broker/Market maker nhìn thấy → có thể bị hunt
- ❌ Khi biến động mạnh (news) → slippage lớn

**Virtual SL (chỉ trong EA)**:
- ✅ Broker KHÔNG thấy → không bị hunt
- ✅ EA tự close khi đến mức → có thể thêm logic chống spike
- ❌ Nếu mất mạng/EA crash → không có bảo vệ

### Giải pháp: Hybrid Mode (Mặc định)

```
Virtual SL:  đặt tại mức tối ưu (tính bởi scoring system)
Safety SL:   đặt SL thật xa hơn X pips (phòng khi mất mạng)

Khi giá chạm Virtual SL → EA close lệnh ngay
Nếu EA crash → Safety SL thật bảo vệ
```

### Anti-Spike Filter
- Khi giá chạm Virtual SL, EA kiểm tra: đây có phải là spike không?
- Nếu giá quay lại trong vòng 2 giây → KHÔNG trigger (tránh bị quét giả)
- Nếu giá ở dưới Virtual SL > 2 giây → TRIGGER đóng lệnh

---

## ⚙️ Input Parameters

| Tham số | Mặc định | Mô tả |
|---------|----------|-------|
| **Mode** | Hybrid | `Virtual`, `Real`, hoặc `Hybrid` |
| **ATR Period** | 14 | Chu kỳ ATR dùng để tính noise |
| **ATR Multiplier** | 1.5 | Khoảng cách tối thiểu = ATR × multiplier |
| **Swing Lookback** | 100 | Số bar quét tìm swing points |
| **Swing Strength** | 5 | Số bar mỗi bên để xác nhận swing |
| **Round Number Buffer** | 30 | Nếu SL cách round number < N points → penalty |
| **Safety SL Offset** | 200 | SL thật đặt xa hơn Virtual SL bao nhiêu points |
| **Anti-Spike Seconds** | 2 | Thời gian chờ xác nhận trước khi trigger Virtual SL |
| **Max SL (USD)** | 5.0 | Giới hạn loss tối đa (USD) |
| **Auto Trail** | true | Tự động trail SL khi lời |
| **MTF Period** | H1 | Timeframe cao hơn để check confluence |

---

## 💡 Cách Sử Dụng

1. Kéo tool vào chart
2. Mở lệnh BUY hoặc SELL (bằng EA khác hoặc manual)
3. Tool tự động:
   - Quét swing points
   - Chấm điểm từng ứng viên SL
   - Chọn SL tối ưu nhất
   - Đặt Virtual SL + Safety SL (hoặc Real SL tùy mode)
   - Hiển thị mọi thông tin trên panel
4. Khi lệnh đang lời, tool tự trail SL theo logic tương tự
5. Nhấn **Recalculate** bất kỳ lúc nào để tính lại

---

## 📂 Files

| File | Mô tả |
|------|-------|
| `SmartSL.mq5` | Tool chính (Expert Advisor) |
| `SmartSL - Documentation.md` | Tài liệu này |

---

*© Smart StopLoss Tool — Multi-Factor Optimal Placement*
