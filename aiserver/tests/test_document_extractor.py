"""Document extraction for search Phase 7 (SEARCH_PLAN §18).

Each test here encodes a decision that was *measured* during the §18h step 0
spike, not a guess about how the library behaves. Where a test looks
paranoid, the docstring says which measurement it is defending.
"""
import io

import pytest

from aichat import document_extractor as de


# ── Format sniffing ──────────────────────────────────────────────────────────
#
# §18a measured this archive: six of eight sampled `.doc` files are OLE2 and
# two are RTF wearing a `.doc` name. docling routes purely on the extension it
# is handed and raises rather than falling back, so trusting the filename
# turns a readable file into a parse error.

OLE2_MAGIC = b"\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1"


def test_ole2_bytes_named_rtf_are_routed_as_doc():
    """The archive's misnamed files must route on content, not on their name."""
    assert de.sniff_format(OLE2_MAGIC + b"\x00" * 64, "resume.rtf") == "doc"


def test_rtf_bytes_named_doc_are_routed_as_rtf():
    """The measured case: RTF content carrying a .doc extension."""
    assert de.sniff_format(rb"{\rtf1\ansi hello}", "resume.doc") == "rtf"


def test_pdf_is_detected_by_magic_not_extension():
    assert de.sniff_format(b"%PDF-1.5\n%\xe2\xe3\xcf\xd3", "scan.doc") == "pdf"


def test_html_is_refused_by_policy_even_though_docling_reads_it():
    """§18i excludes HTML deliberately: 71 of 94 files here are the HTML part of
    an email whose body is already in emails_fts, so indexing them creates a
    document that competes with its own email on identical text."""
    assert de.sniff_format(b"<!DOCTYPE html><html><body>hi</body></html>", "m.html") is None


def test_unknown_bytes_are_refused_rather_than_guessed():
    assert de.sniff_format(b"\x00\x01\x02\x03 not a document", "mystery.bin") is None


def test_plain_text_falls_back_to_the_extension_hint():
    """Text has no magic number, so the hint is all there is — but it may only
    select among text-ish formats, never among binary ones."""
    assert de.sniff_format(b"just some notes\n", "notes.txt") == "txt"
    assert de.sniff_format(b"just some notes\n", "notes.doc") is None


def test_a_spreadsheet_is_readable_but_never_chunked():
    """"Can we read this" and "should we chunk this" are different questions,
    and §18l is why they had to be separated.

    Chunking a spreadsheet yields windows of delimited fields, and the
    embedding of a window of fields sits nowhere near any question — there is
    no sentence in it for the model to place. They also cost 14 chunks a file
    against 4.7 for every other format. But they must still be *read*, because
    a description is generated from their text, and prose is exactly what their
    rows could never be. Refusing them at the sniffer would have taken the
    description away with the chunks."""
    assert de.sniff_format(b"a,b,c\n1,2,3\n", "data.csv") == "csv"
    assert de.sniff_format(OLE2_MAGIC + b"\x00" * 64, "budget.xls") == "xls"

    with pytest.raises(de.UnsupportedFormat):
        de.extract(b"a,b,c\n1,2,3\n", "data.csv")


def test_an_excluded_format_is_refused_before_its_magic_number_is_read():
    """The exclusion list has to be consulted first, and this is the test that
    says so.

    `.ppt` carries the OLE2 signature. Checked after the magic table, it is
    routed by its bytes and returned before the exclusion is ever reached —
    which is what it actually did: excluded on paper since §18a-1 and extracted
    in fact by any caller that sent one, because only the client's queue was
    enforcing the policy. Sniffing is the layer that has to hold it, since it
    is the one every route passes through."""
    assert de.sniff_format(OLE2_MAGIC + b"\x00" * 64, "deck.ppt") is None
    # The neighbouring format in the same container still routes normally —
    # the exclusion is by format, not by container.
    assert de.sniff_format(OLE2_MAGIC + b"\x00" * 64, "letter.doc") == "doc"


