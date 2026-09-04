# MatchTracker Backend Upgrade Prompt — V2 (roadmap wave)

You are upgrading the MatchTracker backend a second time. **Prerequisite:** the V1 upgrade
(`BACKEND_UPGRADE_PROMPT.md` — expanded sessions payload, players/teams/fields tables,
community field merging, `/teams/{code}/stats`, `/fields/nearby`) is assumed applied; if any
part of V1 is missing, implement it first. Adapt everything below to the existing stack and
conventions; do not assume a specific framework. All endpoints keep the existing
`Authorization: APIKey {key}` header unless stated. All JSON is snake_case. Every write
endpoint must be **idempotent by uuid** (upsert semantics) — the client now retries uploads
from a persistent queue with exponential backoff, so duplicate POSTs are routine, not errors.

## How to execute (delegation pattern)

Work the way the client-side modernization was built — a strong coordinator model making
top-level decisions, cheaper models doing the implementation, adversarial review before every
merge. If you are a single agent without subagent tooling, follow the same phases sequentially.

1. **Contract first.** Before any implementation, write (or update) a short binding
   architecture doc in the backend repo: schema DDL, endpoint signatures, exact wire JSON, and
   module boundaries. The coordinator owns this document; implementation agents may not change
   it — contract drift between parallel agents is the #1 failure mode this prevents.
2. **Partition into waves with disjoint file ownership.** Group the sections below into waves
   whose agents never touch the same files (e.g. Wave 1: migrations + models; Wave 2 parallel:
   {live streaming §1 + comments §2}, {formation §3 + multi-sport §4}, {privacy §5 + teams §6 +
   entitlements §7}; Wave 3: seeding/imagery §8–9 batch pipeline). Delegate implementation to
   less expensive models (e.g. Opus/Sonnet-class via your Agent tool), reserving the strongest
   model for contracts, sequencing, and review adjudication. Each brief must name the files the
   agent owns and forbid everything else.
3. **Verification gates between waves.** Every agent runs the full test suite + migration
   apply/rollback + the relevant acceptance tests (list at the bottom) before reporting, and
   reports exact command results. Subagents never commit; the coordinator commits once a wave
   is independently re-verified green. Keep wave briefs and contracts in files, not just chat
   context, so work survives interruptions.
4. **Review fan-out before finishing.** Run several independent finder passes over the full
   diff (correctness line-scan, backward-compatibility audit against V1 clients, cross-endpoint
   consistency tracing, auth/privacy holes, efficiency), then one adversarial verifier per
   candidate finding returning CONFIRMED / PLAUSIBLE / REFUTED with quoted evidence. Fix
   confirmed findings, re-verify, then commit.
5. **Second viewpoint.** If a Codex plugin / Codex CLI is available, use it for an independent
   review pass of the final diff (and as a rescue diagnosis when stuck) — a different model
   family catches failure modes self-review misses. Treat its findings like any other
   candidate: adversarially verify before acting.

## 1. Live match streaming

The watch now streams `LiveMatchUpdate` deltas to the phone during a match; the phone relays
them to the backend so teammates' phones and a coach dashboard can watch live.

New table `live_status` (one row per device, overwritten):
- `device_id` FK, `team_code`, `match_uuid`, `sequence` int, `updated_at` timestamptz,
- `elapsed_s` float, `heart_rate` float null, `distance_m` float, `current_speed` float null,
- `on_pitch` bool, `us_goals` int null, `them_goals` int null,
- `x` float null, `y` float null  — latest position in normalized field coords when the phone
  knows the field, else null. No raw coordinate history is stored for live data.

`POST /devices/{device_id}/live`
```json
{ "match_uuid": "…", "team_code": "ABC123", "sequence": 42, "timestamp": "2026-07-13T15:04:05Z",
  "elapsed_s": 1810.5, "heart_rate": 156.0, "distance_m": 4321.0, "current_speed": 3.2,
  "on_pitch": true, "us_goals": 1, "them_goals": 0, "x": 0.62, "y": 0.31,
  "new_events": [ { "id": "…", "kind": "goalMine", "date": "2026-07-13T15:04:03Z",
                    "note": "header", "source": "manual" } ] }
```
Rules: reject `sequence` <= stored sequence for the same match (200 with `{"stale": true}`,
not an error); 204 on accept. Rate limit ~1 req/2 s per device.

