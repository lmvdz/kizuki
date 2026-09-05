#!/usr/bin/env bash
# Measurement-only script for issue #454 ("Intermittent events=0 after
# stop/resume on a Box, with vault-id intact"). This is NOT a fix and does
# not implement one; it exists only to discriminate the issue's two
# hypotheses (genuine ledger-row loss vs. a readiness race where doctor
# reads a not-yet-mounted vault). Do not fold this into deploy/proof/box.sh:
# that proof's check 3.2 already asserts the property this script is
# measuring the *mechanism* of.
#
# This branch is based on agent/fix-lease-bootid-20260905 (commit e7ea2cd),
# not origin/main directly: the whole deploy/ tree this script depends on
# (bootstrap.sh, compose.yml, fixtures, box.sh) does not exist on
# origin/main at all -- it lives only on the deploy-* milestone branches,
# which that lane branch already merges together plus the #446/#447 fixes.
# See the session report for why "base on origin/main" could not be
# followed literally here.
#
# Reuses ONE box across every stop/resume cycle (never creates one box per
# cycle) to respect the account's 25-starts/hour rate limit -- a resume is
# not a "start" against that limit; only bootstrap's initial create and any
# later cold start would be.
#
# `bring_up_compose` below is copied verbatim from deploy/proof/box.sh on
# branch agent/fix-lease-bootid-20260905 (commit 084c3b9, unpushed at the
# time this script was written), which fixed the #446 compose-bring-up race
# this measurement would otherwise confound with the #454 symptom. Do not
# "improve" it here; if it needs a change, that belongs on the lease
# branch, not this one.
#
# Usage:
#   deploy/proof/issue-454-measure.sh <box-api-key-file> <ts-authkey-file> [cycles] [ttl-seconds]
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
API_BASE="https://ascii.dev/api/box/v1"
BOOTSTRAP="$ROOT/deploy/box/bootstrap.sh"

usage() {
  echo "usage: $0 <box-api-key-file> <ts-authkey-file> [cycles] [ttl-seconds]" >&2
  exit 2
}
[ $# -ge 2 ] || usage
BOX_API_KEY_FILE="$1"
TS_AUTHKEY_FILE="$2"
CYCLES="${3:-6}"
TTL_SECONDS="${4:-1800}"
BOX_API_KEY="$(cat -- "$BOX_API_KEY_FILE")"

STATE_DIR="$(mktemp -d)"
CREATED_BOXES=""

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

# See deploy/proof/box.sh's own cmd_stdout for why this hand-rolled decode
# exists instead of a real JSON parser.
cmd_stdout() {
  local raw
  raw="$(sed -n 's/.*"stdout":"\(.*\)","stderr".*/\1/p' | sed 's/\\"/"/g')"
  while [ "${raw: -2}" = '\n' ]; do
    raw="${raw%\\n}"
  done
  printf '%s' "$raw"
}

# JSON-string-escapes its one argument (backslash, then double quote) so a
# command containing double quotes can be embedded safely.
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

exec_kizuki() {
  # Runs one shell command inside the kizuki container via compose exec.
  # cmd is wrapped in `sh -c '...'`, so cmd itself must use double quotes,
  # never single quotes, for any internal quoting it needs.
  local box="$1" cmd="$2" full escaped
  full="cd /home/user/kizuki-src/deploy && docker compose exec -T kizuki sh -c '${cmd}' 2>&1"
  escaped="$(json_escape "$full")"
  api POST "/boxes/$box/commands" "{\"command\":\"$escaped\"}" | cmd_stdout
}

box_state() { api GET "/boxes/$1" | json_str state; }
box_vault_id() { exec_kizuki "$1" "cat /vault/.kizuki/vault-id 2>/dev/null || echo MISSING"; }
box_event_count() { exec_kizuki "$1" "kizuki doctor --vault /vault 2>/dev/null | grep -o \"events=[0-9]*\""; }
box_ledger_stat() {
  # size and inode of the ledger file itself; %s and %i are GNU coreutils
  # stat's format specifiers, present in the oven/bun base image (Debian).
  exec_kizuki "$1" "stat -c size=%s,inode=%i /vault/.kizuki/kizuki.db 2>&1 || echo STAT_FAILED"
}
box_mount_state() {
  # Whether /vault is a distinct mount at all right now (a named-volume
  # mount always shows as its own line in /proc/mounts; a container that
  # somehow started against an anonymous/ephemeral overlay path instead
  # would not). Read from /proc directly: `mount` and `mountpoint` are not
  # guaranteed present in a minimal image, but /proc/mounts is a plain file
  # read that needs no capability this cap_drop:[ALL] container lacks.
  exec_kizuki "$1" "grep \" /vault \" /proc/mounts || echo NOT_IN_PROC_MOUNTS"
}
box_kizuki_uptime() {
  # docker compose ps's own idea of how long the kizuki service has been
  # up, read from the host side (not through exec, since this asks about
  # the container itself rather than something inside it).
  api POST "/boxes/$1/commands" \
    '{"command":"cd /home/user/kizuki-src/deploy && docker compose ps kizuki --format \"{{.Status}}\" 2>&1"}' \
    | cmd_stdout
}

# ---- bring_up_compose: copied verbatim from agent/fix-lease-bootid-20260905
# (commit 084c3b9, unpushed), which fixed the #446 compose-bring-up race.
# Do not edit this copy independently of that branch.
bring_up_compose() {
  local box="$1" attempt up_resp ts_logs running_count
  for attempt in 1 2 3 4 5; do
    api POST "/boxes/$box/commands" \
      '{"command":"cd /home/user/kizuki-src/deploy && docker compose down --remove-orphans 2>&1 | tail -20"}' >/dev/null

    up_resp="$(api POST "/boxes/$box/commands" \
      '{"command":"cd /home/user/kizuki-src/deploy && KIZUKI_TS_AUTHKEY_FILE=/home/user/.config/kizuki/ts-authkey docker compose up -d 2>&1 | tail -20"}')"

    ts_logs="$(api POST "/boxes/$box/commands" \
      '{"command":"cd /home/user/kizuki-src/deploy && docker compose logs tailscale 2>&1 | tail -20"}' | cmd_stdout)"
    case "$ts_logs" in
      *'missing secret file'*)
        api POST "/boxes/$box/commands" \
          '{"command":"docker rm -f deploy-tailscale-1 deploy-kizuki-1 2>/dev/null || true"}' >/dev/null
        sleep 3
        continue
        ;;
    esac
    case "$up_resp" in
      *Conflict*)
        api POST "/boxes/$box/commands" \
          '{"command":"docker rm -f deploy-tailscale-1 deploy-kizuki-1 2>/dev/null || true"}' >/dev/null
        sleep 3
        continue
        ;;
    esac

    running_count="$(api POST "/boxes/$box/commands" \
      '{"command":"cd /home/user/kizuki-src/deploy && docker compose ps --status running -q | wc -l"}' | cmd_stdout)"
    [ "$running_count" = "2" ] && return 0
    sleep 3
  done
  return 1
}

