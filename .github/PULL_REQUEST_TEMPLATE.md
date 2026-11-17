## What and why

<!-- What does this change, and why is it needed? Link the issue it comes from: a change that adds a setting, a
mount point or other surface needs an agreed issue first (see CONTRIBUTING.md). -->

## How it was tested

<!-- The commands you ran and what they showed. -->

## Checklist

- [ ] A test covers the change and fails without it, and the commands in CONTRIBUTING.md pass.
- [ ] The documentation says what changed (README, `docs/`, examples), where users or maintainers need to know.
- [ ] `edge/settings.tsv` is unchanged, or `docs/settings.md` is regenerated with `scripts/gen_settings_doc.py`.
- [ ] `CHANGELOG.md` has an entry under `[Unreleased]`, or the change does not change behaviour.
- [ ] `VERSION` is bumped and `[Unreleased]` is dated as `[X.Y.0] - YYYY-MM-DD`, or this is no new feature and no
      changed default.
- [ ] Nothing site-specific: `example.com` and documentation address ranges only, no secrets.
