"""Document → markdown → chunks, for search Phase 7 (SEARCH_PLAN §18).

Extraction runs through ``docling-rs``, the Rust port of IBM's docling. Three
things about it are non-obvious enough that the code would look arbitrary
without them, all measured during the §18h step 0 spike:

* **Routing is by filename extension, not by content.** ``DocumentStream``
  detects format from the ``name`` it is handed, and a wrong extension raises
  rather than falling back. This archive contains RTF files named ``.doc``
  (§18a), so we sniff the bytes ourselves and hand docling a *synthesized*
  name carrying the extension the content actually deserves.

* **Chunking large tables does not return, and cannot be cancelled.** A 3.4M
  character spreadsheet ran over ten minutes with no result, and ``SIGALRM``
  never fires because the work happens in native code holding the GIL — so a
  timeout is not available as a control here. The only control is to decline
  the call, which is what ``should_gate`` is (§18a-2).

* **Chunk provenance is indirect.** ``chunk.meta.doc_items`` is a list of
  self-ref *strings*, not item objects; the pages live on the document. See
  ``resolve_chunks``.

The endpoint takes bytes rather than a path, matching the thumbnail endpoint's
structural fix for AUDIT H2 — the server never becomes a local-file read
oracle, and the client keeps the job of resolving cloud files (§18i).

**PDF is not wired up here.** Everything in this module works on PDFs already,
but they additionally need docling's model pack *and* a macOS ``libpdfium``
this project must vendor itself — docling's own downloader ships a Linux
binary and reports success (§18d-1). We vendor a macOS arm64
``libpdfium.dylib`` instead and point ``PDFIUM_DYNAMIC_LIB_PATH`` at it — see
``configure_pdf_runtime`` below. Without it a PDF comes back as a **503**
(``ExtractionUnavailable``), deliberately not a 422, so it does not spend its
retry budget waiting for a library.

**The 2 GB model pack is not required.** Measured 2026-08-13: with
``do_ocr=False`` and an empty ``artifacts_path``, both sampled archive PDFs
converted completely and with full page provenance. The ONNX pack buys OCR and
layout/table analysis, and §18b measured **zero** scanned pages in this
archive — so a born-digital PDF's embedded text layer is all we read, and
pdfium alone reads it. That turns step 5 from "ship a 2 GB opt-in download"
into "vendor 3.4 MB", and an earlier draft of §18d that treated the pack as a
prerequisite is corrected in §18h-6.
"""
from __future__ import annotations

import io
import os
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from typing import Any, List, Optional

from .utils import _resolve_models_base

# The largest markdown input measured to chunk in bounded time: 291k chars
# completed in 5.1s, 1.5M did not finish in ten minutes. Superlinear, so the
# ceiling sits just under the last known-good point rather than between them.
MAX_CHUNK_INPUT_CHARS = 300_000

# §18c-1: sections first, 512-token ceiling. docling's own default is 256.
CHUNK_MAX_TOKENS = 512

# The embedding model whose tokenizer decides what "512 tokens" means. Counting
# against docling's bundled all-MiniLM tokenizer would budget for a different
# model than the one that embeds the text.
EMBEDDING_MODEL_DIR = "Qwen-Qwen3-VL-Embedding-2B-local"


class UnsupportedFormat(Exception):
    """The bytes are not a document we index, or not one docling can read."""


class ExtractionUnavailable(Exception):
    """This server cannot extract this format *right now* — a missing
    dependency, not a bad document.

    The distinction is the whole of §18i's permanent/transient split, and
    getting it wrong is expensive in a way that is invisible at the time. A PDF
    that fails because ``libpdfium`` is not installed looks exactly like a
    corrupt PDF from the caller's side, so the client counts an attempt; five
    passes later the file is retired permanently, and it stays retired after
    the library is installed. Measured on this archive that had already
    retired 29 of 47 PDFs before the PDF pipeline was even scheduled to ship.
    """


