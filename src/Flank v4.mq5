//+------------------------------------------------------------------+
//|                                                     Flank_v4.mq5 |
//|                                                                  |
//|  FLANK v4 - Consolidation-Zone Continuation System               |
//|                                                                  |
//|  Faithful MQL5 port of:                                          |
//|    * "Flank v1" rule set (Definitions / Rules / Execution / Exit) |
//|    * "Consolidation Detection Engine [CDE]" Pine v6 indicator     |
//|                                                                  |
//|  ARCHITECTURE                                                    |
//|    M5   : CDE state machine -> consolidation zones + entries      |
//|    M15  : Choppiness Index block filter                           |
//|    H1   : ATR (volatility) for SL / TP / position sizing          |
//|    H2   : RSI resting point + SMMA-9 retest release               |
//|    H4   : SMMA-9 break-and-retest -> trend direction              |
//|                                                                  |
//|  NON-REPAINTING: every higher-timeframe read uses shift >= 1      |
//|  (closed bars only). Entries are evaluated on M5 bar close.       |
//+------------------------------------------------------------------+
#property copyright "Flank v1"
#property link      ""
#property version   "4.00"
#property description "Flank v4 - CDE consolidation zone continuation EA"

#include <Trade/Trade.mqh>

//==================================================================
//                            INPUTS
//==================================================================

enum ENUM_CDE_MODE { CDE_FIXED = 0, CDE_PERCENTILE = 1 };

input group "=== 1. EXECUTION / ENGINE TIMEFRAMES ==="
//  Defaults below are the timeframe set selected on TSLA and BABA.
//  The original specification used M5 / M15 / H1 / H2 / H4; only these
//  five values were changed during the timeframe search.
input ENUM_TIMEFRAMES InpZoneTF        = PERIOD_M1;   // Zone + execution timeframe
input ENUM_TIMEFRAMES InpChopTF        = PERIOD_M1;   // Choppiness filter timeframe
input ENUM_TIMEFRAMES InpVolTF         = PERIOD_M30;  // Volatility (ATR) timeframe
input ENUM_TIMEFRAMES InpRestTF        = PERIOD_M30;  // Resting point timeframe
input ENUM_TIMEFRAMES InpTrendTF       = PERIOD_M15;  // Trend direction timeframe

input group "=== 2. CDE - CORE DETECTION WINDOW ==="
input int    InpDetLen                 = 20;      // Detection window (bars)

input ENUM_CDE_MODE InpCdeMode         = CDE_FIXED;  // Thresholding mode
input int    InpPctLB                  = 500;     // Percentile lookback
input double InpPctTail                = 25.0;    // Quiet-tail %

input group "=== 3. CDE - FIXED THRESHOLDS ==="
input bool   InpUseER                  = true;    // Efficiency Ratio filter
input double InpErMax                  = 0.35;    //   Max Efficiency Ratio
input bool   InpUseSlope               = true;    // Regression slope filter
input double InpSlopeMax               = 0.15;    //   Max |slope| (ATR/bar)
input bool   InpUseRange               = true;    // Range height filter
input double InpRngMax                 = 6.0;     //   Max range (ATR)
input bool   InpUseComp                = false;   // ATR compression filter
input double InpCompMax                = 0.90;    //   Max ATRfast/ATRslow
input bool   InpUseChopCde             = false;   // Choppiness filter (inside CDE)
input double InpChopMinCde             = 50.0;    //   Min CHOP

input group "=== 4. CDE - FEATURE LENGTHS ==="
input int    InpAtrLen                 = 14;      // ATR (normaliser)
input int    InpAtrFast                = 14;      // ATR fast (compression)
input int    InpAtrSlow                = 100;     // ATR slow (compression)
input int    InpChopLenCde             = 14;      // Choppiness length (CDE)

input group "=== 5. CDE - ZONE CONSTRUCTION ==="
input int    InpMinBars                = 8;       // Min bars to confirm zone
input int    InpMaxTol                 = 2;       // Noisy bars tolerated
input double InpBrkBuf                 = 0.0;     // Breakout buffer (ATR)
input int    InpMinTouch               = 0;       // Min touches of EACH boundary (0=off)
input double InpTouchTol               = 0.5;     // Touch tolerance (ATR)
input int    InpWarmupBars             = 3000;    // Warm-up bars for CDE state machine

input group "=== 6. TREND (SMMA-9 BREAK & RETEST) ==="
input int    InpSmmaPeriod             = 9;       // SMMA period
input int    InpRetestWindow            = 12;     // Max bars for retest after break
input bool   InpRetestNeedsClose       = true;    // Retest bar must close back on break side

input group "=== 7. RESTING POINT (RSI) ==="
input int    InpRsiPeriod              = 14;      // RSI period
input double InpRsiOB                  = 70.0;    // Overbought level (>=)
input double InpRsiOS                  = 30.0;    // Oversold level (<=)
input bool   InpRestBlocksBothSides    = true;    // true = blocks ALL trades (literal spec)

input group "=== 8. CHOP FILTER ==="
input int    InpChopLenFilter          = 14;      // Choppiness length (filter)
input double InpChopBlockLevel         = 50.5;    // Block when CHOP >=
input bool   InpBlockChopRising        = true;    // Block when CHOP rising

input group "=== 9. RISK / SIZING ==="
input double InpRiskPct                = 1.0;     // Risk per trade (% of balance)
input double InpMaxMarginUtilPct       = 15.0;    // Max margin per trade (% of free margin)
input double InpMaxLotCap              = 0.0;     // Hard lot ceiling (0 = off)
input int    InpMaxPositions           = 3;       // Max concurrent positions
input bool   InpInverted               = false;   // Inverted toggle (flip Buy/Sell)
input double InpFixedLot               = 0.0;     // Fixed lot (0 = use % risk)

input group "=== 10. EXIT ==="
input double InpSlAtrMult              = 2.0;     // Stop loss = N x ATR(InpVolTF)
input double InpTpAtrMult              = 5.0;     // Hard TP = N x ATR(InpVolTF)
input bool   InpUseTrail               = true;    // Trail SL at N x ATR
input bool   InpTrailUsesLiveATR       = false;   // true = recompute ATR each bar
input double InpArmAtRR                = 1.0;     // Arm dynamic exit at this RR
input double InpGivebackPct            = 30.0;    // Dynamic exit: % giveback from peak

input group "=== 11. MISC ==="
input long   InpMagic                  = 990311;  // Magic number
input int    InpSlippage               = 30;      // Deviation (points)
input bool   InpDrawZones              = false;   // Draw zones on chart
input bool   InpVerbose                = false;   // Verbose logging

//==================================================================
//                          GLOBALS
//==================================================================

CTrade  trade;

int hAtrZone   = INVALID_HANDLE;   // ATR normaliser on zone TF
int hAtrFast   = INVALID_HANDLE;
int hAtrSlow   = INVALID_HANDLE;
int hAtrVol    = INVALID_HANDLE;   // ATR on volatility TF (H1)
int hSmmaTrend = INVALID_HANDLE;   // SMMA-9 on H4
int hSmmaRest  = INVALID_HANDLE;   // SMMA-9 on H2
int hRsiRest   = INVALID_HANDLE;   // RSI on H2

