# Transportation Equity Analysis

This project examines how transportation infrastructure — highway proximity, transit access, and noise exposure — relates to the Child Opportunity Index (COI) across all U.S. census tracts. The central question is whether children in low-opportunity neighborhoods face systematically different transportation environments, and how those relationships shift across the rural–urban spectrum.

---

## Repository Structure

```
transportation/
├── code/
│   ├── run_all.R                  # Pipeline orchestrator
│   ├── transport_01_load.R        # Data loading & spatial metrics
│   ├── transport_02_analysis.R    # Regression models & summaries
│   └── transport_03_figures.R     # Publication figures
├── data/
│   ├── 2010 census tracts .../    # COI 3.0 (2023 release)
│   ├── RUCA/                      # Rural-urban classification codes
│   ├── NTAD_National_Highway_System/   # NHS shapefile
│   ├── NTAD_National_Transit_Map_*/    # Bus stops & routes
│   ├── NTAD_North_American_Rail_*/     # Rail network
│   └── conus_shp/                 # DOT noise model (state-level shapefiles)
├── output/                        # Figures, CSVs, cached RDS files
├── papers/                        # Reference literature
├── COI.qgz                        # QGIS project file
└── Transportation_Analysis_Full_Summary.txt   # Detailed methods & results
```

---

## Data Sources

| Source | Description |
|--------|-------------|
| **COI 3.0 (2023)** | Child Opportunity Index scores (0–100 percentile) and quintile assignments for every 2010 census tract |
| **ACS 2020 5-Year** | Census demographic variables (income, poverty, vehicle access, transit commuting, age) via `tidycensus` |
| **RUCA 2020** | Rural-Urban Commuting Area codes for urbanicity stratification (4 categories: Metropolitan, Micropolitan, Small Town, Rural) |
| **NTAD NHS** | National Highway System shapefile (interstates + major US routes) |
| **NTAD Transit** | National Transit Map stops and routes (all modes) |
| **DOT Noise Model** | Population-weighted transportation noise exposure (dB), state-level shapefiles for all 48 CONUS states |

**Census API key required:** set `CENSUS_API_KEY=<your_key>` in `~/.Renviron` before running.

---

## Pipeline

Run the full analysis with:

```r
source("code/run_all.R")
```

First run takes **45–90 minutes** (spatial computations + ACS download). Subsequent runs take ~5 minutes (cached objects in `output/`).

### Step 1: `transport_01_load.R` — Data Loading & Spatial Metrics

Loads all inputs and computes five spatial infrastructure metrics per census tract (CRS: EPSG:5070 NAD83 Conus Albers):

- **`dist_highway_km`** — distance to nearest NHS highway centroid
- **`n_bus_stops`** — bus stop count within tract boundary
- **`stop_density`** — bus stops per km²
- **`hwy_mi_Xmi`** — highway miles within 0.5, 1, 2, and 5-mile buffers
- **`hwy_decay`** — distance-decay access score (inverse-distance weighted)

Spatial metrics are cached in `output/infra_metrics.rds`. Final merged dataset (82,315 tracts) is saved to `output/transport_df.rds`.

### Step 2: `transport_02_analysis.R` — Analysis

Produces:
- Descriptive statistics by COI quintile
- Highway buffer curves (miles of NHS within each buffer radius by quintile)
- Three OLS regression specifications:
  - **M1:** No fixed effects
  - **M2:** RUCA urbanicity fixed effects (4 categories)
  - **M3:** RUCA + state fixed effects (49 entities)
- RUCA-stratified regressions (M1 run separately within each urbanicity class)

### Step 3: `transport_03_figures.R` — Figures

Generates six publication-quality PNG figures (200 dpi) in `output/`:

| Figure | Description |
|--------|-------------|
| `transport_fig1_profile.png` | 6-panel infrastructure profile by COI quintile |
| `transport_fig2_buffer_curve.png` | Highway miles within 0.5–5 mi buffers by quintile |
| `transport_fig3_coi_hwy.png` | COI vs NHS distance, LOESS by RUCA category (4 panels) |
| `transport_fig4_noveh_ruca.png` | % No-vehicle coefficient by RUCA (bar + 95% CI) |
| `transport_fig5_coi_hwy_all.png` | COI vs NHS distance, all tracts colored by quintile |
| `transport_fig6_noise.png` | COI vs noise exposure, all tracts colored by quintile |

