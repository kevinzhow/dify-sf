/// Canvas comments (docs/protocol.md, section 2 "Comments"): Dify 1.17.1's workflow comments as a server resource beside
/// the document (not in the document, the op log, snapshots, the export or undo). Field names follow Dify's
/// `WorkflowCommentDetail`. Protocol 1.8: authors, resolvers and mentions are **account ids** with the accounts' names and
/// avatars (before 1.8: client ids with their display names).
library;

/// A mentioned account (`{"account", "name"?, "avatar_url"?}`; 1.3-era answers say `client` instead of `account`).
final class CommentMention {
  const CommentMention({required this.account, this.name, this.avatarUrl});

  factory CommentMention.fromJson(Object? json) {
    final m = _map(json, 'mention');
    return CommentMention(
      account: m['account'] is String ? m['account']! as String : _str(m, 'client'),
      name: m['name'] as String?,
      avatarUrl: m['avatar_url'] as String?,
    );
  }

  /// The mentioned account's id.
  final String account;

  /// The account's name (absent for an id that matches no account).
  final String? name;
  final String? avatarUrl;

  /// The mentioned id under its pre-1.8 name (it was a client id). Same as [account]; prefer [account].
  String get client => account;

  Map<String, Object?> toJson() => {'account': account, 'name': ?name, 'avatar_url': ?avatarUrl};

  @override
  bool operator ==(Object other) =>
      other is CommentMention && other.account == account && other.name == name && other.avatarUrl == avatarUrl;

  @override
  int get hashCode => Object.hash(account, name, avatarUrl);
}

/// A reply in a comment's thread.
final class CommentReply {
  const CommentReply({
    required this.id,
    required this.content,
    required this.createdBy,
    this.createdByName,
    this.createdByAvatarUrl,
    required this.createdAt,
    required this.updatedAt,
    this.mentions = const [],
  });

  factory CommentReply.fromJson(Object? json) {
    final m = _map(json, 'reply');
    return CommentReply(
      id: _str(m, 'id'),
      content: _str(m, 'content'),
      createdBy: _str(m, 'created_by'),
      createdByName: m['created_by_name'] as String?,
      createdByAvatarUrl: m['created_by_avatar_url'] as String?,
      createdAt: _requiredTime(m, 'created_at'),
      updatedAt: _requiredTime(m, 'updated_at'),
      mentions: _mentions(m['mentions']),
    );
  }

  final String id;
  final String content;

  /// The author's account id (1.8).
  final String createdBy;
  final String? createdByName;
  final String? createdByAvatarUrl;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<CommentMention> mentions;

  Map<String, Object?> toJson() => {
    'id': id,
    'content': content,
    'created_by': createdBy,
    'created_by_name': ?createdByName,
    'created_by_avatar_url': ?createdByAvatarUrl,
    'created_at': createdAt.toUtc().toIso8601String(),
    'updated_at': updatedAt.toUtc().toIso8601String(),
    'mentions': [for (final x in mentions) x.toJson()],
  };
}

/// A comment pinned at canvas (flow) coordinates, with its replies (oldest first).
final class Comment {
  const Comment({
    required this.id,
    required this.positionX,
    required this.positionY,
    required this.content,
    required this.createdBy,
    this.createdByName,
    this.createdByAvatarUrl,
    required this.createdAt,
    required this.updatedAt,
    this.resolved = false,
    this.resolvedBy,
    this.resolvedByName,
    this.resolvedByAvatarUrl,
    this.resolvedAt,
    this.mentions = const [],
    this.replies = const [],
    int? replyCount,
  }) : replyCount = replyCount ?? replies.length;

  factory Comment.fromJson(Object? json) {
    final m = _map(json, 'comment');
    final replies = [
      if (m['replies'] is List<Object?>)
        for (final r in m['replies']! as List<Object?>) CommentReply.fromJson(r),
    ];
    return Comment(
      id: _str(m, 'id'),
      positionX: _num(m, 'position_x'),
      positionY: _num(m, 'position_y'),
      content: _str(m, 'content'),
      createdBy: _str(m, 'created_by'),
      createdByName: m['created_by_name'] as String?,
      createdByAvatarUrl: m['created_by_avatar_url'] as String?,
      createdAt: _requiredTime(m, 'created_at'),
      updatedAt: _requiredTime(m, 'updated_at'),
      resolved: m['resolved'] as bool? ?? false,
      resolvedBy: m['resolved_by'] as String?,
      resolvedByName: m['resolved_by_name'] as String?,
      resolvedByAvatarUrl: m['resolved_by_avatar_url'] as String?,
      resolvedAt: _time(m, 'resolved_at'),
      mentions: _mentions(m['mentions']),
      replies: replies,
      replyCount: m['reply_count'] as int? ?? replies.length,
    );
  }