double g_point, g_tickSize, g_tickValue, g_lotStep, g_lotMin, g_lotMax;
int    g_digits, g_stopLevel, g_freezeLevel;
bool   g_symbolReady = false;   // true once tick size / tick value are readable

//--- (re)read symbol properties. In a Market Watch scan these can be
//    unavailable at OnInit for symbols the terminal has not yet synced,
//    so this is retried on tick rather than aborting the pass.
void RefreshSymbolInfo(void)
{
   g_digits     = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   g_point      = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   g_tickSize   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   g_tickValue  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(g_tickValue <= 0.0) g_tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   g_lotStep    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   g_lotMin     = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   g_lotMax     = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   g_stopLevel  = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   g_freezeLevel= (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);

   g_symbolReady = (g_tickSize > 0.0 && g_tickValue > 0.0 &&
                    g_lotStep  > 0.0 && g_point     > 0.0);
}

//==================================================================
//                       SMALL UTILITIES
//==================================================================

bool IsValid(const double v)
{
   return (v != EMPTY_VALUE && v != DBL_MAX && MathIsValidNumber(v));
}

//--- read one value from an indicator buffer at a given shift
double IndVal(const int handle, const int shift, const int buffer = 0)
{
   if(handle == INVALID_HANDLE) return EMPTY_VALUE;
   double b[];
   ArraySetAsSeries(b, true);
   if(CopyBuffer(handle, buffer, shift, 1, b) < 1) return EMPTY_VALUE;
   if(!MathIsValidNumber(b[0])) return EMPTY_VALUE;
   return b[0];
}

//--- Choppiness Index, replicating the Pine formulation exactly:
//    chop = 100 * log( sum(TR, len) / (highest(high,len) - lowest(low,len)) ) / log(len)
double ChopIndex(const string sym, const ENUM_TIMEFRAMES tf,
                 const int len, const int shift)
{
   if(len < 2) return EMPTY_VALUE;
   double h[], l[], c[];
   ArraySetAsSeries(h, true); ArraySetAsSeries(l, true); ArraySetAsSeries(c, true);
   const int need = len + 1;                     // +1 for prior close in TR
   if(CopyHigh (sym, tf, shift, need, h) < need) return EMPTY_VALUE;
   if(CopyLow  (sym, tf, shift, need, l) < need) return EMPTY_VALUE;
   if(CopyClose(sym, tf, shift, need, c) < need) return EMPTY_VALUE;

   double trSum = 0.0, hh = -DBL_MAX, ll = DBL_MAX;
   for(int i = 0; i < len; i++)
   {
      const double tr = MathMax(h[i] - l[i],
                        MathMax(MathAbs(h[i] - c[i + 1]),
                                MathAbs(l[i] - c[i + 1])));
      trSum += tr;
      if(h[i] > hh) hh = h[i];
      if(l[i] < ll) ll = l[i];
   }
   const double den = hh - ll;
   if(den <= 0.0 || trSum <= 0.0) return EMPTY_VALUE;
   return 100.0 * MathLog(trSum / den) / MathLog((double)len);
}

//--- percent rank of v against the stored history (Pine ta.percentrank semantics:
//    "percent of previous values that were <= the current value")
double PercentRank(const double &hist[], const int count, const double v)
{
   if(count < 1) return -1.0;
   int c = 0;
   for(int i = 0; i < count; i++)
      if(hist[i] <= v) c++;
   return 100.0 * (double)c / (double)count;
}

//==================================================================
//              CONSOLIDATION DETECTION ENGINE (CDE)
//==================================================================
//  Direct port of the Pine v6 state machine.
//  st: 0 IDLE, 1 FORMING (candidate), 2 ACTIVE (zone confirmed)
//==================================================================
class CCDE
{
private:
   // --- state machine
   int      m_st;
   double   m_zTop, m_zBot;
   int      m_nBars, m_tolCnt, m_topTch, m_botTch;
   long     m_zoneId;            // monotonically increasing id per confirmed zone
   datetime m_zoneStart;
   datetime m_lastBar;
   bool     m_warmed;

   // --- percentile ring buffers
   double   m_hER[], m_hSlp[], m_hRng[], m_hCmp[], m_hChp[];
   int      m_bufSize, m_bufCount, m_bufPos;

   // --- last computed feature values (for logging / dashboard)
   double   m_er, m_slp, m_rng, m_cmp, m_chp;
   bool     m_isConsol;

   // --- last VALID optional features, carried forward so that an
   //     occasional na (flat range -> CHOP undefined) does not corrupt
   //     the percentile ranking history
   double   m_lastCmpOK, m_lastChpOK;
   bool     m_haveCmpOK, m_haveChpOK;

   void PushHistory(const double er, const double slp, const double rng,
                    const double cmp, const double chp)
   {
      m_hER [m_bufPos] = er;
      m_hSlp[m_bufPos] = slp;
      m_hRng[m_bufPos] = rng;
      m_hCmp[m_bufPos] = cmp;
      m_hChp[m_bufPos] = chp;
      m_bufPos = (m_bufPos + 1) % m_bufSize;
      if(m_bufCount < m_bufSize) m_bufCount++;
   }

   //--- compute the five CDE features at a given shift on the zone timeframe
   bool ComputeFeatures(const int shift, double &er, double &slp,
                        double &rng, double &cmp, double &chp)
   {
      er = slp = rng = cmp = chp = EMPTY_VALUE;

      const int need = InpDetLen + 2;
      double h[], l[], c[];
      ArraySetAsSeries(h, true); ArraySetAsSeries(l, true); ArraySetAsSeries(c, true);
      if(CopyHigh (_Symbol, InpZoneTF, shift, need, h) < need) return false;
      if(CopyLow  (_Symbol, InpZoneTF, shift, need, l) < need) return false;
      if(CopyClose(_Symbol, InpZoneTF, shift, need, c) < need) return false;

      const double atrN = IndVal(hAtrZone, shift);
      if(!IsValid(atrN) || atrN <= 0.0) return false;

      // ---- Kaufman Efficiency Ratio -------------------------------
      const double netChg = MathAbs(c[0] - c[InpDetLen]);
      double pathLn = 0.0;
      for(int i = 0; i < InpDetLen; i++)
         pathLn += MathAbs(c[i] - c[i + 1]);
      er = (pathLn != 0.0) ? netChg / pathLn : 0.0;

      // ---- OLS regression slope per bar, normalised by ATR --------
      //  Pine: ta.linreg(close,L,0) - ta.linreg(close,L,1) == OLS slope.
      //  x runs oldest(0) -> newest(L-1) so the sign matches Pine; we
      //  take |slope| anyway.
      {
         const int    L  = InpDetLen;
         double sx = 0.0, sy = 0.0, sxy = 0.0, sxx = 0.0;
         for(int i = 0; i < L; i++)
         {
            const double x = (double)(L - 1 - i);   // c[i] is newest at i=0
            const double y = c[i];
            sx  += x;  sy  += y;
            sxy += x * y;
            sxx += x * x;
         }
         const double den = (double)L * sxx - sx * sx;
         if(den == 0.0) return false;
         const double slopeRaw = ((double)L * sxy - sx * sy) / den;
         slp = MathAbs(slopeRaw) / atrN;
      }

      // ---- Range in ATR units -------------------------------------
      {
         double hh = -DBL_MAX, ll = DBL_MAX;
         for(int i = 0; i < InpDetLen; i++)
         {
            if(h[i] > hh) hh = h[i];
            if(l[i] < ll) ll = l[i];
         }
         rng = (hh - ll) / atrN;
      }

      // ---- ATR compression ----------------------------------------
      {
         const double af = IndVal(hAtrFast, shift);
         const double as = IndVal(hAtrSlow, shift);
         if(IsValid(af) && IsValid(as) && as != 0.0) cmp = af / as;
         else                                        cmp = EMPTY_VALUE;
      }

      // ---- Choppiness ---------------------------------------------
      chp = ChopIndex(_Symbol, InpZoneTF, InpChopLenCde, shift);

      return true;
   }

