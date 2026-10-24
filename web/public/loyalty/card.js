// Customer's read-only loyalty card. Data comes only from the server; this page computes nothing.
(function () {
  // Stamp circle centres and the "Name:" line on each card image (pixels of the original artwork) —
  // the same table the mobile app uses (mobile/lib/widgets/loyalty_card_view.dart).
  var ART = {
    STANDARD: { img: 'standard.jpg', w: 1004, h: 648, xs: [167, 330, 495, 660, 830], ys: [330, 455], r: 58, name: [192, 238, 925], stamp: '#1F3C9E', ink: '#ffffff', nameColor: '#ffffff', accent: '#2747b0' },
    GOLDEN: { img: 'golden.jpg', w: 1004, h: 649, xs: [145, 307, 470, 643, 822], ys: [326, 449], r: 60, name: [184, 234, 925], stamp: '#151515', ink: '#FFD21F', nameColor: '#FFD21F', accent: '#b98900' },
    DIAMOND: { img: 'diamond.jpg', w: 1004, h: 650, xs: [167, 332, 497, 662, 830], ys: [330, 458], r: 58, name: [192, 239, 930], stamp: '#173C86', ink: '#BFEAFF', nameColor: '#ffffff', accent: '#1c8fc4' },
    LIGHT: { img: 'light.jpg', w: 1004, h: 649, xs: [167, 330, 495, 660, 830], ys: [330, 456], r: 58, name: [184, 238, 925], stamp: '#D01F26', ink: '#ffffff', nameColor: '#ffffff', accent: '#c4161c' },
  };

  function el(tag, attrs, text) {
    var e = document.createElement(tag);
    for (var k in attrs || {}) {
      if (k === 'style') Object.assign(e.style, attrs[k]);
      else e.setAttribute(k, attrs[k]);
    }
    if (text != null) e.textContent = text;
    return e;
  }
  function pct(v, of) { return (v / of * 100).toFixed(3) + '%'; }

  function renderCard(d) {
    var a = ART[d.tier.code] || ART.STANDARD;
    var card = el('div', { class: 'card', role: 'img', 'aria-label': d.tier.title + ', ' + d.currentCard.stampsEarned + ' of 10 stamps' });
    card.style.setProperty('--stamp', a.stamp);
    card.style.setProperty('--ink', a.ink);
    card.style.setProperty('--nameColor', a.nameColor);
    card.appendChild(el('img', { src: '/loyalty/' + a.img, alt: '' }));
    card.appendChild(el('div', { class: 'name', style: { left: pct(a.name[0], a.w), top: pct(a.name[1], a.h), width: pct(a.name[2] - a.name[0], a.w) } }, d.firstName));
    var next = null;
    d.currentCard.positions.forEach(function (p) { if (!p.earned && next === null) next = p.position; });
    d.currentCard.positions.forEach(function (p) {
      var x = a.xs[(p.position - 1) % 5], y = a.ys[Math.floor((p.position - 1) / 5)];
      var style = { left: pct(x, a.w), top: pct(y, a.h), width: pct(a.r * 2, a.w), height: pct(a.r * 2, a.h) };
      if (!p.earned) {
        if (p.position === next && !(d.account && d.account.isMaxTierCompleted)) card.appendChild(el('div', { class: 'slot next', style: style }));
        return;
      }
      if (!p.rewardType) { card.appendChild(el('div', { class: 'slot stamp', style: style }, '✓')); return; }
      var used = p.reward && p.reward.status === 'REDEEMED';
      var s = el('div', { class: 'slot reward' + (used ? ' used' : ''), style: style });
      s.appendChild(el('span', { class: 'tag' }, used ? 'USED' : 'EARNED'));
      card.appendChild(s);
    });
    if (d.account && d.account.isMaxTierCompleted) card.appendChild(el('div', { class: 'vip' }, 'VIP · COMPLETE'));
    return card;
  }

  function render(d) {
    var app = document.getElementById('app');
    app.textContent = '';
    var a = ART[d.tier.code] || ART.STANDARD;
    document.documentElement.style.setProperty('--accent', a.accent);
    app.appendChild(el('h1', null, 'Hi ' + d.firstName + ' — your ' + d.tier.title));
    app.appendChild(renderCard(d));

    var pr = d.progress, p1 = el('div', { class: 'panel' });
    if (pr.maxTierCompleted) {
      p1.appendChild(el('strong', null, 'You completed every card — Light VIP status!'));
      p1.appendChild(el('div', { class: 'muted' }, 'Any rewards below are still yours to use.'));
    } else {
      p1.appendChild(el('strong', null, 'Card ' + d.currentCard.cardNumber + ': ' + d.currentCard.stampsEarned + ' of 10 stamps'));
      p1.appendChild(el('div', { class: 'muted' }, pr.isFinalTier ? 'Final VIP card — ' + pr.stampsToCompleteCard + ' stamps to go'
        : pr.completedCardsInTier + ' of ' + pr.cardsRequired + ' cards completed' + (pr.nextTier ? ' · ' + pr.stampsToNextTier + ' stamps to ' + pr.nextTier.title : '')));
      var pips = el('div', { class: 'pips' });
      for (var i = 0; i < pr.cardsRequired; i++) pips.appendChild(el('div', { class: 'pip' + (i < pr.completedCardsInTier ? ' done' : '') }, i < pr.completedCardsInTier ? '✓' : i === pr.completedCardsInTier ? pr.stampsOnCard + '/10' : ''));
      p1.appendChild(pips);
      var bar = el('div', { class: 'bar' }), fill = el('div');
      fill.style.width = ((pr.completedCardsInTier * 10 + pr.stampsOnCard) / (pr.cardsRequired * 10) * 100) + '%';
      bar.appendChild(fill); p1.appendChild(bar);
    }
    app.appendChild(p1);

    var avail = d.rewards.filter(function (r) { return r.status === 'AVAILABLE'; });
    var p2 = el('div', { class: 'panel' });
    p2.appendChild(el('strong', null, avail.length ? 'Your rewards (' + avail.length + ')' : 'Rewards'));
    if (!avail.length) p2.appendChild(el('div', { class: 'muted' }, 'Keep skating — rewards appear here as soon as you earn them.'));
    var ul = el('ul');
    avail.forEach(function (r) {
      var li = el('li');
      li.appendChild(el('div', null, r.label));
      li.appendChild(el('div', { class: 'muted' }, r.description));
      var line = el('div', null, 'Show code ');
      line.appendChild(el('span', { class: 'code' }, r.code));
      line.appendChild(document.createTextNode(' at the desk'));
      li.appendChild(line);
      ul.appendChild(li);
    });
    var used = d.rewards.filter(function (r) { return r.status === 'REDEEMED'; });
    used.slice(0, 10).forEach(function (r) {
      ul.appendChild(el('li', { class: 'muted' }, r.label + ' — used ' + new Date(r.redeemedAt).toLocaleDateString()));
    });
    p2.appendChild(ul);
    app.appendChild(p2);
    app.appendChild(el('footer', { class: 'muted' }, d.venueName + ' · Skate More, Get More'));
  }

  var token = location.pathname.split('/').filter(Boolean).pop();
  fetch('/api/v1/public/loyalty/' + encodeURIComponent(token), { headers: { accept: 'application/json' } })
    .then(function (r) { if (!r.ok) throw new Error(r.status === 404 ? 'notfound' : 'error'); return r.json(); })
    .then(render)
    .catch(function (e) {
      var app = document.getElementById('app');
      app.textContent = '';
      app.appendChild(el('div', { class: 'err' }, e.message === 'notfound'
        ? 'This card link is not valid any more. Ask the Light Skate desk for a new QR code.'
        : 'Your card could not be loaded right now. Please try again in a moment.'));
    });
})();