# Substrings that mark a docling failure as environmental rather than about the
# document. Matched on the message because the Rust bindings raise one
# ConversionError for everything — there is no exception type to switch on.
_UNAVAILABLE_MARKERS = (
    "pdfium",
    "library is not installed",
    "model not found",
    "download_dependencies",
)


@dataclass
class Chunk:
    chunk_index: int
    text: str
    page: Optional[int] = None
    heading_path: Optional[str] = None
    char_start: Optional[int] = None
    char_end: Optional[int] = None


@dataclass
class Extraction:
    fmt: str
    markdown_chars: int
    gated: bool
    chunks: List[Chunk]
    # Only the description path (§18l) asks for the text itself; the chunking
    # path reads it through `chunks` and would pay to send it twice.
    markdown: Optional[str] = None


# ── PDF runtime ──────────────────────────────────────────────────────────────

# Where the vendored dylib lands: beside the frozen binary under PyInstaller,
# and in the source tree during development. `make pdfium` populates the
# latter; main.spec copies it into the former.
_PDFIUM_SUBDIR = os.path.join("vendor", "pdfium", "lib")
_PDFIUM_LIB = "libpdfium.dylib"

# Set once, at import, and read by the Rust side on first PDF.
_pdf_ready: Optional[bool] = None
_pdf_reason: str = "not configured"


def _pdfium_search_roots() -> List[str]:
    """Directories that may hold the vendored pdfium, most specific first."""
    roots = []
    # PyInstaller one-file/one-dir: assets are unpacked beside the executable.
    meipass = getattr(__import__("sys"), "_MEIPASS", None)
    if meipass:
        roots.append(os.path.join(meipass, _PDFIUM_SUBDIR))
    # Running from source: aiserver/vendor/pdfium/lib
    here = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    roots.append(os.path.join(here, _PDFIUM_SUBDIR))
    return roots


def _is_macho(path: str) -> bool:
    """True if `path` is a Mach-O object.

    Checked rather than assumed because the failure this guards against
    already happened once: docling's own downloader wrote a **Linux ELF**
    pdfium, reported success, and every PDF then failed with "the pdfium
    library is not installed" — a message that describes the wrong problem and
    cost an afternoon to see through (§18d-1). A four-byte read makes the next
    occurrence say what is actually wrong.
    """
    try:
        with open(path, "rb") as handle:
            magic = handle.read(4)
    except OSError:
        return False
    # 64-bit Mach-O, little- and big-endian, plus the universal-binary wrapper.
    return magic in (
        b"\xcf\xfa\xed\xfe",
        b"\xfe\xed\xfa\xcf",
        b"\xca\xfe\xba\xbe",
        b"\xbe\xba\xfe\xca",
    )


def configure_pdf_runtime() -> bool:
    """Point docling at the vendored pdfium. Idempotent; returns readiness.

    Deliberately does *not* configure `artifacts_path`. The ONNX pack is only
    needed for OCR and layout analysis, and this archive has no scanned pages
    (§18b) — see the module docstring.
    """
    global _pdf_ready, _pdf_reason
    if _pdf_ready is not None:
        return _pdf_ready

    # An explicit override wins: a developer pointing at their own build should
    # not have it silently replaced by whatever happens to be vendored.
    if os.environ.get("PDFIUM_DYNAMIC_LIB_PATH"):
        _pdf_ready, _pdf_reason = True, "PDFIUM_DYNAMIC_LIB_PATH set externally"
        return True

    for root in _pdfium_search_roots():
        candidate = os.path.join(root, _PDFIUM_LIB)
        if not os.path.exists(candidate):
            continue
        if not _is_macho(candidate):
            _pdf_reason = (
                f"{candidate} is not a Mach-O object — wrong platform build; "
                "PDF extraction disabled"
            )
            print(f"[ERROR] extract-text: {_pdf_reason}", flush=True)
            _pdf_ready = False
            return False
        os.environ["PDFIUM_DYNAMIC_LIB_PATH"] = root
        _pdf_ready, _pdf_reason = True, candidate
        print(f"[INFO] extract-text: pdfium at {candidate}", flush=True)
        return True

    _pdf_reason = (
        f"no {_PDFIUM_LIB} in {_pdfium_search_roots()} — run `make pdfium`"
    )
    print(f"[WARN] extract-text: {_pdf_reason}", flush=True)
    _pdf_ready = False
    return False