# ── The size gate ────────────────────────────────────────────────────────────
#
# §18a-2: HybridChunker took >10 min on a 3.4M-char spreadsheet and SIGALRM
# does not interrupt it, because the work is native code holding the GIL. A
# timeout is therefore not available as a control — the only control is to
# decline the call.

def test_gate_declines_input_above_the_measured_ceiling():
    assert de.should_gate("x" * (de.MAX_CHUNK_INPUT_CHARS + 1)) is True


def test_gate_allows_input_at_the_ceiling():
    assert de.should_gate("x" * de.MAX_CHUNK_INPUT_CHARS) is False


def test_gated_document_still_yields_one_searchable_chunk():
    """A gated file must stay findable by BM25 — it loses vectors, not text.
    Losing the text too would make the gate a data-loss bug rather than a
    liveness fix."""
    text = "y" * (de.MAX_CHUNK_INPUT_CHARS + 10)
    chunks = de.gated_chunks(text)

    assert len(chunks) == 1
    assert chunks[0].text == text
    assert chunks[0].chunk_index == 0
    # No page/heading: nothing was chunked, so there is no structure to cite.
    assert chunks[0].page is None


# ── Provenance resolution ────────────────────────────────────────────────────
#
# The subtle one. `chunk.meta.doc_items` in docling-rs is a list of self-ref
# *strings* ('#/texts/144'), not item objects, so reading `.prov[0].page_no`
# off them silently yields nothing and looks exactly like "this format has no
# page numbers". It cost an hour during the spike and would cost the footnote
# feature entirely if it shipped.

class _FakeProv:
    def __init__(self, page_no, charspan):
        self.page_no = page_no
        self.charspan = charspan


class _FakeItem:
    def __init__(self, self_ref, page_no=None, charspan=None):
        self.self_ref = self_ref
        self.prov = [_FakeProv(page_no, charspan)] if page_no is not None else []


class _FakeDoc:
    def __init__(self, items):
        self._items = items

    def iterate_items(self):
        return [(it, 0) for it in self._items]


class _FakeMeta:
    def __init__(self, doc_items, headings=None):
        self.doc_items = doc_items
        self.headings = headings


class _FakeChunk:
    def __init__(self, text, doc_items, headings=None):
        self.text = text
        self.meta = _FakeMeta(doc_items, headings)


def test_page_is_resolved_through_the_self_ref_index():
    """Reading prov off chunk.meta.doc_items directly cannot work — they are
    strings. The page has to come from the document's own items."""
    doc = _FakeDoc([
        _FakeItem("#/texts/0", page_no=7, charspan=(0, 40)),
        _FakeItem("#/texts/1", page_no=8, charspan=(40, 90)),
    ])
    chunks = [_FakeChunk("body", ["#/texts/0", "#/texts/1"], ["Intro"])]

    out = de.resolve_chunks(doc, chunks)

    assert out[0].page == 7, "a chunk spanning pages cites the first, where the reader lands"
    assert out[0].char_start == 0
    assert out[0].char_end == 90
    assert out[0].heading_path == "Intro"


def test_formats_without_provenance_still_produce_chunks():
    """.doc/.xls/.ppt emit no prov at all (measured). The heading path is the
    anchor there, and a missing page must not drop the chunk."""
    doc = _FakeDoc([_FakeItem("#/texts/0")])
    chunks = [_FakeChunk("body", ["#/texts/0"], ["Policy", "Summary"])]

    out = de.resolve_chunks(doc, chunks)

    assert len(out) == 1
    assert out[0].page is None
    assert out[0].heading_path == "Policy > Summary"


def test_chunk_index_is_dense_and_ordered():
    """§18e makes (file_id, chunk_index) the primary key and §18f cites the
    winning chunk, so the index must be positional, not derived from refs."""
    doc = _FakeDoc([_FakeItem(f"#/texts/{i}", page_no=i + 1) for i in range(3)])
    chunks = [_FakeChunk(f"c{i}", [f"#/texts/{i}"]) for i in range(3)]

    out = de.resolve_chunks(doc, chunks)

    assert [c.chunk_index for c in out] == [0, 1, 2]
    assert [c.page for c in out] == [1, 2, 3]