   //--- per-bar consolidation verdict
   bool EvalConsolidation(const double er, const double slp, const double rng,
                          const double cmp, const double chp)
   {
      bool cER = true, cSlp = true, cRng = true, cCmp = true, cChp = true;

      if(InpCdeMode == CDE_FIXED)
      {
         // NOTE: Pine treats `na < x` as false, so an unavailable feature
         // fails its condition. Mirrored here.
         cER  = (!InpUseER)      || (IsValid(er)  && er  < InpErMax);
         cSlp = (!InpUseSlope)   || (IsValid(slp) && slp < InpSlopeMax);
         cRng = (!InpUseRange)   || (IsValid(rng) && rng < InpRngMax);
         cCmp = (!InpUseComp)    || (IsValid(cmp) && cmp < InpCompMax);
         cChp = (!InpUseChopCde) || (IsValid(chp) && chp > InpChopMinCde);
      }
      else
      {
         if(m_bufCount < m_bufSize) return false;   // Pine returns na until filled

         const double pER  = PercentRank(m_hER , m_bufCount, er);
         const double pSlp = PercentRank(m_hSlp, m_bufCount, slp);
         const double pRng = PercentRank(m_hRng, m_bufCount, rng);
         const double pCmp = PercentRank(m_hCmp, m_bufCount, cmp);
         const double pChp = PercentRank(m_hChp, m_bufCount, chp);

         cER  = (!InpUseER)      || (pER  >= 0.0 && pER  <= InpPctTail);
         cSlp = (!InpUseSlope)   || (pSlp >= 0.0 && pSlp <= InpPctTail);
         cRng = (!InpUseRange)   || (pRng >= 0.0 && pRng <= InpPctTail);
         cCmp = (!InpUseComp)    || (pCmp >= 0.0 && pCmp <= InpPctTail);
         cChp = (!InpUseChopCde) || (pChp >= 0.0 && pChp >= 100.0 - InpPctTail);
      }
      return (cER && cSlp && cRng && cCmp && cChp);
   }

   //--- process exactly one closed bar at `shift`
   void ProcessBar(const int shift)
   {
      double er, slp, rng, cmp, chp;
      if(!ComputeFeatures(shift, er, slp, rng, cmp, chp)) return;

      const double atrN = IndVal(hAtrZone, shift);
      if(!IsValid(atrN) || atrN <= 0.0) return;

      const bool isConsol = EvalConsolidation(er, slp, rng, cmp, chp);

      // history is pushed AFTER evaluation so percentrank compares against
      // strictly previous values (Pine semantics).
      // ER / slope / range are always defined once ATR exists. The two
      // optional features can be na; carry the last valid value forward
      // rather than injecting DBL_MAX into the ranking window.
      if(IsValid(cmp)) { m_lastCmpOK = cmp; m_haveCmpOK = true; }
      if(IsValid(chp)) { m_lastChpOK = chp; m_haveChpOK = true; }
      const double pCmp = m_haveCmpOK ? m_lastCmpOK : 0.0;
      const double pChp = m_haveChpOK ? m_lastChpOK : 0.0;
      if(IsValid(er) && IsValid(slp) && IsValid(rng))
         PushHistory(er, slp, rng, pCmp, pChp);

      m_er = er; m_slp = slp; m_rng = rng; m_cmp = cmp; m_chp = chp;
      m_isConsol = isConsol;

      double bh[], bl[], bc[];
      ArraySetAsSeries(bh, true); ArraySetAsSeries(bl, true); ArraySetAsSeries(bc, true);
      if(CopyHigh (_Symbol, InpZoneTF, shift, 1, bh) < 1) return;
      if(CopyLow  (_Symbol, InpZoneTF, shift, 1, bl) < 1) return;
      if(CopyClose(_Symbol, InpZoneTF, shift, 1, bc) < 1) return;
      const double bHigh = bh[0], bLow = bl[0], bClose = bc[0];
      const datetime bTime = iTime(_Symbol, InpZoneTF, shift);

      //================= STATE MACHINE (Pine port) =================
      if(m_st == 0)                                   // ---- IDLE ----
      {
         if(isConsol)
         {
            m_st        = 1;
            m_zoneStart = bTime;
            m_zTop      = bHigh;
            m_zBot      = bLow;
            m_nBars     = 1;
            m_tolCnt    = 0;
            m_topTch    = 0;
            m_botTch    = 0;
         }
      }
      else if(m_st == 1)                              // ---- FORMING ----
      {
         // touches counted against the boundary as it stood BEFORE this
         // bar expands it (identical ordering to Pine)
         if(InpMinTouch > 0)
         {
            if(bHigh >= m_zTop - InpTouchTol * atrN) m_topTch++;
            if(bLow  <= m_zBot + InpTouchTol * atrN) m_botTch++;
         }

         if(isConsol)
         {
            m_zTop  = MathMax(m_zTop, bHigh);
            m_zBot  = MathMin(m_zBot, bLow);
            m_nBars++;
            m_tolCnt = 0;

            const bool touchOK = (InpMinTouch == 0) ||
                                 (m_topTch >= InpMinTouch && m_botTch >= InpMinTouch);
            if(m_nBars >= InpMinBars && touchOK)
            {
               m_st = 2;
               m_zoneId++;                      // new confirmed zone
               if(InpDrawZones) DrawZone(true, bTime);
               if(InpVerbose)
                  PrintFormat("[CDE] zone #%d CONFIRMED  top=%.*f bot=%.*f bars=%d",
                              (int)m_zoneId, g_digits, m_zTop, g_digits, m_zBot, m_nBars);
            }
         }
         else
         {
            m_tolCnt++;
            if(m_tolCnt > InpMaxTol) m_st = 0;  // candidate died, nothing drawn
         }
      }
      else if(m_st == 2)                              // ---- ACTIVE ----
      {
         // breakout tested against boundary as it stood at bar start
         const bool brokeUp   = (bClose > m_zTop + InpBrkBuf * atrN);
         const bool brokeDown = (bClose < m_zBot - InpBrkBuf * atrN);

         if(brokeUp || brokeDown)
         {
            if(InpDrawZones) DrawZone(false, bTime);
            if(InpVerbose)
               PrintFormat("[CDE] zone #%d BREAKOUT %s", (int)m_zoneId,
                           brokeUp ? "UP" : "DOWN");
            m_st = 0;
         }
         else
         {
            if(isConsol) m_tolCnt = 0;
            else         m_tolCnt++;

            if(m_tolCnt > InpMaxTol)
            {
               if(InpDrawZones) DrawZone(false, bTime);
               if(InpVerbose) PrintFormat("[CDE] zone #%d DISSOLVED", (int)m_zoneId);
               m_st = 0;
            }
            else
            {
               m_zTop = MathMax(m_zTop, bHigh);
               m_zBot = MathMin(m_zBot, bLow);
               m_nBars++;
               if(InpDrawZones) DrawZone(true, bTime);
            }
         }
      }
   }

