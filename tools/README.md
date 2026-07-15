# tools/ — repo maintenance helpers

## review-lock.sh — single-owner lock for shared files (default `docs/review.html`)

**Why:** on 2026-07-15 two Dev instances committed `docs/review.html` minutes apart
(07:52 + 08:54); the second push overtook a pending decision and skipped the
re-clear gate. Safe only by luck. `git status` clean does **not** catch a second
instance about to commit — there was no cross-instance mutual exclusion. This lock
provides it (atomic `mkdir`, works across processes).

### MANDATORY protocol before editing/committing `docs/review.html`
```
tools/review-lock.sh acquire "<your-owner-id>"   # if this FAILS → STAND DOWN, do not edit
#   ... edit + verify by observation ...
git add docs/review.html && git commit && git push
tools/review-lock.sh release "<your-owner-id>"
```
- `acquire` exits **1** and prints the current holder if someone else owns it — that
  means stand down and coordinate, not retry.
- `release` only works for the owner that holds it (refuses a foreign release).
- Locks auto-stale after `ttl_min` (default 45) so a crashed instance can't wedge it.
- `status` shows the holder; `steal <owner> <reason>` force-takes a confirmed-dead
  lock (logged to `.locks/lock.log`).

The `.locks/` dir is gitignored — the lock never ships to Pages.
