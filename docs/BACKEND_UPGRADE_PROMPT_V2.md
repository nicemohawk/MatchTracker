# MatchTracker Backend Upgrade Prompt — V2 (roadmap wave)

You are upgrading the MatchTracker backend a second time. **Prerequisite:** the V1 upgrade
(`BACKEND_UPGRADE_PROMPT.md` — expanded sessions payload, players/teams/fields tables,
community field merging, `/teams/{code}/stats`, `/fields/nearby`) is assumed applied; if any
part of V1 is missing, implement it first. Adapt everything below to the existing stack and
conventions; do not assume a specific framework. All endpoints keep the existing
`Authorization: APIKey {key}` header unless stated. All JSON is snake_case. Every write
endpoint must be **idempotent by uuid** (upsert semantics) — the client now retries uploads
from a persistent queue with exponential backoff, so duplicate POSTs are routine, not errors.

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
  "on_pitch": true, "us_goals": 1, "them_goals": 0, "x": 0.62, "y": 0.31 }
```
Rules: reject `sequence` <= stored sequence for the same match (200 with `{"stale": true}`,
not an error); 204 on accept. Rate limit ~1 req/2 s per device.

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

## 8. Satellite field seeding (server-side)

Batch pipeline seeding community fields for venues no device has visited:
- `POST /fields/seed-request` `{ "lat": 39.32, "lon": -82.10, "radius_m": 1500 }` (rate-limited
  1/day/device) → enqueue a seed job; 202.
- Worker: fetch satellite imagery for the request area from a **licensed** source (Apple Maps
  Server API snapshots where license permits, else a provider like Mapbox/Maxar — flag the
  licensing decision for a human before implementation), run pitch detection (port the client's
  contour heuristic: white-line mask → contour → convex quad → per-sport dimension check; an ML
  segmentation model is a drop-in upgrade later), insert results as fields with
  `source = "community"`, `confidence = 0.25`, `observation_count = 0`, flagged
  `seeded = true`.
- Seeded fields appear in `/fields/nearby` only with `min_confidence` <= 0.25 until a real
  observation confirms them (then normal merge rules apply).

## 9. Field imagery caching

- `GET /fields/{uuid}/imagery` → cached satellite snapshot (PNG, ~1024px) for the field's
  bounding region, `Cache-Control: max-age=2592000`; populate lazily on first request via the
  same licensed imagery source as §8; store object-storage side. 404 when imagery is
  unavailable — clients fall back to on-device MapKit tiles.

## 10. Events metadata

- `sessions.events[]` items now include `"source": "manual" | "automatic"` (absent ⇒ manual).
  Store it; expose it back in any endpoint returning events. Aggregations (goals/assists in
  team stats) count both sources.

## Migrations

1. `live_status`, `match_comments`, `device_teams`, `entitlements` tables; `sport_id` columns;
   `players.initials_only`/`consent_acknowledged_at`; `teams.requires_consent`;
   `fields.seeded`; sessions stats blob accepts `mean_x`/`mean_y`.
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
9. Seeding: seed-request enqueues once per day per device; seeded fields hidden above
   min_confidence 0.25.
10. V1 regression suite still green (legacy endpoints untouched).
