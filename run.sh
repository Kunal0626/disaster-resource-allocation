#!/usr/bin/env bash
#
# run.sh -- single entry point for the Disaster Resource Allocation System.
#
# Why a shell script and not just a Makefile: the credential handling below is
# the only safe way to hand a password to the mysql client, and it is easier to
# read and audit in shell than in make syntax. The Makefile delegates here so
# that `make test` and `./run.sh test` can never drift apart.
#
# Usage: ./run.sh <target>
#   check    verify server access and that every SQL feature this project needs
#            is actually supported by the server you are pointed at
#   docs     grammar-check the Mermaid diagrams in docs/ (no database needed)
#   schema   (re)create the schema
#   seed     load sample data
#   reset    drop and rebuild everything, then seed
#   test     run the test suite
#   demo     run the end-to-end worked demo
#   shell    open an interactive mysql shell on the project database

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

# ---------------------------------------------------------------------------
# Credentials
#
# We never put the password on a command line. Anything passed as `-pSECRET`
# is visible to every user on the machine via `ps`, and MySQL warns about it.
# Instead we copy .env into a 0600 temp file in MySQL's own defaults format
# and pass --defaults-extra-file. The temp file is removed on exit, including
# on error or Ctrl-C, by the trap below.
# ---------------------------------------------------------------------------

DRA_MYSQL_USER=""; DRA_MYSQL_PASSWORD=""; DRA_MYSQL_HOST=""
DRA_MYSQL_PORT=""; DRA_MYSQL_DB=""; MYSQL_BIN="${MYSQL_BIN:-}"

