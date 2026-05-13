class Contact {
  final int? id;
  final String username;
  final String phone;
  final String hashedPhone;
  final String displayName;
  final String bio;
  final String avatarUrl;

  // Transient fields — populated from messages table, not stored in contacts table
  final String? lastMessage;
  final int? lastMessageTime;

  Contact({
    this.id,
    required this.username,
    this.phone = '',
    required this.hashedPhone,
    this.displayName = '',
    this.bio = '',
    this.avatarUrl = '',
    this.lastMessage,
    this.lastMessageTime,
  });

  Map<String, dynamic> toMap() {
    return {
      'username': username,
      'phone': phone,
      'hashed_phone_number': hashedPhone,
      'display_name': displayName,
      'bio': bio,
      'avatar_url': avatarUrl,
    };
  }

  factory Contact.fromMap(Map<String, dynamic> map) {
    return Contact(
      id: map['id'] as int?,
      username: map['username'] as String,
      phone: (map['phone'] ?? '') as String,
      hashedPhone: (map['hashed_phone_number'] ?? map['hashed_phone'] ?? '') as String,
      displayName: (map['display_name'] ?? '') as String,
      bio: (map['bio'] ?? '') as String,
      avatarUrl: (map['avatar_url'] ?? '') as String,
      lastMessage: map['last_message'] as String?,
      lastMessageTime: map['last_message_time'] as int?,
    );
  }
}
