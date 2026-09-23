#!/usr/bin/env bash
# setup-singapore-proxy: export a proxy to later steps, optionally rotate it,
# and check that the egress IP really is a Singapore mobile IP.
set -euo pipefail
export LC_ALL=C

POLL_EVERY="${SG_POLL_EVERY:-3}"            # seconds between IP checks after rotating
DEFAULT_RETRY_AFTER="${SG_DEFAULT_RETRY_AFTER:-240}"  # SMP's per-modem rotation cooldown

# Customer-visible egress ASNs first, then each carrier's company/fixed ASNs.
# Singtel mobile data = AS45143, M1 mobile data = AS4773, StarHub mobile = AS9874.
carrier_for_asn() {
  case "$1" in
    45143|7473) echo singtel ;;
    4773|17547) echo m1 ;;
    9874|4657|55430) echo starhub ;;
    *) echo unknown ;;
  esac
}

err() { echo "::error title=setup-singapore-proxy::$*" >&2; exit 1; }
warn() { echo "::warning title=setup-singapore-proxy::$*" >&2; }
out() { [ -n "${GITHUB_OUTPUT:-}" ] && echo "$1=$2" >> "$GITHUB_OUTPUT"; return 0; }
# skip 1-3 char values: masking "p" would star out every p in the log
mask() { [ "${#1}" -ge 4 ] && echo "::add-mask::$1"; return 0; }
is_true() { case "$(echo "$1" | tr '[:upper:]' '[:lower:]')" in true|1|yes|on) return 0 ;; *) return 1 ;; esac; }
is_uint() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

