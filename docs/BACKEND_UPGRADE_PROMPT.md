# Backend Upgrade Prompt — MatchTracker API

Paste this prompt to a coding agent working in the **backend repository** (server-side Swift /
Vapor or equivalent — adapt file/module names to whatever framework and project layout you
find; do not assume Vapor-specific types are already in place).

---

## Prompt

You are upgrading the MatchTracker backend service (`https://match-tracks.service.nicemohawk.com`)
to support an expanded iOS/watchOS app. The app now records richer match data (events, live
stats, player/team identity) and needs new read endpoints for team dashboards. Implement the
changes below in this repo, adapting to whatever web framework, ORM, and project structure
already exist here — do not assume a specific stack beyond "some server-side Swift service with
a database." If the repo uses something other than server-side Swift, port the intent, not the
syntax.

### How to work (delegation pattern)

Use a coordinator-plus-subagents workflow when your tooling allows it (otherwise follow the
same phases sequentially): (1) write a short **binding contract doc** first — schema DDL, exact
wire JSON, endpoint signatures — that implementation agents may not change; (2) partition the
work into **waves with disjoint file ownership** and delegate implementation to cheaper models,
keeping the strongest model for contracts and review adjudication; (3) gate every wave on the
full test suite + migration apply/rollback + the acceptance tests below, with only the
coordinator committing after independent re-verification; (4) finish with a **review fan-out**
(correctness scan, legacy-client back-compat audit, cross-endpoint consistency, auth holes) and
adversarially verify each finding (CONFIRMED/REFUTED with quoted evidence) before fixing; (5)
if a Codex plugin/CLI is available, run it as an independent second-viewpoint review of the
final diff — verify its findings like any other candidate. Keep contracts and wave briefs in
files so work survives interruptions.

### Goal

1. Keep the two legacy endpoints working byte-for-byte compatible with existing clients.
2. Extend the data model and the `/sessions` payload to carry events, stats, field/team/player
   linkage.
3. Add read endpoints for team rosters/stats, device match history, nearby community fields,
   and a health check.
4. Build the crowd-sourced **community field database**: fields come from two sources — manual
   touchline training (user walks the perimeter) and automatic inference from match GPS tracks —
   and the server merges observations across all devices by geometric proximity so field
   geometry improves as more users play on the same pitch.
5. Add auth scoping and basic rate limiting notes (implementation-level guidance, not a hard
   requirement to build a full auth system from scratch).

### Backward compatibility — must not break

These two endpoints exist today and MUST keep accepting exactly this shape, unauthenticated
changes forbidden, response codes unchanged:

```
POST /devices/{deviceUUID}/fields
Authorization: APIKey {key}
Content-Type: application/json

{
  "fields": [
    {
      "track": { "coordinates": [[lat, lon], [lat, lon], ...] },
      "recorded_at": "2026-07-13T18:04:00Z",
      "uuid": "3F2504E0-4F89-11D3-9A0C-0305E82C3301"
    }
  ]
}
```

```
POST /devices/{deviceUUID}/sessions
Authorization: APIKey {key}
Content-Type: application/json

{
  "sessions": [
    {
      "track": { "coordinates": [[lat, lon], ...] },
      "recorded_at": "2026-07-13T18:04:00Z",
      "uuid": "9F86D081-884C-11E4-A9AB-8C705AC7304F"
    }
  ]
}
```

Any client sending only these legacy fields must continue to get the same success response as
today. New fields (below) are additive and optional on write; treat missing new fields as
`null`/empty on read.

### Extended data model

Add/extend these entities. Use your existing ORM/migration tooling; keep primary keys as UUIDs
where the client already generates them (fields, matches), since the client is the source of
truth for those ids (offline-first — the watch/phone generate UUIDs before any network call).

**devices**
- `id` (UUID, primary key — this is the existing `{deviceUUID}` path param)
- `created_at`
- `last_seen_at`

**players** (device-linked profile; one row per device, upserted from `/sessions` payloads)
- `device_id` (UUID, FK -> devices.id, unique)
- `name` (string, nullable)
- `team_code` (string, nullable, FK -> teams.code)
- `updated_at`

**teams**
- `code` (string, primary key — short human-entered code, e.g. `"U14-RED"`)
- `name` (string, nullable)
- `created_at`