def test_unresolvable_refs_do_not_crash_the_chunk():
    """A ref with no matching item must degrade to 'no page', not raise —
    the port's ref set is not guaranteed to match iterate_items exactly."""
    doc = _FakeDoc([_FakeItem("#/texts/0", page_no=1)])
    chunks = [_FakeChunk("body", ["#/texts/999"])]

    out = de.resolve_chunks(doc, chunks)

    assert out[0].page is None
    assert out[0].text == "body"


# ── Endpoint behaviour ───────────────────────────────────────────────────────

# ── Chunker selection ────────────────────────────────────────────────────────
#
# Regression: HybridChunker does not fall back when handed tokenizer=None, it
# raises at chunk() time. Since the tokenizer ships inside the embedding
# model's snapshot, that turned "embedding model not downloaded yet" into
# "document extraction returns 422" — the opposite of §18j, which requires
# extraction to keep working and degrade search to BM25.

def test_missing_tokenizer_falls_back_instead_of_failing(monkeypatch):
    """A fresh install has no embedding model, so no tokenizer. Extraction must
    still produce chunks — text in file_chunks_fts is what keeps documents
    findable while the model downloads."""
    monkeypatch.setattr(de, "_tokenizer_path", lambda: None)
    chosen = {}

    class _FakeHierarchical:
        def chunk(self, document):
            chosen["chunker"] = "hierarchical"
            return []

    monkeypatch.setitem(
        __import__("sys").modules,
        "docling_rs.chunking",
        type("m", (), {"HierarchicalChunker": _FakeHierarchical})(),
    )

    de._chunk(object())

    assert chosen["chunker"] == "hierarchical"


def test_tokenizer_is_passed_through_when_available(monkeypatch):
    """When the tokenizer exists, the token budget must actually be applied —
    counting against docling's bundled all-MiniLM default would budget for a
    different model than the one doing the embedding."""
    monkeypatch.setattr(de, "_tokenizer_path", lambda: "/models/tokenizer.json")
    seen = {}

    class _FakeHybrid:
        def __init__(self, tokenizer=None, max_tokens=None, merge_peers=None):
            seen.update(
                tokenizer=tokenizer, max_tokens=max_tokens, merge_peers=merge_peers
            )

        def chunk(self, document):
            return []

    monkeypatch.setitem(
        __import__("sys").modules,
        "docling_rs.chunking",
        type("m", (), {"HybridChunker": _FakeHybrid})(),
    )

    de._chunk(object())

    assert seen["tokenizer"] == "/models/tokenizer.json"
    assert seen["max_tokens"] == de.CHUNK_MAX_TOKENS == 512
    assert seen["merge_peers"] is True, "§18c-1: undersized peers under one heading merge"


def test_extract_refuses_an_unsupported_format_without_calling_docling(monkeypatch):
    """Sniffing gates the expensive path; an unreadable blob must not reach the
    converter at all."""
    called = []
    monkeypatch.setattr(de, "_convert", lambda *a, **k: called.append(1))

    with pytest.raises(de.UnsupportedFormat):
        de.extract(b"\x00\x01\x02\x03", "mystery.bin")

    assert called == []


class _FakeDocument:
    def __init__(self, markdown):
        self._markdown = markdown

    def export_to_markdown(self):
        return self._markdown


def test_extract_markdown_reads_a_spreadsheet_the_chunking_path_refuses(monkeypatch):
    """The description path's whole reason to exist (§18l)."""
    monkeypatch.setattr(de, "_convert", lambda *a, **k: _FakeDocument("| a | b |\n"))

    result = de.extract_markdown(b"a,b\n1,2\n", "budget.csv")

    assert result.fmt == "csv"
    assert result.markdown == "| a | b |\n"
    assert result.chunks == [], "reading is not chunking"


