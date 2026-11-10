"""End-to-end tests for /util/extract-text, against the real docling-rs.

The unit tests in test_document_extractor.py cover the logic with fakes; these
run bytes through the actual library so the wiring is pinned too — the
sniff → synthesized-name → convert → chunk path is exactly where a library
upgrade would break silently.

Only paths that need no model download are used here, so the suite stays
runnable on a machine that has never fetched docling's 2 GB pack. That now
includes PDF: see ``TestBornDigitalPdf``.
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


def _pdf_with_text_layer(pages: list[str]) -> bytes:
    """A real PDF, xref table and all, with one line of Helvetica per page.

    An empty string makes a page with no text layer, which is what a scanned
    page looks like to a reader that does not OCR.
    """
    font = 3 + 2 * len(pages)
    kids = " ".join(f"{3 + 2 * i} 0 R" for i in range(len(pages)))
    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        f"<< /Type /Pages /Kids [{kids}] /Count {len(pages)} >>".encode(),
    ]
    for i, text in enumerate(pages):
        objects.append(
            f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] "
            f"/Contents {4 + 2 * i} 0 R "
            f"/Resources << /Font << /F1 {font} 0 R >> >> >>".encode()
        )
        content = f"BT /F1 12 Tf 72 720 Td ({text}) Tj ET".encode()
        objects.append(
            b"<< /Length %d >>\nstream\n%s\nendstream" % (len(content), content)
        )
    objects.append(b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")

    out = b"%PDF-1.4\n"
    offsets = []
    for number, body in enumerate(objects, 1):
        offsets.append(len(out))
        out += b"%d 0 obj\n%s\nendobj\n" % (number, body)
    xref = len(out)
    out += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objects) + 1)
    out += b"".join(b"%010d 00000 n \n" % offset for offset in offsets)
    return out + (
        b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n"
        % (len(objects) + 1, xref)
    )


class TestBornDigitalPdf:
    """The PDF path against the real library, with no models available.

    docling-rs changed what ``do_ocr=False`` means under this code: it used to
    skip the whole ML stack and now only skips OCR, so every PDF began failing
    on a missing layout model. Nothing noticed, because the failure is a
    retryable 503 and no test here converted an actual PDF. An upgrade that
    moves this behaviour again has to fail here rather than quietly stop PDFs
    being indexed.
    """

    @pytest.fixture(autouse=True)
    def _no_models_and_no_pdfium(self, tmp_path, monkeypatch):
        try:
            import docling_rs  # noqa: F401
        except ImportError as e:
            pytest.skip(f"docling_rs cannot load here: {e}")

        # Every place docling looks for a model is empty, so a dev machine that
        # happens to have the pack cannot make these pass by accident: a
        # relative `.models/` under the cwd, the cache dir, and the override.
        monkeypatch.chdir(tmp_path)
        monkeypatch.setenv("DOCLING_RS_CACHE", str(tmp_path))
        monkeypatch.delenv("DOCLING_LAYOUT_ONNX", raising=False)
        monkeypatch.delenv("PDFIUM_DYNAMIC_LIB_PATH", raising=False)
        # With a tokenizer, HybridChunker merges these short pages into a single
        # chunk citing page 1, so what a test could assert would depend on
        # whether this machine has downloaded the embedding model.
        monkeypatch.setattr(de, "_tokenizer_path", lambda: None)

    async def test_a_born_digital_pdf_returns_chunks_with_their_pages(self):
        pdf = _pdf_with_text_layer(
            [
                "Alpha page mentions the quarterly invoice total.",
                "Beta page mentions the renewal deadline.",
            ]
        )

        result = await _extract(pdf, "report.pdf")

        assert result["format"] == "pdf"
        pages_by_word = {
            word: chunk["page"]
            for chunk in result["chunks"]
            for word in ("invoice", "renewal")
            if word in chunk["text"]
        }
        # The page is what a search result links the reader to, so reading the
        # text but losing where it came from would still be a regression.
        assert pages_by_word == {"invoice": 1, "renewal": 2}

    async def test_a_pdf_with_no_text_layer_is_empty_rather_than_an_error(self):
        """Scanned pages must not fail: the file is fine, it has nothing to
        read without OCR, and `_warn_if_scanned` is what reports that."""
        result = await _extract(_pdf_with_text_layer(["", ""]), "scan.pdf")

        assert result["format"] == "pdf"
        assert not "".join(c["text"] for c in result["chunks"]).strip()

    async def test_a_corrupt_pdf_is_unprocessable_not_unavailable(self):
        """A file the parser cannot read is reported as "pdfium support is not
        compiled in", because pdfium is docling's optional last resort for such
        files. It must not read as a missing dependency: there is nothing to
        install, and a 503 costs no attempt, so the client would retry this
        file forever instead of retiring it."""
        with pytest.raises(HTTPException) as exc:
            await _extract(b"%PDF-1.4\nnot really a pdf at all\n", "broken.pdf")

        assert exc.value.status_code == 422


async def test_invalid_base64_is_rejected_before_any_extraction():
    with pytest.raises(HTTPException) as exc:
        await extract_text(ExtractTextRequest(file_base64="not base64!!", filename="x.txt"))

    assert exc.value.status_code == 400