`new_events` (optional; absent/empty ⇒ none) carries events the wearer tagged since the last
update — the same `MatchEvent` shape sessions upload (`id`, `kind`, `date`, optional `note`,
optional `source`). The raw GPS track is **not** relayed live; only these tagged events are. On
receipt, **append** each event, keyed by its `id`, to a **team-scoped live event log** (dedup by
event uuid — a replayed live POST re-sending the same event ids is a no-op, never a duplicate).
A stale `sequence` (rejected above) must not append its `new_events` either. When the finished
match is later uploaded via `/devices/{id}/sessions`, reconcile: the session's `events[]` are the
source of truth and **replace** the provisional live-log copies of the same uuids (so an edited
note or a manual event that overrode an automatic one wins); live-log events whose uuid never
arrives in an uploaded session are retained until they age out of the `since_hours` window (§11).
These reconciled events feed the team timeline in §11.

`GET /teams/{code}/live` → last-known status for every device on the team:
```json
{ "players": [ { "player_name": "Ben L", "updated_at": "…", "x": 0.62, "y": 0.31,
    "heart_rate": 156.0, "distance_m": 4321.0, "on_pitch": true,
    "stale": false } ] }
```
`stale` = `updated_at` older than 30 s. Respect `initials_only` (§5). Optional stretch: SSE
endpoint `GET /teams/{code}/live/stream` pushing the same JSON on change; polling contract
above is the requirement.

## 2. Match comments (team chat)

New table `match_comments`: `id` uuid PK, `match_uuid`, `team_code`, `author_device` FK,
`author_name` (denormalized at post time, initials-respecting), `body` text (<= 1000 chars),
`posted_at` timestamptz, soft-delete flag.

- `GET /matches/{match_uuid}/comments` → `{ "comments": [ { "id": "…", "match_uuid": "…",
  "author": "Ben L", "body": "great pressing in the second half", "posted_at": "…" } ] }`
  ordered oldest-first, paginated (`?after={id}`).
- `POST /matches/{match_uuid}/comments` body `{ "id": "…", "body": "…", "author": "…" }` —
  idempotent by `id`; server stamps `posted_at`; author resolved server-side from the device's
  player row (client-sent `author` is a fallback only).
- Authorization: device must belong to the match's team (§6 membership). Rate limit 10/min.

## 3. Team formation clustering

`GET /teams/{code}/formation?window_days=30`
Cluster the team's recent matches (same `field_uuid` or same kickoff window ± 2 h) using each
session's stored `position_role`/`position_side` and mean normalized points (extend the
sessions stats blob to persist `mean_x`, `mean_y` — the client now sends them inside `stats`
as `mean_x`/`mean_y`, floats 0–1; tolerate absence). Algorithm guidance: build per-player mean
points, mirror-align attack direction across players, then match against formation templates
(4-4-2, 4-3-3, 3-5-2, 4-2-3-1, 3-4-3) by minimum-cost assignment (Hungarian); confidence =
1 − normalized residual. Response:
```json
{ "name": "4-3-3", "confidence": 0.74,
  "slots": [ { "player_name": "Ben L", "x": 0.35, "y": 0.18, "role": "left midfielder" } ] }
```
404 with `{"reason": "insufficient_data"}` when fewer than 5 distinct players have qualifying
matches in the window.

## 4. Multi-sport support

- `fields.sport_id` and `sessions.sport_id`: nullable text, `NULL` ≡ `"soccer"`. Accept from
  both POST payloads; index alongside geometry.
