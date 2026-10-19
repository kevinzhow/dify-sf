/// Dify's QR code (web/app/components/base/qrcode).
library;

import 'package:flutter/widgets.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../dify_tokens.g.dart';

/// The QR code of [data] as qrcode.react's QRCodeCanvas draws it: error correction level L, no margin, black modules
/// on white.
class DifyQrCode extends StatelessWidget {
  const DifyQrCode({super.key, required this.data, this.size = 160});
  final String data;
  final double size;

  @override
  Widget build(BuildContext context) => ColoredBox(
    // The code is an image, not themed: QRCodeCanvas's black modules (qr_flutter's default) on white
    // (`effects-image-frame` is white in both themes), in the dark theme too.
    color: DifyColors.effectsImageFrame,
    child: Semantics(
      image: true,
      child: SizedBox.square(
        dimension: size,
        child: CustomPaint(painter: qrPainterOf(data)),
      ),
    ),
  );
}

/// The painter behind [DifyQrCode] (also used for the PNG).
QrPainter qrPainterOf(String data) =>
    QrPainter(data: data, version: QrVersions.auto, errorCorrectionLevel: QrErrorCorrectLevel.L, gapless: true);
