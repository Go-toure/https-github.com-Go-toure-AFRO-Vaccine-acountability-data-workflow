#!/usr/bin/env python3
"""
fetch_ona_data.py  (step 1 of run_pipeline.r)
Author: Gorgui Ba Toure

Downloads the ONA form(s) listed in config/forms.csv for vaccine accountability -- same safe download logic as the
LQAS / IM pipelines (paged, retried, never overwrites a good file with a partial download).

TOKENS (one per country, never mixed)
  config/forms.csv has a column token_env that names the environment variable holding the token of that row:
      Nigeria            -> ONA_API_TOKEN_NIE
      every other country -> ONA_API_TOKEN
  The value is read from the real environment or from the git-ignored config/secrets.env. There is NO fallback from
  one token to the other: a Nigeria form is only ever fetched with the Nigeria token, other countries only with the
  other token. A row whose token is missing is skipped (and reported); the other rows still run.

Output (data/ is git-ignored)
  data/raw/<iso3>_<form_id>.parquet           raw copy, every column as text
  data/raw/<iso3>_<form_id>_metadata.json
  data/raw/fetch_summary.json

Safety: a failed/partial download never replaces a good file; if ONA returns more than 10% fewer records than the
file already on disk it is treated as a broken response and the old file is kept (--allow-shrink to accept it).

Usage
  python fetch_ona_data.py                       # every enabled row of config/forms.csv
  python fetch_ona_data.py --countries NGA       # only these ISO3 codes
  python fetch_ona_data.py --form-ids 829
  python fetch_ona_data.py --test                # only test the token(s)
Exit code 1 if something could not be refreshed, 0 otherwise.
"""
import argparse
import csv
import json
import os
import sys
import time
from datetime import datetime
from pathlib import Path

import pandas as pd
import requests

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from _env_loader import load_secrets_env  # noqa: E402

BASE_URL = "https://api.whonghub.org/api/v1/data"
RAW_DIR = HERE / "data" / "raw"
FORMS_FILE = HERE / "config" / "forms.csv"
SHRINK_TOLERANCE = 0.90
PAGE_SIZE = 10000


class FetchError(Exception):
    """A page could not be downloaded (so a failed download is never mistaken for 'no more records')."""


def read_forms():
    with open(FORMS_FILE, newline="", encoding="utf-8-sig") as f:
        rows = list(csv.DictReader(f))
    for r in rows:
        r["form_id"] = int(r["form_id"])
        r["enabled"] = str(r.get("enabled", "TRUE")).strip().upper() in ("TRUE", "T", "1", "YES")
    return rows


def flatten_dict(data, parent_key="", sep="/"):
    flat = {}
    for key, value in data.items():
        new_key = f"{parent_key}{sep}{key}" if parent_key else key
        if isinstance(value, dict):
            flat.update(flatten_dict(value, new_key, sep))
        elif isinstance(value, list):
            for i, item in enumerate(value, 1):
                if isinstance(item, dict):
                    flat.update(flatten_dict(item, f"{new_key}[{i}]", sep))
                else:
                    flat[f"{new_key}[{i}]"] = str(item) if item is not None else ""
        else:
            flat[new_key] = str(value) if value is not None else ""
    return flat


