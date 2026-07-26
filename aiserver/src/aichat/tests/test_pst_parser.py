"""
Tests for PstParser email field quality.

These tests validate that the parser correctly extracts:
  - FROM: must contain a valid email address, never just a display name
           or the sentinel value "Unknown" / "(Unknown Sender)"
  - TO:   must be a list (can be empty for some system messages,
           but should be populated for real emails)
  - CC:   must be a list (can be empty when there are no CC recipients)

They run against the small PST files committed under `fixtures/` (see
fixtures/README.md), so the suite is self-contained — no local archive needed.
Point TEST_PST_FILE at your own .pst to run the same quality checks against a
bigger, messier archive:

  pdm run pytest src/aichat/tests/test_pst_parser.py -v
  TEST_PST_FILE=~/archive.pst pdm run pytest src/aichat/tests/test_pst_parser.py -v

TestBundledFixtures asserts exact, hand-verified expectations for both fixture
files. Those numbers are the regression lock: the fixtures never change, so any
drift in the parser shows up there as a precise diff rather than a vague
quality-percentage wobble.
"""

import hashlib
import re
import sys
import os
import pytest

# ---------------------------------------------------------------------------
# Adjust the path so we can import PstParser from the sibling package
# ---------------------------------------------------------------------------
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from pst_parser import (  # noqa: E402
    PstParser,
    NON_EMAIL_FOLDER_NAMES,
    WRAPPER_FOLDER_NAMES,
    UNREADABLE_FOLDER_NAME,
)

# ---------------------------------------------------------------------------
# PST files under test. The bundled fixtures keep the suite runnable anywhere;
# TEST_PST_FILE swaps in a larger local archive for the quality checks.
# ---------------------------------------------------------------------------
FIXTURES_DIR = os.path.join(os.path.dirname(__file__), "fixtures")
# Outlook-authored: nested folders, Sent Items, HTML bodies, 34 attachments,
# populated Calendar/Contacts, plus a free/busy system item. The richer of the
# two, so it is what the general quality tests run against by default.
OUTLOOK_FIXTURE = os.path.join(FIXTURES_DIR, "outlook_sample.pst")
# Aspose-authored: a minimal, differently-written PST — guards against tying the
# parser to Outlook's own layout.
ASPOSE_FIXTURE = os.path.join(FIXTURES_DIR, "aspose_sample.pst")

PST_FILE = os.environ.get("TEST_PST_FILE") or OUTLOOK_FIXTURE

# Regex that matches a bare email address anywhere in a string,
# e.g. "Joe Smith <joe@example.com>" or "joe@example.com"
EMAIL_PATTERN = re.compile(r"[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}")

# Sentinel values that should NEVER appear as a from address
BAD_FROM_VALUES = {
    "unknown",
    "(unknown sender)",
    "(error getting sender)",
    "",
}


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _has_email(s: str) -> bool:
    """Return True if *s* contains at least one valid email address."""
    return bool(EMAIL_PATTERN.search(s or ""))


def _is_bad_from(s: str) -> bool:
    """Return True if *s* is one of the known bad sentinel values."""
    return (s or "").strip().lower() in BAD_FROM_VALUES


def _is_non_email_folder(folder_path: str) -> bool:
    """Return True if any path component matches a known non-email folder.

    Delegates to the parser's own NON_EMAIL_FOLDER_NAMES so the test stays
    in sync with production logic automatically.
    """
    parts = [p.lower() for p in re.split(r'[\\/]', folder_path)]
    return bool(NON_EMAIL_FOLDER_NAMES & set(parts))


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

def _walk_pst(pst_path, output_dir):
    """Parse `pst_path` end to end, returning every record the walk yielded."""
    parser = PstParser(pst_path, output_dir=str(output_dir))
    parser.open()
    try:
        return list(parser.walk())
    finally:
        parser.close()


@pytest.fixture(scope="module")
def all_raw_records(tmp_path_factory):
    """
    Parse the PST file once and return ALL non-folder records (emails, errors)
    as-is, with NO folder filtering applied.  Used by TestItemTypeFiltering to
    verify the parser itself gates non-email folders.
    """
    if not os.path.exists(PST_FILE):
        pytest.skip(f"PST file not found at {PST_FILE!r}. Set TEST_PST_FILE env var.")

    out = tmp_path_factory.mktemp("pst_raw")
    return [r for r in _walk_pst(PST_FILE, out) if r.get("type") != "folder"]


@pytest.fixture(scope="module")
def parsed_emails(tmp_path_factory):
    """
    Parse the PST file once for the entire test module and return only the
    email-type records from genuine mail folders (Inbox, Sent Items, etc.).
    Contacts, Calendar, Tasks, Notes and Journal items are excluded since they
    are not mail messages and don't have From/To/CC fields.
    """
    if not os.path.exists(PST_FILE):
        pytest.skip(f"PST file not found at {PST_FILE!r}. Set TEST_PST_FILE env var.")

    out = tmp_path_factory.mktemp("pst_emails")
    emails = [
        r for r in _walk_pst(PST_FILE, out)
        if r.get("type") == "email" and not _is_non_email_folder(r.get("folder", ""))
    ]

    if not emails:
        pytest.skip("No email records found in PST file.")

    return emails


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

