/// app/create-app-modal (Create from Blank) in app/create-app-dialog-shell: the full-screen dialog with the app type
/// cards, name, icon and description on the left and the type's preview on the right. dify-sf creates the two modes
/// its editor runs (owner decision): Workflow and Chatflow, Dify's first two cards; the "for beginners" types and the
/// "browse templates" link are left out.
library;

import 'dart:async';
import 'dart:ui' as ui;

import 'package:collab_client/collab_client.dart';
import 'package:flutter/material.dart' show Material, MaterialType;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../design/dify_icon.dart';
import '../design/dify_tokens.g.dart';
import '../design/widgets/app_icon_picker.dart' show UploadAppIcon;
import '../design/widgets/widgets.dart';
import '../i18n/dify_i18n.dart';
import '../workflow_editor/panel_fields/controls.dart' show DifyInput;
import '../workflow_editor/panel_fields/form_controls.dart' show DifyTextarea;
import 'app_icons.dart';
import 'app_modals.dart';

String _a(String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr('app', key, params);

/// Shows [child] in CreateAppDialogShell: the whole window (`p-4`) over the blurred overlay backdrop, a
/// `rounded-2xl border-effects-highlight bg-background-default-subtle` box with the close button at the top right.
Future<T?> showCreateAppDialogShell<T>(BuildContext context, {required String title, required WidgetBuilder builder}) =>
    showGeneralDialog<T>(
      context: context,
      barrierDismissible: true,
      barrierLabel: title,
      barrierColor: const Color(0x00000000),
      transitionDuration: const Duration(milliseconds: 150),
      transitionBuilder: (context, animation, _, child) => FadeTransition(opacity: animation, child: child),
      pageBuilder: (context, _, _) => CallbackShortcuts(
        bindings: {const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.pop(context)},
        child: FocusScope(
          autofocus: true,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Positioned.fill(
                child: BackdropFilter(
                  filter: ui.ImageFilter.blur(sigmaX: 3, sigmaY: 3),
                  child: ColoredBox(color: DifyColors.backgroundOverlayBackdrop),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Material(
                  type: MaterialType.transparency,
                  child: Semantics(
                    container: true,
                    scopesRoute: true,
                    namesRoute: true,
                    explicitChildNodes: true,
                    label: title,
                    child: Container(
                      clipBehavior: Clip.antiAlias,
                      decoration: BoxDecoration(
                        color: DifyColors.backgroundDefaultSubtle,
                        borderRadius: BorderRadius.circular(DifyRadius.xxl),
                        border: Border.all(color: DifyColors.effectsHighlight),
                      ),
                      child: Stack(
                        children: [
                          Positioned.fill(child: builder(context)),
                          Positioned(
                            top: 12,
                            right: 12,
                            child: DifyPressable(
                              key: const ValueKey('create-app-shell-close'),
                              semanticLabel: 'Close',
                              onPressed: () => Navigator.pop(context),
                              builder: (context, hovered, focused) => Container(
                                width: 36,
                                height: 36,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: hovered
                                      ? DifyColors.componentsButtonTertiaryBgHover
                                      : DifyColors.componentsButtonTertiaryBg,
                                  borderRadius: BorderRadius.circular(10),
                                  border: focused ? Border.all(color: DifyColors.stateAccentSolid, width: 2) : null,
                                ),
                                child: RemixIcon(
                                  'close-large-line',
                                  size: 14,
                                  color: DifyColors.componentsButtonTertiaryText,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

/// The blank app to create (`POST /apps`).
typedef CreateAppRequest = ({
  String name,
  String description,
  String mode,
  String iconType,
  String icon,
  String? iconBackground,
});

/// CreateApp: [onCreate] creates the app (and opens it); on success the dialog shows `newApp.appCreated` and closes
/// through [onClose]. Create (debounced 300 ms, also Mod+Enter) is disabled until there is a name.
class CreateAppModal extends StatefulWidget {
  const CreateAppModal({
    super.key,
    required this.onClose,
    required this.onCreate,
    this.defaultAppMode,
    this.canCreateApp = true,
    this.uploadIcon,
  });

  final VoidCallback onClose;
  final Future<void> Function(CreateAppRequest request) onCreate;

  /// The Studio's type filter; Chatflow otherwise.
  final String? defaultAppMode;
  final bool canCreateApp;
  final UploadAppIcon? uploadIcon;

  @override
  State<CreateAppModal> createState() => _CreateAppModalState();
}

class _CreateAppModalState extends State<CreateAppModal> {
  late String _mode = AppModes.creatable.contains(widget.defaultAppMode)
      ? widget.defaultAppMode!
      : AppModes.advancedChat;
  AppIconSelection _icon = (type: 'emoji', icon: '🤖', background: '#FFEAD5', url: null);
  String _name = '';
  String _description = '';
  bool _creating = false;
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _create() async {
    if (!widget.canCreateApp) return;
    if (!AppModes.creatable.contains(_mode)) {
      toast.error(_a('newApp.appTypeRequired'));
      return;
    }
    if (_name.trim().isEmpty) {
      toast.error(_a('newApp.nameNotEmpty'));
      return;
    }
    if (_creating) return;
    setState(() => _creating = true);
    try {
      await widget.onCreate((
        name: _name,
        description: _description,
        mode: _mode,
        iconType: _icon.type,
        icon: _icon.icon,
        iconBackground: _icon.type == 'emoji' ? _icon.background : null,
      ));
      toast.success(_a('newApp.appCreated'));
      widget.onClose();
    } on TransportException catch (e) {
      toast.error(e.message.isNotEmpty ? e.message : _a('newApp.appCreateFailed'));
    } on Object {
      toast.error(_a('newApp.appCreateFailed'));
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  void _handleCreate() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () => unawaited(_create()));
  }

  Future<void> _pickIcon() async {
    final v = await pickAppIcon(context, _icon, upload: widget.uploadIcon);
    if (v != null && mounted) setState(() => _icon = v);
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 1536;
    final top = wide ? 139.0 : 24.0;
    final canSubmit = widget.canCreateApp && _name.isNotEmpty;
    return CallbackShortcuts(
      bindings: modEnter(widget.canCreateApp ? _handleCreate : null),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: SingleChildScrollView(
              child: Align(
                alignment: AlignmentDirectional.topEnd,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 40),
                  child: SizedBox(
                    width: 660,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(height: top),
                        Padding(
                          padding: const EdgeInsets.only(top: 4, bottom: 24),
                          child: Text(
                            _a('newApp.startFromBlank'),
                            style: difyTextStyle(DifyType.title2xlSemiBold, DifyColors.textPrimary),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Text(
                            _a('newApp.chooseAppType'),
                            style: difyTextStyle(DifyType.systemSmSemibold, DifyColors.textSecondary),
                          ),
                        ),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          spacing: 16,
                          children: [
                            Row(
                              spacing: 8,
                              children: [
                                _AppTypeCard(
                                  key: const ValueKey('create-app-type-workflow'),
                                  active: _mode == AppModes.workflow,
                                  title: _a('types.workflow'),
                                  description: _a('newApp.workflowShortDescription'),
                                  color: DifyColors.componentsIconBgIndigoSolid,
                                  icon: RemixIcon(
                                    'exchange-2-fill',
                                    size: 16,
                                    color: DifyColors.componentsAvatarShapeFillStop100,
                                  ),
                                  onTap: () => setState(() => _mode = AppModes.workflow),
                                ),
                                _AppTypeCard(
                                  key: const ValueKey('create-app-type-advanced-chat'),
                                  active: _mode == AppModes.advancedChat,
                                  title: _a('types.advanced'),
                                  description: _a('newApp.advancedShortDescription'),
                                  color: DifyColors.componentsIconBgBlueLightSolid,
                                  icon: DifyIcon(
                                    'vender/solid/communication/bubble-text-mod',
                                    size: 16,
                                    color: DifyColors.componentsAvatarShapeFillStop100,
                                  ),
                                  onTap: () => setState(() => _mode = AppModes.advancedChat),
                                ),
                              ],
                            ),
                            DifyDivider(margin: EdgeInsets.zero),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              spacing: 12,
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.stretch,
                                    children: [
                                      SizedBox(
                                        height: 24,
                                        child: Align(
                                          alignment: AlignmentDirectional.centerStart,
                                          child: Text(
                                            _a('newApp.captionName'),
                                            style: difyTextStyle(DifyType.systemSmSemibold, DifyColors.textSecondary),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      DifyInput(
                                        key: const ValueKey('create-app-name'),
                                        value: _name,
                                        placeholder: _a('newApp.appNamePlaceholder'),
                                        semanticLabel: _a('newApp.captionName'),
                                        onChanged: (v) => setState(() => _name = v),
                                      ),
                                    ],
                                  ),
                                ),
                                DifyAppIcon(
                                  key: const ValueKey('create-app-icon'),
                                  size: DifyAppIconSize.xxl,
                                  radius: DifyRadius.xxl,
                                  iconType: _icon.type,
                                  icon: _icon.icon,
                                  background: _icon.background,
                                  imageUrl: _icon.url,
                                  semanticLabel: _a('iconPicker.emoji'),
                                  onTap: _pickIcon,
                                ),
                              ],
                            ),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                SizedBox(
                                  height: 24,
                                  child: Row(
                                    children: [
                                      Text(
                                        _a('newApp.captionDescription'),
                                        style: difyTextStyle(DifyType.systemSmSemibold, DifyColors.textSecondary),
                                      ),
                                      Flexible(
                                        child: Padding(
                                          padding: const EdgeInsets.only(left: 4),
                                          child: Text(
                                            '(${_a('newApp.optional')})',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: difyTextStyle(DifyType.systemXsRegular, DifyColors.textTertiary),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 4),
                                DifyTextarea(
                                  key: const ValueKey('create-app-description'),
                                  value: _description,
                                  placeholder: _a('newApp.appDescriptionPlaceholder'),
                                  semanticLabel: _a('newApp.captionDescription'),
                                  onChanged: (v) => setState(() => _description = v),
                                ),
                              ],
                            ),
                          ],
                        ),
                        Padding(
                          padding: const EdgeInsets.only(top: 20, bottom: 40),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            spacing: 8,
                            children: [
                              DifyButton(
                                key: const ValueKey('create-app-cancel'),
                                semanticLabel: _a('newApp.Cancel'),
                                onPressed: widget.onClose,
                                child: Text(_a('newApp.Cancel')),
                              ),
                              DifyButton(
                                key: const ValueKey('create-app-submit'),
                                variant: DifyButtonVariant.primary,
                                disabled: !canSubmit,
                                loading: _creating,
                                semanticLabel: _a('newApp.Create'),
                                onPressed: _handleCreate,
                                child: labelWithModEnter(_a('newApp.Create'), disabled: !canSubmit),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            child: _Preview(mode: _mode, top: top),
          ),
        ],
      ),
    );
  }
}

/// AppTypeCard: `box-content h-21 w-47.75 rounded-xl border-[0.5px] border-components-option-card-option-border
/// bg-components-panel-on-panel-item-bg p-3 shadow-xs hover:shadow-md`; the active one also has the selected outline.
class _AppTypeCard extends StatelessWidget {
  const _AppTypeCard({
    super.key,
    required this.active,
    required this.title,
    required this.description,
    required this.color,
    required this.icon,
    required this.onTap,
  });

  final bool active;
  final String title, description;
  final Color color;
  final Widget icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    selected: active,
    child: DifyPressable(
      semanticLabel: title,
      onPressed: onTap,
      builder: (context, hovered, focused) => Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            // `box-content w-47.75 h-21 p-3 border-[0.5px]`.
            width: 191 + 24 + 1,
            height: 84 + 24 + 1,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: DifyColors.componentsPanelOnPanelItemBg,
              borderRadius: BorderRadius.circular(DifyRadius.xl),
              border: Border.all(color: DifyColors.componentsOptionCardOptionBorder, width: 0.5),
              boxShadow: active || hovered ? DifyShadows.md : DifyShadows.xs,
            ),
            // `h-21` with CSS's visible overflow: the content keeps its own height.
            child: OverflowBox(
              alignment: Alignment.topLeft,
              minHeight: 0,
              maxHeight: double.infinity,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 24,
                    height: 24,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(DifyRadius.md)),
                    child: icon,
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 8, bottom: 2),
                    child: Text(title, style: difyTextStyle(DifyType.systemSmSemibold, DifyColors.textSecondary)),
                  ),
                  Text(
                    description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: difyTextStyle(DifyType.systemXsRegular, DifyColors.textTertiary),
                  ),
                ],
              ),
            ),
          ),
          // The selected `outline-[1.5px]` and the focus ring sit outside the box (no layout).
          if (active || focused)
            Positioned(
              left: focused ? -2 : -1.5,
              top: focused ? -2 : -1.5,
              right: focused ? -2 : -1.5,
              bottom: focused ? -2 : -1.5,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(DifyRadius.xl + (focused ? 2 : 1.5)),
                    border: Border.all(
                      color: focused
                          ? DifyColors.stateAccentSolid
                          : DifyColors.componentsOptionCardOptionSelectedBorder,
                      width: focused ? 2 : 1.5,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    ),
  );
}

/// The right half: AppPreview (the type's name and user description) over its screenshot
/// (`/screenshots/<theme>/<Workflow|Chatflow>.png`, 664 x 448) on the striped background, between divider lines.
class _Preview extends StatelessWidget {
  const _Preview({required this.mode, required this.top});

  final String mode;
  final double top;

  @override
  Widget build(BuildContext context) {
    final workflow = mode == AppModes.workflow;
    final title = workflow ? _a('types.workflow') : _a('types.advanced');
    final description = workflow ? _a('newApp.workflowUserDescription') : _a('newApp.advancedUserDescription');
    final theme = DifyColors.isDark ? 'dark' : 'light';
    final line = BorderSide(color: DifyColors.dividerSubtle);
    return ClipRect(
      child: Stack(
        children: [
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: top,
            child: DecoratedBox(
              decoration: BoxDecoration(border: Border(bottom: line)),
            ),
          ),
          Align(
            alignment: AlignmentDirectional.topStart,
            child: Container(
              width: 666,
              decoration: BoxDecoration(
                border: Border(left: line, right: line),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(height: top),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          difyTransform(DifyType.systemSmSemiboldUppercase, title),
                          style: difyTextStyle(DifyType.systemSmSemiboldUppercase, DifyColors.textSecondary),
                        ),
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(minHeight: 32, maxWidth: 384),
                            child: Text(
                              description,
                              style: difyTextStyle(DifyType.systemXsRegular, DifyColors.textTertiary),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  DecoratedBox(
                    decoration: BoxDecoration(border: Border(bottom: line)),
                  ),
                  SizedBox(
                    height: 448,
                    child: CustomPaint(
                      painter: _StripesPainter(),
                      child: Center(
                        child: Image.asset(
                          'assets/screenshots/$theme/${workflow ? 'Workflow' : 'Chatflow'}.png',
                          key: ValueKey('create-app-preview-$mode'),
                          width: 664,
                          height: 448,
                          excludeFromSemantics: true,
                          errorBuilder: (_, _, _) => const SizedBox(width: 664, height: 448),
                        ),
                      ),
                    ),
                  ),
                  DecoratedBox(
                    decoration: BoxDecoration(border: Border(bottom: line)),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// `repeating-linear-gradient(135deg, transparent, transparent 2px, rgba(16,24,40,0.04) 4px, transparent 3px,
/// transparent 6px)`: a 6 px period towards the bottom right.
class _StripesPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    const d = 6 / 1.4142135623730951;
    final paint = Paint()
      ..shader = ui.Gradient.linear(
        Offset.zero,
        const Offset(d, d),
        const [Color(0x00000000), Color(0x00000000), Color(0x0A101828), Color(0x00000000), Color(0x00000000)],
        const [0, 2 / 6, 4 / 6, 4 / 6, 1],
        TileMode.repeated,
      );
    canvas.drawRect(Offset.zero & size, paint);
  }

  @override
  bool shouldRepaint(_StripesPainter old) => false;
}
