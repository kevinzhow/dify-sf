import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';

import '../../../design/dify_icon.dart';
import '../../../design/dify_tokens.g.dart';
import '../../../design/widgets/widgets.dart';
import '../../../i18n/dify_i18n.dart';
import '../hotkey.dart';
import 'suggested_action.dart';
import 'utils.dart';

String _w(String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr('workflow', key, params);

/// The published version the summary describes (Dify's WorkflowResponse: `id`, `created_at` in seconds,
/// `marked_name`, `marked_comment`, `version_number`, `created_by.name`).
@immutable
class PublishedWorkflowInfo {
  const PublishedWorkflowInfo({
    required this.id,
    required this.createdAt,
    this.markedName = '',
    this.markedComment = '',
    this.versionNumber,
    this.createdByName,
  });

  /// From Dify's WorkflowResponse JSON.
  factory PublishedWorkflowInfo.fromJson(Map<String, Object?> json) => PublishedWorkflowInfo(
    id: '${json['id'] ?? ''}',
    createdAt: (json['created_at'] as num?)?.toInt() ?? 0,
    markedName: json['marked_name'] as String? ?? '',
    markedComment: json['marked_comment'] as String? ?? '',
    versionNumber: (json['version_number'] as num?)?.toInt(),
    createdByName: switch (json['created_by']) {
      final Map<String, Object?> by => by['name'] as String?,
      _ => null,
    },
  );

  final String id;

  /// Seconds since the epoch.
  final int createdAt;
  final String markedName;
  final String markedComment;
  final int? versionNumber;
  final String? createdByName;
}

/// shared/timeline-marker.tsx: the dot (`size-2 rounded-full border-2 border-text-quaternary bg-components-panel-bg`)
/// and the `w-0.5 bg-divider-subtle` line linking the summary's first and last rows across the publish button.
/// [top] true: the line runs from below the dot to 14 px past the row; false: from 14 px above the row to the dot.
class PublisherTimelineRow extends StatelessWidget {
  const PublisherTimelineRow({super.key, required this.top, required this.child});

  final bool top;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final dot = SizedBox(
      width: 16,
      height: 16,
      child: Padding(
        padding: EdgeInsets.all(4),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: DifyColors.componentsPanelBg,
            shape: BoxShape.circle,
            border: Border.fromBorderSide(BorderSide(color: DifyColors.textQuaternary, width: 2)),
          ),
        ),
      ),
    );
    // Row padding: top `px-1 py-0.5`, bottom `py-0.5 pr-0.5 pl-1`; the marker is 16 px wide, its line centred.
    final line = top
        ? Positioned(left: 11, width: 2, top: 16, bottom: -12, child: ColoredBox(color: DifyColors.dividerSubtle))
        : Positioned(
            left: 11,
            width: 2,
            top: -12,
            height: 16,
            child: ColoredBox(color: DifyColors.dividerSubtle),
          );
    return Stack(
      clipBehavior: Clip.none,
      children: [
        line,
        Padding(
          padding: top ? const EdgeInsets.symmetric(horizontal: 4, vertical: 2) : const EdgeInsets.fromLTRB(4, 2, 2, 2),
          child: Row(
            crossAxisAlignment: top ? CrossAxisAlignment.start : CrossAxisAlignment.center,
            spacing: 4,
            children: [
              dot,
              Expanded(child: child),
            ],
          ),
        ),
      ],
    );
  }
}

/// built-in-publisher/summary-section.tsx: the latest published version (its name, notes and time for workflow
/// apps), the publish button with its `Mod+Shift+P` keycaps (and the trigger-limit upgrade hint), and the draft's
/// state. [published] is the open session's lock: publish and restore stay disabled after publishing.
class PublisherSummarySection extends StatelessWidget {
  const PublisherSummarySection({
    super.key,
    this.draftUpdatedAt,
    required this.formatTimeFromNow,
    required this.onPublish,
    required this.onRestore,
    required this.isChatApp,
    this.isWorkflowApp = false,
    this.onEditVersion,
    this.publishDisabled = false,
    required this.published,
    this.publishedAt,
    this.startNodeLimitExceeded = false,
    this.versionInfo,
  });

