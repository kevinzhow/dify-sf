import 'package:dify_sf_app/src/design/dify_fonts.dart';
import 'package:dify_sf_app/src/design/widgets/font_notice.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
void main(){
 testWidgets('recoverable font notice retains the same editable field and its input',(t)async{
  await t.runAsync(()=>DifyI18n.load('zh-Hans',namespaces:['common']));
  var input='用户尚未提交的输入 😀';
  addTearDown(()=>DifyFonts.failed.value=false);
  await t.pumpWidget(MaterialApp(home:Scaffold(body:Stack(children:[DifyInput(value:input,onChanged:(v)=>input=v),const DifyFontLoadNotice()]))));
  final editable=t.state<EditableTextState>(find.byType(EditableText));
  DifyFonts.failed.value=true;await t.pump();expect(find.text('部分文字加载失败，请联网后重试。'),findsOneWidget);
  await t.tap(find.text('重试'));await t.pump();
  expect(DifyFonts.failed.value,isFalse);expect(input,'用户尚未提交的输入 😀');
  expect(t.state<EditableTextState>(find.byType(EditableText)),same(editable));
 });
}
