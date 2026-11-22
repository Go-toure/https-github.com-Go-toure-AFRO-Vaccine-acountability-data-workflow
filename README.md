# AFRO Vaccine Accountability data workflow

Author: Gorgui Ba Toure (WHO AFRO GIS Centre)

Pipeline for the **vaccine accountability** ONA form (Nigeria form **829**), built like the LQAS / IM / admin pipelines:
Python fetch, R processing, geoname cleaning, quality control, push to the SharePoint *Data Repository* folder, data
dictionary. Nigeria first, **config-driven** so other countries are added by editing `config/forms.csv`.
Sister pipeline: `AFRO-Team-Supervision-data-workflow` (form 16194) -- same layout, same commands.

## What it produces

| File | One row is | Where |
|---|---|---|
| `data/final/afro_vaccine_accountability_repository.csv` | one ward and campaign-day report (cleaned, standard state/LGA, valid vial counts) | local + SharePoint (not in git: large) |
| `data/final/afro_vaccine_accountability_lga_month.csv` | LGA x month x vaccine (reports, vials received / returned, % returned, batch checks) | git + SharePoint |
| `data/final/afro_vaccine_accountability_state_month.csv` | state x month x vaccine (same measures) | git + SharePoint |
| `data/metadata/AFRO_vaccine_accountability_dictionary.xlsx` | data dictionary (columns, tables, changelog) | git + SharePoint |
| `reports/qc_summary.json`, `qc_history.csv`, `geo_unmatched.csv` | quality control | local |

**AI agent:** reads these files from the same SharePoint *Data Repository* folder as the LQAS / IM / admin data
(`AFRO_vaccine_accountability_*.csv`, dictionary `AFRO_vaccine_accountability_dictionary.xlsx`) and, locally, from
`data/final/`. The dictionary says what every column means.

## Tokens (never mixed)

| Country | Variable in `config/secrets.env` |
|---|---|
| Nigeria | `ONA_API_TOKEN_NIE` |
| every other country | `ONA_API_TOKEN` |

Each row of `config/forms.csv` names its token in the column `token_env`. A Nigeria form is only fetched with the
Nigeria token and the other countries only with the other one: there is no fallback from one to the other. Copy
`config/secrets.env.example` to `config/secrets.env` and fill it in (git-ignored; on Windows check it is not saved as
`secrets.env.txt` -- that name is also accepted).

## Run

```
pip install requests pandas pyarrow
Rscript run_pipeline.r                      # everything
Rscript run_pipeline.r --skip-fetch         # re-process the data already downloaded
Rscript run_pipeline.r --skip-sharepoint-push --skip-qc
Rscript run_pipeline.r --countries NGA      # only some countries in the fetch step
```
Steps: `1 fetch_ona_data.py` -> `2 R/02_process_accountability.R` -> `3 R/03_clean_geonames.R` ->
`4 R/05_quality_control.R` -> `5 R/06_push_to_sharepoint.R`. Each can also be run alone. The fetch, the QC and the
SharePoint push never stop the pipeline. R packages: `data.table`, `jsonlite`, `httr`, `writexl` (and `arrow` if you
have it, otherwise python + pyarrow reads the parquet).

## Add a country

1. Add a row to `config/forms.csv` (`form_id, country, iso3, name, token_env, min_date, enabled`); use `ONA_API_TOKEN`
   for any country other than Nigeria.
2. Add its states / districts: `python tools/build_geo_lookup.py --admin ../AFRO-Dash/input/AFRO_admin_data.rds --countries "ETHIOPIA=ETH"`
   (existing countries are kept).
3. Run the pipeline; fix names listed in `reports/geo_unmatched.csv` with `data/lookup/geoname_overrides.csv`
   (`iso3,state_raw,lga_raw,state,lga`).

## Rules used (summary)

- Repeated submissions of the same ONA record are removed (the latest is kept).
- Report date = the date typed in the form if plausible (not before `min_date`, not after the submission date + 1 day,
  not more than 60 days before it); otherwise the submission date (`date_source`). `min_date` for Nigeria is 2020-01-01.
- Vials: used only when received and returned are both between 0 and 5,000 and returned <= received (typing errors such
  as 421,601,324 are common). Everything else is left out of the totals and counted in the QC.
- **To confirm with the form owner:** what "vials returned" exactly means. Until then do not quote "100 - % returned"
  as vials lost or not returned.
- The detailed stock fields (`detail_*`) exist only in the newest form version (about 1% of reports).
- No names of people or phone numbers are kept in the repository.