def test_extract_markdown_truncates_to_the_requested_budget(monkeypatch):
    """A description is written from the head of a document — the title, the
    headers, the first rows. Carrying three megabytes of a stock export back
    over HTTP to summarise its first page is waste with no upside, and the
    model would discard the tail anyway."""
    monkeypatch.setattr(de, "_convert", lambda *a, **k: _FakeDocument("x" * 5000))

    result = de.extract_markdown(b"a,b\n", "big.csv", limit=100)

    assert len(result.markdown) == 100
    assert result.markdown_chars == 100, "the count must describe what was returned"


def test_extract_markdown_still_refuses_what_policy_excludes(monkeypatch):
    """Readable-but-unchunkable widened one door, not both: html and ppt are
    excluded because indexing them is wrong, not because chunking them is."""
    monkeypatch.setattr(de, "_convert", lambda *a, **k: _FakeDocument("hi"))

    for hint in ("mail.html", "deck.ppt"):
        with pytest.raises(de.UnsupportedFormat):
            de.extract_markdown(OLE2_MAGIC + b"\x00" * 64, hint)


# ── PDF runtime (search plan §18h-6) ─────────────────────────────────────────

class TestPdfRuntime:
    """Guards on the vendored pdfium.

    The failure these exist for already happened: docling's downloader wrote a
    Linux ELF, reported success, and every PDF failed with "the pdfium library
    is not installed" — a message describing the wrong problem entirely
    (§18d-1). The point is that a wrong-platform binary must be *loud*.
    """

    def _reset(self):
        de._pdf_ready = None
        de._pdf_reason = "not configured"

    def test_accepts_a_macho_object(self, tmp_path):
        lib = tmp_path / "libpdfium.dylib"
        lib.write_bytes(b"\xcf\xfa\xed\xfe" + b"\0" * 64)
        assert de._is_macho(str(lib))

    def test_rejects_a_linux_elf(self, tmp_path):
        # Exactly what docling's own download_models() writes on macOS.
        lib = tmp_path / "libpdfium.so"
        lib.write_bytes(b"\x7fELF" + b"\0" * 64)
        assert not de._is_macho(str(lib))

    def test_rejects_a_missing_file(self, tmp_path):
        assert not de._is_macho(str(tmp_path / "absent.dylib"))

    def test_an_external_override_is_honoured(self, monkeypatch):
        # A developer pointing at their own build should not have it silently
        # replaced by whatever happens to be vendored.
        self._reset()
        monkeypatch.setenv("PDFIUM_DYNAMIC_LIB_PATH", "/somewhere/of/my/own")
        try:
            assert de.configure_pdf_runtime() is True
        finally:
            self._reset()

    def test_a_pdf_without_pdfium_is_unavailable_not_unparseable(
        self, monkeypatch
    ):
        # 503, never 422: a missing library says nothing about the document,
        # and counting it would retire every PDF in the archive (§18h-4).
        self._reset()
        monkeypatch.delenv("PDFIUM_DYNAMIC_LIB_PATH", raising=False)
        monkeypatch.setattr(
            de, "_pdfium_search_roots", lambda: ["/nonexistent"]
        )
        try:
            with pytest.raises(de.ExtractionUnavailable):
                de._convert_raw(b"%PDF-1.4 ...", "pdf")
        finally:
            self._reset()


class TestScannedTripwire:
    """§18b turned OCR off on measurement; this is what notices if that was
    wrong for some future corpus."""

    class _Doc:
        def __init__(self, pages):
            self._pages = pages

        def num_pages(self):
            return self._pages

    def test_warns_when_a_pdf_yields_almost_no_text(self, capsys):
        de._warn_if_scanned(self._Doc(20), "a" * 100, "pdf")
        assert "likely scanned images" in capsys.readouterr().out

    def test_silent_on_a_normal_pdf(self, capsys):
        de._warn_if_scanned(self._Doc(10), "a" * 50_000, "pdf")
        assert capsys.readouterr().out == ""

    def test_silent_on_formats_that_have_no_pages(self, capsys):
        # A .doc has no pages at all, so chars-per-page is meaningless there.
        de._warn_if_scanned(self._Doc(0), "", "doc")
        assert capsys.readouterr().out == ""


