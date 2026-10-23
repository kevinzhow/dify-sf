// Browser fixture for the actual shared menu widgets; no backend or user account.
import 'package:dify_sf_app/src/auth/account_dropdown.dart';
import 'package:dify_sf_app/src/auth/auth_api.dart';
import 'package:dify_sf_app/src/design/dify_fonts.dart';
import 'package:dify_sf_app/src/design/dify_icon.dart';
import 'package:dify_sf_app/src/design/dify_theme.dart';
import 'package:dify_sf_app/src/design/dify_theme_mode.dart';
import 'package:dify_sf_app/src/design/dify_tokens.g.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/i18n/app_locale.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:flutter/widgets.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await DifyFonts.loadFor('zh-Hans');
  await DifyI18n.load('zh-Hans');
  final dark = Uri.base.queryParameters['theme'] == 'dark';
  DifyColors.useDark(dark);
  final theme = AppTheme(dark ? DifyThemeMode.dark : DifyThemeMode.light, remember: false);
  runApp(
    ListenableBuilder(
      listenable: theme,
      builder: (_, _) => DifyApplication(
        theme: difyTheme(
          fontFamily: DifyFonts.primaryFamily,
          fontFamilyFallback: DifyFonts.fallbackFamilies,
          brightness: theme.isDark ? Brightness.dark : Brightness.light,
        ),
        home: AppLocaleScope(
          locale: AppLocale('zh-Hans'),
          child: AppThemeScope(theme: theme, child: const _Menus()),
        ),
      ),
    ),
  );
}

class _Menus extends StatefulWidget {
  const _Menus();
  @override
  State<_Menus> createState() => _MenusState();
}

class _MenusState extends State<_Menus> {
  bool checked = false, deep = false;
  String radio = '甲', selected = '甲';
  int actions = 0;
  Widget button(String label, DifyFloatingController c) => DifyButton(onPressed: c.toggle, child: DifyTextLine(label));
  List<Widget> get items => [
    DifyMenuItem(
      leading: const RemixIcon('add-line'),
      onSelect: () => setState(() => actions++),
      child: const DifyTextLine('普通操作'),
    ),
    const DifyMenuItem(disabled: true, child: DifyTextLine('禁用操作')),
    DifyMenuCheckboxItem(
      checked: checked,
      onCheckedChange: (v) => setState(() => checked = v),
      child: const DifyTextLine('保持打开'),
    ),
    DifyMenuRadioGroup<String>(
      value: radio,
      onValueChange: (v) => setState(() => radio = v),
      children: const [
        DifyMenuRadioItem(value: '甲', child: DifyTextLine('选项甲')),
        DifyMenuRadioItem(value: '乙', child: DifyTextLine('选项乙')),
      ],
    ),
    DifyMenuSubmenu(
      label: const DifyTextLine('次级菜单'),
      width: 180,
      children: [
        DifyMenuSubmenu(
          label: const DifyTextLine('深层菜单'),
          width: 180,
          children: [
            DifyMenuCheckboxItem(
              checked: deep,
              onCheckedChange: (v) => setState(() => deep = v),
              child: const DifyTextLine('深层保持'),
            ),
          ],
        ),
      ],
    ),
  ];
  @override
  Widget build(BuildContext context) => DifyPage(
    body: Stack(
      children: [
        Positioned.fill(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: DefaultTextStyle.merge(
              textAlign: TextAlign.center,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 16,
                children: [
                  const DifyTextLine('共享菜单交互测试'),
                  DifyDropdownMenu(
                    width: 240,
                    semanticLabel: '共享菜单',
                    builder: (_, c) => button('打开菜单', c),
                    children: items,
                  ),
                  DifyPopover(
                    placement: DifyPlacement.rightStart,
                    semanticLabel: '第一层弹出框',
                    builder: (_, c) => button('第一层弹出框', c),
                    content: SizedBox(
                      width: 180,
                      height: 80,
                      child: Center(
                        child: DifyPopover(
                          placement: DifyPlacement.rightStart,
                          semanticLabel: '第二层弹出框',
                          builder: (_, c) => button('第二层弹出框', c),
                          content: SizedBox(
                            width: 180,
                            height: 80,
                            child: Center(
                              child: DifyDropdownMenu(
                                width: 180,
                                placement: DifyPlacement.rightStart,
                                semanticLabel: '混合深层菜单',
                                builder: (_, c) => button('第三层菜单', c),
                                children: [
                                  DifyMenuCheckboxItem(
                                    checked: deep,
                                    onCheckedChange: (v) => setState(() => deep = v),
                                    child: const DifyTextLine('混合保持'),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  DifyContextMenu(
                    semanticLabel: '上下文菜单',
                    width: 200,
                    children: items,
                    child: Container(
                      width: 200,
                      height: 72,
                      color: DifyColors.backgroundSection,
                      alignment: Alignment.center,
                      child: const DifyTextLine('右键或长按区域'),
                    ),
                  ),
                  SizedBox(
                    width: 240,
                    child: DifySelect<String>(
                      value: selected,
                      semanticLabel: '菜单选择器',
                      onChanged: (v) => setState(() => selected = v),
                      options: const [(value: '甲', label: '选择甲'), (value: '乙', label: '选择乙')],
                    ),
                  ),
                  DifyTextLine('actions=$actions checked=$checked deep=$deep radio=$radio select=$selected'),
                ],
              ),
            ),
          ),
        ),
        const Positioned(
          left: 12,
          bottom: 12,
          child: AccountSection(
            compact: true,
            account: Account(id: 'menu-fixture', name: '菜单验收', email: 'menu@example.test', role: AccountRole.owner),
          ),
        ),
      ],
    ),
  );
}