class TestFromField:
    """FROM / sender field must always contain a valid email address."""

    def test_from_field_is_never_unknown(self, parsed_emails):
        """
        No email should have 'Unknown' (or its variants) as the sender.
        Every message in a PST was sent by someone; 'Unknown' means the
        parser failed to extract the email address.

        Note: Sent Items in Exchange PSTs may only have the sender's display
        name in the transport headers (Exchange stores them internally).
        Those are NOT counted as failures here — only messages where the
        sender field is literally a sentinel value like '(Unknown Sender)'.
        """
        failures = []
        for email in parsed_emails:
            sender = email.get("sender", "")
            if _is_bad_from(sender):
                failures.append(
                    {
                        "subject": email.get("subject", "(no subject)"),
                        "folder": email.get("folder", ""),
                        "sender": repr(sender),
                    }
                )

        if failures:
            # Build a readable summary (cap at 20 to keep output sane)
            sample = failures[:20]
            details = "\n".join(
                f"  [{i+1}] folder={r['folder']} | subject={r['subject']} | sender={r['sender']}"
                for i, r in enumerate(sample)
            )
            pytest.fail(
                f"{len(failures)} email(s) have a bad/unknown sender "
                f"(showing first {len(sample)}):\n{details}"
            )

    def test_from_field_contains_email_address(self, parsed_emails):
        """
        The sender string must contain an @ character, i.e. an actual email
        address.  Display-name-only values like "Joe Smith" are not acceptable.

        Exchange PST 2010 quirk: Sent Items store the sender as a display name
        only (no transport From: header) because Exchange handled delivery
        internally.  Sent Items are therefore EXCLUDED from this strict check;
        they are covered by test_sent_items_have_sender_display_name instead.
        """
        failures = []
        for email in parsed_emails:
            folder = email.get("folder", "")
            # Allow Sent Items to have display-name-only senders (Exchange quirk)
            if "sent items" in folder.lower():
                continue
            sender = email.get("sender", "")
            if not _has_email(sender):
                failures.append(
                    {
                        "subject": email.get("subject", "(no subject)"),
                        "folder": folder,
                        "sender": repr(sender),
                    }
                )

        if failures:
            sample = failures[:20]
            details = "\n".join(
                f"  [{i+1}] folder={r['folder']} | subject={r['subject']} | sender={r['sender']}"
                for i, r in enumerate(sample)
            )
            pytest.fail(
                f"{len(failures)} email(s) have a sender with no email address "
                f"(showing first {len(sample)}):\n{details}"
            )

    def test_sent_items_have_sender_display_name(self, parsed_emails):
        """
        Exchange PST 2010 does not embed a From: transport header for Sent
        Items (the email was dispatched via Exchange internally).  We therefore
        only require that the sender field is a non-empty, non-sentinel display
        name for messages in the Sent Items folder.

        This test documents the known limitation and will catch regressions
        where we start returning blank/unknown senders for sent mail.
        """
        failures = []
        for email in parsed_emails:
            folder = email.get("folder", "")
            if "sent items" not in folder.lower():
                continue
            sender = email.get("sender", "")
            if _is_bad_from(sender) or not sender.strip():
                failures.append(
                    {
                        "subject": email.get("subject", "(no subject)"),
                        "folder": folder,
                        "sender": repr(sender),
                    }
                )

        if failures:
            sample = failures[:20]
            details = "\n".join(
                f"  [{i+1}] folder={r['folder']} | subject={r['subject']} | sender={r['sender']}"
                for i, r in enumerate(sample)
            )
            pytest.fail(
                f"{len(failures)} Sent Item(s) have a blank/unknown sender "
                f"(showing first {len(sample)}):\n{details}"
            )




class TestToField:
    """TO field must be a list and must not be None."""

    def test_to_is_a_list(self, parsed_emails):
        """The 'to' field must always be a list (never None or missing)."""
        failures = []
        for email in parsed_emails:
            to_field = email.get("to")
            if not isinstance(to_field, list):
                failures.append(
                    {
                        "subject": email.get("subject", "(no subject)"),
                        "folder": email.get("folder", ""),
                        "to": repr(to_field),
                    }
                )

        if failures:
            sample = failures[:20]
            details = "\n".join(
                f"  [{i+1}] folder={r['folder']} | subject={r['subject']} | to={r['to']}"
                for i, r in enumerate(sample)
            )
            pytest.fail(
                f"{len(failures)} email(s) have a non-list 'to' field "
                f"(showing first {len(sample)}):\n{details}"
            )

    def test_to_recipients_contain_email_addresses(self, parsed_emails):
        """
        Where the TO list is non-empty, each entry must include an email address.
        A display-name-only entry like "Joe Smith" is a parsing failure.
        """
        failures = []
        for email in parsed_emails:
            to_list = email.get("to", [])
            if not isinstance(to_list, list):
                continue  # caught by test_to_is_a_list
            bad_entries = [entry for entry in to_list if not _has_email(entry)]
            if bad_entries:
                failures.append(
                    {
                        "subject": email.get("subject", "(no subject)"),
                        "folder": email.get("folder", ""),
                        "bad_entries": bad_entries,
                    }
                )

        if failures:
            sample = failures[:20]
            details = "\n".join(
                f"  [{i+1}] folder={r['folder']} | subject={r['subject']} | bad_to={r['bad_entries']}"
                for i, r in enumerate(sample)
            )
            pytest.fail(
                f"{len(failures)} email(s) have TO recipients without email addresses "
                f"(showing first {len(sample)}):\n{details}"
            )


class TestCcField:
    """CC field must be a list and must not be None."""

    def test_cc_is_a_list(self, parsed_emails):
        """The 'cc' field must always be a list (never None or missing)."""
        failures = []
        for email in parsed_emails:
            cc_field = email.get("cc")
            if not isinstance(cc_field, list):
                failures.append(
                    {
                        "subject": email.get("subject", "(no subject)"),
                        "folder": email.get("folder", ""),
                        "cc": repr(cc_field),
                    }
                )

        if failures:
            sample = failures[:20]
            details = "\n".join(
                f"  [{i+1}] folder={r['folder']} | subject={r['subject']} | cc={r['cc']}"
                for i, r in enumerate(sample)
            )
            pytest.fail(
                f"{len(failures)} email(s) have a non-list 'cc' field "
                f"(showing first {len(sample)}):\n{details}"
            )

    def test_cc_recipients_contain_email_addresses(self, parsed_emails):
        """
        Where the CC list is non-empty, each entry must include an email address.
        """
        failures = []
        for email in parsed_emails:
            cc_list = email.get("cc", [])
            if not isinstance(cc_list, list):
                continue  # caught by test_cc_is_a_list
            bad_entries = [entry for entry in cc_list if not _has_email(entry)]
            if bad_entries:
                failures.append(
                    {
                        "subject": email.get("subject", "(no subject)"),
                        "folder": email.get("folder", ""),
                        "bad_entries": bad_entries,
                    }
                )

        if failures:
            sample = failures[:20]
            details = "\n".join(
                f"  [{i+1}] folder={r['folder']} | subject={r['subject']} | bad_cc={r['bad_entries']}"
                for i, r in enumerate(sample)
            )
            pytest.fail(
                f"{len(failures)} email(s) have CC recipients without email addresses "
                f"(showing first {len(sample)}):\n{details}"
            )


