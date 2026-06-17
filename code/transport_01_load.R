# transport_01_load.R ─────────────────────────────────────────────────────────
# Self-contained data load. Reads COI + RUCA CSVs, downloads ACS via
# tidycensus, computes spatial metrics from NHS shapefiles + NTM bus stops
# (all cached after first run).
# Census API key required in ~/.Renviron: CENSUS_API_KEY=<key>
# First run: ~30-60 min.  Subsequent runs: instant (loads cache).
# Output: output/transport_df.rds

library(tidyverse)
library(sf)
library(tigris)
library(tidycensus)

REPO_ROOT     <- r"(C:\Users\bdevoe\Desktop\git\transportation)"
DATA_DIR      <- file.path(REPO_ROOT, "data")
OUTPUT_DIR    <- file.path(REPO_ROOT, "output")
HIGHWAY_SHP   <- file.path(DATA_DIR, "NTAD_National_Highway_System", "National_Highway_System_(NHS).shp")
BUS_STOPS_SHP <- file.path(DATA_DIR, "NTAD_National_Transit_Map_Stops_8953550677584268325",
                            "National_Transit_Map_Stops.shp")
NOISE_DIR     <- file.path(DATA_DIR, "conus_shp")
INFRA_CACHE     <- file.path(OUTPUT_DIR, "infra_metrics.rds")
PROJ_CRS        <- 5070
COI_LEVEL_ORDER <- c("Very Low", "Low", "Moderate", "High", "Very High")
CONUS_STATES    <- c(state.abb[!state.abb %in% c("AK", "HI")], "DC")

options(tigris_use_cache = TRUE)
dir.create(OUTPUT_DIR, showWarnings = FALSE, recursive = TRUE)

# ── 1. COI + RUCA ─────────────────────────────────────────────────────────────
message("Loading COI data...")
coi <- read_csv(file.path(DATA_DIR, "2010 census tracts, overall index and domains (COI 3.0-2023)", "data.csv"),
                col_types = cols(geoid10 = col_character(), state_usps = col_character(),
                                 .default = col_guess()), show_col_types = FALSE) |>
  rename(geoid20 = geoid10) |>
  filter(year == max(year, na.rm = TRUE), state_usps %in% CONUS_STATES) |>
  mutate(r_COI_nat  = as.numeric(r_COI_nat),
         c5_COI_nat = as.character(c5_COI_nat),
         state_fips = substr(geoid20, 1, 2))

ruca <- read_csv(file.path(DATA_DIR, "RUCA", "RUCA-codes-2020-tract.csv"),
                 col_types = cols_only(TractFIPS20 = col_character(), PrimaryRUCA = col_double()),
                 show_col_types = FALSE) |>
  rename(geoid20 = TractFIPS20) |>
  mutate(ruca_cat = case_when(
    PrimaryRUCA %in% 1:3 ~ "Metropolitan",
    PrimaryRUCA %in% 4:6 ~ "Micropolitan",
    PrimaryRUCA %in% 7:9 ~ "Small Town",
    PrimaryRUCA >= 10    ~ "Rural"
  ))

base_df <- left_join(coi, ruca |> select(geoid20, ruca_cat), by = "geoid20")
message(sprintf("  %s CONUS tracts", format(nrow(base_df), big.mark = ",")))

# ── 2. Infrastructure metrics (computed once, then cached) ────────────────────
if (file.exists(INFRA_CACHE)) {
  message("Loading cached infrastructure metrics...")
  infra <- readRDS(INFRA_CACHE)
} else {
  message("Computing infrastructure metrics (first run only — cached afterwards)...")

  message("  Downloading tract geometries via tigris (49 states)...")
  tracts_sf <- map_dfr(CONUS_STATES, \(st) tracts(state = st, year = 2020, cb = TRUE)) |>
    st_transform(PROJ_CRS) |> rename(geoid20 = GEOID) |>
    filter(geoid20 %in% base_df$geoid20)
  cent_geom <- st_centroid(st_geometry(tracts_sf))
  geoids    <- tracts_sf$geoid20

  # Bus stops per tract
  message("  Counting bus stops...")
  stops <- st_read(BUS_STOPS_SHP, quiet = TRUE) |>
    filter(stop_type == 3) |> st_transform(PROJ_CRS)
  n_bus_stops    <- lengths(st_intersects(tracts_sf, stops))
  stops_per_sqkm <- n_bus_stops / pmax(as.numeric(st_area(tracts_sf)) / 1e6, 0.01)

  # NHS highway geometry + lengths
  message("  Loading NHS highways...")
  hwy        <- st_read(HIGHWAY_SHP, quiet = TRUE) |> st_transform(PROJ_CRS)
  hwy_geom   <- st_geometry(hwy)
  hwy_len_mi <- as.numeric(st_length(hwy_geom)) / 1609.34

  # Distance to nearest NHS highway
  message("  Distance to nearest highway...")
  near_idx        <- st_nearest_feature(cent_geom, hwy_geom)
  dist_highway_km <- as.numeric(
    st_distance(cent_geom, hwy_geom[near_idx], by_element = TRUE)) / 1000

  # Vectorised buffer miles
  buf_miles <- function(lines_g, gids, cents, dist_m) {
    bufs    <- st_sf(geoid20 = gids, geometry = st_buffer(cents, dist_m))
    clipped <- tryCatch(suppressWarnings(st_intersection(st_sf(geometry = lines_g), bufs)),
                        error = function(e) NULL)
    out <- tibble(geoid20 = gids, mi = 0)
    if (!is.null(clipped) && nrow(clipped) > 0) {
      cs <- clipped |> mutate(mi = as.numeric(st_length(geometry)) / 1609.34) |>
        st_drop_geometry() |> group_by(geoid20) |> summarise(mi = sum(mi), .groups = "drop")
      out <- rows_update(out, cs, by = "geoid20", unmatched = "ignore")
    }
    out$mi
  }
  message("  Highway buffer miles (0.5 / 1 / 2 / 5 mi)...")
  hwy_mi_half <- buf_miles(hwy_geom, geoids, cent_geom,  805)
  hwy_mi_1mi  <- buf_miles(hwy_geom, geoids, cent_geom, 1609)
  hwy_mi_2mi  <- buf_miles(hwy_geom, geoids, cent_geom, 3219)
  hwy_mi_5mi  <- buf_miles(hwy_geom, geoids, cent_geom, 8047)

  # Distance-decay access score (bandwidth = 1 mi, radius = 10 mi)
  message("  Highway decay score...")
  idx_decay <- st_intersects(st_buffer(cent_geom, 16093), hwy_geom)
  hwy_decay <- map_dbl(seq_along(idx_decay), function(i) {
    idx <- idx_decay[[i]]
    if (!length(idx)) return(0)
    sum(hwy_len_mi[idx] * exp(-as.numeric(st_distance(cent_geom[i], hwy_geom[idx])) / 1609))
  })

  infra <- tibble(geoid20 = geoids, dist_highway_km, n_bus_stops, stops_per_sqkm,
                  hwy_mi_half, hwy_mi_1mi, hwy_mi_2mi, hwy_mi_5mi, hwy_decay)
  saveRDS(infra, INFRA_CACHE)
  message("  Saved: infra_metrics.rds")
}

