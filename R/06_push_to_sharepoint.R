# ============================================================
# 06_push_to_sharepoint.R   (step 5 of run_pipeline.r)
# Author: Gorgui Ba Toure
#
# Pushes the cleaned vaccine accountability files to the WHO AFRO GIS Workspace "Data Repository" folder on SharePoint
# -- the SAME folder the LQAS / IM / admin repositories are pushed to, so the AI agent reads everything from one place:
#   https://worldhealthorg.sharepoint.com/sites/AF-pep/GISWORKSPACE/Shared Documents/7. SIA_Data/Data Repository
#
# Same app-only Microsoft Graph login as Posit-LQAS-Workflow/R/06_push_to_sharepoint.R. Credentials come only from
# config/secrets.env (git-ignored). The target folder is checked before uploading; if it does not exist the script
# stops instead of uploading somewhere else. Existing files of the same name are replaced (refreshed in place).
# Large files are uploaded in chunks read one at a time from disk (no need to load the whole file in memory).
#
# Files (a missing optional file only gives a warning; a missing required file fails the push):
#   data/final/afro_vaccine_accountability_lga_month.csv  ->  AFRO_vaccine_accountability_lga_month.csv  (required)
#   data/final/afro_vaccine_accountability_state_month.csv  ->  AFRO_vaccine_accountability_state_month.csv  (required)
#   data/metadata/AFRO_vaccine_accountability_dictionary.xlsx  ->  AFRO_vaccine_accountability_dictionary.xlsx  (optional)
#   data/final/afro_vaccine_accountability_repository.csv  ->  AFRO_vaccine_accountability_repository.csv  (optional)
# Never prints the client secret or the access token.
# Usage:  Rscript R/06_push_to_sharepoint.R
# ============================================================
suppressPackageStartupMessages({ library(httr); library(jsonlite) })
source("R/utils/env_loader.R")
load_secrets_env(getwd())

log_msg <- function(msg) cat(sprintf("[06_push_to_sharepoint] %s\n", msg))
`%||%` <- function(a, b) if (is.null(a)) b else a

SITE_HOSTNAME <- "worldhealthorg.sharepoint.com"
SITE_PATH     <- "sites/AF-pep/GISWORKSPACE"
TARGET_FOLDER <- "7. SIA_Data/Data Repository"
GRAPH_ENDPOINT <- "https://graph.microsoft.com/v1.0"

# local file, name on SharePoint, required?
FILES <- list(
  list("data/final/afro_vaccine_accountability_lga_month.csv", "AFRO_vaccine_accountability_lga_month.csv", TRUE),
  list("data/final/afro_vaccine_accountability_state_month.csv", "AFRO_vaccine_accountability_state_month.csv", TRUE),
  list("data/metadata/AFRO_vaccine_accountability_dictionary.xlsx", "AFRO_vaccine_accountability_dictionary.xlsx", FALSE),
  list("data/final/afro_vaccine_accountability_repository.csv", "AFRO_vaccine_accountability_repository.csv", FALSE)
)

encode_path <- function(path) {
  seg <- strsplit(path, "/", fixed = TRUE)[[1]]
  paste(vapply(seg, utils::URLencode, character(1), reserved = TRUE), collapse = "/")
}

get_access_token <- function(tenant_id, client_id, client_secret) {
  resp <- POST(paste0("https://login.microsoftonline.com/", tenant_id, "/oauth2/v2.0/token"),
               body = list(client_id = client_id, client_secret = client_secret,
                           scope = "https://graph.microsoft.com/.default", grant_type = "client_credentials"),
               encode = "form")
  if (status_code(resp) != 200) {
    stop("Failed to get access token: ", content(resp, "parsed")$error_description %||% status_code(resp))
  }
  content(resp, "parsed")$access_token
}

get_drive_id <- function(token) {
  auth <- add_headers(Authorization = paste("Bearer", token))
  s <- GET(paste0(GRAPH_ENDPOINT, "/sites/", SITE_HOSTNAME, ":/", SITE_PATH), auth)
  if (status_code(s) != 200) stop("Could not resolve SharePoint site '", SITE_PATH, "' (status ", status_code(s), ").")
  site_id <- content(s, "parsed")$id
  d <- GET(paste0(GRAPH_ENDPOINT, "/sites/", site_id, "/drive"), auth)
  if (status_code(d) != 200) stop("Could not resolve the site's document library (status ", status_code(d), ").")
  content(d, "parsed")$id
}

verify_target_folder <- function(drive_id, token) {
  r <- GET(paste0(GRAPH_ENDPOINT, "/drives/", drive_id, "/root:/", encode_path(TARGET_FOLDER)),
           add_headers(Authorization = paste("Bearer", token)))
  if (status_code(r) != 200) {
    stop("Target folder '", TARGET_FOLDER, "' not found (status ", status_code(r),
         "). Refusing to upload to a fallback location.")
  }
  log_msg(paste0("Confirmed target folder exists: ", TARGET_FOLDER))
}

