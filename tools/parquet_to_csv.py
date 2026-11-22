"""
parquet_to_csv.py   Author: Gorgui Ba Toure
Used by the R steps when the R package 'arrow' is not installed: writes the wanted columns of a parquet file to CSV.
Usage: python tools/parquet_to_csv.py <in.parquet> <out.csv> col1,col2,...
Columns that do not exist in the file are skipped (the R side fills them with NA).
"""
import sys

import pyarrow.parquet as pq

src, dst, wanted = sys.argv[1], sys.argv[2], sys.argv[3].split(",")
names = pq.ParquetFile(src).schema.names
cols = [c for c in wanted if c in names]
pq.read_table(src, columns=cols).to_pandas().to_csv(dst, index=False, encoding="utf-8")
print(f"wrote {len(cols)} of {len(wanted)} requested columns")