   void DrawZone(const bool live, const datetime tRight)
   {
      const string nm = StringFormat("CDE_%d", (int)m_zoneId);
      if(ObjectFind(0, nm) < 0)
      {
         if(!ObjectCreate(0, nm, OBJ_RECTANGLE, 0, m_zoneStart, m_zTop, tRight, m_zBot))
            return;
         ObjectSetInteger(0, nm, OBJPROP_FILL, true);
         ObjectSetInteger(0, nm, OBJPROP_BACK, true);
      }
      ObjectSetDouble (0, nm, OBJPROP_PRICE, 0, m_zTop);
      ObjectSetDouble (0, nm, OBJPROP_PRICE, 1, m_zBot);
      ObjectSetInteger(0, nm, OBJPROP_TIME,  0, m_zoneStart);
      ObjectSetInteger(0, nm, OBJPROP_TIME,  1, tRight);
      ObjectSetInteger(0, nm, OBJPROP_COLOR, live ? clrRoyalBlue : clrPurple);
   }

public:
   CCDE(void) : m_st(0), m_zTop(0), m_zBot(0), m_nBars(0), m_tolCnt(0),
                m_topTch(0), m_botTch(0), m_zoneId(0), m_zoneStart(0),
                m_lastBar(0), m_warmed(false), m_bufSize(0), m_bufCount(0),
                m_bufPos(0), m_er(0), m_slp(0), m_rng(0), m_cmp(0), m_chp(0),
                m_isConsol(false), m_lastCmpOK(0), m_lastChpOK(0),
                m_haveCmpOK(false), m_haveChpOK(false) {}

   void Init(void)
   {
      m_bufSize = MathMax(10, InpPctLB);
      ArrayResize(m_hER , m_bufSize); ArrayInitialize(m_hER , 0.0);
      ArrayResize(m_hSlp, m_bufSize); ArrayInitialize(m_hSlp, 0.0);
      ArrayResize(m_hRng, m_bufSize); ArrayInitialize(m_hRng, 0.0);
      ArrayResize(m_hCmp, m_bufSize); ArrayInitialize(m_hCmp, 0.0);
      ArrayResize(m_hChp, m_bufSize); ArrayInitialize(m_hChp, 0.0);
      m_bufCount = 0; m_bufPos = 0;
   }

   //--- returns true when a NEW closed bar was processed on the zone TF
   bool Update(void)
   {
      const datetime t = iTime(_Symbol, InpZoneTF, 0);
      if(t == 0) return false;
      if(t == m_lastBar) return false;

      if(!m_warmed)
      {
         Warmup();
         m_lastBar = t;
         return m_warmed;          // no signal on the warm-up pass itself
      }

      ProcessBar(1);               // shift 1 = the bar that just closed
      m_lastBar = t;
      return true;
   }

   //--- replay history so the state machine and percentile buffers are
   //    seeded exactly as a live-running instance would have been
   void Warmup(void)
   {
      const int barsAvail = Bars(_Symbol, InpZoneTF);
      const int minHist   = MathMax(InpDetLen, MathMax(InpAtrSlow, InpChopLenCde)) + 5;
      const int needed    = (InpCdeMode == CDE_PERCENTILE)
                            ? InpPctLB + minHist + 50
                            : minHist + 50;
      if(barsAvail < needed) return;              // wait for more history

      if(BarsCalculated(hAtrZone) < needed)  return;
      if(BarsCalculated(hAtrSlow) < needed)  return;

      // leave a safety margin at the far edge of history so we never
      // evaluate bars where the slow ATR is still un-warmed
      int start = (int)MathMin((double)InpWarmupBars, (double)(barsAvail - minHist - 60));
      if(start < 1) return;

      for(int s = start; s >= 1; s--)
         ProcessBar(s);

      m_warmed = true;
      PrintFormat("[CDE] warm-up complete: %d bars replayed, state=%d, zones=%d",
                  start, m_st, (int)m_zoneId);
   }

   bool   Warmed(void)     const { return m_warmed; }
   bool   IsActive(void)   const { return (m_st == 2); }
   long   ZoneId(void)     const { return m_zoneId; }
   double Top(void)        const { return m_zTop; }
   double Bottom(void)     const { return m_zBot; }
   int    State(void)      const { return m_st; }
   int    ZoneBars(void)   const { return m_nBars; }
};

CCDE cde;

//==================================================================
//        TREND DIRECTION - SMMA-9 BREAK AND RETEST (InpTrendTF)
//==================================================================
//  A "break" is a close crossing the SMMA-9.
//  A "retest" is a subsequent bar that trades back into the SMMA-9
//  and (optionally) closes back on the break side, within
//  InpRetestWindow bars. Only then does the trend flip.
//  Trend persists until the OPPOSITE break-and-retest completes.
//==================================================================
class CTrendH4
{
private:
   int      m_dir;          // +1 bull, -1 bear, 0 undefined
   int      m_pending;      // pending break awaiting retest
   int      m_barsSince;
   datetime m_lastBar;
   bool     m_warmed;

