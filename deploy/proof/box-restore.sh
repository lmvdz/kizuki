#!/usr/bin/env bash
# Backup/restore disaster-recovery finish line: prove that a customer whose
# box dies can get their vault back on a new one, through the public
# `kizuki export` / `kizuki restore` seam only. Not CI-runnable: it
# provisions and deletes real Box VMs (box.ascii.dev) and bills per second,
# the same as deploy/proof/box.sh, whose helper conventions (api(),
# json_str(), cmd_stdout(), cmd_success(), cmd_stderr(), the fixtures
# consent-grant policy) this script matches deliberately. It provisions two
# boxes in sequence -- box A is genuinely destroyed before box B ever reads
# its data -- rather than one, which is why this is a separate script and
# not a numbered check inside box.sh: see the "Why a separate script"
# section of docs/deploy-box-tailscale.md for the argument.
#
# Usage:
#   deploy/proof/box-restore.sh <box-api-key-file> <ts-authkey-file> [ttl-seconds]
#
# Prints one `PASS <n> <label>`, `FAIL <n> <label> <reason>` or
# `BLOCKED <n> <label> <reason>` line per check, does not stop at the first
# failure, and exits non-zero if anything failed or was blocked. Every box
# this run creates is deleted before it exits, success or failure, and the
# fleet is confirmed empty at the end (printed, not asserted as a numbered
# check -- same rationale as box.sh).
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
API_BASE="https://ascii.dev/api/box/v1"
BOOTSTRAP="$ROOT/deploy/box/bootstrap.sh"

# Finding (2026-09-06): every `docker compose` invocation on a box -- not
# only `up` -- re-parses deploy/compose.yml, whose top-level `secrets:`
# block interpolates `${KIZUKI_TS_AUTHKEY_FILE:?...}`. Any invocation that
# does not set this variable fails closed with "required variable
# KIZUKI_TS_AUTHKEY_FILE is missing a value", even against an already
# healthy stack (reproduced directly with a bare `docker compose exec ...
# curl 127.0.0.1:8787/health` against a box whose build+up had just
# finished cleanly). deploy/box/bootstrap.sh's own `wait_health` and
# deploy/proof/box.sh's `bring_up_compose`/`box_vault_id`/`box_event_count`
# omit it on every call except their own `up -d`, so bootstrap.sh's health
# check -- and by the same cause, box.sh's 3.2/3.3 -- cannot currently pass
# against this exact head; see this run's own report for the reproduction.
# This script never omits it: every `docker compose` call below goes
# through compose(), which always sets it, and this script never trusts
# bootstrap.sh's own exit code for the reason above -- see provision_box().
AUTHKEY_ENV="KIZUKI_TS_AUTHKEY_FILE=/home/user/.config/kizuki/ts-authkey"