def fetch_page(form_id, page, token):
    headers = {"Authorization": f"Token {token}"}
    params = {"page": page, "page_size": PAGE_SIZE}
    problem = ""
    for attempt in range(1, 4):
        try:
            r = requests.get(f"{BASE_URL}/{form_id}.json", params=params, headers=headers, timeout=120)
        except requests.exceptions.Timeout:
            problem = f"timeout on page {page} of form {form_id}"
        except Exception as e:  # noqa: BLE001
            problem = f"{type(e).__name__} on page {page} of form {form_id}"
        else:
            if r.status_code == 200:
                try:
                    return r.json()
                except ValueError:
                    problem = f"invalid JSON on page {page} of form {form_id}"
            elif r.status_code == 429:
                print("  [rate limited] waiting 30 s")
                time.sleep(30)
                problem = f"rate limited on page {page} of form {form_id}"
                continue
            elif r.status_code in (401, 403):
                raise FetchError(f"authentication failed for form {form_id} (HTTP {r.status_code})")
            elif r.status_code == 404:
                raise FetchError(f"form {form_id} not found (HTTP 404: this token's account cannot see it)")
            else:
                problem = f"HTTP {r.status_code} for form {form_id}"
        if attempt < 3:
            print(f"  [retry {attempt}/2] {problem}")
            time.sleep(5 * attempt)
    raise FetchError(problem)


def fetch_all(form_id, token):
    rows, page = [], 1
    print(f"[FETCH] form {form_id}")
    while True:
        print(f"  page {page} ...", end=" ", flush=True)
        data = fetch_page(form_id, page, token)
        if not data:
            print("no data")
            break
        print(f"{len(data)} records")
        rows.extend(flatten_dict(d) for d in data)
        if len(data) < PAGE_SIZE:
            break
        page += 1
        time.sleep(0.5)
    return rows


def test_token(token_env, token):
    try:
        r = requests.get(BASE_URL.rsplit("/data", 1)[0] + "/user.json",
                         headers={"Authorization": f"Token {token}"}, timeout=30)
    except Exception as e:  # noqa: BLE001
        print(f"[ERROR] {token_env}: connection error ({type(e).__name__})")
        return False
    if r.status_code == 200:
        try:
            print(f"[OK] {token_env}: connection successful (ONA user: {r.json().get('username')})")
        except (ValueError, AttributeError):
            print(f"[OK] {token_env}: connection successful")
        return True
    print(f"[ERROR] {token_env}: connection failed (HTTP {r.status_code})")
    return False


def save(row, records, prev):
    df = pd.DataFrame(records).fillna("").astype(str)
    stem = f"{row['iso3']}_{row['form_id']}"
    RAW_DIR.mkdir(parents=True, exist_ok=True)
    pq, tmp = RAW_DIR / f"{stem}.parquet", RAW_DIR / f"{stem}.parquet.tmp"
    df.to_parquet(tmp, engine="pyarrow", compression="snappy", index=False)
    os.replace(tmp, pq)
    with open(RAW_DIR / f"{stem}_metadata.json", "w") as f:
        json.dump({"form_id": row["form_id"], "country": row["country"], "iso3": row["iso3"], "name": row["name"],
                   "records": len(df), "columns": len(df.columns),
                   "last_fetch": datetime.now().isoformat(), "previous_records": prev}, f, indent=2)
    print(f"[SAVED] {row['country']} form {row['form_id']}: {len(df):,} rows x {len(df.columns)} columns -> data/raw/{pq.name}")


