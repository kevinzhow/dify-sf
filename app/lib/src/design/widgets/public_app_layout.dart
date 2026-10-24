/// Published web app chrome, from Dify 1.17.1's share/text-generation and
/// base/chat/chat-with-history. Runtime and form state remain with the caller.
library;

import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';

import '../dify_icon.dart';
import '../dify_tokens.g.dart';
import '../../i18n/dify_i18n.dart';
import 'widgets.dart';

/// The public workflow's 600px (at most half the desktop) input sidebar and
/// remaining result area. The mobile page stacks scrollable content instead.
class DifyPublicWorkflowLayout extends StatelessWidget {
  const DifyPublicWorkflowLayout({
    super.key,
    required this.header,
    required this.tabs,
    required this.inputs,
    required this.actions,
    required this.result,
    required this.footer,
    this.hasResult = false,
  });
  final Widget header, tabs, inputs, actions, result, footer;
  final bool hasResult;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final desktop = constraints.maxWidth >= 1024;
      final padding = desktop ? 32.0 : 16.0;
      final form = ColoredBox(
        color: DifyColors.componentsPanelBg,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: EdgeInsets.fromLTRB(padding, padding, padding, 0),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: DifyColors.dividerSubtle)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 16,
                children: [
                  header,
                  DifyToolbarStrip(child: tabs),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: EdgeInsets.symmetric(horizontal: padding),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    inputs,
                    Padding(padding: const EdgeInsets.symmetric(vertical: 24), child: actions),
                  ],
                ),
              ),
            ),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: padding - 12),
              child: footer,
            ),
          ],
        ),
      );
      final output = DecoratedBox(
        decoration: BoxDecoration(gradient: DifyGradients.chatbotBg),
        child: result,
      );
      if (desktop) {
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              key: const Key('public-workflow-inputs'),
              width: math.min(600, constraints.maxWidth / 2),
              child: form,
            ),
            Expanded(key: const Key('public-workflow-result'), child: output),
          ],
        );
      }
      return Column(
        children: [
          Expanded(child: form),
          if (hasResult) Expanded(child: output),
        ],
      );
    },
  );
}

/// Chat's 236px navigation and inset, rounded conversation area. The sidebar
/// can collapse on desktop; compact pages retain a keyboard-safe composer.
class DifyPublicChatLayout extends StatefulWidget {
  const DifyPublicChatLayout({
    super.key,
    required this.header,
    required this.newChat,
    required this.body,
    required this.composer,
    required this.footer,
  });
  final Widget header, newChat, body, composer, footer;
  @override
  State<DifyPublicChatLayout> createState() => _DifyPublicChatLayoutState();
}

class _DifyPublicChatLayoutState extends State<DifyPublicChatLayout> {
  bool collapsed = false;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final mobile = constraints.maxWidth < 768;
      final navigation = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
            child: Row(
              spacing: 12,
              children: [
                Expanded(child: widget.header),
                if (!mobile)
                  DifyIconButton(
                    label: DifyI18n.tr('layout', 'sidebar.collapseSidebar'),
                    onPressed: () => setState(() => collapsed = true),
                    icon: const RemixIcon('layout-left-2-line'),
                  ),
              ],
            ),
          ),
          Padding(padding: const EdgeInsets.fromLTRB(16, 16, 12, 16), child: widget.newChat),
          if (!mobile) const Spacer(),
          if (!mobile) Padding(padding: const EdgeInsets.only(right: 12), child: widget.footer),
        ],
      );
      final conversation = Padding(
        padding: mobile ? EdgeInsets.zero : const EdgeInsets.all(8),
        child: ClipRRect(
          borderRadius: BorderRadius.vertical(top: const Radius.circular(16), bottom: Radius.circular(mobile ? 0 : 16)),
          child: DecoratedBox(
            decoration: BoxDecoration(gradient: DifyGradients.chatbotBg),
            child: Column(
              children: [
                if (!mobile)
                  SizedBox(
                    height: 56,
                    child: collapsed
                        ? Align(
                            alignment: Alignment.centerLeft,
                            child: DifyIconButton(
                              label: DifyI18n.tr('layout', 'sidebar.expandSidebar'),
                              onPressed: () => setState(() => collapsed = false),
                              icon: const RemixIcon('layout-left-2-line'),
                            ),
                          )
                        : null,
                  ),
                Expanded(child: widget.body),
                Align(
                  alignment: Alignment.bottomCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 768),
                    child: Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), child: widget.composer),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      if (mobile) {
        return Column(
          children: [
            navigation,
            Expanded(child: conversation),
          ],
        );
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!collapsed) SizedBox(key: const Key('public-chat-sidebar'), width: 236, child: navigation),
          Expanded(child: conversation),
        ],
      );
    },
  );
}

/// The public chat composer uses the shared undecorated text field inside the
/// product's panel surface, so Material input density cannot change its line box.
class DifyPublicChatComposer extends StatefulWidget {
  const DifyPublicChatComposer({
    super.key,
    required this.value,
    required this.onChanged,
    required this.action,
    this.placeholder,
    this.disabled = false,
    this.onSubmitted,
  });
  final String value;
  final String? placeholder;
  final bool disabled;
  final ValueChanged<String> onChanged;
  final VoidCallback? onSubmitted;
  final Widget action;
  @override
  State<DifyPublicChatComposer> createState() => _DifyPublicChatComposerState();
}

class _DifyPublicChatComposerState extends State<DifyPublicChatComposer>
    with DifyControlledText<DifyPublicChatComposer> {
  final focus = FocusNode();
  @override
  String textOf(DifyPublicChatComposer widget) => widget.value;
  @override
  void didUpdateWidget(DifyPublicChatComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    syncText();
  }

  @override
  void dispose() {
    focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(8),
    decoration: BoxDecoration(
      color: DifyColors.componentsPanelBg,
      borderRadius: BorderRadius.circular(12),
      boxShadow: DifyShadows.md,
    ),
    child: Row(
      spacing: 8,
      children: [
        Expanded(
          child: difyTextField(
            context: context,
            controller: controller,
            focusNode: focus,
            style: difyTextStyle(DifyType.systemMdRegular, DifyColors.textPrimary),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            placeholder: widget.placeholder,
            disabled: widget.disabled,
            onChanged: widget.onChanged,
            onSubmitted: (_) {
              if (!widget.disabled) widget.onSubmitted?.call();
            },
            textInputAction: TextInputAction.send,
          ),
        ),
        widget.action,
      ],
    ),
  );
}
