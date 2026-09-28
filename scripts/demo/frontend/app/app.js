const revenue = await fetch('./revenue.json').then(response => response.json());
const total = row => row.direct + row.partners + row.organic;
const money = amount => '$' + Math.round(amount / 1000) + 'k';
let half = 'H1';

document.querySelector('#app').innerHTML = `
  <aside class="sidebar"><a class="brand" href="#overview"><span>h</span> harbor</a><div class="nav-label">WORKSPACE</div><nav aria-label="Main navigation"><a href="#overview">Overview</a><a class="active" href="#revenue">Revenue</a><a href="#customers">Customers</a><a href="#reports">Reports</a></nav><div class="sidebar-footer">Demo workspace<br><small>Growth team</small></div></aside>
  <main><header class="page-header"><div><p class="breadcrumb">Analytics / Revenue</p><h1>Revenue overview</h1><p>See what drives your growth.</p></div><button id="refresh" class="button">↻ Refresh</button></header>
  <section class="metrics" aria-label="Business summary"><article><span>Total customers</span><strong>1,248</strong><small>↑ 18% this year</small></article><article><span>Net retention</span><strong>112%</strong><small>↑ 6 pts this year</small></article><article><span>Active markets</span><strong>24</strong><small>Across 3 regions</small></article></section>
  <section id="revenue-panel" class="revenue-panel" aria-labelledby="revenue-title"><div class="panel-heading"><div><p class="eyebrow">PERFORMANCE</p><h2 id="revenue-title">Monthly revenue</h2><p class="subtitle">Direct, Partners and Organic · 2026</p></div><div class="period-control" aria-label="Revenue period"><button data-half="H1" aria-pressed="true">Jan–Jun</button><button data-half="H2" aria-pressed="false">Jul–Dec</button></div></div><div id="revenue-chart" class="chart-host"></div><footer class="panel-footer"><span id="period-total"></span><a href="./revenue.json" download>Download data ↗</a></footer></section>
  <section class="insight"><span class="insight-icon">↗</span><div><h2>Growth, in focus</h2><p>Track channel performance and spot changes over time.</p></div><span class="live-dot"></span><small>Updated just now</small></section>
  <div id="tooltip" class="tooltip" role="status" hidden></div></main>`;

function render() {
  const rows = revenue.slice(half === 'H1' ? 0 : 6, half === 'H1' ? 6 : 12);
  const max = Math.ceil(Math.max(...rows.map(total)) / 25000) * 25000;
  const x0 = 64, y0 = 25, width = 690, height = 300, step = width / rows.length;
  const axis = [0, .25, .5, .75, 1].map(ratio => {
    const y = y0 + height * (1 - ratio);
    return `<line class="gridline" x1="${x0}" x2="${x0 + width}" y1="${y}" y2="${y}"/><text class="tick" x="${x0 - 13}" y="${y + 5}" text-anchor="end">${money(max * ratio)}</text>`;
  }).join('');
  const bars = rows.map((row, index) => {
    const amount = total(row), h = amount / max * height, x = x0 + index * step + 28, y = y0 + height - h;
    const label = `${row.month}: ${money(amount)} total revenue. Direct ${money(row.direct)}, Partners ${money(row.partners)}, Organic ${money(row.organic)}.`;
    return `<g class="month-mark" tabindex="0" role="img" aria-label="${label}" data-month="${row.month}" data-total="${amount}"><rect class="revenue-bar" x="${x}" y="${y}" width="58" height="${h}" rx="5"/><text class="bar-value" x="${x+29}" y="${y-10}" text-anchor="middle">${money(amount)}</text><text class="month-label" x="${x+29}" y="${y0+height+30}" text-anchor="middle">${row.month}</text></g>`;
  }).join('');
  document.querySelector('#revenue-chart').innerHTML = `<svg viewBox="0 0 790 380" role="group" aria-label="Monthly revenue chart">${axis}${bars}</svg>`;
  document.querySelector('#period-total').textContent = `${half === 'H1' ? 'Jan–Jun' : 'Jul–Dec'} total: ${money(rows.reduce((sum,row) => sum + total(row), 0))}`;
  document.querySelectorAll('[data-half]').forEach(button => button.setAttribute('aria-pressed', String(button.dataset.half === half)));
  document.querySelectorAll('.month-mark').forEach(mark => {
    const show = () => { const tip = document.querySelector('#tooltip'); tip.textContent = mark.getAttribute('aria-label'); tip.hidden = false; };
    mark.addEventListener('pointerenter', show); mark.addEventListener('focus', show);
    mark.addEventListener('pointerleave', () => document.querySelector('#tooltip').hidden = true);
    mark.addEventListener('blur', () => document.querySelector('#tooltip').hidden = true);
  });
}

document.querySelectorAll('[data-half]').forEach(button => button.addEventListener('click', () => { half = button.dataset.half; render(); }));
document.querySelector('#refresh').addEventListener('click', render);
render();