  final int? draftUpdatedAt;
  final String Function(int milliseconds) formatTimeFromNow;
  final VoidCallback onPublish;
  final VoidCallback onRestore;
  final bool isChatApp;
  final bool isWorkflowApp;
  final VoidCallback? onEditVersion;
  final bool publishDisabled;
  final bool published;

  /// Milliseconds.
  final int? publishedAt;
  final bool startNodeLimitExceeded;
  final PublishedWorkflowInfo? versionInfo;

  @override
  Widget build(BuildContext context) {
    final hasPublishedVersion = publishedAt != null && publishedAt != 0;
    final publishedTimestamp = hasPublishedVersion
        ? publishedAt
        : (versionInfo != null && versionInfo!.createdAt != 0 ? versionInfo!.createdAt * 1000 : null);
    final buttonDisabled = publishDisabled || published;
    final buttonLabel = published
        ? _w('common.published')
        : hasPublishedVersion
        ? _w('common.publishUpdate')
        : _w('common.publish');
    final tertiary = difyTextStyle(DifyType.systemXsRegular, DifyColors.textTertiary);

    Widget? publishedLine({bool truncate = false}) {
      if (publishedTimestamp == null) return null;
      final name = versionInfo?.createdByName;
      final time = formatTimeFromNow(publishedTimestamp);
      return Text(
        name != null && name.isNotEmpty
            ? _w('common.publishedBy', {'time': time, 'author': name})
            : '${_w('common.publishedAt')} $time',
        maxLines: truncate ? 1 : null,
        overflow: truncate ? TextOverflow.ellipsis : null,
        style: tertiary,
      );
    }

    final Widget head;
    if (!hasPublishedVersion) {
      head = Text(_w('common.notPublishedYet'), style: tertiary);
    } else if (isWorkflowApp) {
      final info = versionInfo;
      final editDisabled = info == null || onEditVersion == null;
      final named = info != null && info.markedName.isNotEmpty;
      final line = publishedLine();
      head = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 4,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 16),
            child: Row(
              spacing: 4,
              children: [
                Flexible(
                  child: Text(
                    getWorkflowVersionName(
                      markedName: info?.markedName,
                      versionNumber: info?.versionNumber,
                      defaultName: _w('versionHistory.defaultName'),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: difyTextStyle(DifyType.systemSmSemibold, DifyColors.textSecondary),
                  ),
                ),
                ExcludeSemantics(child: Text('·', style: tertiary)),
                if (named)
                  PublisherPressable(
                    label: _w('versionHistory.editVersionInfo'),
                    disabled: editDisabled,
                    onPressed: onEditVersion,
                    builder: (context, hovered, focused) => Container(
                      width: 16,
                      height: 16,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(DifyRadius.sm),
                        boxShadow: difyFocusRing(focused),
                      ),
                      child: RemixIcon(
                        'edit-line',
                        size: 14,
                        color: hovered ? DifyColors.textAccent : DifyColors.textTertiary,
                      ),
                    ),
                  )
                else
                  Flexible(
                    child: PublisherPressable(
                      label: _w('versionHistory.nameIt'),
                      disabled: editDisabled,
                      waitCursorWhenDisabled: true,
                      onPressed: onEditVersion,
                      builder: (context, hovered, focused) {
                        final color = hovered ? DifyColors.textAccentSecondary : DifyColors.textAccent;
                        return Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(DifyRadius.sm),
                            boxShadow: difyFocusRing(focused),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            spacing: 4,
                            children: [
                              RemixIcon('edit-line', size: 14, color: color),
                              Flexible(
                                child: Text(
                                  _w('versionHistory.nameIt'),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: difyTextStyle(DifyType.systemXsMedium, color),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
          if (info != null && info.markedComment.isNotEmpty) ...[
            Text(info.markedComment, maxLines: 3, overflow: TextOverflow.ellipsis, style: tertiary),
            Container(
              margin: const EdgeInsets.symmetric(vertical: 4),
              width: 16,
              height: 1,
              color: DifyColors.dividerRegular,
            ),
          ],
          ?line,
        ],
      );
    } else {
      final line = publishedLine(truncate: true);
      head = Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 8,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _w('common.latestPublished'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: difyTextStyle(DifyType.systemSmSemibold, DifyColors.textSecondary),
                ),
                ?line,
              ],
            ),
          ),
          if (isChatApp)
            DifyButton(
              size: DifyButtonSize.small,
              disabled: published,
              onPressed: onRestore,
              semanticLabel: _w('common.restore'),
              leading: const RemixIcon('reset-left-line', size: 14),
              child: Text(_w('common.restore')),
            ),
        ],
      );
    }

    final status = published
        ? (isWorkflowApp ? _w('common.published') : _w('common.upToDate'))
        : isWorkflowApp && draftUpdatedAt != null && draftUpdatedAt != 0
        ? '${_w('common.autoSaved')} · ${formatTimeFromNow(draftUpdatedAt!)}'
        : _w('common.currentDraft');

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 12,
        children: [
          PublisherTimelineRow(top: true, child: head),
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DifyButton(
                variant: DifyButtonVariant.primary,
                disabled: buttonDisabled,
                onPressed: onPublish,
                semanticLabel: buttonLabel,
                child: publishDisabled
                    ? Text(buttonLabel)
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        spacing: 4,
                        children: [
                          Flexible(child: Text(buttonLabel)),
                          DifyKbdGroup(
                            children: [
                              for (final k in appPublishHotkey.split('+'))
                                DifyKbd(formatHotkeyForDisplay(k), color: DifyKbdColor.white, disabled: buttonDisabled),
                            ],
                          ),
                        ],
                      ),
              ),
              if (startNodeLimitExceeded) const _StartNodeLimitHint(),
            ],
          ),
          PublisherTimelineRow(
            top: false,
            child: Semantics(
              container: true,
              role: SemanticsRole.status,
              child: Text(status, maxLines: 1, overflow: TextOverflow.ellipsis, style: tertiary),
            ),
          ),
        ],
      ),
    );
  }
}

