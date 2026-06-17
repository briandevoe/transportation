#### COI DATA MERGE ####

## Load Packages
packages <- c(
  "tidyverse",
  "sf",
  "data.table",
  "tigris",
  "tmap",
  "here"
)
installed <- rownames(installed.packages())
to_install <- packages[!packages %in% installed]
if (length(to_install)) {
  message("Installing missing packages: ", paste(to_install, collapse = ", "))
  install.packages(to_install, repos = "https://cloud.r-project.org")
}
invisible(lapply(packages, library, character.only = TRUE))

options(tigris_use_cache = TRUE)
sf_use_s2(TRUE) 
tmap_mode("plot")

## Load Data 
COI_CSV     <- here("data", "2010 census tracts, overall index and domains (COI 3.0-2023)", "data.csv")
NOISE_DIR   <- here("data", "conus_shp")
HIGHWAY_SHP <- here("data", "NTAD_National_Highway_System", "National_Highway_System_(NHS).shp")
BUS_SHP     <- here("data", "NTAD_National_Transit_Map_Routes", "National_Transit_Map_Routes.shp")
RAIL_SHP    <- here("data", "NTAD_North_American_Rail_Network_Lines_6760165070091449209", "North_American_Rail_Network_Lines.shp")
OUTPUT_DIR  <- here("output")
dir.create(OUTPUT_DIR, showWarnings = FALSE, recursive = TRUE)

## Load COI Data
coi_raw <- read_csv(COI_CSV, col_types = cols(.default = "c"), show_col_types = FALSE)

coi_clean <- coi_raw %>%
  
  mutate(GEOID = str_pad(str_trim(geoid10), 11, pad = "0")) %>%
  
  select(GEOID, year, r_COI_nat, c5_COI_nat) %>%
  
  mutate(year = as.integer(year)) %>%
  group_by(GEOID) %>%
  slice_max(year, n = 1, with_ties = FALSE) %>%
  ungroup()

# Standard 50-State Based on CONUS shapefile
state_fips <- c(
  "01","04","05","06","08","09","10","11","12","13","16","17","18",
  "19","20","21","22","23","24","25","26","27","28","29","30","31","32","33",
  "34","35","36","37","38","39","40","41","42","44","45","46","47","48","49",
  "50","51","53","54","55","56"
)

# Download all states safely via loop
tracts_list <- lapply(state_fips, function(s) {
  tracts(state = s, cb = TRUE, year = 2010, progress_bar = FALSE)
})
tracts_raw <- bind_rows(tracts_list)

# Find FIPS ID Name across data sources
spatial_id_col <- intersect(c("GEOID10", "GEOID", "TRACTCE10", "GEO_ID"), names(tracts_raw))[1]


tracts_clean <- tracts_raw %>%
  mutate(
    
    raw_val = str_trim(as.character(.data[[spatial_id_col]])),
    GEOID = if_else(
      nchar(raw_val) > 11,
      str_sub(raw_val, -11), 
      str_pad(raw_val, 11, pad = "0") 
    )
  ) %>%
  select(GEOID, geometry)

# Run the relational join 
joined_dataset <- tracts_clean %>% left_join(coi_clean, by = "GEOID")

# Join quality 
total_shapes   <- nrow(tracts_clean)
matched_shapes <- sum(!is.na(joined_dataset$r_COI_nat))
join_rate      <- (matched_shapes / total_shapes) * 100

### Join Noise data

noise_files <- list.files(NOISE_DIR, pattern = "\\.shp$", full.names = TRUE)
if (length(noise_files) == 0) {
  stop(" No .shp files found inside NOISE_DIR")
}

# Bind together
noise_raw <- bind_rows(lapply(noise_files, function(f) st_read(f, quiet = TRUE)))

## Calculate Statistics

noise_summary <- noise_raw %>%
  st_drop_geometry() %>% 
  mutate(
    across(c(estimat, ns4050n, ns5060n, ns6070n, ns7080n, ns8090n, nois90n), as.numeric),
    
    # Calc weighted decibel sum based on midpoints
    wt_noise_sum  = (ns4050n * 45) + (ns5060n * 55) + (ns6070n * 65) +
      (ns7080n * 75) + (ns8090n * 85) + (nois90n * 95),
    
    # Calc final indices
    mean_noise_db = if_else(estimat > 0, wt_noise_sum / estimat, NA_real_),
    pct_exposed_60db = ((ns6070n + ns7080n + ns8090n + nois90n) / if_else(estimat > 0, estimat, NA_real_)) * 100
  ) %>%
  # Normalize GEOID text 
  mutate(GEOID = str_pad(str_trim(GEOID), 11, pad = "0")) %>%
  select(GEOID, mean_noise_db, pct_exposed_60db)

