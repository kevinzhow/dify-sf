/// The generator button of node panels (the form controls they are built from live in design/widgets).
library;

import 'package:flutter/material.dart';

import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../i18n/dify_i18n.dart';

/// prompt-generator-btn.tsx / code-generator-button.tsx: `IconButton` around `Generator size-4 text-primary-600`,
/// shown whether or not a model can generate (Dify's modal then has none to pick). [onPressed] null: there is no
/// generator here, and the button says so.
class GeneratorButton extends StatelessWidget {
  const GeneratorButton({super.key, this.onPressed});
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => DifyIconButton(
    label: DifyI18n.tr('app-debug', 'operation.automatic'),
    icon: DifyIcon('vender/other/generator', size: 16, color: DifyColors.utilColorsBlueBlue600),
    onPressed: onPressed ?? () => toast.error(DifyI18n.tr('app-debug', 'noModelProviderConfigured')),
  );
}
