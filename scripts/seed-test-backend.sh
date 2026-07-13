#!/usr/bin/env bash
#
# seed-test-backend.sh — seed a MatchTracker test backend with fixture data.
#
# This script pushes enough data at a running MatchTracker backend to exercise
# the iOS app's team read paths (team stats, formation, chat, live) against a
# local/test server. It speaks the EXACT wire formats documented in:
#   docs/BACKEND_UPGRADE_PROMPT.md      (V1: sessions/fields/teams/stats)
#   docs/BACKEND_UPGRADE_PROMPT_V2.md   (V2: live, comments, formation, membership, event source, sport_id)
# and matches the client structs in MatchTrackerKit/Sources/MatchTrackerKit/Backend.swift.
#
# It is deliberately tolerant: every call is wrapped so that a partial backend
# (e.g. a V1-only server that lacks /live or /teams/{code}/formation) produces a
# warning and the run continues rather than aborting. All UUIDs are fixed so the
# script is idempotent — re-running it upserts the same rows (the backend keys
# every write endpoint by uuid) instead of creating duplicates.
#
# Configuration (environment variables, all optional):
#   BASE_URL    Base URL of the backend            (default: http://localhost:8080)
#   API_KEY     Value for the "APIKey" auth header  (default: smarmy)
#   TEAM_CODE   Team code to seed and query         (default: TEST01)
#
# Usage:
#   ./scripts/seed-test-backend.sh
#   BASE_URL=http://192.168.1.20:8080 API_KEY=secret TEAM_CODE=U14RED ./scripts/seed-test-backend.sh
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
BASE_URL="${BASE_URL:-http://localhost:8080}"
API_KEY="${API_KEY:-smarmy}"
TEAM_CODE="${TEAM_CODE:-TEST01}"

# Strip any trailing slash so ${BASE_URL}${path} never doubles up.
BASE_URL="${BASE_URL%/}"

# ---------------------------------------------------------------------------
# Shared fixture geometry — a single soccer pitch centred near 39.325, -82.101.
# ~105 m x ~68 m: half-length ~0.00047 deg lat, half-width ~0.00040 deg lon.
# ---------------------------------------------------------------------------
FIELD_UUID="33333333-3333-3333-3333-000000000001"

# Trained outline: a closed ring walked around the pitch perimeter.
OUTLINE='[[39.32547,-82.10140],[39.32547,-82.10060],[39.32453,-82.10060],[39.32453,-82.10140],[39.32547,-82.10140]]'

# A handful of GPS points inside the pitch, reused as each session's track cloud.
TRACK='[[39.32500,-82.10100],[39.32520,-82.10120],[39.32480,-82.10080],[39.32510,-82.10090],[39.32490,-82.10110],[39.32505,-82.10105]]'

# Fixed speed-zone seconds (roughly a full match), shared across sessions.
SPEED_ZONES='{"standing_s":210.0,"walking_s":880.0,"jogging_s":1300.0,"running_s":500.0,"sprinting_s":150.0}'

# ---------------------------------------------------------------------------
# Fixture roster — 6 devices with fixed UUIDs and a rough 4-3-3 spread.
# Index 0 is a placeholder so devices are addressed 1..6 (readability under set -u).
# mean_x runs along the long axis (0 = own goal, 1 = opponent goal); mean_y runs
# across the pitch (0 = left touchline, 1 = right). The spread gives the backend
# formation clustering (V2 §3) a keeper + back line + midfield + front three.
# ---------------------------------------------------------------------------
NAMES=(        ""  "Alex Keeper"  "Bea Back"   "Cal Mid"     "Dana Wing"  "Evan Stopper" "Fen Striker" )
DEVICE_IDS=(   ""  "11111111-1111-1111-1111-000000000001" \
                   "11111111-1111-1111-1111-000000000002" \
                   "11111111-1111-1111-1111-000000000003" \
                   "11111111-1111-1111-1111-000000000004" \
                   "11111111-1111-1111-1111-000000000005" \
                   "11111111-1111-1111-1111-000000000006" )