# ── Legacy Word recovery (§18m) ──────────────────────────────────────────────
#
# Measured 2026-08-14 against the live archive: 142 of 229 `.doc` files parse
# through docling and 87 do not. The 87 are not corrupt. Reading their OLE2
# directories by hand shows the stream the error names is present in every one
# checked — "no WordDocument stream" on a file whose directory lists
# `WordDocument`. It is an incomplete reader, the same family as the 43% `.ppt`
# reader §18a-1 declined to use.
#
# macOS ships a complete one. `textutil` recovered 85 of the 87.

# The first bytes of `noncomp.doc` as textutil actually returned them: the
# file's own OLE2 header, decoded as text, exit code 0.
TEXTUTIL_MOJIBAKE = "–œ‡°±·\x00\x00\x00\x00˛ˇ\t\x00\x00ˇˇˇˇˇˇˇˇˇˇˇˇÄ\x00\x00"


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


class TestReadableGuard:
    """textutil does not fail on a file it cannot parse — it exits 0 and hands
    back the bytes re-encoded as text. The exit code proves nothing, so the
    output is what has to be judged."""

    def test_recovered_prose_is_readable(self):
        assert de._is_readable("Michael NIMER\n4438 South Honeywood Lane\n(801) 969-5489")

    def test_re_encoded_binary_is_not(self):
        assert not de._is_readable(TEXTUTIL_MOJIBAKE)

    def test_empty_output_is_not_readable(self):
        """A file textutil emptied is a failure, not a document with no words."""
        assert not de._is_readable("   \n\t  ")

    def test_prose_with_typographic_characters_survives(self):
        """The measured recoveries carry bullets and curly quotes; the guard
        must not mistake ordinary word processing for binary."""
        assert de._is_readable('Select “Technology” • revise the criteria — then save.')


class TestLegacyRecovery:
    def test_a_doc_docling_cannot_parse_is_recovered(self, monkeypatch):
        converter = _RecordingConverter(RuntimeError("parse error: doc: no WordDocument stream"))
        monkeypatch.setattr(de, "_convert_raw", converter)
        monkeypatch.setattr(de, "_run_textutil", lambda data, fmt: "Michael NIMER, resume")

        document = de._convert(OLE2_MAGIC + b"\x00" * 64, "doc")

        assert document.export_to_markdown() == "Michael NIMER, resume"

    def test_recovered_text_is_re_read_as_text_not_as_a_doc(self, monkeypatch):
        """The recovery returns a *document*, not a string, so the size gate,
        the chunker and provenance all behave exactly as on a first-pass parse.
        Re-reading it as `doc` would fail the same way it just did."""
        converter = _RecordingConverter(RuntimeError("parse error: doc: bad FIB magic"))
        monkeypatch.setattr(de, "_convert_raw", converter)
        monkeypatch.setattr(de, "_run_textutil", lambda data, fmt: "recovered prose here")

        de._convert(OLE2_MAGIC, "doc")

        assert converter.calls == ["doc", "txt"]

    def test_output_that_is_still_binary_leaves_the_original_error_standing(
        self, monkeypatch
    ):
        """The `noncomp.doc` case. Storing this would put the file's own header
        into the search index as though it were the document's text."""
        converter = _RecordingConverter(RuntimeError("parse error: doc: no WordDocument stream"))
        monkeypatch.setattr(de, "_convert_raw", converter)
        monkeypatch.setattr(de, "_run_textutil", lambda data, fmt: TEXTUTIL_MOJIBAKE)

        with pytest.raises(RuntimeError, match="no WordDocument stream"):
            de._convert(OLE2_MAGIC, "doc")

        assert converter.calls == ["doc"]

    def test_a_format_textutil_cannot_help_is_not_retried(self, monkeypatch):
        """Recovery is scoped to what was measured. A failed PDF is a pdfium
        problem, and running a Word converter over it would only turn one
        honest error into two."""
        converter = _RecordingConverter(RuntimeError("parse error: pdf: broken xref"))
        monkeypatch.setattr(de, "_convert_raw", converter)
        monkeypatch.setattr(
            de, "_run_textutil", lambda data, fmt: pytest.fail("textutil consulted")
        )

        with pytest.raises(RuntimeError, match="broken xref"):
            de._convert(b"%PDF-1.4", "pdf")

    def test_an_environmental_failure_is_never_masked_by_recovery(self, monkeypatch):
        """A missing library must stay a 503. If recovery could answer it, a
        `.doc` would quietly return degraded text on a box whose extraction
        stack is broken, and nothing would ever say so."""
        monkeypatch.setattr(
            de,
            "_convert_raw",
            lambda data, fmt: (_ for _ in ()).throw(
                RuntimeError("the pdfium library is not installed")
            ),
        )
        monkeypatch.setattr(
            de, "_run_textutil", lambda data, fmt: pytest.fail("textutil consulted")
        )

        with pytest.raises(de.ExtractionUnavailable):
            de._convert(OLE2_MAGIC, "doc")

    def test_recovery_is_skipped_where_textutil_does_not_exist(self, monkeypatch):
        """`_run_textutil` returning None is how every non-macOS host, and every
        textutil crash, arrives here: the original error stands."""
        converter = _RecordingConverter(RuntimeError("parse error: doc: bad FIB magic"))
        monkeypatch.setattr(de, "_convert_raw", converter)
        monkeypatch.setattr(de, "_run_textutil", lambda data, fmt: None)

        with pytest.raises(RuntimeError, match="bad FIB magic"):
            de._convert(OLE2_MAGIC, "doc")


