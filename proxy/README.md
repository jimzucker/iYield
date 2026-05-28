# TrueYield CORS proxy

The web build (GitHub Pages) calls Yahoo Finance from the browser, but Yahoo's
chart endpoint sends no `Access-Control-Allow-Origin` header, so the browser
blocks the response. This folder is a tiny [Cloudflare Worker](https://workers.cloudflare.com/)
that forwards the request and adds the CORS headers. Native (iOS/Android/desktop)
builds are unaffected — they call Yahoo directly and never use the proxy.

It proxies only `GET /v8/finance/chart/*`; everything else is rejected.

## Deploy (one time)

1. Install Wrangler and sign in to Cloudflare (free plan is fine):

   ```sh
   npm install -g wrangler
   wrangler login
   ```

2. Deploy from this folder:

   ```sh
   cd proxy
   wrangler deploy
   ```

   Wrangler prints the URL, e.g. `https://trueyield-proxy.<subdomain>.workers.dev`.

3. Tell the web build to use it. In the GitHub repo:
   **Settings → Secrets and variables → Actions → Variables → New repository
   variable**

   - **Name:** `YAHOO_PROXY`
   - **Value:** the worker URL from step 2, **no trailing slash**

4. Re-run the **Deploy to GitHub Pages** workflow (Actions tab, or push to
   `main`). The build passes `--dart-define=YAHOO_PROXY=...`, and the live demo
   will fetch data through the worker.

## How it's wired

- `lib/main.dart` reads `YAHOO_PROXY` via `String.fromEnvironment` and, **only on
  web**, prefixes the Yahoo path with it (`yahooBase`). With the variable unset,
  the web build still loads but live lookups stay CORS-blocked.
- `.github/workflows/pages.yml` forwards the repo variable into the build with
  `--dart-define=YAHOO_PROXY=${{ vars.YAHOO_PROXY }}`.

## Notes

- The worker is stateless and adds a 60s cache; Cloudflare's free tier covers
  far more than a demo needs.
- To lock it down, replace `Access-Control-Allow-Origin: *` in `worker.js` with
  your Pages origin (`https://<user>.github.io`).
