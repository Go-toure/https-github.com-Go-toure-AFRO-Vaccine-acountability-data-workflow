# ============================================================
# 02_process_accountability.R   (step 2 of run_pipeline.r)
# Author: Gorgui Ba Toure
#
# Reads the raw ONA download of each enabled form in config/forms.csv (data/raw/<iso3>_<form_id>.parquet) and writes
# ONE clean table:  data/processed/accountability_clean.csv   (one row per ward and campaign day report)
#
# What it does (nothing is changed in the raw files):
#   - removes repeated submissions of the same record (_id), keeping the latest
#   - date of the report: the date typed in the form ('today') when plausible (not before the form's min_date, not
#     after the submission date + 1 day, not more than 60 days before it); otherwise the submission date (date_source)
#   - vials: vials_received (received at LGA level) and vials_returned (returned by the teams) are kept as numbers
#     only when BOTH are between 0 and 5,000 and returned <= received (vials_valid = TRUE); typing errors (e.g.
#     421,601,324) and impossible pairs are set to NA and counted. vials_difference = received - returned and
#     pct_returned = returned / received are derived for valid records only.
#   - batch_match: TRUE / FALSE when both batch numbers are filled (batch returned = batch received)
#   - the detailed stock fields of the newest form version (VACCINE/, DEVICES/, DALUENTS/) are kept as detail_*
#     (about 1% of the records have them)
#   - names of people and phone numbers are NOT carried into the repository (privacy)
# Writes reports/process_summary.json.
# ============================================================
suppressPackageStartupMessages({ library(data.table); library(jsonlite) })
source("R/utils/env_loader.R"); source("R/utils/helpers.R")
STEP <- "02_process_accountability"
dir.create("data/processed", showWarnings = FALSE, recursive = TRUE); dir.create("reports", showWarnings = FALSE, recursive = TRUE)
MAX_FUTURE_DAYS <- 1; MAX_PAST_DAYS <- 60; VIAL_CAP <- 5000

DETAIL <- c(population = "population", vaccine_issued = "VACCINE/vaccine_issued", additional_issued = "VACCINE/additional_issued",
            usable_vials = "VACCINE/usable_vials", unusable_vials = "VACCINE/unusable_vials", empty_vials = "VACCINE/empty_vials",
            distorted_vials = "VACCINE/distorted_vials", broken_damage_vials = "VACCINE/broken_damage_vials",
            target_immunised = "VACCINE/target_immunised",
            syr_0_5ml_issued = "DEVICES/syr_0.5ml_issued", syr_0_5ml_used = "DEVICES/syr_0.5ml_used",
            syr_5ml_issued = "DEVICES/syr_5ml_issued", syr_5ml_used = "DEVICES/syr_5ml_used",
            safetybox_issued = "DEVICES/safetybox_issued", safetybox_used = "DEVICES/safetybox_used",
            diluents_issued = "DALUENTS/diluents_issued", usable_diluents = "DALUENTS/usable_diluents",
            diluents_returned = "DALUENTS/diluents_returned")
SRC <- c("_id", "_submission_time", "today", "states", "lgas", "Wards", "wards", "agency", "agency_other",
         "supervisor_designation", "vaccine_type", "day_activity", "Vials_Rcvd_LGA", "Vials_Return_Teams",
         "BatchNo_Rcvd_LGA", "BatchNo_Return_Teams", "_geolocation[1]", "_geolocation[2]", "_version", unname(DETAIL))

