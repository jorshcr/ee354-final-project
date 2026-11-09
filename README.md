                     PC
          Image preparation / model loading
          Final box decoding / NMS
                      │
                      ▼
┌──────────────────── FPGA ────────────────────┐
│                                             │
│  Layer controller                           │
│  Dimensions, addresses, scales, start/done   │
│          │                                  │
│          ▼                                  │
│  ┌──────── Reusable accelerator ──────────┐  │
│  │ Input buffer      Weight buffer       │  │
│  │       └──────┬──────────┘              │  │
│  │              ▼                        │  │
│  │      Convolution MAC engine           │  │
│  │              ▼                        │  │
│  │     Bias / activation / rescaling     │  │
│  │              ▼                        │  │
│  │       Optional max pooling            │  │
│  │              ▼                        │  │
│  │         Output buffer                 │  │
│  └───────────────────────────────────────┘  │
│               ⇅                             │
│      Memory transfer logic + DDR2 controller│
└───────────────⇅─────────────────────────────┘
         External DDR2 memory
       Weights + feature maps