   void ProcessBar(const int shift)
   {
      const double smma1 = IndVal(hSmmaTrend, shift);
      const double smma2 = IndVal(hSmmaTrend, shift + 1);
      if(!IsValid(smma1) || !IsValid(smma2)) return;

      const double c1 = iClose(_Symbol, InpTrendTF, shift);
      const double c2 = iClose(_Symbol, InpTrendTF, shift + 1);
      const double h1 = iHigh (_Symbol, InpTrendTF, shift);
      const double l1 = iLow  (_Symbol, InpTrendTF, shift);
      if(c1 == 0.0 || c2 == 0.0) return;

      const bool breakUp = (c1 > smma1 && c2 <= smma2);
      const bool breakDn = (c1 < smma1 && c2 >= smma2);

      if(breakUp)      { m_pending = +1; m_barsSince = 0; return; }
      if(breakDn)      { m_pending = -1; m_barsSince = 0; return; }
      if(m_pending == 0) return;

      m_barsSince++;
      if(m_barsSince > InpRetestWindow) { m_pending = 0; return; }

      if(m_pending == +1)
      {
         const bool touched = (l1 <= smma1);
         const bool closeOK = (!InpRetestNeedsClose) || (c1 > smma1);
         if(touched && closeOK)
         {
            m_dir = +1;
            m_pending = 0;
            if(InpVerbose) Print("[TREND] H4 flipped BULLISH (break & retest above SMMA9)");
         }
      }
      else if(m_pending == -1)
      {
         const bool touched = (h1 >= smma1);
         const bool closeOK = (!InpRetestNeedsClose) || (c1 < smma1);
         if(touched && closeOK)
         {
            m_dir = -1;
            m_pending = 0;
            if(InpVerbose) Print("[TREND] H4 flipped BEARISH (break & retest below SMMA9)");
         }
      }
   }

public:
   CTrendH4(void) : m_dir(0), m_pending(0), m_barsSince(0),
                    m_lastBar(0), m_warmed(false) {}

   void Update(void)
   {
      const datetime t = iTime(_Symbol, InpTrendTF, 0);
      if(t == 0 || t == m_lastBar) return;

      if(!m_warmed)
      {
         const int avail = Bars(_Symbol, InpTrendTF);
         if(avail > InpSmmaPeriod + 10 && BarsCalculated(hSmmaTrend) > InpSmmaPeriod + 10)
         {
            const int start = (int)MathMin(1500.0, (double)(avail - InpSmmaPeriod - 5));
            for(int s = start; s >= 1; s--) ProcessBar(s);
            m_warmed = true;
            PrintFormat("[TREND] warm-up complete: dir=%d", m_dir);
         }
         m_lastBar = t;
         return;
      }

      ProcessBar(1);
      m_lastBar = t;
   }

   int  Dir(void)    const { return m_dir; }
   bool Warmed(void) const { return m_warmed; }
};

CTrendH4 trendH4;

//==================================================================
//        RESTING POINT - RSI + SMMA-9 RETEST RELEASE (InpRestTF)
//==================================================================
//  Enter resting when RSI >= 70 or <= 30 on InpRestTF.
//  Release when a closed bar's range touches the SMMA-9 on that TF.
//  Per-bar order: release first, then re-arm - so a bar that touches
//  the SMMA while still overbought remains in the resting state.
//==================================================================
class CRestingH2
{
private:
   bool     m_resting;
   int      m_side;         // +1 overbought, -1 oversold, 0 none
   datetime m_lastBar;
   bool     m_warmed;

   void ProcessBar(const int shift)
   {
      const double rsi  = IndVal(hRsiRest,  shift);
      const double smma = IndVal(hSmmaRest, shift);
      if(!IsValid(rsi) || !IsValid(smma)) return;

      const double h = iHigh(_Symbol, InpRestTF, shift);
      const double l = iLow (_Symbol, InpRestTF, shift);
      if(h == 0.0 || l == 0.0) return;

      // 1) release on SMMA-9 retest (range touches the line)
      if(m_resting && l <= smma && h >= smma)
      {
         m_resting = false;
         m_side    = 0;
         if(InpVerbose) Print("[REST] released - H2 retested SMMA9");
      }

      // 2) (re-)arm on RSI extreme
      if(rsi >= InpRsiOB)      { m_resting = true; m_side = +1; }
      else if(rsi <= InpRsiOS) { m_resting = true; m_side = -1; }
   }

public:
   CRestingH2(void) : m_resting(false), m_side(0), m_lastBar(0), m_warmed(false) {}

   void Update(void)
   {
      const datetime t = iTime(_Symbol, InpRestTF, 0);
      if(t == 0 || t == m_lastBar) return;

      if(!m_warmed)
      {
         const int avail = Bars(_Symbol, InpRestTF);
         const int minH  = MathMax(InpRsiPeriod, InpSmmaPeriod) + 10;
         if(avail > minH && BarsCalculated(hRsiRest) > minH && BarsCalculated(hSmmaRest) > minH)
         {
            const int start = (int)MathMin(1500.0, (double)(avail - minH - 2));
            for(int s = start; s >= 1; s--) ProcessBar(s);
            m_warmed = true;
            PrintFormat("[REST] warm-up complete: resting=%s", m_resting ? "YES" : "no");
         }
         m_lastBar = t;
         return;
      }

      ProcessBar(1);
      m_lastBar = t;
   }

   //--- does the resting state block a trade in direction `dir`?
   bool Blocks(const int dir) const
   {
      if(!m_resting) return false;
      if(InpRestBlocksBothSides) return true;      // literal spec: blocks everything
      // optional narrower reading: overbought blocks longs, oversold blocks shorts
      if(m_side == +1 && dir > 0) return true;
      if(m_side == -1 && dir < 0) return true;
      return false;
   }

   bool Resting(void) const { return m_resting; }
   bool Warmed(void)  const { return m_warmed; }
};

CRestingH2 restH2;

//==================================================================
//                    POSITION MANAGEMENT
//==================================================================
struct SPosMeta
{
   ulong    ticket;
   long     zoneId;
   double   entry;
   double   initRisk;      // price distance entry -> initial SL (locked at entry)
   double   trailDist;     // price distance for the trailing stop
   double   mfe;           // peak favourable excursion, price distance
   bool     armed;         // dynamic exit armed (1:1 RR reached)
   bool     used;
};

#define MAX_TRACKED 32
SPosMeta g_meta[MAX_TRACKED];
long     g_lastTradedZone = -1;

//--- diagnostics: why did this symbol never trade?
long g_diagBars = 0, g_diagNoWarm = 0, g_diagNoZone = 0, g_diagSameZone = 0;
long g_diagNoTrend = 0, g_diagResting = 0, g_diagChop = 0, g_diagMaxPos = 0;
long g_diagNoAtr = 0, g_diagStopLvl = 0, g_diagLot = 0, g_diagMargin = 0;
long g_diagEntries = 0;

void PrintDiagnostics(void)
{
   PrintFormat("[DIAG] %s bars=%d | entries=%d | blocked: warmup=%d noZone=%d sameZone=%d "
               "noTrend=%d resting=%d chop=%d maxPos=%d atr=%d stopLvl=%d lot=%d margin=%d",
               _Symbol, (int)g_diagBars, (int)g_diagEntries, (int)g_diagNoWarm,
               (int)g_diagNoZone, (int)g_diagSameZone, (int)g_diagNoTrend,
               (int)g_diagResting, (int)g_diagChop, (int)g_diagMaxPos,
               (int)g_diagNoAtr, (int)g_diagStopLvl, (int)g_diagLot, (int)g_diagMargin);
}