ROLES=(        ""  "goalkeeper"   "defender"   "midfielder"  "forward"    "defender"     "forward" )
SIDES=(        ""  "center"       "left"       "center"      "left"       "right"        "center" )
MEAN_X=(       ""  "0.05"         "0.25"       "0.50"        "0.80"       "0.25"         "0.85" )
MEAN_Y=(       ""  "0.50"         "0.20"       "0.50"        "0.20"       "0.80"         "0.50" )
# Primary scoring event per player (in addition to a matchStart), so team stats
# aggregation sees a realistic mix of goals and assists with both sources.
EVENT_KIND=(   ""  "flag"         "assist"     "assist"      "goalFor"    "goalFor"      "goalFor" )
EVENT_SOURCE=( ""  "manual"       "automatic"  "manual"      "manual"     "manual"       "automatic" )

# ---------------------------------------------------------------------------
# Bookkeeping for the closing summary.
# ---------------------------------------------------------------------------
ok_count=0
warn_count=0
missing_notes=()   # human-readable notes about optional endpoints that were absent

warn() {
    warn_count=$((warn_count + 1))
    printf 'WARN: %s\n' "$*" >&2
}

# ---------------------------------------------------------------------------
# iso_days_ago N — print an ISO8601 UTC timestamp N days in the past.
# Handles both BSD date (macOS) and GNU date (Linux) so the script is portable.
# ---------------------------------------------------------------------------
iso_days_ago() {
    local days="$1"
    if date -u -v-1d >/dev/null 2>&1; then
        date -u -v-"${days}"d +%Y-%m-%dT%H:%M:%SZ   # BSD/macOS
    else
        date -u -d "${days} days ago" +%Y-%m-%dT%H:%M:%SZ   # GNU/Linux
    fi
}
iso_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# ---------------------------------------------------------------------------
# api METHOD PATH DATA LABEL [OPTIONAL]
#   Performs one authenticated curl. Never aborts the script: on failure it
#   warns (and, when OPTIONAL is non-empty, records the endpoint as "missing").
#   On success the response body is stashed in LAST_BODY. Always returns 0 so
#   `set -e` keeps going through a partially-implemented backend.
# ---------------------------------------------------------------------------
LAST_BODY=""
api() {
    local method="$1" path="$2" data="$3" label="$4" optional="${5:-}"
    local rc=0 out
    local -a args=(
        -fsS -X "$method" "${BASE_URL}${path}"
        -H "Authorization: APIKey ${API_KEY}"
        -H "content-type: application/json"
    )
    [ -n "$data" ] && args+=( --data "$data" )

    # `|| rc=$?` keeps a curl failure from tripping errexit inside the assignment.
    out=$(curl "${args[@]}") || rc=$?

    if [ "$rc" -eq 0 ]; then
        ok_count=$((ok_count + 1))
        LAST_BODY="$out"
        printf '  ok   %-6s %s\n' "$method" "$path"
    else
        LAST_BODY=""
        if [ -n "$optional" ]; then
            missing_notes+=("$label ($method $path) — curl exit $rc")
        fi
        warn "$label failed ($method $path, curl exit $rc)"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# get_pretty PATH LABEL — GET an endpoint and pretty-print it (jq if available).
# Tolerant like api(): warns and continues if the endpoint is missing.
# ---------------------------------------------------------------------------
get_pretty() {
    local path="$1" label="$2" rc=0 out
    out=$(curl -fsS -X GET "${BASE_URL}${path}" \
            -H "Authorization: APIKey ${API_KEY}" \
            -H "content-type: application/json") || rc=$?
    if [ "$rc" -ne 0 ]; then
        missing_notes+=("$label (GET $path) — curl exit $rc")
        warn "$label failed (GET $path, curl exit $rc)"
        return 0
    fi
    ok_count=$((ok_count + 1))
    printf '\n=== %s (GET %s) ===\n' "$label" "$path"
    if command -v jq >/dev/null 2>&1; then
        printf '%s' "$out" | jq . || printf '%s\n' "$out"
    else
        printf '%s\n' "$out"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# build_session I J RECORDED_AT — emit the JSON body for one /sessions upload.
# Matches MatchPayload in Backend.swift: legacy track/recorded_at/uuid plus V2
# events (with source), field_uuid, team_code, player_name, sport_id, and the
# full stats blob including mean_x/mean_y for formation clustering.
# ---------------------------------------------------------------------------
build_session() {
    local i="$1" j="$2" recorded_at="$3"

    # Fixed, deterministic UUIDs keyed by device+session so re-runs upsert.
    local session_uuid="22222222-2222-2222-2222-0000000000${i}${j}"
    local event_uuid_start="44444444-4444-4444-4444-0000000000${i}${j}"
    local event_uuid_primary="55555555-5555-5555-5555-0000000000${i}${j}"

    local name="${NAMES[$i]}" role="${ROLES[$i]}" side="${SIDES[$i]}"
    local mean_x="${MEAN_X[$i]}" mean_y="${MEAN_Y[$i]}"
    local ekind="${EVENT_KIND[$i]}" esrc="${EVENT_SOURCE[$i]}"

    # Lightly varied stats so per-player aggregates differ. Integer JSON numbers
    # are valid doubles on the wire; workrate/HR carry a fractional part.
    local distance_m=$(( 4800 + i * 350 + j * 120 ))
    local time_on_pitch_s=$(( 2600 + i * 40 + j * 10 ))
    local sprint_count=$(( 7 + i ))
    local run_count=$(( 22 + i * 2 ))
    local workrate_score avg_hr
    workrate_score=$(awk -v i="$i" -v j="$j" 'BEGIN { printf "%.1f", 58 + i * 2.5 + j * 1.3 }')
    avg_hr=$(awk -v i="$i" 'BEGIN { printf "%.1f", 148 + i * 2.2 }')

    cat <<JSON
{
  "sessions": [
    {
      "uuid": "${session_uuid}",
      "recorded_at": "${recorded_at}",
      "track": { "coordinates": ${TRACK} },
      "duration_s": ${time_on_pitch_s}.0,
      "field_uuid": "${FIELD_UUID}",
      "team_code": "${TEAM_CODE}",
      "player_name": "${name}",
      "sport_id": "soccer",
      "events": [
        { "uuid": "${event_uuid_start}", "kind": "matchStart", "date": "${recorded_at}", "note": null, "source": "automatic" },
        { "uuid": "${event_uuid_primary}", "kind": "${ekind}", "date": "${recorded_at}", "note": "seeded fixture", "source": "${esrc}" }
      ],
      "stats": {
        "total_distance_m": ${distance_m}.0,
        "time_on_pitch_s": ${time_on_pitch_s}.0,
        "sprint_count": ${sprint_count},
        "run_count": ${run_count},
        "workrate_score": ${workrate_score},
        "speed_zones": ${SPEED_ZONES},
        "avg_hr": ${avg_hr},
        "position_role": "${role}",
        "position_side": "${side}",
        "mean_x": ${mean_x},
        "mean_y": ${mean_y}
      }
    }
  ]
}
JSON
}

# ===========================================================================
# Seeding begins
# ===========================================================================
printf 'Seeding MatchTracker test backend\n'
printf '  BASE_URL  = %s\n' "$BASE_URL"
printf '  API_KEY   = %s\n' "$API_KEY"
printf '  TEAM_CODE = %s\n\n' "$TEAM_CODE"

# 0. Liveness check (V1 §/health). Optional — a bare backend may not have it.
api GET "/health" "" "health check" optional

# 1. Shared trained field. Uploaded as a walked outline; the server fits the
#    rectangle and marks it source="trained". Must exist before sessions so their
#    field_uuid resolves to it. (FieldWire shape: track/recorded_at/uuid/sport_id.)
FIELD_BODY=$(cat <<JSON
{
  "fields": [
    {
      "track": { "coordinates": ${OUTLINE} },
      "recorded_at": "$(iso_days_ago 21)",
      "uuid": "${FIELD_UUID}",
      "sport_id": "soccer"
    }
  ]
}
JSON
)
api POST "/devices/${DEVICE_IDS[1]}/fields" "$FIELD_BODY" "shared trained field"

# 2. Per-device team membership + 2 sessions each.
#    recorded_at is staggered from ~20 down to ~9 days ago (inside the last 3 weeks).
day_offset=20
for i in 1 2 3 4 5 6; do
    device_id="${DEVICE_IDS[$i]}"

    # 2a. Register team membership (V2 §6). V1-only backends lack this endpoint —
    #     tolerate failure with a warning; sessions below still create the team.
    api POST "/devices/${device_id}/teams" \
        "{\"team_code\": \"${TEAM_CODE}\"}" \
        "team membership for ${NAMES[$i]}" optional

    # 2b. Two sessions, each its own POST (idempotent by session uuid).
    for j in 1 2; do
        recorded_at="$(iso_days_ago "$day_offset")"
        session_body="$(build_session "$i" "$j" "$recorded_at")"
        api POST "/devices/${device_id}/sessions" "$session_body" \
            "session ${i}.${j} (${NAMES[$i]})"
        day_offset=$((day_offset - 1))
    done
done

# 3. Three comments on the first player's first match (V2 §2 shape).
#    match_uuid == that session's uuid.
FIRST_MATCH_UUID="22222222-2222-2222-2222-000000000011"
comment_bodies=(
    "Great pressing in the second half."
    "Nice overlap on the left wing."
    "Let's tighten the back line next week."
)
comment_authors=("Cal Mid" "Dana Wing" "Bea Back")
for c in 0 1 2; do
    comment_id="66666666-6666-6666-6666-00000000000$((c + 1))"
    body_json=$(cat <<JSON
{ "id": "${comment_id}", "body": "${comment_bodies[$c]}", "author": "${comment_authors[$c]}" }
JSON
)
    api POST "/matches/${FIRST_MATCH_UUID}/comments" "$body_json" \
        "comment $((c + 1)) on first match"
done

# 4. A couple of live updates for two devices (V2 §1). Optional — tolerate 404
#    on backends without live streaming. x/y come from each player's mean point.
NOW="$(iso_now)"
for i in 1 3; do
    device_id="${DEVICE_IDS[$i]}"
    match_uuid="22222222-2222-2222-2222-0000000000${i}1"
    live_body=$(cat <<JSON
{
  "match_uuid": "${match_uuid}",
  "team_code": "${TEAM_CODE}",
  "sequence": 42,
  "timestamp": "${NOW}",
  "elapsed_s": 1810.5,
  "heart_rate": 156.0,
  "distance_m": 4321.0,
  "current_speed": 3.2,
  "on_pitch": true,
  "us_goals": 1,
  "them_goals": 0,
  "x": ${MEAN_X[$i]},
  "y": ${MEAN_Y[$i]}
}
JSON
)
    api POST "/devices/${device_id}/live" "$live_body" \
        "live update for ${NAMES[$i]}" optional
done

# 5. Read back the two team aggregates the iOS app renders, pretty-printed.
get_pretty "/teams/${TEAM_CODE}/stats" "team stats"
get_pretty "/teams/${TEAM_CODE}/formation?window_days=30" "team formation"

# ===========================================================================
# Summary
# ===========================================================================
printf '\n=== Seed summary ===\n'
printf 'Successful calls: %d\n' "$ok_count"
printf 'Warnings:         %d\n' "$warn_count"
printf 'Seeded:\n'
printf '  - 1 shared trained field (%s)\n' "$FIELD_UUID"
printf '  - 6 devices, 12 sessions (2 per device), team_code=%s\n' "$TEAM_CODE"
printf '  - 3 comments on match %s\n' "$FIRST_MATCH_UUID"
printf '  - live updates attempted for 2 devices\n'

if [ "${#missing_notes[@]}" -gt 0 ]; then
    printf 'Optional endpoints missing / unavailable:\n'
    for note in "${missing_notes[@]}"; do
        printf '  - %s\n' "$note"
    done
else
    printf 'All optional endpoints responded.\n'
fi

printf '\nDone.\n'
