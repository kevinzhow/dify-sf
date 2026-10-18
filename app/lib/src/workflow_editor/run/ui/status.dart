/// The run panels' status pieces: run/status-container.tsx (the tinted, lined box), run/status.tsx (status, time and
/// tokens of a run or node, its error, partial success, pause reasons) and run/meta.tsx (the metadata table).
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import '../../../cards/card_kit.dart';
import '../../../design/css_metrics.dart';
import '../../../design/dify_tokens.g.dart';
import '../../../i18n/dify_i18n.dart';
import '../../header/format.dart' as fmt;
import '../../node_panel/bodies/llm/model_selector.dart' show StatusDot, StatusDotKind;
import '../../variable_inspect/panel.dart' show CopyFeedback;

String _tw(String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr('workflow', key, params);
String _tr(String key) => DifyI18n.tr('run-log', key);

/// The status look: border, background, line colour (the bg-line-*.svg stroke), text colour, inset glow colour.
({Color border, Color bg, Color line, Color text, Color glow})? _look(String status) => switch (status) {
  'succeeded' || 'partial-succeeded' => (
    border: const Color(0xCC17B26A),
    bg: DifyColors.workflowDisplaySuccessBg,
    line: const Color(0xFF17B26A),
    text: DifyColors.textSuccess,
    glow: const Color(0x3317B26A),
  ),
  'failed' => (
    border: const Color(0xCCF04438),
    bg: DifyColors.workflowDisplayErrorBg,
    line: const Color(0xFFF04438),
    text: DifyColors.textWarning,
    glow: const Color(0x33F04438),
  ),
  'stopped' || 'paused' || 'exception' => (
    border: const Color(0xCCF79009),
    bg: DifyColors.workflowDisplayWarningBg,
    line: const Color(0xFFF79009),
    text: DifyColors.textDestructive,
    glow: const Color(0x33F79009),
  ),
  'running' => (
    border: const Color(0xCC0BA5EC),
    bg: DifyColors.workflowDisplayNormalBg,
    line: const Color(0xFF0BA5EC),
    text: DifyColors.utilColorsBlueLightBlueLight600,
    glow: const Color(0x330BA5EC),
  ),
  _ => null,
};

/// StatusContainer: `rounded-lg border px-3 py-2.5 system-xs-regular break-all` in the status's colours, with the
/// light theme's inset shadows, the 2 px line pattern and the top-left highlight. [copyContent] adds a copy button at
/// the top right (shown on hover, as Dify's `group-hover`; always on touch).
class StatusContainer extends StatefulWidget {
  const StatusContainer({super.key, required this.status, required this.child, this.copyContent});
  final String status;
  final Widget child;
  final String? copyContent;

  @override
  State<StatusContainer> createState() => _StatusContainerState();
}

class _StatusContainerState extends State<StatusContainer> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final look = _look(widget.status);
    final copyable = widget.copyContent != null;
    final r = BorderRadius.circular(DifyRadius.lg);
    final body = Container(
      padding: EdgeInsets.fromLTRB(12, 10, copyable && _hover ? 40 : 12, 10),
      decoration: BoxDecoration(
        color: look?.bg,
        borderRadius: r,
        border: Border.all(color: look?.border ?? DifyColors.workflowDisplayDisabledBorder1),
        boxShadow: look == null
            ? null
            : const [
                BoxShadow(offset: Offset(0, 1), blurRadius: 1.7321, color: Color(0x0D09090B)),
                BoxShadow(spreadRadius: 1, color: Color(0x0D000000)),
              ],
      ),
      foregroundDecoration: null,
      child: CustomPaint(
        painter: look == null ? null : _StatusBackgroundPainter(look.line, look.glow),
        child: DefaultTextStyle.merge(
          style: difyStyle(DifyType.systemXsRegular, look?.text ?? DifyColors.textPrimary),
          child: widget.child,
        ),
      ),
    );
    return Semantics(
      container: true,
      liveRegion: true,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: Stack(
          children: [
            body,
            if (copyable && _hover) Positioned(top: 6, right: 6, child: CopyFeedback(content: widget.copyContent!)),
          ],
        ),
      ),
    );
  }
}