# ---------------------------------------------------------------------------
# Item-type filtering – the parser must never emit non-email items as emails
# ---------------------------------------------------------------------------

class TestItemTypeFiltering:
    """
    Verify that the parser itself (not just the test fixture) suppresses
    contacts, calendar events, tasks, notes, and other non-email items.

    These tests use the raw, unfiltered record list so they exercise
    PstParser logic, not post-parse filtering in the test suite.
    """

    def test_no_email_records_from_contacts_folder(self, all_raw_records):
        """
        Any record whose folder path contains 'Contacts' (case-insensitive)
        must NOT have type == 'email'.  PST Contacts are stored as messages
        internally but are vCards, not emails.
        """
        violations = [
            r for r in all_raw_records
            if r.get("type") == "email"
            and "contacts" in r.get("folder", "").lower()
        ]
        if violations:
            sample = violations[:10]
            details = "\n".join(
                f"  [{i+1}] folder={r['folder']} | subject={r.get('subject', '')}"
                for i, r in enumerate(sample)
            )
            pytest.fail(
                f"{len(violations)} contact record(s) were emitted as type='email' "
                f"(showing first {len(sample)}):\n{details}"
            )

    def test_no_email_records_from_calendar_folder(self, all_raw_records):
        """
        Calendar entries must not appear as emails.
        """
        violations = [
            r for r in all_raw_records
            if r.get("type") == "email"
            and "calendar" in r.get("folder", "").lower()
        ]
        if violations:
            sample = violations[:10]
            details = "\n".join(
                f"  [{i+1}] folder={r['folder']} | subject={r.get('subject', '')}"
                for i, r in enumerate(sample)
            )
            pytest.fail(
                f"{len(violations)} calendar record(s) were emitted as type='email' "
                f"(showing first {len(sample)}):\n{details}"
            )

    def test_no_email_records_from_tasks_folder(self, all_raw_records):
        """Task items must not appear as emails."""
        violations = [
            r for r in all_raw_records
            if r.get("type") == "email"
            and "tasks" in r.get("folder", "").lower()
        ]
        if violations:
            sample = violations[:10]
            details = "\n".join(
                f"  [{i+1}] folder={r['folder']} | subject={r.get('subject', '')}"
                for i, r in enumerate(sample)
            )
            pytest.fail(
                f"{len(violations)} task record(s) were emitted as type='email' "
                f"(showing first {len(sample)}):\n{details}"
            )

    def test_no_email_records_from_notes_folder(self, all_raw_records):
        """Note items must not appear as emails."""
        violations = [
            r for r in all_raw_records
            if r.get("type") == "email"
            and "notes" in r.get("folder", "").lower()
        ]
        if violations:
            sample = violations[:10]
            details = "\n".join(
                f"  [{i+1}] folder={r['folder']} | subject={r.get('subject', '')}"
                for i, r in enumerate(sample)
            )
            pytest.fail(
                f"{len(violations)} note record(s) were emitted as type='email' "
                f"(showing first {len(sample)}):\n{details}"
            )

    def test_no_email_records_from_any_non_email_folder(self, all_raw_records):
        """
        Comprehensive check: no record whose folder path contains ANY of the
        known non-email folder names should surface as type='email'.
        This is the single source-of-truth test that will catch new folder
        types being added to NON_EMAIL_FOLDER_NAMES.
        """
        violations = [
            r for r in all_raw_records
            if r.get("type") == "email"
            and _is_non_email_folder(r.get("folder", ""))
        ]
        if violations:
            sample = violations[:20]
            details = "\n".join(
                f"  [{i+1}] folder={r['folder']} | subject={r.get('subject', '')} | sender={r.get('sender', '')}"
                for i, r in enumerate(sample)
            )
            pytest.fail(
                f"{len(violations)} non-email item(s) were emitted as type='email' "
                f"(showing first {len(sample)}):\n{details}"
            )


# ---------------------------------------------------------------------------
# Attachments
# ---------------------------------------------------------------------------

