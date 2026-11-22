# ============================================================
# env_loader.R
# Author: Gorgui Ba Toure
#
# Loads KEY=VALUE lines from config/secrets.env (or secrets.env.txt, which Windows creates when the file extension
# is hidden) into the R session's environment. A variable already set in the real environment is NOT overwritten.
# Secrets are never printed.
# ============================================================
load_secrets_env <- function(base_dir = getwd()) {
  for (nm in c("secrets.env", "secrets.env.txt")) {
    path <- file.path(base_dir, "config", nm)
    if (!file.exists(path)) next
    for (line in readLines(path, warn = FALSE, encoding = "UTF-8")) {
      line <- trimws(sub("^﻿", "", line))
      if (nchar(line) == 0 || startsWith(line, "#") || !grepl("=", line, fixed = TRUE)) next
      parts <- strsplit(line, "=", fixed = TRUE)[[1]]
      key <- trimws(parts[1])
      value <- gsub("^[\"']|[\"']$", "", trimws(paste(parts[-1], collapse = "=")))
      if (nchar(key) > 0 && nchar(value) > 0 && identical(Sys.getenv(key), "")) {
        do.call(Sys.setenv, setNames(list(value), key))
      }
    }
    break
  }
  invisible(NULL)
}
