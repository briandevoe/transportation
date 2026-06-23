# Transportation Opportunity Index — Construction Plan

**Project:** Transportation Infrastructure & Child Opportunity Index  
**Authors:** Brian DeVoe, Emilie Cahill  
**Date:** June 2026

---

## Overview

Having completed the descriptive and regression analysis of transportation infrastructure vs. COI across all U.S. census tracts, the next phase is constructing a tract-level **Transportation Opportunity Index (TOI)** — a single composite score integrating highway access/burden, transit access, and noise exposure.

Four weighting approaches will be constructed and compared; the best-performing method will be selected for the final index.

---

## Variable Set (5 inputs)

| Variable | Direction |
|---|---|
| `log1p(dist_highway_km)` | Mixed — see Sign-Flip below |
| `hwy_mi_1mi` | − (immediate burden) |
| `hwy_mi_5mi` | + (regional access; universally positive across RUCA groups) |
| `log1p(n_bus_stops)` | + (transit access) |
| `mean_noise_db` | − (acoustic burden) |

`pct_no_vehicle` and `pct_exposed_60db` are excluded from the primary index (sign-flip and suppressor issues, respectively) but included in sensitivity analyses.

All variables are z-scored before weighting. Variables where higher = worse are negated so that high TOI scores consistently indicate better transportation opportunity.

---

## The Sign-Flip Problem

Two variables reverse their relationship with COI depending on urbanicity:

- **`log(dist_highway_km)`** — closer to highway improves COI in metropolitan tracts but is neutral-to-negative in rural tracts
- **`pct_no_vehicle`** — car-free correlates with transit access in cities but with hardship in rural areas

**Proposed resolution:** construct the index separately for Metropolitan and non-Metropolitan tracts using RUCA-stratified directionality rules, then merge. An alternative is to scope the index to metropolitan tracts only. **This decision must be made before any index code is written.**

---

## Four Weighting Methods

1. **Equal weighting** — simple mean of direction-corrected z-scores
2. **Expert weighting** — substantive weights assigned by the research team (to be finalized with Emilie), following COI methodology
3. **Regression-based weighting** — weights proportional to standardized OLS coefficients from RUCA-stratified models
4. **PCA weighting** — first principal component loadings from PCA on the normalized variable matrix

---

## Open Questions

- [ ] RUCA-stratified index vs. metropolitan-only scope — decide before coding
- [ ] Finalize expert weights (Method 2) with Emilie
- [ ] Confirm index name "TOI"
