#!/usr/bin/env Rscript
# ============================================================
# run_pipeline.r  --  Vaccine accountability pipeline
# Author: Gorgui Ba Toure
#
# Same layout as the LQAS / IM pipelines. Run from the project folder:
#     Rscript run_pipeline.r
#
# Steps
#   1 fetch          python fetch_ona_data.py            ONA download (token per country, see config/forms.csv)
#   2 process        Rscript R/02_process_accountability.R
#   3 clean          Rscript R/03_clean_geonames.R       standard state/LGA names, final tables, data dictionary
#   4 qc             Rscript R/05_quality_control.R      checks (never stops the pipeline)
#   5 sharepoint     Rscript R/06_push_to_sharepoint.R   Data Repository folder (a failure does not stop anything)
#
# Options
#   --skip-fetch --skip-process --skip-clean --skip-qc --skip-sharepoint-push
#   --countries NGA[,ETH,...]     only these ISO3 codes in the fetch step
#   --allow-shrink                accept a download with >10% fewer records than before
# ============================================================
args <- commandArgs(trailingOnly = TRUE)
has <- function(flag) flag %in% args
opt_value <- function(flag) { i <- match(flag, args); if (is.na(i) || i == length(args)) NULL else args[i + 1] }

py <- Sys.which("python"); if (py == "") py <- Sys.which("python3")
rs <- Sys.which("Rscript"); if (rs == "") rs <- "Rscript"

fetch_args <- c("fetch_ona_data.py")
if (!is.null(opt_value("--countries"))) fetch_args <- c(fetch_args, "--countries", opt_value("--countries"))
if (has("--allow-shrink")) fetch_args <- c(fetch_args, "--allow-shrink")

steps <- list(
  list(name = "Fetch from ONA",            skip = has("--skip-fetch"),           cmd = py, args = fetch_args,                      hard_stop = FALSE),
  list(name = "Process",                   skip = has("--skip-process"),         cmd = rs, args = "R/02_process_accountability.R",               hard_stop = TRUE),
  list(name = "Clean names / final files", skip = has("--skip-clean"),           cmd = rs, args = "R/03_clean_geonames.R",         hard_stop = TRUE),
  list(name = "Quality control",           skip = has("--skip-qc"),              cmd = rs, args = "R/05_quality_control.R",        hard_stop = FALSE),
  list(name = "Push to SharePoint",        skip = has("--skip-sharepoint-push"), cmd = rs, args = "R/06_push_to_sharepoint.R",     hard_stop = FALSE)
)

if (py == "") stop("python was not found on the PATH")
cat(strrep("=", 60), "\nVaccine accountability pipeline  --  ", format(Sys.time(), "%Y-%m-%d %H:%M:%S"), "\n", strrep("=", 60), "\n", sep = "")
outcome <- list()
for (s in steps) {
  if (isTRUE(s$skip)) { cat("\n>>> SKIPPED: ", s$name, "\n", sep = ""); outcome[[s$name]] <- "skipped"; next }
  cat("\n>>> ", s$name, "\n", sep = "")
  t0 <- Sys.time()
  status <- suppressWarnings(system2(s$cmd, s$args))     # output is shown live
  ok <- identical(as.integer(status), 0L)
  cat(sprintf("<<< %s: %s (%.0f s)\n", s$name, if (ok) "OK" else "FAILED", as.numeric(difftime(Sys.time(), t0, units = "secs"))))
  outcome[[s$name]] <- if (ok) "ok" else "failed"
  if (!ok && isTRUE(s$hard_stop)) { cat("\nStopped: '", s$name, "' is required by the next steps.\n", sep = ""); quit(status = 1) }
}
cat("\n", strrep("=", 60), "\nSummary\n", sep = "")
for (n in names(outcome)) cat(sprintf("  %-28s %s\n", n, outcome[[n]]))
quit(status = ifelse(any(unlist(outcome) == "failed"), 1, 0))