upload_file <- function(path, remote_name, drive_id, token) {
  size <- file.info(path)$size
  item_path <- paste0(TARGET_FOLDER, "/", remote_name)
  log_msg(sprintf("Uploading %s (%.1f MB) -> %s/%s", basename(path), size / 1024^2, TARGET_FOLDER, remote_name))
  auth <- add_headers(Authorization = paste("Bearer", token))
  if (size > 4 * 1024^2) {
    ses <- POST(paste0(GRAPH_ENDPOINT, "/drives/", drive_id, "/root:/", encode_path(item_path), ":/createUploadSession"),
                auth, body = list(item = list(`@microsoft.graph.conflictBehavior` = "replace")), encode = "json")
    if (status_code(ses) != 200) stop("Failed to create an upload session (status ", status_code(ses), ")")
    url <- content(ses, "parsed")$uploadUrl
    chunk <- 10 * 1024^2                       # a multiple of 320 KiB, as Graph requires
    n <- ceiling(size / chunk)
    con <- file(path, "rb"); on.exit(close(con), add = TRUE)
    for (i in seq_len(n)) {
      start <- (i - 1) * chunk
      data <- readBin(con, "raw", n = chunk)
      resp <- PUT(url, add_headers("Content-Range" = sprintf("bytes %.0f-%.0f/%.0f", start, start + length(data) - 1, size),
                                   "Content-Type" = "application/octet-stream"), body = data)
      if (!(status_code(resp) %in% c(200, 201, 202))) stop("Chunk ", i, " of ", n, " failed (status ", status_code(resp), ")")
      if (i %% 5 == 0 || i == n) log_msg(sprintf("  uploaded chunk %d/%d", i, n))
    }
    item <- content(resp, "parsed")
  } else {
    ctype <- if (grepl("\\.xlsx$", remote_name, ignore.case = TRUE))
      "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" else "text/csv"
    resp <- PUT(paste0(GRAPH_ENDPOINT, "/drives/", drive_id, "/root:/", encode_path(item_path), ":/content"),
                add_headers(Authorization = paste("Bearer", token), "Content-Type" = ctype),
                body = readBin(path, "raw", n = size))
    if (!(status_code(resp) %in% c(200, 201))) stop("Upload failed (status ", status_code(resp), ")")
    item <- content(resp, "parsed")
  }
  log_msg("SUCCESS: upload complete.")
  if (!is.null(item$webUrl)) log_msg(paste0("  View at: ", item$webUrl))
  invisible(TRUE)
}

main <- function() {
  tenant <- Sys.getenv("SHAREPOINT_TENANT_ID"); client <- Sys.getenv("SHAREPOINT_CLIENT_ID")
  secret <- Sys.getenv("SHAREPOINT_CLIENT_SECRET")
  if (tenant == "" || client == "" || secret == "") {
    log_msg("FAILED: SHAREPOINT_TENANT_ID / SHAREPOINT_CLIENT_ID / SHAREPOINT_CLIENT_SECRET are not all set.")
    log_msg("Add them to config/secrets.env (see config/secrets.env.example).")
    quit(status = 1)
  }
  to_push <- Filter(function(f) {
    if (file.exists(f[[1]])) return(TRUE)
    log_msg(paste0(if (isTRUE(f[[3]])) "MISSING (required): " else "WARNING: not found, skipped: ", f[[1]]))
    FALSE
  }, FILES)
  missing_required <- any(vapply(FILES, function(f) isTRUE(f[[3]]) && !file.exists(f[[1]]), logical(1)))
  if (missing_required || length(to_push) == 0) {
    log_msg("FAILED: a required file is missing -- run the processing steps first.")
    quit(status = 1)
  }
  ok <- tryCatch({
    token <- get_access_token(tenant, client, secret)
    log_msg("Authenticated to Microsoft Graph.")
    drive <- get_drive_id(token)
    verify_target_folder(drive, token)
    for (f in to_push) {
      if (isTRUE(f[[3]])) {
        upload_file(f[[1]], f[[2]], drive, token)
      } else {
        # optional files never fail the push
        tryCatch(upload_file(f[[1]], f[[2]], drive, token),
                 error = function(e) log_msg(paste0("WARNING: ", f[[2]], " not uploaded (", conditionMessage(e), ")")))
      }
    }
    TRUE
  }, error = function(e) { log_msg(paste0("FAILED: ", conditionMessage(e))); FALSE })
  quit(status = ifelse(isTRUE(ok), 0, 1))
}
main()
