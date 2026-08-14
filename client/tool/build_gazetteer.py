#!/usr/bin/env python3
"""Builds the embedded gazetteer asset the Photos location search runs on.

The app ships a place list rather than calling a geocoding service, because
the whole point of this product is that nothing about the user's library
leaves the machine — and a reverse-geocode request is a list of the exact
coordinates the user has photographed.

Source: GeoNames `cities5000` (every populated place over 5,000 people),
licensed CC BY 4.0. Attribution lives in `assets/gazetteer/README.md` and has
to ship with the app.

Output: `assets/gazetteer/cities.tsv.gz`, one row per place —

    name <TAB> region <TAB> country <TAB> lat <TAB> lng <TAB> population
         <TAB> search_name <TAB> search_alt <TAB> search_extra

`region` and `country` are resolved to display names here rather than in Dart,
so seeding the table at runtime is a straight parse with no lookup tables.

`search_name`/`search_alt` are the match columns: lowercased and stripped of
diacritics, because someone typing "zurich" on a US keyboard will never match
a stored "Zürich". `search_alt` carries GeoNames' own ascii spelling when it
differs from the folded name after that (their ascii form of Zürich is
"Zuerich", which folding cannot produce), and is empty otherwise.

`search_extra` holds everything that qualifies the name — region, the region's
abbreviation, and country — as space-separated tokens, so "Naperville, IL"
matches. People type a city together with its state, and matching on the name
alone meant the suggestions emptied the moment they did. The abbreviation is
carried explicitly because GeoNames stores the region as "Illinois" and nobody
types that.

Usage:
    python3 tool/build_gazetteer.py [--work-dir DIR]

Re-run it to refresh the asset; GeoNames publishes daily, but the data moves
slowly enough that this is a once-a-year chore at most.
"""

from __future__ import annotations

import argparse
import gzip
import io
import pathlib
import sys
import unicodedata
import urllib.request
import zipfile

BASE = "https://download.geonames.org/export/dump"
CITIES = "cities5000.zip"
ADMIN1 = "admin1CodesASCII.txt"
COUNTRIES = "countryInfo.txt"

OUTPUT = pathlib.Path(__file__).resolve().parent.parent / (
    "assets/gazetteer/cities.tsv.gz"
)


# Characters NFKD leaves alone because the diacritic is part of the letter
# rather than a combining mark — ø, ł, đ, ß, æ and friends. NFKD on its own
# would leave "Tromsø" as "tromsø", which no one types.
_EXPANSIONS = {
    "àáâãäåāăą": "a",
    "çćĉċč": "c",
    "ďđ": "d",
    "èéêëēĕėęě": "e",
    "ĝğġģ": "g",
    "ĥħ": "h",
    "ìíîïĩīĭįı": "i",
    "ĵ": "j",
    "ķ": "k",
    "ĺļľŀł": "l",
    "ñńņňŉ": "n",
    "òóôõöøōŏő": "o",
    "ŕŗř": "r",
    "śŝşš": "s",
    "ţťŧ": "t",
    "ùúûüũūŭůűų": "u",
    "ŵ": "w",
    "ýÿŷ": "y",
    "źżž": "z",
    "æ": "ae",
    "œ": "oe",
    "ß": "ss",
}

_FOLD_MAP = {
    char: replacement
    for chars, replacement in _EXPANSIONS.items()
    for char in chars
}


def fold(value: str) -> str:
    """Lowercases and strips diacritics, so `Zürich` matches a typed `zurich`.

    Mirrored **exactly** by `GazetteerRepository.fold` on the Dart side. The
    two run on opposite sides of a build — this one writes the `search_name`
    column, that one folds what the user types — and a query folded any
    differently from the stored value matches nothing at all, with no error to
    say why. Change one and you must change the other.
    """
    lowered = value.lower()
    decomposed = unicodedata.normalize("NFKD", lowered)
    stripped = "".join(c for c in decomposed if not unicodedata.combining(c))
    return "".join(_FOLD_MAP.get(c, c) for c in stripped)


def fetch(work_dir: pathlib.Path, name: str) -> pathlib.Path:
    """Downloads `name` into `work_dir`, reusing an existing copy."""
    target = work_dir / name
    if target.exists():
        print(f"  reusing {target}")
        return target
    url = f"{BASE}/{name}"
    print(f"  downloading {url}")
    urllib.request.urlretrieve(url, target)
    return target


def load_countries(path: pathlib.Path) -> dict[str, str]:
    """ISO country code -> country name."""
    codes: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.startswith("#") or not line.strip():
            continue
        fields = line.split("\t")
        if len(fields) > 4:
            codes[fields[0]] = fields[4]
    return codes


def load_admin1(path: pathlib.Path) -> dict[str, str]:
    """`<country>.<admin1 code>` -> region name (e.g. `US.TX` -> `Texas`)."""
    regions: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        fields = line.split("\t")
        if len(fields) > 1:
            regions[fields[0]] = fields[1]
    return regions


def build(work_dir: pathlib.Path) -> None:
    print("Fetching GeoNames data...")
    cities_zip = fetch(work_dir, CITIES)
    countries = load_countries(fetch(work_dir, COUNTRIES))
    regions = load_admin1(fetch(work_dir, ADMIN1))

    print("Building rows...")
    rows: list[str] = []
    with zipfile.ZipFile(cities_zip) as archive:
        with archive.open("cities5000.txt") as raw:
            for line in io.TextIOWrapper(raw, encoding="utf-8"):
                f = line.rstrip("\n").split("\t")
                if len(f) < 15:
                    continue
                name, ascii_name = f[1], f[2]
                lat, lng = f[4], f[5]
                country_code, admin1_code = f[8], f[10]
                population = f[14] or "0"

                country = countries.get(country_code, country_code)
                region = regions.get(f"{country_code}.{admin1_code}", "")

                search_name = fold(name)
                search_alt = fold(ascii_name)
                # Folding already covers the ordinary accent case; the alias
                # only earns its bytes for transliterations folding cannot
                # produce (Zürich -> Zuerich).
                if search_alt == search_name:
                    search_alt = ""

                # Deduplicated because "Luxembourg, Luxembourg, Luxembourg" is
                # three tokens' worth of bytes for one token's worth of match.
                extra_tokens: list[str] = []
                for value in (region, admin1_code, country, country_code):
                    for token in fold(value).replace(",", " ").split():
                        if token and token not in extra_tokens:
                            extra_tokens.append(token)
                search_extra = " ".join(extra_tokens)

                rows.append(
                    "\t".join(
                        [
                            name,
                            region,
                            country,
                            lat,
                            lng,
                            population,
                            search_name,
                            search_alt,
                            search_extra,
                        ]
                    )
                )

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    payload = ("\n".join(rows) + "\n").encode("utf-8")
    with gzip.open(OUTPUT, "wb", compresslevel=9) as out:
        out.write(payload)

    size_mb = OUTPUT.stat().st_size / (1024 * 1024)
    print(f"Wrote {len(rows):,} places to {OUTPUT} ({size_mb:.2f} MB)")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--work-dir",
        type=pathlib.Path,
        default=pathlib.Path("/tmp/geonames"),
        help="where downloads are cached (default: /tmp/geonames)",
    )
    args = parser.parse_args()
    args.work_dir.mkdir(parents=True, exist_ok=True)
    build(args.work_dir)
    return 0


if __name__ == "__main__":
    sys.exit(main())