usage() {
  echo "usage: $0 <box-api-key-file> <ts-authkey-file> [ttl-seconds]" >&2
  exit 2
}
[ $# -ge 2 ] || usage
BOX_API_KEY_FILE="$1"
TS_AUTHKEY_FILE="$2"
TTL_SECONDS="${3:-1800}"
BOX_API_KEY="$(cat -- "$BOX_API_KEY_FILE")"

STATE_DIR="$(mktemp -d)"
ANY_FAIL=0
CREATED_BOXES=""

pass() { printf 'PASS %s %s\n' "$1" "$2"; }
fail() { printf 'FAIL %s %s %s\n' "$1" "$2" "$3"; ANY_FAIL=1; }
blocked() { printf 'BLOCKED %s %s %s\n' "$1" "$2" "$3"; ANY_FAIL=1; }

api() {
  local method="$1" path="$2" data="${3:-}"
  if [ -n "$data" ]; then
    curl -sS -X "$method" -H "Authorization: Bearer $BOX_API_KEY" -H "Content-Type: application/json" \
      --data-binary "$data" "$API_BASE$path"
  else
    curl -sS -X "$method" -H "Authorization: Bearer $BOX_API_KEY" "$API_BASE$path"
  fi
}
json_str() { sed -n "s/.*\"$1\":\"\\([^\"]*\\)\".*/\\1/p" | head -1; }

# Same double-escaping fix as box.sh's identical helper (see its own
# comment): a command's stdout is JSON-embedded with literal `\"` for a
# real quote and a trailing literal `\n` for a real trailing newline, never
# run through a real JSON decoder.
cmd_stdout() {
  local raw
  raw="$(sed -n 's/.*"stdout":"\(.*\)","stderr".*/\1/p' | sed 's/\\"/"/g')"
  while [ "${raw: -2}" = '\n' ]; do
    raw="${raw%\\n}"
  done
  printf '%s' "$raw"
}
cmd_stderr() {
  local raw
  raw="$(sed -n 's/.*"stderr":"\(.*\)","stdoutTruncated".*/\1/p' | sed 's/\\"/"/g')"
  while [ "${raw: -2}" = '\n' ]; do
    raw="${raw%\\n}"
  done
  printf '%s' "$raw"
}
cmd_success() { sed -n 's/.*"success":\([a-z]*\).*/\1/p' | head -1; }
cmd_truncated() { sed -n 's/.*"stdoutTruncated":\([a-z]*\).*/\1/p' | head -1; }

# run BOX CMD -- runs a plain host-level command (no compose wrapper) on
# the box and prints the full commands-endpoint JSON response.
run() {
  local box="$1" cmd="$2"
  local escaped
  escaped="$(printf '%s' "$cmd" | sed 's/\\/\\\\/g; s/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')"
  api POST "/boxes/$box/commands" "{\"command\":\"$escaped\"}"
}

# compose BOX SUBCOMMAND -- runs `docker compose <SUBCOMMAND>` from the
# deploy directory with the secrets env var always set (see AUTHKEY_ENV
# above), and prints the full commands-endpoint JSON response.
compose() {
  local box="$1" sub="$2"
  run "$box" "cd /home/user/kizuki-src/deploy && $AUTHKEY_ENV docker compose $sub"
}

# Finding (2026-09-06): neither direction of `docker cp` works against this
# container. Reading out (`docker cp box:/tmp/x host-path`) fails with
# "Could not find the file" for anything under /tmp, even a file `docker
# compose exec` just created and can `cat` back successfully -- Docker's
# copy-out path resolves a container's files through its image/graph-driver
# layers, and a tmpfs mount (compose.yml's `tmpfs: [/tmp]`, this read-only-
# rootfs container's only writable path besides the named `/vault` volume)
# is not part of that view. Writing in (`docker cp host-path box:/tmp/x`)
# fails outright with "container rootfs is marked read-only", regardless of
# the destination being a writable tmpfs mount, because the daemon's own
# check is on the container's `read_only` flag, not the target mount.
# `/vault` itself round-trips fine through `docker cp` (also confirmed
# directly), but `kizuki export`'s own `assertSeparated`
# (packages/core/src/export.ts) correctly refuses a destination inside the
# vault it is exporting, so it is not a usable relay either. The Box
# `files` endpoint (`PUT|GET /boxes/{id}/files`) only ever reaches the
# box's own host filesystem, one hop short of a path docker cp can use.
#
# The one channel that reaches inside this container from outside without
# any of the above is the `commands` endpoint's own request body and
# stdout, exactly as bootstrap.sh and box.sh already use it to place the
# consent policy JSON (see check_2's `printf %s $policy_b64 | base64 -d`
# below) -- proven at this script's own working scale (an 8000-byte base64
# payload round-tripped byte-for-byte through both a request body and a
# stdout read, sha256-verified directly against this exact API). Both
# helpers below move bytes exclusively that way; the export bundle here is
# three short markdown fixtures, nowhere near a size where the commands
# endpoint's response truncation (`stdoutTruncated`, checked below) would
# ever trigger.

# tar_b64_from BOX DIR -- tars+gzips DIR inside BOX's kizuki container and
# returns it as a base64 string read straight off the command's own
# stdout. Empty (and a printed diagnostic) if the read was truncated.
tar_b64_from() {
  local box="$1" dir="$2" resp truncated stdout
  resp="$(compose "$box" "exec -T kizuki sh -c 'tar -C $dir -cz . | base64 -w0'")"
  truncated="$(printf '%s' "$resp" | cmd_truncated)"
  if [ "$truncated" = "true" ]; then
    echo "  tar_b64_from: stdout was truncated reading $dir" >&2
    return 1
  fi
  stdout="$(printf '%s' "$resp" | cmd_stdout)"
  [ -n "$stdout" ] || return 1
  printf '%s' "$stdout"
}

# untar_b64_into BOX B64_CONTENT DIR -- writes B64_CONTENT (already a
# base64 string) into BOX's kizuki container, decodes and untars it into
# DIR (created if needed). B64_CONTENT travels embedded directly in the
# command's own request body, exactly like check_2's policy_b64 -- safe
# because base64's alphabet has no shell metacharacter in it.
untar_b64_into() {
  local box="$1" b64="$2" dir="$3"
  compose "$box" "exec -T kizuki sh -c 'mkdir -p $dir && printf %s $b64 | base64 -d | tar -C $dir -xz'" >/dev/null
}

box_vault_id() {
  compose "$1" "exec -T kizuki cat /vault/.kizuki/vault-id 2>/dev/null || true" | cmd_stdout | head -c 200
}
restored_vault_id() {
  compose "$1" "exec -T kizuki cat $2/.kizuki/vault-id 2>/dev/null || true" | cmd_stdout | head -c 200
}

delete_all_created() {
  local box
  for box in $CREATED_BOXES; do
    curl -sS -X DELETE -H "Authorization: Bearer $BOX_API_KEY" -H "X-Ascii-Confirm-Delete: $box" \
      "$API_BASE/boxes/$box" >/dev/null 2>&1 || true
  done
}
trap delete_all_created EXIT

# provision_box RUN_STATE_DIR -> echoes "box_id elapsed_seconds" on success,
# nonzero return on failure. Calls bootstrap.sh with
# KIZUKI_BOX_KEEP_ON_FAILURE=1 and never trusts its exit code -- only its
# side effects (a box created, the deploy tree cloned, compose built and
# brought up) -- for the reason recorded in the AUTHKEY_ENV comment above:
# bootstrap.sh's own wait_health always reports failure, box or no box, so
# treating its exit code as ground truth would either wrongly delete a
# healthy box (without KEEP_ON_FAILURE) or wrongly declare success from an
# exit code alone (this script does neither: it reads the box id bootstrap
# itself recorded, then runs its own health check with AUTHKEY_ENV set).
provision_box() {
  local run_state_dir="$1" start end elapsed box_id waited=0 health
  mkdir -p "$run_state_dir"
  start="$(date +%s)"
  KIZUKI_BOX_KEEP_ON_FAILURE=1 "$BOOTSTRAP" "$BOX_API_KEY_FILE" "$TS_AUTHKEY_FILE" "$TTL_SECONDS" "$run_state_dir" \
    > "$run_state_dir/bootstrap.log" 2>&1
  box_id="$(cat -- "$run_state_dir/box-id" 2>/dev/null || true)"
  [ -n "$box_id" ] || return 1
  CREATED_BOXES="$CREATED_BOXES $box_id"
  while [ "$waited" -lt 180 ]; do
    health="$(compose "$box_id" "exec -T kizuki curl -fsS 127.0.0.1:8787/health" | cmd_stdout)"
    case "$health" in
      *'"ok":true'*) break ;;
    esac
    sleep 3
    waited=$((waited + 3))
  done
  case "$health" in
    *'"ok":true'*) ;;
    *) return 1 ;;
  esac
  end="$(date +%s)"
  elapsed=$((end - start))
  printf '%s %s' "$box_id" "$elapsed"
}