---

## Key Findings

### The Proximity Paradox

The dominant predictor of COI is distance to the nearest NHS highway, but the direction reverses depending on spatial scale:

- **Distance to highway (log km):** β = −4.79*** — farther tracts have lower COI (in aggregate)
- **Highway miles within 1-mile buffer:** β = −0.31*** — immediate adjacency is harmful
- **Highway miles within 5-mile buffer:** β = +0.024*** — broader access is beneficial

This reflects two competing forces: highway adjacency concentrates noise, pollution, and displacement; but regional highway access enables economic opportunity. Low-opportunity tracts suffer the worst of both — closer proximity to roads while receiving less of the economic benefit.

### Noise is Independent of Proximity

Mean transportation noise (dB) carries an independent negative relationship with COI (β = −0.022***) even after controlling for highway distance. Very Low opportunity tracts average 6+ dB more noise than all other quintiles — a meaningful burden given the logarithmic scale of decibels. This suggests noise is not simply a proxy for proximity; it reflects structural siting patterns that expose low-opportunity communities to disproportionate acoustic burden.

### The Urban–Rural Sign Flip

The direction of the highway distance relationship reverses completely across the rural–urban spectrum:

| RUCA Category | NHS Distance β | Interpretation |
|---------------|---------------|----------------|
| Metropolitan (n ≈ 42,000) | −4.98*** | Farther from highway = lower opportunity |
| Micropolitan | −2.1*** | Same direction, attenuated |
| Small Town | ~0 | Null / ambiguous |
| Rural (n ≈ 8,000) | +0.79* | **Farther from highway = higher opportunity** |

In rural areas, being distant from an interstate highway is associated with *higher* COI — likely because the most economically distressed rural communities sit along highway corridors, while more prosperous rural tracts are interior farming or recreational communities.

The same reversal holds for vehicle access:

- **Metro:** % No-vehicle β = +0.099*** — low car ownership reflects transit-rich environments
- **Rural:** % No-vehicle β = −0.123*** — low car ownership reflects mobility hardship

### Descriptive Patterns by Quintile

| COI Quintile | Median Income | Dist to NHS (km) | Bus Stops | % No Vehicle | Mean Noise (dB) |
|-------------|--------------|-----------------|-----------|-------------|----------------|
| Very High | $113,000 | ~2.5× closer | 7.66 | low | low |
| Very Low | $37,800 | farther | 6.20 | 15.6% | 20.4 |

Note: Very Low tracts have *fewer* bus stops than Very High tracts despite higher transit dependence — a direct measure of service inequity.

### Model Performance

All three specifications explain roughly 78% of COI variance (R² = 0.775–0.788). Adding state fixed effects (M3) yields minimal improvement over RUCA-only fixed effects (M2), indicating that urbanicity — not geography — is the primary moderator of the infrastructure–opportunity relationship.

---

## Known Limitations

- **NHS specificity:** Analysis covers only National Highway System roads. Local arterials and secondary roads are excluded.
- **Bus stop count as transit proxy:** Stop counts do not capture service frequency, hours of operation, or network connectivity.
- **Noise model vintage:** DOT noise data predate recent traffic pattern changes; exact vintage varies by state.
- **Causality:** All associations are cross-sectional. The direction of effect (does poor infrastructure cause low opportunity, or do low-opportunity areas receive poor infrastructure?) cannot be determined from this design.
- **2010 tract boundaries:** COI 3.0 uses 2010 census tracts; some spatial misalignment with 2020 infrastructure data exists in rapidly-developing areas.

---

## R Dependencies

```r
install.packages(c(
  "tidyverse", "sf", "tigris", "tidycensus",
  "broom", "ggplot2", "scales", "data.table",
  "here", "tmap"
))
```

---

## Output Files

| File | Contents |
|------|----------|
| `output/transport_df.rds` | Master dataset (82,315 tracts, all merged variables) |
| `output/infra_metrics.rds` | Cached spatial metrics |
| `output/transport_summary.csv` | Descriptive statistics by COI quintile |
| `output/transport_buffer_curve.csv` | Buffer analysis by radius and quintile |
| `output/transport_regression.csv` | M1/M2/M3 regression coefficients |
| `output/transport_regression_ruca.csv` | RUCA-stratified coefficients |

Full methods, variable definitions, and result tables are documented in `Transportation_Analysis_Full_Summary.txt`.