# Join Noise Metrics to Master Dataset 
joined_dataset <- joined_dataset %>% left_join(noise_summary, by = "GEOID")

# Verify Noise Data Coverage
total_tracts <- nrow(joined_dataset)
tracts_with_noise <- sum(!is.na(joined_dataset$mean_noise_db))
noise_coverage <- (tracts_with_noise / total_tracts) * 100

total_tracts
tracts_with_noise
noise_coverage

# Load/Project Transportation Data 

# Define the Target CRS
PROJ_CRS <- 5070

joined_dataset_proj <- st_transform(joined_dataset, PROJ_CRS)

# Load/Project Infrastructure 
highways_sf <- st_read(HIGHWAY_SHP, quiet = TRUE) %>% 
  st_transform(PROJ_CRS) %>% 
  st_make_valid()

bus_sf <- st_read(BUS_SHP, quiet = TRUE) %>% 
  st_transform(PROJ_CRS) %>% 
  st_make_valid()

rail_sf <- st_read(RAIL_SHP, quiet = TRUE) %>% 
  st_transform(PROJ_CRS) %>% 
  st_make_valid()

# Clean and Filter the Rail Network
if ("COUNTRY" %in% names(rail_sf)) {
  rail_sf <- filter(rail_sf, COUNTRY == "US")
} else if ("STATEAB" %in% names(rail_sf)) {
  rail_sf <- filter(rail_sf, STATEAB %in% c(state.abb, "DC"))
}


# Create centroids for census tracts
tract_centroids <- st_centroid(joined_dataset_proj)

# Define target buffer zones for matrix
BUFFER_DISTANCES <- c(0, 100, 250, 500, 750, 1000)

# Convert string categories into 3 large equity bins
opp_3class <- function(coi_level_string) {
  case_when(
    coi_level_string %in% c("Very Low", "Low") ~ "Low",
    coi_level_string == "Moderate"              ~ "Moderate",
    coi_level_string %in% c("High", "Very High") ~ "High",
    TRUE                                         ~ NA_character_
  )
}

# Create calculation Loop 
calculate_proximity_matrix <- function(infrastructure_sf, infrastructure_name) {
 
  nearest_idx <- st_nearest_feature(tract_centroids, infrastructure_sf)
  
  distances_meters <- as.numeric(st_distance(tract_centroids, infrastructure_sf[nearest_idx, ], by_element = TRUE))
  
  joined_dataset_proj[[paste0("dist_", infrastructure_name)]] <<- distances_meters
  
  dt_tracts <- as.data.table(st_drop_geometry(joined_dataset_proj))
  dt_tracts[, opp_group := opp_3class(c5_COI_nat)]
  dt_tracts[, target_dist := distances_meters]
  
  layer_summaries <- lapply(BUFFER_DISTANCES, function(d) {
    sub_dt <- if (d == 0) dt_tracts[target_dist == 0] else dt_tracts[target_dist <= d]
    n_tracts_in_buffer <- nrow(sub_dt)
    
    if (n_tracts_in_buffer == 0) {
      return(data.frame(transport = infrastructure_name, buffer_m = d, n_tracts = 0, 
                        pct_low_opp = NA, pct_high_opp = NA, mean_noise_db = NA))
    }
    
    data.frame(
      transport     = infrastructure_name,
      buffer_m      = d,
      n_tracts      = n_tracts_in_buffer,
      pct_low_opp   = (sum(sub_dt$opp_group == "Low",     na.rm = TRUE) / n_tracts_in_buffer) * 100,
      pct_high_opp  = (sum(sub_dt$opp_group == "High",    na.rm = TRUE) / n_tracts_in_buffer) * 100,
      mean_noise_db = mean(sub_dt$mean_noise_db,          na.rm = TRUE)
    )
  })
  
  return(rbindlist(layer_summaries))
}

# Run for All Transportation Matrices
buffer_matrix_results <- rbindlist(list(
  calculate_proximity_matrix(highways_sf, "Highway"),
  calculate_proximity_matrix(bus_sf,      "Bus"),
  calculate_proximity_matrix(rail_sf,     "Rail")
))

# Save output table
write_csv(buffer_matrix_results, file.path(OUTPUT_DIR, "buffer_summary.csv"))