FIXTURES_POLICY='{"purposes":["capture","recall","session","correction","audit","derive","extract","export"],"allowed_fields":["text","subjects","attachments","metadata"],"retention":"persistent_owned_until_revoked","egress":"local_only","sensitivity_floor":"private"}'

# ---- Box A: seed the vault that will be lost -------------------------

BOX_A=""
A_ELAPSED=""
check_1_provision_a() {
  local out
  out="$(provision_box "$STATE_DIR/a")"
  if [ -z "$out" ]; then
    fail 1 provision-box-a "bootstrap did not produce a healthy box within budget; see $STATE_DIR/a/bootstrap.log"
    return 1
  fi
  BOX_A="${out%% *}"
  A_ELAPSED="${out#* }"
  pass 1 provision-box-a
  echo "  box_a=$BOX_A elapsed=${A_ELAPSED}s" >&2
}

check_2_import_with_consent() {
  if [ -z "$BOX_A" ]; then
    blocked 2 import-with-consent "box A was not provisioned"
    return
  fi
  local refuse_resp refuse_success refuse_stderr
  refuse_resp="$(compose "$BOX_A" "exec -T kizuki kizuki import markdown-folder --source /fixtures --vault /vault")"
  refuse_success="$(printf '%s' "$refuse_resp" | cmd_success)"
  refuse_stderr="$(printf '%s' "$refuse_resp" | cmd_stderr)"
  if [ "$refuse_success" = "true" ]; then
    fail 2 import-with-consent "import with no grant unexpectedly succeeded"
    return
  fi
  case "$refuse_stderr" in
    *consent-required*) ;;
    *) fail 2 import-with-consent "refusal missing 'consent-required' hint: $refuse_stderr"; return ;;
  esac

  local policy_b64
  policy_b64="$(printf '%s' "$FIXTURES_POLICY" | base64 -w0)"
  compose "$BOX_A" "exec -T kizuki sh -c 'umask 077; printf %s $policy_b64 | base64 -d > /tmp/fixtures-policy.json'" >/dev/null

  local grant_resp grant_success grant_stdout
  grant_resp="$(compose "$BOX_A" "exec -T kizuki kizuki import markdown-folder --source /fixtures --vault /vault --policy /tmp/fixtures-policy.json --expected-revision 0 --operation-id proof-grant-fixtures")"
  grant_success="$(printf '%s' "$grant_resp" | cmd_success)"
  grant_stdout="$(printf '%s' "$grant_resp" | cmd_stdout)"
  if [ "$grant_success" != "true" ]; then
    fail 2 import-with-consent "granted import exited non-zero: $grant_stdout"
    return
  fi
  case "$grant_stdout" in
    *events_stored=3*) ;;
    *) fail 2 import-with-consent "granted import stdout missing events_stored=3: $grant_stdout"; return ;;
  esac
  pass 2 import-with-consent
}