/// The status box's background art, painted inside its padding box: the inset glow (`inset 0 2px 24px <colour>`, the
/// white top-left `inset 2px 2px 0` and the dark `inset 0 1px 3px`), the line pattern (0.5 px lines every 2 px at
/// 15 % of the status colour) and the highlight (237 x 50, white 12 % → 50 % at half opacity, clipped to 65 % width).
class _StatusBackgroundPainter extends CustomPainter {
  _StatusBackgroundPainter(this.line, this.glow);
  final Color line, glow;

  @override
  void paint(Canvas canvas, Size size) {
    // The decoration's padding box: the painter covers the content box, so reach back over the padding.
    final box = Rect.fromLTRB(-12, -10, size.width + 12, size.height + 10);
    final rrect = RRect.fromRectAndRadius(box, const Radius.circular(DifyRadius.lg - 1));
    canvas
      ..save()
      ..clipRRect(rrect);
    final lines = Paint()
      ..color = line.withValues(alpha: 0.15)
      ..strokeWidth = 0.5;
    for (var y = box.top; y <= box.bottom; y += 2) {
      canvas.drawLine(Offset(box.left, y), Offset(box.right, y), lines);
    }
    void inset(Offset offset, double blur, Color color) {
      final hole = rrect.shift(offset);
      final path = Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(box.inflate(blur * 2 + 20))
        ..addRRect(hole);
      final paint = Paint()..color = color;
      if (blur > 0) paint.maskFilter = MaskFilter.blur(BlurStyle.normal, blur / 2);
      canvas.drawPath(path, paint);
    }

    inset(const Offset(0, 2), 24, glow);
    inset(const Offset(0, 1), 3, const Color(0x1F000000));
    inset(const Offset(2, 2), 0, const Color(0x80FFFFFF));
    // highlight.svg at the top left, `w-[65%] h-12.5`, no repeat.
    canvas
      ..save()
      ..clipRect(Rect.fromLTWH(box.left, box.top, box.width * 0.65, 50));
    final h = Path()
      ..moveTo(box.left, box.top + 8)
      ..arcToPoint(Offset(box.left + 8, box.top), radius: const Radius.circular(8))
      ..lineTo(box.left + 237, box.top)
      ..lineTo(box.left + 215.033, box.top + 50)
      ..lineTo(box.left + 8, box.top + 50)
      ..arcToPoint(Offset(box.left, box.top + 42), radius: const Radius.circular(8))
      ..close();
    canvas.drawPath(
      h,
      Paint()
        ..shader = LinearGradient(
          colors: const [Color(0x0FFFFFFF), Color(0x40FFFFFF)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ).createShader(Rect.fromLTWH(box.left, box.top, 168, 23)),
    );
    canvas
      ..restore()
      ..restore();
  }

  @override
  bool shouldRepaint(_StatusBackgroundPainter old) => old.line != line || old.glow != glow;
}

/// `animate-pulse` (opacity 1 → 0.5 → 1, 2 s) around [child].
class Pulse extends StatefulWidget {
  const Pulse({super.key, required this.child});
  final Widget child;

  @override
  State<Pulse> createState() => _PulseState();
}

class _PulseState extends State<Pulse> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(seconds: 2))..repeat();
  late final _opacity = TweenSequence([
    TweenSequenceItem(
      tween: Tween(begin: 1.0, end: 0.5).chain(CurveTween(curve: const Cubic(0.4, 0, 0.6, 1))),
      weight: 1,
    ),
    TweenSequenceItem(
      tween: Tween(begin: 0.5, end: 1.0).chain(CurveTween(curve: const Cubic(0.4, 0, 0.6, 1))),
      weight: 1,
    ),
  ]).animate(_c);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(opacity: _opacity, child: widget.child);
}

/// A skeleton bar: `h-2 rounded-xs bg-text-quaternary` [width] wide, pulsing unless [still].
class SkeletonBar extends StatelessWidget {
  const SkeletonBar({super.key, required this.width, this.still = false, this.margin = EdgeInsets.zero});
  final double width;
  final bool still;
  final EdgeInsets margin;

  @override
  Widget build(BuildContext context) {
    final bar = Container(
      width: width,
      height: 8,
      margin: margin,
      decoration: BoxDecoration(
        color: DifyColors.textQuaternary,
        borderRadius: BorderRadius.circular(DifyRadius.xs),
      ),
    );
    return still ? bar : Pulse(child: bar);
  }
}

