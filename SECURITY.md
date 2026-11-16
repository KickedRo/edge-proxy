# Security policy

## Reporting a vulnerability

Please report it privately, using GitHub's private vulnerability reporting: go to the **Security** tab of this
repository and choose **Report a vulnerability**. Do not open a public issue or pull request for a vulnerability.

Include what you found, how to reproduce it, and which image tag or digest you tested. You will get an answer when
the maintainers can, with no fixed response time: this project is maintained for the maintainers' own use.

## What is in scope

- The `edge` and `gen` images as published by this repository, and their configuration: for example a way around
  a protection that is documented as on by default, or a flaw in how the images are built, signed or published.
- The workflows and scripts in this repository (`.github/`, `scripts/`).

## What is not in scope

- Vulnerabilities in nginx, ModSecurity, the OWASP Core Rule Set, docker-gen, nginx-proxy's template, Debian packages
  or acme-companion: report those to the upstream project. If a fixed version exists, a rebuild picks it up; tell us
  if it does not.
- Findings that need a setting the documentation marks as weakened (a `SECURITY:` line at start).
- Rule bypasses that are false negatives of the OWASP Core Rule Set itself (report them to the CRS project).

## Supported versions

Only the current `latest` images. Older tags are not patched; update to the newest image.