def pdf_unavailable_reason() -> str:
    """Why PDFs cannot be read, for the 503 body."""
    return _pdf_reason


# ── Sniffing ─────────────────────────────────────────────────────────────────

# Content signatures, longest-prefix first. Order matters: OLE2 covers .doc,
# .xls and .ppt alike, so the container is identified here and the extension
# hint disambiguates which application wrote it.
_MAGIC = (
    (b"%PDF", "pdf"),
    (b"{\\rtf", "rtf"),
    (b"\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1", "_ole2"),
    (b"PK\x03\x04", "_zip"),
)

# Which OLE2 payload the extension claims. A wrong guess here costs one parse
# error, not a security problem, so the hint is allowed to decide.
_OLE2_BY_HINT = {"xls": "xls", "doc": "doc"}
_ZIP_BY_HINT = {"docx": "docx", "xlsx": "xlsx", "pptx": "pptx"}

# Formats with no magic number at all — the hint is the only evidence.
_TEXTUAL = {"txt": "txt", "csv": "csv", "md": "md", "markdown": "md"}

# Formats we will not read at all, whatever their bytes say.
#
# * htm/html — §18i policy: most are the HTML part of a mail whose body is
#   already indexed, so they compete with their own email on identical text.
# * ppt — §18a-1 measured docling's legacy CFB reader at a 43% parse rate,
#   yielding slide titles only. `pptx` is a different reader and stays.
_EXCLUDED_HINTS = {"htm", "html", "ppt"}

# Readable, but never chunked (§18l).
#
# A row is not a passage: a window of delimited fields embeds nowhere near any
# question, and spreadsheets cost 14 chunks a file against 4.7 for every other
# format — the least retrieval for the most vectors. They are still *read*,
# because a description is generated from their text, and prose is the thing
# their rows could never be. So "can we read this" and "should we chunk this"
# are two questions, and this is the second one.
_UNCHUNKABLE = {"csv", "xls", "xlsx"}


def _hint_ext(filename_hint: Optional[str]) -> str:
    if not filename_hint or "." not in filename_hint:
        return ""
    return filename_hint.rsplit(".", 1)[-1].lower()


def sniff_format(data: bytes, filename_hint: Optional[str] = None) -> Optional[str]:
    """Return the format to route as, or None if we will not index these bytes.

    Content wins over the filename wherever the content is self-identifying;
    the hint only breaks ties the magic number cannot (which OLE2 application,
    and the text formats that have no signature).
    """
    ext = _hint_ext(filename_hint)
    head = data[:8]

    # Before the magic numbers, not after. An excluded format that *does* have
    # a signature — every one of ppt, xls and xlsx — would otherwise be routed
    # by its magic number and returned before the exclusion was ever consulted,
    # which is exactly what `.ppt` did: declined on paper since §18a-1, and
    # extracted in fact by any caller that sent one. The client's queue was the
    # only thing enforcing the policy, so the rule and the code agreed only for
    # as long as the two lists did.
    if ext in _EXCLUDED_HINTS:
        return None

    for magic, fmt in _MAGIC:
        if head.startswith(magic):
            if fmt == "_ole2":
                # An unhinted OLE2 file is far more often a .doc than anything
                # else; a wrong guess costs one parse error.
                return _OLE2_BY_HINT.get(ext, "doc")
            if fmt == "_zip":
                # A bare .zip is not a document; only the OOXML hints qualify.
                return _ZIP_BY_HINT.get(ext)
            return fmt

    # No signature. Only textual formats may be claimed by extension alone —
    # otherwise a truncated binary named .doc would be handed to the MS-DOC
    # parser as if it were text.
    return _TEXTUAL.get(ext)