class TestAttachments:
    """Attachment extraction must be correct and present for emails that have them."""

    def test_attachments_field_is_always_a_list(self, parsed_emails):
        """
        Every email record must have 'attachments' as a list (never None/missing).
        An email with no attachments should have an empty list, not None.
        """
        failures = [
            {
                "subject": e.get("subject", "(no subject)"),
                "folder": e.get("folder", ""),
                "attachments": repr(e.get("attachments")),
            }
            for e in parsed_emails
            if not isinstance(e.get("attachments"), list)
        ]
        if failures:
            sample = failures[:10]
            details = "\n".join(
                f"  [{i+1}] folder={r['folder']} | subject={r['subject']} | attachments={r['attachments']}"
                for i, r in enumerate(sample)
            )
            pytest.fail(
                f"{len(failures)} email(s) have a non-list 'attachments' field "
                f"(showing first {len(sample)}):\n{details}"
            )

    def test_at_least_one_email_has_attachments(self, parsed_emails):
        """
        A real-world PST with 1000+ emails should contain at least one email
        that has an attachment.  If this fails it means the attachment extraction
        code is silently swallowing every attachment (e.g. all get_data() calls
        are crashing and being silently ignored).
        """
        emails_with_attachments = [e for e in parsed_emails if e.get("attachments")]
        assert len(emails_with_attachments) > 0, (
            f"No emails with attachments found out of {len(parsed_emails)} total. "
            "Attachment extraction may be broken (check silent exception handling "
            "in _process_message)."
        )

    def test_attachment_entries_have_required_keys(self, parsed_emails):
        """
        Each attachment dict must have: name, path, size, contentType.
        A missing key means the attachment was partially extracted.
        """
        REQUIRED_ATT_KEYS = {"name", "path", "size", "contentType"}
        failures = []
        for email in parsed_emails:
            for att in email.get("attachments") or []:
                missing = REQUIRED_ATT_KEYS - set(att.keys())
                if missing:
                    failures.append({
                        "subject": email.get("subject", "(no subject)"),
                        "att_name": att.get("name", "?"),
                        "missing_keys": sorted(missing),
                    })
        if failures:
            sample = failures[:10]
            details = "\n".join(
                f"  [{i+1}] subject={r['subject']} | att={r['att_name']} | missing={r['missing_keys']}"
                for i, r in enumerate(sample)
            )
            pytest.fail(
                f"{len(failures)} attachment(s) are missing required keys "
                f"(showing first {len(sample)}):\n{details}"
            )

    def test_attachment_files_exist_on_disk(self, parsed_emails):
        """
        Every attachment that was extracted must have its file actually present
        on disk at the reported path.  A missing file means the write failed
        silently.
        """
        failures = []
        for email in parsed_emails:
            for att in email.get("attachments") or []:
                path = att.get("path", "")
                if path and not os.path.exists(path):
                    failures.append({
                        "subject": email.get("subject", "(no subject)"),
                        "att_name": att.get("name", "?"),
                        "path": path,
                    })
        if failures:
            sample = failures[:10]
            details = "\n".join(
                f"  [{i+1}] subject={r['subject']} | att={r['att_name']} | path={r['path']}"
                for i, r in enumerate(sample)
            )
            pytest.fail(
                f"{len(failures)} attachment file(s) are missing on disk "
                f"(showing first {len(sample)}):\n{details}"
            )

    def test_attachment_sizes_are_positive(self, parsed_emails):
        """
        Every extracted attachment must have a size > 0.  A zero-byte file
        almost certainly means the read/write failed silently.
        """
        failures = []
        for email in parsed_emails:
            for att in email.get("attachments") or []:
                size = att.get("size", -1)
                if not isinstance(size, (int, float)) or size <= 0:
                    failures.append({
                        "subject": email.get("subject", "(no subject)"),
                        "att_name": att.get("name", "?"),
                        "size": size,
                    })
        if failures:
            sample = failures[:10]
            details = "\n".join(
                f"  [{i+1}] subject={r['subject']} | att={r['att_name']} | size={r['size']}"
                for i, r in enumerate(sample)
            )
            pytest.fail(
                f"{len(failures)} attachment(s) have a zero or invalid size "
                f"(showing first {len(sample)}):\n{details}"
            )

    # ------------------------------------------------------------
    # Image extensions that should produce an image/* content type
    # ------------------------------------------------------------
    _IMAGE_EXTENSIONS = {".jpg", ".jpeg", ".png", ".gif", ".bmp", ".tiff", ".tif", ".webp"}

    def test_attachment_image_content_type_is_not_octet_stream(self, parsed_emails):
        """
        Attachments whose filename has a recognised image extension must have a
        content type of 'image/*', NOT 'application/octet-stream'.

        If this fails the parser is not using mimetypes.guess_type() (or it is
        overriding the result with the hardcoded fallback).
        """
        failures = []
        for email in parsed_emails:
            for att in email.get("attachments") or []:
                name = att.get("name", "")
                ext = os.path.splitext(name)[-1].lower()
                if ext not in self._IMAGE_EXTENSIONS:
                    continue
                ct = att.get("contentType", "")
                if not ct.startswith("image/"):
                    failures.append({
                        "subject": email.get("subject", "(no subject)"),
                        "att_name": name,
                        "contentType": ct,
                    })
        if failures:
            sample = failures[:10]
            details = "\n".join(
                f"  [{i+1}] subject={r['subject']} | att={r['att_name']} | contentType={r['contentType']!r}"
                for i, r in enumerate(sample)
            )
            pytest.fail(
                f"{len(failures)} image attachment(s) have a non-image content type "
                f"(showing first {len(sample)}):\n{details}"
            )

    def test_attachment_path_contains_folder_and_year(self, parsed_emails):
        """
        Every attachment path must contain:
          1. The email folder name somewhere in the path  (e.g. 'INBOX')
          2. A 4-digit year directory component           (e.g. '2010')

        This validates that the Python parser is organising attachments under
        ``output_dir/<folder_path>/<year>/`` as per the spec.
        """
        year_re = re.compile(r"[\\/]\d{4}[\\/]")
        failures = []
        for email in parsed_emails:
            folder = email.get("folder", "")
            # Use the leaf folder name for the path check
            leaf = os.path.basename(folder) if folder else ""
            for att in email.get("attachments") or []:
                path = att.get("path", "")
                missing = []
                if leaf and leaf.lower() not in path.lower():
                    missing.append(f"folder '{leaf}'")
                if not year_re.search(path):
                    missing.append("year component (e.g. /2010/)")
                if missing:
                    failures.append({
                        "subject": email.get("subject", "(no subject)"),
                        "folder": folder,
                        "att_name": att.get("name", "?"),
                        "path": path,
                        "missing": ", ".join(missing),
                    })
        if failures:
            sample = failures[:10]
            details = "\n".join(
                f"  [{i+1}] folder={r['folder']} | att={r['att_name']} | "
                f"missing={r['missing']} | path={r['path']}"
                for i, r in enumerate(sample)
            )
            pytest.fail(
                f"{len(failures)} attachment(s) have unexpected paths "
                f"(showing first {len(sample)}):\n{details}"
            )


