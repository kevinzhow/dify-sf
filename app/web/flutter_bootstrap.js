{{flutter_js}}
{{flutter_build_config}}

// Use Flutter's supported bootstrap API; keep generated SDK files untouched.
import('./wasm_policy.mjs').then(
  ({start}) => start(_flutter.loader, {
    serviceWorkerSettings: {serviceWorkerVersion: {{flutter_service_worker_version}}},
  }),
  () => _flutter.loader.load({
    config: {renderer: 'canvaskit', fontFallbackBaseUrl: new URL('font-fallback/', document.baseURI).href},
    onEntrypointLoaded: async initializer => {
      try {
        window.__difyStartup?.stage('engine');
        const runner = await initializer.initializeEngine({renderer: 'canvaskit', fontFallbackBaseUrl: new URL('font-fallback/', document.baseURI).href});
        window.__difyStartup?.stage('app');
        await runner.runApp();
      } catch (error) { window.__difyStartup?.fail(); throw error; }
    },
  }).catch(error => { window.__difyStartup?.fail(); throw error; }),
);
