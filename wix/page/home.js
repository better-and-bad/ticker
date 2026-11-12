// Home page code: renders the ticker strip from the Ticker collection.
// Editor setup: a repeater #tickerRepeater with these elements in each item:
//   #tickerLabel (text), #tickerValue (text), #tickerChange (text),
//   #tickerAsOf (text), #tickerDot (small circle box)

import wixData from 'wix-data';

const DOT = { better: '#10b981', bad: '#f97316', neutral: '#e8e0d0' };
const ARROW = { better: '▲ ', bad: '▼ ', neutral: '' }; // shape, not just color

$w.onReady(async function () {
  const { items } = await wixData.query('Ticker')
    .eq('showOnTicker', true)
    .ne('status', 'needs_review')
    .ascending('sortOrder')
    .find();

  if (items.length === 0) {
    $w('#tickerRepeater').collapse();
    return;
  }

  $w('#tickerRepeater').onItemReady(($item, d) => {
    $item('#tickerLabel').text = d.label;
    $item('#tickerValue').text = d.overrideDisplay || d.display;
    $item('#tickerChange').text = d.changeDisplay
      ? `${ARROW[d.tag] || ''}${d.changeDisplay} ${d.changeLabel}`
      : '';
    // Show the data period on every item; flag late data plainly
    $item('#tickerAsOf').text = d.status === 'stale'
      ? `${d.asOfLabel} · latest available · ${d.source}`
      : `${d.asOfLabel} · ${d.source}`;
    $item('#tickerDot').style.backgroundColor = DOT[d.tag] || DOT.neutral;
  });

  $w('#tickerRepeater').data = items;
});
