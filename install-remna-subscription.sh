#!/opt/bin/sh
# Pilot installer for an existing subscription_1 on XKeen / Mihomo.
# Run from a directory containing remna-subscription-update.sh and S98remna-subscription.
set -eu
umask 077
PATH=/opt/bin:/opt/sbin:/usr/bin:/usr/sbin:/bin:/sbin
export PATH
ASSETS=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
STATE=/opt/etc/remna-subscription
CONFIG=/opt/etc/mihomo/config.yaml
CACHE=/opt/etc/mihomo/proxies/subscription-resilient.yaml
BACKUP="$STATE/before-$(date -u '+%Y%m%dT%H%M%SZ')"
SERVICE=/opt/etc/init.d/S98remna-subscription
PROGRAM=/opt/sbin/remna-subscription-update
[ "$(id -u)" = 0 ] || { printf 'Root required\n'; exit 1; }
for tool in curl jq yq mihomo sha256sum; do command -v "$tool" >/dev/null; done
if [ -e "$STATE/install.json" ]; then
    [ "$(jq -r .status "$STATE/install.json")" = active ] && [ ! -f "$STATE/disabled" ] || { printf 'Existing installation is not active; inspect it before reinstalling\n'; exit 1; }
    yq -e '.proxy-providers.subscription_1.type == "file" and .proxy-providers.subscription_1.path == "/opt/etc/mihomo/proxies/subscription-resilient.yaml"' "$CONFIG" >/dev/null
    [ -s "$STATE/settings.json" ] && [ -s "$CACHE" ]
    cp "$ASSETS/remna-subscription-update.sh" "$PROGRAM.next"; chmod 700 "$PROGRAM.next"; mv -f "$PROGRAM.next" "$PROGRAM"
    cp "$ASSETS/S98remna-subscription" "$SERVICE.next"; chmod 700 "$SERVICE.next"; mv -f "$SERVICE.next" "$SERVICE"
    "$SERVICE" restart
    sleep 1
    "$SERVICE" status
    printf 'Existing installation updated; personal settings and original backup preserved\n'
    exit 0
fi
yq -e '.proxy-providers.subscription_1.type == "http"' "$CONFIG" >/dev/null
mkdir -p "$BACKUP" "$(dirname "$CACHE")"
chmod 700 "$STATE" "$BACKUP"
cp -p "$CONFIG" "$BACKUP/config.yaml"
sha256sum "$CONFIG" | cut -d ' ' -f 1 > "$BACKUP/original.sha256"
yq -o=json '.proxy-providers.subscription_1' "$CONFIG" | jq '
 if (.url | startswith("https://sub.demon-cloud.pro/")) then
 {primary:.url,reserve:("https://sub.demon.sarl:8443"+(.url|ltrimstr("https://sub.demon-cloud.pro"))),headers:.header}
 else error("Unexpected primary subscription origin") end' > "$STATE/settings.json"
chmod 600 "$STATE/settings.json"
cp "$ASSETS/remna-subscription-update.sh" "$PROGRAM"; chmod 700 "$PROGRAM"
cp "$ASSETS/S98remna-subscription" "$SERVICE"; chmod 700 "$SERVICE"
"$PROGRAM" once
yq '.proxy-providers.subscription_1.type = "file" |
 .proxy-providers.subscription_1.path = "/opt/etc/mihomo/proxies/subscription-resilient.yaml" |
 del(.proxy-providers.subscription_1.url,.proxy-providers.subscription_1.interval,.proxy-providers.subscription_1.header)' \
 "$CONFIG" > "$STATE/config.next.yaml"
mihomo -t -d /opt/etc/mihomo -f "$STATE/config.next.yaml" > "$STATE/config-validation.log" 2>&1

# Reload helper reads the controller secret from the config; never puts it in arguments.
cat > "$STATE/api.sh" <<'API'
#!/opt/bin/sh
set -eu
umask 077
PATH=/opt/bin:/opt/sbin:/usr/bin:/usr/sbin:/bin:/sbin
export PATH
STATE=/opt/etc/remna-subscription
CONFIG=/opt/etc/mihomo/config.yaml
METHOD=$1; ENDPOINT=$2; BODY=${3:-}
port=$(yq -r '."external-controller"' "$CONFIG"); port=${port##*:}
case "$port" in ''|*[!0-9]*) exit 2;; esac
tmp=$(mktemp "$STATE/.api.XXXXXX")
trap 'rm -f "$tmp"' EXIT
yq -o=json '.secret // ""' "$CONFIG" | jq -r --arg method "$METHOD" --arg url "http://127.0.0.1:$port/$ENDPOINT" \
 '"url = "+($url|@json), "request = "+($method|@json), "header = \"Content-Type: application/json\"",
 (if length>0 then "header = "+(("Authorization: Bearer "+.)|@json) else empty end)' > "$tmp"