# Add proximity distance tracks to primary master dataset 
joined_dataset <- joined_dataset %>%
  mutate(
    dist_Highway = joined_dataset_proj$dist_Highway,
    dist_Bus     = joined_dataset_proj$dist_Bus,
    dist_Rail    = joined_dataset_proj$dist_Rail
  )

print(head(buffer_matrix_results, 6))


########################################################################################################
########################################################################################################
########################################################################################################
########################################################################################################
########################################################################################################

## Visualize Data

# Focus on lower 48 * adding alaksa/hawaii made it harder to visualize
EXCLUDE_STATES_FP <- c("02","15","72","78","66","60","69")
tracts_plot <- joined_dataset %>% filter(!str_sub(GEOID, 1, 2) %in% EXCLUDE_STATES_FP)

# Download state outlines for boundaries
states_raw <- tigris::states(cb = TRUE, year = 2010, progress_bar = FALSE)
state_fips_col <- intersect(c("STATEFP10", "STATEFP", "STATE"), names(states_raw))[1]

states_sf <- states_raw %>%
  rename(fips_col = all_of(state_fips_col)) %>%
  filter(!fips_col %in% EXCLUDE_STATES_FP) %>%
  st_transform(st_crs(joined_dataset))

# Define spatial boundaries/color ramp
bbox_conus   <- st_bbox(c(xmin = -125, ymin = 24, xmax = -66, ymax = 50), crs = st_crs(4326))
level_order  <- c("Very Low", "Low", "Moderate", "High", "Very High")
level_colors <- c("Very Low"="#d73027", "Low"="#fc8d59", "Moderate"="#ffffbf", "High"="#91cf60", "Very High"="#1a9850")

# Construct the categorical COI 
tracts_plot <- tracts_plot %>%
  mutate(
    coi_level_f = case_when(
      c5_COI_nat == "1" ~ "Very Low",
      c5_COI_nat == "2" ~ "Low",
      c5_COI_nat == "3" ~ "Moderate",
      c5_COI_nat == "4" ~ "High",
      c5_COI_nat == "5" ~ "Very High",
      TRUE ~ NA_character_
    ),
    coi_level_f = factor(coi_level_f, levels = level_order),
    coi_score_num = as.numeric(r_COI_nat)
  )

#### Map 1: COI Ranked Categorical Map 

tracts_plot_m1 <- tracts_plot %>%
  filter(!is.na(coi_score_num))

map1 <- tm_shape(tracts_plot_m1, bbox = bbox_conus) +
  tm_fill(
    col = "coi_score_num", 
    palette = "RdYlGn",          
    style = "quantile",          
    n = 5,                       
    title = "Opportunity Level", 
    labels = c("Very Low", "Low", "Moderate", "High", "Very High"), 
    colorNA = "grey85", 
    textNA = "No Data"
  ) +
  tm_shape(states_sf) + 
  tm_borders(col = "white", lwd = 0.5) +
  tm_layout(
    main.title = "Child Opportunity Index (COI 3.0)", 
    main.title.size = 0.9, 
    legend.outside = TRUE, 
    frame = FALSE
  )

#map1
#tmap_save(map1, file.path(OUTPUT_DIR, "map1_coi_level.png"), width = 14, height = 8, dpi = 200)

#### Map 2: Continuous COI Score Quantiles

map2 <- tm_shape(tracts_plot, bbox = bbox_conus) +
  tm_fill("coi_score_num", palette = "RdYlGn", title = "COI Score (0-100)", style = "quantile", n = 7, alpha = 0.9, colorNA = "grey85") +
  tm_shape(states_sf) + tm_borders(col = "white", lwd = 0.5) +
  tm_layout(main.title = "Child Opportunity Score by Census Tract", main.title.size = 0.9, legend.outside = TRUE, frame = FALSE)

#map2
#tmap_save(map2, file.path(OUTPUT_DIR, "map2_coi_score.png"), width = 14, height = 8, dpi = 200)

#### Map 3: Ambient Decibel Noise Mapping Profiles

map3 <- tm_shape(tracts_plot, bbox = bbox_conus) +
  tm_fill("mean_noise_db", palette = c("#ffffcc","#fed976","#fd8d3c","#e31a1c","#800026"), title = "Mean Noise (dB)", style = "quantile", n = 5, alpha = 0.9, colorNA = "grey85") +
  tm_shape(states_sf) + tm_borders(col = "white", lwd = 0.4) +
  tm_layout(main.title = "Transportation Noise Pollution Profile", main.title.size = 0.9, legend.outside = TRUE, frame = FALSE)

#map3
#tmap_save(map3, file.path(OUTPUT_DIR, "map3_noise.png"), width = 14, height = 8, dpi = 200)

