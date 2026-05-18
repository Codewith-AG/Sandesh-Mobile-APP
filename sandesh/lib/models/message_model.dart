/// Supported message content types.
enum MessageType { text, image, video, document }

/// Extension to convert between enum and DB string values.
extension MessageTypeX on MessageType {
  String get value {
    switch (this) {
      case MessageType.text:
        return 'text';
      case MessageType.image:
        return 'image';
      case MessageType.video:
        return 'video';
      case MessageType.document:
        return 'document';
    }
  }

  static MessageType fromString(String? s) {
    switch (s) {
      case 'image':
        return MessageType.image;
      case 'video':
        return MessageType.video;
      case 'document':
        return MessageType.document;
      default:
        return MessageType.text;
    }
  }
}

class Message {
  final String id;
  final String senderUsername;
  final String receiverUsername;
  final String? text;
  /// Legacy base64 field — kept for backward-compat but no longer written.
  final String? mediaBase64;
  /// Public URL of the media in Supabase Storage (image/video/document).
  final String? mediaUrl;
  /// Original file name for documents.
  final String? fileName;
  /// Local device path after auto-download (replaces mediaUrl for offline reading).
  final String? localPath;
  /// Content type: text | image | video | document.
  final MessageType messageType;
  final bool isMe;
  final int timestamp;

  Message({
    required this.id,
    required this.senderUsername,
    required this.receiverUsername,
    this.text,
    this.mediaBase64,
    this.mediaUrl,
    this.fileName,
    this.localPath,
    MessageType? messageType,
    required this.isMe,
    required this.timestamp,
  }) : messageType = messageType ??
            (mediaUrl != null ? MessageType.image : MessageType.text);

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'sender_username': senderUsername,
      'receiver_username': receiverUsername,
      'text': text,
      'media_base64': mediaBase64,
      'media_url': mediaUrl,
      'file_name': fileName,
      'local_path': localPath,
      'message_type': messageType.value,
      'is_me': isMe ? 1 : 0,
      'timestamp': timestamp,
    };
  }

  factory Message.fromMap(Map<String, dynamic> map) {
    return Message(
      id: map['id'] as String,
      senderUsername: map['sender_username'] as String,
      receiverUsername: map['receiver_username'] as String,
      text: map['text'] as String?,
      mediaBase64: map['media_base64'] as String?,
      mediaUrl: map['media_url'] as String?,
      fileName: map['file_name'] as String?,
      localPath: map['local_path'] as String?,
      messageType: MessageTypeX.fromString(map['message_type'] as String?),
      isMe: (map['is_me'] as int) == 1,
      timestamp: map['timestamp'] as int,
    );
  }
}
