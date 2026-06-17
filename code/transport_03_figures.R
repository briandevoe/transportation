# transport_03_figures.R ──────────────────────────────────────────────────────
# Figures: infrastructure profile, buffer curve, COI vs highway distance,
# no-vehicle sign flip, all-tracts scatter, noise scatter.
# Input:   transport_df.rds, transport_summary.csv, transport_buffer_curve.csv,
#          transport_regression_ruca.csv  (OUTPUT_DIR)
# Outputs: transport_fig1_profile.png  transport_fig2_buffer_curve.png
#          transport_fig3_coi_hwy.png  transport_fig4_noveh_ruca.png
#          transport_fig5_coi_hwy_all.png  transport_fig6_noise.png

library(tidyverse)
library(here)

OUTPUT_DIR       <- here("output")
COI_LEVEL_ORDER  <- c("Very Low", "Low", "Moderate", "High", "Very High")
COI_LEVEL_COLORS <- c("Very Low"="#d73027","Low"="#fc8d59","Moderate"="#ffffbf",
                       "High"="#91cf60","Very High"="#1a9850")

df       <- readRDS(file.path(OUTPUT_DIR, "transport_df.rds"))
summ     <- read_csv(file.path(OUTPUT_DIR, "transport_summary.csv"),         show_col_types = FALSE)
buf_curv <- read_csv(file.path(OUTPUT_DIR, "transport_buffer_curve.csv"),    show_col_types = FALSE)
ruca_reg <- read_csv(file.path(OUTPUT_DIR, "transport_regression_ruca.csv"), show_col_types = FALSE)

# shared helpers
theme_coi <- function(base_size = 13, ...) {
  theme_minimal(base_size = base_size) +
    theme(plot.title       = element_text(face = "bold"),
          strip.text       = element_text(face = "bold"),
          panel.grid.minor = element_blank(),
          plot.background  = element_rect(fill = "white", color = NA),
          panel.background = element_rect(fill = "white", color = NA), ...)
}
save_fig <- function(p, name, w, h) {
  ggsave(file.path(OUTPUT_DIR, name), p, width = w, height = h, dpi = 200, bg = "white")
  message("Saved: ", name)
}

loess_sample <- function(data, n, seed) {
  set.seed(seed)
  data |>
    filter(!is.na(coi_score), !is.na(coi_level)) |>
    mutate(coi_level = factor(coi_level, levels = COI_LEVEL_ORDER)) |>
    slice_sample(n = n)
}

# ── Fig 1: Infrastructure profile by COI quintile ────────────────────────────
p1 <- summ |>
  select(coi_level,
         `Bus Stops\n(per tract)` = bus_stops,
         `Hwy Distance\n(km)`     = dist_hwy_km,
         `Hwy Miles\n@ 1mi buf`   = hwy_mi_1mi,
         `Hwy Miles\n@ 5mi buf`   = hwy_mi_5mi,
         `% No Vehicle`           = pct_no_vehicle,
         `Mean Noise\n(dB)`       = mean_noise_db) |>
  pivot_longer(-coi_level) |>
  mutate(coi_level = factor(coi_level, levels = COI_LEVEL_ORDER)) |>
  ggplot(aes(x = coi_level, y = value, fill = coi_level)) +
  geom_col(width = 0.7) +
  facet_wrap(~name, scales = "free_y", ncol = 3, nrow = 2) +
  scale_fill_manual(values = COI_LEVEL_COLORS, guide = "none") +
  scale_y_continuous(expand = expansion(mult = c(0, 0.15))) +
  labs(title    = "Transportation Access by Child Opportunity Index Quintile",
       subtitle = "NHS highways · NTM bus stops · ACS vehicle availability · All CONUS tracts",
       x = NULL, y = NULL) +
  theme_coi(base_size = 11, axis.text.x = element_text(angle = 30, hjust = 1, size = 8),
            panel.grid.major.x = element_blank())
save_fig(p1, "transport_fig1_profile.png", 11, 6)

# ── Fig 2: Highway buffer curve ───────────────────────────────────────────────
p2 <- buf_curv |>
  mutate(coi_level = factor(coi_level, levels = COI_LEVEL_ORDER)) |>
  ggplot(aes(x = buffer_mi, y = mean_miles, colour = coi_level, group = coi_level)) +
  geom_line(linewidth = 1.1) + geom_point(size = 2.5) +
  scale_colour_manual(name = "COI Quintile", values = COI_LEVEL_COLORS) +
  scale_x_continuous(breaks = c(0.5, 1, 2, 5)) +
  labs(title    = "NHS Highway Miles Within Buffer by Opportunity Level",
       subtitle = "U-shaped pattern: Very Low and Very High tracts have more highway access than middle quintiles",
       x = "Buffer Radius (miles)", y = "Mean NHS Highway Miles") +
  theme_coi(legend.position = "right")
