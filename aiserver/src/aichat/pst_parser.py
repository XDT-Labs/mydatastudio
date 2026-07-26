import pypff
import json
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
                    result = self._process_message(message, current_path)
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

    def _process_message(self, message, folder_path):
        try:
            entry_id = "unknown"
            try:
                eid = message.get_entry_identifier()
                if isinstance(eid, bytes):
                    entry_id = eid.hex()
                else:
                    entry_id = str(eid)
            except: pass

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

            try:
                data["subject"] = self.safe_str(message.get_subject())
            except Exception as e:
                data["subject"] = f"(Error getting subject: {str(e)})"

            # ----------------------------------------------------------------
            # Parse sender and recipients from Transport Headers.
            # pypff's `get_sender_email_address()` and `get_number_of_recipients()`
            # are absent in many builds; the Transport-Headers property reliably
            # contains the original RFC-2822 From/To/CC header lines.
            # ----------------------------------------------------------------
            headers_str = ""
            try:
                raw = message.get_transport_headers()
                if raw:
                    headers_str = raw.decode('utf-8', errors='replace') if isinstance(raw, bytes) else str(raw)
            except:
                pass

            parsed_headers = HeaderParser().parsestr(headers_str, headersonly=True)

            # --- Sender ---
            sender_from_headers = self._parse_address_header(parsed_headers.get('From', ''))
            if sender_from_headers:
                data["sender"] = sender_from_headers[0]
            else:
                # Fallback: try get_sender_name() which IS available
                try:
                    fallback_name = self.safe_str(message.get_sender_name())
                    data["sender"] = fallback_name or "(Unknown Sender)"
                except:
                    data["sender"] = "(Unknown Sender)"

            # --- To ---
            to_from_headers = self._parse_address_header(parsed_headers.get('To', ''))
            if to_from_headers:
                data["to"] = to_from_headers

            # --- CC ---
            cc_from_headers = self._parse_address_header(parsed_headers.get('Cc', '') or parsed_headers.get('CC', ''))
            if cc_from_headers:
                data["cc"] = cc_from_headers

            try:
                data["body"] = self.safe_str(message.get_plain_text_body())
            except:
                data["body"] = ""

            try:
                data["html_body"] = self.safe_str(message.get_html_body())
            except:
                data["html_body"] = ""
            
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

                            att.seek_offset(0, 0)
                            raw_data = att.read_buffer(att.size)

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
