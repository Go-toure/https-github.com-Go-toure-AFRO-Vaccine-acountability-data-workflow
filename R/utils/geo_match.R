# ============================================================
# geo_match.R  -- standard state / LGA names (shared by the pipelines)
# Author: Gorgui Ba Toure
#
# standardise_geo(dt, step) takes a table with iso3, state_raw, lga_raw and returns it with state, lga (standard names
# from data/lookup/geo_lookup.csv) and geo_match (override / exact / fuzzy / state_only / unmatched). Order of rules:
#   a) data/lookup/geoname_overrides.csv   manual corrections (iso3, state_raw, lga_raw, state, lga) -- always win
#   b) data/lookup/geo_aliases.csv         state spellings (iso3, alias, state), e.g. FCT ABUJA -> FCT
#   c) exact match on letters+digits only  ("Dange-Shuni" = "DANGE SHUNI")
#   d) fuzzy match inside the same state   (edit distance <= 1 per 5 letters, only when ONE best candidate)
# Writes reports/geo_unmatched.csv (names to add to geoname_overrides.csv) and reports/geo_fuzzy_review.csv.
# ============================================================
standardise_geo <- function(dt, STEP) {
  dir.create("reports", showWarnings = FALSE, recursive = TRUE)
  dt[state_raw == "", state_raw := NA_character_]; dt[lga_raw == "", lga_raw := NA_character_]
  if (!file.exists("data/lookup/geo_lookup.csv")) {
    log_msg(STEP, "FAILED: data/lookup/geo_lookup.csv not found (python tools/build_geo_lookup.py ...)"); quit(status = 1)
  }
  geo <- fread("data/lookup/geo_lookup.csv", colClasses = "character", encoding = "UTF-8")
  geo[, `:=`(skey = norm_key(state), lkey = norm_key(lga))]
  read_optional <- function(p, cols) if (file.exists(p)) fread(p, colClasses = "character", encoding = "UTF-8") else
    setNames(data.table(matrix(character(), 0, length(cols))), cols)
  ovr <- read_optional("data/lookup/geoname_overrides.csv", c("iso3", "state_raw", "lga_raw", "state", "lga"))
  ali <- read_optional("data/lookup/geo_aliases.csv", c("iso3", "alias", "state"))
  ovr[, `:=`(sk = norm_key(state_raw), lk = norm_key(lga_raw))]
  ali[, ak := norm_key(alias)]

  best_fuzzy <- function(key, candidates) {          # candidates: character vector of keys; returns index or NA
    if (is.na(key) || key == "" || length(candidates) == 0) return(NA_integer_)
    d <- as.vector(adist(key, candidates))
    m <- min(d); limit <- max(1, floor(nchar(key) / 5))
    if (m <= limit && sum(d == m) == 1) which.min(d) else NA_integer_
  }

  u <- unique(dt[, .(iso3, state_raw, lga_raw)])
  u[, `:=`(sk = norm_key(state_raw), lk = norm_key(lga_raw), state_std = NA_character_, lga_std = NA_character_,
           geo_match = "unmatched")]
  for (i in seq_len(nrow(u))) {
    iso <- u$iso3[i]; g <- geo[iso3 == iso]
    o <- ovr[iso3 == iso & sk == u$sk[i] & lk == u$lk[i]]
    if (nrow(o) > 0) {
      u[i, `:=`(state_std = o$state[1], lga_std = o$lga[1], geo_match = "override")]; next
    }
    # state
    st <- NA_character_
    a <- ali[iso3 == iso & ak == u$sk[i]]
    if (nrow(a) > 0) st <- a$state[1]
    if (is.na(st)) { s <- unique(g[skey == u$sk[i], state]); if (length(s) == 1) st <- s }
    if (is.na(st)) { ss <- unique(g[, .(state, skey)]); j <- best_fuzzy(u$sk[i], ss$skey); if (!is.na(j)) st <- ss$state[j] }
    if (is.na(st)) { u[i, `:=`(state_std = u$state_raw[i], lga_std = u$lga_raw[i])]; next }
    # LGA inside the state
    gs <- g[state == st]
    hit <- gs[lkey == u$lk[i]]
    if (nrow(hit) > 0 && u$lk[i] != "") {
      u[i, `:=`(state_std = st, lga_std = hit$lga[1], geo_match = "exact")]
    } else {
      j <- best_fuzzy(u$lk[i], gs$lkey)
      if (!is.na(j)) u[i, `:=`(state_std = st, lga_std = gs$lga[j], geo_match = "fuzzy")]
      else u[i, `:=`(state_std = st, lga_std = u$lga_raw[i], geo_match = if (is.na(u$lga_raw[i])) "state_only" else "unmatched")]
    }
  }
  dt <- merge(dt, u[, .(iso3, state_raw, lga_raw, state_std, lga_std, geo_match)],
              by = c("iso3", "state_raw", "lga_raw"), all.x = TRUE, sort = FALSE)
  setnames(dt, c("state_std", "lga_std"), c("state", "lga"))
  dt[is.na(state), state := state_raw]

  mt <- dt[, .N, by = geo_match][order(-N)]
  for (k in seq_len(nrow(mt))) log_msg(STEP, sprintf("geo_match %-10s %s records (%.2f%%)", mt$geo_match[k],
                                                     format(mt$N[k], big.mark = ","), 100 * mt$N[k] / nrow(dt)))
  unm <- dt[geo_match %in% c("unmatched", "state_only"), .(records = .N), by = .(iso3, state_raw, lga_raw, geo_match)][order(-records)]
  fwrite(unm, "reports/geo_unmatched.csv", na = "")
  if (nrow(unm) > 0) log_msg(STEP, nrow(unm), " state/LGA spellings not matched -> reports/geo_unmatched.csv ",
                             "(add the right name in data/lookup/geoname_overrides.csv)")

  fz <- dt[geo_match == "fuzzy", .(records = .N), by = .(iso3, state_raw, lga_raw, state, lga)][order(-records)]
  fwrite(fz, "reports/geo_fuzzy_review.csv", na = "")
  log_msg(STEP, nrow(fz), " close-spelling matches to review -> reports/geo_fuzzy_review.csv (wrong ones: add to geoname_overrides.csv)")
  dt[is.na(state), state := "UNKNOWN"]; dt[is.na(lga), lga := "UNKNOWN"]
  dt
}
