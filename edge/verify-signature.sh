#!/bin/sh
# Build-time helper: verify a detached PGP signature against pinned key fingerprints.
#   verify-signature.sh FILE SIGNATURE KEYFILE FINGERPRINT...
# The key file is imported into a throw-away keyring. Every FINGERPRINT (full 40 hex digits) must be
# among its primary keys, and the signature must be good and made by one of them. A key that is only
# identified by a short ID, or one not in the pinned list, never passes.
set -eu
file=$1 sig=$2 keyfile=$3
shift 3
[ "$#" -ge 1 ] || { echo "verify-signature: no fingerprint given" >&2; exit 2; }
for fpr in "$@"; do
  case $fpr in
    *[!0-9A-F]* | "") echo "verify-signature: not a full upper-case fingerprint: $fpr" >&2; exit 2 ;;
  esac
  [ "${#fpr}" -eq 40 ] || { echo "verify-signature: not a full fingerprint: $fpr" >&2; exit 2; }
done

home=$(mktemp -d)
trap 'rm -rf "$home"' EXIT
export GNUPGHOME=$home
gpg --batch --quiet --import "$keyfile" 2>/dev/null

primaries=$(gpg --batch --with-colons --list-keys | awk -F: '/^pub/{p=1;next} p&&/^fpr/{print $10;p=0}')
for fpr in "$@"; do
  echo "$primaries" | grep -qx "$fpr" || { echo "verify-signature: pinned key $fpr is not in $keyfile" >&2; exit 1; }
done

status=$(gpg --batch --status-fd 1 --verify "$sig" "$file" 2>/dev/null || true)
# Only a plain GOODSIG counts: an expired, revoked or bad key or signature is refused.
if echo "$status" | grep -qE '^\[GNUPG:\] (EXPKEYSIG|REVKEYSIG|EXPSIG|BADSIG|ERRSIG) '; then
  echo "verify-signature: $file has an expired, revoked or bad signature or key" >&2; exit 1
fi
echo "$status" | grep -q '^\[GNUPG:\] GOODSIG ' || { echo "verify-signature: no good signature on $file" >&2; exit 1; }
signer=$(echo "$status" | awk '$2=="VALIDSIG"{print $NF}')
[ -n "$signer" ] || { echo "verify-signature: no valid signature on $file" >&2; exit 1; }
for fpr in "$@"; do
  [ "$signer" = "$fpr" ] && { echo "verify-signature: $file signed by $fpr"; exit 0; }
done
echo "verify-signature: $file signed by $signer, which is not pinned" >&2
exit 1