# ---------------------------------------------------------------------------
# Summary / smoke test
# ---------------------------------------------------------------------------

class TestPstFileSanity:
    """Basic sanity checks on the PST file parsing itself."""

    def test_at_least_one_email_parsed(self, parsed_emails):
        """The PST file must contain at least one parseable email."""
        assert len(parsed_emails) > 0, "No emails were returned by the parser."

    def test_email_ids_are_unique(self, parsed_emails):
        """No two emails in a real PST may share an id.

        The client keys its Email rows off this value, so duplicates are not a
        cosmetic problem — they silently collapse the entire import into one
        row. See test_message_ids_are_unique_across_the_walk for the same
        guarantee driven over a fake tree.
        """
        ids = [e.get("id") for e in parsed_emails]
        assert all(ids), "some emails have a missing/blank id"
        duplicates = len(ids) - len(set(ids))
        assert duplicates == 0, (
            f"{duplicates} of {len(ids)} emails share an id with another "
            "message; the client would import them as a single email"
        )

    def test_email_records_have_required_keys(self, parsed_emails):
        """Every email record must have the minimum set of required keys."""
        required_keys = {"type", "subject", "sender", "to", "cc", "date", "folder", "attachments"}
        failures = []
        for email in parsed_emails:
            missing = required_keys - set(email.keys())
            if missing:
                failures.append(
                    {
                        "subject": email.get("subject", "(no subject)"),
                        "missing_keys": sorted(missing),
                    }
                )

        if failures:
            sample = failures[:10]
            details = "\n".join(
                f"  [{i+1}] subject={r['subject']} | missing={r['missing_keys']}"
                for i, r in enumerate(sample)
            )
            pytest.fail(
                f"{len(failures)} email record(s) are missing required keys "
                f"(showing first {len(sample)}):\n{details}"
            )

    def test_statistics(self, parsed_emails, capsys):
        """
        Not a real assertion — prints a summary of the parsing results to help
        diagnose problems.  Always passes.
        """
        total = len(parsed_emails)
        no_email_in_from = sum(
            1 for e in parsed_emails if not _has_email(e.get("sender", ""))
        )
        unknown_from = sum(
            1 for e in parsed_emails if _is_bad_from(e.get("sender", ""))
        )
        empty_to = sum(1 for e in parsed_emails if not e.get("to"))
        empty_cc = sum(1 for e in parsed_emails if not e.get("cc"))

        # Attachment stats
        emails_with_attachments = [
            e for e in parsed_emails if e.get("attachments")
        ]
        total_attachments = sum(len(e["attachments"]) for e in emails_with_attachments)
        att_count = len(emails_with_attachments)

        with capsys.disabled():
            print(f"\n{'='*60}")
            print(f"PST Parsing Statistics for: {PST_FILE}")
            print(f"{'='*60}")
            print(f"  Total emails parsed        : {total}")
            print(f"  FROM missing email addr    : {no_email_in_from} ({no_email_in_from/total*100:.1f}%)")
            print(f"  FROM is 'Unknown'/bad      : {unknown_from}   ({unknown_from/total*100:.1f}%)")
            print(f"  TO list is empty           : {empty_to}   ({empty_to/total*100:.1f}%)")
            print(f"  CC list is empty           : {empty_cc}   ({empty_cc/total*100:.1f}%)")
            print(f"  Emails with attachments    : {att_count}   ({att_count/total*100:.1f}%)")
            print(f"  Total attachments found    : {total_attachments}")
            if emails_with_attachments:
                sample = emails_with_attachments[:5]
                print(f"  Sample (up to 5):")
                for e in sample:
                    names = ", ".join(a.get("name", "?") for a in e["attachments"])
                    print(f"    subject={e.get('subject', '')!r} | files=[{names}]")
            print(f"{'='*60}")


# ---------------------------------------------------------------------------
# Exact expectations for the two committed fixture files.
#
# The tests above measure *quality* and work against any PST. These pin down
# *behaviour* against two files that will never change, so a regression shows up
# as "expected 11 emails, got 12" instead of a percentage that drifted a little.
# Every number below was verified by hand against the fixture contents.
# ---------------------------------------------------------------------------

@pytest.fixture(scope="module")
def outlook_records(tmp_path_factory):
    if not os.path.exists(OUTLOOK_FIXTURE):
        pytest.skip(f"fixture missing: {OUTLOOK_FIXTURE}")
    out = tmp_path_factory.mktemp("outlook_fixture")
    return _walk_pst(OUTLOOK_FIXTURE, out), out


@pytest.fixture(scope="module")
def aspose_records(tmp_path_factory):
    if not os.path.exists(ASPOSE_FIXTURE):
        pytest.skip(f"fixture missing: {ASPOSE_FIXTURE}")
    out = tmp_path_factory.mktemp("aspose_fixture")
    return _walk_pst(ASPOSE_FIXTURE, out), out


def _split(records):
    """Split a walk into (folders, emails, errors, summary)."""
    by_type = {"folder": [], "email": [], "error": [], "summary": []}
    for r in records:
        by_type.setdefault(r["type"], []).append(r)
    summary = by_type["summary"][-1] if by_type["summary"] else None
    return by_type["folder"], by_type["email"], by_type["error"], summary