class TestTextutilRunner:
    def test_returns_none_off_macos(self, monkeypatch):
        monkeypatch.setattr(de.sys, "platform", "linux")
        assert de._run_textutil(b"anything", "doc") is None

    def test_a_nonzero_exit_is_not_a_recovery(self, monkeypatch):
        monkeypatch.setattr(de.sys, "platform", "darwin")
        monkeypatch.setattr(
            de.subprocess, "run", lambda *a, **k: _CompletedProcess(1, b"")
        )
        assert de._run_textutil(b"anything", "doc") is None

    def test_a_crash_or_timeout_is_not_a_recovery(self, monkeypatch):
        """textutil is a subprocess on someone else's machine; it is allowed to
        die without taking the extraction request with it."""
        monkeypatch.setattr(de.sys, "platform", "darwin")

        def _boom(*a, **k):
            raise OSError("no such binary")

        monkeypatch.setattr(de.subprocess, "run", _boom)
        assert de._run_textutil(b"anything", "doc") is None


class _CompletedProcess:
    def __init__(self, returncode, stdout):
        self.returncode = returncode
        self.stdout = stdout


# ── Legacy text encodings (§18n) ─────────────────────────────────────────────
#
# docling reads the textual formats as UTF-8 and raises on the first byte that
# is not. A 1999 CSV exported from Windows is not UTF-8, and one byte in one
# Swedish surname was enough to lose all 14kB of it — logins, ids and addresses
# that are pure ASCII and perfectly readable.

# `...a.se,385081,Mats R\x86de` — the real bytes, at the real offset.
LEGACY_CSV = (
    b"login,id,name\r\n"
    b"mats,385081,Mats R\x86de\r\n"
    b"bob,46495,Bob Kafato\r\n"
)


