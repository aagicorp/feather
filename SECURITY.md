# Security policy

## Supported versions

Only the latest release of Feather receives security fixes. Released copies check for updates once a day, so
staying current is the default; **Feather ▸ Check for Updates…** checks now. A fix for a serious problem is
shipped as a required update, which every older copy offers at once.

| Version | Supported |
| --- | --- |
| Latest release | Yes |
| Anything older | No, please update |

## Reporting a vulnerability

Please do not open a public issue for a security problem.

- Preferred: use GitHub's private vulnerability reporting, **Security ▸ Report a vulnerability** on the
  repository page (`https://github.com/aagicorp/feather/security/advisories/new`).
- Or email **SECURITY_CONTACT_EMAIL** (placeholder: fill in before the repository is published).

Include the Feather version (**Feather ▸ About Feather**), the macOS version, what you did, what happened and
what you expected. A proof of concept helps; a fix is welcome but not expected.

You will get an acknowledgement within 3 working days and a plan, or a request for more detail, within 10. We
will tell you when the fix ships and credit you in the release notes unless you prefer otherwise.

## What is in scope

Feather is a local application. Reports we are most concerned about:

- Code running without the user's say-so, in particular anything that gets past **Restricted Mode** (an
  untrusted folder must not start language servers, run tasks or run git).
- The update path: anything that would let a copy install an update that was not signed with the project's
  EdDSA key, or accept a feed it should not.
- Secrets leaving the Mac: API client secret variables are meant to live only in the Keychain; nothing in Feather
  should send project contents anywhere the user did not ask it to.
- The preview's local file server and localhost relay serving anything outside the folder they were asked to.

Crashes and bugs without a security consequence belong in an ordinary [issue](.github/ISSUE_TEMPLATE/bug_report.md).
