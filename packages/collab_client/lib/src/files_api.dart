import 'client/transport.dart';

/// Protocol 1.17: Dify's UploadFile response; no filesystem path is exposed to callers.
final class UploadedFile {
  const UploadedFile({
    required this.id,
    required this.name,
    required this.size,
    required this.extension,
    required this.mimeType,
    this.reference,
    this.previewUrl,
    this.createdBy,
    this.createdAt,
  });

  factory UploadedFile.fromJson(Map<String, Object?> m) {
    final id = m['id'], name = m['name'], size = m['size'];
    if (id is! String ||
        id.isEmpty ||
        name is! String ||
        size is! int ||
        size < 0) {
      throw const TransportException('malformed uploaded file');
    }
    return UploadedFile(
      id: id,
      name: name,
      size: size,
      extension: m['extension'] is String ? m['extension']! as String : '',
      mimeType: m['mime_type'] is String
          ? m['mime_type']! as String
          : 'application/octet-stream',
      reference: m['reference'] as String?,
      previewUrl: m['preview_url'] as String?,
      createdBy: m['created_by'] as String?,
      createdAt: m['created_at'] as int?,
    );
  }

  final String id, name, extension, mimeType;
  final int size;
  final String? reference, previewUrl, createdBy;
  final int? createdAt;
}

final class FileUploadLimits {
  const FileUploadLimits({
    required this.fileMiB,
    required this.imageMiB,
    required this.audioMiB,
    required this.videoMiB,
    required this.batchCount,
    required this.workflowCount,
  });

  factory FileUploadLimits.fromJson(Map<String, Object?> m) {
    int number(String key) {
      final v = m[key];
      if (v is! int || v < 0) {
        throw const TransportException('malformed upload limits');
      }
      return v;
    }

    return FileUploadLimits(
      fileMiB: number('file_size_limit'),
      imageMiB: number('image_file_size_limit'),
      audioMiB: number('audio_file_size_limit'),
      videoMiB: number('video_file_size_limit'),
      batchCount: number('batch_count_limit'),
      workflowCount: number('workflow_file_upload_limit'),
    );
  }

  final int fileMiB, imageMiB, audioMiB, videoMiB, batchCount, workflowCount;
}

abstract interface class FilesApi {
  Future<FileUploadLimits> limits();
  Future<UploadedFile> upload(
    List<int> bytes, {
    required String filename,
    String? mimeType,
  });
  Future<String> textPreview(String fileId);
}