- Per-sport plausibility bounds for the server-side field merge/inference pipeline (mirror the
  client's `SportProfile` ranges): soccer 90–130 × 45–90 m, lacrosse 100–110 × 55–60 m,
  field_hockey 91 × 55 m ± 10%, rugby 94–144 × 68–70 m, ultimate 64–110 × 25–37 m — keep in a
  config table, not code constants.
- `/fields/nearby` gains optional `sport_id` filter; `/teams/{code}/stats` unchanged (stats
  are sport-agnostic).

## 5. Minors privacy & compliance

- `players.initials_only` bool (V1 defined it — enforce it now **server-side** in every
  response that includes a name: roster stats, live, comments author, formation slots →
  render "B. L." style initials when true; never rely on clients to redact).
- `players.consent_acknowledged_at` timestamptz null — set via
  `POST /devices/{id}/consent` `{ "guardian_name": "…", "acknowledged": true }`; team stats
  endpoints exclude players on teams flagged `requires_consent` until set.
- `teams.requires_consent` bool (set at team creation; default false).
- **Data deletion:** `DELETE /devices/{device_id}` — cascades sessions, fields observations
  (decrement counts, keep merged community geometry), comments (tombstone author), live rows,
  player row. Respond 202 + `{"deletion_id": …}`; document the retention window (<= 30 days to
  purge backups). This is a compliance path — log it, don't rate-limit it away.

## 6. Multi-team membership

New table `device_teams`: `device_id`, `team_code`, `joined_at`, unique pair. A device may
belong to many teams; `players.team_code` becomes the *default* team (keep for V1 compat).
- `POST /devices/{id}/teams` `{ "team_code": "ABC123" }`, `DELETE /devices/{id}/teams/{code}`.
- `GET /devices/{id}/teams` → memberships with team names.
- Sessions already carry per-match `team_code` — validate it against membership on ingest
  (400 `{"reason": "not_a_member"}` otherwise). Team-scoped reads (`stats`, `live`, `comments`,
  `formation`) require membership of the requesting device (pass `X-Device-ID` header,
  validated against the API key's device registry).

## 7. Entitlements (team-features subscription)

The iOS app gates team features behind a StoreKit 2 subscription
(`com.nicemohawk.MatchTracker.team.monthly`).
- `POST /devices/{id}/receipt` `{ "jws": "<StoreKit 2 signed transaction>" }` — verify via
  App Store Server API (or local JWS signature check against Apple root certs), store
  `entitlements(device_id, product_id, expires_at, environment)`.
- `GET /devices/{id}/entitlements` → `{ "team": { "active": true, "expires_at": "…" } }`.
- Enforce server-side: team-scoped WRITE endpoints (live ingest, comments post) require an
  active `team` entitlement for the posting device; reads stay open to team members (a lapsed
  coach can still see old stats). Free tier (no team) is unaffected.

## 8. Satellite field seeding

Community-field seeding for venues no device has *played*, split into a shipped client-side phase
and a future server-side batch phase. Both feed the same seeded-field concept; the server treats a
seed identically regardless of who detected it.

### Phase 1 — on-device seeding (shipped client-side)

The iOS app now detects nearby pitches from Apple Maps satellite imagery **on-device**
(`iOS App/NearbyFieldSeeder.swift` tiling ~1.5 km into ~600 m squares around the user and running
the existing `SatelliteFieldDetector` contour heuristic). MapKit `MKMapSnapshotter` is ordinary
first-party usage, so there is no imagery-licensing question for this path. Opted-in clients
(Settings → "Contribute detected fields", default on) POST these detections through the normal
`/fields` upsert with `source = "satellite"` and `observation_count = 0`. **The server must treat
any incoming field with `observation_count == 0` and `source` in {`satellite`} as a seed:**
- store it flagged `seeded = true` with `confidence = 0.25` (do **not** trust a client-supplied
  confidence for seeds);
- keep the existing V1 community merge/de-dup rules — a seed within the merge radius of an existing
  field folds into it (never lowering an already-confirmed field's confidence), rather than
  creating a duplicate;
- hide seeded fields from `/fields/nearby` unless the request passes `min_confidence` <= 0.25;
  once a **real observation** (a played match, `observation_count` > 0, or a trained/inferred
  field) confirms the location, clear `seeded` and let normal confidence/merge rules take over.

Idempotency still holds: the client retries the same seed `uuid` from its offline queue, so
repeated seed POSTs must be no-ops.

### Phase 2 — server-side batch seeding (future)

For venues **no device has even passed near**, a server-side batch pipeline pre-seeds fields from
licensed imagery:
- `POST /fields/seed-request` `{ "lat": 39.32, "lon": -82.10, "radius_m": 1500 }` (rate-limited
  1/day/device) → enqueue a seed job; 202.
- Worker: fetch satellite imagery for the request area from a **licensed** source (Apple Maps
  Server API snapshots where license permits, else a provider like Mapbox/Maxar — flag the
  licensing decision for a human before implementation), run pitch detection (port the client's
  contour heuristic: white-line mask → contour → convex quad → per-sport dimension check; an ML
  segmentation model is a drop-in upgrade later), insert results as seeds exactly as in Phase 1
  (`source = "community"` acceptable here since there's no originating device;
  `confidence = 0.25`, `observation_count = 0`, `seeded = true`).
- Seeded fields (from either phase) appear in `/fields/nearby` only with `min_confidence` <= 0.25
  until a real observation confirms them (then normal merge rules apply).

## 9. Field imagery caching

- `GET /fields/{uuid}/imagery` → cached satellite snapshot (PNG, ~1024px) for the field's
  bounding region, `Cache-Control: max-age=2592000`; populate lazily on first request via the
  same licensed imagery source as §8; store object-storage side. 404 when imagery is
  unavailable — clients fall back to on-device MapKit tiles.

## 10. Events metadata

- `sessions.events[]` items now include `"source": "manual" | "automatic"` (absent ⇒ manual).
  Store it; expose it back in any endpoint returning events. Aggregations (goals/assists in
  team stats) count both sources.
- Sessions also carry optional `format` (`match|small_sided|indoor`, `NULL` ≡ `match`) and
  `stats.effort_source` (`gps+hr|gps|hr`); store/echo both, treat unknown strings as opaque.

## 11. Team event timeline

The coach view coalesces every player's tagged match events (goals, cards, subs, flags, free-text
notes) into a single chronological feed the coach reviews and — for events a player left
unlabeled — annotates with a coach label. Events come from two sources that share the same event
`uuid`: the live event log fed by `new_events` on `/devices/{id}/live` (§1) during a match, and the
reconciled `sessions.events[]` after upload. The timeline is the union, deduped by event uuid.

`GET /teams/{code}/events?since_hours=6`
Returns every team member's events from matches whose events fall within the last `since_hours`
(default 6), ordered **oldest-first** (ascending `date`):
```json
{ "events": [
    { "id": "…", "player_name": "Ben L", "match_uuid": "…", "kind": "goalMine",
      "date": "2026-07-13T15:04:03Z", "note": "top corner", "coach_label": "great finish",
      "source": "manual" }
] }
```
- `player_name` is the event's author, resolved server-side and **subject to `initials_only`**
  (§5) exactly like every other name-bearing response — render "B. L." when the author's player
  row is flagged. Never trust the client to redact.
- `kind` is the raw event-kind string (`goalMine`, `flag`, `yellowCard`, …). Pass unknown kinds
  through verbatim — the client preserves and displays them; do not coerce or drop them.
- `note` is the **player's own** note (may be absent). `coach_label` is the coach annotation
  (below), a **separate** field — never fold one into the other; both may be present at once.
- `source` (`manual` / `automatic`, absent ⇒ manual) is echoed per §10.
- Auth: requires **team membership** of the requesting device (§6, `X-Device-ID`). Reads stay
  open to any member (no entitlement needed — a lapsed coach can still review), consistent with §7.

`POST /matches/{match_uuid}/events/{event_id}/annotation`
```json
{ "label": "great finish" }
```
- Stores `label` as the event's `coach_label`, **separate from the player's `note`** (never
  overwrites it). **Idempotent overwrite**: re-posting replaces the previous `coach_label`; an
  empty/absent label clears it.
- Auth: requires **team membership** AND an active `team` entitlement (§7) for the posting device
  — annotating is a coach write, gated like other team-scoped writes.
- `204` on success; `404` when `event_id` is unknown for that `match_uuid`; `403` non-member;
  `402/403` when the entitlement is inactive.

## 12. Peer-cohort benchmarking

The roster leaderboard (§V1 `/teams/{code}/stats`) is *intra-team* only. Catapult One and SoccerBee
let a player rank against their age group, position, and the whole population; this endpoint gives
MatchTracker the same "where do I stand?" hook — the compounding, return-driving loop called out in
gap #4 — built on the workrate/run data we already collect. It is a **community** feature, not a
team-subscription one: any player with an API key sees it (the client hides it only when no key is
bootstrapped), so it works for solo players with no team.

`GET /players/me/benchmark?cohort=age_band|position|all`
Resolve the requesting player from the API key's device registry (the same "me" resolution the
device-scoped endpoints use — no `player_id` in the path, and never accept one from the client).
Compute the player's percentile rank (0–100, higher = better) within the selected cohort for each
metric, over a rolling recent window (suggest last 90 days of that player's uploaded sessions,
aggregated per player so a single high-volume player can't skew a cohort):

- `workrate` — mean `workrate_score`.
- `distance_per_match_m` — mean `total_distance_m` per match (per-match, not lifetime total, so
  cohort members with different match counts compare fairly).
- `sprint_distance_m` — sprint-zone distance (derive from `speed_zones.sprinting_s` × the sprint
  speed band, or a dedicated column if you add one; keep the definition consistent with the
  industry sprint-threshold convention flagged in the competitive doc's gap #1).
- `high_speed_running_m` — high-speed-running-band distance (the HSR band below sprint).
- `top_speed_ms` — the player's representative top speed (e.g. 95th-percentile instantaneous speed
  across the window, to reject a single GPS spike).

```json
{ "cohort": "30–39 · Midfield", "sample_size": 1240,
  "percentiles": { "workrate": 78.0, "distance_per_match_m": 64.0, "sprint_distance_m": 52.0,
                   "high_speed_running_m": 71.0, "top_speed_ms": 45.0 },
  "contribution_streak": 5, "badge_count": 3 }
```

**Cohort computation.**
- `age_band` — from the player's **optional** birth year. Bucket into decade-ish bands
  (`<20`, `20–29`, `30–39`, `40–49`, `50+`; pick the exact edges once and keep them in a config
  table, not code). Birth year is **never required**: a player who hasn't supplied one simply
  can't request `cohort=age_band` (answer `404 insufficient_data`, same as an under-populated
  cohort — never an error, never a prompt to hand over a birthday). Store it on `players`
  (`birth_year` int null) set via the existing device/profile write; do not add a mandatory field.
- `position` — from the modal `position_role` (+ optional `position_side`) across the player's
  recent `PositionAnalyzer` uploads (the sessions already carry `position_role`/`position_side`).
  A player with no position-bearing uploads can't request `cohort=position` → `404`.
- `all` — every player with qualifying sessions in the window; always available once the global
  population itself clears the k-anonymity floor.
- The `cohort` string in the response is a human-readable descriptor the client shows verbatim
  ("30–39 · Midfield", "Midfield", "Everyone") — the server owns this copy so bands/labels can
  evolve without a client release.

**k-anonymity (hard privacy gate).** Never return a benchmark for a cohort with **fewer than 25
players**. Below the floor, answer `404` with `{"reason": "insufficient_data"}` (the client renders
a quiet "Benchmarks unlock as the community grows" one-liner, identical in spirit to §3's formation
gate). A percentile against a handful of people would both be statistically meaningless and leak
individual standings.

**Privacy constraints.** This endpoint returns **aggregates only** — percentiles and a sample
count. It must **never enumerate cohort members**, expose another player's name or raw metric, or
let the caller derive an individual's value (that's why the ≥25 floor and per-player aggregation
matter). `initials_only` (§5) is moot here because no other member is ever named. The player only
ever sees their own rank within an anonymous crowd.

