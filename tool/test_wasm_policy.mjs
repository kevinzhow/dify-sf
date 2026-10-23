import test from 'node:test';
import assert from 'node:assert/strict';
import {iosCandidate, start} from '../app/web/wasm_policy.mjs';

const safari = version => ({
  userAgent: `Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 Version/${version} Mobile/15E148 Safari/604.1`,
  platform: 'iPhone', maxTouchPoints: 5,
});
const features = {gc: true, exceptions: true, jsTag: true, strings: true, webgl: true};
function environment(navigator = safari('26.6'), href = 'https://test.invalid/?lang=zh-Hans') {
  const target = new EventTarget();
  const replacements = [];
  return {
    navigator, replacements,
    location: {href, replace: value => replacements.push(value)},
    console: {warn() {}},
    addEventListener: target.addEventListener.bind(target),
    removeEventListener: target.removeEventListener.bind(target),
    dispatchEvent: target.dispatchEvent.bind(target),
  };
}
async function launch(env, {probe = async () => features, load} = {}) {
  let options;
  const state = await start({load: async value => {
    options = value;
    if (load) await load(value);
  }}, {environment: env, probe});
  return {state, options};
}

test('Safari 26.6 uses its browser version, ignoring the frozen OS 18 token', () => {
  assert.deepEqual(iosCandidate(safari('26.6')), {isIOS: true, allowed: true});
  assert.deepEqual(iosCandidate(safari('27.0')), {isIOS: true, allowed: true});
  for (const version of ['18.6', '26.0', '26.2', '26.5']) {
    assert.deepEqual(iosCandidate(safari(version)), {isIOS: true, allowed: false});
  }
});

test('iPad desktop mode is iOS, desktop Safari is not', () => {
  const pad = {...safari('26.6'), userAgent: 'Macintosh Version/26.6 Safari/605.1.15', platform: 'MacIntel'};
  assert.equal(iosCandidate(pad).allowed, true);
  assert.equal(iosCandidate({...pad, maxTouchPoints: 0}).isIOS, false);
});

test('iOS Chrome and Firefox use their OS version rather than their brand version', () => {
  for (const brand of ['CriOS/156.0', 'FxiOS/148.0', 'EdgiOS/150.0']) {
    const nav = {...safari('26.6'), userAgent: `iPhone OS 26_6 ${brand} Mobile Safari/604.1`};
    assert.equal(iosCandidate(nav).allowed, true);
    assert.equal(iosCandidate({...nav, userAgent: nav.userAgent.replace('26_6', '26_5')}).allowed, false);
  }
});

test('unknown/frozen iOS versions still require all real feature probes', async () => {
  const nav = {...safari('26.6'), userAgent: 'iPhone OS 18_7 FxiOS/148.0 Mobile Safari/604.1'};
  assert.equal((await launch(environment(nav))).state.iosWasmEnabled, true);
  assert.equal((await launch(environment(nav), {probe: async () => ({...features, strings: false})})).state.iosWasmEnabled, false);
});

test('every required capability can independently prevent Wasm selection', async () => {
  for (const key of Object.keys(features)) {
    const {options, state} = await launch(environment(), {probe: async () => ({...features, [key]: false})});
    assert.equal(state.iosWasmEnabled, false, key);
    assert.equal(options.config.wasmAllowList.webkit, false, key);
    assert.equal(options.config.wasmAllowList.blink, false, key);
  }
});

test('probe exceptions use compatibility without failing startup', async () => {
  const {state, options} = await launch(environment(), {probe: async () => {throw Error('blocked');}});
  assert.equal(state.reason, 'features-unavailable');
  assert.equal(options.config.wasmAllowList.webkit, false);
});

test('old iOS and explicit compatibility do not start probes', async () => {
  let calls = 0;
  const probe = async () => {calls++; return features;};
  const older = await launch(environment(safari('26.5')), {probe});
  const explicit = await launch(environment(safari('26.6'), 'https://test.invalid/?renderer=canvaskit'), {probe});
  assert.equal(calls, 0);
  assert.equal(older.state.reason, 'below-minimum');
  assert.equal(explicit.options.config.renderer, 'canvaskit');
  assert.equal(explicit.state.iosWasmEnabled, false);
});

test('Android/desktop SDK selection remains intact and is not probed', async () => {
  let calls = 0;
  const {options, state} = await launch(environment({userAgent: 'Linux Android Chrome/156', platform: 'Linux', maxTouchPoints: 5}), {
    probe: async () => {calls++; return features;},
  });
  assert.deepEqual(options.config, {});
  assert.equal(calls, 0);
  assert.equal(state.reason, 'sdk-default');
});

test('the same config reaches Flutter engine initialization', async () => {
  const env = environment();
  let ran = false;
  const {state, options} = await launch(env, {load: async opts => {
    await opts.onEntrypointLoaded({initializeEngine: async config => {
      assert.equal(config, opts.config);
      return {runApp: async () => {ran = true; env.dispatchEvent(new Event('flutter-first-frame'));}};
    }});
  }});
  assert.equal(ran, true);
  assert.equal(state.phase, 'ready');
  assert.equal(options.config.wasmAllowList.webkit, true);
});

test('download/compile failure replaces the document once, preserving route/query/fragment', async () => {
  const original = 'https://test.invalid/form/test-form?server=https%3A%2F%2Fapi.invalid&lang=zh-Hans&doc=test#section';
  const env = environment(safari('26.6'), original);
  const {state} = await launch(env, {load: async () => {throw Error('compile failed');}});
  assert.equal(state.phase, 'fallback');
  assert.equal(env.replacements.length, 1);
  const actual = new URL(env.replacements[0]);
  assert.equal(actual.searchParams.get('renderer'), 'canvaskit');
  actual.searchParams.delete('renderer');
  assert.equal(actual.href, original);
  const next = environment(safari('26.6'), env.replacements[0]);
  await assert.rejects(launch(next, {load: async () => {throw Error('compatibility also failed');}}));
  assert.deepEqual(next.replacements, []);
});

for (const stage of ['initializeEngine', 'runApp']) {
  test(`${stage} rejection falls back before the first frame`, async () => {
    const env = environment();
    await launch(env, {load: async options => options.onEntrypointLoaded({initializeEngine: async () => {
      if (stage === 'initializeEngine') throw Error('engine failed');
      return {runApp: async () => {throw Error('app failed');}};
    }})});
    assert.equal(env.replacements.length, 1);
  });
}

test('concurrent startup errors trigger exactly one recovery', async () => {
  const env = environment();
  await launch(env);
  const rejection = new Event('unhandledrejection', {cancelable: true});
  env.dispatchEvent(rejection);
  const error = new Event('error', {cancelable: true});
  error.error = Error('another initialization failure');
  env.dispatchEvent(error);
  assert.equal(rejection.defaultPrevented, true);
  assert.equal(error.defaultPrevented, true);
  assert.equal(env.replacements.length, 1);
});

test('runtime errors after first paint are not mistaken for startup failures', async () => {
  const env = environment();
  await launch(env);
  env.dispatchEvent(new Event('flutter-first-frame'));
  const rejection = new Event('unhandledrejection', {cancelable: true});
  env.dispatchEvent(rejection);
  assert.equal(rejection.defaultPrevented, false);
  assert.deepEqual(env.replacements, []);
});
