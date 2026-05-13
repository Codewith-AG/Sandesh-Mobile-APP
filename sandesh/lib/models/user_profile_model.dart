class UserProfile {
  final String username;
  final String phone;
  final String hashedPhone;
  final String bio;
  final String avatarUrl;

  UserProfile({
    required this.username,
    required this.phone,
    required this.hashedPhone,
    this.bio = '',
    this.avatarUrl = '',
  });

  Map<String, dynamic> toMap() {
    return {
      'username': username,
      'phone': phone,
      'hashed_phone': hashedPhone,
      'bio': bio,
      'avatar_url': avatarUrl,
    };
  }

  factory UserProfile.fromMap(Map<String, dynamic> map) {
    return UserProfile(
      username: map['username'] as String? ?? '',
      phone: map['phone'] as String? ?? '',
      hashedPhone: map['hashed_phone'] as String? ?? '',
      bio: map['bio'] as String? ?? '',
      avatarUrl: map['avatar_url'] as String? ?? '',
    );
  }

  /// For upserting to the Supabase `users` table
  Map<String, dynamic> toSupabaseMap() {
    return {
      'username': username,
      'hashed_phone': hashedPhone,
      'bio': bio,
      'avatar_url': avatarUrl,
    };
  }

  UserProfile copyWith({
    String? username,
    String? phone,
    String? hashedPhone,
    String? bio,
    String? avatarUrl,
  }) {
    return UserProfile(
      username: username ?? this.username,
      phone: phone ?? this.phone,
      hashedPhone: hashedPhone ?? this.hashedPhone,
      bio: bio ?? this.bio,
      avatarUrl: avatarUrl ?? this.avatarUrl,
    );
  }
}
