/// `view_image` (a dify-sf extension; Dify's agent has no such tool): the
/// model looks at an image file of its workspace. The file is uploaded to
/// the Swift server as a file of the execution and attached, as a
/// `dify-sf-file:<upload_id>` reference, after the tool result. It stays in
/// the conversation: every later model call sends the same history, so the
/// request prefix stays byte-stable and the provider's prompt cache can
/// serve it (docs/agent-v2.md, "Prompt cache").
library;

import 'dart:typed_data';

/// Name of the tool.
const viewImageToolName = 'view_image';

/// Largest total size of the viewed images kept in one conversation (every
/// `view_image` of the execution, resumes and output retries included).
/// Kept images are re-sent with every model call, and the Swift gateway
/// accepts at most 6 MiB of files per model request: this half is for
/// viewed images, the other half for the task's images.
const viewImageConversationBytes = 3 * 1024 * 1024;

/// Metadata key on the attached `MediaPart`: `{"path", "detail", "size",
/// "sha256"}`. A part without `size` comes from a snapshot taken before
/// images were kept; it is never sent again.
const viewImageMetadataKey = 'dify_sf_view_image';

const viewImageDescription =
    'Look at an image file in the workspace (PNG, JPEG or WebP). The image is '
    'attached after the result and stays in the conversation, so you can '
    'refer back to it later; do not view the same image twice. All viewed '
    'images together may have at most 3 MiB per conversation: view small '
    'copies (for example a JPEG at most 1500 pixels on its longest side) '
    'rather than large renders. Use it to check renders, plots and '
    'screenshots you made with the shell.';

const viewImageInputSchema = <String, Object?>{
  'type': 'object',
  'properties': {
    'path': {
      'type': 'string',
      'description': 'Path of the image file, relative to /workspace or absolute inside it.',
    },
    'detail': {
      'type': 'string',
      'enum': ['high', 'low'],
      'description': 'Image detail for the model: "high" (default) or "low" (fewer tokens).',
    },
  },
  'required': ['path'],
  'additionalProperties': false,
};

/// The format and size of an image, from its first bytes.
typedef ImageInfo = ({String mimeType, int width, int height});

/// Reads the PNG, JPEG or WebP header of [bytes]; null when it is none of
/// them (or is truncated).
ImageInfo? imageInfo(List<int> bytes) {
  final b = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
  int be16(int i) => (b[i] << 8) | b[i + 1];
  int be32(int i) =>
      (b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3];
  int le16(int i) => b[i] | (b[i + 1] << 8);
  int le24(int i) => b[i] | (b[i + 1] << 8) | (b[i + 2] << 16);
  bool at(int i, List<int> magic) {
    if (b.length < i + magic.length) return false;
    for (var k = 0; k < magic.length; k++) {
      if (b[i + k] != magic[k]) return false;
    }
    return true;
  }

  // PNG: signature, then the IHDR chunk.
  if (at(0, const [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) &&
      at(12, 'IHDR'.codeUnits) &&
      b.length >= 24) {
    return (mimeType: 'image/png', width: be32(16), height: be32(20));
  }
  // JPEG: SOI, then segments up to a start-of-frame marker.
  if (at(0, const [0xff, 0xd8])) {
    var i = 2;
    while (i + 9 < b.length) {
      if (b[i] != 0xff) return null;
      final marker = b[i + 1];
      if (marker == 0xff) {
        i++;
        continue;
      }
      final isFrame =
          marker >= 0xc0 &&
          marker <= 0xcf &&
          marker != 0xc4 &&
          marker != 0xc8 &&
          marker != 0xcc;
      if (isFrame) {
        return (
          mimeType: 'image/jpeg',
          width: be16(i + 7),
          height: be16(i + 5),
        );
      }
      if (marker == 0xd9 || marker == 0xda) return null;
      i += 2 + be16(i + 2);
    }
    return null;
  }
  // WebP: RIFF....WEBP and a VP8, VP8L or VP8X chunk.
  if (at(0, 'RIFF'.codeUnits) && at(8, 'WEBP'.codeUnits) && b.length >= 30) {
    if (at(12, 'VP8 '.codeUnits) && at(23, const [0x9d, 0x01, 0x2a])) {
      return (
        mimeType: 'image/webp',
        width: le16(26) & 0x3fff,
        height: le16(28) & 0x3fff,
      );
    }
    if (at(12, 'VP8L'.codeUnits) && b[20] == 0x2f) {
      final bits = b[21] | (b[22] << 8) | (b[23] << 16) | (b[24] << 24);
      return (
        mimeType: 'image/webp',
        width: (bits & 0x3fff) + 1,
        height: ((bits >> 14) & 0x3fff) + 1,
      );
    }
    if (at(12, 'VP8X'.codeUnits)) {
      return (
        mimeType: 'image/webp',
        width: le24(24) + 1,
        height: le24(27) + 1,
      );
    }
  }
  return null;
}
