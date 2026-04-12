# OVH API v1: DNS

ovh_sign() {
    local method="$1" url="$2" body="${3:-}" ts sig_hex
    ts=$(date +%s)
    sig_hex=$(printf '%s' "${OVH_APPLICATION_SECRET}+${OVH_CONSUMER_KEY}+${method}+${url}+${body}+${ts}" \
        | LC_ALL=C openssl dgst -sha1 | LC_ALL=C sed 's/^.* //')
    printf '%s\n' "$ts" '$1$'"$sig_hex"
}

ovh_http() {
    local method="$1" path="$2" body="${3:-}"
    local url ts sig tmp code resp_body
    local -a _ovh_sign_lines
    url="${OVH_ENDPOINT%/}/1.0${path}"
    mapfile -t _ovh_sign_lines < <(ovh_sign "$method" "$url" "$body")
    ts=${_ovh_sign_lines[0]}
    sig=${_ovh_sign_lines[1]}
    if [ -z "$ts" ] || [ -z "$sig" ]; then
        echo "WARNING: OVH signature failed (empty ts/sig); check openssl and OVH_* keys." >&2
        return 1
    fi
    tmp=$(mktemp) || return 1
    code=$(curl -sS -o "$tmp" -w "%{http_code}" -X "$method" "$url" \
        -H "Content-Type: application/json" \
        -H "X-Ovh-Application: $OVH_APPLICATION_KEY" \
        -H "X-Ovh-Consumer: $OVH_CONSUMER_KEY" \
        -H "X-Ovh-Timestamp: $ts" \
        -H "X-Ovh-Signature: $sig" \
        ${body:+-d "$body"}) || code="000"
    resp_body=$(cat "$tmp")
    rm -f "$tmp"
    printf '%s\n' "$resp_body"
    printf '%s\n' "$code"
}

ovh_zone_refresh() {
    local zone="$1" resp code body
    resp=$(ovh_http POST "/domain/zone/${zone}/refresh" "")
    code=$(echo "$resp" | tail -n1)
    body=$(echo "$resp" | sed '$d')
    if [ "$code" != "200" ] && [ "$code" != "201" ]; then
        echo "WARNING: OVH zone refresh zwrócił HTTP $code${body:+ — $body}" >&2
        return 1
    fi
    return 0
}

ovh_dns_set_a() {
    local zone="$1" sub="$2" ip="$3"
    local list_resp list_code ids first_id post_resp post_code put_resp put_code
    local body_post body_put list_body post_body put_body

    body_post=$(printf '{"fieldType":"A","subDomain":"%s","target":"%s","ttl":%s}' "$sub" "$ip" "$OVH_DNS_TTL")

    list_resp=$(ovh_http GET "/domain/zone/${zone}/record?fieldType=A&subDomain=${sub}" "")
    list_code=$(echo "$list_resp" | tail -n1)
    list_body=$(echo "$list_resp" | sed '$d')
    if [ "$list_code" != "200" ]; then
        echo "WARNING: OVH list record failed HTTP $list_code${list_body:+ — $list_body}" >&2
        return 1
    fi

    ids=$(echo "$list_body" | grep -oE '[0-9]+' || true)
    first_id=$(echo "$ids" | head -n1)

    if [ -n "$first_id" ]; then
        body_put=$(printf '{"target":"%s","subDomain":"%s","ttl":%s}' "$ip" "$sub" "$OVH_DNS_TTL")
        put_resp=$(ovh_http PUT "/domain/zone/${zone}/record/${first_id}" "$body_put")
        put_code=$(echo "$put_resp" | tail -n1)
        put_body=$(echo "$put_resp" | sed '$d')
        if [ "$put_code" != "200" ]; then
            echo "WARNING: OVH PUT A record failed HTTP $put_code${put_body:+ — $put_body}" >&2
            return 1
        fi
    else
        post_resp=$(ovh_http POST "/domain/zone/${zone}/record" "$body_post")
        post_code=$(echo "$post_resp" | tail -n1)
        post_body=$(echo "$post_resp" | sed '$d')
        if [ "$post_code" != "200" ] && [ "$post_code" != "201" ]; then
            echo "WARNING: OVH POST A record failed HTTP $post_code${post_body:+ — $post_body}" >&2
            return 1
        fi
    fi

    ovh_zone_refresh "$zone" || true
    if [ -n "$sub" ]; then
        echo "OVH DNS: A ${sub}.${zone} -> $ip"
    else
        echo "OVH DNS: A @ ${zone} -> $ip"
    fi
    return 0
}

