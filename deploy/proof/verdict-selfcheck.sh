#!/usr/bin/env bash
# Proves the terminal verdict line cannot lie.
#
# Why this exists: a proof read through a pipe loses its exit status
# (`script | tail` reports tail's status, not the script's), and `tail` can
# truncate the FAIL line that would otherwise be the only evidence. So a run
# must be judged by the PRESENCE of a success marker, never by the ABSENCE of
# a failure. That is only sound if the marker is provably absent whenever a
# check fails -- which is what this asserts.
#
# Run it directly, without a pipe:  bash deploy/proof/verdict-selfcheck.sh
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
VERDICT='ALL CHECKS PASSED'
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
rc=0

pass() { printf 'PASS %s %s\n' "$1" "$2"; }
fail() { printf 'FAIL %s %s\n' "$1" "$2"; rc=1; }

# 4.1 positive control: a passing proof prints the verdict and exits 0.
# compose-lint.sh is the only proof with no infrastructure dependency, so it
# is the one that can be run for real here.
out="$(bash "$ROOT/deploy/proof/compose-lint.sh" 2>&1)"
status=$?
if [ "$status" -eq 0 ] && printf '%s' "$out" | grep -qF "$VERDICT"; then
  pass 4.1 verdict-on-success
else
  fail 4.1 verdict-on-success "compose-lint exited $status and the verdict line was $(printf '%s' "$out" | grep -qF "$VERDICT" && echo present || echo absent)"
fi

# 4.2 the verdict is absent when a check fails. Each proof gets a copy with a
# forced failure injected into its first check, so nothing real is touched:
# no docker build, no tailnet join, no box is ever created.
inject() {
  local src="$1" fn="$2" id="$3" name="$4" dst="$5"
  awk -v fn="$fn" -v id="$id" -v nm="$name" '
    $0 ~ "^"fn"\\(\\) \\{" { print; printf "  fail %s %s \"forced failure: verdict self-check\"\n", id, nm; next }
    { print }' "$src" > "$dst"
}

check_absent() {
  local label="$1" script="$2" fn="$3" id="$4" name="$5"
  shift 5
  local copy="$TMP/$(basename "$script")"
  inject "$ROOT/deploy/proof/$script" "$fn" "$id" "$name" "$copy"
  if ! grep -q "forced failure: verdict self-check" "$copy"; then
    fail "$label" "no-verdict-on-failure" "could not inject a failure into $script ($fn)"
    return
  fi
  local o s
  o="$(bash "$copy" "$@" 2>&1)"; s=$?
  if [ "$s" -ne 0 ] && ! printf '%s' "$o" | grep -qF "$VERDICT"; then
    pass "$label" "no-verdict-on-failure($script)"
  else
    fail "$label" "no-verdict-on-failure($script)" "exit=$s, verdict $(printf '%s' "$o" | grep -qF "$VERDICT" && echo PRESENT || echo absent)"
  fi
}

check_absent 4.2 compose-lint.sh check_2_1 2.1 images-pinned
check_absent 4.3 container.sh   check_1_1 1.1 image-builds
check_absent 4.4 tailnet.sh     check_2_6 2.6 node-online
check_absent 4.5 box.sh         check_3_1 3.1 create-to-healthy-under-5min "$TMP/nonexistent-key" "$TMP/nonexistent-key"

# 4.6 the accumulating proofs must guard the verdict on ANY_FAIL rather than
# printing it unconditionally, so a BLOCKED check also withholds it.
for f in tailnet.sh box.sh; do
  if grep -qE 'if \[ "\$ANY_FAIL" -eq 0 \]; then printf' "$ROOT/deploy/proof/$f"; then
    pass 4.6 "verdict-guarded($f)"
  else
    fail 4.6 "verdict-guarded($f)" "verdict is not guarded on ANY_FAIL"
  fi
done

if [ "$rc" -eq 0 ]; then
  printf '%s\n' "$VERDICT"
fi
exit "$rc"
