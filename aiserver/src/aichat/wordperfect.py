"""Plain text from WordPerfect 6-8 documents, with no dependencies.

Why this exists: two `.doc` attachments in this archive (1998 contracts from a
PST) are WordPerfect documents inside an OLE2 container, in a stream named
`WordDocument`. docling's Word reader and macOS `textutil` both fail on them.
Nothing on PyPI reads WordPerfect, and bundling libwpd would mean building,
relinking and notarizing native code for two files. The format is simple enough
to read the text out directly.

Layout of a WordPerfect 6+ document (as libwpd documents it):

    header   b"\\xFFWPC", u32 offset of the document area, product type, file
             type (10 = document), version bytes
    text     from that offset:
      0x01-0x1F  characters from WordPerfect's own charset
      0x20-0x7F  ASCII
      0x80-0xCF  single-byte functions: spaces, hyphens, line and page ends
      0xD0-0xEF  variable-length groups: code, subgroup, u16 total size, ...,
                 closing code. 0xD0 is the end-of-line group.
      0xF0       extended character: F0 <char> <charset> F0
      0xF1-0xFE  fixed-length groups that end with the same code byte. 0xF1 is
                 the undo group, which brackets deleted revision text.

Only text and line breaks are kept; all formatting is dropped. That is enough
for search, which is the only consumer.
"""
from __future__ import annotations

import struct
from typing import Iterator, Optional, Tuple

SIGNATURE = b"\xffWPC"
_OLE2_MAGIC = b"\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1"

_SOFT_SPACE, _HARD_SPACE = 0x80, 0x81
_HARD_HYPHEN = 0x84
# Single-byte line and page ends (hard/soft EOL, EOP, EOC variants).
_LINE_ENDS = frozenset({0x87, 0x88, 0x89, 0x8A, 0x8B, 0x8C} | set(range(0xC7, 0xD0)))
_EOL_GROUP = 0xD0
_UNDO_GROUP = 0xF1
# Undo group types: 0/1 open and close deleted text, 2/3 open and close the
# text that replaced it.
_UNDO_INVALID_START, _UNDO_INVALID_END = 0, 1
# How far to look for the closing byte of a fixed-length group. The longest in
# the format is well under this.
_FIXED_GROUP_MAX = 64


def find_wordperfect(data: bytes) -> Optional[bytes]:
    """The WordPerfect document in `data`, bare or inside any OLE2 stream.

    None when there is none, including for a damaged container: this runs on
    files another reader already failed on, so malformed input is expected.
    """
    if data.startswith(SIGNATURE):
        return data
    if data.startswith(_OLE2_MAGIC):
        try:
            for _name, payload in _ole2_streams(data):
                if payload.startswith(SIGNATURE):
                    return payload
        except (struct.error, IndexError, ValueError):
            return None
    return None


def extract_text(document: bytes) -> str:
    """The text of a WordPerfect document, with formatting removed."""
    if len(document) < 16 or not document.startswith(SIGNATURE):
        return ""
    i = struct.unpack_from("<I", document, 4)[0]
    n = len(document)
    out = []
    in_deleted = 0  # nesting depth of undo (deleted revision) spans

    while i < n:
        b = document[i]
        if b == _UNDO_GROUP:
            if i + 4 < n and document[i + 4] == _UNDO_GROUP:
                kind = document[i + 1]
                if kind == _UNDO_INVALID_START:
                    in_deleted += 1
                elif kind == _UNDO_INVALID_END and in_deleted:
                    in_deleted -= 1
                i += 5
            else:
                i += 1
            continue

        if 0x20 <= b <= 0x7F:
            if not in_deleted:
                out.append(chr(b))
            i += 1
        elif 0x01 <= b <= 0x1F:
            # A glyph from WordPerfect's own charset; its table isn't verified
            # here, so it stands in as a space rather than a wrong letter.
            if not in_deleted:
                out.append(" ")
            i += 1
        elif 0x80 <= b <= 0xCF:
            if not in_deleted:
                if b in (_SOFT_SPACE, _HARD_SPACE):
                    out.append(" ")
                elif b == _HARD_HYPHEN:
                    out.append("-")
                elif b in _LINE_ENDS:
                    out.append("\n")
            i += 1
        elif 0xD0 <= b <= 0xEF:
            if i + 4 > n:
                break
            size = struct.unpack_from("<H", document, i + 2)[0]
            if size < 4 or i + size > n:
                break  # truncated or corrupt: keep what was read so far
            if b == _EOL_GROUP and not in_deleted:
                out.append("\n")
            i += size
        elif b == 0xF0:
            # Extended character: F0 <char> <charset> F0. The charset tables
            # aren't verified, so it is dropped rather than guessed.
            i += 4 if i + 3 < n and document[i + 3] == 0xF0 else 1
        elif 0xF2 <= b <= 0xFE:
            end = document.find(bytes([b]), i + 1, i + _FIXED_GROUP_MAX)
            i = end + 1 if end != -1 else i + 1
        else:
            i += 1

    return _tidy("".join(out))


