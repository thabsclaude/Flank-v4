# Flank v4

A rule-based consolidation-zone continuation system for MetaTrader 5, published as research.

The system enters trades in the direction of the prevailing trend from inside consolidation zones detected online by a purpose-built state machine. It was tested across a full instrument universe without optimisation, then with a restricted timeframe search on the two strongest instruments.

**It is not deployed, and this repository does not recommend deploying it.** The reason is documented in full in the paper: the position sizes implied by the risk model cannot be financed at equity margin rates. The strategy is profitable in a backtest at 1:100 leverage and impossible to open at 1:3.

📄 **[Read the paper](docs/Flank%20v4%20Research.md)**  ·  [PDF](docs/Flank%20v4%20Research.pdf)  ·  [Word](docs/Flank%20v4%20Research.docx)

---

## Results summary

Unoptimised, default timeframes, full Market Watch scan, Jan 2022 to Jul 2026:

| Instrument | Profit factor | Trades | t-statistic |
|---|---|---|---|
| TSLA | 1.25 | 727 | 2.94 |
| BABA | 1.18 | 636 | 2.13 |
| AAPL | 1.17 | 710 | 2.14 |
| META | 1.13 | 670 | 1.66 |
| XAUUSD | 0.99 | 2,488 | −0.17 |

Every non-equity instrument failed. Correcting for a thirty-instrument scan requires t ≈ 2.94, which only TSLA reaches, and only with an optimistic variance estimate.

After searching the five engine timeframes on TSLA and BABA and changing nothing else:

| Instrument | Profit factor | Trades | Net return | Sharpe | Max equity DD |
|---|---|---|---|---|---|
| BABA | 1.46 | 2,134 | +894.8% | 4.68 | 11.24% |
| TSLA | 1.35 | 2,599 | +730.4% | 3.90 | 26.30% |

These stage 2 figures are in-sample. Timeframes were selected on the same data used to score them.

---

## The finding

Both stage 2 runs peak near 50 percent deposit load at 1:100 leverage. Equity margin at 1:3 is 33.3 times more expensive, which puts the same position set at roughly 1,667 percent of the account.

The cause is structural. A stop at twice the M30 ATR on a large-cap equity is around one percent of notional, so risking one percent of the account behind it requires notional exposure close to the full balance for a single position. The specification allows three.

Holding margin level constant at 1:3 means dividing size by 33, which turns 1 percent risk per trade into 0.03 percent and a 730 percent return into roughly 22 percent over four and a half years.

More capital does not solve this, because the constraint scales with the account. The system generates too little expectancy per unit of margin consumed to survive equity margin rules.

---

## Repository layout

```
├── src/
│   └── Flank v4.mq5          Expert Advisor, complete implementation
├── params/
│   └── Flank v4 TSLA.set     Stage 2 parameter set
├── docs/
│   ├── Flank v4 Research.md   Full paper (Markdown, renders on GitHub)
│   ├── Flank v4 Research.docx Word version
│   ├── Flank v4 Research.pdf  PDF version
│   └── figures/               Strategy Tester reports and equity curves
└── README.md
```

---

## Running it

1. Copy `src/Flank v4.mq5` into `MQL5/Experts/` inside your terminal's data folder.
2. Compile in MetaEditor. No external dependencies beyond the standard `Trade` library.
3. Open the Strategy Tester, select the EA, and load `params/Flank v4 TSLA.set` from the Inputs tab.
4. Set modelling to *Every tick based on real ticks* and confirm history quality is above 95 percent before reading any result.

The EA reads its own timeframes from inputs and does not depend on the chart timeframe.

### Diagnostics

If a run produces no trades, set `InpVerbose = true` and read the Journal. Every pass prints a `[DIAG]` line on deinitialisation giving the symbol, bars processed, entries taken, and a count of which gate blocked each candidate:

```
[DIAG] TSLA bars=435998 | entries=2599 | blocked: warmup=0 noZone=... resting=... chop=... margin=...
```

A high `margin=` count means position sizing exceeded the margin ceiling. A high `warmup=` count with low `bars=` means there was not enough history to seed the state machine.

### Visual verification

Set `InpDrawZones = true` and run in visual mode to render detected zones on the chart. The state machine is path dependent from the start of history, so a single divergence early compounds. Confirming the boxes visually is the fastest way to check that the engine is behaving.

---

## Implementation notes

- Every higher-timeframe read uses closed bars only. Entries are evaluated at the close of a completed execution bar and filled at the open of the next.
- Initial risk is locked at fill. The stop trails, so measuring RR against the live stop would make the arming threshold a moving target.
- Position size is capped by a margin utilisation ceiling in addition to the risk fraction. Without it, a tight ATR stop on a low-volatility instrument drives deposit load past 100 percent.
- The state machine replays a warm-up window at initialisation so a backtest and a live instance reach the same state from the same data.

---

## Status and next steps

Published as research. Not under active development for deployment.

Open work, in order of value:

- Walk-forward validation of the stage 2 timeframes on data held back from the search.
- A permutation test: shuffle entry signals within the same bar distribution and locate the observed profit factor in the resulting null distribution.
- Commission modelling. At 2,000 plus trades on a one-minute frame, per-trade cost is material and is currently absent.
- A port of the detection engine to C++ with a Python analysis layer, with a reconciliation test asserting identical zone boundaries and entry timestamps against the MQL5 output.

---

## Licence

MIT. See `LICENSE`.

This repository is published for research and educational purposes. It is not financial advice and it is not a recommendation to trade. Past simulated performance does not indicate future results.