void MetaInit(void)
{
   for(int i = 0; i < MAX_TRACKED; i++)
   {
      g_meta[i].used     = false;
      g_meta[i].ticket   = 0;
      g_meta[i].zoneId   = -1;
      g_meta[i].entry    = 0.0;
      g_meta[i].initRisk = 0.0;
      g_meta[i].trailDist= 0.0;
      g_meta[i].mfe      = 0.0;
      g_meta[i].armed    = false;
   }
}

int MetaFind(const ulong ticket)
{
   for(int i = 0; i < MAX_TRACKED; i++)
      if(g_meta[i].used && g_meta[i].ticket == ticket) return i;
   return -1;
}

int MetaAdd(const ulong ticket, const long zoneId, const double entry,
            const double initRisk, const double trailDist)
{
   for(int i = 0; i < MAX_TRACKED; i++)
   {
      if(!g_meta[i].used)
      {
         g_meta[i].used      = true;
         g_meta[i].ticket    = ticket;
         g_meta[i].zoneId    = zoneId;
         g_meta[i].entry     = entry;
         g_meta[i].initRisk  = initRisk;
         g_meta[i].trailDist = trailDist;
         g_meta[i].mfe       = 0.0;
         g_meta[i].armed     = false;
         return i;
      }
   }
   return -1;
}

//--- drop metadata for tickets that no longer exist
void MetaPrune(void)
{
   for(int i = 0; i < MAX_TRACKED; i++)
   {
      if(!g_meta[i].used) continue;
      if(!PositionSelectByTicket(g_meta[i].ticket))
         g_meta[i].used = false;
   }
}

//--- rebuild metadata after a restart / recompile
void MetaRebuild(void)
{
   MetaInit();
   const int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      const ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)      continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic)     continue;

      const double entry = PositionGetDouble(POSITION_PRICE_OPEN);
      const double sl    = PositionGetDouble(POSITION_SL);
      double risk = (sl > 0.0) ? MathAbs(entry - sl) : 0.0;
      if(risk <= 0.0)
      {
         const double atr = IndVal(hAtrVol, 1);
         risk = IsValid(atr) ? atr * InpSlAtrMult : 0.0;
      }
      const int idx = MetaAdd(tk, -1, entry, risk, risk);
      if(idx >= 0)
         Print("[META] rebuilt tracking for ticket ", tk);
   }
}

int CountOwnPositions(void)
{
   int n = 0;
   const int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      if(PositionGetTicket(i) == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)  continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      n++;
   }
   return n;
}

//==================================================================
//                        POSITION SIZING
//==================================================================
//--- round DOWN to the broker's volume step (never round up: that would
//    silently exceed the 1% risk mandate)
double NormalizeLot(const double lots)
{
   if(g_lotStep <= 0.0) return 0.0;

   int lotDigits = 0;
   double step = g_lotStep;
   while(lotDigits < 8 && MathAbs(step - MathRound(step)) > 1e-9)
   {
      step *= 10.0;
      lotDigits++;
   }

   double v = MathFloor(lots / g_lotStep + 1e-9) * g_lotStep;
   v = MathMax(v, g_lotMin);
   v = MathMin(v, g_lotMax);
   return NormalizeDouble(v, lotDigits);
}

//--- largest lot whose initial margin stays within InpMaxMarginUtilPct
//    of free margin. On low-volatility instruments a 1%-risk sizing with
//    a tight ATR stop demands enormous notional; without this cap the
//    deposit load runs past 100% and the account is one gap from a
//    margin call.
double MaxLotsByMargin(const ENUM_ORDER_TYPE type, const double price)
{
   if(InpMaxMarginUtilPct <= 0.0) return g_lotMax;
   if(price <= 0.0 || g_lotStep <= 0.0) return 0.0;

   double marginPerLot = 0.0;
   if(!OrderCalcMargin(type, _Symbol, 1.0, price, marginPerLot)) return g_lotMax;
   if(marginPerLot <= 0.0) return g_lotMax;

   const double budget = AccountInfoDouble(ACCOUNT_MARGIN_FREE) * InpMaxMarginUtilPct / 100.0;
   return budget / marginPerLot;
}

double CalcLots(const double slPriceDist, const ENUM_ORDER_TYPE type, const double price)
{
   double lots;

   if(InpFixedLot > 0.0)
   {
      lots = InpFixedLot;
   }
   else
   {
      if(slPriceDist <= 0.0 || g_tickSize <= 0.0 || g_tickValue <= 0.0)
         return 0.0;

      const double balance    = AccountInfoDouble(ACCOUNT_BALANCE);
      const double riskMoney  = balance * InpRiskPct / 100.0;
      const double lossPerLot = (slPriceDist / g_tickSize) * g_tickValue;
      if(lossPerLot <= 0.0) return 0.0;
      lots = riskMoney / lossPerLot;
   }

   //--- apply the margin ceiling and the optional hard cap
   const double marginCap = MaxLotsByMargin(type, price);
   if(lots > marginCap)
   {
      if(InpVerbose)
         PrintFormat("[SIZE] risk model wanted %.4f lots, margin cap allows %.4f",
                     lots, marginCap);
      lots = marginCap;
   }
   if(InpMaxLotCap > 0.0 && lots > InpMaxLotCap) lots = InpMaxLotCap;

   return NormalizeLot(lots);
}

//--- refuse the trade if free margin would not cover it
bool MarginOK(const ENUM_ORDER_TYPE type, const double lots, const double price)
{
   double need = 0.0;
   if(!OrderCalcMargin(type, _Symbol, lots, price, need)) return false;
   return (need <= AccountInfoDouble(ACCOUNT_MARGIN_FREE) * 0.95);
}