class TestBundledFixtures:
    """Exact, hand-verified expectations for the committed fixture PSTs."""

    # -- outlook_sample.pst ------------------------------------------------

    def test_outlook_walk_is_clean_and_complete(self, outlook_records):
        """The walk must finish with a summary and no errors — the client only
        marks a PST import 'complete' when it sees exactly that."""
        folders, emails, errors, summary = _split(outlook_records[0])
        assert errors == [], f"unexpected errors: {[e['message'] for e in errors]}"
        assert summary == {
            "type": "summary", "folders": 23, "emails": 11, "errors": 0,
        }
        assert len(folders) == 23
        assert len(emails) == 11

    def test_outlook_email_ids_are_the_pst_descriptor_ids(self, outlook_records):
        """Ids must come from the message's own PST descriptor id.

        Uniqueness alone is too weak to guard this: the parser has a
        folder+index fallback for messages whose identifier can't be read, and
        that fallback is *also* unique — so a regression back to reading a
        non-existent accessor would slip through a uniqueness-only check while
        silently changing every id in the archive. Pinning the exact values ties
        them to the file, which is the property the client depends on.

        These are the descriptor ids stored in the fixture; they never change.
        """
        _, emails, _, _ = _split(outlook_records[0])
        by_folder = {}
        for e in emails:
            by_folder.setdefault(e["folder"], []).append(e["id"])

        assert sorted(by_folder["Inbox"]) == [
            "2097476", "2097508", "2097540", "2097636", "2097668", "2097700",
        ]
        assert sorted(by_folder["Sent Items"]) == [
            "2097252", "2097284", "2097316", "2097412", "2097444",
        ]
        ids = [e["id"] for e in emails]
        assert len(set(ids)) == len(ids) == 11
        assert all("/" not in i and "\\" not in i for i in ids)

    def test_outlook_folder_tree_including_nesting(self, outlook_records):
        """Folder paths carry their parent, and the PST root wrapper is hidden.
        The client rebuilds its folder hierarchy by splitting these paths, so a
        lost or extra level reparents mail in the UI."""
        folders, _, _, _ = _split(outlook_records[0])
        paths = [f["path"] for f in folders]
        assert "Inbox" in paths
        assert "Inbox/SubInbox" in paths, "nested folder lost its parent"
        assert not any(p.startswith("Root") for p in paths), "wrapper leaked into paths"

    def test_outlook_non_mail_folders_are_flagged_and_skipped(self, outlook_records):
        """Calendar and Contacts each hold one item in this fixture. They must be
        reported as folders but must not yield email records — a fixture with
        *populated* Calendar/Contacts is what makes this assertion meaningful."""
        folders, emails, _, _ = _split(outlook_records[0])
        non_mail = {f["path"] for f in folders if not f["is_email_folder"]}
        assert non_mail == {"Calendar", "Contacts", "Journal", "Notes", "Tasks"}

        populated = {f["path"] for f in folders if f["count"] > 0}
        assert {"Calendar", "Contacts"} <= populated, "fixture no longer exercises this"
        assert {e["folder"] for e in emails} == {"Inbox", "Sent Items"}

    def test_outlook_freebusy_system_item_is_not_imported(self, outlook_records):
        """'Freebusy Data' holds an IPM.Microsoft.ScheduleData.FreeBusy item —
        Outlook bookkeeping, not mail. It has no sender and no date, so
        importing it produced a phantom email stamped with the import time.
        Folder-name filtering can't catch it; PR_MESSAGE_CLASS can."""
        folders, emails, _, _ = _split(outlook_records[0])
        assert any(f["path"] == "Freebusy Data" and f["count"] == 1 for f in folders), (
            "fixture no longer contains the free/busy item this test guards"
        )
        assert not any(e["folder"] == "Freebusy Data" for e in emails)
        assert not any(e.get("subject") == "LocalFreebusy" for e in emails)

    def test_outlook_delivery_reports_would_still_import(self):
        """Guard the message-class predicate itself: NDRs are mail the user
        received and must survive the filter that drops free/busy items."""
        assert PstParser._is_mail_message_class("IPM.Note")
        assert PstParser._is_mail_message_class("IPM.Note.SMIME")
        assert PstParser._is_mail_message_class("REPORT.IPM.Note.NDR")
        assert not PstParser._is_mail_message_class("IPM.Microsoft.ScheduleData.FreeBusy")
        assert not PstParser._is_mail_message_class("IPM.Contact")
        # Unknown/unreadable class fails open — never drop mail on a guess.
        assert PstParser._is_mail_message_class(None)
        assert PstParser._is_mail_message_class("")

    def test_outlook_sender_and_recipients(self, outlook_records):
        """Every message is between the same Exchange account. Sent Items carry
        no transport headers, so their recipients come from PR_DISPLAY_TO —
        which Outlook stores quoted ('addr'). The quotes must be stripped or the
        same person is two different strings across folders."""
        _, emails, _, _ = _split(outlook_records[0])
        assert {e["sender"] for e in emails} == {"Saqib Razzaq <saqib.razzaq@xp.local>"}
        assert {t for e in emails for t in e["to"]} == {"saqib.razzaq@xp.local"}
        sent = [e for e in emails if e["folder"] == "Sent Items"]
        assert len(sent) == 5
        assert all(e["to"] == ["saqib.razzaq@xp.local"] for e in sent)

    def test_outlook_bodies_are_extracted(self, outlook_records):
        """All 11 messages have an HTML body; a body that silently comes back
        empty is invisible in the UI and unsearchable."""
        _, emails, _, _ = _split(outlook_records[0])
        assert all(e["html_body"] for e in emails)
        assert all(e["body"] for e in emails)

    def test_outlook_attachments_are_written_and_typed(self, outlook_records):
        """Attachments must land on disk at the reported path and size, with a
        content type derived from the real filename — the client stores that
        path verbatim and maps the type to its own file-kind constants."""
        records, out_dir = outlook_records
        _, emails, _, _ = _split(records)
        atts = [a for e in emails for a in e["attachments"]]
        assert len(atts) == 34

        by_name = {a["name"]: a for a in atts}
        assert by_name["Sunset.jpg"]["contentType"] == "image/jpeg"
        assert by_name["Sunset.jpg"]["size"] == 71189
        assert by_name["text file.txt"]["contentType"] == "text/plain"
        assert by_name["image010.gif"]["contentType"] == "image/gif"
        assert by_name["image001.png"]["contentType"] == "image/png"

        for a in atts:
            assert a["size"] > 0, f"{a['name']} written with no content"
            assert os.path.isfile(a["path"]), f"{a['name']} missing on disk"
            assert os.path.getsize(a["path"]) == a["size"]
            # Confined to the requested output dir, and filed by folder + year.
            assert os.path.realpath(a["path"]).startswith(
                os.path.realpath(str(out_dir)) + os.sep
            )
            assert "2011" in a["path"]

    def test_outlook_attachment_paths_do_not_collide(self, outlook_records):
        """The same filename appears in several messages (image001.png is in
        both the Inbox and Sent Items copies). Each must get its own file, or
        one message's attachment silently overwrites another's."""
        _, emails, _, _ = _split(outlook_records[0])
        atts = [a for e in emails for a in e["attachments"]]
        names = [a["name"] for a in atts]
        assert len(set(names)) < len(names), "fixture no longer has repeated names"
        paths = [a["path"] for a in atts]
        assert len(set(paths)) == len(paths), "two attachments share one path"

    # -- aspose_sample.pst -------------------------------------------------

    def test_aspose_walk_is_clean_and_complete(self, aspose_records):
        """A PST written by a non-Microsoft library must parse just as cleanly —
        this fixture is what stops the parser being tuned to Outlook's layout."""
        folders, emails, errors, summary = _split(aspose_records[0])
        assert errors == []
        assert summary == {
            "type": "summary", "folders": 8, "emails": 1, "errors": 0,
        }
        assert len(folders) == 8
        assert len(emails) == 1

    def test_aspose_nested_folder_is_preserved(self, aspose_records):
        """Custom folder names (not the standard Outlook set) must still nest."""
        folders, _, _, _ = _split(aspose_records[0])
        paths = [f["path"] for f in folders]
        assert "myInbox" in paths
        assert "myInbox/subfolder1" in paths

    def test_aspose_multi_recipient_headers(self, aspose_records):
        """The only fixture with multiple To *and* Cc recipients: it pins down
        address-list splitting and "Name <addr>" formatting, which a single
        recipient would never exercise."""
        _, emails, _, _ = _split(aspose_records[0])
        email = emails[0]
        assert email["sender"] == "Sender Name <from@domain.com>"
        assert email["to"] == [
            "Recipient 1 <to1@domain.com>",
            "Recipient 2 <to2@domain.com>",
        ]
        assert email["cc"] == [
            "Recipient 3 <cc1@domain.com>",
            "Recipient 4 <cc2@domain.com>",
        ]
        assert email["folder"] == "myInbox"
        assert email["attachments"] == []
        assert email["body"]

    def test_aspose_email_id_is_the_pst_descriptor_id(self, aspose_records):
        """Same guarantee as the Outlook fixture, on a PST this app didn't
        write: the id is read from the file, not synthesised."""
        _, emails, _, _ = _split(aspose_records[0])
        assert emails[0]["id"] == "2097188"