load_env() {
  if [[ ! -f .env ]]; then
    cat >&2 <<'MSG'
error: .env not found.

  cp .env.example .env && chmod 600 .env

then edit it with your MySQL user and password. .env is git-ignored.
MSG
    exit 1
  fi

  # Parse KEY=VALUE literally rather than `source`-ing the file. Sourcing would
  # execute whatever is in .env, and would mangle passwords containing $, ` or \.
  local line key value
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "${line// }" ]] && continue          # blank
    [[ "${line#"${line%%[![:space:]]*}"}" == \#* ]] && continue   # comment
    [[ "$line" != *=* ]] && continue
    key="${line%%=*}"
    value="${line#*=}"
    key="${key//[[:space:]]/}"
    # Strip one layer of matching quotes, if present.
    if [[ "$value" == \"*\" && ${#value} -ge 2 ]]; then value="${value:1:${#value}-2}"
    elif [[ "$value" == \'*\' && ${#value} -ge 2 ]]; then value="${value:1:${#value}-2}"
    fi
    case "$key" in
      DRA_MYSQL_USER|DRA_MYSQL_PASSWORD|DRA_MYSQL_HOST|DRA_MYSQL_PORT|DRA_MYSQL_DB|MYSQL_BIN)
        printf -v "$key" '%s' "$value" 2>/dev/null || declare -g "$key=$value" ;;
      *) ;;   # ignore unknown keys rather than failing: .env may hold other things
    esac
  done < .env

  : "${DRA_MYSQL_HOST:=127.0.0.1}"
  : "${DRA_MYSQL_PORT:=3306}"
  : "${DRA_MYSQL_DB:=disaster_relief}"

  local missing=()
  [[ -z "$DRA_MYSQL_USER" ]] && missing+=(DRA_MYSQL_USER)
  [[ -z "$DRA_MYSQL_PASSWORD" ]] && missing+=(DRA_MYSQL_PASSWORD)
  if (( ${#missing[@]} )); then
    echo "error: .env is missing: ${missing[*]}" >&2
    exit 1
  fi
}

find_mysql() {
  if [[ -n "$MYSQL_BIN" ]]; then
    [[ -x "$MYSQL_BIN" ]] || { echo "error: MYSQL_BIN=$MYSQL_BIN is not executable" >&2; exit 1; }
    return
  fi
  if command -v mysql >/dev/null 2>&1; then MYSQL_BIN="$(command -v mysql)"; return; fi
  local candidate
  for candidate in /usr/local/mysql/bin/mysql \
                   /usr/local/mysql-*/bin/mysql \
                   /opt/homebrew/opt/mysql/bin/mysql \
                   /usr/bin/mysql; do
    [[ -x "$candidate" ]] && { MYSQL_BIN="$candidate"; return; }
  done
  echo "error: mysql client not found. Set MYSQL_BIN in .env." >&2
  exit 1
}

DEFAULTS_FILE=""

# An EXIT trap's final exit status REPLACES the script's own. If the last
# command in here returns non-zero -- which a failed [[ ... ]] test does --
# every failure would be reported to make as a success. Hence the explicit
# `return 0`.
cleanup() {
  if [[ -n "$DEFAULTS_FILE" ]]; then
    rm -f "$DEFAULTS_FILE"
    rmdir "$(dirname "$DEFAULTS_FILE")" 2>/dev/null || true
  fi
  return 0
}
trap cleanup EXIT INT TERM

write_defaults_file() {
  local dir
  dir="$(mktemp -d "${TMPDIR:-/tmp}/dra.XXXXXX")"
  DEFAULTS_FILE="$dir/client.cnf"
  ( umask 077; : > "$DEFAULTS_FILE" )   # create 0600 before anything is written
  {
    printf '[client]\n'
    printf 'user=%s\n' "$DRA_MYSQL_USER"
    printf 'password=%s\n' "$DRA_MYSQL_PASSWORD"
    printf 'host=%s\n' "$DRA_MYSQL_HOST"
    printf 'port=%s\n' "$DRA_MYSQL_PORT"
  } > "$DEFAULTS_FILE"
}

# mysql_raw: run the client with no database selected.
# mysql_db:  run it against the project database.
# Both read SQL from stdin. --defaults-extra-file must be the first argument.
mysql_raw() { "$MYSQL_BIN" "--defaults-extra-file=$DEFAULTS_FILE" "$@"; }
mysql_db()  { "$MYSQL_BIN" "--defaults-extra-file=$DEFAULTS_FILE" "$DRA_MYSQL_DB" "$@"; }

connect() { load_env; find_mysql; write_defaults_file; }

not_yet() {
  echo "error: '$1' is not built yet. It arrives in Phase $2." >&2
  echo "       See the Roadmap in README.md for what exists today." >&2
  exit 2
}

# ---------------------------------------------------------------------------
# Targets
# ---------------------------------------------------------------------------

target_check() {
  connect
  echo "==> client:  $MYSQL_BIN"
  echo "==> connect: $DRA_MYSQL_USER@$DRA_MYSQL_HOST:$DRA_MYSQL_PORT"
  echo

  if ! mysql_raw --connect-timeout=10 -e "SELECT 1" >/dev/null 2>/tmp/dra_connect_err; then
    echo "FAIL: could not connect." >&2
    sed 's/^/       /' /tmp/dra_connect_err >&2
    rm -f /tmp/dra_connect_err
    exit 1
  fi
  rm -f /tmp/dra_connect_err

  echo "--- server settings ------------------------------------------------"
  mysql_raw --table <<'SQL'
SELECT VARIABLE_NAME AS setting, VARIABLE_VALUE AS value
FROM performance_schema.global_variables
WHERE VARIABLE_NAME IN (
  'version','version_comment','default_storage_engine','sql_mode',
  'transaction_isolation','innodb_lock_wait_timeout','autocommit',
  'character_set_server','collation_server','lower_case_table_names',
  'log_bin','log_bin_trust_function_creators','max_connections',
  'innodb_deadlock_detect','innodb_buffer_pool_size'
)
ORDER BY VARIABLE_NAME;
SQL
  echo
  echo "--- current session ------------------------------------------------"
  mysql_raw --table -e "SELECT CURRENT_USER() AS effective_user, @@hostname AS host_name;"
  echo
  echo "--- feature probe --------------------------------------------------"
  echo "    (uses a scratch database, dra_probe_tmp, and drops it afterwards)"
  echo

  # The probe is run tolerantly: if a statement aborts the script we still want
  # to print whatever was recorded, because the missing sentinel row plus the
  # client's own error message is how we find out what the server refused.
  local probe_status=0
  mysql_raw < tools/capabilities.sql || probe_status=$?

  mysql_raw --table -e "SELECT seq, feature, verdict, detail FROM dra_probe_tmp.probe_result ORDER BY seq;"

  local failures completed
  failures=$(mysql_raw -N -B -e \
    "SELECT COUNT(*) FROM dra_probe_tmp.probe_result WHERE verdict <> 'PASS';")
  completed=$(mysql_raw -N -B -e \
    "SELECT COUNT(*) FROM dra_probe_tmp.probe_result WHERE feature = 'probe_completed';")

  mysql_raw -e "DROP DATABASE IF EXISTS dra_probe_tmp;"

  echo
  if [[ "$completed" != "1" ]]; then
    echo "RESULT: INCOMPLETE -- the probe script stopped early (exit $probe_status)."
    echo "        The error above names the statement the server refused."
    return 1
  fi
  if [[ "$failures" != "0" ]]; then
    echo "RESULT: $failures probe(s) FAILED. Phase 2 should not start until these pass."
    return 1
  fi
  echo "RESULT: all probes PASS. This server supports everything the project needs."
}

# Checks the ER diagram in the docs against the Mermaid erDiagram grammar.
# Needs no database, so it is useful before any .env exists. It is a grammar
# check, NOT a render: it catches the mistakes that make GitHub show an error
# box, but it does not prove the picture looks right.
target_docs() {
  python3 -I tools/check_mermaid.py docs/*.md
}

target_schema() { not_yet schema 2; }
target_seed()   { not_yet seed 3; }
target_reset()  { not_yet reset 3; }
target_test()   { not_yet test 2; }
target_demo()   { not_yet demo 8; }

target_shell() {
  connect
  exec mysql_db
}

usage() {
  # Print the "Usage:" block from this file's own header comment, so the help
  # text and the real target list cannot drift apart.
  sed -n '/^# Usage: /,/^$/p' "$0" | sed 's/^#\{1,\} \{0,1\}//;s/^#$//'
  exit 1
}

main() {
  local target="${1:-}"
  case "$target" in
    check)  target_check ;;
    docs)   target_docs ;;
    schema) target_schema ;;
    seed)   target_seed ;;
    reset)  target_reset ;;
    test)   target_test ;;
    demo)   target_demo ;;
    shell)  target_shell ;;
    ""|-h|--help|help) usage ;;
    *) echo "error: unknown target '$target'" >&2; echo >&2; usage ;;
  esac
}

main "$@"
