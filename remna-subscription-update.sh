#!/opt/bin/sh
# Entware: curl + jq + mikefarah/yq v4 + mihomo. No subscription URLs in logs.
set -u
umask 077
PATH=/opt/bin:/opt/sbin:/usr/bin:/usr/sbin:/bin:/sbin
export PATH
SETTINGS=${2:-/opt/etc/remna-subscription/settings.json}
STATE=${3:-/opt/etc/remna-subscription}
CACHE=${4:-/opt/etc/mihomo/proxies/subscription-resilient.yaml}
SELF=/opt/sbin/remna-subscription-update

once() (
    mkdir -p "$STATE" "$(dirname "$CACHE")" || exit 2
    LOCK="$STATE/update.lock"
    if ! mkdir "$LOCK" 2>/dev/null; then
        owner=$(cat "$LOCK/pid" 2>/dev/null || :)
        case "$owner" in ''|*[!0-9]*) exit 3;; esac
        if kill -0 "$owner" 2>/dev/null; then exit 3; fi
        rm -f "$LOCK/pid"; rmdir "$LOCK" 2>/dev/null || exit 3
        mkdir "$LOCK" 2>/dev/null || exit 3
    fi
    printf '%s\n' "$$" > "$LOCK/pid"
    TMP=$(mktemp -d "$(dirname "$CACHE")/.remna-update.XXXXXX") || exit 2
    cleanup() { rm -f "$LOCK/pid"; rmdir "$LOCK" 2>/dev/null || :; rm -rf "$TMP"; }
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    ATTEMPT=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    errors='[]'
    for source in primary reserve; do
        # curl config keeps token-bearing URLs out of process arguments.
        if ! jq -er --arg source "$source" '
            "url = " + (.[$source] | @json),
            ((.headers // {}) | to_entries[] | .key as $name | .value[] | "header = " + (($name+": "+.) | @json))
        ' "$SETTINGS" > "$TMP/curl.conf"; then exit 2; fi
        reason=download_failed
        if curl --config "$TMP/curl.conf" --silent --show-error --fail --location \
            --proto '=https' --proto-redir '=https' --max-redirs 3 --noproxy '*' \
            --connect-timeout 5 --max-time 15 --max-filesize 2097152 \
            --output "$TMP/response" 2>"$TMP/curl.log"; then
            reason=invalid_subscription
            if yq -o=json '.proxies' "$TMP/response" > "$TMP/nodes.json" 2>"$TMP/yq.log" && \
               jq -e 'type == "array" and length > 0 and
                 all(.[]; type == "object" and (.name | type == "string" and length > 0) and (.type | type == "string" and length > 0)) and
                 ([.[].name] | length == (unique | length))' "$TMP/nodes.json" >/dev/null 2>&1; then
                jq '{proxies: ., rules: ["MATCH,DIRECT"], "log-level": "error"}' "$TMP/nodes.json" > "$TMP/validation.json"
                mkdir -p "$TMP/validator"
                if mihomo -t -d "$TMP/validator" -f "$TMP/validation.json" >"$TMP/mihomo.log" 2>&1; then
                    jq '{proxies: .}' "$TMP/nodes.json" > "$TMP/provider.yaml"
                    hash=$(sha256sum "$TMP/provider.yaml" | cut -d ' ' -f 1)
                    count=$(jq 'length' "$TMP/nodes.json")
                    changed=true
                    if [ -f "$CACHE" ] && cmp -s "$CACHE" "$TMP/provider.yaml"; then
                        changed=false
                    else
                        if [ -f "$CACHE" ]; then cp -p "$CACHE" "$TMP/last-good" && mv -f "$TMP/last-good" "$CACHE.previous" || exit 2; fi
                        chmod 600 "$TMP/provider.yaml"
                        mv -f "$TMP/provider.yaml" "$CACHE" || exit 2
                    fi
                    jq -n --arg at "$ATTEMPT" --arg source "$source" --arg hash "$hash" \
                        --argjson count "$count" --argjson changed "$changed" --argjson errors "$errors" \
                        '{last_attempt:$at,last_success:$at,result:"ok",source:$source,node_count:$count,sha256:$hash,changed:$changed,errors:$errors}' \
                        > "$TMP/status.json"
                    mv -f "$TMP/status.json" "$STATE/status.json"
                    printf 'subscription_update result=ok source=%s nodes=%s changed=%s\n' "$source" "$count" "$changed"
                    exit 0
                fi
                reason=mihomo_validation_failed
            fi
        fi
        errors=$(printf '%s' "$errors" | jq --arg source "$source" --arg reason "$reason" '. + [{source:$source,reason:$reason}]')
    done
    previous='{}'
    [ ! -f "$STATE/status.json" ] || previous=$(cat "$STATE/status.json")
    printf '%s' "$previous" | jq --arg at "$ATTEMPT" --argjson errors "$errors" \
        '. + {last_attempt:$at,result:"kept_cache",changed:false,errors:$errors}' > "$TMP/status.json"
    mv -f "$TMP/status.json" "$STATE/status.json"
    printf 'subscription_update result=kept_cache sources_unavailable=2\n'
    exit 1
)

daemon() {
    PIDFILE=/opt/var/run/remna-subscription.pid
    sleep_pid=''
    finish() {
        [ -z "$sleep_pid" ] || kill "$sleep_pid" 2>/dev/null || :
        [ "$(cat "$PIDFILE" 2>/dev/null)" != "$$" ] || rm -f "$PIDFILE"
        exit 0
    }
    trap finish TERM INT
    mkdir -p /opt/var/run
    printf '%s\n' "$$" > "$PIDFILE"
    while :; do
        if "$SELF" once >/dev/null 2>&1; then delay=3600; else delay=300; fi
        sleep "$delay" & sleep_pid=$!
        wait "$sleep_pid" || :
        sleep_pid=''
    done
}

case "${1:-once}" in
    once) once;;
    daemon) daemon;;
    *) printf 'Usage: remna-subscription-update once [settings state cache] | daemon\n' >&2; exit 2;;
esac
