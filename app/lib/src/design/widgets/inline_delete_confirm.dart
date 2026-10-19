/// Dify's InlineDeleteConfirm (web/app/components/base/inline-delete-confirm).
library;

import 'package:flutter/widgets.dart';

import '../../i18n/dify_i18n.dart';
import '../dify_tokens.g.dart';
import 'widgets.dart';

/// base/inline-delete-confirm in the reply menu (`m-0 w-full border-0 shadow-none`): the title and No / Yes.
class DifyInlineDeleteConfirm extends StatelessWidget {
  const DifyInlineDeleteConfirm({super.key, required this.title, required this.onConfirm, required this.onCancel});
  final String title;
  final VoidCallback onConfirm, onCancel;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 6,
      children: [
        Text(title, style: difyTextStyle(DifyType.systemXsSemibold, DifyColors.textPrimary)),
        Row(
          spacing: 4,
          children: [
            Expanded(
              child: DifyButton(size: DifyButtonSize.small, onPressed: onCancel, child: Text(_tc('operation.no'))),
            ),
            Expanded(
              child: DifyButton(
                size: DifyButtonSize.small,
                variant: DifyButtonVariant.primary,
                tone: DifyButtonTone.destructive,
                onPressed: onConfirm,
                child: Text(_tc('operation.yes')),
              ),
            ),
          ],
        ),
      ],
    ),
  );
}

String _tc(String key) => DifyI18n.tr('common', key);
