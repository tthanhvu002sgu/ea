┌─────────────────────────────────────────────────────────┐
│                QUANTITATIVE PIPELINE                     │
│                                                         │
│  STEP 1: DATA LAYER (shared)                            │
│  └── Load CSV → Detect asset → Detect timeframe         │
│      → DataFrame dùng chung cho tất cả modules          │
│                                                         │
│  STEP 2: MARKET CONTEXT                                 │
│  ├── MEI: Thị trường có đáng trade không?               │
│  │   └── Rolling MEI → filter khung giờ inefficient     │
│  └── Regime: Loại thị trường nào?                       │
│      └── Trending / Ranging / Volatile                  │
│                                                         │
│  STEP 3: STRATEGY DISCOVERY                             │
│  ├── Built-in: Test 10 nhóm patterns                    │
│  └── Custom: Test strategies user tự định nghĩa         │
│  → Kết quả LỌC theo Regime + MEI (không phải avg chung) │
│                                                         │
│  STEP 4: PORTFOLIO CONSTRUCTION                         │
│  └── Tối ưu phân bổ vốn cho strategies đã chọn          │
│      → Input: kết quả Step 3 (đã filter theo context)    │
│                                                         │
│  STEP 5: OUTPUT                                         │
│  ├── Unified JSON report                                │
│  ├── Charts (MEI rolling, regime timeline, equity curve) │
│  └── Trading recommendations (actionable)               │
└─────────────────────────────────────────────────────────┘