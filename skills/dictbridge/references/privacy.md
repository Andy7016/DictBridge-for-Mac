# Privacy and issue reports

## Contents

- Data handling rules
- Allowed report content
- Forbidden report content
- Redaction performed by `make-report.sh`
- Human review checklist

## Data handling rules

- Process dictionary files locally only.
- Do not upload `.mdx`, `.mdd`, `.dictionary`, or extracted entry content.
- Do not include dictionary download links.
- Do not request registration keys, passwords, cookies, or tokens.
- Do not send logs to a remote service.
- Do not modify the user's source dictionary.

## Allowed report content

- Dictionary name and edition;
- DictBridge version;
- macOS version and chip architecture;
- File names and sizes;
- Conversion stage and exit status;
- A short, redacted log excerpt;
- Screenshots without personal or copyrighted content.

## Forbidden report content

- Dictionary files or archives;
- Entry text beyond the minimum needed to explain a display bug;
- Download links;
- Usernames, email addresses, IP addresses, or absolute home-directory paths;
- API keys, tokens, passwords, registration keys, or session cookies;
- Proxy URLs, subscription links, or node credentials.

## Redaction performed by `make-report.sh`

The script:

- replaces the current home directory with `$HOME`;
- redacts other `/Users/<name>` paths;
- redacts common GitHub, OpenAI, and generic token patterns;
- redacts Bearer tokens and credential assignments;
- redacts email addresses and IPv4 addresses;
- replaces URLs with `<url>`;
- limits the report to 200 log lines and 20,000 characters by default.

Redaction is best-effort. It is not a substitute for human review.

## Human review checklist

Before sharing a report:

- [ ] No dictionary content is included.
- [ ] No download links are included.
- [ ] No credentials or personal paths remain.
- [ ] The log excerpt is sufficient to reproduce the failure.
- [ ] Screenshots do not expose private information.
- [ ] The user has approved sharing the report.
