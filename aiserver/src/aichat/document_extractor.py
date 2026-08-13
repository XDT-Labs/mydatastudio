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
binary and reports success (§18d-1). Until §18h step 5 sets
``PDFIUM_DYNAMIC_LIB_PATH`` and ``artifacts_path``, a PDF reaches ``_convert``
and comes back as a 422. The formats that make up ~85% of the archive
(.doc/.xls/.rtf/.txt/.csv) need neither.
"""
from __future__ import annotations

import io
import os
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
_OLE2_BY_HINT = {"xls": "xls", "ppt": "ppt", "doc": "doc"}
_ZIP_BY_HINT = {"docx": "docx", "xlsx": "xlsx", "pptx": "pptx"}

# Formats with no magic number at all — the hint is the only evidence.
_TEXTUAL = {"txt": "txt", "csv": "csv", "md": "md", "markdown": "md"}

# Deliberately absent from every table above: htm/html (§18i policy) and ppt
# (§18a-1 measured 43% parse rate yielding slide titles only).
_EXCLUDED_HINTS = {"htm", "html", "ppt"}


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

    for magic, fmt in _MAGIC:
        if head.startswith(magic):
            if fmt == "_ole2":
                return _OLE2_BY_HINT.get(ext, "doc")
            if fmt == "_zip":
                # A bare .zip is not a document; only the OOXML hints qualify.
                return _ZIP_BY_HINT.get(ext)
            return fmt

    if ext in _EXCLUDED_HINTS:
        return None

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
    from docling_rs import DocumentConverter, DocumentStream

    converter = DocumentConverter(do_ocr=False)
    # The synthesized name is the whole point: docling routes on this
    # extension, and it is the sniffed format rather than the caller's.
    source = DocumentStream(name=f"document.{fmt}", stream=io.BytesIO(data))
    return converter.convert(source).document


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


def extract(data: bytes, filename_hint: Optional[str] = None) -> Extraction:
    """Extract and chunk a document supplied as raw bytes.

    Raises ``UnsupportedFormat`` before doing any expensive work when the bytes
    are not something we index.
    """
    fmt = sniff_format(data, filename_hint)
    if fmt is None:
        raise UnsupportedFormat(
            f"unsupported or excluded document format (hint={filename_hint!r})"
        )

    document = _convert(data, fmt)
    markdown = document.export_to_markdown()

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
