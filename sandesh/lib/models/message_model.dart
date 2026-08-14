/// Supported message content types.
enum MessageType { text, image, video, document, call, callInvite, callAccepted, callRejected, callEnded, system }

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
      case MessageType.call:
        return 'call';
      case MessageType.callInvite:
        return 'call_invite';
      case MessageType.callAccepted:
        return 'call_accepted';
      case MessageType.callRejected:
        return 'call_rejected';
      case MessageType.callEnded:
        return 'call_ended';
      case MessageType.system:
        return 'system';
    }
  }

  bool get isCallSignal => this == MessageType.callInvite ||
      this == MessageType.callAccepted ||
      this == MessageType.callRejected ||
      this == MessageType.callEnded;

  static MessageType fromString(String? s) {
    switch (s) {
      case 'image':
        return MessageType.image;
      case 'video':
        return MessageType.video;
      case 'document':
        return MessageType.document;
      case 'call':
        return MessageType.call;
      case 'call_invite':
        return MessageType.callInvite;
      case 'call_accepted':
        return MessageType.callAccepted;
      case 'call_rejected':
        return MessageType.callRejected;
      case 'call_ended':
        return MessageType.callEnded;
      case 'system':
        return MessageType.system;
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
  /// Content type: text | image | video | document | call_*
  final MessageType messageType;
  /// For call signals: 'audio' or 'video'
  final String? callType;
  final bool isMe;
  final int timestamp;

  /// Reply metadata (denormalized so the reply preview survives even after the
  /// original message row has been cleaned up by store-and-forward).
  final String? replyToId;
  final String? replyToSender;
  final String? replyToText;
  final String? replyToType;

  /// Delivery status for OWN (sent) messages: 'sent' | 'delivered' | 'read'.
  /// Null for received messages.
  final String? status;

  Message({
    required this.id,
    required this.senderUsername,
    required this.receiverUsername,
    this.text,
    this.mediaBase64,
    this.mediaUrl,
    this.fileName,
    this.localPath,
    this.callType,
    MessageType? messageType,
    required this.isMe,
    required this.timestamp,
    this.replyToId,
    this.replyToSender,
    this.replyToText,
    this.replyToType,
    this.status,
  }) : messageType = messageType ??
            (mediaUrl != null ? MessageType.image : MessageType.text);

  Message copyWith({
    String? localPath,
    String? status,
    String? text,
  }) {
    return Message(
      id: id,
      senderUsername: senderUsername,
      receiverUsername: receiverUsername,
      text: text ?? this.text,
      mediaBase64: mediaBase64,
      mediaUrl: mediaUrl,
      fileName: fileName,
      localPath: localPath ?? this.localPath,
      callType: callType,
      messageType: messageType,
      isMe: isMe,
      timestamp: timestamp,
      replyToId: replyToId,
      replyToSender: replyToSender,
      replyToText: replyToText,
      replyToType: replyToType,
      status: status ?? this.status,
    );
  }

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
      'call_type': callType,
      'message_type': messageType.value,
      'is_me': isMe ? 1 : 0,
      'timestamp': timestamp,
      'reply_to_id': replyToId,
      'reply_to_sender': replyToSender,
      'reply_to_text': replyToText,
      'reply_to_type': replyToType,
      'status': status,
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
      callType: map['call_type'] as String?,
      messageType: MessageTypeX.fromString(map['message_type'] as String?),
      isMe: (map['is_me'] as int) == 1,
      timestamp: map['timestamp'] as int,
      replyToId: map['reply_to_id'] as String?,
      replyToSender: map['reply_to_sender'] as String?,
      replyToText: map['reply_to_text'] as String?,
      replyToType: map['reply_to_type'] as String?,
      status: map['status'] as String?,
    );
  }
}
