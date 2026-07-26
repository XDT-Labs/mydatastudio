import pypff
import json
import hashlib
import os
import argparse
import sys
import re
import mimetypes
from datetime import datetime
from email import headerregistry, policy
from email.parser import HeaderParser

# PST folder names that store non-email items (contacts, calendar events,
# tasks, notes, etc.).  Any folder whose name (case-insensitive) matches one
# of these will have its messages *skipped* during the walk so they are never
# surfaced as email records to the caller.
NON_EMAIL_FOLDER_NAMES = frozenset({
    "contacts",
    "calendar",
    "tasks",
    "notes",
    "journal",
    # Exchange sync/conflict folders – not real mail
    "sync issues",
    "conflicts",
    "server failures",
    "local failures",
})

# These folder names are transparent wrappers in the PST hierarchy.
# Their names are excluded from the path so that
#   Root / Top of Personal Folders / Inbox / 2010
# becomes simply:
#   Inbox / 2010
WRAPPER_FOLDER_NAMES = frozenset({
    "root",
    "top of personal folders",
    "personal folders",
    "mailbox",
    "outlook data file",
})

# Stand-in for a folder whose name could not be read. Must stay outside both
# sets above so an unnamed-by-error folder is still treated as a real mail
# folder and its direct messages are imported.
UNREADABLE_FOLDER_NAME = "(unreadable folder)"

# MAPI property IDs read straight off a message's record sets when pypff's
# convenience accessors fail. Mail written by older Exchange servers stores text
# in codepages libpff cannot map (e.g. codepage 4013), which makes
# get_subject() / get_sender_name() / get_transport_headers() / get_plain_text_body()
# raise even though the value sits readable in the record set. Without these
# fallbacks such messages import as "(Unknown Sender)" with no subject or body.
PR_MESSAGE_CLASS = 0x001A
PR_SUBJECT = 0x0037
PR_SENT_REPRESENTING_NAME = 0x0042
PR_SENT_REPRESENTING_EMAIL_ADDRESS = 0x0065
PR_TRANSPORT_MESSAGE_HEADERS = 0x007D
PR_BODY = 0x1000
PR_HTML = 0x1013
PR_DISPLAY_CC = 0x0E03
PR_DISPLAY_TO = 0x0E04
PR_SENDER_NAME = 0x0C1A
PR_SENDER_EMAIL_ADDRESS = 0x0C1F

# PR_MESSAGE_CLASS prefixes that identify an item as actual mail. A PST folder
# holds more than mail — Outlook keeps free/busy blocks, view definitions and
# other bookkeeping items as "messages" too, and those would otherwise import as
# emails with no sender and a fabricated (import-time) date.
#
# "IPM.Note" covers ordinary mail and its variants (IPM.Note.SMIME, ...);
# "REPORT." covers delivery/non-delivery reports, which are real mail the user
# received and expects to see. Anything else with a *readable* class is skipped.
# A message whose class is missing or unreadable is imported anyway — failing
# open here loses nothing, while failing closed would silently drop real mail.
MAIL_MESSAGE_CLASS_PREFIXES = ("ipm.note", "report.")


