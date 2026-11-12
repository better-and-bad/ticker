#!/usr/bin/env Rscript
# =====================================================================
# better&bad ticker pipeline
# Pulls each ticker indicator, computes the headline number + change,
# runs sanity checks, and writes ticker.json for the Wix site to read.
#
# Sources: FRED (key required), CDC data.cdc.gov, World Bank (no keys).
# Secrets: FRED_API_KEY must be set as an environment variable.
#          Never hard-code keys in this file — the repo is public.
# =====================================================================

suppressPackageStartupMessages({
  library(fredr)
  library(httr2)
  library(jsonlite)
  library(dplyr)
})

OUT <- "ticker.json"

fred_key <- Sys.getenv("FRED_API_KEY")
if (fred_key == "") stop("FRED_API_KEY is not set")
fredr_set_key(fred_key)

now_utc <- format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")

# ---------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------

# Pull a FRED series, drop missing values, oldest -> newest
fred <- function(id, years_back = 4) {
  fredr(series_id = id, observation_start = Sys.Date() - 365 * years_back) |>
    filter(!is.na(value)) |>
    arrange(date) |>
    select(date, value)
}

# Last value on or before a given date (handles daily/weekly gaps)
at_or_before <- function(df, d) {
  x <- df[df$date <= d, ]
  if (nrow(x) == 0) NA_real_ else x$value[nrow(x)]
}

minus_years <- function(d, k) seq(d, length.out = 2, by = paste0("-", k, " year"))[2]

latest <- function(df) df[nrow(df), ]

# World Bank indicator for a country/aggregate (e.g. "WLD", "USA")
wb <- function(country, indicator) {
  url <- sprintf("https://api.worldbank.org/v2/country/%s/indicator/%s", country, indicator)
  j <- request(url) |>
    req_url_query(format = "json", per_page = 200) |>
    req_retry(max_tries = 3) |>
    req_perform() |>
    resp_body_json(simplifyVector = TRUE)
  df <- j[[2]]
  data.frame(year = as.integer(df$date), value = as.numeric(df$value)) |>
    filter(!is.na(value)) |>
    arrange(year)
}

# Annual series: latest value vs. the value ~10 years earlier
annual_vs_decade <- function(df, years = 10) {
  last <- latest(df)
  base <- df[df$year <= last$year - years, ]
  base_val <- if (nrow(base)) base$value[nrow(base)] else NA_real_
  base_yr  <- if (nrow(base)) base$year[nrow(base)] else NA_integer_
  list(value = last$value, base = base_val, base_year = base_yr,
       as_of = as.Date(paste0(last$year, "-01-01")), year = last$year)
}

# ---------------------------------------------------------------------
# Formatting
# ---------------------------------------------------------------------

signed <- function(x, digits = 1) {
  x <- round(x, digits)  # so -0.003 prints as "0.0", not "-0.0"
  s <- formatC(abs(x), format = "f", digits = digits, big.mark = ",")
  paste0(if (x > 0) "+" else if (x < 0) "-" else "", s)
}

fmt_value <- function(x, type) {
  if (is.na(x)) return(NA_character_)
  switch(type,
    pct1        = sprintf("%.1f%%", x),
    pct1_signed = paste0(signed(x), "%"),
    rate2       = sprintf("%.2f%%", x),
    index1      = sprintf("%.1f", x),
    millions_k  = sprintf("%.1fM", x / 1000),          # input in thousands
    trillions_b = sprintf("$%.1fT", x / 1000),         # input in billions
    usd         = sprintf("$%.0f", x),
    usd_k       = sprintf("$%.1fk", x / 1000),
    count       = formatC(round(x, -2), format = "d", big.mark = ","),
    per1000     = sprintf("%.1f per 1,000", x),
    years       = sprintf("%.1f yrs", x),
    stop("unknown value format: ", type))
}

fmt_change <- function(x, type) {
  if (is.na(x)) return(NA_character_)
  switch(type,
    pts     = paste0(signed(x), " pts"),
    pts2    = paste0(signed(x, 2), " pts"),
    pct     = paste0(signed(x), "%"),
    count_k = paste0(signed(x, 0), "k"),
    years   = paste0(signed(x), " yrs"),
    stop("unknown change format: ", type))
}

