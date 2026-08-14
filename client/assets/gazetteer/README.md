# Embedded gazetteer

`cities.tsv.gz` is the place list the Photos module's location search runs on:
every populated place over 5,000 people (~69,600 rows, ~1.5 MB compressed).

It is embedded rather than queried from a geocoding service because a
reverse-geocode request is, in effect, a list of the exact coordinates the user
has photographed — precisely the thing this product exists to keep on-device.

## Attribution

Derived from the [GeoNames](https://www.geonames.org/) `cities5000` export,
licensed under [Creative Commons Attribution 4.0](https://creativecommons.org/licenses/by/4.0/).

This attribution must remain visible in the shipped application.

## Format

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

## Regenerating

```bash
python3 client/tool/build_gazetteer.py
```

Downloads the current GeoNames export and rewrites this asset. GeoNames
publishes daily, but the data moves slowly enough that this is a rare chore.
