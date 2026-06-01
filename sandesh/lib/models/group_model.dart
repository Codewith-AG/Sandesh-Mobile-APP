class Group {
  final String id;
  final String name;
  final String description;
  final String avatarUrl;
  final String createdBy;
  final int createdAt;

  // Transient fields — populated from joins/queries, not stored in groups table
  final List<String> members;
  final String? lastMessage;
  final int? lastMessageTime;
  final String? lastMessageSender;

  Group({
    required this.id,
    required this.name,
    this.description = '',
    this.avatarUrl = '',
    required this.createdBy,
    required this.createdAt,
    this.members = const [],
    this.lastMessage,
    this.lastMessageTime,
    this.lastMessageSender,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'description': description,
      'avatar_url': avatarUrl,
      'created_by': createdBy,
      'created_at': createdAt,
    };
  }

  factory Group.fromMap(Map<String, dynamic> map) {
    return Group(
      id: map['id'] as String,
      name: map['name'] as String,
      description: (map['description'] ?? '') as String,
      avatarUrl: (map['avatar_url'] ?? '') as String,
      createdBy: map['created_by'] as String,
      createdAt: map['created_at'] as int,
      lastMessage: map['last_message'] as String?,
      lastMessageTime: map['last_message_time'] as int?,
      lastMessageSender: map['last_message_sender'] as String?,
    );
  }

  Group copyWith({
    String? id,
    String? name,
    String? description,
    String? avatarUrl,
    String? createdBy,
    int? createdAt,
    List<String>? members,
    String? lastMessage,
    int? lastMessageTime,
    String? lastMessageSender,
  }) {
    return Group(
      id: id ?? this.id,
      name: name ?? this.name,
      description: description ?? this.description,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      createdBy: createdBy ?? this.createdBy,
      createdAt: createdAt ?? this.createdAt,
      members: members ?? this.members,
      lastMessage: lastMessage ?? this.lastMessage,
      lastMessageTime: lastMessageTime ?? this.lastMessageTime,
      lastMessageSender: lastMessageSender ?? this.lastMessageSender,
    );
  }
}
