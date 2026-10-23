import 'package:dify_sf_app/src/settings/form/base_form.dart';

/// A stand-in for tanstack's form API in the hooks' specs (Dify's tests pass plain objects).
class FakeFormApi implements FormApi {
  FakeFormApi({this.values, this.errors, this.meta});

  @override
  final Map<String, Object?>? values;
  final Map<String, List<String>>? errors;
  final FieldMeta? Function(String name)? meta;

  @override
  Map<String, List<String>>? getAllErrors() => errors;

  @override
  FieldMeta? getFieldMeta(String name) => meta?.call(name);
}
