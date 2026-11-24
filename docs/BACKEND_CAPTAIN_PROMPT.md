# MatchTracker backend: captain-led teams

A contract request that builds on `BACKEND_UPGRADE_PROMPT.md` (V1) and `_V2.md`. Same conventions:
snake_case JSON, `Authorization: APIKey {key}`, idempotent writes, additive migrations. Work the way
V2 describes (contract first, disjoint waves, review before merge).

**The rule.** A team works with or without a coach. Whoever starts it is its captain; everyone who
joins sees the team for free. Nothing below is in the app's interface yet: the app shows no control
for it until the server has it, because a control that works for one person and not the next is worse
than none.

## 0. Fix first: what the shipped app already depends on

1. **Membership.** On join the app calls `POST /devices/{id}/teams {"team_code"}`; on leave,
   `DELETE /devices/{id}/teams/{code}` (V2 §6). It may arrive long after the player joined (offline),
   and is repeated until it gets a 2xx. Both must be idempotent. Joining a code no one has used
   **creates the team** (as V1 `/sessions` does), and the first member is its captain (§1).
   A member with no uploads must be able to read `stats`, `events`, `live` and `formation`: that is a
   teammate without a watch.
2. **`X-Device-ID`.** The app now sends it on every request. It had never sent it, so V2 §6's check,
   if live, has been refusing every team read from shipped builds. Until those age out, treat a
   missing header as "membership unknown" and allow the read.
3. **Live is free.** V2 §7 requires an active `team` entitlement for `POST /devices/{id}/live`. Remove
   it: a teammate's match must be visible whether or not that teammate pays. The only write that keeps
   the gate is the event annotation (§11), and match comments if they ever ship.
4. **Entitlement.** The app now sends `POST /devices/{id}/receipt {"jws"}` whenever it sees an active
   subscription (it never did before, so annotation could not have worked for anyone).
5. **Heart rate.** The app no longer sends `heart_rate` in live updates. Older builds do: **drop it on
   ingest and never return it** from `/teams/{code}/live`.
6. **`device_id` in `/teams/{code}/stats` is a hole.** The API key is the same for everyone and the
   device id is the only other credential, so a teammate who reads it can upload as, or delete, that
   player. Replace it with an opaque, per-team `member_id` (uuid). No device id may appear in any
   response about somebody else.
7. **Nameless members.** `player_name` must never be null; send `"No name"`.

## 1. Identity and roles

Issue a per-device secret, so that a device id alone is not a credential:
`POST /devices/{id}/secret` → `{"secret": "…"}`, once per device (409 after that). The app keeps it in the
Keychain and sends `X-Device-Secret`. All of §2–§6 **writes** require it.

`device_teams` gains `member_id uuid unique`, `role text not null default 'player'`
(`captain | coach | player`), `removed_at timestamptz null`. A team has exactly one captain while it has
members, and any number of coaches including none. No endpoint may require a coach to exist.

| | player | coach | captain |
|---|---|---|---|
| Read everything about the team | yes | yes | yes |
| Share the invite | yes | yes | yes |
| Take or drop the coach role for oneself | yes | yes | yes |
| Set formation, who's in | no | yes | yes |
| Rename, remove a player, give/take coach, new code, hand over | no | no | yes |

If the captain leaves or deletes their data without handing over, the longest-standing member becomes
captain.

## 2. The team

`GET /teams/{code}` (members only)
```json
{ "code": "K7QM2P", "name": "Red Dragons", "created_at": "…", "my_member_id": "…",
  "members": [ { "member_id": "…", "player_name": "Ben L", "role": "captain",
                 "joined_at": "…", "matches_shared": 4, "last_shared_at": "…" } ] }
```
Includes members who have shared nothing (`matches_shared: 0`, `last_shared_at: null`); this is what lets
the app list teammates without a watch. `ETag` / `If-None-Match` → 304.

`PUT /teams/{code}` `{"name": "Red Dragons"}`: the name for everyone, 1–60 characters, one line. Captain
only, **except** that the first member may set it while it is null (so a team started offline gets its
name with the membership call). 403 `{"reason":"not_captain"}`.

`PUT /devices/{id}/player` `{"player_name": "Ben L"}`: the typed name, applied to every team at once.
Today a name reaches the server only inside an uploaded match, so someone without a watch has none.
Stored exactly as typed.

Also return `member_id`, `role` in `/stats`, and `member_id` in `/live`, `/events` and `/formation`. Names
are not unique; the app matches players by name today and will switch to `member_id`.

## 3. Members

- `DELETE /teams/{code}/members/{member_id}`, captain only. Sets `removed_at`. The removed device gets
  403 `{"reason":"removed"}` from team reads, uploads and `POST /devices/{id}/teams` for that code, until
  the captain restores it: `POST /teams/{code}/members/{member_id}/restore`. Their past matches leave the
  team's totals.
- `POST /teams/{code}/captain` `{"member_id"}`, captain only; the old captain becomes a player. 204.
- `PUT /teams/{code}/members/{member_id}/role` `{"role": "coach" | "player"}`: captain for anyone, or
  anyone for themselves. `captain` is refused (400): use the endpoint above.