**fields**
- `uuid` (UUID, primary key — client-generated)
- `device_id` (UUID, FK -> devices.id — original uploader)
- `name` (string, nullable)
- `outline` (JSON array of `[lat, lon]` pairs — raw trained outline)
- `rect_center_lat` (double)
- `rect_center_lon` (double)
- `rect_length_m` (double — long side, meters)
- `rect_width_m` (double — short side, meters)
- `rect_heading_deg` (double — compass bearing of long axis, 0..<180)
- `source` (string: `"trained"` — user walked/drew the outline; `"inferred"` — geometry derived
  server-side from match GPS tracks; `"community"` — merged from multiple devices' observations)
- `observation_count` (int, default 1 — number of observations (trained outlines + match
  tracks) that have contributed to this field's geometry)
- `confidence` (float, 0–1 — server-maintained. A single trained outline starts higher
  (~0.7) than a single inferred track (~0.3); confidence rises monotonically with
  `observation_count` and with agreement between observations. Pick a simple formula, e.g.
  `1 - (1 - base) * decay^(observation_count - 1)`, and document it in code.)
- `created_at`
- `merged_into` (UUID, nullable, FK -> fields.uuid — set when de-duped into an earlier field)

**matches**
- `uuid` (UUID, primary key — client-generated, == HKWorkout.uuid)
- `device_id` (UUID, FK -> devices.id)
- `field_uuid` (UUID, nullable, FK -> fields.uuid)
- `recorded_at` (timestamp — match start)
- `duration_s` (double, nullable)
- `track` (JSON: `{"coordinates": [[lat, lon], ...]}`)
- `events` (JSON array, see below)
- `stats` (JSON object, see below)
- `team_code` (string, nullable, FK -> teams.code, denormalized for query speed)
- `created_at`

**match_events** (either a JSON column on `matches.events` as above, or a normalized child
table `match_events(match_uuid, uuid, kind, date, note)` — normalized is preferred if your ORM
makes JSON querying painful, since goal/assist aggregation for team stats needs to filter by
`kind`). Event shape:

```json
{
  "uuid": "C56A4180-65AA-42EC-A945-5FD21DEC0538",
  "kind": "goalFor",
  "date": "2026-07-13T18:22:10Z",
  "note": "left-footed volley"
}
```

`kind` is a free-form string on the wire; known values from the client are: `matchStart`,
`matchEnd`, `periodStart`, `periodEnd`, `subIn`, `subOut`, `goalFor`, `goalAgainst`,
`goalMine`, `assist`, `flag`. Do not validate against an enum server-side — store whatever
string arrives (forward-compatible with new client event kinds).

**stats** blob shape (stored as JSON on `matches.stats`):

```json
{
  "total_distance_m": 6423.5,
  "time_on_pitch_s": 3120.0,
  "sprint_count": 14,
  "run_count": 37,
  "workrate_score": 72.4,
  "speed_zones": {
    "standing_s": 210.0,
    "walking_s": 890.0,
    "jogging_s": 1340.0,
    "running_s": 520.0,
    "sprinting_s": 160.0
  },
  "avg_hr": 152.3,
  "position_role": "midfielder",
  "position_side": "left"
}
```

All fields nullable/optional — the client may upload partial stats (e.g. no HR if the watch
wasn't worn snugly). Types: all numeric fields are doubles except `sprint_count`/`run_count`
(integers). `position_role` ∈ `goalkeeper|defender|midfielder|forward` (string, nullable).
`position_side` ∈ `left|center|right` (string, nullable). Treat unknown enum strings as opaque
pass-through, not a validation error.

### Extended `POST /devices/{deviceUUID}/sessions` payload

Add these optional keys to each object in the existing `sessions` array (legacy keys `track`,
`recorded_at`, `uuid` unchanged):

```json
{
  "sessions": [
    {
      "uuid": "9F86D081-884C-11E4-A9AB-8C705AC7304F",
      "recorded_at": "2026-07-13T18:04:00Z",
      "track": { "coordinates": [[lat, lon], ...] },
      "duration_s": 3120.0,
      "field_uuid": "3F2504E0-4F89-11D3-9A0C-0305E82C3301",
      "team_code": "U14-RED",
      "player_name": "Ben Lachman",
      "events": [
        { "uuid": "C56A4180-65AA-42EC-A945-5FD21DEC0538", "kind": "goalFor", "date": "2026-07-13T18:22:10Z", "note": null }
      ],
      "stats": {
        "total_distance_m": 6423.5,
        "time_on_pitch_s": 3120.0,
        "sprint_count": 14,
        "run_count": 37,
        "workrate_score": 72.4,
        "speed_zones": { "standing_s": 210.0, "walking_s": 890.0, "jogging_s": 1340.0, "running_s": 520.0, "sprinting_s": 160.0 },
        "avg_hr": 152.3,
        "position_role": "midfielder",
        "position_side": "left"
      }
    }
  ]
}
```

Also optional: top-level `format` (string, nullable, `NULL` ≡ `"match"`; values `match|small_sided|indoor`) and `stats.effort_source` (string, nullable; `gps+hr|gps|hr` — which signals produced `workrate_score`). Store both as opaque pass-through.

Server behavior on receipt:
- Upsert the `matches` row by `uuid` (idempotent re-upload — client may retry).
- If `team_code` present and no `teams` row exists, create one with `name = null`.
- If `player_name` and/or `team_code` present, upsert the `players` row for `device_id` (last
  write wins; update `updated_at`).
- Store `events` and `stats` as-is (JSON passthrough is fine; don't over-validate).
- Treat the track as a **field observation**: refine the matched field's geometry and bump its
  `observation_count`/`confidence` (see "Match tracks as field observations" under New
  endpoints below).
- Response: same success shape as legacy (do not change status code or body shape clients
  already depend on — additive only, e.g. it's fine to add new response keys but do not
  remove/rename existing ones).

### New endpoints

**`GET /teams/{code}/stats`**

Per-player aggregates across all matches with that `team_code`, joined against `players` by
`device_id` for display name. Query params: `since` (ISO8601, optional, filter `recorded_at >=`),
`limit`/`offset` for player pagination (optional, default no limit).

Response:

```json
{
  "team_code": "U14-RED",
  "team_name": "Red Dragons",
  "players": [
    {
      "device_id": "…",
      "player_name": "Ben Lachman",
      "matches_played": 12,
      "total_minutes": 640.5,
      "total_distance_m": 74210.0,
      "total_sprints": 168,
      "avg_workrate_score": 68.9,
      "goals": 5,
      "assists": 3
    }
  ]
}
```

`matches_played` = count of matches with that `team_code` and `device_id`. `total_minutes` =
sum of `stats.time_on_pitch_s / 60` across those matches. `goals`/`assists` = count of events
with `kind == "goalFor"` (or `goalMine`, count both as goals for the scoring player — document
your choice) / `kind == "assist"` per device across matches. `avg_workrate_score` = mean of
non-null `stats.workrate_score`.

**`GET /devices/{deviceUUID}/matches`**

List a device's matches, most recent first. Query params: `limit` (default 20, max 100),
`offset` (default 0).

Response:

```json
{
  "matches": [
    {
      "uuid": "9F86D081-884C-11E4-A9AB-8C705AC7304F",
      "recorded_at": "2026-07-13T18:04:00Z",
      "duration_s": 3120.0,
      "field_uuid": "3F2504E0-4F89-11D3-9A0C-0305E82C3301",
      "team_code": "U14-RED",
      "stats": { "...": "same shape as above" }
    }
  ],
  "total": 47,
  "limit": 20,
  "offset": 0
}
```

Omit `track`/`events` from the list response (keep it light); a future `GET
/devices/{deviceUUID}/matches/{uuid}` detail endpoint can return the full record — add it too if
trivial, but it's not required for this pass.

**Field de-dup/merge on `POST /devices/{deviceUUID}/fields` (community field database)**

This is the core of the crowd-sourced field database: every uploaded field is an *observation*
of a physical pitch, and observations from any device merge into one canonical field whose
geometry improves as more people train or play on it.

Before inserting a new field, check existing fields (any device — fields are shared) for
geometric proximity: same field if
`distance(new.rect_center, existing.rect_center) < 40m` AND
`abs(new.rect_length_m - existing.rect_length_m) < 15m` AND
`abs(new.rect_width_m - existing.rect_width_m) < 15m`. Heading may differ by up to 10° or by
~180° (goals swap ends match-to-match; treat heading and heading+180 as equivalent for this
check).

On match, do not insert a new row. Instead **merge, weighting by `observation_count`**:
- Update the canonical field's rectangle as a weighted average: each of center lat/lon,
  length, width, and heading becomes
  `(existing_value * existing.observation_count + new_value) / (existing.observation_count + 1)`
  (for heading, average in the folded 0..<180 domain, handling the wrap so 179° and 1° average
  to 0°, not 90°). Increment `observation_count`, recompute `confidence`.
- If the new outline is richer (more points) than the stored one, replace `outline` with it;
  the fitted rectangle stays the weighted average, not the raw new fit.
- If the canonical field has merged observations from more than one device, set
  `source = "community"`. A trained observation merging into an inferred-only field upgrades
  `source` from `"inferred"` to `"trained"` (trained beats inferred; community beats both once
  multi-device).
- Record the incoming `uuid` as an alias so future `field_uuid` references from that upload
  resolve correctly — either store `merged_into` on a stub row with the new uuid pointing at the
  canonical uuid, or maintain a small alias table `field_aliases(alias_uuid, canonical_uuid)`.
  Pick whichever fits your schema better; either is acceptable as long as clients that uploaded
  the "duplicate" uuid and later reference it in `field_uuid` on a match resolve to the same
  canonical field in reads.
- Response to the client is unchanged (still whatever the legacy success shape is) — de-dup is
  invisible to the client.

**Match tracks as field observations on `POST /devices/{deviceUUID}/sessions`**

Every match track is also evidence of field geometry. On each session upload:
- If `field_uuid` resolves to a known field (directly or via alias): fit an oriented rectangle
  to the track's coordinate cloud server-side (a convex hull + minimum-area rotating-calipers
  fit, or any reasonable equivalent — player tracks under-cover the pitch, so expand the fit by
  ~5% per axis before merging and discard fits wildly smaller than a plausible pitch), then
  merge it into the matched field using the same observation-weighted averaging as above and
  bump `observation_count`/`confidence`. Because the weight of one match track is 1 against the
  accumulated count, a noisy track nudges rather than corrupts established geometry.
- If `field_uuid` is absent or unknown: run the same fit, then attempt proximity matching
  against existing fields (same thresholds as /fields de-dup). On a match, merge as above and
  associate the match with the canonical field. On no match, create a new field row with
  `source = "inferred"`, `observation_count = 1`, low starting `confidence`, a server-generated
  `uuid`, and `outline = null` (there is no walked outline).
- Skip this step entirely for tracks with fewer than ~200 points or fits that fail sanity
  bounds (length 60–130 m, width 30–90 m for soccer) — do not pollute the field DB with warmup
  jogs or bad GPS.

**`GET /fields/nearby?lat={lat}&lon={lon}&radius_m={radius}`**

Return community fields near a location, so a new user arriving at a known venue gets fields
they never trained. Requires the standard `Authorization: APIKey {key}` header. Query params:
`lat`/`lon` (doubles, required), `radius_m` (double, optional, default 2000, max 20000),
`min_confidence` (float, optional, default 0 — let the client filter low-confidence inferred
fields). Only canonical fields are returned (never alias/`merged_into` stubs), sorted by
distance ascending.

Request:

```
GET /fields/nearby?lat=39.3292&lon=-82.1013&radius_m=3000
Authorization: APIKey {key}
```

Response:

```json
{
  "fields": [
    {
      "uuid": "3F2504E0-4F89-11D3-9A0C-0305E82C3301",
      "name": "West Side Park #2",
      "source": "community",
      "observation_count": 23,
      "confidence": 0.94,
      "distance_m": 412.7,
      "outline": [[39.3291, -82.1015], [39.3299, -82.1013], [39.3298, -82.1002], [39.3290, -82.1004]],
      "rectangle": {
        "center_lat": 39.32945,
        "center_lon": -82.10085,
        "length_m": 100.5,
        "width_m": 64.2,
        "heading_deg": 12.3
      },
      "created_at": "2026-05-02T14:11:00Z"
    }
  ]
}
```

`outline` is `null` for purely inferred fields. `distance_m` is from the query point to the
rectangle center. Use a bounding-box prefilter on `rect_center_lat`/`rect_center_lon` (indexed)
before exact haversine distance so the query stays cheap without PostGIS; add PostGIS/spatial
indexing only if it's already in the stack.

**`GET /health`**

Trivial liveness check, no auth required. `200 OK` with a small JSON body (e.g.
`{"status":"ok"}`) is sufficient. Add a DB connectivity check if cheap to do (e.g. `SELECT 1`)
and return `503` with `{"status":"degraded"}` on failure.

### Auth

- Keep the existing `Authorization: APIKey {key}` header scheme unchanged for all
  device-scoped endpoints (`/devices/{deviceUUID}/...`).
- Add **per-team read scoping** for `GET /teams/{code}/stats`: require the same `APIKey` header,
  but validate that the presented key is associated with a device whose `players.team_code`
  matches `{code}` (or maintain a separate team-level API key if that's simpler in your auth
  model — either approach is fine, document which one you pick). Do not leave team stats
  endpoints open to any valid API key regardless of team membership.
- **Rate limiting**: add a basic per-key rate limit on write endpoints (`/fields`, `/sessions`)
  — e.g. 60 requests/minute — to protect against a buggy client retry loop. Read endpoints can
  have a looser limit (e.g. 120/minute). Use whatever rate-limiting middleware/library is
  idiomatic for this framework; a naive in-memory token bucket keyed by API key is acceptable if
  no middleware exists yet, but note in your PR description that it won't work correctly if the
  service runs multiple instances (needs a shared store like Redis for that case).

### Migration guidance

- Write additive migrations only (new tables, new nullable columns). Do not alter or drop any
  column the legacy endpoints touch.
- Backfill: existing `fields`/`sessions` rows written under the legacy schema have no
  `device_id`-linked `players` row and no `stats`/`events` — leave them null, do not
  synthesize fake data. For existing `fields` rows, backfill `source = "trained"`,
  `observation_count = 1`, and the single-trained-outline starting `confidence`.
- Deploy migrations before deploying the new endpoint code; the new columns must exist before
  the extended `/sessions` handler tries to write to them.
- Roll out behind a feature flag or canary if your deploy pipeline supports it, since this
  touches the write path for a currently-working endpoint.

### Acceptance tests

1. Legacy `POST /devices/{uuid}/fields` with only `track`/`recorded_at`/`uuid` still returns
   the same success response as before the change.
2. Legacy `POST /devices/{uuid}/sessions` with only `track`/`recorded_at`/`uuid` still returns
   the same success response as before the change.
3. Extended `POST /devices/{uuid}/sessions` payload (with `events`, `field_uuid`, `team_code`,
   `player_name`, `stats`) round-trips: values are queryable afterward via `GET
   /devices/{uuid}/matches`.
4. Re-posting the same `sessions[].uuid` twice updates the existing match row, does not create a
   duplicate.
5. `POST /devices/{uuid}/fields` with a field whose fitted rectangle is within the de-dup
   threshold of an existing field does not create a new `fields` row; a match later uploaded
   referencing the duplicate's original `uuid` as `field_uuid` still resolves to the canonical
   field on read.
6. `GET /teams/{code}/stats` returns correct `matches_played`, `total_minutes`, `goals`,
   `assists` for a fixture with 2 devices, 3 matches, mixed event kinds.
7. `GET /teams/{code}/stats` with an API key from a device on a *different* team is rejected
   (403/401) or returns empty — document which.
8. `GET /devices/{uuid}/matches` pagination: `limit=1&offset=1` returns the second-most-recent
   match only; `total` reflects full count.
9. `GET /health` returns `200` under normal operation.
10. Write endpoints reject a burst beyond the configured rate limit with `429`.
11. Merge weighting: a field with `observation_count = 9` merged with 1 new observation moves
    its center/length/width by exactly 1/10 of the delta; `observation_count` becomes 10 and
    `confidence` increases.
12. Heading wrap in merge: merging observations with headings 179° and 1° yields a heading near
    0°, not 90°; a new observation at heading+180° merges rather than creating a new field.
13. `POST /sessions` with a track and no `field_uuid` on a venue matching an existing field
    associates the match with the canonical field and bumps its `observation_count`; the same
    track at a fresh venue creates a new field with `source = "inferred"`.
14. `POST /sessions` with a short/degenerate track (< 200 points or fit outside sanity bounds)
    does not create or modify any field row.
15. `GET /fields/nearby` returns a field within `radius_m` sorted by distance, excludes fields
    outside the radius and alias stubs, respects `min_confidence`, and rejects missing
    `lat`/`lon` with `400`.
16. A brand-new device querying `GET /fields/nearby` at a venue where *other* devices trained a
    field receives that community field.

### Deliverable

Open a PR with: schema migrations, updated route handlers, the observation-weighted field
merge + alias logic, the track-as-field-observation pipeline on `/sessions`, the three new GET
endpoints (`/teams/{code}/stats`, `/devices/{id}/matches`, `/fields/nearby`), health check,
rate limiting middleware (or documented in-memory fallback), and tests covering the acceptance
list above. Include a short README note describing
the auth-scoping choice you made for team stats.
