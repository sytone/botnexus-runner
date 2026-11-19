# Security and safe publication

This is a public repository. Keep live profiles, deployment parameters, receipts,
logs, credentials, personal identifiers and private infrastructure endpoints outside
Git. Do not migrate production runner source or a live profile as part of this
repository bootstrap.

## Checks in this repository

The `Publication safety` workflow runs on pull requests, pushes, and a weekly
schedule. Its `privacy-guard` check reports only a rule and file location. It rejects
configured sensitive paths, credential-like assignments, private network endpoints,
and non-example email addresses and phone numbers. Its patterns are intentionally
limited heuristics; they do not prove that content contains no personal information.
Use documented examples such as `example.com`, `example.invalid`, RFC 5737
documentation IP ranges, and reserved `555-0100`–`555-0199` numbers.

The `secret-scan` job uses Gitleaks on the commit range and, on scheduled runs, the
complete fetched history. Findings are redacted; PR comments, job summaries and
uploaded scan artifacts are disabled. The job also smoke-tests detection of a
synthetic token and acceptance of example data. Never copy a real credential or
personal identifier into a test.

`.gitleaksignore` contains one exact historical fingerprint for a synthetic
publication-test sentinel that Gitleaks classified as a generic API key. The current
test fixture no longer uses the flagged variable name. Do not broaden or add
fingerprint exemptions without independent review.

Run the local privacy check before proposing a change:

```sh
python3 scripts/repo/publication_guard.py --history
```

The history option requires a complete Git clone and checks all local branches.
A clean current tree cannot remove sensitive content from an earlier commit. Rotate
exposed credentials and coordinate history cleanup privately; do not make a public
test branch containing real sensitive data.

## GitHub repository settings

Workflow files cannot enable or prove the effective state of GitHub repository
settings. A repository administrator must read back the settings in GitHub before
relying on them:

1. In **Settings → Code security and analysis**, verify secret scanning and push
   protection are enabled and effective for this public repository. GitHub documents
   secret scanning for public repositories at no cost and protected branches for
   public repositories on GitHub Free; secret scanning availability alone does not
   prove push protection is enabled. Verify any generic-pattern options required by
   the repository's policy. See GitHub's [secret scanning setup][secret-settings],
   [push protection][push-protection], and [protected branch][branch-protection]
   documentation.
2. Protect the default branch. Require pull requests, independent human approval,
   and both `Publication safety / privacy-guard` and
   `Publication safety / secret-scan` status checks. Block force pushes and branch
   deletion. Configure the rule so administrators and the bot cannot bypass the
   review or required checks.
3. If GitHub does not offer a requested control for this repository or plan, record
   that limitation and do not claim the repository is protected by it.

The available coding-agent interfaces could not read or change these repository
settings during this bootstrap. Therefore the effective state of secret scanning,
push protection and default-branch protection remains **unverified** until an
administrator confirms it in GitHub. A successful workflow run is not that
confirmation.

Auto-merge is authorized for this repository only after required checks pass and
independent review is complete. This does not authorize BotNexus application merges
or infrastructure deployment.

## Disclosure surfaces outside branch checks

Repository checks cannot reliably prevent sensitive disclosure in issue bodies,
pull-request titles or descriptions, comments, commit messages, workflow logs,
uploaded artifacts, release notes, or screenshots. Do not place secrets, private
infrastructure details, or personal data in those surfaces. Share a report privately
with the repository owner instead of opening a public issue containing the details.

[secret-settings]: https://docs.github.com/en/code-security/secret-scanning/enabling-secret-scanning-features/enabling-secret-scanning-for-your-repository
[push-protection]: https://docs.github.com/en/code-security/concepts/secret-security/push-protection
[branch-protection]: https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches
