deploy/ssl/  —  Cloudflare Origin Certificate material.

Production nginx terminates TLS with two files placed in this directory:

    origin.crt   — full certificate chain (PEM-encoded, leaf + any intermediates)
    origin.key   — private key (PEM-encoded, unencrypted)

Both files are mounted into the nginx container at /etc/nginx/ssl
read-only. They are loaded by deploy/nginx.conf at startup; nginx will
fail fast with "cannot load certificate" if either is missing.

Domain:  accommodation.parisunitedgroup.com


How to obtain the cert
----------------------
1.  Cloudflare dashboard → select your zone (parisunitedgroup.com)
    → SSL/TLS → Origin Server → "Create Certificate".
2.  Private key type: RSA (2048).
    Hostnames:  accommodation.parisunitedgroup.com
               (add *.parisunitedgroup.com if you'll want other
                subdomains under the same cert later)
    Validity:   15 years  (longest Cloudflare offers).
3.  Two text blocks will appear:
       - "Origin Certificate" — paste into  deploy/ssl/origin.crt
       - "Private key"        — paste into  deploy/ssl/origin.key
    Each file should look like:
       -----BEGIN CERTIFICATE-----
       MIIE...lots of base64...
       -----END CERTIFICATE-----
    and for the key:
       -----BEGIN PRIVATE KEY-----
       MIIE...lots of base64...
       -----END PRIVATE KEY-----
    See origin.crt.example next to this file for the literal layout.

File permissions
----------------
Linux / macOS:
    chmod 644 deploy/ssl/origin.crt
    chmod 600 deploy/ssl/origin.key

Windows (Docker Desktop / WSL2):
    chmod doesn't apply to NTFS the same way, but you should still
    right-click → Properties → Security and restrict origin.key to
    Administrators + your user account. The container mounts the
    files read-only either way, so the runtime guarantee holds; the
    Windows ACL is just defence in depth on the host.

DO NOT COMMIT
-------------
.gitignore already excludes deploy/ssl/* except this README and the
*.example template files. If you accidentally `git add origin.crt` or
`origin.key`, REVOKE the certificate in Cloudflare and mint a new one.
Once a private key has touched a public history it's compromised forever.

Line endings (Windows users — important!)
-----------------------------------------
When pasting from the Cloudflare dashboard into Notepad / VS Code on
Windows, the file may get saved with CRLF line endings. Nginx accepts
those for the certificate, but some openssl tool chains and older
nginx builds choke. Save the files as UTF-8 with **LF** line endings:
  - VS Code: bottom-right status bar → "CRLF" → click → "LF" → File: Save.
  - Notepad++: Edit → EOL Conversion → Unix (LF).
The nginx.conf in this repo and the Alpine image we ship don't
require LF, but standardising on LF avoids future surprises.

Full deployment runbook: see ../../DEPLOY.md.
