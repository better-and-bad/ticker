// backend/tickerSync.js
// Pulls ticker.json from GitHub and upserts it into the "Ticker" CMS collection.
// Runs on a schedule (see jobs.config). Safe to run any number of times.

import { fetch } from 'wix-fetch';
import wixData from 'wix-data';

const TICKER_URL = 'https://raw.githubusercontent.com/better-and-bad/ticker/main/ticker.json';
const COLLECTION = 'Ticker';
const OPTS = { suppressAuth: true }; // scheduled jobs run without a logged-in user

export async function syncTicker() {
  const res = await fetch(TICKER_URL, { method: 'get' });
  if (!res.ok) throw new Error(`ticker.json fetch failed: HTTP ${res.status}`);
  const { indicators } = await res.json();
  if (!Array.isArray(indicators) || indicators.length === 0) {
    throw new Error('ticker.json has no indicators; leaving CMS untouched');
  }

  const existing = await wixData.query(COLLECTION).limit(1000).find(OPTS);
  const byKey = new Map(existing.items.map((item) => [item.key, item]));

  for (const ind of indicators) {
    // Fields the pipeline owns: overwritten on every sync
    const synced = {
      key: ind.id,
      label: ind.label,
      display: ind.display,
      secondary: ind.secondary || '',
      changeDisplay: ind.change_display || '',
      changeLabel: ind.change_label || '',
      tag: ind.tag,
      asOfLabel: ind.as_of_label,
      status: ind.status,
      source: ind.source,
      sourceUrl: ind.source_url,
      note: ind.note,
      lastSynced: new Date(),
    };

    const old = byKey.get(ind.id);
    if (old) {
      // showOnTicker, sortOrder and overrideDisplay belong to you in the CMS;
      // the sync never touches them after the first insert.
      await wixData.update(COLLECTION, { ...old, ...synced }, OPTS);
    } else {
      await wixData.insert(COLLECTION, {
        ...synced,
        showOnTicker: ind.on_ticker,
        sortOrder: ind.sort,
        overrideDisplay: '',
      }, OPTS);
    }
  }
  return { synced: indicators.length };
}
