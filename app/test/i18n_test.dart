import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Dify translations load, interpolate and fall back to en-US', () async {
    final en = await DifyI18n.load('en-US');
    expect(en.t('workflow', 'nodes.common.retry.retryTimes', {'times': 3}), 'Retry 3 times on failure');
    expect(en.t('workflow', 'no.such.key'), 'no.such.key');
    final zh = await DifyI18n.load('zh-Hans');
    expect(zh.t('workflow', 'entryNodeStatus.enabled'), isNot('entryNodeStatus.enabled'));
    DifyI18n.current = KeyEchoTranslator();
  });

  test('plural categories follow CLDR for Dify languages', () {
    expect(DifyI18n.pluralCategory('en-US', 1), 'one');
    expect(DifyI18n.pluralCategory('en-US', 2), 'other');
    expect(DifyI18n.pluralCategory('zh-Hans', 1), 'other');
    expect(DifyI18n.pluralCategory('ru-RU', 3), 'few');
    expect(DifyI18n.pluralCategory('ru-RU', 11), 'many');
    expect(DifyI18n.pluralCategory('fr-FR', 0), 'one');
  });

  test('locales map to Dify languages', () {
    expect(difyLanguageFor(const Locale('zh', 'CN')), 'zh-Hans');
    expect(difyLanguageFor(const Locale('zh', 'TW')), 'zh-Hant');
    expect(difyLanguageFor(const Locale('pt', 'PT')), 'pt-BR');
    expect(difyLanguageFor(const Locale('xx')), 'en-US');
  });
}
