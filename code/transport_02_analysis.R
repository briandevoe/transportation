# transport_02_analysis.R ─────────────────────────────────────────────────────
# Summary statistics and regressions: highway + bus access vs COI.
# Input:   transport_df.rds  (OUTPUT_DIR)
# Outputs: transport_summary.csv, transport_buffer_curve.csv,
#          transport_regression.csv, transport_regression_ruca.csv

library(tidyverse)
library(broom)

OUTPUT_DIR <- r"(C:\Users\bdevoe\Desktop\git\transportation\output)"

df <- readRDS(file.path(OUTPUT_DIR, "transport_df.rds"))

# ── 1. Summary by COI quintile ────────────────────────────────────────────────
summ <- df |>
  group_by(coi_level) |>
  summarise(
    n                = n(),
    bus_stops        = round(mean(n_bus_stops,     na.rm = TRUE), 2),
    stop_density     = round(mean(stops_per_sqkm,  na.rm = TRUE), 3),
    dist_hwy_km      = round(mean(dist_highway_km, na.rm = TRUE), 2),
    hwy_mi_1mi       = round(mean(hwy_mi_1mi,      na.rm = TRUE), 3),
    hwy_mi_5mi       = round(mean(hwy_mi_5mi,      na.rm = TRUE), 2),
    hwy_decay        = round(mean(hwy_decay,        na.rm = TRUE), 3),
    pct_no_vehicle   = round(mean(pct_no_vehicle,   na.rm = TRUE), 1),
    mean_noise_db    = round(mean(mean_noise_db,    na.rm = TRUE), 2),
    pct_exposed_60db = round(mean(pct_exposed_60db, na.rm = TRUE), 1),
    med_income_k     = round(median(med_hh_income,  na.rm = TRUE) / 1000, 1),
    .groups = "drop"
  )
write_csv(summ, file.path(OUTPUT_DIR, "transport_summary.csv"))
print(as.data.frame(summ))

# ── 2. Highway buffer curve ───────────────────────────────────────────────────
buf_curve <- df |>
  filter(!is.na(coi_level)) |>
  group_by(coi_level) |>
  summarise(
    `0.5` = mean(hwy_mi_half, na.rm = TRUE),
    `1`   = mean(hwy_mi_1mi,  na.rm = TRUE),
    `2`   = mean(hwy_mi_2mi,  na.rm = TRUE),
    `5`   = mean(hwy_mi_5mi,  na.rm = TRUE),
    .groups = "drop"
  ) |>
  pivot_longer(-coi_level, names_to = "buffer_mi", values_to = "mean_miles") |>
  mutate(buffer_mi = as.numeric(buffer_mi))
write_csv(buf_curve, file.path(OUTPUT_DIR, "transport_buffer_curve.csv"))

# ── 3. Regressions (M1 no FE, M2 RUCA FE, M3 RUCA + state FE) ───────────────
fm <- coi_score ~
  log1p(n_bus_stops) + log1p(dist_highway_km) + hwy_mi_1mi + hwy_mi_5mi + hwy_decay +
  pct_no_vehicle + mean_noise_db + pct_exposed_60db +
  log_income + pct_nonwhite + pct_renter + pct_under18 + pct_poverty +
  pct_transit_commute + median_age

m1 <- lm(fm, data = df)
m2 <- lm(update(fm, . ~ . + factor(ruca_cat)),                        data = df)
m3 <- lm(update(fm, . ~ . + factor(ruca_cat) + factor(state_fips)),   data = df)

cat(sprintf("M1 R²=%.3f | M2 R²=%.3f | M3 R²=%.3f\n",
            summary(m1)$r.squared, summary(m2)$r.squared, summary(m3)$r.squared))

key_terms <- c("log1p(n_bus_stops)", "log1p(dist_highway_km)",
               "hwy_mi_1mi", "hwy_mi_5mi", "hwy_decay",
               "pct_no_vehicle", "mean_noise_db", "pct_exposed_60db")

reg_tbl <- bind_rows(
  tidy(m1, conf.int = TRUE) |> mutate(model = "M1"),
  tidy(m2, conf.int = TRUE) |> mutate(model = "M2_RUCA"),
  tidy(m3, conf.int = TRUE) |> mutate(model = "M3_RUCA_state")
) |>
  filter(term %in% key_terms) |>
  mutate(across(where(is.numeric), \(x) round(x, 5)))

write_csv(reg_tbl, file.path(OUTPUT_DIR, "transport_regression.csv"))
print(as.data.frame(reg_tbl |> select(model, term, estimate, p.value)))

# ── 4. RUCA-stratified M1 ────────────────────────────────────────────────────
ruca_reg <- df |>
  filter(!is.na(ruca_cat)) |>
  group_by(ruca_cat) |>
  group_map(\(d, g) {
    m <- tryCatch(lm(fm, data = d), error = function(e) NULL)
    if (is.null(m)) return(NULL)
    tidy(m, conf.int = TRUE) |>
      filter(term %in% key_terms) |>
      mutate(ruca_cat = g$ruca_cat, n = nrow(d),
             r2 = round(summary(m)$r.squared, 4),
             across(where(is.numeric), \(x) round(x, 5)))
  }, .keep = TRUE) |>
  bind_rows()

write_csv(ruca_reg, file.path(OUTPUT_DIR, "transport_regression_ruca.csv"))
print(as.data.frame(ruca_reg |> select(ruca_cat, term, estimate, p.value, r2)))

message("\nOutputs saved to: ", OUTPUT_DIR)
