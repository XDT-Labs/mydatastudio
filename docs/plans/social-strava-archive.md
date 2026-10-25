---
status: proposed
adr: none
remaining: [sample-export, activities-csv, gpx-fit-parsing, route-storage, near-and-map, import-ui, api-phase-2]
---

# Plan: Archive Strava activities (routes on the map)

**Release order: 6.** Every run, ride and hike with its **GPS track**, so the app's map and
`near:` gain years of "where I've been". Export first, with a bring-your-own API app later for
incremental sync.

**Scope:** the user's own activities: type, date, name, description, stats and the recorded
track, plus photos if the export includes them. Out of scope: kudos, comments, followers,
segments, clubs.

## Path 1: bulk export (v1)

- **Settings › My Account › Download or Delete Your Account › Get Started › Request Your
  Archive** **(verify the path)**. An email arrives, usually within hours.
- Contents: **`activities.csv`** (one row per activity: id, date, name, type, description?,
  distance, moving time, elevation, heart rate, power, filename) and an **`activities/`**
  folder of original **GPX / FIT / TCX** files, some **gzipped**. Guides disagree on whether
  photos and descriptions are included **(verify)**.
- **Parsing:** GPX and TCX are XML (Dart). **FIT** is binary: parse it in the aiserver (Python
  `fitdecode`/`fitparse`) through a new `/util/parse/fit` endpoint, rather than writing a Dart
  FIT decoder.
- **Storage:**
  - each activity → `social_posts` (`platform = 'strava'`, `kind = activity`: name + description
    in `text`, stats in `raw_json`, `created_at` = the start time, start point in
    `latitude`/`longitude`);
  - plus a new `activity_tracks` table `(post_id, polyline, bbox, distance_m, …)`. The track is
    simplified to a few hundred points (Douglas–Peucker) for display, with the original file kept
    in `files`.
- **`near:` and the map:**
  - `near:banff` matches activities whose **bbox** intersects the place's radius, then confirms
    against the polyline, not just the start point;
  - the Photos map gets a "Routes" layer drawing tracks;
  - photos taken during an activity's time window and area can show "During: Morning ride".
- **UI:** the shared setup panel and file picker. A Strava page with an activity list (map
  thumbnail per activity), filters by sport and year, "On this day", and a heatmap of all routes.
  Re-export reminder.

## Path 2 (later): personal Strava API app

- The user creates their own app at **strava.com/settings/api** (client id + secret are the
  user's own, kept locally). OAuth with a loopback redirect, scope `activity:read_all`.
  Refresh tokens rotate (access tokens last 6 hours) **(verify)**.
- `GET /athlete/activities?after=<newest>`, then the activity streams (latlng, time, altitude)
  for the track. Rate limits around 200 requests/15 min and 2,000/day **(verify)**: fine for
  daily sync.
- Strava's API terms limit showing data to anyone but the athlete. A private local archive
  fits **(verify the current agreement)**.

## Done when

A user imports their archive and sees every activity with its route. `near:` finds rides that
passed through a place. Photos from a run show which activity they belong to.