class TestEncodingRecovery:
    def test_utf8_is_passed_through_untouched(self):
        """The common case must be byte-identical, not round-tripped through a
        detector that could disagree with itself."""
        data = "name,city\nZoë,Zürich\n".encode("utf-8")
        assert de._as_utf8(data, "csv") is data

    def test_a_legacy_encoding_is_transcoded(self):
        """The whole point: one undecodable byte must not cost the document."""
        result = de._as_utf8(LEGACY_CSV, "csv")

        assert result is not LEGACY_CSV
        result.decode("utf-8")  # no exception: docling can now read it

    def test_the_ascii_the_file_is_mostly_made_of_survives(self):
        """What is actually being rescued. The detector may or may not land on
        the right character for byte 0x86; everything either side of it is
        unambiguous and is what someone would search for."""
        text = de._as_utf8(LEGACY_CSV, "csv").decode("utf-8")

        assert "385081" in text
        assert "Bob Kafato" in text
        assert "login,id,name" in text

    def test_a_binary_format_is_never_transcoded(self):
        """A .doc carries its encoding inside the container. Rewriting those
        bytes as though they were text would corrupt the file on its way to a
        parser that was reading it correctly."""
        ole2 = OLE2_MAGIC + b"\x86\x00\x91"
        assert de._as_utf8(ole2, "doc") is ole2

    def test_undecodable_input_is_left_for_docling_to_refuse(self, monkeypatch):
        """When nothing decodes, the honest outcome is the original parse
        error — a 422 that spends an attempt — not a fabricated document."""
        monkeypatch.setattr(de, "_detect_text", lambda data: None)
        assert de._as_utf8(LEGACY_CSV, "csv") is LEGACY_CSV

    def test_transcoding_happens_before_docling_sees_the_bytes(self, monkeypatch):
        """`_convert` is the seam both `extract` and `extract_markdown` share,
        so the description path gets this for free."""
        seen = []
        monkeypatch.setattr(
            de, "_convert_raw", lambda data, fmt: seen.append(data) or _FakeDocument("ok")
        )

        de._convert(LEGACY_CSV, "csv")

        seen[0].decode("utf-8")  # no exception


class TestDetectionCost:
    """Detection is O(n) despite charset_normalizer's docstring claiming it
    samples "5 blocks of 512o". Measured 2026-08-14: 1.9s and a 210MB peak on
    a 50MB file, against 36ms and 157MB when detection reads a preview and the
    decode is done directly. Same encoding, byte-identical text, at 1MB, 10MB
    and 50MB.
    """

    def test_detection_reads_only_a_preview(self, monkeypatch):
        """The fix. Extraction runs in a threadpool rather than on the event
        loop, so this was never a liveness bug — but a second of CPU and four
        times the file in peak memory is a worker held for no reason."""
        import charset_normalizer

        seen = {}
        real = charset_normalizer.from_bytes

        def _spy(payload, *args, **kwargs):
            seen["size"] = len(payload)
            return real(payload, *args, **kwargs)

        monkeypatch.setattr(charset_normalizer, "from_bytes", _spy)

        big = LEGACY_CSV * 20_000
        assert len(big) > de._DETECT_PREVIEW_BYTES
        de._detect_text(big)

        assert seen["size"] == de._DETECT_PREVIEW_BYTES

    def test_the_whole_file_is_still_decoded_not_just_the_preview(self):
        """Detecting on a preview must not truncate the document to it."""
        big = LEGACY_CSV * 20_000
        text = de._detect_text(big)

        assert text is not None
        assert len(text) >= len(big) - 1  # one byte per row is a 1-char codepoint

    def test_a_byte_the_detected_codepage_cannot_read_does_not_cost_the_file(
        self, monkeypatch
    ):
        """Detection now sees a preview, so a rare byte later in the file can
        be one the chosen codepage has no mapping for. §18n's trade says the
        ASCII either side of it is still worth having, so that byte becomes a
        replacement character rather than an exception that discards 14kB."""
        import charset_normalizer

        class _Match:
            encoding = "ascii"
            coherence = 0.9

        class _Result:
            def best(self):
                return _Match()

        monkeypatch.setattr(charset_normalizer, "from_bytes", lambda *a, **k: _Result())

        text = de._detect_text(b"login,id\r\nmats,R\x86de\r\n")

        assert text is not None
        assert "login,id" in text and "mats,R" in text
