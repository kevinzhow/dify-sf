// Document shell for the pinned Flutter bootstrap. No CSS web font is required.
// Theme/language storage keys mirror shared_preferences_web and AppTheme/AppLocale.
window.__difyStartupLabels = {"ar-TN":{"loading":"جاري التحميل","retry":"إعادة المحاولة"},"de-DE":{"loading":"Laden","retry":"Erneut versuchen"},"en-US":{"loading":"Loading","retry":"Retry"},"es-ES":{"loading":"Cargando","retry":"Reintentar"},"fa-IR":{"loading":"در حال بارگذاری","retry":"تلاش دوباره"},"fr-FR":{"loading":"Chargement","retry":"Réessayer"},"hi-IN":{"loading":"लोड हो रहा है","retry":"पुनः प्रयास करें"},"id-ID":{"loading":"Memuat...","retry":"Coba lagi"},"it-IT":{"loading":"Caricamento","retry":"Riprova"},"ja-JP":{"loading":"読み込み中","retry":"再試行"},"ko-KR":{"loading":"로드 중","retry":"다시 시도"},"lo-LA":{"loading":"ກຳລັງໂຫລດ...","retry":"ລອງໃໝ່"},"nl-NL":{"loading":"Loading","retry":"Opnieuw proberen"},"pl-PL":{"loading":"Ładowanie","retry":"Spróbuj ponownie"},"pt-BR":{"loading":"Carregamento","retry":"Tentar novamente"},"ro-RO":{"loading":"Se încarcă","retry":"Reîncercați"},"ru-RU":{"loading":"Загрузка","retry":"Повторить"},"sl-SI":{"loading":"Nalaganje","retry":"Poskusi znova"},"th-TH":{"loading":"การโหลด","retry":"ลองอีกครั้ง"},"tr-TR":{"loading":"Yükleniyor","retry":"Tekrar dene"},"uk-UA":{"loading":"Завантаження","retry":"Повторити"},"vi-VN":{"loading":"Tải","retry":"Thử lại"},"zh-Hans":{"loading":"加载中","retry":"重试"},"zh-Hant":{"loading":"載入中","retry":"重試"}};

(() => {
  const root = document.documentElement;
  const shell = document.getElementById('dify-startup');
  const message = document.getElementById('dify-startup-message');
  const retry = document.getElementById('dify-startup-retry');
  const query = new URL(location.href).searchParams;
  const stored = key => {
    try { return JSON.parse(localStorage.getItem(`flutter.${key}`)); } catch (_) { return null; }
  };
  const supported = Object.keys(window.__difyStartupLabels);
  const browserLanguage = () => {
    const language = navigator.language || 'en-US';
    if (/^zh(?:-|$)/i.test(language)) return /(?:Hant|TW|HK|MO)/i.test(language) ? 'zh-Hant' : 'zh-Hans';
    return supported.includes(language) ? language : supported.find(value => value.split('-')[0] === language.split('-')[0]) || 'en-US';
  };
  const language = query.get('lang') || stored('lang') || browserLanguage();
  const labels = window.__difyStartupLabels[language] || window.__difyStartupLabels['en-US'];
  root.lang = language;
  message.textContent = labels.loading;
  retry.textContent = labels.retry;
  const system = matchMedia('(prefers-color-scheme: dark)');
  const validMode = value => ['light', 'dark', 'system'].includes(value) ? value : null;
  const mode = validMode(query.get('theme')) || validMode(stored('theme')) || 'system';
  const applyTheme = () => {
    root.dataset.startupTheme = mode === 'system' ? system.matches ? 'dark' : 'light' : mode;
    const chrome = document.querySelector('meta[name="theme-color"]');
    if (chrome) chrome.content = getComputedStyle(root).getPropertyValue('--background-default').trim();
  };
  applyTheme();
  system.addEventListener('change', applyTheme);
  // Flutter fetches these as assets, not CSS fonts. Matching fetch/CORS mode lets
  // its later requests consume the preload; browser verification checks no duplicate transfers.
  // Only Latin faces are eager. CJK core/shards are selected by the app and
  // Flutter's glyph-miss hook, using the actual locale and displayed text.
  const region = null;
  const fonts = ['NotoSans-Regular.ttf', 'NotoSans-Bold.ttf', 'DejaVuSansMono.ttf'];
  for (const path of fonts) {
    const link = document.createElement('link');
    link.rel = 'preload'; link.as = 'fetch'; link.crossOrigin = 'anonymous';
    link.href = `assets/assets/fonts/${path}`;
    document.head.append(link);
  }
  const state = window.__difyStartup = {phase: 'loading', language, region};
  const mark = phase => {
    state.phase = phase;
    performance.mark(`dify-startup:${phase}`);
  };
  let slow;
  state.stage = phase => { if (state.phase !== 'ready' && state.phase !== 'failed') mark(phase); };
  state.fail = () => {
    if (state.phase === 'ready' || state.phase === 'failed') return;
    mark('failed');
    shell.dataset.failed = 'true';
    shell.setAttribute('aria-busy', 'false');
    message.textContent = ({
      'zh-Hans': '应用加载失败，请重试。', 'zh-Hant': '應用程式載入失敗，請重試。',
      'ja-JP': 'アプリを読み込めませんでした。もう一度お試しください。',
      'ko-KR': '앱을 불러오지 못했습니다. 다시 시도해 주세요.',
    })[language] || 'Unable to load the app. Please try again.';
    retry.hidden = false;
    clearTimeout(slow);
  };
  const rejected = event => queueMicrotask(() => { if (!event.defaultPrevented) state.fail(); });
  const errored = event => { if (event.error) rejected(event); };
  window.addEventListener('unhandledrejection', rejected);
  window.addEventListener('error', errored);
  retry.addEventListener('click', () => location.reload());
  slow = setTimeout(() => { if (state.phase !== 'ready') retry.hidden = false; }, 30000);
  window.addEventListener('flutter-first-frame', async () => {
    if (window.__difyWebRuntime?.phase === 'fallback') return;
    performance.mark('dify-startup:first-frame');
    // Flutter's first frame can be the authentication/metadata loading route.
    // Wait for the actual initial page, whose layout discovers its own glyphs.
    if (!window.__difyPageReady) await new Promise(resolve => window.addEventListener('dify-page-ready', resolve, {once:true}));
    // The first text layout may discover emoji or other fallback glyphs. Keep
    // the document shell until those actual requests settle and their repaint
    // reaches the next browser frame. No extra language/font preloads are used.
    await new Promise(resolve => requestAnimationFrame(resolve));
    if (typeof window.difyFontIdle === 'function') await window.difyFontIdle();
    await new Promise(resolve => requestAnimationFrame(resolve));
    if (state.phase === 'failed') return;
    mark('ready'); clearTimeout(slow);
    system.removeEventListener('change', applyTheme);
    window.removeEventListener('unhandledrejection', rejected);
    window.removeEventListener('error', errored);
    shell.remove();
  }, {once: true});
  mark('loading');
})();