#### Map 4: Multi-Modal Corridor Structural Overlay Layering

tracts_plot_m4 <- tracts_plot %>%
  filter(!is.na(coi_score_num)) %>%
  mutate(
    Near_Transit = case_when(
      dist_Highway <= 1000 ~ "Near Highway (<1km)",
      dist_Bus <= 500      ~ "Near Bus (<500m)",
      dist_Rail <= 1000    ~ "Near Rail (<1km)",
      TRUE                 ~ "No Close Transit Line"
    ),
    Near_Transit = factor(Near_Transit, levels = c("Near Highway (<1km)", "Near Bus (<500m)", "Near Rail (<1km)", "No Close Transit Line"))
  )

# Rewrite to generate faster, previous took to long
map4_fast <- tm_shape(tracts_plot_m4, bbox = bbox_conus) +
  tm_fill(
    col = "Near_Transit", 
    palette = c("#2b8cbe", "#7b2d8b", "#d95f02", "#e8e8e8"), 
    title = "Transit Proximity Zone",
    alpha = 0.85
  ) +
  tm_shape(states_sf) + 
  tm_borders(col = "white", lwd = 0.5) +
  tm_layout(
    main.title = "Transit Access Infrastructure Map by Census Tract", 
    main.title.size = 0.9, 
    legend.outside = TRUE, 
    frame = FALSE
  )

#map4_fast
#tmap_save(map4_fast, file.path(OUTPUT_DIR, "map4_coi_transport.png"), width = 14, height = 8, dpi = 200)


#### Map 5: Highway Distance Map 

map5 <- tm_shape(tracts_plot, bbox = bbox_conus) +
  tm_fill(
    col = "dist_Highway", 
    palette = "-YlOrBr", 
    title = "Distance (meters)", 
    style = "quantile", 
    n = 5, 
    colorNA = "grey85"
  ) +
  tm_shape(states_sf) + 
  tm_borders(col = "white", lwd = 0.4) +
  tm_layout(
    main.title = "Distance to Nearest Highway (NHS)", 
    main.title.size = 0.9, 
    legend.outside = TRUE, 
    frame = FALSE
  )

#map5
#tmap_save(map5, file.path(OUTPUT_DIR, "map5_dist_highway.png"), width = 14, height = 8, dpi = 200)


#### Map 6: COI vs Noise Pollution 

tracts_biv <- tracts_plot %>%
  filter(!is.na(coi_score_num), !is.na(mean_noise_db)) %>%
  mutate(
    coi_class = ntile(coi_score_num, 3), 
    noise_class = ntile(mean_noise_db, 3), 
    biv_class = paste0(coi_class, "-", noise_class)
  )

biv_palette <- c(
  "1-1"="#e8e8e8", "1-2"="#dfb0d6", "1-3"="#be64ac", 
  "2-1"="#ace4e4", "2-2"="#a5add3", "2-3"="#8c62aa", 
  "3-1"="#5ac8c8", "3-2"="#5698b9", "3-3"="#3b4994"
)

map6 <- tm_shape(tracts_biv, bbox = bbox_conus) +
  tm_fill(
    col = "biv_class", 
    palette = biv_palette, 
    title = "COI (↑) × Noise (→)", 
    colorNA = "grey85", 
    textNA = "No Data"
  ) +
  tm_shape(states_sf) + 
  tm_borders(col = "white", lwd = 0.4) +
  tm_layout(
    main.title = "Bivariate: Child Opportunity vs. Noise Pollution", 
    main.title.size = 0.9, 
    legend.outside = TRUE, 
    frame = FALSE
  )

#map6
#tmap_save(map6, file.path(OUTPUT_DIR, "map6_bivariate_coi_noise.png"), width = 14, height = 8, dpi = 200)

# Create Charts

library(ggplot2)
library(scales)
library(data.table)

CSV_PATH <- file.path(OUTPUT_DIR, "buffer_summary.csv")

if (!file.exists(CSV_PATH)) {
  stop("CRITICAL: 'buffer_summary.csv' not found in output folder. Please re-run the Step 4 Proximity script first!")
}

# Load counts from CSV, *original path caused error
chart_data_fixed <- fread(CSV_PATH)

chart_data_long <- melt(
  chart_data_fixed[buffer_m > 0], # Drop the 0m buffer since it has 0 tracts
  id.vars = c("transport", "buffer_m", "n_tracts"),
  measure.vars = c("pct_low_opp", "pct_high_opp"),
  variable.name = "opp_group",
  value.name = "percentage"
)

