import 'package:file_selector/file_selector.dart';
import 'package:flutter/widgets.dart';

import 'package:collab_client/collab_client.dart';

import '../auth/auth_controller.dart';
import '../design/widgets/app_icon_picker.dart';
import '../design/widgets/widgets.dart';
import '../i18n/dify_i18n.dart';
import '../workflow_editor/run/ui/before_run_form.dart';

/// The shared image host callback. Native and web both upload through the authenticated console API.
UploadAppIcon? appIconUploader(AuthController auth) {
  if (!auth.systemFeatures.fileUpload || !auth.signedIn) return null;
  return (file) async {
    final api = HttpFilesApi(Uri.parse(auth.server), auth: auth.session);
    try {
      final uploaded = await api.upload(file.bytes, filename: file.name);
      final url = uploaded.previewUrl;
      if (url == null || url.isEmpty) {
        throw const TransportException('uploaded image has no preview URL');
      }
      return (fileId: uploaded.id, url: url);
    } finally {
      api.close();
    }
  };
}

/// Run inputs reuse the authenticated UploadFile host; only opaque ids go back into the graph.
RunFilePicker? runtimeFilePicker(BuildContext context, AuthController? auth) {
  if (auth == null || !auth.signedIn || !auth.systemFeatures.fileUpload) {
    return null;
  }
  return runtimeFilePickerWithApi(
    context,
    () => HttpFilesApi(Uri.parse(auth.server), auth: auth.session),
    close: (api) => (api as HttpFilesApi).close(),
  );
}

/// Same picker, size validation and field mappings for a published visitor's
/// FilesApi. The caller owns the audience; it cannot borrow console credentials.
RunFilePicker runtimeFilePickerWithApi(
  BuildContext context,
  FilesApi Function() apiFor, {
  void Function(FilesApi)? close,
}) {
  return (method) async {
    try {
      if (method == TransferMethod.remoteUrl) {
        final url = await showDifyDialog<String>(
          context,
          builder: (_) => const _RuntimeFileLink(),
        );
        if (url == null) return null;
        return {
          'transferMethod': method,
          'transfer_method': method,
          'url': url,
          'name': url,
          'progress': 100,
        };
      }
      final picked = await openFile();
      if (picked == null) return null;
      final api = apiFor();
      try {
        final limits = await api.limits();
        final ext = picked.name.split('.').last.toLowerCase();
        final type = runtimeFileType(ext);
        final mib = switch (type) {
          'image' => limits.imageMiB,
          'audio' => limits.audioMiB,
          'video' => limits.videoMiB,
          _ => limits.fileMiB,
        };
        if (await picked.length() > mib * 1024 * 1024) {
          throw TransportException('File exceeds the server limit ($mib MiB)');
        }
        final uploaded = await api.upload(
          await picked.readAsBytes(),
          filename: picked.name,
        );
        return {
          'uploadedId': uploaded.id,
          'upload_file_id': uploaded.id,
          'transferMethod': method,
          'transfer_method': method,
          'supportFileType': type,
          'type': type,
          'url': uploaded.previewUrl ?? '',
          'name': uploaded.name,
          'size': uploaded.size,
          'progress': 100,
        };
      } finally {
        close?.call(api);
      }
    } on TransportException catch (e) {
      toast.error(e.message);
      return null;
    } on Object catch (e) {
      toast.error('$e');
      return null;
    }
  };
}

String runtimeFileType(String extension) {
  final ext = extension.toLowerCase();
  if (const {'jpg', 'jpeg', 'png', 'webp', 'gif', 'svg'}.contains(ext)) {
    return 'image';
  }
  if (const {'mp3', 'm4a', 'wav', 'amr', 'mpga'}.contains(ext)) return 'audio';
  if (const {'mp4', 'mov', 'mpeg', 'webm'}.contains(ext)) return 'video';
  if (const {
    'txt',
    'markdown',
    'md',
    'mdx',
    'pdf',
    'html',
    'htm',
    'xlsx',
    'xls',
    'vtt',
    'properties',
    'doc',
    'docx',
    'csv',
    'eml',
    'msg',
    'ppt',
    'pptx',
    'xml',
    'epub',
    'odt',
  }.contains(ext)) {
    return 'document';
  }
  return 'custom';
}

class _RuntimeFileLink extends StatefulWidget {
  const _RuntimeFileLink();
  @override
  State<_RuntimeFileLink> createState() => _RuntimeFileLinkState();
}

class _RuntimeFileLinkState extends State<_RuntimeFileLink> {
  String value = '';
  bool get valid {
    final uri = Uri.tryParse(value.trim());
    return uri != null &&
        const {'http', 'https'}.contains(uri.scheme) &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty;
  }

  @override
  Widget build(BuildContext context) => DifyDialogSurface(
    label: DifyI18n.tr('common', 'fileUploader.pasteFileLink'),
    width: 440,
    padding: const EdgeInsets.all(24),
    scrollable: true,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DifyTextLine(DifyI18n.tr('common', 'fileUploader.pasteFileLink')),
        const SizedBox(height: 16),
        DifyInput(
          value: value,
          placeholder: 'https://',
          onChanged: (v) => setState(() => value = v),
        ),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          spacing: 8,
          children: [
            DifyButton(
              onPressed: () => Navigator.pop(context),
              child: DifyTextLine(DifyI18n.tr('common', 'operation.cancel')),
            ),
            DifyButton(
              variant: DifyButtonVariant.primary,
              disabled: !valid,
              onPressed: () => Navigator.pop(context, value.trim()),
              child: DifyTextLine(DifyI18n.tr('common', 'operation.ok')),
            ),
          ],
        ),
      ],
    ),
  );
}