ovh_dns_set_cname() {
    local zone="$1" sub="$2" target="$3"
    local list_resp list_code ids first_id post_resp post_code put_resp put_code
    local body_post body_put list_body post_body put_body

    body_post=$(printf '{"fieldType":"CNAME","subDomain":"%s","target":"%s","ttl":%s}' "$sub" "$target" "$OVH_DNS_TTL")

    list_resp=$(ovh_http GET "/domain/zone/${zone}/record?fieldType=CNAME&subDomain=${sub}" "")
    list_code=$(echo "$list_resp" | tail -n1)
    list_body=$(echo "$list_resp" | sed '$d')
    if [ "$list_code" != "200" ]; then
        echo "WARNING: OVH list CNAME failed HTTP $list_code${list_body:+ — $list_body}" >&2
        return 1
    fi

    ids=$(echo "$list_body" | grep -oE '[0-9]+' || true)
    first_id=$(echo "$ids" | head -n1)

    if [ -n "$first_id" ]; then
        body_put=$(printf '{"target":"%s","subDomain":"%s","ttl":%s}' "$target" "$sub" "$OVH_DNS_TTL")
        put_resp=$(ovh_http PUT "/domain/zone/${zone}/record/${first_id}" "$body_put")
        put_code=$(echo "$put_resp" | tail -n1)
        put_body=$(echo "$put_resp" | sed '$d')
        if [ "$put_code" != "200" ]; then
            echo "WARNING: OVH PUT CNAME failed HTTP $put_code${put_body:+ — $put_body}" >&2
            return 1
        fi
    else
        post_resp=$(ovh_http POST "/domain/zone/${zone}/record" "$body_post")
        post_code=$(echo "$post_resp" | tail -n1)
        post_body=$(echo "$post_resp" | sed '$d')
        if [ "$post_code" != "200" ] && [ "$post_code" != "201" ]; then
            echo "WARNING: OVH POST CNAME failed HTTP $post_code${post_body:+ — $post_body}" >&2
            return 1
        fi
    fi

    ovh_zone_refresh "$zone" || true
    if [ -n "$sub" ]; then
        echo "OVH DNS: CNAME ${sub}.${zone} -> $target"
    else
        echo "OVH DNS: CNAME @.${zone} -> $target"
    fi
    return 0
}

ovh_fetch_zones_sorted() {
    local resp code body
    resp=$(ovh_http GET "/domain/zone" "")
    code=$(echo "$resp" | tail -n1)
    body=$(echo "$resp" | sed '$d')
    if [ "$code" != "200" ]; then
        echo "WARNING: OVH GET /domain/zone failed HTTP $code${body:+ — $body}" >&2
        return 1
    fi
    echo "$body" | grep -oE '"[^"]+"' | tr -d '"' \
        | while IFS= read -r line; do
            [ -z "$line" ] && continue
            lc=$(echo "$line" | tr '[:upper:]' '[:lower:]')
            printf '%05d\t%s\n' "${#lc}" "$lc"
        done | sort -rn | cut -f2-
}

ovh_resolve_fqdn() {
    local fqdn="$1" zones_txt="$2"
    local fqdn_lc z sub z_lc
    fqdn_lc=$(echo "$fqdn" | tr '[:upper:]' '[:lower:]' | sed 's/\.$//')
    [ -z "$fqdn_lc" ] && return 1
    while IFS= read -r z; do
        [ -z "$z" ] && continue
        z_lc=$(echo "$z" | tr '[:upper:]' '[:lower:]')
        if [ "$fqdn_lc" = "$z_lc" ]; then
            printf '%s\n' "$z"
            printf '%s\n' ""
            return 0
        fi
        case "$fqdn_lc" in
            *."$z_lc")
                sub=${fqdn_lc%."$z_lc"}
                printf '%s\n' "$z"
                printf '%s\n' "$sub"
                return 0
                ;;
        esac
    done <<< "$zones_txt"
    return 1
}

ovh_dns_label_ok() {
    [[ "$1" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]]
}

ovh_dns_www_cname_enabled() {
    if falsey "${OVH_DNS_WWW_CNAME:-true}"; then
        return 1
    fi
    return 0
}

ovh_dns_apply_records_for_fqdn() {
    local fqdn="$1" zones_txt="$2" ip="$3"
    local resolved z sd canon canon_lc www_sd

    resolved=$(ovh_resolve_fqdn "$fqdn" "$zones_txt") || resolved=""
    if [ -z "$resolved" ]; then
        echo "WARNING: FQDN '$fqdn' nie pasuje do żadnej strefy DNS na tym koncie OVH — pomijam ten rekord." >&2
        return 0
    fi
    z=$(printf '%s\n' "$resolved" | sed -n '1p')
    sd=$(printf '%s\n' "$resolved" | sed -n '2p')

    if [ -n "$sd" ] && ! ovh_dns_label_ok "$sd"; then
        echo "WARNING: Odrzucono subdomenę '$sd' (nieprawidłowa etykieta) dla '$fqdn'." >&2
        return 0
    fi

    if ! ovh_dns_set_a "$z" "$sd" "$ip"; then
        return 0
    fi

    ovh_dns_www_cname_enabled || return 0

    canon="${fqdn%.}"
    canon_lc=$(echo "$canon" | tr '[:upper:]' '[:lower:]')
    if [ -n "$sd" ]; then
        www_sd="www.${sd}"
    else
        www_sd="www"
    fi
    if ! ovh_dns_label_ok "$www_sd"; then
        echo "WARNING: Pomijam CNAME www dla '$fqdn' (nieprawidłowa etykieta '$www_sd')." >&2
        return 0
    fi
    ovh_dns_set_cname "$z" "$www_sd" "${canon_lc}." || true
}
