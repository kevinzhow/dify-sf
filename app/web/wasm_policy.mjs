// iOS Web policy, independent of any native deployment target.
// Flutter bootstrap: https://docs.flutter.dev/platform-integration/web/initialization
// Safari 26.6 streaming builtins: https://webkit.org/blog/18178/webkit-features-for-safari-26-6/
// Safari freezes its OS UA: https://webkit.org/blog/17333/webkit-features-in-safari-26-0/

export function iosCandidate(navigator) {
  const ua = navigator.userAgent || '';
  const isIOS = /iPhone|iPad|iPod/.test(ua) ||
    (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
  if (!isIOS) return {isIOS: false, allowed: false};
  // Safari's Version token is useful even when its OS token is frozen at 18.x.
  // Other iOS browsers may expose their real OS version instead. Unknown or
  // privacy-reduced versions still have to pass the native 26.6 feature probes.
  const safari = /\bVersion\/(\d+)(?:\.(\d+))?/.exec(ua);
  const os = /\bOS (\d+)(?:_(\d+))?/.exec(ua);
  const version = safari || (os && Number(os[1]) !== 18 ? os : null);
  const allowed = !version || Number(version[1]) > 26 ||
    (Number(version[1]) === 26 && Number(version[2] || 0) >= 6);
  return {isIOS: true, allowed};
}

export async function detectFeatures(env = globalThis) {
  const result = {gc: false, exceptions: false, jsTag: false, strings: false, webgl: false};
  try {
    const wasm = env.WebAssembly;
    result.gc = wasm.validate(new Uint8Array([0,97,115,109,1,0,0,0,1,5,1,95,1,120,0]));
    result.exceptions = wasm.validate(new Uint8Array([
      0,97,115,109,1,0,0,0,1,4,1,96,0,0,3,2,1,0,10,8,1,6,0,31,64,0,11,11,
    ]));
    result.jsTag = typeof wasm.JSTag !== 'undefined';
    if (!result.gc || !result.exceptions || !result.jsTag) return result;
    // Compile, instantiate AND invoke. Accepting compileOptions (or validate)
    // alone does not prove the engine honors JS String Builtins when streaming.
    const text = value => Array.from(value, c => c.charCodeAt(0));
    const imports = [1,14,...text('wasm:js-string'),12,...text('fromCharCode'),0,0];
    const bytes = new Uint8Array([
      0,97,115,109,1,0,0,0,1,7,1,96,1,127,1,100,111,2,imports.length,...imports,
      7,8,1,4,...text('test'),0,0,
    ]);
    const module = await wasm.compileStreaming(Promise.resolve(new env.Response(bytes, {
      headers: {'Content-Type': 'application/wasm'},
    })), {builtins: ['js-string']});
    const instance = await wasm.instantiate(module, {});
    result.strings = instance.exports.test(65) === 'A';
    const canvas = env.document.createElement('canvas');
    canvas.width = canvas.height = 1;
    const gl = canvas.getContext('webgl2') || canvas.getContext('webgl');
    result.webgl = gl !== null;
    gl?.getExtension('WEBGL_lose_context')?.loseContext();
  } catch (_) {
    // Missing APIs, blocked WebGL and failed native feature probes use Flutter's
    // compatibility build rather than preventing the app from starting.
  }
  return result;
}

export async function start(loader, {
  environment: env = globalThis,
  serviceWorkerSettings,
  probe = detectFeatures,
} = {}) {
  const url = new URL(env.location.href);
  const compatibility = url.searchParams.get('renderer') === 'canvaskit';
  const candidate = iosCandidate(env.navigator);
  let features = null;
  if (candidate.isIOS && candidate.allowed && !compatibility) {
    try { features = await probe(env); } catch (_) { /* compatibility build */ }
  }
  const iosWasm = !compatibility && candidate.allowed && features !== null &&
    ['gc', 'exceptions', 'jsTag', 'strings', 'webgl'].every(key => features[key] === true);
  const config = {};
  if (candidate.isIOS) {
    // iOS browser brands can be classified differently by Flutter's vendor
    // detector. Keep the same iOS version/capability policy for each brand.
    config.wasmAllowList = {blink: iosWasm, webkit: iosWasm, gecko: iosWasm, unknown: iosWasm};
  }
  if (compatibility) config.renderer = 'canvaskit';
  const state = env.__difyWebRuntime = {
    policy: 'ios-26.6-wasm',
    isIOS: candidate.isIOS,
    iosWasmEnabled: iosWasm,
    reason: compatibility ? 'compatibility-url' : !candidate.isIOS ? 'sdk-default' :
      !candidate.allowed ? 'below-minimum' : iosWasm ? 'ios-capabilities-passed' : 'features-unavailable',
    phase: 'loading',
  };
  let ready = false;
  let recovering = false;
  const recover = () => {
    if (!iosWasm || ready || recovering) return false;
    recovering = true;
    state.phase = 'fallback';
    // A fresh document is required: partially initialized Flutter engines are
    // not reentrant. The explicit URL also works without sessionStorage and
    // prevents an endless Wasm retry. Preserve the original route and query.
    const fallback = new URL(url);
    fallback.searchParams.set('renderer', 'canvaskit');
    env.console.warn('Wasm startup failed; restarting with the compatibility renderer.');
    env.location.replace(fallback.href);
    return true;
  };
  const onError = event => { if (event.error && (recovering || recover())) event.preventDefault(); };
  const onRejection = event => { if (recovering || recover()) event.preventDefault(); };
  function stopRecovery() {
    env.removeEventListener('error', onError);
    env.removeEventListener('unhandledrejection', onRejection);
  }
  env.addEventListener('flutter-first-frame', () => {
    if (recovering) return;
    ready = true;
    state.phase = 'ready';
    stopRecovery();
  }, {once: true});
  if (iosWasm) {
    env.addEventListener('error', onError);
    env.addEventListener('unhandledrejection', onRejection);
  }
  const options = {config};
  if (serviceWorkerSettings) options.serviceWorkerSettings = serviceWorkerSettings;
  if (iosWasm) {
    options.onEntrypointLoaded = async initializer => {
      try {
        // Flutter does not forward config automatically with a custom callback.
        const runner = await initializer.initializeEngine(config);
        await runner.runApp();
      } catch (error) {
        if (!recover() && !recovering) throw error;
      }
    };
  }
  try {
    await loader.load(options);
  } catch (error) {
    if (!recover() && !recovering) throw error;
  }
  return state;
}