def _tidy(text: str) -> str:
    """Trim trailing spaces and collapse runs of blank lines."""
    lines = [line.rstrip() for line in text.split("\n")]
    kept, blanks = [], 0
    for line in lines:
        blanks = blanks + 1 if not line else 0
        if blanks <= 1:
            kept.append(line)
    return "\n".join(kept).strip()


def _ole2_streams(data: bytes) -> Iterator[Tuple[str, bytes]]:
    """Every stream in an OLE2 (Compound File Binary) container.

    Minimal and read-only: header, FAT (first 109 DIFAT entries), directory
    and mini stream. Enough for the small legacy documents this is used on.
    """
    sector_size = 1 << struct.unpack_from("<H", data, 0x1E)[0]
    mini_size = 1 << struct.unpack_from("<H", data, 0x20)[0]
    num_fat = struct.unpack_from("<I", data, 0x2C)[0]
    first_dir = struct.unpack_from("<I", data, 0x30)[0]
    mini_cutoff = struct.unpack_from("<I", data, 0x38)[0]
    first_minifat = struct.unpack_from("<I", data, 0x3C)[0]
    if sector_size not in (512, 4096) or num_fat > 109:
        raise ValueError("unsupported OLE2 layout")
    difat = struct.unpack_from("<109I", data, 0x4C)[:num_fat]

    def sector(index: int) -> bytes:
        start = (index + 1) * sector_size
        if start + sector_size > len(data):
            raise ValueError("sector out of range")
        return data[start:start + sector_size]

    fat = []
    for index in difat:
        fat.extend(struct.unpack(f"<{sector_size // 4}I", sector(index)))

    def chain(start: int, table) -> Iterator[int]:
        seen = set()
        while start < 0xFFFFFFFA:
            if start in seen or start >= len(table):
                raise ValueError("broken sector chain")
            seen.add(start)
            yield start
            start = table[start]

    directory = b"".join(sector(s) for s in chain(first_dir, fat))
    entries = []
    for offset in range(0, len(directory) - 127, 128):
        raw = directory[offset:offset + 128]
        name_len = struct.unpack_from("<H", raw, 0x40)[0]
        kind = raw[0x42]
        if kind not in (2, 5) or not 2 <= name_len <= 64:
            continue
        name = raw[:name_len - 2].decode("utf-16le", "replace")
        start, size = struct.unpack_from("<IQ", raw, 0x74)
        entries.append((name, kind, start, size & 0xFFFFFFFF))

    root = next((e for e in entries if e[1] == 5), None)
    mini_stream = b""
    mini_fat = []
    if root is not None and root[2] < 0xFFFFFFFA:
        mini_stream = b"".join(sector(s) for s in chain(root[2], fat))
        if first_minifat < 0xFFFFFFFA:
            for s in chain(first_minifat, fat):
                mini_fat.extend(struct.unpack(f"<{sector_size // 4}I", sector(s)))

    for name, kind, start, size in entries:
        if kind != 2:
            continue
        if size < mini_cutoff:
            parts = [
                mini_stream[s * mini_size:(s + 1) * mini_size]
                for s in chain(start, mini_fat)
            ]
        else:
            parts = [sector(s) for s in chain(start, fat)]
        yield name, b"".join(parts)[:size]
