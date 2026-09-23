# Setup Singapore Mobile Proxy

[![test](https://github.com/Xavierfok/setup-singapore-proxy/actions/workflows/test.yml/badge.svg)](https://github.com/Xavierfok/setup-singapore-proxy/actions/workflows/test.yml)

A GitHub Action that routes the rest of a job through a Singapore mobile IP, so your tests, scrapers or
checks see what a phone user in Singapore sees. It:

- exports `HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY` (and the lowercase versions) to every later step,
  plus `SG_PROXY_SERVER`, `SG_PROXY_USERNAME` and `SG_PROXY_PASSWORD` for tools that ignore those
  variables, like Playwright and Puppeteer
- can call your rotation link first and wait until the modem comes back with a new IP
- checks the egress IP through the proxy and **fails the job** unless it is in Singapore on an allowed
  carrier ASN, so a test never passes quietly from the wrong country
- masks the password, the proxy URL and the rotation link in the logs

It works with any HTTP or SOCKS5 proxy. It was built for
[Singapore Mobile Proxy](https://singaporemobileproxy.com/?utm_source=github&utm_medium=action) ports,
which sit on real 4G/5G modems with Singtel or M1 SIM cards.

## Usage

```yaml
- uses: Xavierfok/setup-singapore-proxy@v1
  with:
    proxy-url: ${{ secrets.SG_PROXY_URL }}   # http://user:pass@host:port
```

Or pass the parts separately:

```yaml
- uses: Xavierfok/setup-singapore-proxy@v1
  with:
    proxy-host: ${{ secrets.SG_PROXY_HOST }}
    proxy-port: ${{ secrets.SG_PROXY_PORT }}
    proxy-username: ${{ secrets.SG_PROXY_USER }}
    proxy-password: ${{ secrets.SG_PROXY_PASS }}
```

Every later step in the job now goes out through the proxy. `curl`, `wget`, `pip`, `npm`, Python
`requests` and most HTTP clients pick up `HTTPS_PROXY` on their own.

### Playwright geo tests

Browsers don't read `HTTPS_PROXY`, so point Playwright at the `SG_PROXY_*` variables:

```yaml
jobs:
  geo-test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 20
      - run: npm ci && npx playwright install --with-deps chromium
      - id: sg
        uses: Xavierfok/setup-singapore-proxy@v1
        with:
          proxy-url: ${{ secrets.SG_PROXY_URL }}
      - run: npx playwright test
        env:
          # keep the proxy for the browser, not for npm or Playwright's own traffic
          HTTPS_PROXY: ""
          HTTP_PROXY: ""
          https_proxy: ""
          http_proxy: ""
```

```ts
// playwright.config.ts
import { defineConfig } from '@playwright/test';

export default defineConfig({
  use: {
    proxy: process.env.SG_PROXY_SERVER
      ? {
          server: process.env.SG_PROXY_SERVER,
          username: process.env.SG_PROXY_USERNAME,
          password: process.env.SG_PROXY_PASSWORD,
        }
      : undefined,
    locale: 'en-SG',
    timezoneId: 'Asia/Singapore',
  },
});
```

Use the proxy's **HTTP** port with Playwright. Chromium doesn't support username/password auth on
SOCKS5 proxies.

### Rotate to a fresh IP first

```yaml
- uses: Xavierfok/setup-singapore-proxy@v1
  with:
    proxy-url: ${{ secrets.SG_PROXY_URL }}
    rotate-url: ${{ secrets.SG_ROTATE_URL }}
```

The action records the current IP, calls the rotation link, then polls through the proxy until the
IP changes (up to `rotate-timeout`, 90 s by default). Requests fail while the modem redials, and
the action expects that.

Mobile rotation is rate-limited per modem. If the link answers `429`, the action sleeps out the
`Retry-After` and tries once more, as long as the wait is under `rotate-max-wait`. A longer wait
fails the step. The carrier sometimes hands back the same IP. That's a warning by default and a
failure with `require-new-ip: true`. If several jobs share one port, only one of them should rotate.

### Use the result

```yaml
- id: sg
  uses: Xavierfok/setup-singapore-proxy@v1
  with:
    proxy-url: ${{ secrets.SG_PROXY_URL }}
- run: echo "Testing from ${{ steps.sg.outputs.ip }} on ${{ steps.sg.outputs.carrier }} (${{ steps.sg.outputs.asn }})"
```

The action also writes a small table with the IP, ASN and carrier to the job summary.

## Inputs

| Input | Default | Description |
|---|---|---|
| `proxy-url` | | Full proxy URL, `scheme://user:pass@host:port`. URL-encode special characters in the password. |
| `proxy-host`, `proxy-port`, `proxy-username`, `proxy-password` | | Used when `proxy-url` is empty. The password can contain any characters; the action encodes it. |
| `proxy-scheme` | `http` | `http`, `socks5` or `socks5h`, when building the URL from parts. |
| `rotate-url` | | Rotation link. When set, the action rotates before verifying. |
| `rotate-timeout` | `90` | Seconds to wait for the new IP after the link accepts the request. |
| `rotate-max-wait` | `300` | Longest `429 Retry-After` the action will sleep out. |
| `require-new-ip` | `false` | Fail if rotation returns the same IP. |
| `verify` | `true` | Check the egress IP, country and carrier through the proxy. |
| `allowed-carriers` | `singtel,m1` | Carriers the egress ASN must belong to: any of `singtel`, `m1`, `starhub`. |
| `ip-info-url` | `https://ipinfo.io/json` | IP lookup returning ipinfo-style JSON (`ip`, `country`, `org` = `"AS<n> <name>"`). |
| `export-env` | `true` | Export the proxy variables to later steps. |
| `no-proxy` | `localhost,127.0.0.1,::1` | Value for `NO_PROXY` / `no_proxy`. |

## Outputs

| Output | Example | Description |
|---|---|---|
| `ip` | `119.234.8.104` | Egress IP seen through the proxy. |
| `country` | `SG` | Country code of the egress IP. |
| `asn` | `AS45143` | Egress ASN. |
| `carrier` | `singtel` | `singtel`, `m1`, `starhub` or `unknown`. |
| `rotated` | `true` | `true` if a rotation changed the IP, `false` if not (or no rotation ran), `unknown` if the IP couldn't be read before rotating. |

## Which ASNs count as which carrier

A mobile carrier's data traffic often exits from a different ASN than the one registered for the
company. The action accepts both:

| Carrier | Mobile egress ASN (what an IP check shows) | Also accepted |
|---|---|---|
| Singtel | AS45143 SINGTELMOBILE | AS7473 |
| M1 | AS4773 MOBILEONELTD | AS17547 |
| StarHub | AS9874 STARHUB-MOBILE | AS4657, AS55430 |

StarHub isn't in the default `allowed-carriers` because Singapore Mobile Proxy only runs Singtel and
M1 SIMs. Add it if your provider uses StarHub.

## Getting a Singapore proxy

Any provider with a Singapore mobile endpoint works. Ours is
[Singapore Mobile Proxy](https://singaporemobileproxy.com/?utm_source=github&utm_medium=action): dedicated
ports on real modems with Singtel or M1 SIMs, HTTP and SOCKS5, and a rotation link per port. There's a
[free 24-hour, 10 GB trial](https://singaporemobileproxy.com/client/trial?utm_source=github&utm_medium=action)
that gives you a working port (host, HTTP and SOCKS5 ports, username, password and rotation link).
After that, plans start at $4 a day or $13 a week, or $40 a month for 200 GB. Each port allows
one rotation every 4 minutes. Save the values as repository secrets and pass
them in as shown above.

## Notes

- **Secrets and forks.** GitHub doesn't pass secrets to workflows triggered by pull requests from
  forks, so the inputs arrive empty and the action fails with a message saying so. Run proxied jobs
  on `push`, `schedule` or `workflow_dispatch`, or on PRs from branches in the same repo.
- **Runners.** It's a composite action using `bash` and `curl`, and is tested on `ubuntu-latest`,
  `macos-latest` and `windows-latest`. No `jq` needed.
- **Data use.** Everything after this step goes through the proxy, including package downloads. Put
  `setup-singapore-proxy` after `npm ci` / `pip install` to save proxy bandwidth, or clear the
  variables for steps that don't need it.
- **The IP lookup** goes to ipinfo.io through your proxy, one request per check. Point
  `ip-info-url` at your own service if you'd rather not.

## License

MIT