# Globals this check hands to the ones that follow, all read from box A
# before it is destroyed.
BEFORE_EVENTS=""
BEFORE_CLAIMS_LINE=""
BEFORE_RECEIPTS_LINE=""
BEFORE_VAULT_ID=""
BEFORE_EVENTS_SHA=""

check_3_capture_before_record() {
  if [ -z "$BOX_A" ]; then
    blocked 3 capture-before-record "box A was not provisioned"
    return
  fi
  local doc
  doc="$(compose "$BOX_A" "exec -T kizuki kizuki doctor --vault /vault" | cmd_stdout)"
  BEFORE_EVENTS="$(printf '%s' "$doc" | grep -o 'events=[0-9]*' | head -1)"
  BEFORE_CLAIMS_LINE="$(printf '%s' "$doc" | grep -o 'claims live=[0-9]* filed=[0-9]* written=[0-9]* unwritten=[0-9]* superseded=[0-9]* skipped=[0-9]* purged=[0-9]*' | head -1)"
  BEFORE_RECEIPTS_LINE="$(printf '%s' "$doc" | grep -o 'receipts=[0-9]* orphans=[0-9]*' | head -1)"
  BEFORE_VAULT_ID="$(box_vault_id "$BOX_A")"
  if [ "$BEFORE_EVENTS" != "events=3" ] || [ -z "$BEFORE_CLAIMS_LINE" ] || [ -z "$BEFORE_RECEIPTS_LINE" ] || [ -z "$BEFORE_VAULT_ID" ]; then
    fail 3 capture-before-record "incomplete before-record (events='$BEFORE_EVENTS' claims='$BEFORE_CLAIMS_LINE' receipts='$BEFORE_RECEIPTS_LINE' vault_id='$BEFORE_VAULT_ID')"
    return
  fi
  pass 3 capture-before-record
  echo "  $BEFORE_EVENTS $BEFORE_CLAIMS_LINE $BEFORE_RECEIPTS_LINE vault_id=$BEFORE_VAULT_ID" >&2
}

