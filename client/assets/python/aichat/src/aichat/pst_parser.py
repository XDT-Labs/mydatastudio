import pypff
import json
import os
import argparse
import sys
import re
from datetime import datetime
from email import headerregistry, policy
from email.parser import HeaderParser

class PstParser:
    def __init__(self, pst_file, output_dir):
        self.pst_file = pst_file
        self.output_dir = output_dir
        self.pst = pypff.file()
        
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
        root = self.pst.get_root_folder()
        yield from self._process_folder(root, "")
        
    def _process_folder(self, folder, folder_path):
        folder_name = folder.get_name() or "Root"
        current_path = os.path.join(folder_path, folder_name)
        
        # Notify Dart about the folder
        yield {
            "type": "folder",
            "name": folder_name,
            "path": current_path,
            "count": folder.get_number_of_sub_messages()
        }
        
        # Process messages using index-based access
        num_messages = folder.get_number_of_sub_messages()
        for i in range(num_messages):
            try:
                message = folder.get_sub_message(i)
                result = self._process_message(message, current_path)
                if result:
                    yield result
            except Exception as e:
                yield {"type": "error", "message": f"Error getting message {i} in {folder_name}: {str(e)}"}
            
        # Recursive walk using index-based access
        num_folders = folder.get_number_of_sub_folders()
        for i in range(num_folders):
            try:
                sub_folder = folder.get_sub_folder(i)
                yield from self._process_folder(sub_folder, current_path)
            except Exception as e:
                yield {"type": "error", "message": f"Error getting sub-folder {i} in {folder_name}: {str(e)}"}
            
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
            try:
                num_attachments = message.get_number_of_attachments()
                if num_attachments > 0:
                    attachment_folder = os.path.join(self.output_dir, folder_path, str(year))
                    if not os.path.exists(attachment_folder):
                        os.makedirs(attachment_folder, exist_ok=True)
                        
                    for i in range(num_attachments):
                        try:
                            att = message.get_attachment(i)
                            filename = att.get_name() or f"attachment_{i}"
                            
                            safe_filename = f"{entry_id}_{filename}"
                            file_path = os.path.join(attachment_folder, safe_filename)
                            
                            with open(file_path, "wb") as f:
                                f.write(att.get_data())
                                
                            data["attachments"].append({
                                "name": filename,
                                "path": file_path,
                                "size": os.path.getsize(file_path),
                                "contentType": "application/octet-stream"
                            })
                        except Exception as att_e:
                            # Log attachment error but continue with message
                            pass
            except:
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
