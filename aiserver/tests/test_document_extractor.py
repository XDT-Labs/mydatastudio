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