LOCAL_BACKUP_B64_FILE="$STATE_DIR/backup.tar.gz.b64"
check_4_export_leaves_box_a() {
  if [ -z "$BOX_A" ]; then
    blocked 4 export-leaves-box-a "box A was not provisioned"
    return
  fi
  local export_resp export_success export_stdout
  export_resp="$(compose "$BOX_A" "exec -T kizuki kizuki export --out /tmp/dr-export --vault /vault")"
  export_success="$(printf '%s' "$export_resp" | cmd_success)"
  export_stdout="$(printf '%s' "$export_resp" | cmd_stdout)"
  if [ "$export_success" != "true" ]; then
    fail 4 export-leaves-box-a "kizuki export exited non-zero: $export_stdout"
    return
  fi

  # Content hash of something specific (brief's own phrasing): sha256 of
  # the exported ledger/events.jsonl, read while it still only exists
  # inside box A's container. Compared against the same file's hash inside
  # box B's own re-export after restore in check 7 -- a stronger claim than
  # counts alone, since it proves the restored ledger's bytes, not merely
  # its row count, match the original.
  BEFORE_EVENTS_SHA="$(compose "$BOX_A" "exec -T kizuki sha256sum /tmp/dr-export/ledger/events.jsonl" | cmd_stdout | cut -d' ' -f1)"
  if [ -z "$BEFORE_EVENTS_SHA" ]; then
    fail 4 export-leaves-box-a "could not read a sha256 for the exported events.jsonl"
    return
  fi

  # Move the export off the container and off box A entirely through the
  # commands endpoint's own stdout (see the finding above tar_b64_from --
  # neither docker cp nor the files API can reach a tmpfs path in this
  # container).
  local remote_b64
  remote_b64="$(tar_b64_from "$BOX_A" /tmp/dr-export)"
  if [ -z "$remote_b64" ]; then
    fail 4 export-leaves-box-a "could not read the export archive back off box A"
    return
  fi
  printf '%s' "$remote_b64" > "$LOCAL_BACKUP_B64_FILE"
  if [ ! -s "$LOCAL_BACKUP_B64_FILE" ]; then
    fail 4 export-leaves-box-a "downloaded backup is empty on the operator's own machine"
    return
  fi
  pass 4 export-leaves-box-a
  echo "  events.jsonl sha256=$BEFORE_EVENTS_SHA local_copy=$LOCAL_BACKUP_B64_FILE ($(wc -c < "$LOCAL_BACKUP_B64_FILE") base64 bytes)" >&2
}

check_5_box_a_destroyed() {
  if [ -z "$BOX_A" ]; then
    blocked 5 box-a-destroyed "box A was not provisioned"
    return
  fi
  curl -sS -X DELETE -H "Authorization: Bearer $BOX_API_KEY" -H "X-Ascii-Confirm-Delete: $BOX_A" \
    "$API_BASE/boxes/$BOX_A" >/dev/null
  local waited=0 listing
  while [ "$waited" -lt 60 ]; do
    listing="$(api GET /boxes)"
    case "$listing" in
      *"\"id\":\"$BOX_A\""*) ;;
      *) break ;;
    esac
    sleep 3
    waited=$((waited + 3))
  done
  case "$listing" in
    *"\"id\":\"$BOX_A\""*)
      fail 5 box-a-destroyed "box A still appears in GET /boxes after delete: $listing"
      return
      ;;
  esac
  CREATED_BOXES="$(printf '%s' "$CREATED_BOXES" | sed "s/\b$BOX_A\b//")"
  pass 5 box-a-destroyed
}

# ---- Box B: fresh box, restore-only ------------------------------------

BOX_B=""
check_6_provision_b() {
  local out
  out="$(provision_box "$STATE_DIR/b")"
  if [ -z "$out" ]; then
    fail 6 provision-box-b "bootstrap did not produce a healthy box within budget; see $STATE_DIR/b/bootstrap.log"
    return 1
  fi
  BOX_B="${out%% *}"
  pass 6 provision-box-b
  echo "  box_b=$BOX_B" >&2
}

