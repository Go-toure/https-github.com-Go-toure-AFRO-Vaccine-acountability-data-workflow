#!/usr/bin/env Rscript
# ============================================================
# 05_quality_control.R   (step 4 of run_pipeline.r)
# Author: Gorgui Ba Toure
#
# Checks the CURRENT vaccine accountability repository (data/final/afro_vaccine_accountability_repository.csv).
# Each check gives OK, WARN or FAIL and says how many rows are concerned. Nothing is changed in the data and the
# script always ends normally (exit 0): a QC finding never stops the pipeline -- read the summary.
#
# Writes (same layout as the LQAS QC):
#   logs/qc.log                 one line per check
#   reports/qc_summary.json     the result in one file
#   reports/qc_issues.csv       the rows behind each WARN / FAIL (first 3000 per check)
#   reports/qc_history.csv      one line per run (trends, sudden drop in rows)
# Settings (environment variables, optional): ACC_QC_INPUT, ACC_QC_MAX_AGE_DAYS (10), ACC_QC_MAX_ROW_DROP (2, percent)
# ============================================================
suppressPackageStartupMessages({ library(data.table); library(jsonlite) })

INPUT_FILE   <- Sys.getenv("ACC_QC_INPUT", "data/final/afro_vaccine_accountability_repository.csv")
MAX_AGE_DAYS <- as.numeric(Sys.getenv("ACC_QC_MAX_AGE_DAYS", "10"))
MAX_ROW_DROP <- as.numeric(Sys.getenv("ACC_QC_MAX_ROW_DROP", "2"))
dir.create("logs", showWarnings = FALSE, recursive = TRUE); dir.create("reports", showWarnings = FALSE, recursive = TRUE)
LOG_FILE <- "logs/qc.log"

log_info <- function(...) {
  line <- sprintf("INFO [%s] %s", format(Sys.time(), "%Y-%m-%d %H:%M:%S"), paste0(...))
  cat(line, "\n", file = LOG_FILE, append = TRUE, sep = ""); cat(line, "\n", sep = "")
}
checks <- list(); issues <- list()
add_check <- function(id, level, msg, n = NA_integer_, rows = NULL) {
  checks[[length(checks) + 1]] <<- list(id = id, level = level, message = msg, n = n)
  log_info(sprintf("[%s] %s: %s", level, id, msg))
  if (level != "OK" && !is.null(rows) && nrow(rows) > 0) { rows <- head(rows, 3000); rows[, check := id]; issues[[length(issues) + 1]] <<- rows }
}
finish <- function(rows_now = NA_integer_) {
  levels <- vapply(checks, function(x) x$level, "")
  overall <- if (any(levels == "FAIL")) "FAIL" else if (any(levels == "WARN")) "WARN" else "OK"
  write_json(list(timestamp = format(Sys.time(), "%Y-%m-%dT%H:%M:%S"), pipeline = "vaccine_accountability", input = INPUT_FILE,
                  overall = overall, n_ok = sum(levels == "OK"), n_warn = sum(levels == "WARN"), n_fail = sum(levels == "FAIL"),
                  checks = checks), "reports/qc_summary.json", auto_unbox = TRUE, pretty = TRUE, na = "null")
  if (length(issues) > 0) fwrite(rbindlist(issues, fill = TRUE), "reports/qc_issues.csv", na = "")
  else if (file.exists("reports/qc_issues.csv")) file.remove("reports/qc_issues.csv")
  hist <- data.table(run = format(Sys.time(), "%Y-%m-%d %H:%M:%S"), rows = rows_now, overall = overall,
                     n_warn = sum(levels == "WARN"), n_fail = sum(levels == "FAIL"))
  fwrite(hist, "reports/qc_history.csv", append = file.exists("reports/qc_history.csv"))
  log_info("Quality control result: ", overall, " (", sum(levels == "OK"), " OK, ", sum(levels == "WARN"), " WARN, ", sum(levels == "FAIL"), " FAIL)")
  quit(status = 0)
}
log_info(strrep("=", 60)); log_info("Running vaccine accountability quality control"); log_info("Checking: ", INPUT_FILE)

# 1 the file
if (!file.exists(INPUT_FILE)) { add_check("file_exists", "FAIL", paste0(INPUT_FILE, " does not exist")); finish() }
age_days <- as.numeric(difftime(Sys.time(), file.mtime(INPUT_FILE), units = "days"))
add_check("file_age", if (age_days > MAX_AGE_DAYS) "WARN" else "OK", sprintf("file written %.1f days ago (limit %g)", age_days, MAX_AGE_DAYS))
dt <- fread(INPUT_FILE, colClasses = list(character = c("record_id", "state", "lga", "ward", "form_version")), encoding = "UTF-8")
n <- nrow(dt)
add_check("rows", if (n == 0) "FAIL" else "OK", paste0(format(n, big.mark = ","), " rows, ", ncol(dt), " columns"), n)
if (n == 0) finish(0L)
key <- intersect(c("iso3", "state", "lga", "visit_date", "record_id"), names(dt))
issue_rows <- function(idx) { x <- dt[idx, key, with = FALSE]; x[, detail := NA_character_]; x }

