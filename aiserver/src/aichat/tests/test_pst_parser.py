"""
TDD tests for PstParser email field quality.

These tests validate that the parser correctly extracts:
  - FROM: must contain a valid email address, never just a display name
           or the sentinel value "Unknown" / "(Unknown Sender)"
  - TO:   must be a list (can be empty for some system messages,
           but should be populated for real emails)
  - CC:   must be a list (can be empty when there are no CC recipients)

Run from the project root:
  pdm run pytest src/aichat/tests/test_pst_parser.py -v

Or with plain pytest (if pypff is on sys.path / installed):
  pytest src/aichat/tests/test_pst_parser.py -v
"""

import re
import sys
import os
import pytest

# ---------------------------------------------------------------------------
# Adjust the path so we can import PstParser from the sibling package
# ---------------------------------------------------------------------------
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from pst_parser import PstParser, NON_EMAIL_FOLDER_NAMES  # noqa: E402

# ---------------------------------------------------------------------------
# Path to the test PST file – override via env var if needed
# ---------------------------------------------------------------------------
PST_FILE = os.environ.get("TEST_PST_FILE", "")

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

@pytest.fixture(scope="module")
def all_raw_records():
    """
    Parse the PST file once and return ALL non-folder records (emails, errors)
    as-is, with NO folder filtering applied.  Used by TestItemTypeFiltering to
    verify the parser itself gates non-email folders.
    """
    if not os.path.exists(PST_FILE):
        pytest.skip(f"PST file not found at {PST_FILE!r}. Set TEST_PST_FILE env var.")

    parser = PstParser(PST_FILE, output_dir="/tmp/pst_test_output")
    parser.open()
    records = [r for r in parser.walk() if r.get("type") != "folder"]
    parser.close()
    return records


@pytest.fixture(scope="module")
def parsed_emails():
    """
    Parse the PST file once for the entire test module and return only the
    email-type records from genuine mail folders (Inbox, Sent Items, etc.).
    Contacts, Calendar, Tasks, Notes and Journal items are excluded since they
    are not mail messages and don't have From/To/CC fields.
    """
    if not os.path.exists(PST_FILE):
        pytest.skip(f"PST file not found at {PST_FILE!r}. Set TEST_PST_FILE env var.")

    parser = PstParser(PST_FILE, output_dir="/tmp/pst_test_output")
    parser.open()

    emails = []
    for record in parser.walk():
        if record.get("type") == "email":
            folder = record.get("folder", "")
            if not _is_non_email_folder(folder):
                emails.append(record)

    parser.close()

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
