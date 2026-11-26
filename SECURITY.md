# Security

This project is experimental. There is currently no stable-release support commitment.

Report security vulnerabilities privately using the repository's **Security → Report a vulnerability** feature. Do not put working exploits, tokens, account details or health data in a public issue. If private reporting is unavailable, ask the maintainer for a private channel without publishing sensitive details.

Useful reports identify the affected commit, a minimal synthetic reproduction, impact and a proposed mitigation. Reports must not require access to another person's WHOOP or Apple Health account.

The app logs and reports WHOOP API errors without the WHOOP user ID, and the diagnostic sanitizer redacts `/user/<id>` paths along with tokens and email addresses. The sign-in web view reads session cookies only from `whoop.com` and its subdomains; look-alike domains such as `evilwhoop.com` are rejected.

If you accidentally disclose credentials, revoke/rotate them immediately. Removing a GitHub file does not remove it from Git history or copies.