# ---------------------------------------------------------------------------
# Walk resilience + completion summary — runs WITHOUT a real PST file by
# driving the walk over an in-memory fake folder tree. PST is a one-shot import
# with no re-sync, so a single corrupt folder must never abort the whole walk,
# and the walk must end with a summary the client can use to decide whether the
# import was clean or only partial.
# ---------------------------------------------------------------------------

class _FakeMsg:
    # pypff.message exposes the PST descriptor id as get_identifier(); there is
    # no get_entry_identifier(). `no_identifier=True` drops it to exercise the
    # parser's per-message fallback id.
    number_of_record_sets = 0

    def __init__(self, i, no_identifier=False):
        self._i = i
        self._no_identifier = no_identifier

    def get_identifier(self):
        if self._no_identifier:
            raise RuntimeError("identifier descriptor error")
        return 2097152 + self._i

    def get_delivery_time(self):
        return None

    def get_subject(self):
        return f"subject {self._i}"

    def get_transport_headers(self):
        return "From: sender@example.com\nTo: rcpt@example.com\n"

    def get_sender_name(self):
        return "Sender"

    def get_plain_text_body(self):
        return "body"

    def get_html_body(self):
        return ""

    def get_number_of_attachments(self):
        return 0


class _FakeFolder:
    """Minimal stand-in for a pypff.folder. `corrupt_count=True` makes
    get_number_of_sub_messages raise, mimicking a damaged descriptor table."""

    def __init__(self, name, msgs=0, subs=None, corrupt_count=False,
                 corrupt_name=False, no_identifiers=False):
        self._name = name
        self._msgs = msgs
        self._subs = subs or []
        self._corrupt = corrupt_count
        self._corrupt_name = corrupt_name
        self._no_identifiers = no_identifiers
        # Real PST descriptor ids are unique across the whole file, not just
        # within a folder — offset each folder's ids so the fake tree keeps that
        # property and uniqueness assertions mean something. Uses a stable
        # digest rather than hash() so ids don't shift with PYTHONHASHSEED.
        digest = hashlib.sha1(name.encode()).hexdigest()[:8]
        self._id_base = int(digest, 16) * 1000

    def get_name(self):
        if self._corrupt_name:
            raise RuntimeError("name descriptor error")
        return self._name

    def get_number_of_sub_messages(self):
        if self._corrupt:
            raise RuntimeError("descriptor table error")
        return self._msgs

    def get_sub_message(self, i):
        return _FakeMsg(self._id_base + i, no_identifier=self._no_identifiers)

    def get_number_of_sub_folders(self):
        return len(self._subs)

    def get_sub_folder(self, i):
        return self._subs[i]


def _walk_fake_tree(root, output_dir):
    parser = PstParser("unused.pst", output_dir=str(output_dir))
    # Bypass pypff entirely: hand the walk a root folder directly.
    parser.pst = type("_FakePst", (), {"get_root_folder": lambda self: root})()
    return list(parser.walk())