/// The paused run's details (`useWorkflowPausedDetails`): the paused nodes' `pause_type`s.
typedef PausedDetailsFetcher = Future<List<Map<String, Object?>>> Function(String workflowRunId);

/// StatusPanel (status.tsx): STATUS / ELAPSED TIME / TOTAL TOKENS in a [StatusContainer]; a failed run's error (and
/// partial-success tip), a partial success's tip with the Tracing link, an exception's error and "Learn more", a paused
/// run's reasons and backstage input URLs (fetched with [fetchPausedDetails]).
class StatusPanel extends StatefulWidget {
  const StatusPanel({
    super.key,
    required this.status,
    this.time,
    this.tokens,
    this.error,
    this.exceptionCounts,
    this.isListening = false,
    this.workflowRunId,
    this.onOpenTracingTab,
    this.fetchPausedDetails,
    this.onOpenUrl,
  });

  final String status;
  final num? time;
  final num? tokens;
  final String? error;
  final int? exceptionCounts;
  final bool isListening;
  final String? workflowRunId;
  final VoidCallback? onOpenTracingTab;
  final PausedDetailsFetcher? fetchPausedDetails;
  final ValueChanged<String>? onOpenUrl;

  @override
  State<StatusPanel> createState() => _StatusPanelState();
}

class _StatusPanelState extends State<StatusPanel> {
  List<Map<String, Object?>>? _pausedNodes;
  String? _fetchedFor;

  @override
  void initState() {
    super.initState();
    _fetchPaused();
  }

  @override
  void didUpdateWidget(StatusPanel old) {
    super.didUpdateWidget(old);
    _fetchPaused();
  }

  void _fetchPaused() {
    final fetch = widget.fetchPausedDetails;
    final id = widget.workflowRunId ?? '';
    if (widget.status != 'paused' || fetch == null || _fetchedFor == id) return;
    _fetchedFor = id;
    fetch(id).then((nodes) {
      if (mounted) setState(() => _pausedNodes = nodes);
    }, onError: (Object _) {});
  }

  Iterable<Map<String, Object?>> get _humanInputs => (_pausedNodes ?? const []).where(
    (n) => (n['pause_type'] as Map?)?['type'] == 'human_input',
  );