period_label <- function(d, freq) {
  switch(freq,
    monthly   = format(d, "%b %Y"),
    quarterly = paste0("Q", (as.integer(format(d, "%m")) - 1) %/% 3 + 1, " ", format(d, "%Y")),
    annual    = format(d, "%Y"),
    weekly    = ,
    daily     = paste0(format(d, "%b "), as.integer(format(d, "%d")), ", ", format(d, "%Y")))
}

# ---------------------------------------------------------------------
# Indicator specs
#   good_direction: "up" / "down" / NA (neutral — no better/bad tag)
#   better_basis:   "change" (did it move the right way?) or
#                   "value"  (is the number itself positive? e.g. GDP growth)
#   max_jump:       largest believable move in `value` between runs;
#                   bigger moves are held for review instead of published
#   stale_days:     days after the as-of date before the item is flagged stale
#   on_ticker:      default visibility; Wix can override per item
# Each fetch() returns list(value, change, as_of, [display], [secondary])
# ---------------------------------------------------------------------

specs <- list(

  # ---------------- Work ----------------
  list(
    id = "unemployment", label = "Unemployment rate", group = "economy",
    frequency = "monthly", value_fmt = "pct1", change_fmt = "pts",
    change_label = "vs. last month", good_direction = "down", better_basis = "change",
    max_jump = 1.5, stale_days = 75, on_ticker = TRUE,
    source = "BLS via FRED", series = "UNRATE",
    source_url = "https://fred.stlouisfed.org/series/UNRATE",
    note = "Doesn't count people who gave up looking for work.",
    fetch = function() {
      d <- fred("UNRATE"); n <- nrow(d)
      list(value = d$value[n], change = d$value[n] - d$value[n - 1], as_of = d$date[n])
    }),

  list(
    id = "prime_age_epop", label = "Prime-age (25-54) adults working", group = "economy",
    frequency = "monthly", value_fmt = "pct1", change_fmt = "pts",
    change_label = "vs. a year ago", good_direction = "up", better_basis = "change",
    max_jump = 1.5, stale_days = 75, on_ticker = TRUE,
    source = "BLS via FRED", series = "LNS12300060",
    source_url = "https://fred.stlouisfed.org/series/LNS12300060",
    note = "Says nothing about pay or hours, just whether people have a job.",
    fetch = function() {
      d <- fred("LNS12300060"); l <- latest(d)
      list(value = l$value, change = l$value - at_or_before(d, minus_years(l$date, 1)),
           as_of = l$date)
    }),

  list(
    id = "payrolls", label = "Jobs in the US", group = "economy",
    frequency = "monthly", value_fmt = "millions_k", change_fmt = "count_k",
    change_label = "added last month", good_direction = "up", better_basis = "change",
    max_jump = 3000, stale_days = 75, on_ticker = FALSE,
    source = "BLS via FRED", series = "PAYEMS",
    source_url = "https://fred.stlouisfed.org/series/PAYEMS",
    note = "First prints get revised, sometimes by a lot.",
    fetch = function() {
      d <- fred("PAYEMS"); n <- nrow(d)
      list(value = d$value[n], change = d$value[n] - d$value[n - 1], as_of = d$date[n])
    }),

  list(
    id = "participation", label = "Labor force participation", group = "economy",
    frequency = "monthly", value_fmt = "pct1", change_fmt = "pts",
    change_label = "vs. a year ago", good_direction = "up", better_basis = "change",
    max_jump = 1.5, stale_days = 75, on_ticker = FALSE,
    source = "BLS via FRED", series = "CIVPART",
    source_url = "https://fred.stlouisfed.org/series/CIVPART",
    note = "Falls as boomers retire, even when the job market is strong.",
    fetch = function() {
      d <- fred("CIVPART"); l <- latest(d)
      list(value = l$value, change = l$value - at_or_before(d, minus_years(l$date, 1)),
           as_of = l$date)
    }),

  # ---------------- Pay & prices ----------------
  list(
    id = "real_wages", label = "Median full-time pay", group = "economy",
    frequency = "quarterly", value_fmt = "usd_k", change_fmt = "pct",
    change_label = "after inflation, vs. a year ago", good_direction = "up", better_basis = "change",
    max_jump = 8000, stale_days = 200, on_ticker = TRUE,
    source = "BLS via FRED (deflated with chained CPI)", series = "LES1252881500Q, SUUR0000SA0",
    source_url = "https://fred.stlouisfed.org/series/LES1252881500Q",
    note = "Full-time wage and salary workers only; leaves out benefits and part-timers.",
    fetch = function() {
      # Nominal median weekly earnings (quarterly)
      w <- fred("LES1252881500Q")
      # Chained CPI (monthly) -> quarterly average, complete quarters only.
      # Chained CPI starts Dec 1999, so the PCE splice from the original
      # script is only needed for long-history charts, not the ticker.
      p <- fred("SUUR0000SA0") |>
        mutate(q = as.Date(cut(date, "quarter"))) |>
        group_by(q) |>
        summarise(price = mean(value), months = n(), .groups = "drop") |>
        filter(months == 3) |>
        rename(date = q)
      d <- inner_join(w, p, by = "date") |> arrange(date)
      l <- latest(d)
      prior <- d[d$date == minus_years(l$date, 1), ]
      real_yoy <- if (nrow(prior)) ((l$value / prior$value) / (l$price / prior$price) - 1) * 100 else NA_real_
      list(value = l$value * 52, change = real_yoy, as_of = l$date)
    }),

  list(
    id = "cpi", label = "Inflation (CPI)", group = "economy",
    frequency = "monthly", value_fmt = "pct1", change_fmt = "pts",
    change_label = "vs. last month's rate", good_direction = "down", better_basis = "change",
    max_jump = 2, stale_days = 75, on_ticker = TRUE,
    source = "BLS via FRED", series = "CPIAUCSL",
    source_url = "https://fred.stlouisfed.org/series/CPIAUCSL",
    note = "Year-over-year change in prices. An average; your basket may differ.",
    fetch = function() {
      d <- fred("CPIAUCSL") |> mutate(yoy = (value / lag(value, 12) - 1) * 100) |>
        filter(!is.na(yoy))
      n <- nrow(d)
      list(value = d$yoy[n], change = d$yoy[n] - d$yoy[n - 1], as_of = d$date[n])
    }),

  list(
    id = "shelter", label = "Rent & housing costs (CPI shelter)", group = "economy",
    frequency = "monthly", value_fmt = "pct1", change_fmt = "pts",
    change_label = "vs. last month's rate", good_direction = "down", better_basis = "change",
    max_jump = 2, stale_days = 75, on_ticker = FALSE,
    source = "BLS via FRED", series = "CUSR0000SAH1",
    source_url = "https://fred.stlouisfed.org/series/CUSR0000SAH1",
    note = "Lags market rents by about a year because existing leases reset slowly.",
    fetch = function() {
      d <- fred("CUSR0000SAH1") |> mutate(yoy = (value / lag(value, 12) - 1) * 100) |>
        filter(!is.na(yoy))
      n <- nrow(d)
      list(value = d$yoy[n], change = d$yoy[n] - d$yoy[n - 1], as_of = d$date[n])
    }),

  list(
    id = "mortgage", label = "30-year mortgage rate", group = "economy",
    frequency = "weekly", value_fmt = "rate2", change_fmt = "pts2",
    change_label = "vs. a year ago", good_direction = "down", better_basis = "change",
    max_jump = 1, stale_days = 21, on_ticker = TRUE,
    source = "Freddie Mac via FRED", series = "MORTGAGE30US",
    source_url = "https://fred.stlouisfed.org/series/MORTGAGE30US",
    note = "Rate on new loans; most owners are locked into older, lower rates.",
    fetch = function() {
      d <- fred("MORTGAGE30US"); l <- latest(d)
      list(value = l$value, change = l$value - at_or_before(d, l$date - 365), as_of = l$date)
    }),

  # ---------------- Growth & money ----------------
  list(
    id = "real_gdp", label = "Economic growth (real GDP)", group = "economy",
    frequency = "quarterly", value_fmt = "pct1_signed", change_fmt = "pts",
    change_label = "vs. last quarter's pace", good_direction = "up", better_basis = "value",
    max_jump = 15, stale_days = 200, on_ticker = FALSE,
    source = "BEA via FRED", series = "GDPC1",
    source_url = "https://fred.stlouisfed.org/series/GDPC1",
    note = "Annualized pace. Measures output, not who gets it.",
    fetch = function() {
      d <- fred("GDPC1") |> mutate(ann = ((value / lag(value))^4 - 1) * 100) |>
        filter(!is.na(ann))
      n <- nrow(d)
      list(value = d$ann[n], change = d$ann[n] - d$ann[n - 1], as_of = d$date[n])
    }),

  list(
    id = "fed_funds", label = "Fed interest rate target", group = "economy",
    frequency = "daily", value_fmt = "rate2", change_fmt = "pts2",
    change_label = "vs. a year ago", good_direction = NA, better_basis = "change",
    max_jump = 1, stale_days = 10, on_ticker = FALSE,
    source = "Federal Reserve via FRED", series = "DFEDTARL, DFEDTARU",
    source_url = "https://fred.stlouisfed.org/series/DFEDTARU",
    note = "Neither good nor bad on its own; depends on inflation and jobs.",
    fetch = function() {
      up <- fred("DFEDTARU", 2); lo <- fred("DFEDTARL", 2); l <- latest(up)
      lo_now <- at_or_before(lo, l$date)
      list(value = l$value, change = l$value - at_or_before(up, l$date - 365), as_of = l$date,
           display = sprintf("%.2f-%.2f%%", lo_now, l$value))
    }),

  list(
    id = "m2", label = "Money supply (M2)", group = "economy",
    frequency = "monthly", value_fmt = "trillions_b", change_fmt = "pct",
    change_label = "vs. a year ago", good_direction = NA, better_basis = "change",
    max_jump = 2000, stale_days = 75, on_ticker = FALSE,
    source = "Federal Reserve via FRED", series = "M2SL",
    source_url = "https://fred.stlouisfed.org/series/M2SL",
    note = "Its link to inflation is loose outside of big shocks.",
    fetch = function() {
      d <- fred("M2SL"); l <- latest(d)
      list(value = l$value,
           change = (l$value / at_or_before(d, minus_years(l$date, 1)) - 1) * 100,
           as_of = l$date)
    }),

  list(
    id = "oil", label = "Oil (Brent, per barrel)", group = "economy",
    frequency = "daily", value_fmt = "usd", change_fmt = "pct",
    change_label = "vs. 30 days ago", good_direction = NA, better_basis = "change",
    max_jump = 40, stale_days = 14, on_ticker = FALSE,
    source = "EIA via FRED", series = "DCOILBRENTEU",
    source_url = "https://fred.stlouisfed.org/series/DCOILBRENTEU",
    note = "Cheap oil helps drivers and hurts producers.",
    fetch = function() {
      # Fixed: compare to 30 calendar days ago, not 30 rows (~6 trading weeks)
      d <- fred("DCOILBRENTEU", 2); l <- latest(d)
      list(value = l$value, change = (l$value / at_or_before(d, l$date - 30) - 1) * 100,
           as_of = l$date)
    }),

  list(
    id = "sentiment", label = "Consumer sentiment", group = "economy",
    frequency = "monthly", value_fmt = "index1", change_fmt = "pts",
    change_label = "vs. a year ago", good_direction = "up", better_basis = "change",
    max_jump = 20, stale_days = 75, on_ticker = FALSE,
    source = "University of Michigan via FRED", series = "UMCSENT",
    source_url = "https://fred.stlouisfed.org/series/UMCSENT",
    note = "How people feel, which often splits from how the data look.",
    fetch = function() {
      d <- fred("UMCSENT"); l <- latest(d)
      list(value = l$value, change = l$value - at_or_before(d, minus_years(l$date, 1)),
           as_of = l$date)
    }),

  # ---------------- People ----------------
  list(
    id = "overdose_deaths", label = "Overdose deaths (past 12 months)", group = "social",
    frequency = "monthly", value_fmt = "count", change_fmt = "pct",
    change_label = "vs. a year earlier", good_direction = "down", better_basis = "change",
    max_jump = 20000, stale_days = 210, on_ticker = TRUE,
    source = "CDC NCHS provisional counts", series = "VSRR xkb8-kh2a (predicted)",
    source_url = "https://www.cdc.gov/nchs/nvss/vsrr/drug-overdose-data.htm",
    note = "Provisional, adjusted for reporting delays; recent months get revised.",
    fetch = function() {
      raw <- request("https://data.cdc.gov/resource/xkb8-kh2a.json") |>
        req_url_query(state = "US", indicator = "Number of Drug Overdose Deaths",
                      `$limit` = 5000) |>
        req_retry(max_tries = 3) |>
        req_perform() |>
        resp_body_json(simplifyVector = TRUE)
      val <- suppressWarnings(as.numeric(raw$predicted_value))
      fallback <- suppressWarnings(as.numeric(raw$data_value))
      val[is.na(val)] <- fallback[is.na(val)]
      d <- data.frame(
        date = as.Date(paste(raw$year, match(raw$month, month.name), 1, sep = "-")),
        value = val) |>
        filter(!is.na(date), !is.na(value)) |>
        distinct(date, .keep_all = TRUE) |>
        arrange(date)
      l <- latest(d)
      list(value = l$value,
           change = (l$value / at_or_before(d, minus_years(l$date, 1)) - 1) * 100,
           as_of = l$date)
    }),

  list(
    id = "extreme_poverty", label = "World in extreme poverty", group = "social",
    frequency = "annual", value_fmt = "pct1", change_fmt = "pts",
    change_label = "in 10 years", good_direction = "down", better_basis = "change",
    max_jump = 5, stale_days = 365 * 4, on_ticker = TRUE,
    source = "World Bank (international poverty line)", series = "SI.POV.DDAY",
    source_url = "https://data.worldbank.org/indicator/SI.POV.DDAY",
    note = "Survey-based estimates; the line itself is extremely low.",
    fetch = function() {
      p <- wb("WLD", "SI.POV.DDAY"); a <- annual_vs_decade(p)
      pop <- wb("WLD", "SP.POP.TOTL")
      pop_yr <- pop$value[pop$year == a$year]
      people <- if (length(pop_yr)) a$value / 100 * pop_yr else NA_real_
      list(value = a$value, change = a$value - a$base, as_of = a$as_of,
           secondary = if (!is.na(people)) sprintf("%.0fM people still", people / 1e6) else NA_character_)
    }),

  list(
    id = "child_mortality", label = "Kids who die before age 5 (world)", group = "social",
    frequency = "annual", value_fmt = "per1000", change_fmt = "pct",
    change_label = "in 10 years", good_direction = "down", better_basis = "change",
    max_jump = 10, stale_days = 365 * 3, on_ticker = TRUE,
    source = "UN IGME via World Bank", series = "SH.DYN.MORT",
    source_url = "https://data.worldbank.org/indicator/SH.DYN.MORT",
    note = "A global average; rates are many times higher in the poorest countries.",
    fetch = function() {
      a <- annual_vs_decade(wb("WLD", "SH.DYN.MORT"))
      list(value = a$value, change = (a$value / a$base - 1) * 100, as_of = a$as_of)
    }),

  list(
    id = "us_life_expectancy", label = "US life expectancy", group = "social",
    frequency = "annual", value_fmt = "years", change_fmt = "years",
    change_label = "in 10 years", good_direction = "up", better_basis = "change",
    max_jump = 3, stale_days = 365 * 3, on_ticker = FALSE,
    source = "World Bank (from CDC/UN data)", series = "SP.DYN.LE00.IN",
    source_url = "https://data.worldbank.org/indicator/SP.DYN.LE00.IN?locations=US",
    note = "Lifespan at birth; hides big gaps by income and region.",
    fetch = function() {
      a <- annual_vs_decade(wb("USA", "SP.DYN.LE00.IN"))
      list(value = a$value, change = a$value - a$base, as_of = a$as_of)
    })
)