RESTORE_SRC="/tmp/dr-restore-src"
RESTORE_SRC_READY=0
check_7_restore_into_fresh_vault() {
  if [ -z "$BOX_B" ]; then
    blocked 7 restore-into-fresh-vault "box B was not provisioned"
    return
  fi
  if [ ! -s "$LOCAL_BACKUP_B64_FILE" ]; then
    blocked 7 restore-into-fresh-vault "no backup was captured off box A (check 4)"
    return
  fi

  untar_b64_into "$BOX_B" "$(cat -- "$LOCAL_BACKUP_B64_FILE")" "$RESTORE_SRC"
  local manifest_check
  manifest_check="$(compose "$BOX_B" "exec -T kizuki test -f $RESTORE_SRC/manifest.json && echo present" | cmd_stdout)"
  if [ "$manifest_check" != "present" ]; then
    fail 7 restore-into-fresh-vault "extracted backup on box B has no manifest.json at $RESTORE_SRC; the archive did not survive transport"
    return
  fi
  # Checks 9 and 10 reuse this real, already-extracted source directory as
  # their "good backup" input (restore into a *different*, bad target); a
  # check that could only ever see an absent source would fail for the
  # wrong reason (the precondition, not the property under test), so they
  # gate on this flag rather than assuming check 7 got this far.
  RESTORE_SRC_READY=1

  local restore_resp restore_success restore_stdout
  restore_resp="$(compose "$BOX_B" "exec -T kizuki kizuki restore --from $RESTORE_SRC --into /tmp/dr-restored-vault")"
  restore_success="$(printf '%s' "$restore_resp" | cmd_success)"
  restore_stdout="$(printf '%s' "$restore_resp" | cmd_stdout)"
  if [ "$restore_success" != "true" ]; then
    fail 7 restore-into-fresh-vault "kizuki restore exited non-zero: $restore_stdout"
    return
  fi
  case "$restore_stdout" in
    *events=3*) ;;
    *) fail 7 restore-into-fresh-vault "restore report missing events=3: $restore_stdout"; return ;;
  esac
  case "$restore_stdout" in
    *doctor_invalid=0*) ;;
    *) fail 7 restore-into-fresh-vault "restore report missing doctor_invalid=0: $restore_stdout"; return ;;
  esac
  local before_claims before_receipts
  before_claims="$(printf '%s' "$BEFORE_CLAIMS_LINE" | grep -o 'live=[0-9]*' | cut -d= -f2)"
  before_receipts="$(printf '%s' "$BEFORE_RECEIPTS_LINE" | grep -o 'receipts=[0-9]*' | cut -d= -f2)"
  case "$restore_stdout" in
    *"claims=$before_claims"*) ;;
    *) fail 7 restore-into-fresh-vault "restore claims count does not match box A's before-record ($before_claims): $restore_stdout"; return ;;
  esac
  case "$restore_stdout" in
    *"receipts=$before_receipts"*) ;;
    *) fail 7 restore-into-fresh-vault "restore receipts count does not match box A's before-record ($before_receipts): $restore_stdout"; return ;;
  esac
  pass 7 restore-into-fresh-vault
  echo "  $restore_stdout" >&2
}

check_8_restored_vault_matches() {
  if [ -z "$BOX_B" ]; then
    blocked 8 restored-vault-matches "box B was not provisioned"
    return
  fi
  local restored_vault="/tmp/dr-restored-vault"
  local restored_id
  restored_id="$(restored_vault_id "$BOX_B" "$restored_vault")"
  if [ -z "$BEFORE_VAULT_ID" ] || [ "$restored_id" != "$BEFORE_VAULT_ID" ]; then
    fail 8 restored-vault-matches "restored vault_id ('$restored_id') does not equal box A's before-record ('$BEFORE_VAULT_ID')"
    return
  fi

  local doc
  doc="$(compose "$BOX_B" "exec -T kizuki kizuki doctor --vault $restored_vault" | cmd_stdout)"
  case "$doc" in
    *"status=ok"*) ;;
    *) fail 8 restored-vault-matches "restored vault doctor did not report status=ok: $doc"; return ;;
  esac
  if printf '%s' "$doc" | grep -q '^problem '; then
    fail 8 restored-vault-matches "restored vault doctor reported a page problem: $doc"
    return
  fi

  local q_resp q_stdout
  q_resp="$(compose "$BOX_B" "exec -T kizuki kizuki query acme --scope ledger --vault $restored_vault")"
  q_stdout="$(printf '%s' "$q_resp" | cmd_stdout)"
  case "$q_stdout" in
    *acme*) ;;
    *) fail 8 restored-vault-matches "restored vault's own content did not surface at query: $q_stdout"; return ;;
  esac

  # Content hash of something specific, the other half of check 4's
  # capture: re-export the restored vault and hash the same file, proving
  # the restored ledger is byte-identical to the original's, not merely
  # equal in row counts.
  compose "$BOX_B" "exec -T kizuki kizuki export --out /tmp/dr-reexport --vault $restored_vault" >/dev/null
  local after_sha
  after_sha="$(compose "$BOX_B" "exec -T kizuki sha256sum /tmp/dr-reexport/ledger/events.jsonl" | cmd_stdout | cut -d' ' -f1)"
  if [ -z "$BEFORE_EVENTS_SHA" ] || [ "$after_sha" != "$BEFORE_EVENTS_SHA" ]; then
    fail 8 restored-vault-matches "re-exported events.jsonl sha256 ('$after_sha') does not equal box A's before-record ('$BEFORE_EVENTS_SHA')"
    return
  fi
  pass 8 restored-vault-matches
  echo "  vault_id=$restored_id events.jsonl sha256=$after_sha (matches box A)" >&2
}

