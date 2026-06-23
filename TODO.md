# Transportation Opportunity Index — TODO

## Decisions

- [ ] Resolve sign-flip problem: RUCA-stratified index vs. metropolitan-only scope
- [ ] Finalize variable set and feature engineering choices (buffer sizes, log transforms, decay functions)
- [ ] Finalize expert weights (Method 2) with Emilie
- [ ] Confirm index name ("TOI" is working name)

## Analysis & Code

### Phase 1 — Tract Level (current)

- [ ] Write R script to construct all four index variants at tract level
- [ ] Run validation: quintile cross-tabs vs. COI, validity map
- [ ] Identify and acquire external validation outcome (e.g., child health data) if feasible
- [ ] Generate output files: tract-level scores, comparison table, figures

### Phase 2 — Block Level (after tract-level index is finalized)

- [ ] Recompute spatial metrics (highway distance, buffer miles, noise, bus stops) at census block level
- [ ] Apply finalized weighting method from Phase 1 to block-level variables
- [ ] Aggregate block-level scores up to tract level and validate against Phase 1 tract scores
- [ ] Generate block-level output files and maps

## Presentation

- [ ] Build PowerPoint slide deck (~8 slides)
- [ ] Schedule meeting with Dolores, Clemens, and Nancy

## Write-Up

- [ ] Draft methods section describing index construction
- [ ] Draft limitations (cross-sectional, NHS highways only, sign-flip tradeoffs)
