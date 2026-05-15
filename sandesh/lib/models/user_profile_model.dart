class UserProfile {
  final String username;
  final String phone;
  final String phoneE164; // E.164 formatted, e.g. +919876543210
  final String hashedPhone;
  final String bio;
  final String avatarUrl;

  UserProfile({
    required this.username,
    this.phone = '',
    this.phoneE164 = '',
    this.hashedPhone = '',
    this.bio = '',
    this.avatarUrl = '',
  });

  Map<String, dynamic> toMap() {
    return {
      'username': username,
      'phone': phone.isNotEmpty ? phone : phoneE164,
      'hashed_phone': hashedPhone,
      'bio': bio,
      'avatar_url': avatarUrl,
    };
  }

  factory UserProfile.fromMap(Map<String, dynamic> map) {
    return UserProfile(
      username: map['username'] as String? ?? '',
      phone: map['phone'] as String? ?? '',
      phoneE164: map['phone_e164'] as String? ?? map['phone'] as String? ?? '',
      hashedPhone: map['hashed_phone'] as String? ?? '',
      bio: map['bio'] as String? ?? '',
      avatarUrl: map['avatar_url'] as String? ?? '',
    );
  }

  /// For upserting to the Supabase `profiles` table (linked via auth UUID)
  Map<String, dynamic> toSupabaseMap({String? authId}) {
    return {
      if (authId != null) 'id': authId,
      'username': username,
      'phone_e164': phoneE164.isNotEmpty ? phoneE164 : phone,
      'bio': bio,
      'avatar_url': avatarUrl,
    };
  }

  UserProfile copyWith({
    String? username,
    String? phone,
    String? phoneE164,
    String? hashedPhone,
    String? bio,
    String? avatarUrl,
  }) {
    return UserProfile(
      username: username ?? this.username,
      phone: phone ?? this.phone,
      phoneE164: phoneE164 ?? this.phoneE164,
      hashedPhone: hashedPhone ?? this.hashedPhone,
      bio: bio ?? this.bio,
      avatarUrl: avatarUrl ?? this.avatarUrl,
    );
  }
}
