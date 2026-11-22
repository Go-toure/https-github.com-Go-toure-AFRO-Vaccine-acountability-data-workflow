# ============================================================
# 03_clean_geonames.R   (step 3 of run_pipeline.r)
# Author: Gorgui Ba Toure
#
# Takes data/processed/accountability_clean.csv and
#   1. gives every record the STANDARD state and LGA name (same names as the AFRO administrative data) -- see
#      R/utils/geo_match.R (overrides, state aliases, exact match, fuzzy match inside the state). Names that could not
#      be matched are kept as typed and listed in reports/geo_unmatched.csv: add them to
#      data/lookup/geoname_overrides.csv and re-run.
#   2. writes the final tables (data/final/)
#        afro_vaccine_accountability_repository.csv      one row per ward and campaign-day report (large: not in git)
#        afro_vaccine_accountability_lga_month.csv       LGA x month x vaccine: reports and vials (valid records only)
#        afro_vaccine_accountability_state_month.csv     state x month x vaccine, with % returned
#   3. writes the data dictionary (data/metadata/AFRO_vaccine_accountability_dictionary.xlsx and ..._columns.csv)
#      with a changelog against the previous run's columns.
# ============================================================
suppressPackageStartupMessages({ library(data.table) })
source("R/utils/helpers.R"); source("R/utils/geo_match.R")
STEP <- "03_clean_geonames"
for (d in c("data/final", "data/metadata", "data/lookup", "reports")) dir.create(d, showWarnings = FALSE, recursive = TRUE)

IN_FILE <- "data/processed/accountability_clean.csv"
if (!file.exists(IN_FILE)) { log_msg(STEP, "FAILED: ", IN_FILE, " not found -- run step 2 first."); quit(status = 1) }
dt <- fread(IN_FILE, colClasses = list(character = c("record_id", "state_raw", "lga_raw", "ward", "form_version")), encoding = "UTF-8")
log_msg(STEP, "Read ", format(nrow(dt), big.mark = ","), " records")
dt <- standardise_geo(dt, STEP)

front <- c("country", "iso3", "form_id", "record_id", "visit_date", "date_source", "year", "month", "epi_week",
           "state", "lga", "ward", "geo_match", "state_raw", "lga_raw", "agency", "supervisor_designation",
           "vaccine_type", "day_activity", "submission_time", "form_version", "lat", "lon", "gps_valid",
           "vials_received", "vials_returned", "vials_difference", "pct_returned", "vials_valid", "vials_filled",
           "vials_returned_gt_received", "batch_match")
repo <- dt[, c(front, grep("^detail_", names(dt), value = TRUE)), with = FALSE]
setorder(repo, iso3, visit_date, state, lga)
fwrite(repo, "data/final/afro_vaccine_accountability_repository.csv", na = "")
log_msg(STEP, "Wrote data/final/afro_vaccine_accountability_repository.csv (", format(nrow(repo), big.mark = ","), " rows)")

summarise_by <- function(keys) {
  repo[, .(reports = .N, reports_with_vials = sum(vials_filled), reports_valid_vials = sum(vials_valid),
           reports_returned_gt_received = sum(vials_returned_gt_received),
           vials_received = sum(vials_received, na.rm = TRUE), vials_returned = sum(vials_returned, na.rm = TRUE),
           reports_batch_checked = sum(!is.na(batch_match)), reports_batch_match = sum(batch_match, na.rm = TRUE)), by = keys][
    , `:=`(pct_returned = fifelse(vials_received > 0, round(100 * vials_returned / vials_received, 1), NA_real_),
           vials_difference = vials_received - vials_returned)]
}
lm <- summarise_by(c("country", "iso3", "state", "lga", "month", "vaccine_type")); setorder(lm, iso3, state, lga, month, vaccine_type)
fwrite(lm, "data/final/afro_vaccine_accountability_lga_month.csv", na = "")
log_msg(STEP, "Wrote data/final/afro_vaccine_accountability_lga_month.csv (", format(nrow(lm), big.mark = ","), " rows)")
sm <- summarise_by(c("country", "iso3", "state", "month", "vaccine_type")); setorder(sm, iso3, state, month, vaccine_type)
fwrite(sm, "data/final/afro_vaccine_accountability_state_month.csv", na = "")
log_msg(STEP, "Wrote data/final/afro_vaccine_accountability_state_month.csv (", format(nrow(sm), big.mark = ","), " rows)")

