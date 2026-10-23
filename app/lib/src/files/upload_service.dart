import 'package:collab_client/collab_client.dart';

import '../auth/auth_controller.dart';
import '../design/widgets/app_icon_picker.dart';

/// The shared image host callback. Native and web both upload through the authenticated console API.
UploadAppIcon? appIconUploader(AuthController auth) {
  if (!auth.systemFeatures.fileUpload || !auth.signedIn) return null;
  return (file) async {
    final api = HttpFilesApi(Uri.parse(auth.server), auth: auth.session);
    try {
      final uploaded = await api.upload(file.bytes, filename: file.name);
      final url = uploaded.previewUrl;
      if (url == null || url.isEmpty) throw const TransportException('uploaded image has no preview URL');
      return (fileId: uploaded.id, url: url);
    } finally {
      api.close();
    }
  };
}
