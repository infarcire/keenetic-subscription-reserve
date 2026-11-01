#!/opt/bin/sh
set -eu
umask 077
PATH=/opt/bin:/opt/sbin:/usr/bin:/usr/sbin:/bin:/sbin
export PATH
VERSION=v1.0.0
BASE="https://raw.githubusercontent.com/infarcire/keenetic-subscription-reserve/$VERSION"
[ "$(id -u)" = 0 ] || { printf 'Run in Entware as root\n'; exit 1; }
for tool in curl jq yq mihomo sha256sum; do
    command -v "$tool" >/dev/null || { printf 'Missing dependency: %s\n' "$tool"; exit 1; }
done
case "$(yq --version)" in *'version v4.'*) ;; *) printf 'mikefarah/yq v4 is required\n'; exit 1;; esac
TMP=$(mktemp -d /opt/tmp/remna-install.XXXXXX)
trap 'rm -rf "$TMP"' EXIT
trap 'exit 143' TERM INT
for name in remna-subscription-update.sh S98remna-subscription install-remna-subscription.sh; do
    curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --retry 2 --connect-timeout 10 --max-time 60 "$BASE/$name" -o "$TMP/$name"
done
cat > "$TMP/SHA256SUMS" <<'CHECKSUMS'
7232db4311cbe21c499c60b865e2a6dddeba840435fe9419f65814ba94a3a303  remna-subscription-update.sh
88e335c6fa7a67fd96ce0004c1e276c5f4123b4e13db4b3498d747e598bc23b8  S98remna-subscription
9c11adb92b5dfc9a19a0972dbfc509ef2cd71189ae883d9162db3665e19376f7  install-remna-subscription.sh
CHECKSUMS
(cd "$TMP" && sha256sum -c SHA256SUMS)
/opt/bin/sh "$TMP/install-remna-subscription.sh"