class TestWalkResilience:
    """The walk must survive a corrupt folder and always end with a summary."""

    def _tree(self):
        # Root(wrapper) → Inbox(2 msgs) → Broken(corrupt count) → Deep(1 msg)
        #              → Contacts(non-email, 1 msg)
        deep = _FakeFolder("Deep", msgs=1)
        broken = _FakeFolder("Broken", corrupt_count=True, subs=[deep])
        inbox = _FakeFolder("Inbox", msgs=2, subs=[broken])
        contacts = _FakeFolder("Contacts", msgs=1)
        return _FakeFolder("Root", subs=[inbox, contacts])

    def test_corrupt_folder_does_not_abort_subtree(self, tmp_path):
        """A folder with an unreadable message count must still yield its
        folder event AND be descended into — its children are not lost."""
        events = _walk_fake_tree(self._tree(), tmp_path)
        folder_paths = [e["path"] for e in events if e["type"] == "folder"]
        # 'Deep' lives under the corrupt 'Broken' folder; it must still appear.
        assert os.path.join("Inbox", "Broken", "Deep") in folder_paths
        # The corruption is surfaced, not swallowed.
        assert any(e["type"] == "error" for e in events)

    def test_wrapper_folder_is_hidden_from_paths(self, tmp_path):
        events = _walk_fake_tree(self._tree(), tmp_path)
        folder_paths = [e["path"] for e in events if e["type"] == "folder"]
        assert "Root" not in folder_paths
        assert "Inbox" in folder_paths

    def test_non_email_folder_messages_are_skipped(self, tmp_path):
        """Contacts is a non-email folder: its message must not be emitted,
        even though the folder itself is still traversed."""
        events = _walk_fake_tree(self._tree(), tmp_path)
        contacts_emails = [
            e for e in events
            if e["type"] == "email" and e.get("folder") == "Contacts"
        ]
        assert contacts_emails == []

    def test_walk_ends_with_summary_counts(self, tmp_path):
        events = _walk_fake_tree(self._tree(), tmp_path)
        assert events, "walk yielded nothing"
        summary = events[-1]
        assert summary["type"] == "summary"
        # Inbox(2) + Deep(1); Contacts(1) is non-email and excluded.
        assert summary["emails"] == 3
        # Exactly the one corrupt folder produced an error.
        assert summary["errors"] == 1
        assert summary["errors"] == sum(1 for e in events if e["type"] == "error")

    def test_unreadable_folder_name_still_imports_its_messages(self, tmp_path):
        """A folder whose name raises must not be mistaken for a wrapper.

        Wrapper folders are skipped in the path *and* return before their own
        messages are read, so falling back to a name in WRAPPER_FOLDER_NAMES
        (e.g. "Root") would silently drop every message the folder holds.
        """
        nameless = _FakeFolder("Mystery", msgs=2, corrupt_name=True)
        root = _FakeFolder("Root", subs=[nameless])
        events = _walk_fake_tree(root, tmp_path)

        folder_paths = [e["path"] for e in events if e["type"] == "folder"]
        assert folder_paths == [UNREADABLE_FOLDER_NAME]

        summary = events[-1]
        assert summary["emails"] == 2, "messages under an unnamed folder were lost"
        assert summary["folders"] == 1
        # The unreadable name is reported, not swallowed.
        assert summary["errors"] == 1

    def test_unreadable_folder_placeholder_is_not_classified_away(self):
        """Guards the placeholder itself: if it ever lands in either set, the
        folder above would be skipped as a wrapper or as non-mail."""
        assert UNREADABLE_FOLDER_NAME.strip().lower() not in WRAPPER_FOLDER_NAMES
        assert UNREADABLE_FOLDER_NAME.strip().lower() not in NON_EMAIL_FOLDER_NAMES

    def test_message_ids_are_unique_across_the_walk(self, tmp_path):
        """Every email must carry its own id.

        This is not cosmetic. The client derives the Email row's primary key
        from this id (uuidv5 of 'email:pst:<collection>:<id>'), so any two
        messages sharing an id upsert onto the same row: a whole archive
        collapses into a single email and the import looks empty. Regression
        test for the parser reading a non-existent get_entry_identifier(),
        which sent every message down the fallback and gave them all the same
        literal id.
        """
        events = _walk_fake_tree(self._tree(), tmp_path)
        ids = [e["id"] for e in events if e["type"] == "email"]
        assert ids, "walk produced no emails"
        assert all(i for i in ids), "some emails have a blank id"
        assert len(set(ids)) == len(ids), (
            f"{len(ids) - len(set(ids))} of {len(ids)} emails share an id — "
            "they would collapse onto one row in the client"
        )

    def test_messages_without_an_identifier_still_get_unique_ids(self, tmp_path):
        """When the descriptor id is unreadable the fallback must still be
        per-message, not one shared sentinel — otherwise a damaged PST silently
        imports as a single email."""
        inbox = _FakeFolder("Inbox", msgs=3, no_identifiers=True)
        deep = _FakeFolder("Archive", msgs=2, no_identifiers=True)
        root = _FakeFolder("Root", subs=[inbox, deep])
        events = _walk_fake_tree(root, tmp_path)

        ids = [e["id"] for e in events if e["type"] == "email"]
        assert len(ids) == 5
        assert len(set(ids)) == 5, "id-less messages collapsed onto one id"
        # The id is also used as an on-disk attachment filename prefix, so it
        # must not carry path separators.
        assert all("/" not in i and "\\" not in i for i in ids)

    def test_clean_tree_reports_zero_errors(self, tmp_path):
        """A healthy tree must end with errors == 0 so the client can mark the
        import complete."""
        inbox = _FakeFolder("Inbox", msgs=3)
        root = _FakeFolder("Root", subs=[inbox])
        events = _walk_fake_tree(root, tmp_path)
        summary = events[-1]
        assert summary["type"] == "summary"
        assert summary["errors"] == 0
        assert summary["emails"] == 3
