# Security and privacy

- No shared credentials are provided. The user-requested direct API-key mode stores the key in macOS Keychain through a hidden settings field, with no redisplay. Native reads/writes run off the main thread; the child receives a bounded one-shot stdin message, never a key in argv/env/settings. Existing user-authorized Vault-compatible helper/service metadata remains supported. Credential-source choice is explicit and failures never switch sources.
- Do not submit tokens, private keys, account cookies, personal dictionaries, typed text, settings, logs, or backups in issues, pull requests, release assets, or Git history.
- `work/`, `artifacts/`, `.venv/`, local settings, sockets, model weights, and dictionary databases are ignored. `.gitignore` is not a substitute for inspecting staged files and scanning history.
- Cloud and cloud + local modes send the current bounded context, pinyin, and candidates to TypeSafe. It is off by default and enabled per application. Local mode never silently switches to cloud.
- TLS verification and redirect rejection protect credential retrieval. Do not weaken these checks to work around configuration errors.
- This source release uses an ad-hoc local build, not Apple Developer ID notarization. macOS input-source consent remains required.

If you find a security issue, use GitHub's private vulnerability reporting when available, or contact the repository owner privately. Do not post a working secret or sensitive reproduction data in a public issue.