class PstParser:
    def __init__(self, pst_file, output_dir):
        self.pst_file = pst_file
        self.output_dir = output_dir
        self.pst = pypff.file()
        # Per-walk counters for the completion summary (reset in walk()).
        self._folder_count = 0
        self._email_count = 0
        self._error_count = 0
        
    @staticmethod
    def safe_str(value):
        if value is None:
            return None
        if isinstance(value, bytes):
            try:
                return value.decode('utf-8')
            except UnicodeDecodeError:
                try:
                    return value.decode('cp1252')
                except UnicodeDecodeError:
                    return value.decode('utf-8', errors='replace')
        return str(value)

    @staticmethod
    def _parse_address_header(header_value: str) -> list:
        """
        Parse an RFC-2822 address header value (From, To, CC, etc.) and
        return a list of formatted strings like "Name <email@example.com>".
        Entries without an email address (e.g. display-name-only) are skipped
        unless there are no valid addresses at all, in which case the raw
        display name is kept as a fallback.
        """
        if not header_value:
            return []

        from email.utils import getaddresses
        # getaddresses handles comma-separated lists, quoted strings, folded headers
        pairs = getaddresses([header_value])

        results = []
        for display_name, email_addr in pairs:
            display_name = (display_name or "").strip().strip("'\"")
            email_addr = (email_addr or "").strip()
            if email_addr and "@" in email_addr:
                if display_name and display_name.lower() != email_addr.lower():
                    results.append(f"{display_name} <{email_addr}>")
                else:
                    results.append(email_addr)
        return results

    @classmethod
    def _entry_str(cls, entry):
        """Read one record-set entry as text, or None if it holds no readable text."""
        try:
            return entry.get_data_as_string()
        except Exception:
            try:
                return cls.safe_str(entry.get_data())
            except Exception:
                return None

    @classmethod
    def _record_set_props(cls, item) -> dict:
        """Map entry_type -> string for every readable entry on `item`.

        This is the raw MAPI view of a message or attachment. It is the fallback
        path for the PR_* properties above: the record set is readable even for
        the messages whose typed accessors raise on an unsupported codepage.
        First occurrence of an entry type wins; unreadable entries are omitted.
        """
        props: dict = {}
        try:
            for rs_idx in range(item.number_of_record_sets):
                rs = item.get_record_set(rs_idx)
                for e_idx in range(rs.number_of_entries):
                    try:
                        entry = rs.get_entry(e_idx)
                    except Exception:
                        continue
                    if entry.entry_type in props:
                        continue
                    value = cls._entry_str(entry)
                    if value:
                        props[entry.entry_type] = value
        except Exception:
            pass
        return props

    @classmethod
    def _try_accessor(cls, message, name):
        """Call a pypff accessor, returning (succeeded, value).

        The distinction matters. An accessor that *returned* an empty value is
        telling us the property is genuinely empty; one that *raised* means the
        value exists but this code path can't decode it. Only the latter is
        worth falling back to the record set for — and only the latter avoids
        paying that cost on every message with, say, no HTML body.
        """
        try:
            return True, cls.safe_str(getattr(message, name)())
        except Exception:
            return False, None

    @staticmethod
    def _strip_subject_prefix(subject):
        """Strip the two-byte marker that fronts a raw PR_SUBJECT value.

        MAPI encodes the reply/forward prefix length in the first two characters
        (0x01 followed by len(prefix) + 1); pypff's get_subject() removes them,
        so the record-set fallback has to do the same or every recovered subject
        starts with control characters.
        """
        if subject and subject[0] == "\x01" and len(subject) >= 2:
            return subject[2:]
        return subject

    @staticmethod
    def _format_address(display_name, email_addr):
        """Combine a MAPI display name + address into "Name <addr>", or None."""
        display_name = (display_name or "").strip().strip("'\"")
        email_addr = (email_addr or "").strip()
        if email_addr and "@" in email_addr:
            if display_name and display_name.lower() != email_addr.lower():
                return f"{display_name} <{email_addr}>"
            return email_addr
        return display_name or None

    @staticmethod
    def _split_display_recipients(value) -> list:
        """Split a PR_DISPLAY_TO / PR_DISPLAY_CC value into recipient addresses.

        These properties are semicolon-separated (splitting on commas too would
        break names stored as "Smith, Joe"), and hold whatever Outlook displayed
        in the header — sometimes an SMTP address, sometimes a bare display name
        or Exchange alias. Only entries carrying an actual address are kept, so
        this fallback can't smuggle display-name-only values into `to`/`cc`.
        """
        if not value:
            return []
        # Outlook stores Sent Items recipients quoted ('addr@host'); keeping the
        # quotes would make the same person a different string here than in a
        # received message's To: header.
        return [
            part.strip().strip("'\"")
            for part in value.split(";")
            if part.strip() and "@" in part
        ]

    def open(self):
        self.pst.open(self.pst_file)
        
    def close(self):
        self.pst.close()
        
    def walk(self):
        # Reset counters so a reused parser reports a fresh summary.
        self._folder_count = 0
        self._email_count = 0
        self._error_count = 0
        try:
            root = self.pst.get_root_folder()
            yield from self._process_folder(root, "")
        except Exception as e:
            yield self._emit_error(f"Error walking PST root: {str(e)}")
        # Explicit end-of-walk marker. Its presence tells the client the parser
        # reached the end (as opposed to an aborted stream); the counts let the
        # client decide whether the import was clean or only partial. PST is a
        # one-shot import with no re-sync, so this signal gates completion.
        yield {
            "type": "summary",
            "folders": self._folder_count,
            "emails": self._email_count,
            "errors": self._error_count,
        }

    def _emit_error(self, message):
        """Build an error event and count it toward the completion summary."""
        self._error_count += 1
        return {"type": "error", "message": message}


    @staticmethod
    def _is_wrapper_folder(folder_name: str) -> bool:
        """Return True if this folder is a transparent wrapper (Root, Top of Personal Folders, etc.)."""
        return (folder_name or "").strip().lower() in WRAPPER_FOLDER_NAMES

    @staticmethod
    def _is_non_email_folder(folder_name: str) -> bool:
        """Return True if this folder stores non-email items (contacts, calendar, etc.)."""
        return (folder_name or "").strip().lower() in NON_EMAIL_FOLDER_NAMES

    @staticmethod
    def _is_mail_message_class(message_class) -> bool:
        """Return True if PR_MESSAGE_CLASS says this item is mail.

        Complements the folder-name filter: that one catches whole folders of
        non-mail (Contacts, Calendar), this one catches individual non-mail
        items sitting in folders that do hold mail.
        """
        if not message_class:
            return True  # unknown class — import rather than risk losing mail
        return message_class.strip().lower().startswith(MAIL_MESSAGE_CLASS_PREFIXES)

    @staticmethod
    def _get_attachment_filename(att, index: int) -> str:
        """
        Extract a human-readable filename from a pypff.attachment object.

        pypff.attachment has no get_name() method; filenames are stored as MAPI
        properties inside the record set:
          PR_ATTACH_LONG_FILENAME  (0x3707) – preferred (full Unicode name)
          PR_ATTACH_FILENAME       (0x3704) – 8.3 short name fallback
          PR_DISPLAY_NAME          (0x3001) – last resort display name
        """
        # MAPI property IDs to probe, in order of preference
        FILENAME_PROPS = (0x3707, 0x3704, 0x3001)

        try:
            for rs_idx in range(att.number_of_record_sets):
                rs = att.get_record_set(rs_idx)
                # Build a map of entry_type → entry for quick lookup
                props: dict = {}
                for e_idx in range(rs.number_of_entries):
                    try:
                        entry = rs.get_entry(e_idx)
                        props[entry.entry_type] = entry
                    except Exception:
                        continue
                for prop_id in FILENAME_PROPS:
                    if prop_id in props:
                        try:
                            name = props[prop_id].get_data_as_string()
                            if name and name.strip():
                                return name.strip()
                        except Exception:
                            continue
        except Exception:
            pass

        return f"attachment_{index}"

    @staticmethod
    def _get_content_type(filename: str) -> str:
        """
        Determine the MIME type for an attachment from its file extension.
        Falls back to 'application/octet-stream' if the type cannot be inferred.
        """
        mime_type, _ = mimetypes.guess_type(filename)
        return mime_type or "application/octet-stream"


    def _process_folder(self, folder, folder_path):
        # A folder whose name can't be read is still worth descending into, so
        # fall back to a placeholder name rather than aborting the subtree.
        #
        # The two fallbacks differ deliberately. An *empty* name is the real
        # PST root, which must be treated as a wrapper so it stays out of the
        # path. A name that *raised* belongs to an unknown folder that may well
        # hold mail, so it gets a placeholder matching neither
        # WRAPPER_FOLDER_NAMES nor NON_EMAIL_FOLDER_NAMES — classifying it as a
        # wrapper would silently skip its direct messages.
        try:
            folder_name = folder.get_name() or "Root"
        except Exception as e:
            folder_name = UNREADABLE_FOLDER_NAME
            yield self._emit_error(f"Error reading folder name: {str(e)}")

        is_wrapper = self._is_wrapper_folder(folder_name)
        is_non_email = self._is_non_email_folder(folder_name)

        # Wrapper folders (Root, Top of Personal Folders, etc.) are transparent:
        # we skip them in the path so Inbox appears at the top level.
        if is_wrapper:
            yield from self._recurse_subfolders(folder, folder_path, folder_name)
            return

        current_path = os.path.join(folder_path, folder_name) if folder_path else folder_name
        self._folder_count += 1

        # Notify Dart about the folder. A corrupt message-count must not discard
        # the folder or its subtree — report 0, say so once, and carry on. This
        # single read is reused for the message loop below.
        try:
            num_messages = folder.get_number_of_sub_messages()
        except Exception as e:
            num_messages = 0
            yield self._emit_error(
                f"Error reading message count in {folder_name}: {str(e)}"
            )
        yield {
            "type": "folder",
            "name": folder_name,
            "path": current_path,
            "count": num_messages,
            "is_email_folder": not is_non_email,
        }

        # Process messages, except in well-known non-email folders (contacts,
        # calendar, etc.) whose items aren't mail. Either way we still descend
        # into sub-folders below.
        if not is_non_email:
            for i in range(num_messages):
                try:
                    message = folder.get_sub_message(i)
                    result = self._process_message(message, current_path, i)
                    if result:
                        if result.get("type") == "email":
                            self._email_count += 1
                        elif result.get("type") == "error":
                            self._error_count += 1
                        yield result
                except Exception as e:
                    yield self._emit_error(f"Error getting message {i} in {folder_name}: {str(e)}")

        yield from self._recurse_subfolders(folder, current_path, folder_name)

    def _recurse_subfolders(self, folder, child_path, folder_name):
        """Recurse into every sub-folder, isolating per-folder failures so one
        corrupt sub-tree can't abort the whole walk."""
        try:
            num_folders = folder.get_number_of_sub_folders()
        except Exception as e:
            yield self._emit_error(f"Error reading sub-folder count in {folder_name}: {str(e)}")
            return
        for i in range(num_folders):
            try:
                sub_folder = folder.get_sub_folder(i)
                yield from self._process_folder(sub_folder, child_path)
            except Exception as e:
                yield self._emit_error(f"Error getting sub-folder {i} in {folder_name}: {str(e)}")

    def _process_message(self, message, folder_path, index=0):
        try:
            # The id is the primary key the client derives its Email row id from,
            # so it MUST be unique per message: a shared id collapses the whole
            # import into a single upserted row. pypff.message exposes the PST
            # descriptor id via get_identifier() — unique within the file — and
            # has no get_entry_identifier() at all, so reaching for the latter
            # silently gave every message the same id.
            entry_id = None
            try:
                identifier = message.get_identifier()
                if identifier is not None:
                    entry_id = str(identifier)
            except Exception:
                pass
            if not entry_id:
                # Still unique per message, and filesystem-safe for the
                # attachment filename prefix below.
                digest = hashlib.sha1(
                    f"{folder_path}\x00{index}".encode("utf-8", errors="replace")
                ).hexdigest()[:16]
                entry_id = f"m{digest}"

            # Built on demand: the typed accessors below work for most messages,
            # and walking every record-set entry is only worth it for the ones
            # they fail on.
            record_props = None

            def prop(prop_id):
                nonlocal record_props
                if record_props is None:
                    record_props = self._record_set_props(message)
                return record_props.get(prop_id)

            # Non-mail items (free/busy blocks, view definitions) live alongside
            # mail in ordinary folders. Returning None skips them without
            # counting toward either the email or the error tally.
            if not self._is_mail_message_class(prop(PR_MESSAGE_CLASS)):
                return None

            delivery_time = None
            try:
                delivery_time = message.get_delivery_time()
            except: pass
            
            # Handle possible null date
            msg_date = delivery_time.isoformat() if delivery_time else datetime.now().isoformat()
            year = delivery_time.year if delivery_time else datetime.now().year
            
            data = {
                "type": "email",
                "id": entry_id,
                "folder": folder_path,
                "date": msg_date,
                "attachments": [],
                "to": [],
                "cc": []
            }

            subject_ok, subject = self._try_accessor(message, "get_subject")
            if not subject_ok:
                subject = self._strip_subject_prefix(prop(PR_SUBJECT))
            data["subject"] = subject

            # ----------------------------------------------------------------
            # Parse sender and recipients from Transport Headers.
            # pypff's `get_sender_email_address()` and `get_number_of_recipients()`
            # are absent in many builds; the Transport-Headers property reliably
            # contains the original RFC-2822 From/To/CC header lines.
            # ----------------------------------------------------------------
            headers_ok, headers_str = self._try_accessor(message, "get_transport_headers")
            if not headers_ok:
                headers_str = prop(PR_TRANSPORT_MESSAGE_HEADERS)
            headers_str = headers_str or ""

            parsed_headers = HeaderParser().parsestr(headers_str, headersonly=True)

            # --- Sender ---
            # Preference order: the RFC-2822 From: line, then the MAPI sender
            # properties (which carry a real address for Exchange-internal mail
            # that never got transport headers), then the display name alone.
            sender_from_headers = self._parse_address_header(parsed_headers.get('From', ''))
            if sender_from_headers:
                data["sender"] = sender_from_headers[0]
            else:
                sender = self._format_address(
                    prop(PR_SENT_REPRESENTING_NAME),
                    prop(PR_SENT_REPRESENTING_EMAIL_ADDRESS),
                ) or self._format_address(
                    prop(PR_SENDER_NAME),
                    prop(PR_SENDER_EMAIL_ADDRESS),
                )
                if not sender:
                    sender = self._try_accessor(message, "get_sender_name")[1]
                data["sender"] = sender or "(Unknown Sender)"

            # --- To ---
            to_from_headers = self._parse_address_header(parsed_headers.get('To', ''))
            if to_from_headers:
                data["to"] = to_from_headers
            else:
                data["to"] = self._split_display_recipients(prop(PR_DISPLAY_TO))

            # --- CC ---
            cc_from_headers = self._parse_address_header(parsed_headers.get('Cc', '') or parsed_headers.get('CC', ''))
            if cc_from_headers:
                data["cc"] = cc_from_headers
            else:
                data["cc"] = self._split_display_recipients(prop(PR_DISPLAY_CC))

            body_ok, body = self._try_accessor(message, "get_plain_text_body")
            if not body_ok:
                body = prop(PR_BODY)
            data["body"] = body or ""

            html_ok, html_body = self._try_accessor(message, "get_html_body")
            if not html_ok:
                html_body = prop(PR_HTML)
            data["html_body"] = html_body or ""

            # Extract attachments
            # NOTE: pypff.attachment has no get_name() or get_data().
            # - Filename comes from MAPI record-set properties:
            #     PR_ATTACH_LONG_FILENAME (0x3707) preferred,
            #     PR_ATTACH_FILENAME      (0x3704) short name fallback,
            #     PR_DISPLAY_NAME         (0x3001) last resort.
            # - Binary data comes from seek_offset(0, 0) + read_buffer(size).
            try:
                num_attachments = message.get_number_of_attachments()
                if num_attachments > 0:
                    real_output = os.path.realpath(self.output_dir)
                    attachment_folder = os.path.join(self.output_dir, folder_path, str(year))
                    # folder_path derives from attacker-controllable PST folder names,
                    # so confirm the target stays inside output_dir BEFORE creating it
                    # (AUDIT M1: the check must precede makedirs, and use a trailing
                    # separator so '/a/b' can't be escaped via a sibling like '/a/bc').
                    real_folder = os.path.realpath(attachment_folder)
                    if real_folder != real_output and not real_folder.startswith(real_output + os.sep):
                        num_attachments = 0
                    else:
                        os.makedirs(attachment_folder, exist_ok=True)

                    for i in range(num_attachments):
                        try:
                            att = message.get_attachment(i)
                            raw_filename = self._get_attachment_filename(att, i)
                            # Sanitize filename to prevent path traversal
                            filename = os.path.basename(raw_filename).replace('..', '')
                            if not filename:
                                filename = f"attachment_{i}"

                            safe_filename = f"{entry_id}_{filename}"
                            file_path = os.path.join(attachment_folder, safe_filename)

                            # Verify resolved path stays within output directory
                            # (trailing separator prevents a sibling-dir escape).
                            real_path = os.path.realpath(file_path)
                            if not real_path.startswith(real_output + os.sep):
                                continue

                            # get_size() raises on attachments whose data stream
                            # libpff can't resolve, and reports 0 for ones that
                            # carry no bytes. Neither yields a file worth
                            # writing, so skip before touching the filesystem.
                            try:
                                att_size = att.get_size()
                            except Exception:
                                att_size = 0
                            if not att_size:
                                continue

                            att.seek_offset(0, 0)
                            raw_data = att.read_buffer(att_size)

                            with open(file_path, "wb") as f_out:
                                f_out.write(raw_data)

                            data["attachments"].append({
                                "name": filename,
                                "path": file_path,
                                "size": os.path.getsize(file_path),
                                "contentType": self._get_content_type(filename),
                            })
                        except Exception as att_e:
                            # Individual attachment failed; keep processing others
                            pass
            except Exception:
                # get_number_of_attachments() can raise for corrupted/unsupported
                # PST entries (libpff descriptor table error).  Skip gracefully.
                pass
            
            return data
            
        except Exception as e:
            return {"type": "error", "message": f"Fatal error in _process_message: {str(e)}"}

def main():
    parser = argparse.ArgumentParser(description="Outlook PST Parser")
    parser.add_argument("--file", required=True, help="Path to the PST file")
    parser.add_argument("--output_dir", required=True, help="Directory to save attachments")
    
    args = parser.parse_args()
    
    if not os.path.exists(args.file):
        print(f"Error: File {args.file} not found", file=sys.stderr)
        sys.exit(1)
        
    try:
        pst_parser = PstParser(args.file, args.output_dir)
        pst_parser.open()
        for item in pst_parser.walk():
            print(json.dumps(item))
        pst_parser.close()
    except Exception as e:
        print(f"Error: {str(e)}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