# ── The size gate ────────────────────────────────────────────────────────────

def should_gate(markdown: str) -> bool:
    """True when chunking this input would risk not returning at all (§18a-2)."""
    return len(markdown) > MAX_CHUNK_INPUT_CHARS


def gated_chunks(markdown: str) -> List[Chunk]:
    """The whole document as one un-vectorizable row.

    The text is kept so the file stays findable through ``file_chunks_fts``;
    only semantic search over it is lost. Dropping the text too would turn a
    liveness fix into silent data loss.
    """
    return [Chunk(chunk_index=0, text=markdown)]


# ── Provenance ───────────────────────────────────────────────────────────────

def _heading_path(meta: Any) -> Optional[str]:
    headings = getattr(meta, "headings", None)
    if not headings:
        return None
    return " > ".join(str(h) for h in headings)


def resolve_chunks(document: Any, raw_chunks: List[Any]) -> List[Chunk]:
    """Attach page and character offsets to each chunk.

    ``chunk.meta.doc_items`` holds ``self_ref`` strings such as
    ``'#/texts/144'``, so provenance cannot be read off the chunk. Walk the
    document once to index ``self_ref → prov``, then resolve. Formats that
    carry no provenance at all (.doc/.xls/.ppt — measured) still produce
    chunks; they are anchored by heading path instead.
    """
    index = {}
    for item, _level in document.iterate_items():
        ref = getattr(item, "self_ref", None)
        prov = getattr(item, "prov", None)
        if ref and prov:
            index[ref] = prov[0]

    out: List[Chunk] = []
    for position, chunk in enumerate(raw_chunks):
        provs = [
            index[ref]
            for ref in (getattr(chunk.meta, "doc_items", None) or [])
            if ref in index
        ]
        pages = [p.page_no for p in provs if getattr(p, "page_no", None) is not None]
        spans = [p.charspan for p in provs if getattr(p, "charspan", None)]

        out.append(
            Chunk(
                chunk_index=position,
                text=chunk.text or "",
                # A chunk can span pages ([2, 3] was measured); cite the first,
                # because that is where the reader should land.
                page=min(pages) if pages else None,
                heading_path=_heading_path(chunk.meta),
                char_start=min(s[0] for s in spans) if spans else None,
                char_end=max(s[1] for s in spans) if spans else None,
            )
        )
    return out


# ── Conversion ───────────────────────────────────────────────────────────────

def _tokenizer_path() -> Optional[str]:
    """The embedding model's tokenizer.json, if it has been downloaded."""
    candidate = os.path.join(_resolve_models_base(), EMBEDDING_MODEL_DIR, "tokenizer.json")
    return candidate if os.path.exists(candidate) else None


def _convert(data: bytes, fmt: str):
    """Bytes → DoclingDocument, routed by the format we sniffed.

    ``do_ocr=False`` because §18b found no scanned pages in this archive and
    OCR is the expensive path; a scanned PDF yields little text instead of
    costing minutes, and §18b's tripwire is what notices.
    """
    data = _as_utf8(data, fmt)
    try:
        return _convert_raw(data, fmt)
    except ExtractionUnavailable:
        raise
    except Exception as e:
        # Re-raise environmental failures as their own type so the route can
        # answer 503 instead of 422 — see ExtractionUnavailable. Matched on the
        # message because the bindings raise one ConversionError for
        # everything; there is no exception type to switch on.
        message = str(e).lower()
        if any(marker in message for marker in _UNAVAILABLE_MARKERS):
            raise ExtractionUnavailable(str(e)) from e
        recovered = _recover_legacy(data, fmt)
        if recovered is not None:
            return recovered
        raise