//==================================================================
//                          ENTRY LOGIC
//==================================================================
void TryEntry(void)
{
   //--- gate 1: an ACTIVE consolidation zone must exist
   if(!cde.IsActive()) { g_diagNoZone++; return; }

   //--- gate 2: only one trade per consolidation zone
   if(cde.ZoneId() == g_lastTradedZone) { g_diagSameZone++; return; }

   //--- gate 3: trend direction must be defined
   const int trend = trendH4.Dir();
   if(trend == 0) { g_diagNoTrend++; return; }

   //--- resolve direction (inverted toggle)
   const int dir = InpInverted ? -trend : trend;

   //--- gate 4: resting point
   if(restH2.Blocks(dir))
   {
      g_diagResting++;
      if(InpVerbose) Print("[ENTRY] blocked - resting point active");
      return;
   }

   //--- gate 5: M15 choppiness
   const double chop1 = ChopIndex(_Symbol, InpChopTF, InpChopLenFilter, 1);
   const double chop2 = ChopIndex(_Symbol, InpChopTF, InpChopLenFilter, 2);
   if(!IsValid(chop1) || !IsValid(chop2)) return;
   if(chop1 >= InpChopBlockLevel)
   {
      g_diagChop++;
      if(InpVerbose) PrintFormat("[ENTRY] blocked - CHOP %.2f >= %.2f", chop1, InpChopBlockLevel);
      return;
   }
   if(InpBlockChopRising && chop1 > chop2)
   {
      g_diagChop++;
      if(InpVerbose) PrintFormat("[ENTRY] blocked - CHOP rising (%.2f > %.2f)", chop1, chop2);
      return;
   }

   //--- gate 6: max concurrent positions
   if(CountOwnPositions() >= InpMaxPositions) { g_diagMaxPos++; return; }

   //--- volatility at the time the trade is made (InpVolTF ATR, closed bar)
   const double atrH1 = IndVal(hAtrVol, 1);
   if(!IsValid(atrH1) || atrH1 <= 0.0) { g_diagNoAtr++; return; }

   const double slDist = InpSlAtrMult * atrH1;
   const double tpDist = InpTpAtrMult * atrH1;

   //--- broker distance sanity
   const double minDist = (double)g_stopLevel * g_point;
   if(slDist <= minDist || tpDist <= minDist)
   {
      g_diagStopLvl++;
      if(InpVerbose) Print("[ENTRY] blocked - SL/TP inside broker stop level");
      return;
   }

   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0) return;

   const ENUM_ORDER_TYPE otype = (dir > 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   const double refPx = (dir > 0) ? ask : bid;

   const double lots = CalcLots(slDist, otype, refPx);
   if(lots < g_lotMin || lots <= 0.0)
   {
      g_diagLot++;
      if(InpVerbose) Print("[ENTRY] blocked - computed lot below minimum");
      return;
   }

   if(!MarginOK(otype, lots, refPx))
   {
      g_diagMargin++;
      if(InpVerbose) Print("[ENTRY] blocked - insufficient free margin");
      return;
   }

   double price, sl, tp;
   bool ok = false;
   const string cmt = StringFormat("FLANK_Z%d", (int)cde.ZoneId());

   if(dir > 0)
   {
      price = ask;
      sl = NormalizeDouble(price - slDist, g_digits);
      tp = NormalizeDouble(price + tpDist, g_digits);
      ok = trade.Buy(lots, _Symbol, price, sl, tp, cmt);
   }
   else
   {
      price = bid;
      sl = NormalizeDouble(price + slDist, g_digits);
      tp = NormalizeDouble(price - tpDist, g_digits);
      ok = trade.Sell(lots, _Symbol, price, sl, tp, cmt);
   }

   if(!ok)
   {
      PrintFormat("[ENTRY] order failed: retcode=%d %s",
                  trade.ResultRetcode(), trade.ResultRetcodeDescription());
      return;
   }

   const ulong tk = trade.ResultOrder();
   const double fill = (trade.ResultPrice() > 0.0) ? trade.ResultPrice() : price;

   // resolve the position ticket (for netting accounts the deal maps to a
   // position with the same id as the order)
   ulong posTicket = tk;
   if(!PositionSelectByTicket(posTicket))
   {
      // fall back: find the newest position of ours on this symbol
      const int total = PositionsTotal();
      for(int i = total - 1; i >= 0; i--)
      {
         const ulong t2 = PositionGetTicket(i);
         if(t2 == 0) continue;
         if(PositionGetString(POSITION_SYMBOL) != _Symbol)  continue;
         if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
         if(MetaFind(t2) >= 0) continue;
         posTicket = t2;
         break;
      }
   }

   MetaAdd(posTicket, cde.ZoneId(), fill, slDist, slDist);
   g_lastTradedZone = cde.ZoneId();
   g_diagEntries++;

   PrintFormat("[ENTRY] %s %.2f lots @ %.*f  SL=%.*f TP=%.*f  ATR=%.*f  zone#%d",
               (dir > 0 ? "BUY" : "SELL"), lots, g_digits, fill,
               g_digits, sl, g_digits, tp, g_digits, atrH1, (int)cde.ZoneId());
}

//==================================================================
//                    EXIT / TRADE MANAGEMENT
//==================================================================
//  Two mechanisms run together:
//    1. Trailing stop at InpSlAtrMult x ATR(InpVolTF). Distance is frozen at
//       entry by default (literal reading of the spec); set
//       InpTrailUsesLiveATR = true to recompute from current ATR.
//    2. Dynamic exit: once MFE >= initial risk (1:1 RR), close the
//       position if it gives back InpGivebackPct of peak profit.
//  A hard TP at InpTpAtrMult x ATR(InpVolTF) sits on the order itself.
//==================================================================
void ManagePositions(void)
{
   const int total = PositionsTotal();
   for(int i = total - 1; i >= 0; i--)
   {
      const ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)  continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;

      const long   type  = PositionGetInteger(POSITION_TYPE);
      const double entry = PositionGetDouble(POSITION_PRICE_OPEN);
      const double curSL = PositionGetDouble(POSITION_SL);

      int idx = MetaFind(tk);
      if(idx < 0)
      {
         const double r = (curSL > 0.0) ? MathAbs(entry - curSL) : 0.0;
         idx = MetaAdd(tk, -1, entry, r, r);
         if(idx < 0) continue;
      }

      const bool isBuy = (type == POSITION_TYPE_BUY);
      const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      if(bid <= 0.0 || ask <= 0.0) continue;

      // price at which the position would be closed right now
      const double closePx = isBuy ? bid : ask;

      // favourable excursion in price terms
      const double fav = isBuy ? (closePx - entry) : (entry - closePx);
      if(fav > g_meta[idx].mfe) g_meta[idx].mfe = fav;

      //-------- 1) dynamic exit -----------------------------------
      const double initRisk = g_meta[idx].initRisk;
      if(initRisk > 0.0)
      {
         if(!g_meta[idx].armed && g_meta[idx].mfe >= InpArmAtRR * initRisk)
         {
            g_meta[idx].armed = true;
            if(InpVerbose)
               PrintFormat("[EXIT] ticket %I64u armed at %.2fR", tk, g_meta[idx].mfe / initRisk);
         }

         if(g_meta[idx].armed && g_meta[idx].mfe > 0.0)
         {
            const double giveback = (g_meta[idx].mfe - fav) / g_meta[idx].mfe * 100.0;
            if(giveback >= InpGivebackPct)
            {
               if(trade.PositionClose(tk, InpSlippage))
                  PrintFormat("[EXIT] dynamic exit ticket %I64u  giveback=%.1f%%  peak=%.2fR",
                              tk, giveback, g_meta[idx].mfe / initRisk);
               continue;
            }
         }
      }

      //-------- 2) trailing stop ----------------------------------
      if(!InpUseTrail) continue;

      double trailDist = g_meta[idx].trailDist;
      if(InpTrailUsesLiveATR)
      {
         const double atrNow = IndVal(hAtrVol, 1);
         if(IsValid(atrNow) && atrNow > 0.0) trailDist = InpSlAtrMult * atrNow;
      }
      if(trailDist <= 0.0) continue;

      const double minDist = (double)g_stopLevel * g_point;
      double newSL;

      if(isBuy)
      {
         newSL = NormalizeDouble(bid - trailDist, g_digits);
         if(bid - newSL < minDist) continue;
         if(curSL > 0.0 && newSL <= curSL + g_point * 0.5) continue;
      }
      else
      {
         newSL = NormalizeDouble(ask + trailDist, g_digits);
         if(newSL - ask < minDist) continue;
         if(curSL > 0.0 && newSL >= curSL - g_point * 0.5) continue;
      }

      const double tp = PositionGetDouble(POSITION_TP);
      if(!trade.PositionModify(tk, newSL, tp))
      {
         if(InpVerbose)
            PrintFormat("[TRAIL] modify failed ticket %I64u retcode=%d",
                        tk, trade.ResultRetcode());
      }
   }
}