  final String id;

  /// Canvas (flow) coordinates of the pin.
  final double positionX;
  final double positionY;
  final String content;

  /// The author's account id (1.8).
  final String createdBy;
  final String? createdByName;
  final String? createdByAvatarUrl;
  final DateTime createdAt;
  final DateTime updatedAt;
  final bool resolved;

  /// The resolver's account id (1.8).
  final String? resolvedBy;
  final String? resolvedByName;
  final String? resolvedByAvatarUrl;
  final DateTime? resolvedAt;
  final List<CommentMention> mentions;
  final List<CommentReply> replies;
  final int replyCount;

  Comment copyWith({
    double? positionX,
    double? positionY,
    String? content,
    bool? resolved,
    List<CommentReply>? replies,
  }) => Comment(
    id: id,
    positionX: positionX ?? this.positionX,
    positionY: positionY ?? this.positionY,
    content: content ?? this.content,
    createdBy: createdBy,
    createdByName: createdByName,
    createdByAvatarUrl: createdByAvatarUrl,
    createdAt: createdAt,
    updatedAt: updatedAt,
    resolved: resolved ?? this.resolved,
    resolvedBy: resolvedBy,
    resolvedByName: resolvedByName,
    resolvedByAvatarUrl: resolvedByAvatarUrl,
    resolvedAt: resolvedAt,
    mentions: mentions,
    replies: replies ?? this.replies,
    replyCount: replies?.length ?? replyCount,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'position_x': positionX,
    'position_y': positionY,
    'content': content,
    'created_by': createdBy,
    'created_by_name': ?createdByName,
    'created_by_avatar_url': ?createdByAvatarUrl,
    'created_at': createdAt.toUtc().toIso8601String(),
    'updated_at': updatedAt.toUtc().toIso8601String(),
    'resolved': resolved,
    'resolved_by': ?resolvedBy,
    'resolved_by_name': ?resolvedByName,
    'resolved_by_avatar_url': ?resolvedByAvatarUrl,
    'resolved_at': ?resolvedAt?.toUtc().toIso8601String(),
    'mentions': [for (final x in mentions) x.toJson()],
    'replies': [for (final r in replies) r.toJson()],
    'reply_count': replyCount,
  };
}

/// Dify's content rule (`_validate_content`): not blank, at most [maxCommentLength] characters. The server enforces it;
/// clients may check first to avoid a round trip. Returns the reason, or null when [content] is acceptable.
String? commentContentProblem(String content) {
  if (content.trim().isEmpty) return 'Comment content cannot be empty';
  if (content.runes.length > maxCommentLength) return 'Comment content cannot exceed $maxCommentLength characters';
  return null;
}

/// Dify's limit (characters = Unicode scalars, as Python's `len`).
const maxCommentLength = 1000;

Map<String, Object?> _map(Object? json, String what) =>
    json is Map<String, Object?> ? json : throw FormatException('expected a $what object, got $json');

String _str(Map<String, Object?> m, String key) =>
    m[key] is String ? m[key]! as String : throw FormatException('missing or non-string "$key" in $m');

double _num(Map<String, Object?> m, String key) =>
    m[key] is num ? (m[key]! as num).toDouble() : throw FormatException('missing or non-numeric "$key" in $m');

DateTime? _time(Map<String, Object?> m, String key) {
  final v = m[key];
  if (v == null) return null;
  if (v is String) return DateTime.parse(v).toUtc();
  if (v is int) return DateTime.fromMillisecondsSinceEpoch(v * 1000, isUtc: true); // Dify's epoch seconds
  throw FormatException('bad time "$key" in $m');
}

DateTime _requiredTime(Map<String, Object?> m, String key) =>
    _time(m, key) ?? (throw FormatException('missing "$key" in $m'));

List<CommentMention> _mentions(Object? v) => [
  if (v is List<Object?>)
    for (final x in v) CommentMention.fromJson(x),
];
