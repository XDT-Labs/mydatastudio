"""End-to-end tests for /util/extract-text, against the real docling-rs.

The unit tests in test_document_extractor.py cover the logic with fakes; these
run bytes through the actual library so the wiring is pinned too — the
sniff → synthesized-name → convert → chunk path is exactly where a library
upgrade would break silently.

Only formats that need no model download are used here (txt/csv/rtf), so the
suite stays runnable on a machine that has never fetched docling's 2 GB pack.
PDF is deliberately absent: it additionally needs a vendored macOS pdfium
(SEARCH_PLAN §18d-1) and belongs with the step-5 work.
"""
import base64

import pytest
from fastapi import HTTPException

from aichat import document_extractor as de
from aichat.document_extractor import MAX_CHUNK_INPUT_CHARS
from aichat.models import ExtractTextRequest
from aichat.routes import extract_text


def _b64(data: bytes) -> str:
    return base64.b64encode(data).decode("utf-8")


async def _extract(data: bytes, filename: str | None):
    return await extract_text(ExtractTextRequest(file_base64=_b64(data), filename=filename))


async def test_plain_text_round_trips_into_chunks():
    body = b"# Notes\n\nThe quarterly review is on Tuesday.\n"
    result = await _extract(body, "notes.txt")

    assert result["format"] == "txt"
    assert result["gated"] is False
    assert result["chunks"], "a non-empty document must yield at least one chunk"
    assert "quarterly review" in " ".join(c["text"] for c in result["chunks"])


async def test_rtf_content_named_doc_is_routed_by_its_bytes():
    """The archive's real case (§18a): RTF files carrying a .doc extension.
    Routing on the filename would hand these to the MS-DOC parser and fail."""
    rtf = rb"{\rtf1\ansi\deff0 {\fonttbl {\f0 Times;}}\f0\fs24 Board minutes here.\par}"

    result = await _extract(rtf, "minutes.doc")

    assert result["format"] == "rtf", "sniffing must override the .doc hint"
    assert "Board minutes" in " ".join(c["text"] for c in result["chunks"])


async def test_chunks_carry_positional_indexes():
    """§18e keys file_chunks on (file_id, chunk_index), so indexes must be
    dense and ordered regardless of how docling grouped the content."""
    body = ("\n\n".join(f"## Section {i}\n\nBody text for section {i}." for i in range(20))).encode()

    result = await _extract(body, "doc.md")

    indexes = [c["chunk_index"] for c in result["chunks"]]
    assert indexes == list(range(len(indexes)))


async def test_oversized_input_is_gated_rather_than_chunked():
    """§18a-2: the chunker does not return on very large tables and cannot be
    cancelled, so the endpoint declines instead of attempting it. The text must
    survive — a gated file loses vectors, not searchability."""
    body = ("word " * ((MAX_CHUNK_INPUT_CHARS // 5) + 1000)).encode()

    result = await _extract(body, "huge.txt")

    assert result["markdown_chars"] > MAX_CHUNK_INPUT_CHARS
    assert result["gated"] is True
    assert len(result["chunks"]) == 1
    assert result["chunks"][0]["text"], "gated documents keep their full text"
    assert result["chunks"][0]["page"] is None


async def test_excluded_format_is_declined_as_unsupported_media():
    """HTML is excluded by policy (§18i), not by capability. 415 tells the
    client to stop retrying rather than to count a failure."""
    with pytest.raises(HTTPException) as exc:
        await _extract(b"<!DOCTYPE html><html><body>hi</body></html>", "mail.html")

    assert exc.value.status_code == 415


async def test_unreadable_content_reports_unprocessable_not_unsupported():
    """§18i splits permanent from transient failures. A file we recognise but
    cannot parse is unprocessable content (422) and does count toward
    embedding_attempts; that is the ~29% of .doc files measured in §18a-1."""
    truncated_ole2 = b"\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1" + b"\x00" * 32

    with pytest.raises(HTTPException) as exc:
        await _extract(truncated_ole2, "broken.doc")

    assert exc.value.status_code == 422


async def test_missing_dependency_reports_unavailable_not_unprocessable(
    monkeypatch,
):
    """A PDF that fails because libpdfium is absent is not a bad PDF.

    Answering 422 here makes the client spend a retry attempt, and five passes
    retire the file permanently — before the feature that could read it has
    even shipped. Measured on the dev archive: 29 of 47 PDFs retired this way.
    503 costs no attempt.
    """
    def _raise(*args, **kwargs):
        raise RuntimeError(
            "parse error: pdf: pdfium error: the pdfium library is not "
            "installed. PDF/image conversion needs pdfium + the ONNX models"
        )

    monkeypatch.setattr(de, "_convert_raw", _raise)

    with pytest.raises(HTTPException) as exc:
        await _extract(b"%PDF-1.5\n", "invoice.pdf")

    assert exc.value.status_code == 503


async def test_invalid_base64_is_rejected_before_any_extraction():
    with pytest.raises(HTTPException) as exc:
        await extract_text(ExtractTextRequest(file_base64="not base64!!", filename="x.txt"))

    assert exc.value.status_code == 400