desc <- c(
  country = "Country name (config/forms.csv)", iso3 = "ISO3 country code", form_id = "ONA form id the record comes from",
  record_id = "ONA record id (_id); unique per report", visit_date = "Date of the report (see date_source)",
  date_source = "form = date typed in the form was plausible; submission_time = replaced by the ONA submission date",
  year = "Year of visit_date", month = "Month of visit_date (YYYY-MM)", epi_week = "ISO week of visit_date",
  state = "Standard state name (AFRO administrative data)", lga = "Standard LGA / district name (AFRO administrative data)",
  ward = "Ward as typed in the form", geo_match = "How state/LGA were matched: override, exact, fuzzy, state_only, unmatched",
  state_raw = "State as typed in the form", lga_raw = "LGA as typed in the form", agency = "Agency of the reporting officer",
  supervisor_designation = "Designation of the reporting officer", vaccine_type = "Vaccine (nOPV2, IPV, mOPV2, bOPV2, fIPV_nOPV2; NOT STATED if blank)",
  day_activity = "Campaign day / activity (D1..D5, Mopup, DOPV-1, ...)", submission_time = "ONA submission time (UTC)",
  form_version = "Version of the ONA form used (newer versions have the detail_* fields)",
  lat = "Latitude (NA when invalid)", lon = "Longitude (NA when invalid)", gps_valid = "TRUE when the GPS point is within range and not 0/0",
  vials_received = "Vials received at LGA level -- only for valid records (both counts 0-5,000 and returned <= received), else NA",
  vials_returned = "Vials returned by the teams -- same rule. The exact meaning of 'returned' is to be confirmed with the form owner: do not present 100 - pct_returned as 'vials not returned' before that",
  vials_difference = "vials_received - vials_returned (valid records only)", pct_returned = "100 * vials_returned / vials_received (valid records only)",
  vials_valid = "TRUE when both vial counts are filled, within 0-5,000 and returned <= received",
  vials_filled = "TRUE when both vial counts are filled (whatever their value)",
  vials_returned_gt_received = "TRUE when returned > received (an inconsistent report; counts left out of the totals)",
  batch_match = "TRUE when the returned batch number equals the received batch number, FALSE when different, NA when one is blank",
  detail_population = "Detail field (newer form only): population", detail_vaccine_issued = "Detail (newer form only): vaccine issued",
  detail_additional_issued = "Detail: additional vaccine issued", detail_usable_vials = "Detail: usable vials", detail_unusable_vials = "Detail: unusable vials",
  detail_empty_vials = "Detail: empty vials", detail_distorted_vials = "Detail: distorted vials", detail_broken_damage_vials = "Detail: broken / damaged vials",
  detail_target_immunised = "Detail: target immunised", detail_syr_0_5ml_issued = "Detail: 0.5 ml syringes issued", detail_syr_0_5ml_used = "Detail: 0.5 ml syringes used",
  detail_syr_5ml_issued = "Detail: 5 ml syringes issued", detail_syr_5ml_used = "Detail: 5 ml syringes used", detail_safetybox_issued = "Detail: safety boxes issued",
  detail_safetybox_used = "Detail: safety boxes used", detail_diluents_issued = "Detail: diluents issued", detail_usable_diluents = "Detail: usable diluents",
  detail_diluents_returned = "Detail: diluents returned")
cols <- data.table(column = names(repo), type = vapply(repo, function(x) class(x)[1], character(1)))
cols[, description := desc[column]]; cols[is.na(description), description := ""]
cols[, file := "afro_vaccine_accountability_repository.csv"]
fwrite(cols, "data/metadata/AFRO_vaccine_accountability_dictionary_columns.csv")
tabs <- data.table(table = c("afro_vaccine_accountability_repository.csv", "afro_vaccine_accountability_lga_month.csv", "afro_vaccine_accountability_state_month.csv"),
  one_row_is = c("one ward and campaign-day report", "LGA x month x vaccine (reports, valid-vial totals, % returned)", "state x month x vaccine (same measures)"))
prev_file <- "data/metadata/schema_previous.csv"; cur <- data.table(column = names(repo))
chg <- if (file.exists(prev_file)) { prev <- fread(prev_file)
  rbind(data.table(change = "added", column = setdiff(cur$column, prev$column)), data.table(change = "removed", column = setdiff(prev$column, cur$column)))
} else data.table(change = "first run", column = cur$column)
if (nrow(chg) == 0) chg <- data.table(change = "no change", column = "")
chg[, run_date := as.character(Sys.Date())]; fwrite(cur, prev_file)
about <- data.table(item = c("Pipeline", "Author", "Source", "Records", "Generated", "Reading note"),
  value = c("AFRO-Vaccine-Accountability-data-workflow", "Gorgui Ba Toure", "ONA form(s) listed in config/forms.csv", format(nrow(repo), big.mark = ","),
            format(Sys.time(), "%Y-%m-%d %H:%M"),
            "Vial totals use only valid reports (both counts 0-5,000, returned <= received). 'Returned' is to be confirmed with the form owner. The detail_* fields exist only in the newest form version (about 1% of reports). No names of people are kept."))
if (requireNamespace("writexl", quietly = TRUE)) {
  writexl::write_xlsx(list(About = about, Tables = tabs, Columns = cols, Changelog = chg), "data/metadata/AFRO_vaccine_accountability_dictionary.xlsx")
  log_msg(STEP, "Wrote data/metadata/AFRO_vaccine_accountability_dictionary.xlsx")
} else log_msg(STEP, "WARNING: package 'writexl' not installed -- only the CSV dictionary was written")
log_msg(STEP, "Done.")
