import pypff
import json
import os
import argparse
import sys
from datetime import datetime

class PstParser:
    def __init__(self, pst_file, output_dir):
        self.pst_file = pst_file
        self.output_dir = output_dir
        self.pst = pypff.file()
        
    def open(self):
        self.pst.open(self.pst_file)
        
    def close(self):
        self.pst.close()
        
    def walk(self):
        root = self.pst.get_root_folder()
        self._process_folder(root, "")
        
    def _process_folder(self, folder, folder_path):
        folder_name = folder.get_name() or "Root"
        current_path = os.path.join(folder_path, folder_name)
        
        # Notify Dart about the folder
        print(json.dumps({
            "type": "folder",
            "name": folder_name,
            "path": current_path
        }))
        
        # Process messages
        for message in folder.sub_messages:
            self._process_message(message, current_path)
            
        # Recursive walk
        for sub_folder in folder.sub_folders:
            self._process_folder(sub_folder, current_path)
            
    def _process_message(self, message, folder_path):
        try:
            delivery_time = message.get_delivery_time()
            # Handle possible null date
            msg_date = delivery_time.isoformat() if delivery_time else datetime.now().isoformat()
            year = delivery_time.year if delivery_time else datetime.now().year
            
            data = {
                "type": "email",
                "id": message.get_entry_identifier(),
                "subject": message.get_subject(),
                "sender": message.get_sender_name(),
                "date": msg_date,
                "body": message.get_plain_text_body(),
                "html_body": message.get_html_body(),
                "folder": folder_path,
                "attachments": []
            }
            
            # Extract attachments
            if message.get_number_of_attachments() > 0:
                # Target path similar to Gmail scanner: Folder/Year/Attachments
                # Using a flatter structure under the collection path
                attachment_folder = os.path.join(self.output_dir, folder_path, str(year))
                if not os.path.exists(attachment_folder):
                    os.makedirs(attachment_folder, exist_ok=True)
                    
                for i in range(message.get_number_of_attachments()):
                    att = message.get_attachment(i)
                    filename = att.get_name() or f"attachment_{i}"
                    
                    # Avoid collisions
                    safe_filename = f"{message.get_entry_identifier()}_{filename}"
                    file_path = os.path.join(attachment_folder, safe_filename)
                    
                    with open(file_path, "wb") as f:
                        f.write(att.get_data())
                        
                    data["attachments"].append({
                        "name": filename,
                        "path": file_path,
                        "size": os.path.getsize(file_path),
                        "contentType": "application/octet-stream" # pypff doesn't give mime type easily
                    })
            
            # Stream the JSON result
            print(json.dumps(data))
            
        except Exception as e:
            # Report error in a way Dart can handle
            print(json.dumps({"type": "error", "message": str(e)}), file=sys.stderr)

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
        pst_parser.walk()
        pst_parser.close()
    except Exception as e:
        print(f"Error: {str(e)}", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()