**Touchline-walk contribution rewards (optional).** To close the same community-flywheel loop from
gap #4 (seed the field-definition network by *rewarding* touchline walks), the response MAY carry
two optional counters for the requesting player: `contribution_streak` (consecutive periods —
weeks — in which they contributed at least one touchline field-walk) and `badge_count` (milestone
badges earned for field contributions). Both are **optional** wire fields: omit them entirely for
players/backends with no contribution history (the client treats absence as "no rewards yet" and
shows nothing, never a zero). These are the player's *own* counts — not a leaderboard of others.

Idempotent read; no writes. Auth: the standard `Authorization: APIKey {key}` header. No entitlement
gate (reads stay open; this is a free community hook, consistent with §7's read policy).

## Migrations

1. `live_status`, `match_comments`, `device_teams`, `entitlements` tables; `sport_id` columns;
   `players.initials_only`/`consent_acknowledged_at`; `teams.requires_consent`;
   `fields.seeded`; sessions stats blob accepts `mean_x`/`mean_y`; `players.birth_year` int null
   (optional, for §12 age-band cohorts — never required).
2. Backfill: `device_teams` from existing `players.team_code`; everything else defaults.
3. All new columns nullable/defaulted — V1 clients keep working untouched.

## Acceptance tests

1. Live: sequence regression returns stale=true and does not overwrite; team live respects
   initials_only and marks 30 s+ rows stale.
2. Comments: idempotent POST by id; non-member 403; pagination.
3. Formation: synthetic 11-player fixture matches 4-3-3 with confidence > 0.6; < 5 players →
   404 insufficient_data.
4. sport_id: rugby-sized field accepted with `sport_id":"rugby"`, rejected as soccer.
5. Privacy: initials_only enforced in stats/live/comments/formation; DELETE device cascades
   and tombstones comments; consent gating hides players until acknowledged.
6. Multi-team: session with non-member team_code 400; membership CRUD; stats scoped.
7. Entitlements: expired JWS → team writes 402/403; reads unaffected.
8. Idempotency: replaying any successful POST (sessions, fields, comments, live) changes
   nothing and returns success.
9. Seeding: a `/fields` POST with `source":"satellite"` and `observation_count":0` is stored as a
   seed (`seeded=true`, confidence forced to 0.25) and hidden from `/fields/nearby` above
   min_confidence 0.25; a later real observation clears the seed flag. Phase 2 seed-request
   enqueues once per day per device.
10. V1 regression suite still green (legacy endpoints untouched).
11. Live events: a `/devices/{id}/live` POST carrying `new_events` appends them to the team live
    event log keyed by event uuid; replaying the same POST (or resending overlapping event ids)
    adds no duplicates; a stale-sequence POST appends nothing; on session upload the uploaded
    `events[]` replace the live-log copies of the same uuids.
12. Team timeline: `GET /teams/{code}/events` merges live-log and uploaded events deduped by uuid,
    ordered oldest-first, enforces `initials_only` on `player_name`, passes unknown `kind` strings
    through, and requires membership. `POST .../events/{id}/annotation` sets `coach_label` without
    touching the player's `note`, is an idempotent overwrite, requires membership + active team
    entitlement, and 404s for an unknown event.
13. Benchmark: `GET /players/me/benchmark?cohort=all` returns 0–100 percentiles + `sample_size`
    once the cohort has ≥25 players and `404 insufficient_data` below it; `cohort=age_band` 404s
    for a player with no `birth_year` (never errors, never demands one) and `cohort=position` 404s
    with no position-bearing uploads; the response is aggregate-only and never names or enumerates
    another cohort member; `contribution_streak`/`badge_count` are present only with contribution
    history and absent otherwise.
