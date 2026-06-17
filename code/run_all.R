# run_all.R ────────────────────────────────────────────────────────────────────
# Runs all three transport scripts in order.
# From the COI project root:
#   Rscript code/run_all.R
#
# Script order:
#   1. transport_01_load.R   -- load COI/RUCA, compute infra cache, download ACS
#   2. transport_02_analysis.R -- summary stats + regressions
#   3. transport_03_figures.R  -- all 6 figures
#
# First run: 45-90 min (TIGER road download + spatial compute, then cached).
# Subsequent runs: ~5 min (cache loads instantly; ACS + noise are fast).

library(here)
CODE_DIR <- here("code")

run_script <- function(name) {
  path <- file.path(CODE_DIR, name)
  cat(rep("─", 72), "\n", sep = "")
  message(sprintf("[ %s ]  Starting: %s", format(Sys.time(), "%H:%M:%S"), name))
  cat(rep("─", 72), "\n", sep = "")
  t0 <- proc.time()
  source(path, echo = FALSE, local = FALSE)
  elapsed <- round((proc.time() - t0)[["elapsed"]])
  message(sprintf("[ %s ]  Done: %s  (%d min %02d sec)\n",
                  format(Sys.time(), "%H:%M:%S"), name,
                  elapsed %/% 60, elapsed %% 60))
}

t_total <- proc.time()

run_script("transport_01_load.R")
run_script("transport_02_analysis.R")
run_script("transport_03_figures.R")

total <- round((proc.time() - t_total)[["elapsed"]])
cat(rep("═", 72), "\n", sep = "")
message(sprintf("All scripts complete.  Total time: %d min %02d sec",
                total %/% 60, total %% 60))
cat(rep("═", 72), "\n", sep = "")
