# Site exclusions and local rules (`custom.d`)

Mount a directory of `*.conf` files at `/etc/nginx/modsec/custom.d` in the `edge` container (read-only is fine; see
`examples/docker-compose.yml`). The files are loaded **before** the OWASP Core Rule Set, so an exclusion written
here is in place when the rule runs. Files that must come after the rules (`SecRuleRemoveById`, response
exclusions) go in `/etc/nginx/modsec/after.d` instead. An empty or missing directory is fine. The configuration
guide has the [full picture](../../docs/configuration.md#mount-points-for-your-own-rules-and-config), and the usual
[first-use false positives](../../docs/configuration.md#first-use-false-positives) (REST methods, upload types,
WordPress's method override, large forms) with their settings and files.

## How exclusions work

1. A request is blocked and the user (or your monitoring) reports it. The block page shows a reference; find the entry
   in the audit log with that `unique_id` (or run with `MODSEC_RULE_ENGINE=DetectionOnly` and read the log).
2. In the entry, note the rule **ID** and **tags** that matched and the variable (for example `ARGS:comment`).
3. Write the narrowest exclusion: one rule or tag, one variable, one host or path. Not "switch the rule off".
4. Restart the `edge` container (or reload nginx) and repeat the request.

## Rule IDs for your own rules

Use **10100 to 99999**. ID 10001 is the image's ACME exemption, and the Core Rule Set uses 900000 and up. Give
every rule an ID that is unique across your files.

## Example

`app-example-com.conf`: the form field `comment` on `app.example.com` may contain HTML, so the XSS rules must not
inspect that one field there. Everything else on that host, and that field on other hosts, is still checked.

```
SecRule REQUEST_HEADERS:Host "@streq app.example.com" \
    "id:10200,\
    phase:1,\
    pass,\
    nolog,\
    ctl:ruleRemoveTargetByTag=attack-xss;ARGS:comment"
```

To exclude a single rule from a single path instead, use `ctl:ruleRemoveById=<id>` with an exact path match
(`REQUEST_FILENAME "@streq /upload"`) or a prefix that ends in `/` (`"@beginsWith /api/"`). A bare prefix such as
`/api` also matches `/api-admin`. Remember that one request often matches several rules: the tag form
above removes a whole class at once.