# ── Legacy text encodings (§18n) ─────────────────────────────────────────────
#
# docling reads the textual formats as UTF-8 and raises on the first byte that
# is not one. This archive is full of files that predate UTF-8 being the
# default anywhere: a 1999 CSV exported from Windows cost all 14kB of itself —
# logins, ids and addresses, pure ASCII and perfectly readable — over a single
# byte in a single Swedish surname.
#
# Only the formats docling reads *as text* need this. Everything else carries
# its encoding declaration inside the container, and rewriting those bytes
# would corrupt a file that was being read correctly.
_TRANSCODABLE = frozenset(_TEXTUAL.values())


def _detect_text(data: bytes) -> Optional[str]:
    """Best guess at what this byte string says, or None if there is none.

    charset_normalizer ships with `requests`, so this adds nothing to the
    bundle. It is a *guess*: for the CSV above it picks cp1250, which is
    coherent and may still be the wrong codepage for one accented character in
    one name. That trade is deliberate — the alternative on offer is not a
    perfect reading, it is no reading at all.
    """
    from charset_normalizer import from_bytes

    best = from_bytes(data).best()
    if best is None:
        return None
    print(
        f"[INFO] extract-text: not UTF-8; re-read as {best.encoding} "
        f"(coherence {best.coherence:.2f})",
        flush=True,
    )
    return str(best)


def _as_utf8(data: bytes, fmt: str) -> bytes:
    """Hand docling something it can read, or hand back what we were given.

    Returning the original object unchanged on the UTF-8 path matters: the
    common case must not be round-tripped through a detector that could
    disagree with the bytes it was handed.
    """
    if fmt not in _TRANSCODABLE:
        return data

    try:
        data.decode("utf-8")
        return data
    except UnicodeDecodeError:
        pass

    text = _detect_text(data)
    if text is None:
        # Nothing decodes it. The honest outcome is docling's own parse error —
        # a 422 that spends an attempt — rather than a fabricated document.
        return data
    return text.encode("utf-8")


def _convert_raw(data: bytes, fmt: str):
    """The docling call itself, split out so the classification above can be
    tested without a real missing library."""
    from docling_rs import DocumentConverter, DocumentStream

    if fmt == "pdf" and not configure_pdf_runtime():
        # Raised before the call so the message names the real problem. Left
        # to docling, this surfaces as "the pdfium library is not installed"
        # even when the library is present and simply built for Linux.
        raise ExtractionUnavailable(
            f"PDF extraction unavailable: {pdf_unavailable_reason()}"
        )

    converter = DocumentConverter(do_ocr=False)
    # The synthesized name is the whole point: docling routes on this
    # extension, and it is the sniffed format rather than the caller's.
    source = DocumentStream(name=f"document.{fmt}", stream=io.BytesIO(data))
    return converter.convert(source).document


# ── Legacy Word recovery (§18m) ──────────────────────────────────────────────
#
# docling's Rust CFB reader is incomplete. Measured 2026-08-14 against the live
# archive: 142 of 229 `.doc` files parse and 87 do not — and the 87 are not
# corrupt. Reading their OLE2 directories by hand shows the stream the error
# names is present in every one checked, including a plain Word 8.0 file
# carrying both `WordDocument` and `1Table` that reports "no WordDocument
# stream". It is a 62% reader, of the same family as the 43% `.ppt` reader
# §18a-1 declined to use.
#
# macOS ships a complete one, in the base system, with no dependency to add:
# `textutil` recovered 85 of those 87. It runs only after docling has failed,
# so a working parse never pays for it.
_TEXTUTIL_RECOVERABLE = {"doc"}

_TEXTUTIL = "/usr/bin/textutil"
_TEXTUTIL_TIMEOUT_SECONDS = 60