# ---- Negative cases: a check that can only pass proves nothing ---------

check_9_refuses_nonempty_target() {
  if [ -z "$BOX_B" ]; then
    blocked 9 refuses-nonempty-target "box B was not provisioned"
    return
  fi
  if [ "$RESTORE_SRC_READY" != "1" ]; then
    blocked 9 refuses-nonempty-target "no extracted backup at $RESTORE_SRC (check 7 did not get that far)"
    return
  fi
  compose "$BOX_B" "exec -T kizuki sh -c 'mkdir -p /tmp/dr-nonempty && touch /tmp/dr-nonempty/keep'" >/dev/null
  local resp success stderr
  resp="$(compose "$BOX_B" "exec -T kizuki kizuki restore --from $RESTORE_SRC --into /tmp/dr-nonempty")"
  success="$(printf '%s' "$resp" | cmd_success)"
  stderr="$(printf '%s' "$resp" | cmd_stderr)"
  if [ "$success" = "true" ]; then
    fail 9 refuses-nonempty-target "restore into a non-empty directory unexpectedly succeeded"
    return
  fi
  case "$stderr" in
    *empty*) ;;
    *) fail 9 refuses-nonempty-target "refusal did not mention 'empty': $stderr"; return ;;
  esac
  pass 9 refuses-nonempty-target
}

check_10_refuses_missing_manifest() {
  if [ -z "$BOX_B" ]; then
    blocked 10 refuses-missing-manifest "box B was not provisioned"
    return
  fi
  compose "$BOX_B" "exec -T kizuki sh -c 'mkdir -p /tmp/dr-no-manifest-src /tmp/dr-no-manifest-dst'" >/dev/null
  local resp success stderr
  resp="$(compose "$BOX_B" "exec -T kizuki kizuki restore --from /tmp/dr-no-manifest-src --into /tmp/dr-no-manifest-dst")"
  success="$(printf '%s' "$resp" | cmd_success)"
  stderr="$(printf '%s' "$resp" | cmd_stderr)"
  if [ "$success" = "true" ]; then
    fail 10 refuses-missing-manifest "restore from a manifest-less directory unexpectedly succeeded"
    return
  fi
  case "$stderr" in
    *manifest*) ;;
    *) fail 10 refuses-missing-manifest "refusal did not mention 'manifest': $stderr"; return ;;
  esac
  pass 10 refuses-missing-manifest
}

main() {
  check_1_provision_a
  check_2_import_with_consent
  check_3_capture_before_record
  check_4_export_leaves_box_a
  check_5_box_a_destroyed
  check_6_provision_b
  check_7_restore_into_fresh_vault
  check_8_restored_vault_matches
  check_9_refuses_nonempty_target
  check_10_refuses_missing_manifest
  echo "--- deleting every box this run created ---" >&2
  delete_all_created
  CREATED_BOXES=""
  local remaining
  remaining="$(api GET /boxes)"
  echo "fleet after cleanup: $remaining" >&2
  exit "$ANY_FAIL"
}

main