# ---------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------

prev <- if (file.exists(OUT)) fromJSON(OUT, simplifyVector = FALSE)$indicators else list()
prev_by_id <- setNames(prev, vapply(prev, function(p) p$id, character(1)))

is_better <- function(spec, value, change) {
  if (is.na(spec$good_direction)) return(NA)
  x <- if (spec$better_basis == "value") value else change
  # Judge on the rounded number people see, so "0.0 yrs" is neutral, not "better"
  digits <- switch(spec$change_fmt, pts2 = 2, count_k = 0, 1)
  if (spec$better_basis == "change" && !is.na(x)) x <- round(x, digits)
  if (is.na(x) || x == 0) return(NA)
  (x > 0) == (spec$good_direction == "up")
}

build_one <- function(spec, sort_order) {
  old <- prev_by_id[[spec$id]]

  res <- tryCatch(spec$fetch(), error = function(e) {
    message(sprintf("  [%s] fetch failed: %s", spec$id, conditionMessage(e)))
    NULL
  })

  # Fetch failed -> keep last good entry, mark held
  if (is.null(res) || is.null(res$value) || is.na(res$value)) {
    if (is.null(old)) return(NULL)
    old$status <- "held"
    return(old)
  }

  # Sanity check: implausible jump vs. last published value -> hold for review
  if (!is.null(old) && !is.null(old$value) &&
      abs(res$value - old$value) > spec$max_jump) {
    message(sprintf("  [%s] jump %.2f -> %.2f exceeds max_jump; holding",
                    spec$id, old$value, res$value))
    old$status <- "needs_review"
    return(old)
  }

  age_days <- as.numeric(Sys.Date() - res$as_of)
  stale <- age_days > spec$stale_days

  display <- if (!is.null(res$display)) res$display else fmt_value(res$value, spec$value_fmt)
  better <- is_better(spec, res$value, res$change)

  # (JSON reads whole numbers back as integers, so compare numerically)
  changed <- is.null(old) || is.null(old$value) ||
    abs(round(res$value, 3) - as.numeric(old$value)) > 1e-9 ||
    !identical(format(res$as_of), old$as_of)

  list(
    id             = spec$id,
    label          = spec$label,
    group          = spec$group,
    value          = round(res$value, 3),
    display        = display,
    secondary      = if (!is.null(res$secondary)) res$secondary else NA_character_,
    change         = if (is.na(res$change)) NA_real_ else round(res$change, 3),
    change_display = fmt_change(res$change, spec$change_fmt),
    change_label   = spec$change_label,
    is_better      = better,
    tag            = if (is.na(better)) "neutral" else if (better) "better" else "bad",
    as_of          = format(res$as_of),
    as_of_label    = period_label(res$as_of, spec$frequency),
    frequency      = spec$frequency,
    status         = if (stale) "stale" else "ok",
    last_updated   = if (changed) now_utc else old$last_updated,
    source         = spec$source,
    source_url     = spec$source_url,
    series         = spec$series,
    note           = spec$note,
    on_ticker      = spec$on_ticker,
    sort           = sort_order
  )
}

message("Building ticker...")
items <- Filter(Negate(is.null), Map(build_one, specs, seq_along(specs)))
n_ok <- sum(vapply(items, function(i) i$status %in% c("ok", "stale"), logical(1)))
message(sprintf("%d of %d indicators fresh", n_ok, length(specs)))

if (n_ok == 0) stop("Every fetch failed; leaving ticker.json untouched")

to_json <- function(x) toJSON(x, auto_unbox = TRUE, na = "null", null = "null",
                              digits = NA, pretty = TRUE)

# Only rewrite the file when the data actually changed, so the git
# history stays a clean log of real number changes.
if (length(prev) && identical(as.character(to_json(prev)), as.character(to_json(items)))) {
  message("No changes; ticker.json left as is")
} else {
  writeLines(to_json(list(generated_at = now_utc, indicators = items)), OUT, useBytes = TRUE)
  message("Wrote ", OUT)
}