delete_all_created() {
  local box
  for box in $CREATED_BOXES; do
    curl -sS -X DELETE -H "Authorization: Bearer $BOX_API_KEY" -H "X-Ascii-Confirm-Delete: $box" \
      "$API_BASE/boxes/$box" >/dev/null 2>&1 || true
  done
}
trap delete_all_created EXIT

is_archived() { [ "$1" = "archived" ]; }
is_usable() { case "$1" in idle|running|ready) return 0 ;; *) return 1 ;; esac; }

# $2 is the name of a predicate function (is_archived / is_usable), never a
# glob string: bash `case` alternation (`a|b|c`) is parsed at script-parse
# time, not evaluated from a runtime variable's contents, so an earlier
# version of this that tried `case "$state" in $want_pattern)` silently
# never matched multi-choice patterns. Confirmed directly: `pat='a|b';
# case x in $pat) ;; esac` does not match "a" or "b" even when $state=a.
wait_for_state() {
  local box="$1" predicate="$2" waited=0 state
  while [ "$waited" -lt 120 ]; do
    state="$(box_state "$box")"
    if "$predicate" "$state"; then echo "$state"; return 0; fi
    sleep 3; waited=$((waited + 3))
  done
  echo "$state"
  return 1
}

echo "=== issue-454 measurement: $CYCLES cycles ==="

echo "--- creating one box (bootstrap.sh) ---" >&2
BOOT_OUT="$("$BOOTSTRAP" "$BOX_API_KEY_FILE" "$TS_AUTHKEY_FILE" "$TTL_SECONDS" "$STATE_DIR/boot" 2>&1)"
BOOT_RC=$?
BOX_ID="$(printf '%s' "$BOOT_OUT" | sed -n 's/^box_id=//p')"
if [ -z "$BOX_ID" ] || [ "$BOOT_RC" -ne 0 ]; then
  echo "RESULT: BLOCKED - bootstrap.sh exited $BOOT_RC, no usable box_id. Output:" >&2
  echo "$BOOT_OUT" >&2
  exit 1
fi
CREATED_BOXES="$BOX_ID"
echo "box_id=$BOX_ID" >&2

echo "--- seeding the vault with a known event count ---" >&2
api POST "/boxes/$BOX_ID/commands" \
  '{"command":"cd /home/user/kizuki-src/deploy && docker compose exec -T kizuki kizuki import markdown-folder --source /fixtures --vault /vault"}' >/dev/null