forms <- read_forms_config(); summ <- list(); out <- list()
for (i in seq_len(nrow(forms))) {
  f <- forms[i]
  path <- file.path("data/raw", sprintf("%s_%s.parquet", f$iso3, f$form_id))
  if (!file.exists(path)) { log_msg(STEP, "WARNING: ", path, " not found -- run the fetch step. Skipped."); next }
  log_msg(STEP, "Reading ", path)
  dt <- read_raw_columns(path, SRC)
  n_raw <- nrow(dt)
  dt[, record_id := `_id`]
  setorder(dt, `_submission_time`)
  dt <- dt[!duplicated(record_id, fromLast = TRUE) | is.na(record_id)]
  n_dup <- n_raw - nrow(dt)

  min_date <- as.Date(f$min_date)
  sub_date <- to_date(dt[["_submission_time"]]); form_date <- to_date(dt[["today"]])
  plausible <- !is.na(form_date) & form_date >= min_date & form_date <= sub_date + MAX_FUTURE_DAYS & form_date >= sub_date - MAX_PAST_DAYS
  plausible[is.na(plausible)] <- FALSE
  dt[, visit_date := fifelse(plausible, form_date, sub_date)]
  dt[, date_source := fifelse(plausible, "form", "submission_time")]
  in_window <- !is.na(dt$visit_date) & dt$visit_date >= min_date & dt$visit_date <= Sys.Date() + 1
  n_out <- sum(!in_window); n_fallback <- sum(in_window & dt$date_source == "submission_time")
  dt <- dt[in_window]

  rec <- to_num(dt[["Vials_Rcvd_LGA"]]); ret <- to_num(dt[["Vials_Return_Teams"]])
  has_both <- !is.na(rec) & !is.na(ret)
  valid <- has_both & rec >= 0 & rec <= VIAL_CAP & ret >= 0 & ret <= VIAL_CAP & ret <= rec
  br <- toupper(trimws(dt[["BatchNo_Rcvd_LGA"]])); bt <- toupper(trimws(dt[["BatchNo_Return_Teams"]]))
  both_b <- !is.na(br) & !is.na(bt) & br != "" & bt != ""

  res <- dt[, .(
    country = f$country, iso3 = f$iso3, form_id = f$form_id, record_id = record_id, submission_time = `_submission_time`,
    visit_date = visit_date, date_source = date_source, year = as.integer(format(visit_date, "%Y")),
    month = format(visit_date, "%Y-%m"),
    epi_week = sprintf("%s-W%02d", format(visit_date, "%G"), as.integer(format(visit_date, "%V"))),
    state_raw = clean_text(states), lga_raw = clean_text(lgas),
    ward = clean_text(fifelse(is.na(Wards) | trimws(Wards) == "", wards, Wards)),
    agency = clean_text(agency), supervisor_designation = clean_text(supervisor_designation),
    vaccine_type = fifelse(is.na(vaccine_type) | trimws(vaccine_type) == "", "NOT STATED", trimws(vaccine_type)),
    day_activity = clean_text(day_activity), form_version = `_version`
  )]
  lat <- to_num(dt[["_geolocation[1]"]]); lon <- to_num(dt[["_geolocation[2]"]])
  gv <- !is.na(lat) & !is.na(lon) & abs(lat) <= 90 & abs(lon) <= 180 & !(lat == 0 & lon == 0)
  res[, `:=`(lat = fifelse(gv, lat, NA_real_), lon = fifelse(gv, lon, NA_real_), gps_valid = gv)]
  res[, `:=`(vials_received = fifelse(valid, rec, NA_real_), vials_returned = fifelse(valid, ret, NA_real_),
             vials_valid = valid, vials_filled = has_both,
             vials_returned_gt_received = has_both & rec <= VIAL_CAP & ret <= VIAL_CAP & ret > rec)]
  res[, `:=`(vials_difference = vials_received - vials_returned,
             pct_returned = fifelse(vials_received > 0, round(100 * vials_returned / vials_received, 1), NA_real_))]
  res[, batch_match := fifelse(both_b, br == bt, NA)]
  for (nm in names(DETAIL)) set(res, j = paste0("detail_", nm), value = to_num(dt[[DETAIL[[nm]]]]))

  out[[length(out) + 1]] <- res
  summ[[f$iso3]] <- list(country = f$country, form_id = f$form_id, records_downloaded = n_raw, repeated_submissions_removed = n_dup,
                         date_outside_window_removed = n_out, date_from_submission_time = n_fallback, records_kept = nrow(res),
                         first_date = as.character(min(res$visit_date)), last_date = as.character(max(res$visit_date)),
                         records_with_valid_vials = sum(res$vials_valid), records_returned_gt_received = sum(res$vials_returned_gt_received))
  log_msg(STEP, sprintf("%s: %s downloaded, %s repeated removed, %s outside %s..today removed, %s kept (%s dated by submission time); valid vial counts in %s",
                        f$country, format(n_raw, big.mark = ","), format(n_dup, big.mark = ","), format(n_out, big.mark = ","), f$min_date,
                        format(nrow(res), big.mark = ","), format(n_fallback, big.mark = ","), format(sum(res$vials_valid), big.mark = ",")))
}
if (length(out) == 0) { log_msg(STEP, "FAILED: no raw data found -- nothing to process."); quit(status = 1) }
all <- rbindlist(out, use.names = TRUE, fill = TRUE)
fwrite(all, "data/processed/accountability_clean.csv", na = "")
write_json(list(timestamp = format(Sys.time(), "%Y-%m-%dT%H:%M:%S"), forms = summ), "reports/process_summary.json", auto_unbox = TRUE, pretty = TRUE)
log_msg(STEP, "Wrote data/processed/accountability_clean.csv (", format(nrow(all), big.mark = ","), " rows)")
