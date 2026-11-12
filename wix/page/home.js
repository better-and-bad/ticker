// Home page code: sends the Ticker CMS rows to the ticker HTML embed (#tickerEmbed).
// The embed (wix/embed/ticker-embed.html) renders them as the scrolling strip.

import wixData from 'wix-data';

let items = [];

$w.onReady(async function () {
  const embed = $w('#tickerEmbed');

  // The embed says "ticker-ready" once loaded; answer with the data
  embed.onMessage((event) => {
    if (event.data === 'ticker-ready' && items.length) embed.postMessage({ ticker: items });
  });

  const { items: rows } = await wixData.query('Ticker')
    .eq('showOnTicker', true)
    .ne('status', 'needs_review')
    .ascending('sortOrder')
    .find();

  items = rows.map((d) => ({
    label: d.label,
    display: d.overrideDisplay || d.display,
    secondary: d.secondary,
    change: d.changeDisplay,
    changeLabel: d.changeLabel,
    tag: d.tag,
    asOf: d.asOfLabel,
    source: d.source,
    url: d.sourceUrl,
    status: d.status,
  }));

  embed.postMessage({ ticker: items });
});
