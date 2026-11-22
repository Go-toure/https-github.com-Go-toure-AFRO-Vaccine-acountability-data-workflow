"""
build_geo_lookup.py   Author: Gorgui Ba Toure

Builds data/lookup/geo_lookup.csv (country, iso3, state, lga) from the AFRO administrative data
(AFRO-Dash/input/AFRO_admin_data.rds or an exported CSV). The cleaning step R/03_clean_geonames.R matches the
state / LGA names written in the ONA form against this list.

Usage (from the project folder):
    python tools/build_geo_lookup.py --admin ../AFRO-Dash/input/AFRO_admin_data.rds --countries "NIGERIA=NGA"
    python tools/build_geo_lookup.py --admin admin.csv --countries "NIGERIA=NGA,ETHIOPIA=ETH"   # add a country later
Requires: pandas, and pyreadr for an .rds file.
Existing rows of other countries in geo_lookup.csv are kept.
"""
import argparse
import re
from pathlib import Path

import pandas as pd

ap = argparse.ArgumentParser()
ap.add_argument("--admin", required=True)
ap.add_argument("--countries", required=True, help='"NAME=ISO3,NAME=ISO3" with NAME as written in the admin data (upper case)')
ap.add_argument("--merge-states", default="", help='"FROM=TO;FROM2=TO2": state spellings of the admin data to merge, e.g. "FCT, ABUJA=FCT"')
ap.add_argument("--out", default="data/lookup/geo_lookup.csv")
a = ap.parse_args()

if a.admin.lower().endswith(".rds"):
    import pyreadr
    admin = list(pyreadr.read_r(a.admin).values())[0]
else:
    admin = pd.read_csv(a.admin, low_memory=False)
admin = admin[["Country", "Province", "District"]].copy()
for c in admin.columns:
    admin[c] = admin[c].astype(str).str.strip().str.upper()

merge = dict(m.split("=") for m in a.merge_states.upper().split(";") if "=" in m)
admin["Province"] = admin["Province"].replace(merge)
key = lambda x: re.sub(r"[^A-Z0-9]", "", x)  # noqa: E731
pairs = dict(p.split("=") for p in a.countries.upper().split(","))
out = []
for name, iso3 in pairs.items():
    g = admin[admin.Country == name]
    g = g[(g.Province != "") & (g.District != "") & (g.Province != "NAN") & (g.District != "NAN")]
    g = g.assign(k=g.Province.map(key) + "|" + g.District.map(key))
    # one spelling per normalised key: the most frequent one in the admin data
    g = g.groupby("k").agg(state=("Province", lambda s: s.value_counts().index[0]),
                           lga=("District", lambda s: s.value_counts().index[0])).reset_index(drop=True)
    g.insert(0, "iso3", iso3)
    g.insert(0, "country", name.title())
    out.append(g)
    print(f"{name}: {len(g)} state/LGA pairs, {g.state.nunique()} states")
new = pd.concat(out, ignore_index=True)
p = Path(a.out)
if p.exists():
    old = pd.read_csv(p, dtype=str)
    new = pd.concat([old[~old.iso3.isin(new.iso3.unique())], new], ignore_index=True)
p.parent.mkdir(parents=True, exist_ok=True)
new.sort_values(["iso3", "state", "lga"]).to_csv(p, index=False, encoding="utf-8")
print(f"wrote {p} ({len(new)} rows)")
