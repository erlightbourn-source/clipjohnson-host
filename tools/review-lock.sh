#!/usr/bin/env bash
#
# review-lock.sh — atomic advisory mutual-exclusion lock for shared,
# single-owner files in this repo (default resource: docs/review.html).
#
# WHY THIS EXISTS
#   On 2026-07-15 two concurrent Dev instances committed docs/review.html
#   (07:52 + 08:54). The second push overtook a pending decision and bypassed
#   the mandated re-clear gate. It was SAFE ONLY BY LUCK. `git status` being
#   clean does NOT catch a second instance that is about to commit — there is
#   no cross-instance mutual exclusion. This gives a REAL one owns it / others
#   stand down lock via an atomic `mkdir` (POSIX-atomic even across processes).
#
# MANDATORY PROTOCOL before editing/committing the guarded file:
#   1. tools/review-lock.sh acquire "<owner>"      # STAND DOWN if this fails
#   2. edit + verify by observation
#   3. git commit + git push
#   4. tools/review-lock.sh release "<owner>"
#
# USAGE
#   review-lock.sh acquire <owner> [ttl_min]   # atomic; exit 1 if held (prints holder)
#   review-lock.sh release <owner>             # releases only if <owner> holds it
#   review-lock.sh status                      # prints holder or "free" (exit 0/0)
#   review-lock.sh steal   <owner> <reason>    # force-take (logged) — use only after
#                                              #   confirming the holder is truly gone
#
# Guard a different file:  LOCK_RESOURCE=docs/other.html review-lock.sh acquire me
#
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESOURCE="${LOCK_RESOURCE:-docs/review.html}"
SAFE="$(printf '%s' "$RESOURCE" | tr '/' '_')"
LOCKDIR="$REPO/.locks/${SAFE}.lock"
META="$LOCKDIR/holder"
LOG="$REPO/.locks/lock.log"
DEFAULT_TTL="${LOCK_TTL_MIN:-45}"   # minutes; auto-stale after this with no release

now_epoch() { date +%s; }
now_human() { date '+%Y-%m-%d %H:%M:%S %Z'; }
session_id() { printf '%s' "${OPENCLAW_SESSION:-${SESSION_KEY:-unknown-session}}"; }

_log() { mkdir -p "$REPO/.locks"; printf '%s | %s\n' "$(now_human)" "$*" >>"$LOG"; }

_read_meta() { [ -f "$META" ] && cat "$META" || true; }

_meta_field() { # field= value from holder file
  _read_meta | awk -F'=' -v k="$1" '$1==k{sub(/^[^=]*=/,"");print;exit}'
}

_write_meta() {
  local owner="$1" ttl="$2"
  {
    printf 'owner=%s\n' "$owner"
    printf 'session=%s\n' "$(session_id)"
    printf 'resource=%s\n' "$RESOURCE"
    printf 'acquired_epoch=%s\n' "$(now_epoch)"
    printf 'acquired_human=%s\n' "$(now_human)"
    printf 'ttl_min=%s\n' "$ttl"
    printf 'host=%s\n' "$(hostname)"
  } >"$META"
}

_age_min() { # minutes since acquired; empty holder -> huge
  local a; a="$(_meta_field acquired_epoch)"
  [ -n "$a" ] || { echo 999999; return; }
  echo $(( ( $(now_epoch) - a ) / 60 ))
}

_is_stale() {
  local ttl age; ttl="$(_meta_field ttl_min)"; [ -n "$ttl" ] || ttl="$DEFAULT_TTL"
  age="$(_age_min)"
  [ "$age" -ge "$ttl" ]
}

cmd_acquire() {
  local owner="${1:?owner required}" ttl="${2:-$DEFAULT_TTL}"
  mkdir -p "$REPO/.locks"
  if mkdir "$LOCKDIR" 2>/dev/null; then
    _write_meta "$owner" "$ttl"
    _log "ACQUIRE ok owner=$owner session=$(session_id) resource=$RESOURCE ttl=${ttl}m"
    echo "LOCK ACQUIRED: $RESOURCE  (owner=$owner, ttl=${ttl}m)"
    echo "  release with: tools/review-lock.sh release \"$owner\""
    return 0
  fi
  # held — decide reclaim vs stand-down
  local h_owner h_age h_ttl h_when
  h_owner="$(_meta_field owner)"; h_age="$(_age_min)"
  h_ttl="$(_meta_field ttl_min)"; h_when="$(_meta_field acquired_human)"
  if _is_stale; then
    _log "RECLAIM stale prev_owner=$h_owner age=${h_age}m -> new_owner=$owner"
    rm -rf "$LOCKDIR"
    if mkdir "$LOCKDIR" 2>/dev/null; then
      _write_meta "$owner" "$ttl"
      echo "LOCK RECLAIMED (stale ${h_age}m>=${h_ttl:-$DEFAULT_TTL}m, prev=$h_owner): $RESOURCE (owner=$owner)"
      return 0
    fi
  fi
  echo "LOCK HELD — STAND DOWN. Do NOT edit $RESOURCE." >&2
  echo "  holder : $h_owner" >&2
  echo "  since  : $h_when (${h_age}m ago, ttl=${h_ttl:-$DEFAULT_TTL}m)" >&2
  echo "  session: $(_meta_field session)" >&2
  echo "  If the holder is truly gone: tools/review-lock.sh steal \"$owner\" \"<reason>\"" >&2
  return 1
}

cmd_release() {
  local owner="${1:?owner required}"
  if [ ! -d "$LOCKDIR" ]; then echo "no lock held for $RESOURCE (nothing to release)"; return 0; fi
  local h_owner; h_owner="$(_meta_field owner)"
  if [ "$h_owner" != "$owner" ]; then
    echo "REFUSING release: lock owned by '$h_owner', not '$owner'." >&2
    echo "  use steal only if you are certain the holder is gone." >&2
    return 1
  fi
  rm -rf "$LOCKDIR"
  _log "RELEASE ok owner=$owner resource=$RESOURCE"
  echo "LOCK RELEASED: $RESOURCE (owner=$owner)"
}

cmd_status() {
  if [ ! -d "$LOCKDIR" ]; then echo "free: $RESOURCE"; return 0; fi
  local h_owner h_age h_ttl; h_owner="$(_meta_field owner)"; h_age="$(_age_min)"; h_ttl="$(_meta_field ttl_min)"
  local tag="held"; _is_stale && tag="STALE(reclaimable)"
  echo "$tag: $RESOURCE"
  echo "  holder : $h_owner"
  echo "  since  : $(_meta_field acquired_human) (${h_age}m ago, ttl=${h_ttl:-$DEFAULT_TTL}m)"
  echo "  session: $(_meta_field session)"
}

cmd_steal() {
  local owner="${1:?owner required}" reason="${2:?reason required}"
  local prev; prev="$(_meta_field owner)"
  rm -rf "$LOCKDIR"; mkdir -p "$REPO/.locks"; mkdir "$LOCKDIR"
  _write_meta "$owner" "$DEFAULT_TTL"
  _log "STEAL owner=$owner prev=$prev reason=$reason"
  echo "LOCK STOLEN from '$prev' by '$owner' (reason: $reason): $RESOURCE"
}

case "${1:-}" in
  acquire) shift; cmd_acquire "$@" ;;
  release) shift; cmd_release "$@" ;;
  status)  shift; cmd_status "$@" ;;
  steal)   shift; cmd_steal "$@" ;;
  *) echo "usage: review-lock.sh {acquire <owner> [ttl_min]|release <owner>|status|steal <owner> <reason>}" >&2; exit 2 ;;
esac