if [ -n "$BODY" ]; then
    curl --config "$tmp" --fail --silent --show-error --noproxy '*' --connect-timeout 3 --max-time 15 --data-binary "@$BODY"
else
    curl --config "$tmp" --fail --silent --show-error --noproxy '*' --connect-timeout 3 --max-time 15
fi
API
chmod 700 "$STATE/api.sh"
jq -n --arg backup "$BACKUP" '{backup_dir:$backup,provider:"subscription_1",status:"prepared"}' > "$STATE/install.json"
cat > "$STATE/rollback.sh" <<'ROLLBACK'
#!/opt/bin/sh
set -eu
umask 077
PATH=/opt/bin:/opt/sbin:/usr/bin:/usr/sbin:/bin:/sbin
export PATH
STATE=/opt/etc/remna-subscription
backup=$(jq -r .backup_dir "$STATE/install.json")
case "$backup" in /opt/etc/remna-subscription/before-*) ;; *) exit 2;; esac
touch "$STATE/disabled"
/opt/etc/init.d/S98remna-subscription stop || :
cp -p "$backup/config.yaml" /opt/etc/mihomo/.config.rollback.yaml
mv -f /opt/etc/mihomo/.config.rollback.yaml /opt/etc/mihomo/config.yaml
printf '{}\n' > "$STATE/.reload.json"
"$STATE/api.sh" PUT 'configs?force=true' "$STATE/.reload.json"
rm -f "$STATE/.reload.json"
jq '.status="rolled_back"' "$STATE/install.json" > "$STATE/.install.next"
mv -f "$STATE/.install.next" "$STATE/install.json"
printf 'Original subscription config restored\n'
ROLLBACK
chmod 700 "$STATE/rollback.sh"
"$STATE/api.sh" GET proxies > "$BACKUP/proxies-before.json"
expected=$(jq '.node_count' "$STATE/status.json")
[ "$(sha256sum "$CONFIG" | cut -d ' ' -f 1)" = "$(cat "$BACKUP/original.sha256")" ] || { printf 'Configuration changed during preparation; refusing activation\n'; exit 1; }
switched=0; completed=0
cleanup() {
    if [ "$switched" = 1 ] && [ "$completed" = 0 ]; then
        printf 'Activation failed; restoring original config\n'
        "$STATE/rollback.sh" || printf 'ROLLBACK_REQUIRES_ATTENTION\n'
    fi
}
trap cleanup EXIT
trap 'exit 143' TERM INT
cp -p "$STATE/config.next.yaml" /opt/etc/mihomo/.config.resilient.yaml
mv -f /opt/etc/mihomo/.config.resilient.yaml "$CONFIG"
switched=1
printf '{}\n' > "$STATE/.reload.json"
"$STATE/api.sh" PUT 'configs?force=true' "$STATE/.reload.json"
rm -f "$STATE/.reload.json"
actual=0; counter=0
while [ "$counter" -lt 10 ]; do
    "$STATE/api.sh" GET providers/proxies/subscription_1 > "$STATE/provider-check.json" || :
    actual=$(jq -r '.proxies | length' "$STATE/provider-check.json" 2>/dev/null || printf 0)
    [ "$actual" != "$expected" ] || break
    counter=$((counter+1)); sleep 1
done
[ "$actual" = "$expected" ]
[ "$(jq -r .vehicleType "$STATE/provider-check.json")" = File ]
# Preserve the user's selections across the hot reload.
jq -c '.proxies | to_entries[] | select(.value.type=="Selector") | {group:.key,node:.value.now}' "$BACKUP/proxies-before.json" > "$STATE/selections.jsonl"
while IFS= read -r selection; do
    group=$(printf '%s' "$selection" | jq -r '.group | @uri')
    printf '%s' "$selection" | jq '{name:.node}' > "$STATE/.selection.json"
    "$STATE/api.sh" PUT "proxies/$group" "$STATE/.selection.json"
done < "$STATE/selections.jsonl"
rm -f "$STATE/.selection.json"
"$SERVICE" start
sleep 1
"$SERVICE" status
jq '.status="active"' "$STATE/install.json" > "$STATE/.install.next"
mv -f "$STATE/.install.next" "$STATE/install.json"
completed=1
printf 'PILOT_ACTIVE provider=subscription_1 vehicle=File nodes=%s backup=%s\n' "$actual" "$BACKUP"
