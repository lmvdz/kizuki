#!/usr/bin/env bash
# Companion to issue-454-measure.sh: runs exactly one stop/resume cycle
# against an EXISTING box id, with the identical measurement logic. Written
# to resume manual measurement against a box that already exists after the
# main script's background process was interrupted mid-run (see the
# session report) -- reuses the same box rather than creating a new one,
# to respect the account's 25-starts/hour rate limit.
#
# Usage:
#   deploy/proof/issue-454-cycle-once.sh <box-api-key-file> <box-id> <cycle-label>
set -uo pipefail

API_BASE="https://ascii.dev/api/box/v1"
BOX_API_KEY_FILE="$1"
BOX_ID="$2"
LABEL="${3:-N}"
BOX_API_KEY="$(cat -- "$BOX_API_KEY_FILE")"

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
cmd_stdout() {
  local raw
  raw="$(sed -n 's/.*"stdout":"\(.*\)","stderr".*/\1/p' | sed 's/\\"/"/g')"
  while [ "${raw: -2}" = '\n' ]; do
    raw="${raw%\\n}"
  done
  printf '%s' "$raw"
}
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}
exec_kizuki() {
  local box="$1" cmd="$2" full escaped
  full="cd /home/user/kizuki-src/deploy && docker compose exec -T kizuki sh -c '${cmd}' 2>&1"
  escaped="$(json_escape "$full")"
  api POST "/boxes/$box/commands" "{\"command\":\"$escaped\"}" | cmd_stdout
}
box_state() { api GET "/boxes/$1" | json_str state; }
box_vault_id() { exec_kizuki "$1" "cat /vault/.kizuki/vault-id 2>/dev/null || echo MISSING"; }
box_event_count() { exec_kizuki "$1" "kizuki doctor --vault /vault 2>/dev/null | grep -o \"events=[0-9]*\""; }
box_ledger_stat() { exec_kizuki "$1" "stat -c size=%s,inode=%i /vault/.kizuki/kizuki.db 2>&1 || echo STAT_FAILED"; }
box_mount_state() { exec_kizuki "$1" "grep \" /vault \" /proc/mounts || echo NOT_IN_PROC_MOUNTS"; }
box_kizuki_uptime() {
  api POST "/boxes/$1/commands" \
    '{"command":"cd /home/user/kizuki-src/deploy && docker compose ps kizuki --format \"{{.Status}}\" 2>&1"}' \
    | cmd_stdout
}
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
        api POST "/boxes/$box/commands" '{"command":"docker rm -f deploy-tailscale-1 deploy-kizuki-1 2>/dev/null || true"}' >/dev/null
        sleep 3; continue ;;
    esac
    case "$up_resp" in
      *Conflict*)
        api POST "/boxes/$box/commands" '{"command":"docker rm -f deploy-tailscale-1 deploy-kizuki-1 2>/dev/null || true"}' >/dev/null
        sleep 3; continue ;;
    esac
    running_count="$(api POST "/boxes/$box/commands" \
      '{"command":"cd /home/user/kizuki-src/deploy && docker compose ps --status running -q | wc -l"}' | cmd_stdout)"
    [ "$running_count" = "2" ] && return 0
    sleep 3
  done
  return 1
}
is_archived() { [ "$1" = "archived" ]; }
is_usable() { case "$1" in idle|running|ready) return 0 ;; *) return 1 ;; esac; }
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

cycle="$LABEL"
before_stat="$(box_ledger_stat "$BOX_ID")"
before_vault_id="$(box_vault_id "$BOX_ID")"
before_count="$(box_event_count "$BOX_ID")"
echo "CYCLE $cycle before-stop: ledger_stat=[$before_stat] vault_id=[$before_vault_id] events=[$before_count]"

stop_resp="$(api POST "/boxes/$BOX_ID/stop" '{}')"
case "$stop_resp" in
  *'"ok":true'*) ;;
  *) echo "CYCLE $cycle RESULT: FAIL - stop did not report ok:true: $stop_resp"; exit 1 ;;
esac
stop_state="$(wait_for_state "$BOX_ID" is_archived)"
echo "CYCLE $cycle stop: reached state=$stop_state"
[ "$stop_state" = "archived" ] || { echo "CYCLE $cycle RESULT: FAIL - did not reach archived (last: $stop_state)"; exit 1; }

resume_resp="$(api POST "/boxes/$BOX_ID/resume" '{}')"
case "$resume_resp" in
  *'"ok":true'*) ;;
  *) echo "CYCLE $cycle RESULT: FAIL - resume did not report ok:true: $resume_resp"; exit 1 ;;
esac
resume_state="$(wait_for_state "$BOX_ID" is_usable)"
echo "CYCLE $cycle resume: reached state=$resume_state"
is_usable "$resume_state" || { echo "CYCLE $cycle RESULT: FAIL - did not become usable (last: $resume_state)"; exit 1; }

bring_up_compose "$BOX_ID"
echo "CYCLE $cycle bring_up_compose exit=$?"

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