save_fig(p2, "transport_fig2_buffer_curve.png", 9, 5)

# ── Fig 3: COI vs NHS distance by RUCA (non-linear, faceted) ─────────────────
samp3 <- df |>
  filter(!is.na(dist_highway_km), !is.na(ruca_cat),
         dist_highway_km <= quantile(dist_highway_km, 0.99, na.rm = TRUE)) |>
  loess_sample(20000, seed = 1)

p3 <- ggplot(samp3, aes(x = dist_highway_km, y = coi_score)) +
  geom_point(alpha = 0.06, size = 0.4, colour = "grey40") +
  geom_smooth(method = "loess", span = 0.5, se = TRUE,
              colour = "#d73027", fill = "#d73027", alpha = 0.15, linewidth = 1) +
  facet_wrap(~ruca_cat, scales = "free_x") +
  labs(title    = "COI National Percentile vs Distance to Nearest NHS Highway",
       subtitle = "LOESS smoother — relationship is non-linear and direction reverses by urbanicity",
       x = "Distance to Nearest NHS Highway (km)", y = "COI National Percentile (0–100)") +
  theme_coi()
save_fig(p3, "transport_fig3_coi_hwy.png", 12, 7)

# ── Fig 4: % No-vehicle coefficient by RUCA (sign flip) ──────────────────────
p4 <- ruca_reg |>
  filter(term == "pct_no_vehicle") |>
  mutate(ruca_cat = factor(ruca_cat, levels = c("Metropolitan","Micropolitan","Small Town","Rural")),
         sig      = ifelse(p.value < 0.05, "p < 0.05", "n.s.")) |>
  ggplot(aes(x = ruca_cat, y = estimate, fill = sig)) +
  geom_col(width = 0.6) +
  geom_errorbar(aes(ymin = conf.low, ymax = conf.high), width = 0.25) +
  geom_hline(yintercept = 0, linetype = "dashed", colour = "grey30") +
  scale_fill_manual(values = c("p < 0.05" = "#2166ac", "n.s." = "#aaaaaa"), name = NULL) +
  labs(title    = "Effect of % No-Vehicle Households on COI Score by Urbanicity",
       subtitle = "Metro: car-free = transit-rich → higher COI\nRural: car-free = mobility hardship → lower COI",
       x = NULL, y = "Coefficient (COI percentile points per 1 pp change)") +
  theme_coi(legend.position = "bottom")
save_fig(p4, "transport_fig4_noveh_ruca.png", 8, 5)

# ── Fig 5 & 6 share the same scatter-LOESS layout ────────────────────────────
scatter_loess <- function(samp, x_var, x_lab, title, subtitle) {
  ggplot(samp, aes(x = .data[[x_var]], y = coi_score, colour = coi_level)) +
    geom_point(alpha = 0.10, size = 0.5) +
    geom_smooth(aes(group = 1), method = "loess", span = 0.4, se = TRUE,
                colour = "black", fill = "grey60", alpha = 0.2, linewidth = 1.1) +
    scale_colour_manual(name = "COI Quintile", values = COI_LEVEL_COLORS,
                        guide = guide_legend(override.aes = list(alpha = 0.8, size = 2))) +
    labs(title = title, subtitle = subtitle,
         x = x_lab, y = "COI National Percentile (0–100)") +
    theme_coi(legend.position = "right")
}

# Fig 5: all tracts, NHS distance
samp5 <- df |>
  filter(!is.na(dist_highway_km),
         dist_highway_km <= quantile(dist_highway_km, 0.99, na.rm = TRUE)) |>
  loess_sample(20000, seed = 2)

p5 <- scatter_loess(samp5, "dist_highway_km",
  "Distance to Nearest NHS Highway (km)",
  "COI National Percentile vs Distance to Nearest NHS Highway",
  "All CONUS tracts · LOESS smoother (black) · coloured by COI quintile")
save_fig(p5, "transport_fig5_coi_hwy_all.png", 10, 6)

# Fig 6: all tracts, noise exposure
samp6 <- df |>
  filter(!is.na(mean_noise_db)) |>
  loess_sample(20000, seed = 3)

p6 <- scatter_loess(samp6, "mean_noise_db",
  "Mean Noise Exposure (dB, population-weighted)",
  "COI National Percentile vs Transportation Noise Exposure",
  "All CONUS tracts · LOESS smoother · coloured by COI quintile\nNoise = population-weighted mean dB from DOT tract-level noise model")
save_fig(p6, "transport_fig6_noise.png", 10, 6)

message("\n6 figures saved to: ", OUTPUT_DIR)