  Widget _label(String key) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: DifyText(_tr(key), DifyType.system2xsMediumUppercase, color: DifyColors.textTertiary),
  );

  Widget _divider(Color color) => Container(height: 0.5, margin: const EdgeInsets.symmetric(vertical: 8), color: color);

  Widget? _partialSucceededTip(DifyTextStyle style, Color color) {
    final n = widget.exceptionCounts ?? 0;
    if (n == 0) return null;
    // `nodes.common.errorHandle.partialSucceeded.tip`: "There are {{num}} nodes in the process running abnormally,
    // please go to <tracingLink>tracing</tracingLink> to check the logs."
    final raw = _tw('nodes.common.errorHandle.partialSucceeded.tip', {'num': n});
    final m = RegExp(r'<tracingLink>(.*?)</tracingLink>').firstMatch(raw);
    final base = difyStyle(style, color);
    if (m == null) return Text(raw, style: base);
    return Text.rich(
      TextSpan(
        style: base,
        children: [
          TextSpan(text: raw.substring(0, m.start)),
          TextSpan(
            text: m.group(1),
            style: widget.onOpenTracingTab == null ? null : const TextStyle(color: DifyColors.textAccent),
            recognizer: widget.onOpenTracingTab == null
                ? null
                : (TapGestureRecognizer()..onTap = widget.onOpenTracingTab),
            mouseCursor: widget.onOpenTracingTab == null ? null : SystemMouseCursors.click,
          ),
          TextSpan(text: raw.substring(m.end)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.status;
    final running = s == 'running' || s == 'paused';
    final (Color statusColor, StatusDotKind? dot, String? label) = switch (s) {
      'running' => (DifyColors.utilColorsBlueLightBlueLight600, null, widget.isListening ? 'Listening' : 'Running'),
      'succeeded' => (DifyColors.utilColorsGreenGreen600, StatusDotKind.success, 'SUCCESS'),
      'partial-succeeded' => (DifyColors.utilColorsGreenGreen600, StatusDotKind.success, 'PARTIAL SUCCESS'),
      'exception' => (DifyColors.textSecondary, StatusDotKind.warning, 'EXCEPTION'),
      'failed' => (DifyColors.utilColorsRedRed600, StatusDotKind.error, 'FAIL'),
      'stopped' => (DifyColors.utilColorsWarningWarning600, StatusDotKind.warning, 'STOP'),
      'paused' => (DifyColors.utilColorsWarningWarning600, StatusDotKind.warning, 'PENDING'),
      _ => (DifyColors.textSecondary, null, null),
    };
    final valueStyle = difyStyle(DifyType.systemSmMedium, DifyColors.textSecondary);
    final reasons = [if (_humanInputs.isNotEmpty) _tw('nodes.humanInput.log.reasonContent')];
    final urls = [for (final n in _humanInputs) '${(n['pause_type'] as Map)['backstage_input_url'] ?? ''}'];
    return StatusContainer(
      status: s,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Flexible(
                child: ConstrainedBox(
                  // `max-w-30` with `min-w-35` for a partial success: CSS lets the minimum win.
                  constraints: s == 'partial-succeeded'
                      ? const BoxConstraints(minWidth: 140, maxWidth: 140)
                      : const BoxConstraints(maxWidth: 120),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _label('resultPanel.status'),
                      if (label != null)
                        Row(
                          spacing: 4,
                          children: [
                            if (s == 'running')
                              const StatusDot(status: StatusDotKind.normal)
                            else if (dot != null)
                              StatusDot(status: dot),
                            Flexible(
                              child: DifyText(
                                label,
                                // `system-xs-semibold-uppercase`, but "Running"/"Listening" keep their case.
                                s == 'running' ? DifyType.systemXsSemibold : DifyType.systemXsSemiboldUppercase,
                                color: statusColor,
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
              ),
              Flexible(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 152),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _label('resultPanel.time'),
                      SizedBox(
                        height: 20,
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: running
                              ? const SkeletonBar(width: 64)
                              : Text(
                                  (widget.time ?? 0) != 0 ? '${widget.time!.toStringAsFixed(3)}s' : '-',
                                  style: valueStyle,
                                ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _label('resultPanel.tokens'),
                    SizedBox(
                      height: 20,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: running
                            ? const SkeletonBar(width: 80)
                            : Text('${(widget.tokens ?? 0) == 0 ? 0 : widget.tokens} Tokens', style: valueStyle),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (s == 'failed' && (widget.error ?? '').isNotEmpty) ...[
            _divider(DifyColors.dividerSubtle),
            DifyText(widget.error!, DifyType.systemXsRegular, color: DifyColors.textDestructive, maxLines: null),
            if ((widget.exceptionCounts ?? 0) != 0) ...[
              _divider(DifyColors.dividerSubtle),
              _partialSucceededTip(DifyType.systemXsRegular, DifyColors.textDestructive)!,
            ],
          ],
          if (s == 'partial-succeeded' && (widget.exceptionCounts ?? 0) != 0) ...[
            _divider(DifyColors.dividerDeep),
            _partialSucceededTip(DifyType.systemXsMedium, DifyColors.textWarning)!,
          ],
          if (s == 'exception') ...[
            _divider(DifyColors.dividerDeep),
            Text.rich(
              TextSpan(
                style: difyStyle(DifyType.systemXsMedium, DifyColors.textWarning),
                children: [
                  TextSpan(text: widget.error ?? ''),
                  TextSpan(
                    text: _tw('common.learnMore'),
                    style: const TextStyle(color: DifyColors.textAccent),
                    recognizer: widget.onOpenUrl == null
                        ? null
                        : (TapGestureRecognizer()
                            ..onTap = () => widget.onOpenUrl!('https://docs.dify.ai/use-dify/debug/error-type')),
                  ),
                ],
              ),
            ),
          ],
          if (s == 'paused') ...[
            _divider(DifyColors.dividerDeep),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 8,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 2,
                  children: [
                    DifyText(
                      _tw('nodes.humanInput.log.reason'),
                      DifyType.system2xsMediumUppercase,
                      color: DifyColors.textTertiary,
                    ),
                    if (reasons.isNotEmpty)
                      for (final r in reasons) DifyText(r, DifyType.systemXsMedium, color: DifyColors.textSecondary)
                    else
                      const SkeletonBar(width: 80),
                  ],
                ),
                if (urls.isNotEmpty)
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: 2,
                    children: [
                      DifyText(
                        _tw('nodes.humanInput.log.backstageInputURL'),
                        DifyType.system2xsMediumUppercase,
                        color: DifyColors.textTertiary,
                      ),
                      for (final u in urls)
                        GestureDetector(
                          onTap: () => widget.onOpenUrl?.call(u),
                          child: DifyText(u, DifyType.systemXsMedium, color: DifyColors.textAccent, maxLines: null),
                        ),
                    ],
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// RunMetaData (meta.tsx): METADATA, then Status, Executor, Start Time, Elapsed Time, Total Tokens and (with [showSteps])
/// Run Steps, with skeleton bars while running.
class RunMetaData extends StatelessWidget {
  const RunMetaData({
    super.key,
    required this.status,
    this.executor,
    this.startTime,
    this.time,
    this.tokens,
    this.steps = 1,
    this.showSteps = true,
    this.formatTime,
  });

  final String status;
  final String? executor;

  /// Seconds.
  final int? startTime;
  final num? time;
  final num? tokens;
  final int? steps;
  final bool showSteps;

  /// `useTimestamp().formatTime(seconds, format)`; the app's local time format by default.
  final String Function(int seconds, String format)? formatTime;

  @override
  Widget build(BuildContext context) {
    final running = status == 'running';
    final valueStyle = difyStyle(DifyType.systemXsRegular, DifyColors.textSecondary);
    Widget row(String key, Widget value) => Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 104,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: DifyText(_tr(key), DifyType.systemXsRegular, color: DifyColors.textTertiary),
          ),
        ),
        Expanded(
          child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6), child: value),
        ),
      ],
    );
    Widget text(String s) => Text(s, style: valueStyle, strutStyle: Css.lineStrut(valueStyle));
    Widget bar(double w, {bool pulse = false}) => Align(
      alignment: Alignment.centerLeft,
      child: SkeletonBar(width: w, still: !pulse, margin: const EdgeInsets.symmetric(vertical: 4)),
    );
    final statusText = switch (status) {
      'succeeded' => 'SUCCESS',
      'partial-succeeded' => 'PARTIAL SUCCESS',
      'exception' => 'EXCEPTION',
      'failed' => 'FAIL',
      'stopped' => 'STOP',
      'paused' => 'PENDING',
      _ => null,
    };
    final format = formatTime ?? _formatTime;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 24,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: DifyText(_tr('meta.title'), DifyType.systemXsMediumUppercase, color: DifyColors.textTertiary),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            children: [
              row(
                'meta.status',
                running ? bar(64) : (statusText == null ? const SizedBox(height: 16) : text(statusText)),
              ),
              row('meta.executor', running ? bar(88) : text(executor?.isNotEmpty == true ? executor! : 'N/A')),
              row(
                'meta.startTime',
                running
                    ? bar(72)
                    : text(
                        (startTime ?? 0) != 0 ? format(startTime!, DifyI18n.tr('app-log', 'dateTimeFormat')) : '-',
                      ),
              ),
              row('meta.time', running ? bar(72) : text((time ?? 0) != 0 ? '${time!.toStringAsFixed(3)}s' : '-')),
              row(
                'meta.tokens',
                status == 'running' || status == 'paused'
                    ? bar(48, pulse: true)
                    : text('${(tokens ?? 0) == 0 ? 0 : tokens} Tokens'),
              ),
              if (showSteps) row('meta.steps', running ? bar(24) : text('${steps ?? 1}')),
            ],
          ),
        ),
      ],
    );
  }
}

/// dayjs's `format` for the tokens Dify's date-time formats use (`YYYY MM DD HH hh mm ss A`); the translation key
/// itself when the app-log namespace is missing (as Dify's test i18n returns keys).
String _formatTime(int seconds, String format) => fmt.formatTime(seconds, format);
