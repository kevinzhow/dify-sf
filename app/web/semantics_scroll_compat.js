// Flutter 3.47.6's semantics scroll synchronizer writes scrollTop for both axes.
// SDK revision: 5fc346839b5d0eef006ed8404392afb4dfae428d. Remove after the
// engine synchronizes by axis; rerun verify_semantics_scroll_web.py and real UI taps.
// Restrict the correction to its horizontal accessibility overflow elements.
(() => {
  const descriptor = Object.getOwnPropertyDescriptor(Element.prototype, 'scrollTop');
  if (!descriptor?.get || !descriptor?.set) return;
  const horizontal = element => Array.from(element.children).some(child =>
    child.localName === 'flt-semantics-scroll-overflow' &&
    child.style.height === '1px' && child.style.width !== '1px');
  const attach = element => {
    if (element.localName !== 'flt-semantics' || Object.hasOwn(element, 'scrollTop')) return;
    Object.defineProperty(element, 'scrollTop', {
      configurable: true,
      get() { return descriptor.get.call(this); },
      set(value) {
        if (horizontal(this)) {
          this.scrollLeft = value;
          descriptor.set.call(this, 0);
        } else descriptor.set.call(this, value);
      }
    });
  };
  const visit = node => {
    if (!(node instanceof Element)) return;
    attach(node);
    node.querySelectorAll('flt-semantics').forEach(attach);
  };
  new MutationObserver(records => {
    for (const record of records) for (const node of record.addedNodes) visit(node);
  }).observe(document, { childList: true, subtree: true });
  visit(document.documentElement);
})();
