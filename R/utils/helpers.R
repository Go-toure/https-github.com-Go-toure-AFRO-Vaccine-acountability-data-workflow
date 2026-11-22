# ============================================================
# helpers.R   -- small functions shared by the R steps
# Author: Gorgui Ba Toure
# ============================================================
suppressPackageStartupMessages(library(data.table))

log_msg <- function(step, ...) cat(sprintf("[%s] %s\n", step, paste0(...)))

# Rows of config/forms.csv that are enabled (one row = one country's form)
read_forms_config <- function(path = "config/forms.csv") {
  if (!file.exists(path)) stop("config/forms.csv not found")
  f <- fread(path, colClasses = "character", encoding = "UTF-8")
  f[, enabled := toupper(trimws(enabled)) %in% c("TRUE", "T", "1", "YES")]
  f[enabled == TRUE]
}

# Upper-case letters and digits only: "Dange-Shuni" and "DANGE SHUNI" give the same key
norm_key <- function(x) {
  x <- iconv(as.character(x), to = "ASCII//TRANSLIT", sub = "")
  x[is.na(x)] <- ""
  gsub("[^A-Z0-9]", "", toupper(x))
}
clean_text <- function(x) {
  x <- toupper(trimws(gsub("\\s+", " ", as.character(x))))
  x[is.na(x) | x %in% c("", "NA", "NAN", "NULL", "N/A")] <- NA_character_
  x
}

# Reads the wanted columns of a raw parquet file as TEXT; columns missing in the file are added as NA.
# Uses the 'arrow' package when installed; otherwise tools/parquet_to_csv.py (needs python + pyarrow).
read_raw_columns <- function(path, cols) {
  cols <- unique(cols)
  dt <- NULL
  if (requireNamespace("arrow", quietly = TRUE)) {
    dt <- as.data.table(arrow::read_parquet(path, col_select = tidyselect::any_of(cols)))
  } else {
    py <- Sys.which("python"); if (py == "") py <- Sys.which("python3")
    if (py == "") stop("Neither the R package 'arrow' nor python is available to read ", path)
    tmp <- tempfile(fileext = ".csv")
    status <- system2(py, c(shQuote("tools/parquet_to_csv.py"), shQuote(path), shQuote(tmp),
                            shQuote(paste(cols, collapse = ","))), stdout = FALSE)
    if (!identical(as.integer(status), 0L) || !file.exists(tmp)) stop("parquet_to_csv.py failed for ", path)
    dt <- fread(tmp, colClasses = "character", na.strings = NULL, encoding = "UTF-8")
    unlink(tmp)
  }
  for (cn in names(dt)) set(dt, j = cn, value = as.character(dt[[cn]]))
  for (m in setdiff(cols, names(dt))) set(dt, j = m, value = NA_character_)
  dt
}

to_num <- function(x) suppressWarnings(as.numeric(x))
to_date <- function(x) suppressWarnings(as.Date(substr(as.character(x), 1, 10), format = "%Y-%m-%d"))
