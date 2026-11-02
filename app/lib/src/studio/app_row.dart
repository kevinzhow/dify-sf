/// The Studio's phone row for an app (mockup 1): the app's icon with its mode badge, the name and "type · edited
/// time", and a "…" button that opens the app's operations as an action sheet (a long press opens it too). A tap
/// opens the app as a card does. A dify-sf divergence: Dify's Studio is a card grid with hover actions.
library;

import 'dart:async';

import 'package:collab_client/collab_client.dart';
import 'package:flutter/widgets.dart';

import '../design/dify_icon.dart';
import '../design/dify_tokens.g.dart';
import '../design/widgets/widgets.dart';
import '../i18n/dify_i18n.dart';
import '../workflow_editor/header/format.dart' show formatDateFields;
import 'app_actions.dart';
import 'app_card.dart' show appModeLabel;
import 'app_icons.dart';
import 'studio_scope.dart';

String _a(String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr('app', key, params);
String _c(String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr('common', key, params);

/// The row's short edit time: "Edited at" and the time today, the month and day this year, else the date.
String appEditTimeShort(AppInfo app, {DateTime? now}) {
  final ts = app.updatedAt != 0 ? app.updatedAt : app.createdAt;
  if (ts == 0) return '';
  final d = DateTime.fromMillisecondsSinceEpoch(ts * 1000), today = now ?? DateTime.now();
  final format = d.year != today.year
      ? 'YYYY-MM-DD'
      : d.month == today.month && d.day == today.day
      ? 'HH:mm'
      : 'MM-DD';
  return '${DifyI18n.tr('dataset-documents', 'segment.editedAt')} ${formatDateFields(d, format)}';
}

/// One app of the phone Studio.
class AppListRow extends StatefulWidget {
  const AppListRow({super.key, required this.app});

  final AppInfo app;

  @override
  State<AppListRow> createState() => _AppListRowState();
}

class _AppListRowState extends State<AppListRow> with StudioAppActions<AppListRow> {
  @override
  AppInfo get app => widget.app;

  /// The operations, like the card's More menu, with the star toggle (the card's hover bar) first.
  void _showActions(AppOperations ops) {
    final app = this.app;
    final star = app.isStarred ? _c('mobile.unstarApp') : _a('studio.starApp');
    unawaited(
      showDifyActionSheet(
        context,
        title: app.name,
        actions: [
          DifyActionSheetAction(
            label: star,
            icon: const RemixIcon('star-line', size: 20),
            enabled: !togglingStar,
            onTap: () => unawaited(toggleStar(!app.isStarred)),
          ),
          if (ops.edit)
            DifyActionSheetAction(
              label: _a('editApp'),
              icon: const RemixIcon('edit-line', size: 20),
              onTap: () => unawaited(editApp()),
            ),
          if (ops.duplicate)
            DifyActionSheetAction(
              label: _a('duplicate'),
              icon: const RemixIcon('file-copy-line', size: 20),
              onTap: () => unawaited(duplicateApp()),
            ),
          if (ops.export)
            DifyActionSheetAction(
              label: _a('export'),
              icon: const RemixIcon('file-download-line', size: 20),
              enabled: !exporting,
              onTap: () => unawaited(exportApp()),
            ),
          if (ops.delete)
            DifyActionSheetAction(
              label: _c('operation.delete'),
              icon: const RemixIcon('delete-bin-line', size: 20),
              destructive: true,
              onTap: () => unawaited(deleteApp()),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    services = StudioScope.of(context);
    final previewOnly = hasOnlyAppPreviewPermission(app.permissionKeys);
    final ops = AppOperations.of(app, services);
    final edited = appEditTimeShort(app);
    final more = _c('operation.moreActionsFor', {'name': app.name});
    return Opacity(
      opacity: previewOnly ? 0.6 : 1,
      child: DifyListRow(
        key: ValueKey('app-row-${app.id}'),
        leading: _RowIcon(app: app),
        title: app.name,
        subtitle: [appModeLabel(app.mode), if (edited.isNotEmpty) edited].join(' · '),
        strong: true,
        onTap: previewOnly
            ? () => toast.warning(_a('noAccessResourcePermission'))
            : () => unawaited(services.open(app)),
        onLongPress: previewOnly ? null : () => _showActions(ops),
        actions: [
          if (!previewOnly)
            DifyTouchIconButton(
              key: ValueKey('app-row-more-${app.id}'),
              label: exporting ? _c('operation.exporting') : more,
              disabled: exporting,
              icon: exporting
                  ? DifySpinner(color: DifyColors.textTertiary, size: 20)
                  : RemixIcon('more-fill', size: 20, color: DifyColors.textTertiary),
              onPressed: () => _showActions(ops),
            ),
        ],
      ),
    );
  }
}

/// The app's 44 px icon (`rounded-xl`) with the mode badge at its bottom right, as on the cards.
class _RowIcon extends StatelessWidget {
  const _RowIcon({required this.app});
  final AppInfo app;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: 44,
    child: Stack(
      clipBehavior: Clip.none,
      children: [
        Center(
          child: DifyAppIcon(
            size: DifyAppIconSize.large,
            iconType: app.iconType,
            icon: app.icon,
            background: app.iconBackground,
            imageUrl: app.iconUrl,
          ),
        ),
        Positioned(
          right: -1,
          bottom: -1,
          child: AppTypeIcon(type: app.mode, box: 16, iconSize: 12, shadow: true),
        ),
      ],
    ),
  );
}

/// A pulsing row while the first page loads (the card skeleton's parts in a row).
class AppListRowSkeleton extends StatelessWidget {
  const AppListRowSkeleton({super.key});

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: DecoratedBox(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: DifyColors.dividerSubtle)),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: DifyListRow.minHeightWithSubtitle),
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: DifySkeletonRow(
            children: [
              DifySkeletonRectangle(width: 40, height: 40, radius: DifyRadius.lg, pulse: true),
              Expanded(
                child: DifySkeletonContainer(
                  children: [
                    DifySkeletonRectangle(widthFactor: 2 / 3, height: 16, pulse: true),
                    DifySkeletonRectangle(widthFactor: 1 / 3, height: 12, pulse: true),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
