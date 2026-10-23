import 'package:flutter/foundation.dart';

import 'workflow_store.dart';

/// workflow/plugin-dependency/store.ts: the plugins an imported DSL needs (Dify's Dependency JSON).
class PluginDependencyStore {
  final dependencies = ValueNotifier<List<DifyJson>>(const []);
  void setDependencies(List<DifyJson> v) => dependencies.value = v;

  void dispose() => dependencies.dispose();
}
