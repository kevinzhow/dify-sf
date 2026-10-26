import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/account/release_status.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
void main(){
 testWidgets('version extension distinguishes absent server release and real capability without overflow',(t)async{
  await t.runAsync(()=>DifyI18n.load('zh-Hans',namespaces:['common']));
  t.view.physicalSize=const Size(320,800);t.view.devicePixelRatio=1;addTearDown(t.view.reset);
  await t.pumpWidget(const Directionality(textDirection:TextDirection.ltr,child:ReleaseStatus(features:SystemFeatures(inlineAgent:true,inlineAgentShell:false))));
  expect(find.text('版本与能力'),findsNothing);
  expect(find.text('dify-sf · 版本与能力'),findsOneWidget);
  expect(find.text('未报告'),findsNWidgets(3));expect(find.text('已启用'),findsOneWidget);expect(find.text('未启用'),findsNWidgets(2));
  expect(t.takeException(),isNull);
 });
}