urlencode() {
  local s="$1" out="" c i
  for (( i = 0; i < ${#s}; i++ )); do
    c="${s:i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) out+="$c" ;;
      *) out+=$(printf '%%%02X' "'$c") ;;
    esac
  done
  printf '%s' "$out"
}

urldecode() { local s="${1//+/ }"; printf '%b' "${s//%/\\x}"; }

# pull one string field out of flat JSON without needing jq
json_field() {
  printf '%s' "$1" | tr -d '\r\n' | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p"
}

# ---- 1. work out the proxy -------------------------------------------------
PROXY_URL="${IN_PROXY_URL:-}"
if [ -n "$PROXY_URL" ]; then
  re='^([a-zA-Z0-9]+)://((.*)@)?([^:/@]+):([0-9]+)/?$'
  [[ "$PROXY_URL" =~ $re ]] || err "proxy-url must look like scheme://user:pass@host:port (got something else; check the secret)."
  SCHEME="${BASH_REMATCH[1]}"; AUTH="${BASH_REMATCH[3]}"
  HOST="${BASH_REMATCH[4]}"; PORT="${BASH_REMATCH[5]}"
  USERNAME="$(urldecode "${AUTH%%:*}")"
  PASSWORD=""; [[ "$AUTH" == *:* ]] && PASSWORD="$(urldecode "${AUTH#*:}")"
else
  SCHEME="${IN_PROXY_SCHEME:-http}"; HOST="${IN_PROXY_HOST:-}"; PORT="${IN_PROXY_PORT:-}"
  USERNAME="${IN_PROXY_USERNAME:-}"; PASSWORD="${IN_PROXY_PASSWORD:-}"
  [ -n "$HOST" ] && [ -n "$PORT" ] || err "set proxy-url, or proxy-host and proxy-port. If you passed secrets, check they exist in this repo (secrets are empty on pull requests from forks)."
  is_uint "$PORT" || err "proxy-port must be a number, got '$PORT'."
  AUTH=""
  if [ -n "$USERNAME" ]; then
    AUTH="$(urlencode "$USERNAME")"
    [ -n "$PASSWORD" ] && AUTH+=":$(urlencode "$PASSWORD")"
    AUTH+="@"
  fi
  PROXY_URL="${SCHEME}://${AUTH}${HOST}:${PORT}"
fi
case "$SCHEME" in http|socks5|socks5h) ;; *) err "proxy scheme must be http, socks5 or socks5h, got '$SCHEME'." ;; esac

mask "$PASSWORD"; mask "$(urlencode "$PASSWORD")"; mask "$PROXY_URL"; mask "${IN_ROTATE_URL:-}"

# ---- 2. helpers that go through the proxy ----------------------------------
IP_INFO_URL="${IN_IP_INFO_URL:-https://ipinfo.io/json}"
LAST_INFO=""
fetch_info() {  # sets LAST_INFO; returns non-zero on failure
  LAST_INFO="$(curl -sS --fail --max-time 20 -x "$PROXY_URL" -H 'Accept: application/json' "$IP_INFO_URL" 2>&1)" || return 1
}
current_ip() { fetch_info && json_field "$LAST_INFO" ip; }

# ---- 3. optional rotation --------------------------------------------------
ROTATED=""
if [ -n "${IN_ROTATE_URL:-}" ]; then
  ROTATE_TIMEOUT="${IN_ROTATE_TIMEOUT:-90}"; MAX_WAIT="${IN_ROTATE_MAX_WAIT:-300}"
  is_uint "$ROTATE_TIMEOUT" || err "rotate-timeout must be whole seconds."
  is_uint "$MAX_WAIT" || err "rotate-max-wait must be whole seconds."

  OLD_IP="$(current_ip || true)"
  [ -n "$OLD_IP" ] || warn "could not read the IP before rotating, so the action can't tell whether it changed."

  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  call_rotate() {
    curl -sS --max-time 60 -o "$tmp/body" -D "$tmp/headers" -w '%{http_code}' "$IN_ROTATE_URL" 2>"$tmp/curlerr" || true
  }
  code="$(call_rotate)"
  if [ "$code" = "429" ]; then
    ra="$(tr -d '\r' < "$tmp/headers" | sed -n 's/^[Rr]etry-[Aa]fter:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | tail -1)"
    [ -n "$ra" ] || ra="$DEFAULT_RETRY_AFTER"
    [ "$ra" -le "$MAX_WAIT" ] || err "rotation link is cooling down for another ${ra}s (HTTP 429), longer than rotate-max-wait=${MAX_WAIT}s. Each modem allows one rotation every few minutes; space out jobs that rotate the same port."
    echo "Rotation link answered 429, waiting ${ra}s as asked (Retry-After) ..."
    sleep "$ra"
    code="$(call_rotate)"
  fi
  if [ "$code" = "000" ]; then
    err "could not reach the rotation link: $(head -c 300 "$tmp/curlerr")"
  elif [ "$code" -ge 400 ]; then
    err "rotation link returned HTTP $code: $(head -c 300 "$tmp/body")"
  fi
  echo "Rotation accepted (HTTP $code). Waiting up to ${ROTATE_TIMEOUT}s for the modem to redial ..."

  NEW_IP=""; start=$SECONDS
  while [ $(( SECONDS - start )) -lt "$ROTATE_TIMEOUT" ]; do
    sleep "$POLL_EVERY"
    ip="$(current_ip || true)"
    [ -n "$ip" ] || continue          # requests fail while the modem redials
    NEW_IP="$ip"
    [ -z "$OLD_IP" ] || [ "$ip" != "$OLD_IP" ] && break
  done

  if [ -z "$NEW_IP" ]; then
    err "the proxy did not answer within ${ROTATE_TIMEOUT}s after rotating. Try a longer rotate-timeout."
  elif [ -z "$OLD_IP" ]; then
    ROTATED=unknown; echo "IP after rotation: $NEW_IP"
  elif [ "$NEW_IP" != "$OLD_IP" ]; then
    ROTATED=true; echo "IP changed: $OLD_IP -> $NEW_IP"
  else
    ROTATED=false
    msg="the carrier handed back the same IP ($NEW_IP). That happens on mobile networks; rotate again after the cooldown."
    is_true "${IN_REQUIRE_NEW_IP:-false}" && err "$msg"
    warn "$msg"
  fi
fi
out rotated "${ROTATED:-false}"

# ---- 4. verify egress ------------------------------------------------------
if is_true "${IN_VERIFY:-true}"; then
  fetch_info || err "could not fetch $IP_INFO_URL through the proxy. curl said: $(printf '%s' "$LAST_INFO" | head -c 300). Check the host, port and credentials, and that the plan hasn't expired."
  IP="$(json_field "$LAST_INFO" ip)"; COUNTRY="$(json_field "$LAST_INFO" country)"
  ORG="$(json_field "$LAST_INFO" org)"
  ASN_NUM="$(printf '%s' "$ORG" | sed -n 's/^AS\([0-9][0-9]*\).*/\1/p')"
  [ -n "$IP" ] || err "IP lookup answered without an ip field: $(printf '%s' "$LAST_INFO" | head -c 300)"
  CARRIER="$(carrier_for_asn "${ASN_NUM:-0}")"
  ASN=""; [ -n "$ASN_NUM" ] && ASN="AS$ASN_NUM"

  out ip "$IP"; out country "$COUNTRY"; out asn "$ASN"; out carrier "$CARRIER"
  echo "Egress: $IP  country=$COUNTRY  $ORG  carrier=$CARRIER"

  [ "$COUNTRY" = "SG" ] || err "egress IP $IP is in '${COUNTRY:-unknown}', not Singapore (SG)."
  ALLOWED="$(echo "${IN_ALLOWED_CARRIERS:-singtel,m1}" | tr -d ' ' | tr '[:upper:]' '[:lower:]')"
  [[ ",$ALLOWED," == *",$CARRIER,"* ]] || err "egress IP $IP is on ${ORG:-an unknown ASN} (carrier=$CARRIER), which isn't in allowed-carriers ($ALLOWED)."

  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
      echo "### Singapore proxy"
      echo "| IP | Country | ASN | Carrier | Rotated |"
      echo "|---|---|---|---|---|"
      echo "| \`$IP\` | $COUNTRY | $ORG | $CARRIER | ${ROTATED:-no} |"
    } >> "$GITHUB_STEP_SUMMARY"
  fi
else
  out ip "${NEW_IP:-}"; out country ""; out asn ""; out carrier ""
fi

# ---- 5. hand the proxy to later steps --------------------------------------
if is_true "${IN_EXPORT_ENV:-true}"; then
  [ -n "${GITHUB_ENV:-}" ] || err "GITHUB_ENV is not set; export-env only works inside GitHub Actions."
  {
    for v in HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy; do echo "$v=$PROXY_URL"; done
    NP="${IN_NO_PROXY-localhost,127.0.0.1,::1}"
    echo "NO_PROXY=$NP"; echo "no_proxy=$NP"
    # Playwright/Puppeteer ignore *_PROXY, so give them the parts separately
    echo "SG_PROXY_URL=$PROXY_URL"
    echo "SG_PROXY_SERVER=${SCHEME}://${HOST}:${PORT}"
    echo "SG_PROXY_USERNAME=$USERNAME"
    echo "SG_PROXY_PASSWORD=$PASSWORD"
  } >> "$GITHUB_ENV"
  echo "Exported HTTP_PROXY/HTTPS_PROXY/ALL_PROXY and SG_PROXY_* for the rest of the job."
fi