/// The trigger-limit hint: `text-sm/5 font-semibold` in the upgrade gradient (constants.ts `upgradeHighlightStyle`:
/// 97deg, prompt-1 at -3.64 % to prompt-2 at 45.14 %, clipped to the text) and `mt-1 text-xs/4 text-text-secondary`.
/// Dify's UpgradeBtn (billing) below it is left out.
class _StartNodeLimitHint extends StatelessWidget {
  const _StartNodeLimitHint();

  // The gradient's colour at 0 % (its first stop lies before the box).
  static Color get _start => Color.lerp(
    DifyColors.componentsInputBorderActivePrompt1,
    DifyColors.componentsInputBorderActivePrompt2,
    3.64 / (45.14 + 3.64),
  )!;

  @override
  Widget build(BuildContext context) {
    const title = TextStyle(fontSize: 14, height: 20 / 14, fontWeight: FontWeight.w600, color: Color(0xFFFFFFFF));
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ShaderMask(
            blendMode: BlendMode.srcIn,
            shaderCallback: (rect) => CssLinearGradient(
              angle: 97,
              colors: [_start, DifyColors.componentsInputBorderActivePrompt2],
              stops: const [0, 0.4514],
            ).createShader(rect),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_w('publishLimit.startNodeTitlePrefix'), style: title),
                Text(_w('publishLimit.startNodeTitleSuffix'), style: title),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              _w('publishLimit.startNodeDesc'),
              style: TextStyle(fontSize: 12, height: 16 / 12, color: DifyColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}
