#!/bin/zsh
# Prepares the demo data Database's screenshots (.dev/screenshots.json) open, so they never show real connections:
# starts the servers the scenes browse (docker-compose.yml), fills them with Scripts/seed-demo.py, and writes the
# demo files (files/) and connections (data/, for --data-dir) to .build/screenshots-demo, with DuckDB installed in
# data/DuckDB the way the app's Download button does it (when the release has it).
# Usage: Scripts/screenshot-demo.sh [folder]
set -euo pipefail
cd "${0:A:h}/.."
demo=${1:-.build/screenshots-demo}
mkdir -p "$demo"
demo=${demo:A}
servers=(postgres mongodb-demo redis cassandra)

docker compose --profile screenshots up -d --wait $servers

duckdb=$demo/data/DuckDB
library=Sources/DuckDBKit/DuckDBLibrary.swift
version=$(sed -n 's/^ *version: "\(.*\)",$/\1/p' $library)
if [[ $(cat $duckdb/VERSION 2>/dev/null) != $version ]]; then
  url=$(sed -n 's/^ *url: URL(string: "\(.*\)")!,$/\1/p' $library)
  sha=$(sed -n 's/^ *sha256: "\(.*\)",$/\1/p' $library)
  work=$(mktemp -d)
  if curl -fsSL "$url" -o $work/duckdb.zip; then
    [[ $(shasum -a 256 $work/duckdb.zip | cut -d' ' -f1) == $sha ]] || { print -u2 "DuckDB download doesn't match $sha"; exit 1; }
    ditto -x -k $work/duckdb.zip $work/unpacked
    mkdir -p $duckdb
    mv -f $work/unpacked/libduckdb.dylib $duckdb/
    print -n $version > $duckdb/VERSION
  else
    print -u2 "DuckDB $version isn't downloadable from $url: the demo goes without the DuckDB and Parquet files"
  fi
  rm -rf $work
fi

# The app keeps what it imported in data/Vault, keyed in secrets-dev.json, which seeding replaces.
rm -rf $demo/data/Vault
DATABASE_DUCKDB_DIR=$duckdb python3 Scripts/seed-demo.py --files $demo/files --data-dir $demo/data --servers ${(j:,:)servers}
