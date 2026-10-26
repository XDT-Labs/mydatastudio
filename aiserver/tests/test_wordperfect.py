"""WordPerfect text extraction (search plan §18m follow-up).

Two `.doc` attachments in this archive (1998 contracts from a PST) are not
Word files at all: an OLE2 container whose `WordDocument` stream holds a
WordPerfect 6–8 document (`\\xFFWPC`, product type 10, version 2.3). docling's
Word reader and macOS `textutil` both fail on them, so they were never
searchable. Nothing on PyPI reads WordPerfect, and bundling libwpd would mean
building, relinking and notarizing native code, so this is a small reader of
our own.

The byte sequences below are the ones measured in those two files. The
fixtures are synthetic: the real documents are someone's contracts.
"""
import struct

import pytest

from aichat import document_extractor as de
from aichat import wordperfect as wp

# ── Fixture builders ─────────────────────────────────────────────────────────


def wp_document(body: bytes) -> bytes:
    """A WordPerfect 6+ file: header pointing at a document area that is `body`."""
    header = b"\xffWPC" + struct.pack("<I", 16) + bytes([1, 10, 2, 3]) + b"\x00" * 4
    return header + body


def ole2(streams: dict) -> bytes:
    """A minimal valid OLE2 (CFB) file holding `streams` (name -> bytes).

    Every stream is padded to 4096 bytes so it lives in regular sectors. The
    reader's mini-stream path (streams under 4096 bytes) is not covered by
    this builder; it was checked against the real archive files' small
    summary streams.
    """
    sector = 512
    end = 0xFFFFFFFE
    free = 0xFFFFFFFF
    data_sectors = []  # (name, first_sector, size)
    payload = b""
    next_sector = 2  # 0 = FAT, 1 = directory
    for name, content in streams.items():
        padded = content.ljust(max(4096, -(-len(content) // sector) * sector), b"\x00")
        # The recorded size is the padded one: a stream under the 4096-byte
        # cutoff would have to live in the mini stream, which this builder
        # doesn't write. Trailing zero bytes are ignored by the extractor.
        size = len(padded)
        count = len(padded) // sector
        data_sectors.append((name, next_sector, size, count))
        payload += padded
        next_sector += count

    fat = [0xFFFFFFFD, end]  # FAT sector itself, directory chain
    for _, first, _, count in data_sectors:
        fat += [first + k + 1 for k in range(count - 1)] + [end]
    fat += [free] * (sector // 4 - len(fat))

    def entry(name, etype, start, size, child=free):
        raw = name.encode("utf-16le") + b"\x00\x00"
        e = raw.ljust(64, b"\x00") + struct.pack("<HBB", len(raw), etype, 1)
        e += struct.pack("<III", free, free, child)  # left, right, child
        e += b"\x00" * 16 + b"\x00" * 4 + b"\x00" * 16  # clsid, state, times
        e += struct.pack("<IQ", start, size)
        return e

    entries = [entry("Root Entry", 5, end, 0, child=1 if data_sectors else free)]
    for i, (name, first, size, _) in enumerate(data_sectors):
        entries.append(entry(name, 2, first, size))
    # Chain siblings through the right pointer so every entry is reachable.
    directory = b""
    for i, e in enumerate(entries):
        if 0 < i < len(entries) - 1:
            e = e[:0x48] + struct.pack("<I", i + 1) + e[0x4C:]
        directory += e
    directory = directory.ljust(sector, b"\x00")

    header = b"\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1" + b"\x00" * 16
    header += struct.pack("<HHHH", 0x3E, 3, 0xFFFE, 9)  # minor, major, BOM, sector shift
    header += struct.pack("<H", 6) + b"\x00" * 6  # mini shift, reserved
    header += struct.pack("<IIIIIIIII", 0, 1, 1, 0, 4096, end, 0, end, 0)
    header += struct.pack("<109I", 0, *([free] * 108))
    return header + struct.pack(f"<{sector // 4}I", *fat) + directory + payload


def text(body: bytes) -> str:
    return wp.extract_text(wp_document(body))


# ── Finding WordPerfect content ──────────────────────────────────────────────


class TestFindWordPerfect:
    def test_a_bare_file_is_its_own_payload(self):
        doc = wp_document(b"Hello")
        assert wp.find_wordperfect(doc) == doc

    def test_a_wordperfect_stream_inside_ole2_is_found(self):
        # The archive's case: WordPerfect inside a stream named WordDocument.
        doc = wp_document(b"Contract")
        found = wp.find_wordperfect(ole2({"WordDocument": doc}))
        assert found is not None and found.startswith(b"\xffWPC")
        assert wp.extract_text(found) == "Contract"

    def test_a_real_word_document_is_not_mistaken_for_wordperfect(self):
        word_fib = struct.pack("<HH", 0xA5EC, 193) + b"\x00" * 60
        assert wp.find_wordperfect(ole2({"WordDocument": word_fib, "1Table": b"\x00" * 8})) is None

    def test_other_bytes_are_not_wordperfect(self):
        assert wp.find_wordperfect(b"%PDF-1.4 ...") is None
        assert wp.find_wordperfect(b"") is None

    @pytest.mark.parametrize(
        "damaged",
        [
            b"\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1",  # header only
            b"\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1" + b"\xff" * 600,  # nonsense tables
        ],
    )
    def test_a_damaged_container_is_declined_not_raised(self, damaged):
        # Called on files docling already failed on, so garbage is expected input.
        assert wp.find_wordperfect(damaged) is None


# ── Extracting text ──────────────────────────────────────────────────────────


class TestExtractText:
    def test_ascii_soft_spaces_and_hard_returns(self):
        assert text(b"Hello\x80world\xccNext") == "Hello world\nNext"

    def test_an_end_of_line_group_is_a_line_break(self):
        # Measured: the letterhead ends lines with `d0 04 15 00 ... d0` groups,
        # which the spike skipped, gluing "TAREN SYSTEMS" to "580 Mill Creek".
        eol = b"\xd0\x04" + struct.pack("<H", 8) + b"\x00\x00\x00\xd0"
        assert text(b"SYSTEMS" + eol + b"580\x80Mill") == "SYSTEMS\n580 Mill"

    def test_other_variable_length_groups_are_skipped_whole(self):
        # A formatting group can contain bytes in the ASCII range; none of them
        # are text.
        group = b"\xd4\x1b" + struct.pack("<H", 10) + b"XYZ!\x00\xd4"
        assert text(b"before" + group + b"after") == "beforeafter"

    def test_fixed_length_groups_are_skipped(self):
        # Attribute on/off, e.g. bold: f2 0c f2 ... f3 0c f3
        assert text(b"\xf2\x0c\xf2Bold\xf3\x0c\xf3 text") == "Bold text"

    def test_deleted_revision_text_is_dropped(self):
        # Measured: "Employee" was edited to "Contractor". WordPerfect keeps the
        # deleted text in an undo span (F1 type 0 .. type 1) and the current
        # text in a valid span (type 2 .. type 3). The spike printed both:
        # "EmployeeContractor".
        undo = lambda kind: b"\xf1" + bytes([kind]) + struct.pack("<H", 2) + b"\xf1"
        body = b"(" + undo(0) + b"Employee" + undo(1) + undo(2) + b"Contractor" + undo(3) + b")"
        assert text(body) == "(Contractor)"

    def test_an_unknown_extended_character_is_dropped_not_guessed(self):
        # WordPerfect's character-set tables aren't verified here, so an
        # extended character becomes nothing rather than a wrong letter.
        assert text(b"a\xf0\x05\x07\xf0b") == "ab"

    def test_blank_line_runs_collapse(self):
        assert text(b"one\xcc\xcc\xcc\xcctwo") == "one\n\ntwo"

    def test_a_truncated_group_ends_extraction_cleanly(self):
        # Size field pointing past the end of the data.
        assert text(b"kept\xd4\x00\xff\xff") == "kept"

    def test_a_header_pointing_past_the_end_yields_nothing(self):
        bad = b"\xffWPC" + struct.pack("<I", 10_000) + b"\x00" * 8 + b"text"
        assert wp.extract_text(bad) == ""


# ── Wiring into the document extractor ───────────────────────────────────────

OLE2_MAGIC_BYTES = b"\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1"


class _FakeDocument:
    def __init__(self, markdown):
        self._markdown = markdown

    def export_to_markdown(self):
        return self._markdown


class _RecordingConverter:
    """docling that fails on the legacy format and succeeds on plain text."""

    def __init__(self, failure):
        self.calls = []
        self._failure = failure

    def __call__(self, data, fmt):
        self.calls.append(fmt)
        if fmt == "txt":
            return _FakeDocument(data.decode("utf-8"))
        raise self._failure


class TestWordPerfectRecovery:
    """WordPerfect files named `.doc` (the last 2 of the 87 §18m failures).

    Measured: both are OLE2 containers whose `WordDocument` stream holds
    WordPerfect 6-8 data. docling and textutil both fail on them; the pure-
    Python reader in `aichat.wordperfect` does not.
    """

    def _wp(self, body=b"Non\x80compete\x80agreement"):
        return wp_document(body)

    def test_a_wordperfect_doc_docling_cannot_parse_is_recovered(self, monkeypatch):
        converter = _RecordingConverter(RuntimeError("parse error: doc: no WordDocument stream"))
        monkeypatch.setattr(de, "_convert_raw", converter)
        monkeypatch.setattr(
            de, "_run_textutil", lambda data, fmt: pytest.fail("textutil consulted")
        )

        document = de._convert(ole2({"WordDocument": self._wp()}), "doc")

        assert document.export_to_markdown() == "Non compete agreement"
        # Re-read as text, like the textutil path, so chunking is unchanged.
        assert converter.calls == ["doc", "txt"]

    def test_a_bare_wordperfect_file_is_routed_by_its_bytes(self):
        assert de.sniff_format(self._wp(), "contract.doc") == "wpd"
        assert de.sniff_format(self._wp(), None) == "wpd"

    def test_a_bare_wordperfect_file_never_reaches_docling(self, monkeypatch):
        converter = _RecordingConverter(AssertionError("unused"))
        monkeypatch.setattr(de, "_convert_raw", converter)

        document = de._convert(self._wp(), "wpd")

        assert document.export_to_markdown() == "Non compete agreement"
        assert converter.calls == ["txt"]

    def test_unreadable_wordperfect_output_is_a_parse_error(self, monkeypatch):
        monkeypatch.setattr(de, "_convert_raw", _RecordingConverter(AssertionError("unused")))
        binary = self._wp(bytes(range(0x01, 0x20)) * 4)
        with pytest.raises(ValueError, match="WordPerfect"):
            de._convert(binary, "wpd")

    def test_an_ordinary_doc_still_goes_to_textutil(self, monkeypatch):
        converter = _RecordingConverter(RuntimeError("parse error: doc: bad FIB magic"))
        monkeypatch.setattr(de, "_convert_raw", converter)
        monkeypatch.setattr(de, "_run_textutil", lambda data, fmt: "recovered prose here")

        document = de._convert(OLE2_MAGIC_BYTES + b"\x00" * 64, "doc")

        assert document.export_to_markdown() == "recovered prose here"