chart_data_long[, opp_group := case_when(
  opp_group == "pct_low_opp"  ~ "Low Opportunity",
  opp_group == "pct_high_opp" ~ "High Opportunity"
)]

# Calculate the count of tracts 
chart_data_long[, count := round((percentage / 100) * n_tracts)]

# Format from 100m to 1000m
distances_order <- c("100", "250", "500", "750", "1000")
chart_data_long[, buffer_label := factor(paste0(buffer_m, "m"), levels = paste0(distances_order, "m"))]
chart_data_long[, opp_group := factor(opp_group, levels = c("Low Opportunity", "High Opportunity"))]

#### Chart 1: Isolate tract totals per transit mode and buffer zone
p1_data <- unique(chart_data_long[, .(transport, buffer_label, n_tracts)])

plot1_fixed <- ggplot(p1_data, aes(x = buffer_label, y = n_tracts, fill = transport)) +
  geom_col(position = position_dodge(width = 0.8), width = 0.7) +
  scale_fill_manual(name = "Transit Mode", values = c(Highway="#2b8cbe", Bus="#7b2d8b", Rail="#d95f02")) +
  scale_y_continuous(labels = comma) +
  labs(
    title = "Total Census Tracts Within Infrastructure Buffer Zones",
    subtitle = "Cumulative spatial volume counts across the continental United States",
    x = "Buffer Distance Threshold (meters)",
    y = "Number of Census Tracts"
  ) +
  theme_minimal(base_size = 12) +
  theme(
    plot.title = element_text(face = "bold", size = 14),
    panel.grid.minor = element_blank()
  )

#plot1_fixed
#ggsave(file.path(OUTPUT_DIR, "chart1_buffer_total_counts.png"), plot1_fixed, width = 10, height = 6, dpi = 200)


#### Chart 2: COI Tract Counts Comparison

plot2_fixed <- ggplot(chart_data_long, aes(x = buffer_label, y = count, fill = opp_group)) +
  geom_col(position = "dodge", width = 0.7) + 
  facet_wrap(~transport) +
  scale_fill_manual(name = "COI Bracket", values = c("Low Opportunity"="#d73027", "High Opportunity"="#1a9850")) +
  scale_y_continuous(labels = comma) +
  labs(
    title = "Child Opportunity Index (COI) Tract Counts by Buffer Proximity",
    subtitle = "Literal count of low vs. high opportunity census tracts inside each transit buffer",
    x = "Buffer Distance Threshold (meters)",
    y = "Number of Census Tracts"
  ) +
  theme_minimal(base_size = 12) +
  theme(
    plot.title = element_text(face = "bold", size = 14),
    strip.text = element_text(face = "bold", size = 12),
    panel.grid.minor = element_blank()
  )

#plot2_fixed
#ggsave(file.path(OUTPUT_DIR, "chart2_coi_distribution_by_buffer.png"), plot2_fixed, width = 12, height = 6, dpi = 200)

########################################################################################################
########################################################################################################
########################################################################################################
########################################################################################################
########################################################################################################

## Stats

library(data.table)

dt_stats <- as.data.table(st_drop_geometry(joined_dataset))

# Variables to numeric types
dt_stats[, coi_score  := as.numeric(r_COI_nat)]
dt_stats[, noise_db   := as.numeric(mean_noise_db)]
dt_stats[, dist_hwy   := as.numeric(dist_Highway)]
dt_stats[, dist_bus   := as.numeric(dist_Bus)]
dt_stats[, dist_rail  := as.numeric(dist_Rail)]

# Clean missing rows 
dt_stats_clean <- dt_stats[!is.na(coi_score)]

# Split scores into 3 equal-sized tiers
dt_stats_clean[, opp_tier := case_when(
  ntile(coi_score, 3) == 1 ~ "Low Opportunity (Lower 33%)",
  ntile(coi_score, 3) == 2 ~ "Moderate Opportunity (Mid 33%)",
  ntile(coi_score, 3) == 3 ~ "High Opportunity (Upper 33%)"
)]

# Compute final matrix summary
summary_matrix <- dt_stats_clean[, .(
  Tract_Count      = .N,
  Average_Noise_dB = round(mean(noise_db, na.rm = TRUE), 2),
  Avg_Dist_Hwy_m   = round(mean(dist_hwy, na.rm = TRUE), 0),
  Avg_Dist_Bus_m   = round(mean(dist_bus, na.rm = TRUE), 0),
  Avg_Dist_Rail_m  = round(mean(dist_rail, na.rm = TRUE), 0)
), by = opp_tier][order(opp_tier)]

print(summary_matrix)