# 2 rows against the last run
if (file.exists("reports/qc_history.csv")) {
  h <- fread("reports/qc_history.csv"); last <- tail(h$rows[!is.na(h$rows)], 1)
  if (length(last) == 1 && last > 0) {
    drop <- 100 * (last - n) / last
    add_check("row_drop", if (drop > MAX_ROW_DROP) "WARN" else "OK",
              sprintf("rows %s now vs %s at the last run (%+.1f%%)", format(n, big.mark = ","), format(last, big.mark = ","), -drop))
  }
}

# 3 dates
dt[, visit_date := as.Date(visit_date)]
fut <- which(dt$visit_date > Sys.Date() + 1)
add_check("future_dates", if (length(fut)) "FAIL" else "OK", sprintf("%d reports dated in the future", length(fut)), length(fut), if (length(fut)) issue_rows(fut))
sub_share <- 100 * mean(dt$date_source == "submission_time")
add_check("date_from_submission", if (sub_share > 5) "WARN" else "OK",
          sprintf("%.1f%% of reports have an implausible date in the form and use the submission date", sub_share), sum(dt$date_source == "submission_time"))
latest <- max(dt$visit_date, na.rm = TRUE)
add_check("latest_report", if (as.numeric(Sys.Date() - latest) > 90) "WARN" else "OK", paste0("latest report date: ", latest))

# 4 duplicates
dup <- which(duplicated(dt$record_id))
add_check("duplicate_records", if (length(dup)) "FAIL" else "OK", sprintf("%d duplicated record ids", length(dup)), length(dup), if (length(dup)) issue_rows(dup))

# 5 geography
un <- which(dt$geo_match %in% c("unmatched", "state_only"))
pu <- 100 * length(un) / n
add_check("geo_unmatched", if (pu > 10) "FAIL" else if (pu > 2) "WARN" else "OK",
          sprintf("%.2f%% of reports have a state/LGA not found in the geography list (see reports/geo_unmatched.csv)", pu), length(un),
          if (length(un)) issue_rows(un))
fz <- 100 * mean(dt$geo_match == "fuzzy")
add_check("geo_fuzzy", if (fz > 10) "WARN" else "OK", sprintf("%.2f%% of reports matched by close spelling (fuzzy)", fz))

# 6 vials
filled <- dt[vials_filled == TRUE]
vv <- 100 * mean(filled$vials_valid)
add_check("vials_valid", if (nrow(filled) == 0) "WARN" else if (vv < 70) "WARN" else "OK",
          sprintf("%.1f%% of the %s reports with vial counts have valid counts (0-5,000 and returned <= received)", vv, format(nrow(filled), big.mark = ",")),
          sum(!filled$vials_valid), if (vv < 70) issue_rows(which(dt$vials_filled & !dt$vials_valid)))
gt <- 100 * mean(filled$vials_returned_gt_received)
add_check("returned_gt_received", if (gt > 10) "WARN" else "OK", sprintf("%.1f%% of reports return more vials than were received", gt), sum(filled$vials_returned_gt_received))
vf <- 100 * mean(dt$vials_filled)
add_check("vials_filled", if (vf < 80) "WARN" else "OK", sprintf("%.1f%% of reports have both vial counts filled", vf))
ns <- 100 * mean(dt$vaccine_type == "NOT STATED")
add_check("vaccine_type", if (ns > 5) "WARN" else "OK", sprintf("%.2f%% of reports without a vaccine type", ns), sum(dt$vaccine_type == "NOT STATED"))
gp <- 100 * mean(dt$gps_valid, na.rm = TRUE)
add_check("gps_valid", "OK", sprintf("%.1f%% of reports have a valid GPS point (the older form versions have none)", gp))

# 8 the summary tables agree with the repository
f2 <- "data/final/afro_vaccine_accountability_lga_month.csv"
if (file.exists(f2)) {
  s <- fread(f2, select = "reports")
  add_check("summary_consistent", if (sum(s$reports) == n) "OK" else "FAIL",
            sprintf("lga_month table totals %s records, repository has %s", format(sum(s$reports), big.mark = ","), format(n, big.mark = ",")))
} else add_check("summary_consistent", "WARN", paste0(f2, " not found"))
add_check("dictionary", if (file.exists("data/metadata/AFRO_vaccine_accountability_dictionary_columns.csv")) "OK" else "WARN", "data dictionary present")

finish(n)
