### From /cso security review

## Finding 1 — MEDIUM (confidence 6/10, TENTATIVE): Unauthenticated localhost AI server
aiserver/src/aichat/main.py:105

The FastAPI server binds 127.0.0.1 on a random port with no auth token. /thumbnail returns base64 of any file_path, and /import/pst reads file_path / writes to output_dir — both arbitrary local paths.

Why it's only MEDIUM/tentative: real mitigations stack up — random port (unknown to a remote attacker), JSON bodies trigger a CORS preflight that fails for non-localhost origins, and a local process running as the user could already read those files directly. So no clean trust-boundary crossing. But "unauthenticated localhost service with file-touching endpoints" is the kind of thing worth hardening in an OSS app where others may fork and change the bind.

Fix: have PythonManager generate a per-launch token, pass it from Flutter on every request, and reject requests without it. Small change, closes the CSRF/local-process angle entirely.


## Finding 2 — LOW (confidence 7/10, VERIFIED): Malicious PST folder names not sanitized before makedirs
aiserver/src/aichat/pst_parser.py:310

folder_name comes from folder.get_name() — attacker-controlled inside a malicious .pst — and is joined into the attachment path and passed to os.makedirs without stripping ... The per-file realpath().startswith() check (line 328) blocks file writes outside output_dir, but makedirs runs first, so a folder named ../../../tmp/x creates empty directories outside the target.

Impact: empty-directory creation outside the intended dir if a user imports a hostile PST. No arbitrary file write.

Fix: sanitize folder_name (basename + strip ..) and validate the resolved attachment_folder is within output_dir before makedirs. Also change startswith(real_output) → startswith(real_output + os.sep) to avoid sibling-prefix matches like /tmp/out vs /tmp/out-evil.

Two housekeeping notes
.gstack/ is not in .gitignore — the saved report at .gstack/security-reports/2026-05-30-full-audit.json would get committed. Add .gstack/ to .gitignore.
OAuth access_token/refresh_token are stored in plaintext in local SQLite. Standard for local-first desktop apps (OS user account is the trust boundary), so I didn't rate it a finding — but if you want defense-in-depth, flutter_secure_storage (Keychain) is the upgrade path.