# Embedded gazetteers

Two place lists live here, and they are **not** interchangeable. They were
built independently for different features, carry different column orders, and
are read by different repositories. Keep both until one of them is deliberately
retired.

| File | Read by | Feature |
|---|---|---|
| `cities.tsv.gz` | `GazetteerRepository` | Photos location search |
| `cities5000.tsv.gz` | `PlaceRepository` | `near:` in unified search |

Both derive from the same GeoNames `cities5000` export — every populated place
over 5,000 residents, ~69,600 rows — so the duplication is in the *encoding*,
not the data. Merging them is a reasonable future cleanup; it needs one of the
two repositories to change its parser, which is why it has not happened here.

They are embedded rather than queried from a geocoding service because a
reverse-geocode request is, in effect, a list of the exact coordinates the user
has photographed — precisely the thing this product exists to keep on-device.

## Attribution

Both files derive from [GeoNames](https://www.geonames.org/), licensed under
[Creative Commons Attribution 4.0](https://creativecommons.org/licenses/by/4.0/).
The attribution is surfaced in the app's about screen. **It must remain visible
in the shipped application** for as long as either file does.

## `cities.tsv.gz` — Photos location search

Tab-separated, gzipped, one row per place:

| # | Column        | Example              |
|---|---------------|----------------------|
| 0 | `name`        | `Zürich`             |
| 1 | `region`      | `Zurich`             |
| 2 | `country`     | `Switzerland`        |
| 3 | `lat`         | `47.36667`           |
| 4 | `lng`         | `8.55`               |
| 5 | `population`  | `415367`             |
| 6 | `search_name` | `zurich`             |
| 7 | `search_alt`  | `zuerich` (or empty) |

`search_name` is `name` lowercased with diacritics stripped; `search_alt`
carries GeoNames' own ascii spelling when folding cannot produce it. Both are
match columns — see `GazetteerRepository`.

### Regenerating

```bash
python3 client/tool/build_gazetteer.py
```

Downloads the current GeoNames export and rewrites this asset. GeoNames
publishes daily, but the data moves slowly enough that this is a rare chore.

## `cities5000.tsv.gz` — `near:` in unified search

The GeoNames `cities5000` extract (69,572 rows) trimmed to the eight columns
`PlaceRepository` actually reads and gzipped. Fetched 2026-08-06 from
<https://download.geonames.org/export/dump/cities5000.zip>.

Columns, tab-separated, no header — note the order differs from the file above:

```
geonameid  name  ascii_name  latitude  longitude  country  admin1  population
```

The upstream file is 15 MB across 19 columns; almost all of that is
`alternatenames`, which lists every transliteration of every place in every
script. Dropping it and the five columns nothing queries takes the payload to
4.1 MB, and gzip to 1.7 MB.

### Why this tier

`near:` needs the *place name in the query* turned into a centre point. The
tier below this one (`cities15000`) is the tempting default and does not contain
Banff, Alberta (pop. 8,305) — which is the query the feature was designed
around. `cities1000` would add another 70,000 hamlets for 7 MB more, and is a
drop-in replacement if coverage proves too thin: the schema does not change,
only this file.