# textutil does not fail on a file it cannot parse. It reads the bytes as plain
# text and **exits 0**, returning the file's own OLE2 header as mojibake —
# `noncomp.doc` in this archive does exactly that. So the exit code proves
# nothing about the output and the text itself has to be judged.
#
# Measured over the 87 failures: all 85 real recoveries scored 0.92 or better
# and both unreadable files scored far below, so 0.85 sits in the gap with room
# on either side.
_MIN_READABLE_RATIO = 0.85

_READABLE_PUNCTUATION = frozenset(" .,;:'\"()-/&$%#@!?+=*[]{}<>_|\\~`^")


def _is_readable(text: str) -> bool:
    """Whether this looks like recovered prose rather than re-encoded binary.

    Deliberately strict: it counts only ASCII alphanumerics and common
    punctuation, so a document written in a non-Latin script would be judged
    unreadable and declined. That is the right way round for a *fallback* —
    docling has already failed by the time this runs, so a false reject costs
    the status quo, while a false accept writes binary into the search index as
    though it were the document's text.
    """
    body = "".join(ch for ch in text if not ch.isspace())
    if not body:
        return False
    readable = sum(
        1
        for ch in body
        if ch.isascii() and (ch.isalnum() or ch in _READABLE_PUNCTUATION)
    )
    return readable / len(body) >= _MIN_READABLE_RATIO


def _run_textutil(data: bytes, fmt: str) -> Optional[str]:
    """macOS's own Word reader, or None where it cannot be used.

    The bytes go through a temp file because textutil takes a path and will not
    read stdin. None covers every way this can decline — a non-macOS host, a
    missing binary, a crash, a timeout, a non-zero exit — because the caller
    treats them all the same way: leave docling's original error standing.
    """
    if sys.platform != "darwin":
        return None

    try:
        with tempfile.NamedTemporaryFile(suffix=f".{fmt}") as handle:
            handle.write(data)
            handle.flush()
            result = subprocess.run(
                [_TEXTUTIL, "-convert", "txt", "-stdout", handle.name],
                capture_output=True,
                timeout=_TEXTUTIL_TIMEOUT_SECONDS,
            )
    except (OSError, subprocess.SubprocessError):
        return None

    if result.returncode != 0:
        return None
    return result.stdout.decode("utf-8", "replace")


def _recover_legacy(data: bytes, fmt: str):
    """Retry a docling parse failure through macOS's Word reader.

    Returns a *document*, not a string, so the size gate, the chunker and
    provenance all behave exactly as they do on a first-pass parse — or None to
    let the original error stand.
    """
    if fmt not in _TEXTUTIL_RECOVERABLE:
        return None

    text = _run_textutil(data, fmt)
    if text is None or not _is_readable(text):
        return None

    print(
        f"[INFO] extract-text: docling could not read a .{fmt}; recovered "
        f"{len(text)} chars via textutil",
        flush=True,
    )
    # Re-read as plain text: `txt` is a format docling does handle, and this
    # keeps one code path for chunking instead of a second hand-rolled one.
    return _convert_raw(text.encode("utf-8"), "txt")


def _chunk(document) -> List[Any]:
    """HybridChunker where possible, HierarchicalChunker where necessary.

    Hybrid is the default because Hierarchical has no size ceiling at all —
    one table becomes one chunk, measured at 3.4M characters (§18a-2) — so the
    token budget is what bounds chunk size.

    But Hybrid *requires* a tokenizer: passing ``None`` does not fall back, it
    raises at ``chunk()`` time. The tokenizer ships inside the embedding
    model's snapshot, so "no tokenizer" means the embedding model has not been
    downloaded — and §18j is explicit that extraction must still work in that
    state, degrading document search to BM25 rather than to nothing. Falling
    back keeps text flowing into ``file_chunks_fts``; the vectors arrive later
    when the model does.

    The fallback is safe because ``should_gate`` has already run: the input is
    at most ``MAX_CHUNK_INPUT_CHARS``, so the unbounded chunker cannot be
    handed the pathological table that made bounding necessary.
    """
    tokenizer = _tokenizer_path()
    if tokenizer is None:
        from docling_rs.chunking import HierarchicalChunker

        print(
            "[WARN] extract-text: no tokenizer at "
            f"{EMBEDDING_MODEL_DIR}/tokenizer.json — chunking without a token "
            "budget. Chunks will not be size-bounded until the embedding model "
            "is downloaded.",
            flush=True,
        )
        return list(HierarchicalChunker().chunk(document))

    from docling_rs.chunking import HybridChunker

    return list(
        HybridChunker(
            tokenizer=tokenizer,
            max_tokens=CHUNK_MAX_TOKENS,
            merge_peers=True,
        ).chunk(document)
    )