def main():
    ap = argparse.ArgumentParser(description="Fetch the ONA form(s) of config/forms.csv")
    ap.add_argument("--countries", help="comma-separated ISO3 codes (default: all enabled rows)")
    ap.add_argument("--form-ids", help="comma-separated form IDs")
    ap.add_argument("--allow-shrink", action="store_true", help="accept a download with >10%% fewer records than before")
    ap.add_argument("--test", action="store_true", help="only test the token(s)")
    ap.add_argument("--base-url", help="another ONA data URL")
    args = ap.parse_args()
    global BASE_URL
    if args.base_url:
        BASE_URL = args.base_url.rstrip("/")

    src = load_secrets_env(HERE)
    print(f"Secrets file: {'config/' + src if src else 'none found (using environment variables only)'}")
    rows = [r for r in read_forms() if r["enabled"]]
    if args.countries:
        want = {c.strip().upper() for c in args.countries.split(",")}
        rows = [r for r in rows if r["iso3"].upper() in want]
    if args.form_ids:
        want_ids = {int(x) for x in args.form_ids.split(",")}
        rows = [r for r in rows if r["form_id"] in want_ids]
    if not rows:
        sys.exit("[ERROR] No enabled form matches in config/forms.csv")

    # one token per row -- the variable named in token_env, nothing else
    ok_tokens, results = {}, []
    for r in rows:
        env = r["token_env"].strip()
        tok = os.environ.get(env, "").strip()
        if not tok:
            print(f"[SKIPPED] {r['country']} form {r['form_id']}: {env} is not set "
                  f"(add it to config/secrets.env). No other token is used for this country.")
            results.append({"iso3": r["iso3"], "form_id": r["form_id"], "status": "failed", "reason": f"{env} not set"})
            continue
        if env not in ok_tokens:
            ok_tokens[env] = test_token(env, tok)
        if not ok_tokens[env]:
            results.append({"iso3": r["iso3"], "form_id": r["form_id"], "status": "failed", "reason": f"{env} rejected"})
            continue
        r["_token"] = tok
    if args.test:
        sys.exit(0 if ok_tokens and all(ok_tokens.values()) and len(results) == 0 else 1)

    for r in rows:
        if "_token" not in r:
            continue
        stem = f"{r['iso3']}_{r['form_id']}"
        meta = RAW_DIR / f"{stem}_metadata.json"
        prev = None
        if meta.exists():
            try:
                prev = json.load(open(meta)).get("records")
            except (OSError, ValueError):
                prev = None
        have_old = (RAW_DIR / f"{stem}.parquet").exists()
        print(f"\n--- {r['country']} / form {r['form_id']} ({r['name']}) ---")
        try:
            records = fetch_all(r["form_id"], r["_token"])
        except FetchError as e:
            print(f"[FAILED] not refreshed: {e}." + (" Existing file kept." if have_old else ""))
            results.append({"iso3": r["iso3"], "form_id": r["form_id"], "status": "failed", "reason": str(e)})
            continue
        if not records:
            msg = "returned no records" if have_old else "has no records on ONA yet"
            print(f"[{'FAILED' if have_old else 'EMPTY'}] form {r['form_id']} {msg}.")
            results.append({"iso3": r["iso3"], "form_id": r["form_id"],
                            "status": "failed" if have_old else "empty", "reason": msg})
            continue
        if prev is not None and len(records) < int(prev) * SHRINK_TOLERANCE and not args.allow_shrink:
            print(f"[KEPT OLD] ONA returned {len(records)} records, the file on disk has {prev}. Not replaced "
                  f"(use --allow-shrink if records were really deleted).")
            results.append({"iso3": r["iso3"], "form_id": r["form_id"], "status": "kept_old",
                            "reason": f"{len(records)} < {prev}"})
            continue
        try:
            save(r, records, prev)
            results.append({"iso3": r["iso3"], "form_id": r["form_id"], "status": "success",
                            "records": len(records), "previous_records": prev})
        except Exception as e:  # noqa: BLE001
            try:
                (RAW_DIR / f"{stem}.parquet.tmp").unlink()
            except OSError:
                pass
            print(f"[FAILED] could not be saved: {e}")
            results.append({"iso3": r["iso3"], "form_id": r["form_id"], "status": "failed", "reason": f"save error: {e}"})

    RAW_DIR.mkdir(parents=True, exist_ok=True)
    with open(RAW_DIR / "fetch_summary.json", "w") as f:
        json.dump({"timestamp": datetime.now().isoformat(), "results": results}, f, indent=2)
    ok = sum(x["status"] == "success" for x in results)
    bad = [x for x in results if x["status"] in ("failed", "kept_old")]
    print(f"\nRefreshed {ok}/{len(rows)} form(s).")
    for x in bad:
        print(f"[WARN] {x['iso3']} form {x['form_id']} not refreshed ({x['status']}: {x.get('reason', '')}); "
              f"the processing steps use the older file if there is one.")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
