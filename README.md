# better&bad ticker

The live numbers behind the ticker strip on [betterandbad.com](https://www.betterandbad.com).

Every weekday morning a GitHub Action runs `R/build_ticker.R`. It pulls each indicator from its public source, computes the headline number and its change, sanity-checks it, and writes [`ticker.json`](ticker.json). The site reads that file. A commit only happens when a number actually changes, so **this repo's history is a public log of every ticker update.**

## Sources

| Indicator | Source | Series | Updates | Change shown |
|---|---|---|---|---|
| Unemployment rate | BLS via FRED | `UNRATE` | Monthly | pts vs. last month |
| Prime-age (25-54) adults working | BLS via FRED | `LNS12300060` | Monthly | pts vs. a year ago |
| Jobs in the US | BLS via FRED | `PAYEMS` | Monthly | jobs added last month |
| Labor force participation | BLS via FRED | `CIVPART` | Monthly | pts vs. a year ago |
| Median full-time pay | BLS via FRED, deflated with chained CPI | `LES1252881500Q`, `SUUR0000SA0` | Quarterly | real % vs. a year ago |
| Inflation (CPI) | BLS via FRED | `CPIAUCSL` | Monthly | pts vs. last month's rate |
| Rent & housing costs | BLS via FRED | `CUSR0000SAH1` | Monthly | pts vs. last month's rate |
| 30-year mortgage rate | Freddie Mac via FRED | `MORTGAGE30US` | Weekly | pts vs. a year ago |
| Economic growth (real GDP) | BEA via FRED | `GDPC1` | Quarterly | pts vs. last quarter's pace |
| Fed interest rate target | Federal Reserve via FRED | `DFEDTARL`, `DFEDTARU` | Daily | pts vs. a year ago |
| Money supply (M2) | Federal Reserve via FRED | `M2SL` | Monthly | % vs. a year ago |
| Oil (Brent) | EIA via FRED | `DCOILBRENTEU` | Daily | % vs. 30 days ago |
| Consumer sentiment | U. Michigan via FRED | `UMCSENT` | Monthly | pts vs. a year ago |
| Overdose deaths (12 months) | CDC NCHS provisional counts | data.cdc.gov `xkb8-kh2a` | Monthly | % vs. a year earlier |
| World in extreme poverty | World Bank | `SI.POV.DDAY` | Annual | pts in 10 years |
| Kids who die before 5 (world) | UN IGME via World Bank | `SH.DYN.MORT` | Annual | % in 10 years |
| US life expectancy | World Bank | `SP.DYN.LE00.IN` | Annual | yrs in 10 years |

Each indicator also carries a one-line note on what the number doesn't show.

## `ticker.json` fields

| Field | Example | What it's for |
|---|---|---|
| `id` | `"cpi"` | Stable key. Wix matches rows on this |
| `label` | `"Inflation (CPI)"` | Display name |
| `group` | `"economy"` / `"social"` | For grouping or filtering |
| `value` | `2.34` | Raw number |
| `display` | `"2.3%"` | Formatted headline, ready to show |
| `secondary` | `"829M people still"` | Optional second line (the "still bad" half of a pair) |
| `change`, `change_display` | `-0.2`, `"-0.2 pts"` | Raw and formatted change |
| `change_label` | `"vs. last month's rate"` | What the change is compared to |
| `tag` | `"better"` / `"bad"` / `"neutral"` | Did it move the right way? Neutral for rates and prices with no clear good direction |
| `as_of`, `as_of_label` | `"2026-10-01"`, `"Oct 2026"` | The period the data covers, not the day it was fetched |
| `frequency` | `"monthly"` | How often the source updates |
| `status` | `"ok"` | `ok`, `stale` (source is late), `held` (fetch failed, last good value kept), or `needs_review` (implausible jump, last good value kept) |
| `last_updated` | ISO timestamp | When this number last changed |
| `source`, `source_url`, `series` | | Source stamp and link |
| `note` | | What the number doesn't show |
| `on_ticker` | `true` | Default visibility. Override per item in the Wix CMS |
| `sort` | `6` | Default order |

## Guardrails

- **No secrets in code.** The only key is `FRED_API_KEY`, stored as a GitHub Actions secret. CDC and World Bank need no key.
- **Failures don't blank the ticker.** If a source is down, the last good value stays up, marked `held`.
- **Implausible jumps are held.** Each indicator has a `max_jump`. A bigger move between runs keeps the old value and flags `needs_review`, so a bad API response never goes live. If a real move trips this, raise `max_jump` for that indicator or override the value in Wix.
- **Stale data is flagged.** Each indicator has a `stale_days` window measured from its as-of date.

## Setup

1. Get a free FRED API key at <https://fred.stlouisfed.org/docs/api/api_key.html>.
2. In this repo, go to **Settings → Secrets and variables → Actions → New repository secret**. Name it `FRED_API_KEY` and paste the key.
3. Go to **Actions → Update ticker → Run workflow** for the first run. After that it runs on its own every weekday.

To run it locally: `Sys.setenv(FRED_API_KEY = "...")`, then `source("R/build_ticker.R")`, starting in the repo root.

## Adding an indicator

Add one entry to `specs` in `R/build_ticker.R`: id, label, formats, good direction, `max_jump`, `stale_days`, source, note, and a `fetch()` function that returns `list(value, change, as_of)`.
