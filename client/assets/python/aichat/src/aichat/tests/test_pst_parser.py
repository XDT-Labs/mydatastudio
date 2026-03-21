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
from pst_parser import PstParser  # noqa: E402

# ---------------------------------------------------------------------------
# Path to the test PST file – override via env var if needed
# ---------------------------------------------------------------------------
PST_FILE = os.environ.get(
    "TEST_PST_FILE", "/Users/mikenimer/Desktop/email/mnimer_2010.pst"
)

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


# Non-email PST folders – items in these folders are contacts, tasks, calendar
# events, etc. They legitimately have no From/To/CC and should not be tested
# as if they were mail messages.
NON_EMAIL_FOLDER_NAMES = {
    "contacts", "calendar", "tasks", "notes", "journal",
    "deleted items", "outbox",  # 'outbox' items may be incomplete
    # Exchange system/sync folders – not real emails
    "sync issues", "conflicts", "server failures", "local failures",
}


def _is_non_email_folder(folder_path: str) -> bool:
    """Return True if any path component matches a known non-email folder."""
    parts = [p.lower() for p in re.split(r'[\\/]', folder_path)]
    return bool(NON_EMAIL_FOLDER_NAMES & set(parts))


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

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
# Summary / smoke test
# ---------------------------------------------------------------------------

class TestPstFileSanity:
    """Basic sanity checks on the PST file parsing itself."""

    def test_at_least_one_email_parsed(self, parsed_emails):
        """The PST file must contain at least one parseable email."""
        assert len(parsed_emails) > 0, "No emails were returned by the parser."

    def test_email_records_have_required_keys(self, parsed_emails):
        """Every email record must have the minimum set of required keys."""
        required_keys = {"type", "subject", "sender", "to", "cc", "date", "folder"}
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

        with capsys.disabled():
            print(f"\n{'='*60}")
            print(f"PST Parsing Statistics for: {PST_FILE}")
            print(f"{'='*60}")
            print(f"  Total emails parsed        : {total}")
            print(f"  FROM missing email addr    : {no_email_in_from} ({no_email_in_from/total*100:.1f}%)")
            print(f"  FROM is 'Unknown'/bad      : {unknown_from}   ({unknown_from/total*100:.1f}%)")
            print(f"  TO list is empty           : {empty_to}   ({empty_to/total*100:.1f}%)")
            print(f"  CC list is empty           : {empty_cc}   ({empty_cc/total*100:.1f}%)")
            print(f"{'='*60}")
