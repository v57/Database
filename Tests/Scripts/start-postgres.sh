#!/usr/bin/env bash
# Starts a local PostgreSQL that matches the Database test-suite config
# (the docker-compose postgres:18 service):
#   user postgres / password postgres / database postgres
#   listen 127.0.0.1:5432, scram-sha-256 auth (bad passwords are REJECTED)
#
# Uses an ISOLATED data dir so it never touches your Homebrew cluster
# (/opt/homebrew/var/postgresql@18, which is trust-auth + superuser "v57").
#
# Usage:
#   Tests/Scripts/start-postgres.sh          # init (first run) + start + wait
#   Tests/Scripts/start-postgres.sh stop     # stop the server
#   PGDATA=/custom/dir Tests/Scripts/start-postgres.sh   # override data dir
#
# Idempotent: safe to run repeatedly; already-running reports and exits 0.

set -euo pipefail

PGDATA="${PGDATA:-$HOME/.local/share/database-postgres}"
PORT="${PORT:-5432}"
LOG="$PGDATA/server.log"

# --- stop ---------------------------------------------------------------
if [[ "${1:-start}" == "stop" ]]; then
  if pg_ctl -D "$PGDATA" status >/dev/null 2>&1; then
    pg_ctl -D "$PGDATA" stop -m fast
    echo "stopped (PGDATA=$PGDATA)"
  else
    echo "not running (PGDATA=$PGDATA)"
  fi
  exit 0
fi

# --- already running? (read our own PID file, not the port) --------------
if pg_ctl -D "$PGDATA" status >/dev/null 2>&1; then
  echo ">> already running: postgres://postgres:postgres@127.0.0.1:$PORT/postgres"
  echo ">> (logs: $LOG)"
  exit 0
fi

# --- port conflict guard (a DIFFERENT server owns the port) --------------
if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "ERROR: 127.0.0.1:$PORT is taken by a process that is NOT this cluster." >&2
  lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >&2
  echo "(stop it first, or set PORT= to a free port: PORT=5433 Tests/Scripts/start-postgres.sh)" >&2
  exit 1
fi

# --- init on first run ---------------------------------------------------
# Key off PG_VERSION (a real initialized cluster) not mere directory presence,
# so a stray file from a previously-aborted run doesn't block initdb.
if [[ ! -f "$PGDATA/PG_VERSION" ]]; then
  rm -rf "$PGDATA"                      # wipe any half-initialized stash
  echo ">> initdb superuser=postgres with scram-sha-256 auth at: $PGDATA"
  mkdir -p "$(dirname "$PGDATA")"
  pwfile="$(mktemp)"                   # password file lives OUTSIDE the data dir
  printf 'postgres\n' > "$pwfile"
  initdb -D "$PGDATA" -U postgres -A scram-sha-256 --pwfile="$pwfile" \
    --encoding=UTF8 >/dev/null
  rm -f "$pwfile"
  echo ">> initialized."
else
  echo ">> using existing data dir: $PGDATA"
fi

# --- start --------------------------------------------------------------
echo ">> starting on 127.0.0.1:$PORT"
pg_ctl -D "$PGDATA" \
  -o "-c listen_addresses=127.0.0.1 -c port=$PORT" \
  -l "$LOG" start >/dev/null

# --- wait until it accepts connections -----------------------------------
echo ">> waiting for server..."
for _ in $(seq 1 30); do
  if pg_isready -h 127.0.0.1 -p "$PORT" -U postgres >/dev/null 2>&1; then
    echo ">> ready: postgres://postgres:postgres@127.0.0.1:$PORT/postgres"
    echo ">> (logs: $LOG)"
    exit 0
  fi
  sleep 1
done
echo "ERROR: server did not become ready; see $LOG" >&2
exit 1
