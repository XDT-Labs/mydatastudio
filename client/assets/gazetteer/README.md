# Gazetteer

`cities5000.tsv.gz` is the GeoNames `cities5000` extract — every populated place
with more than 5,000 residents (69,572 rows) — trimmed to the eight columns
`PlaceRepository` actually reads and gzipped. Fetched 2026-08-06 from
<https://download.geonames.org/export/dump/cities5000.zip>.

Columns, tab-separated, no header:

```
geonameid  name  ascii_name  latitude  longitude  country  admin1  population
```

The upstream file is 15 MB across 19 columns; almost all of that is
`alternatenames`, which lists every transliteration of every place in every
script. Dropping it and the five columns nothing queries takes the payload to
4.1 MB, and gzip to 1.7 MB.

## Why this tier

`near:` needs the *place name in the query* turned into a centre point. The
tier below this one (`cities15000`) is the tempting default and does not contain
Banff, Alberta (pop. 8,305) — which is the query the feature was designed
around. `cities1000` would add another 70,000 hamlets for 7 MB more, and is a
drop-in replacement if coverage proves too thin: the schema does not change,
only this file.

## Licence

GeoNames data is licensed under [Creative Commons Attribution 4.0][cc-by]. The
attribution is surfaced in the app's about screen; keep it there if this file
stays.

[cc-by]: https://creativecommons.org/licenses/by/4.0/
