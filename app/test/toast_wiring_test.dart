// Dify's panels call the app-wide `toast` directly; ours take toast callbacks from their hosts, which default to the
// app's toast host, so the messages show without a host providing them.
import 'package:dify_sf_app/src/design/dify_icon.dart';
import 'package:dify_sf_app/src/workflow_editor/header/header_data.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/core/core_kit.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/data_common.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/entry/data_source/data_source_host.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/group_host.dart';
import 'package:dify_sf_app/src/workflow_editor/variable_panels/app_variables.dart' show toastError;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';

void main() {
  test('the hosts toast through the app toast host by default', () {
    expect(const WorkflowHeaderData().toast, difyToast);
    expect(LlmGroupServices.empty.toast, difyToast);
    expect(const CorePanelHostData().toastError, difyToastError);
    expect(const DataPanelHost(child: SizedBox()).toast, difyToast);
    expect(const DataSourceHost(child: SizedBox()).onToastError, difyToastError);
    expect(TagInput(items: const [], onChange: (_) {}).onError, difyToastError);
  });

  testWidgets('a panel without a host shows its error on the app toast host', (t) async {
    await t.pumpWidget(
      MaterialApp(
        home: Material(
          child: Stack(
            children: [
              Builder(
                builder: (context) => TextButton(
                  onPressed: () => toastError(context, 'Variable name is required'),
                  child: const Text('Save'),
                ),
              ),
              const DifyToastHost(),
            ],
          ),
        ),
      ),
    );
    await t.tap(find.text('Save'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 600));

    expect(find.text('Variable name is required'), findsOneWidget);
    expect(find.byWidgetPredicate((w) => w is RemixIcon && w.name == 'error-warning-fill'), findsOneWidget);
    await t.pump(const Duration(seconds: 6));
  });
}
