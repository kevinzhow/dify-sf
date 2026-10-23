// HTTP previews have no Async Clipboard API. Keep the native HTTPS API intact;
// use the browser's user-activated copy command only when that API is absent.
// Reading never returns a cached/fabricated clipboard value. Native keyboard
// paste into EditableText remains the browser's responsibility.
(() => {
  if (navigator.clipboard || !document.queryCommandSupported('copy')) return;
  const unavailable = () => Promise.reject(new DOMException(
    'Clipboard reading requires HTTPS. Use the browser keyboard paste command.',
    'NotAllowedError',
  ));
  const writeText = async (text) => {
    const active = document.activeElement;
    const selection = window.getSelection();
    const ranges = selection ? Array.from({length: selection.rangeCount}, (_, i) => selection.getRangeAt(i).cloneRange()) : [];
    const fieldSelection = active && 'selectionStart' in active
      ? [active.selectionStart, active.selectionEnd, active.selectionDirection] : null;
    const field = document.createElement('textarea');
    field.value = String(text);
    field.setAttribute('readonly', '');
    field.setAttribute('aria-hidden', 'true');
    field.tabIndex = -1;
    field.style.cssText = 'position:fixed;left:-10000px;top:0;opacity:0;';
    document.body.appendChild(field);
    try {
      field.select();
      if (!document.execCommand('copy')) {
        throw new DOMException('The browser refused the copy command.', 'NotAllowedError');
      }
    } finally {
      field.remove();
      if (active instanceof HTMLElement) {
        active.focus({preventScroll: true});
        if (fieldSelection && fieldSelection[0] !== null) {
          active.setSelectionRange(...fieldSelection);
        }
      }
      if (selection) {
        selection.removeAllRanges();
        ranges.forEach(range => selection.addRange(range));
      }
    }
  };
  Object.defineProperty(navigator, 'clipboard', {
    configurable: true,
    value: {writeText, readText: unavailable},
  });
})();
