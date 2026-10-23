{{flutter_js}}
{{flutter_build_config}}

// Use Flutter's supported bootstrap API; keep generated SDK files untouched.
import('./wasm_policy.mjs').then(
  ({start}) => start(_flutter.loader, {
    serviceWorkerSettings: {serviceWorkerVersion: {{flutter_service_worker_version}}},
  }),
  () => _flutter.loader.load({config: {renderer: 'canvaskit'}}),
);