# ── 3. ACS 2020 5-year variables ──────────────────────────────────────────────
message("Downloading ACS 2020 5-year variables (may take a few minutes)...")
acs <- get_acs(
  geography = "tract",
  variables = c(
    veh_0   = "B08201_002", veh_tot = "B08201_001",
    income  = "B19013_001", age     = "B01002_001",
    pop_tot = "B03002_001", pop_wnh = "B03002_003",
    renter  = "B25003_003", hh_occ  = "B25003_001",
    pov_tot = "B17001_001", pov_blw = "B17001_002",
    under18 = "B09001_001",
    transit = "B08301_010", commut  = "B08301_001"
  ),
  state = CONUS_STATES, year = 2020, survey = "acs5", output = "wide"
) |>
  transmute(
    geoid20             = GEOID,
    med_hh_income       = incomeE,
    median_age          = ageE,
    pct_no_vehicle      = 100 * veh_0E   / pmax(veh_totE,  1),
    pct_nonwhite        = 100 * (1 - pop_wnhE / pmax(pop_totE, 1)),
    pct_renter          = 100 * renterE  / pmax(hh_occE,   1),
    pct_poverty         = 100 * pov_blwE / pmax(pov_totE,  1),
    pct_under18         = 100 * under18E / pmax(pop_totE,  1),
    pct_transit_commute = 100 * transitE / pmax(commutE,   1)
  )

# ── 4. Noise data (DOT tract-level noise exposure) ───────────────────────────
message("Loading noise data...")
noise_files <- list.files(NOISE_DIR, pattern = "\\.shp$", full.names = TRUE)
noise <- bind_rows(lapply(noise_files, function(f) {
  sf::st_read(f, quiet = TRUE) |> sf::st_drop_geometry()
})) |>
  mutate(
    across(c(estimat, ns4050n, ns5060n, ns6070n, ns7080n, ns8090n, nois90n), as.numeric),
    wt_noise_sum     = (ns4050n * 45) + (ns5060n * 55) + (ns6070n * 65) +
                       (ns7080n * 75) + (ns8090n * 85) + (nois90n * 95),
    mean_noise_db    = if_else(estimat > 0, wt_noise_sum / estimat, NA_real_),
    pct_exposed_60db = ((ns6070n + ns7080n + ns8090n + nois90n) /
                        if_else(estimat > 0, estimat, NA_real_)) * 100,
    geoid20          = str_pad(str_trim(GEOID), 11, pad = "0")
  ) |>
  select(geoid20, mean_noise_db, pct_exposed_60db)
noise_match <- sum(base_df$geoid20 %in% noise$geoid20)
message(sprintf("  Noise match rate: %d / %d tracts (%.1f%%)",
                noise_match, nrow(base_df), 100 * noise_match / nrow(base_df)))

# ── 5. Merge and save ─────────────────────────────────────────────────────────
transport_df <- base_df |>
  left_join(infra,  by = "geoid20") |>
  left_join(acs,    by = "geoid20") |>
  left_join(noise,  by = "geoid20") |>
  mutate(
    coi_score  = as.numeric(r_COI_nat),
    coi_level  = factor(c5_COI_nat, levels = COI_LEVEL_ORDER),
    ruca_cat   = factor(ruca_cat, levels = c("Metropolitan","Micropolitan","Small Town","Rural")),
    log_income = log(pmax(med_hh_income, 1))
  ) |>
  filter(!is.na(coi_score), !is.na(dist_highway_km), !is.na(n_bus_stops),
         !is.na(pct_no_vehicle), !is.na(med_hh_income), !is.na(median_age),
         !is.na(ruca_cat), !is.na(state_fips))

message(sprintf("Transport dataset: %s CONUS tracts", format(nrow(transport_df), big.mark = ",")))
saveRDS(transport_df, file.path(OUTPUT_DIR, "transport_df.rds"))
message("Saved: ", file.path(OUTPUT_DIR, "transport_df.rds"))