//==================================================================
//                       EVENT HANDLERS
//==================================================================
int OnInit(void)
{
   //--- validate inputs
   if(InpDetLen < 5)            { Print("InpDetLen must be >= 5");            return INIT_PARAMETERS_INCORRECT; }
   if(InpMinBars < 2)           { Print("InpMinBars must be >= 2");           return INIT_PARAMETERS_INCORRECT; }
   if(InpMaxTol < 0)            { Print("InpMaxTol must be >= 0");            return INIT_PARAMETERS_INCORRECT; }
   if(InpChopLenCde < 2)        { Print("InpChopLenCde must be >= 2");        return INIT_PARAMETERS_INCORRECT; }
   if(InpChopLenFilter < 2)     { Print("InpChopLenFilter must be >= 2");     return INIT_PARAMETERS_INCORRECT; }
   if(InpAtrSlow < 2)           { Print("InpAtrSlow must be >= 2");           return INIT_PARAMETERS_INCORRECT; }
   if(InpGivebackPct <= 0.0 || InpGivebackPct >= 100.0)
                                { Print("InpGivebackPct must be in (0,100)"); return INIT_PARAMETERS_INCORRECT; }
   if(InpRiskPct <= 0.0 && InpFixedLot <= 0.0)
                                { Print("Set InpRiskPct > 0 or InpFixedLot > 0"); return INIT_PARAMETERS_INCORRECT; }
   if(InpMaxPositions < 1)      { Print("InpMaxPositions must be >= 1");      return INIT_PARAMETERS_INCORRECT; }

   //--- symbol properties
   RefreshSymbolInfo();
   if(!g_symbolReady)
      PrintFormat("[INIT] %s: tick size/value not yet available - will retry on tick "
                  "(tickSize=%.10f tickValue=%.5f)", _Symbol, g_tickSize, g_tickValue);

   //--- indicator handles
   hAtrZone   = iATR(_Symbol, InpZoneTF,  InpAtrLen);
   hAtrFast   = iATR(_Symbol, InpZoneTF,  InpAtrFast);
   hAtrSlow   = iATR(_Symbol, InpZoneTF,  InpAtrSlow);
   hAtrVol    = iATR(_Symbol, InpVolTF,   InpAtrLen);
   hSmmaTrend = iMA (_Symbol, InpTrendTF, InpSmmaPeriod, 0, MODE_SMMA, PRICE_CLOSE);
   hSmmaRest  = iMA (_Symbol, InpRestTF,  InpSmmaPeriod, 0, MODE_SMMA, PRICE_CLOSE);
   hRsiRest   = iRSI(_Symbol, InpRestTF,  InpRsiPeriod, PRICE_CLOSE);

   if(hAtrZone == INVALID_HANDLE || hAtrFast == INVALID_HANDLE ||
      hAtrSlow == INVALID_HANDLE || hAtrVol  == INVALID_HANDLE ||
      hSmmaTrend == INVALID_HANDLE || hSmmaRest == INVALID_HANDLE ||
      hRsiRest == INVALID_HANDLE)
   {
      Print("Failed to create one or more indicator handles");
      return INIT_FAILED;
   }

   //--- trade object
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.LogLevel(LOG_LEVEL_ERRORS);

   cde.Init();
   MetaRebuild();

   Print("=== FLANK v4 initialised on ", _Symbol,
         " | zoneTF=", EnumToString(InpZoneTF),
         " trendTF=", EnumToString(InpTrendTF),
         " mode=", (InpCdeMode == CDE_FIXED ? "FIXED" : "PERCENTILE"), " ===");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   PrintDiagnostics();

   if(hAtrZone   != INVALID_HANDLE) IndicatorRelease(hAtrZone);
   if(hAtrFast   != INVALID_HANDLE) IndicatorRelease(hAtrFast);
   if(hAtrSlow   != INVALID_HANDLE) IndicatorRelease(hAtrSlow);
   if(hAtrVol    != INVALID_HANDLE) IndicatorRelease(hAtrVol);
   if(hSmmaTrend != INVALID_HANDLE) IndicatorRelease(hSmmaTrend);
   if(hSmmaRest  != INVALID_HANDLE) IndicatorRelease(hSmmaRest);
   if(hRsiRest   != INVALID_HANDLE) IndicatorRelease(hRsiRest);

   if(InpDrawZones) ObjectsDeleteAll(0, "CDE_");
}

void OnTick(void)
{
   //--- symbol properties may not have been available at init (Market Watch
   //    scan on a symbol the terminal had not yet synced). Retry here.
   if(!g_symbolReady)
   {
      RefreshSymbolInfo();
      if(!g_symbolReady) return;
      Print("[INIT] ", _Symbol, ": symbol properties now available");
   }

   //--- 1) manage open trades on every tick (dynamic exit + trailing)
   MetaPrune();
   ManagePositions();

   //--- 2) update higher-timeframe context on their own bar closes
   trendH4.Update();
   restH2.Update();

   //--- 3) update the zone engine; a new closed zone-TF bar drives entries
   if(!cde.Update()) return;
   g_diagBars++;
   if(!cde.Warmed()) { g_diagNoWarm++; return; }

   //--- 4) entry evaluation, once per closed zone-TF bar
   if(!MQLInfoInteger(MQL_TESTER) && !TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return;
   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED)) return;
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED)) return;

   TryEntry();
}
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Custom optimization criterion.                                    |
//| Returns 0 for statistically meaningless passes so that a Market   |
//| Watch scan surfaces only symbols with a usable sample.            |
//+------------------------------------------------------------------+
double OnTester(void)
{
   const double trades = TesterStatistics(STAT_TRADES);
   if(trades < 30.0) return 0.0;

   const double pf     = TesterStatistics(STAT_PROFIT_FACTOR);
   const double profit = TesterStatistics(STAT_PROFIT);
   const double dd     = TesterStatistics(STAT_EQUITY_DDREL_PERCENT);

   if(profit <= 0.0 || pf <= 1.0) return 0.0;
   if(dd <= 0.0) return profit;

   // reward profit factor, penalise drawdown, scale by sample size
   return (pf - 1.0) * MathSqrt(trades) / MathMax(dd, 1.0) * 100.0;
}
//+------------------------------------------------------------------+
