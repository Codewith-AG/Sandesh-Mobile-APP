class Message {
  final String id;
  final String senderUsername;
  final String receiverUsername;
  final String? text;
  final String? mediaBase64;
  final bool isMe;
  final int timestamp;

  Message({
    required this.id,
    required this.senderUsername,
    required this.receiverUsername,
    this.text,
    this.mediaBase64,
    required this.isMe,
    required this.timestamp,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'sender_username': senderUsername,
      'receiver_username': receiverUsername,
      'text': text,
      'media_base64': mediaBase64,
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
      isMe: (map['is_me'] as int) == 1,
      timestamp: map['timestamp'] as int,
    );
  }
}