- `POST /teams/{code}/code` → `{"code": "…"}`, captain only: a new code after a leak. Old code stops
  accepting joins at once; existing members keep access under both for 30 days.

## 4. Formation and who's in

`GET` / `PUT /teams/{code}/lineup`, captain or coach to write, members to read.
```json
{ "updated_at": "…", "updated_by": "Ben L", "name": "4-3-3",
  "slots": [ { "member_id": "…", "name": null, "x": 0.26, "y": 0.14 },
             { "member_id": null, "name": "Pat", "x": 0.8, "y": 0.5 } ] }
```
`x` up the pitch from our goal, `y` left to right, both 0–1; at most 11 slots; exactly one of
`member_id` / `name`. Last write wins; `If-Match` on `updated_at` → 412 so two editors don't silently
overwrite each other. 404 until somebody sets one. `/formation` (worked out from matches) is unchanged
and separate.

`GET` / `PUT /teams/{code}/next`
```json
{ "kickoff": "…", "title": "Rovers FC, home", "place": "Demo Park",
  "in": [ { "member_id": "…" }, { "name": "Pat" } ], "updated_at": "…" }
```
Same rules. Cleared 12 h after `kickoff`. `place` is free text; no coordinates.

`name` in both is a person who isn't on MatchTracker and hasn't agreed to anything: keep it only while the
lineup references it, never index it, never return it anywhere else.

## 5. Matches the team played together

`GET /teams/{code}/matches?since=&limit=20`, newest first. Groups uploads whose kickoffs are within two
hours (the app's `TeamMinutes` rule).
```json
{ "matches": [ { "kickoff": "…", "length_minutes": 90,
  "players": [ { "member_id": "…", "player_name": "Ben L", "minutes": 88, "distance_m": 9120,
                 "goals": 1, "assists": 0, "sprints": 14 } ] } ] }
```
Null where unknown, never 0. Today the app can work out minutes and goals from `/events`, but not
distance per match. No routes, coordinates, heart rate or effort.

Live: `x`/`y` in `POST /devices/{id}/live` are optional and the app doesn't send them yet. Return the
elapsed time and score it does send (`elapsed_s`, `us_goals`, `them_goals`) in `/teams/{code}/live`.

## 6. Invites that open anywhere

`matchtracker-join://CODE?team=&captain=` works only where the app is installed, and some chat apps
don't make it tappable. Serve:
- `GET /join/{code}`: a page with the team name, the code to type and the App Store link. **No member
  names** and no confirmation that a code exists: the name comes from the link's own query.
- `/.well-known/apple-app-site-association` with `{"applinks":{"details":[{"appIDs":["<TEAM>.com.nicemohawk.MatchTracker"],"components":[{"/":"/join/*"}]}]}}`.

The app then adds `applinks:match-tracks.service.nicemohawk.com` and sends the https link.
Rate-limit joins to 10 an hour per device and 60 an hour per IP: a six-character code is guessable
at scale.

## 7. Privacy, and minors

- Names are returned exactly as typed, except `initials_only`, enforced server-side in **every** response
  here, including `updated_by`.
- `requires_consent` teams: until `consent_acknowledged_at` is set, a member is left out of `members`,
  `matches`, `stats`, `live` and `lineup` for others, and their uploads are held, not shown.
- For `requires_consent` teams, `live` omits `x`/`y`, and a join is pending until the captain accepts it:
  `GET /teams/{code}/requests`, `POST /teams/{code}/requests/{member_id}` `{"accept": true}`. A leaked
  code must not be enough to watch children play.
- `DELETE /devices/{id}` also clears membership, lineup slots, `updated_by`, and pending requests.
- Leaving or being removed stops uploads to the team (400 `not_a_member`), including ones queued on the
  phone. Log role changes and removals (who, whom, when) for 90 days.
- Never return to teammates: routes, coordinates, `avg_hr`, `heart_rate`, device ids, guardian names.
  `avg_workrate_score` should leave `/stats` too; the app doesn't show it.

## Migration

1. `device_teams`: add `member_id` (backfill random), `role`, `removed_at`; `team_lineups`, `team_next`,
   `join_requests`, `device_secrets`.
2. Backfill captain = the earliest member (`joined_at`, else first upload). Teams whose real captain is
   someone else fix it with the hand-over. Backfill `device_teams` from `players.team_code` (V2) first.
3. Old builds send no secret and no `X-Device-ID`: keep their uploads and reads working; they get none of
   §2–§6's writes.
4. Entitlement check removed from live before anything else ships.

## Acceptance tests

1. A device that has only joined (no uploads) reads stats, events, live and formation, and is in `members`.
2. First joiner of a new code is captain; a second is a player; no coach exists and nothing 4xxs for it.
3. Player → `PUT /teams/{code}`: 403 `not_captain`. Captain → 200 and every member sees the new name.
4. Removed member: 403 `removed` on reads, upload and rejoin; restored member: all work.
5. Captain deletes their data: the longest-standing member is captain.
6. Live POST with no entitlement: 204. Annotation with no entitlement: 402.
7. No response about another player contains a device id, heart rate, coordinate or route.
8. `initials_only` and `requires_consent` hold in every endpoint here.
9. Two lineup writes from the same `updated_at`: one 204, one 412.
10. Joining, leaving, receipt and lineup replays change nothing.