# Below this many characters per page, a PDF is probably scanned images
# rather than text. §18b measured 14–392 text-showing operators per page
# across this archive's PDFs — all born-digital — so this fires on a corpus
# that does not exist here yet, which is exactly what a tripwire is for.
MIN_CHARS_PER_PAGE = 40


def _warn_if_scanned(document: Any, markdown: str, fmt: str) -> None:
    """Log when a PDF looks scanned, rather than turning OCR on for everyone.

    OCR is the expensive path and §18b found nothing here that needs it. The
    cost of being wrong is a PDF that indexes as near-empty — invisible unless
    something says so, which is what this does.
    """
    if fmt != "pdf":
        return
    try:
        pages = document.num_pages()
    except Exception:
        return
    if not pages:
        return
    per_page = len(markdown) / pages
    if per_page < MIN_CHARS_PER_PAGE:
        print(
            f"[WARN] extract-text: PDF yielded {per_page:.0f} chars/page over "
            f"{pages} pages — likely scanned images. OCR is off (§18b); this "
            "document will index as near-empty.",
            flush=True,
        )


def extract_markdown(
    data: bytes, filename_hint: Optional[str] = None, limit: int = 0
) -> Extraction:
    """Read a document to markdown without chunking it (§18l).

    The description path's entry point. It accepts everything ``extract``
    accepts *and* the unchunkable formats, because a spreadsheet is exactly the
    case descriptions exist for: readable, worth finding, and impossible to
    chunk usefully.

    ``limit`` truncates the returned text. A description is written from the
    head of a document — the title, the headers, the first rows — so there is
    no reason to carry three megabytes of a stock export back over HTTP to
    summarise its first page. Zero means no limit.
    """
    fmt = sniff_format(data, filename_hint)
    if fmt is None:
        raise UnsupportedFormat(
            f"unsupported or excluded document format (hint={filename_hint!r})"
        )

    markdown = _convert(data, fmt).export_to_markdown()
    if limit and len(markdown) > limit:
        markdown = markdown[:limit]
    return Extraction(
        fmt=fmt, markdown_chars=len(markdown), gated=False, chunks=[], markdown=markdown
    )


def extract(data: bytes, filename_hint: Optional[str] = None) -> Extraction:
    """Extract and chunk a document supplied as raw bytes.

    Raises ``UnsupportedFormat`` before doing any expensive work when the bytes
    are not something we index.
    """
    fmt = sniff_format(data, filename_hint)
    if fmt is None or fmt in _UNCHUNKABLE:
        raise UnsupportedFormat(
            f"unsupported or excluded document format (hint={filename_hint!r})"
        )

    document = _convert(data, fmt)
    markdown = document.export_to_markdown()
    _warn_if_scanned(document, markdown, fmt)

    if should_gate(markdown):
        return Extraction(
            fmt=fmt,
            markdown_chars=len(markdown),
            gated=True,
            chunks=gated_chunks(markdown),
        )

    return Extraction(
        fmt=fmt,
        markdown_chars=len(markdown),
        gated=False,
        chunks=resolve_chunks(document, _chunk(document)),
    )
