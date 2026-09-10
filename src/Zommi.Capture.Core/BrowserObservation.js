// Executed in a CDP isolated world. Nothing is observed until Zommi invokes it.
(() => {
  if (globalThis.__zommiCapture) return;
  const documentId = crypto.randomUUID();
  const maximumText = 30000;
  let revision = 0;
  let visibilityRevision = 0;
  const visibilityChanged = () => visibilityRevision++;
  document.addEventListener('visibilitychange', visibilityChanged);
  let picker = null;
  let owner = null;
  let leaseTimeout = null;
  const own = element => element?.closest?.('[data-zommi-picker]');
  const mutations = new MutationObserver(records => {
    if (records.some(record => !own(record.target) &&
        !(record.type === 'childList' && [...record.addedNodes, ...record.removedNodes].length > 0 &&
          [...record.addedNodes, ...record.removedNodes].every(node =>
          node.nodeType === 1 && node.hasAttribute('data-zommi-picker'))))) revision++;
  });
  mutations.observe(document, {subtree: true, childList: true, attributes: true, characterData: true});
  const box = rect => ({x: rect.x, y: rect.y, width: rect.width, height: rect.height});
  // Layout/CSS and the desktop crop can round the same edge differently. Allow
  // at most one physical pixel, not enough to claim a clipped line or item.
  const edgeTolerance = () => 1 / Math.max(1, devicePixelRatio);
  const inside = (a, b) => {
    const tolerance = edgeTolerance();
    return a.x >= b.x - tolerance && a.y >= b.y - tolerance &&
      a.x + a.width <= b.x + b.width + tolerance && a.y + a.height <= b.y + b.height + tolerance;
  };
  const intersects = (a, b) => a.x < b.x + b.width && a.x + a.width > b.x &&
    a.y < b.y + b.height && a.y + a.height > b.y;
  const sensitive = element => !!element?.closest?.(
    'input[type=password], [autocomplete=current-password], [autocomplete=new-password], [autocomplete=one-time-code]');
  const parent = element => element?.parentElement || element?.getRootNode()?.host || null;
  const clipFor = element => {
    let left = 0, top = 0, right = innerWidth, bottom = innerHeight;
    for (let ancestor = parent(element), depth = 0; ancestor && depth < 64; ancestor = parent(ancestor), depth++) {
      // Root overflow clips the viewport, not the root's scrolled border box.
      // HTML also propagates body's overflow to that viewport when both root
      // overflow axes are visible (common on pages with a 100vh body).
      if (ancestor === document.documentElement) continue;
      if (ancestor === document.body) {
        const rootStyle = getComputedStyle(document.documentElement);
        if (rootStyle.overflowX === 'visible' && rootStyle.overflowY === 'visible') continue;
      }
      const style = getComputedStyle(ancestor);
      const rect = ancestor.getBoundingClientRect();
      if (style.overflowX !== 'visible') { left = Math.max(left, rect.left); right = Math.min(right, rect.right); }
      if (style.overflowY !== 'visible') { top = Math.max(top, rect.top); bottom = Math.min(bottom, rect.bottom); }
    }
    return {x: left, y: top, width: Math.max(0, right - left), height: Math.max(0, bottom - top)};
  };
  const visible = element => {
    if (!element?.isConnected || own(element) || sensitive(element)) return false;
    const style = getComputedStyle(element);
    const rect = element.getBoundingClientRect();
    return style.display !== 'none' && style.visibility === 'visible' && Number(style.opacity) > 0 &&
      rect.width > 0 && rect.height > 0 && intersects(box(rect), clipFor(element));
  };
  const textOf = element => {
    // Walking visible text nodes avoids leaking hidden/password descendants via textContent.
    const parts = [];
    let length = 0;
    let truncated = false;
    let visited = 0;
    const walk = node => {
      if (++visited > 3000 || length >= maximumText) { truncated = true; return; }
      if (node.nodeType === Node.TEXT_NODE) {
        const value = node.nodeValue || '';
        if (value.trim()) { parts.push(value); length += value.length; }
        return;
      }
      if (node.nodeType === Node.ELEMENT_NODE) {
        if (!visible(node) || ['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE'].includes(node.tagName)) return;
        if (node !== element && ['P', 'DIV', 'LI', 'TR', 'BR', 'H1', 'H2', 'H3'].includes(node.tagName)) parts.push('\n');
        if (node !== element && ['TD', 'TH'].includes(node.tagName) && node.previousElementSibling?.matches('td, th')) parts.push('\t');
      }
      for (const child of node.childNodes) walk(child);
      if (node.shadowRoot) for (const child of node.shadowRoot.childNodes) walk(child);
    };
    walk(element);
    const text = parts.join('').trim();
    return {text: text.slice(0, maximumText), truncated: truncated || text.length > maximumText};
  };
  const linkFor = element => {
    for (let current = element, depth = 0; current && depth < 64; current = parent(current), depth++) {
      if (current.matches?.('a[href]')) {
        try {
          const url = new URL(current.getAttribute('href'), current.baseURI);
          return /^(https?:|file:)$/.test(url.protocol) ? url.href : null;
        } catch { return null; }
      }
    }
    return null;
  };
  const describe = element => {
    const content = textOf(element);
    const role = element.getAttribute('role') || element.tagName.toLowerCase();
    return {
      role, ...content, label: element.getAttribute('aria-label') || element.getAttribute('alt') || null,
      value: /^(INPUT|TEXTAREA|SELECT)$/.test(element.tagName) && !sensitive(element) ? element.value.slice(0, maximumText) : null,
      // The destination belongs to the selected object even when its wrapping
      // link and product caption extend beyond an image-only rectangle.
      href: linkFor(element),
      disabled: 'disabled' in element ? element.disabled : element.getAttribute('aria-disabled') === 'true' ? true : null,
      checked: element.matches('input[type=checkbox], input[type=radio]') ? element.checked : null,
      bounds: box(element.getBoundingClientRect())
    };
  };
  const hit = (x, y) => {
    let element = document.elementFromPoint(x, y);
    for (let depth = 0; element?.shadowRoot && depth < 16; depth++) {
      const deeper = element.shadowRoot.elementFromPoint(x, y);
      if (!deeper || deeper === element) break;
      element = deeper;
    }
    return visible(element) ? element : null;
  };
  const selection = () => {
    const active = document.activeElement;
    if (sensitive(active)) return [];
    if (/^(INPUT|TEXTAREA)$/.test(active?.tagName) && Number.isInteger(active.selectionStart)) {
      return active.selectionStart === active.selectionEnd ? [] : [active.value.slice(active.selectionStart, active.selectionEnd)];
    }
    const selected = getSelection();
    if (!selected || selected.isCollapsed || sensitive(selected.anchorNode?.parentElement) ||
        sensitive(selected.focusNode?.parentElement)) return [];
    return [selected.toString()];
  };
  const stamp = () => ({documentId, revision, visibilityRevision, scrollX, scrollY, width: innerWidth, height: innerHeight,
    viewportX: visualViewport?.offsetLeft || 0, viewportY: visualViewport?.offsetTop || 0,
    viewportScale: visualViewport?.scale || 1, title: document.title, url: location.href,
    visible: document.visibilityState === 'visible'});
  const read = (options, chosen = null) => {
    const before = stamp();
    const elements = [];
    let nearby = null;
    let limitation = null;
    let truncated = false;
    if (options.mode === 'region') {
      const region = options.rect;
      let visited = 0;
      let total = 0;
      const walk = root => {
        for (const child of root.childNodes) {
          if (++visited > 6000 || total > maximumText || elements.length >= 256) { truncated = true; return; }
          if (child.nodeType === Node.TEXT_NODE && child.nodeValue.trim() && visible(child.parentElement)) {
            const range = document.createRange(); range.selectNodeContents(child);
            const rects = [...range.getClientRects()].filter(rect => rect.width > 0 && rect.height > 0);
            // A partially clipped line is not represented as if its entire text were selected.
            const clip = clipFor(child);
            if (rects.length && rects.every(rect => inside(box(rect), region) && inside(box(rect), clip))) {
              const text = child.nodeValue;
              elements.push({role: 'text', text, href: linkFor(child.parentElement), bounds: box(range.getBoundingClientRect()), truncated: false});
              total += text.length;
            }
          } else if (child.nodeType === Node.ELEMENT_NODE && visible(child)) {
            if (child.tagName === 'IFRAME' && intersects(box(child.getBoundingClientRect()), region)) {
              limitation = 'Embedded frame content is not included in this DOM region.';
            } else if (/^(INPUT|TEXTAREA|SELECT|IMG|CANVAS)$/.test(child.tagName)) {
              const bounds = box(child.getBoundingClientRect());
              if (inside(bounds, region) && inside(bounds, clipFor(child))) elements.push(describe(child));
            } else walk(child);
            if (child.shadowRoot) walk(child.shadowRoot);
          }
        }
      };
      walk(document.body || document.documentElement);
    } else {
      let target = chosen || hit(options.x, options.y);
      if (target?.tagName === 'IFRAME') { target = null; limitation = 'This embedded frame requires an image region.'; }
      if (target) {
        elements.push(describe(target));
        if (target.tagName === 'CANVAS') limitation = 'Use image selection to include this canvas\'s visual content.';
        if (options.mode !== 'element') {
          for (let container = parent(target), depth = 0; container && depth < 3; container = parent(container), depth++) {
            if (container === document.body || container === document.documentElement) break;
            if (!visible(container)) continue;
            const context = describe(container);
            if (context.text || context.label || context.value || context.disabled !== null) { nearby = context; break; }
          }
        }
      }
    }
    const selectedText = options.mode === 'capture' ? selection() : [];
    if (selectedText.some(text => text.length > 120000)) {
      selectedText.length = 0;
      limitation = 'The text selection is too large; select a smaller range.';
    }
    return {stamp: before, mode: options.mode, selectedText, elements, nearby,
      truncated: truncated || elements.some(element => element.truncated), limitation};
  };
  const stopPicker = result => {
    if (!picker || picker.done) return;
    picker.done = true;
    picker.result = result;
    for (const [name, handler] of picker.handlers) window.removeEventListener(name, handler, true);
    picker.overlay.remove();
    clearTimeout(picker.timeout);
  };
  const startPicker = options => {
    stopPicker(null);
    const overlay = document.createElement('div');
    overlay.setAttribute('data-zommi-picker', '');
    overlay.style.cssText = 'position:fixed;inset:0;pointer-events:none;z-index:2147483647';
    const shadow = overlay.attachShadow({mode: 'closed'});
    shadow.innerHTML = `<style>
      .outline{position:fixed;border:2px solid #6de0c7;background:#6de0c718;box-sizing:border-box;box-shadow:0 0 0 1px #11372e}
      .help{position:fixed;top:12px;left:50%;transform:translateX(-50%);max-width:90vw;padding:12px 18px;border:1px solid #7b8f92;border-radius:12px;background:#182429;color:#f6faf9;font:14px/1.5 system-ui;box-shadow:0 4px 20px #0008}
      .label{font-size:12px;color:#b4ebdd;overflow:hidden;text-overflow:ellipsis;max-width:70vw;white-space:nowrap}
      </style><div class="outline"></div><div class="help">Point to content · ↑ Larger · ↓ Smaller · Click or Enter to attach · Esc to cancel<div class="label"></div></div>`;
    document.documentElement.append(overlay);
    const outline = shadow.querySelector('.outline');
    const help = shadow.querySelector('.help');
    const label = shadow.querySelector('.label');
    picker = {overlay, handlers: [], target: null, chain: [], index: 0, done: false, result: null};
    const paint = () => {
      const element = picker.chain[picker.index];
      picker.target = element;
      if (!visible(element) || element.tagName === 'IFRAME') { outline.style.display = 'none'; label.textContent = 'No readable element here — choose another area or use image selection'; return; }
      const rect = element.getBoundingClientRect();
      Object.assign(help.style, rect.top < 100 ? {top: 'auto', bottom: '12px'} : {top: '12px', bottom: 'auto'});
      Object.assign(outline.style, {display: 'block', left: `${rect.x}px`, top: `${rect.y}px`, width: `${rect.width}px`, height: `${rect.height}px`});
      label.textContent = `${element.getAttribute('role') || element.tagName.toLowerCase()} · ${textOf(element).text.slice(0, 100) || element.getAttribute('aria-label') || 'visual element'}`;
    };
    const point = (x, y) => {
      const element = hit(x, y);
      if (element && element === picker.chain[0]) { paint(); return; }
      picker.chain = [];
      for (let current = element; current && picker.chain.length < 12; current = parent(current)) {
        if (current === document.documentElement) break;
        if (visible(current)) picker.chain.push(current);
      }
      picker.index = 0; paint();
    };
    const consume = event => {event.preventDefault(); event.stopImmediatePropagation();};
    const finish = () => {
      if (visible(picker.target) && picker.target.tagName !== 'IFRAME') stopPicker(read({mode: 'element'}, picker.target));
    };
    const handlers = {
      mousemove: event => { consume(event); point(event.clientX, event.clientY); },
      mousedown: consume,
      mouseup: consume,
      click: event => {consume(event); finish();},
      contextmenu: event => {consume(event); stopPicker(null);},
      keydown: event => {
        consume(event);
        if (event.key === 'Escape') stopPicker(null);
        else if (event.key === 'Enter') finish();
        else if (event.key === 'ArrowUp') { picker.index = Math.min(picker.chain.length - 1, picker.index + 1); paint(); }
        else if (event.key === 'ArrowDown') { picker.index = Math.max(0, picker.index - 1); paint(); }
      },
      wheel: event => {
        consume(event);
        picker.index = Math.max(0, Math.min(picker.chain.length - 1, picker.index + (event.deltaY < 0 ? 1 : -1))); paint();
      },
      pagehide: () => stopPicker(null),
      blur: () => stopPicker(null)
    };
    picker.handlers = Object.entries(handlers);
    for (const [name, handler] of picker.handlers) window.addEventListener(name, handler, {capture: true, passive: false});
    picker.timeout = setTimeout(() => stopPicker(null), 60000);
    point(options.x, options.y);
    return stamp();
  };
  const release = () => {
    clearTimeout(leaseTimeout);
    stopPicker(null);
    picker = null;
    mutations.disconnect();
    document.removeEventListener('visibilitychange', visibilityChanged);
    delete globalThis.__zommiCapture;
  };
  globalThis.__zommiCapture = (options, caller) => {
    if (options.mode === 'acquire') {
      if (owner !== null && owner !== caller) return false;
      owner = caller;
      return true;
    }
    if (owner !== caller) throw new Error('Another capture owns this observation.');
    clearTimeout(leaseTimeout);
    leaseTimeout = setTimeout(release, 30000);
    if (options.mode === 'release') { release(); return null; }
    if (options.mode === 'stamp') return stamp();
    if (options.mode === 'picker') return startPicker(options);
    if (options.mode === 'poll') return picker ? {done: picker.done, result: picker.result} : {done: true, result: null};
    if (options.mode === 'cancel') { stopPicker(null); return null; }
    return read(options);
  };
  leaseTimeout = setTimeout(release, 30000);
})();