SEED_COUNT="$(box_event_count "$BOX_ID")"
echo "seeded: $SEED_COUNT (want events=3, matching deploy/fixtures/notes' 3 files)" >&2
case "$SEED_COUNT" in
  events=3) ;;
  *) echo "RESULT: BLOCKED - seed import did not reach events=3 (got '$SEED_COUNT')" >&2; exit 1 ;;
esac
SEED_VAULT_ID="$(box_vault_id "$BOX_ID")"
echo "seed vault_id: $SEED_VAULT_ID" >&2

cycle=1
while [ "$cycle" -le "$CYCLES" ]; do
  echo "" >&2
  echo "=== CYCLE $cycle / $CYCLES ===" >&2

  before_stat="$(box_ledger_stat "$BOX_ID")"
  before_vault_id="$(box_vault_id "$BOX_ID")"
  before_count="$(box_event_count "$BOX_ID")"
  echo "CYCLE $cycle before-stop: ledger_stat=[$before_stat] vault_id=[$before_vault_id] events=[$before_count]"

  stop_resp="$(api POST "/boxes/$BOX_ID/stop" '{}')"
  case "$stop_resp" in
    *'"ok":true'*) ;;
    *) echo "CYCLE $cycle RESULT: FAIL - stop did not report ok:true: $stop_resp"; cycle=$((cycle + 1)); continue ;;
  esac
  stop_state="$(wait_for_state "$BOX_ID" is_archived)"
  echo "CYCLE $cycle stop: reached state=$stop_state"
  if [ "$stop_state" != "archived" ]; then
    echo "CYCLE $cycle RESULT: FAIL - did not reach archived after stop (last: $stop_state)"
    cycle=$((cycle + 1))
    continue
  fi

  resume_resp="$(api POST "/boxes/$BOX_ID/resume" '{}')"
  case "$resume_resp" in
    *'"ok":true'*) ;;
    *) echo "CYCLE $cycle RESULT: FAIL - resume did not report ok:true: $resume_resp"; cycle=$((cycle + 1)); continue ;;
  esac
  resume_state="$(wait_for_state "$BOX_ID" is_usable)"
  echo "CYCLE $cycle resume: reached state=$resume_state"
  case "$resume_state" in
    idle|running|ready) ;;
    *) echo "CYCLE $cycle RESULT: FAIL - did not become usable after resume (last: $resume_state)"; cycle=$((cycle + 1)); continue ;;
  esac

  bring_up_compose "$BOX_ID"
  bring_up_rc=$?
  echo "CYCLE $cycle bring_up_compose exit=$bring_up_rc"

  # Immediately, no extra sleep: the earliest possible read.
  mount1="$(box_mount_state "$BOX_ID")"
  uptime1="$(box_kizuki_uptime "$BOX_ID")"
  doctor1="$(box_event_count "$BOX_ID")"
  vaultid1="$(box_vault_id "$BOX_ID")"
  stat1="$(box_ledger_stat "$BOX_ID")"
  echo "CYCLE $cycle read1 (immediate): mount=[$mount1] kizuki_status=[$uptime1] events=[$doctor1] vault_id=[$vaultid1] ledger_stat=[$stat1]"

  sleep 6

  mount2="$(box_mount_state "$BOX_ID")"
  doctor2="$(box_event_count "$BOX_ID")"
  vaultid2="$(box_vault_id "$BOX_ID")"
  stat2="$(box_ledger_stat "$BOX_ID")"
  echo "CYCLE $cycle read2 (+6s):    mount=[$mount2] events=[$doctor2] vault_id=[$vaultid2] ledger_stat=[$stat2]"

  verdict="UNKNOWN"
  if [ "$doctor1" = "events=3" ] && [ "$doctor2" = "events=3" ]; then
    verdict="STABLE_NONZERO"
  elif [ "$doctor1" != "events=3" ] && [ "$doctor2" = "events=3" ]; then
    verdict="READINESS_RACE (read1=$doctor1 read2=$doctor2)"
  elif [ "$doctor1" = "events=0" ] && [ "$doctor2" = "events=0" ]; then
    verdict="STABLE_ZERO_SUSPECT_LOSS"
  else
    verdict="OTHER (read1=$doctor1 read2=$doctor2)"
  fi
  echo "CYCLE $cycle VERDICT: $verdict"

  cycle=$((cycle + 1))
done

echo "" >&2
echo "--- deleting the box this run created ---" >&2
delete_all_created
CREATED_BOXES=""
remaining="$(api GET /boxes)"
echo "fleet after cleanup: $remaining"
