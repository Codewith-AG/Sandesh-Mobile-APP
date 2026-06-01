import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import '../models/message_model.dart';
import '../models/contact_model.dart';
import '../models/user_profile_model.dart';
import '../models/group_model.dart';

class LocalDbService {
  static final LocalDbService _instance = LocalDbService._internal();
  factory LocalDbService() => _instance;
  LocalDbService._internal();

  Database? _database;

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    final dbPath = await getDatabasesPath();
    // v8: adds blocked_users, groups, group_members, group_messages tables.
    // New filename ensures a clean migration without ALTER TABLE complexity.
    final path = join(dbPath, 'sandesh_v8.db');

    return await openDatabase(
      path,
      version: 1,
      onCreate: _onCreate,
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE messages (
        id TEXT PRIMARY KEY,
        sender_username TEXT NOT NULL,
        receiver_username TEXT NOT NULL,
        text TEXT,
        media_base64 TEXT,
        media_url TEXT,
        file_name TEXT,
        local_path TEXT,
        call_type TEXT,
        message_type TEXT NOT NULL DEFAULT 'text',
        is_me INTEGER NOT NULL,
        timestamp INTEGER NOT NULL
      )
    ''');
    await db.execute('CREATE INDEX idx_msg_sender ON messages(sender_username)');
    await db.execute('CREATE INDEX idx_msg_receiver ON messages(receiver_username)');
    await db.execute('CREATE INDEX idx_msg_timestamp ON messages(timestamp)');

    await db.execute('''
      CREATE TABLE contacts (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        username TEXT NOT NULL UNIQUE,
        phone TEXT DEFAULT '',
        hashed_phone_number TEXT NOT NULL DEFAULT '',
        display_name TEXT DEFAULT '',
        bio TEXT DEFAULT '',
        avatar_url TEXT DEFAULT ''
      )
    ''');

    await db.execute('''
      CREATE TABLE user_profile (
        username TEXT PRIMARY KEY,
        phone TEXT NOT NULL DEFAULT '',
        hashed_phone TEXT NOT NULL DEFAULT '',
        bio TEXT DEFAULT '',
        avatar_url TEXT DEFAULT ''
      )
    ''');

    // ── Blocked users (WhatsApp-style block/unblock) ──
    await db.execute('''
      CREATE TABLE blocked_users (
        username TEXT PRIMARY KEY,
        blocked_at INTEGER NOT NULL
      )
    ''');

    // ── Groups ──
    await db.execute('''
      CREATE TABLE groups (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        description TEXT DEFAULT '',
        avatar_url TEXT DEFAULT '',
        created_by TEXT NOT NULL,
        created_at INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE group_members (
        group_id TEXT NOT NULL,
        username TEXT NOT NULL,
        role TEXT DEFAULT 'member',
        PRIMARY KEY (group_id, username)
      )
    ''');

    await db.execute('''
      CREATE TABLE group_messages (
        id TEXT PRIMARY KEY,
        group_id TEXT NOT NULL,
        sender_username TEXT NOT NULL,
        text TEXT,
        media_url TEXT,
        file_name TEXT,
        message_type TEXT NOT NULL DEFAULT 'text',
        timestamp INTEGER NOT NULL
      )
    ''');
    await db.execute('CREATE INDEX idx_grpmsg_group ON group_messages(group_id)');
    await db.execute('CREATE INDEX idx_grpmsg_ts ON group_messages(timestamp)');
  }

  // ──────────────────────────── Messages ────────────────────────────

  Future<void> insertMessage(Message message) async {
    final db = await database;
    await db.insert('messages', message.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<Message>> getMessages(String myUsername, String chatWithUsername) async {
    final db = await database;
    final my = myUsername.toLowerCase();
    final peer = chatWithUsername.toLowerCase();
    final results = await db.query(
      'messages',
      where:
          '(LOWER(sender_username) = ? AND LOWER(receiver_username) = ?) OR (LOWER(sender_username) = ? AND LOWER(receiver_username) = ?)',
      whereArgs: [my, peer, peer, my],
      orderBy: 'timestamp ASC',
    );
    return results.map((m) => Message.fromMap(m)).toList();
  }

  /// Updates the local_path for a media message once it has been downloaded.
  Future<void> updateMessageLocalPath(String messageId, String localPath) async {
    final db = await database;
    await db.update(
      'messages',
      {'local_path': localPath},
      where: 'id = ?',
      whereArgs: [messageId],
    );
  }

  Future<void> deleteChatHistory(String myUsername, String chatWithUsername) async {
    final db = await database;
    final my = myUsername.toLowerCase();
    final peer = chatWithUsername.toLowerCase();
    await db.delete(
      'messages',
      where:
          '(LOWER(sender_username) = ? AND LOWER(receiver_username) = ?) OR (LOWER(sender_username) = ? AND LOWER(receiver_username) = ?)',
      whereArgs: [my, peer, peer, my],
    );
  }

  /// Returns the last message exchanged with a given user
  Future<Message?> getLastMessage(String myUsername, String withUsername) async {
    final db = await database;
    final my = myUsername.toLowerCase();
    final peer = withUsername.toLowerCase();
    final results = await db.query(
      'messages',
      where:
          '(LOWER(sender_username) = ? AND LOWER(receiver_username) = ?) OR (LOWER(sender_username) = ? AND LOWER(receiver_username) = ?)',
      whereArgs: [my, peer, peer, my],
      orderBy: 'timestamp DESC',
      limit: 1,
    );
    if (results.isEmpty) return null;
    return Message.fromMap(results.first);
  }

  // ──────────────────────────── Contacts ────────────────────────────

  Future<void> insertContact(Contact contact) async {
    final db = await database;
    final map = contact.toMap();
    map['username'] = (map['username'] as String).toLowerCase();
    await db.insert('contacts', map,
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> updateContactAvatar(String username, String avatarUrl) async {
    final db = await database;
    await db.update(
      'contacts',
      {'avatar_url': avatarUrl},
      where: 'LOWER(username) = ?',
      whereArgs: [username.toLowerCase()],
    );
  }

  /// Updates the display_name for a contact (WhatsApp-style phone contact name).
  Future<void> updateContactDisplayName(String username, String displayName) async {
    final db = await database;
    await db.update(
      'contacts',
      {'display_name': displayName},
      where: 'LOWER(username) = ?',
      whereArgs: [username.toLowerCase()],
    );
  }

  /// Returns the locally saved display name for a contact (from phone contacts).
  /// Returns null if no contact or no display name is stored.
  Future<String?> getContactDisplayName(String username) async {
    final db = await database;
    final results = await db.query(
      'contacts',
      columns: ['display_name'],
      where: 'LOWER(username) = ?',
      whereArgs: [username.toLowerCase()],
      limit: 1,
    );
    if (results.isEmpty) return null;
    final name = results.first['display_name'] as String?;
    return (name != null && name.isNotEmpty) ? name : null;
  }

  Future<List<Contact>> getContacts() async {
    final db = await database;
    final results = await db.query('contacts', orderBy: 'username ASC');
    return results.map((c) => Contact.fromMap(c)).toList();
  }

  /// Get contacts enriched with their last message for the dashboard
  Future<List<Contact>> getContactsWithLastMessage(String myUsername) async {
    final contacts = await getContacts();
    final enriched = <Contact>[];

    for (final contact in contacts) {
      final lastMsg = await getLastMessage(myUsername, contact.username);

      // Build a human-readable subtitle for media messages
      String? lastMessageText;
      if (lastMsg != null) {
        switch (lastMsg.messageType) {
          case MessageType.image:
            lastMessageText = '📷 Photo';
            break;
          case MessageType.video:
            lastMessageText = '🎥 Video';
            break;
          case MessageType.document:
            lastMessageText = '📄 ${lastMsg.fileName ?? 'Document'}';
            break;
          case MessageType.callInvite:
          case MessageType.callAccepted:
          case MessageType.callRejected:
          case MessageType.callEnded:
            lastMessageText = '📞 Call';
            break;
          case MessageType.text:
            lastMessageText = lastMsg.text;
            break;
        }
      }

      enriched.add(Contact(
        id: contact.id,
        username: contact.username,
        hashedPhone: contact.hashedPhone,
        displayName: contact.displayName,
        bio: contact.bio,
        avatarUrl: contact.avatarUrl,
        lastMessage: lastMessageText,
        lastMessageTime: lastMsg?.timestamp,
      ));
    }

    enriched.sort((a, b) {
      if (a.lastMessageTime == null && b.lastMessageTime == null) return 0;
      if (a.lastMessageTime == null) return 1;
      if (b.lastMessageTime == null) return -1;
      return b.lastMessageTime!.compareTo(a.lastMessageTime!);
    });

    return enriched;
  }

  Future<bool> contactExists(String username) async {
    final db = await database;
    final results = await db.query('contacts',
        where: 'LOWER(username) = ?', whereArgs: [username.toLowerCase()]);
    return results.isNotEmpty;
  }

  // ──────────────────────────── User Profile ────────────────────────────

  Future<void> saveProfile(UserProfile profile) async {
    final db = await database;
    await db.insert('user_profile', profile.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<UserProfile?> getProfile() async {
    final db = await database;
    final results = await db.query('user_profile', limit: 1);
    if (results.isEmpty) return null;
    return UserProfile.fromMap(results.first);
  }

  Future<void> updateProfile(UserProfile profile) async {
    final db = await database;
    await db.update(
      'user_profile',
      profile.toMap(),
      where: 'username = ?',
      whereArgs: [profile.username],
    );
  }

  Future<void> deleteProfile() async {
    final db = await database;
    await db.delete('user_profile');
  }

  Future<void> deleteAllData() async {
    final db = await database;
    await db.delete('messages');
    await db.delete('contacts');
    await db.delete('user_profile');
    await db.delete('blocked_users');
    await db.delete('group_messages');
    await db.delete('group_members');
    await db.delete('groups');
  }

  // ──────────────────────────── Blocked Users ────────────────────────────

  Future<void> blockUser(String username) async {
    final db = await database;
    await db.insert('blocked_users', {
      'username': username.toLowerCase(),
      'blocked_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> unblockUser(String username) async {
    final db = await database;
    await db.delete('blocked_users',
        where: 'username = ?', whereArgs: [username.toLowerCase()]);
  }

  Future<bool> isBlocked(String username) async {
    final db = await database;
    final results = await db.query('blocked_users',
        where: 'username = ?', whereArgs: [username.toLowerCase()]);
    return results.isNotEmpty;
  }

  Future<List<String>> getBlockedUsers() async {
    final db = await database;
    final results = await db.query('blocked_users');
    return results.map((r) => r['username'] as String).toList();
  }

  // ──────────────────────────── Groups ────────────────────────────

  Future<void> insertGroup(Group group) async {
    final db = await database;
    await db.insert('groups', group.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> deleteGroup(String groupId) async {
    final db = await database;
    await db.delete('groups', where: 'id = ?', whereArgs: [groupId]);
    await db.delete('group_members', where: 'group_id = ?', whereArgs: [groupId]);
    await db.delete('group_messages', where: 'group_id = ?', whereArgs: [groupId]);
  }

  Future<List<Group>> getGroups() async {
    final db = await database;
    final results = await db.query('groups', orderBy: 'created_at DESC');
    final groups = <Group>[];
    for (final row in results) {
      final groupId = row['id'] as String;
      final members = await getGroupMembers(groupId);
      groups.add(Group.fromMap(row).copyWith(members: members));
    }
    return groups;
  }

  Future<List<Group>> getGroupsWithLastMessage() async {
    final groups = await getGroups();
    final enriched = <Group>[];
    for (final group in groups) {
      final lastMsg = await getLastGroupMessage(group.id);
      String? lastText;
      String? lastSender;
      int? lastTime;
      if (lastMsg != null) {
        lastText = lastMsg['text'] as String? ?? '📎 Attachment';
        lastSender = lastMsg['sender_username'] as String?;
        lastTime = lastMsg['timestamp'] as int?;
      }
      enriched.add(group.copyWith(
        lastMessage: lastText,
        lastMessageSender: lastSender,
        lastMessageTime: lastTime,
      ));
    }
    enriched.sort((a, b) {
      if (a.lastMessageTime == null && b.lastMessageTime == null) return 0;
      if (a.lastMessageTime == null) return 1;
      if (b.lastMessageTime == null) return -1;
      return b.lastMessageTime!.compareTo(a.lastMessageTime!);
    });
    return enriched;
  }

  // ──────────────────────────── Group Members ────────────────────────────

  Future<void> insertGroupMember(String groupId, String username, {String role = 'member'}) async {
    final db = await database;
    await db.insert('group_members', {
      'group_id': groupId,
      'username': username.toLowerCase(),
      'role': role,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> removeGroupMember(String groupId, String username) async {
    final db = await database;
    await db.delete('group_members',
        where: 'group_id = ? AND username = ?',
        whereArgs: [groupId, username.toLowerCase()]);
  }

  Future<List<String>> getGroupMembers(String groupId) async {
    final db = await database;
    final results = await db.query('group_members',
        where: 'group_id = ?', whereArgs: [groupId]);
    return results.map((r) => r['username'] as String).toList();
  }

  Future<String?> getGroupMemberRole(String groupId, String username) async {
    final db = await database;
    final results = await db.query('group_members',
        where: 'group_id = ? AND username = ?',
        whereArgs: [groupId, username.toLowerCase()]);
    if (results.isEmpty) return null;
    return results.first['role'] as String?;
  }

  // ──────────────────────────── Group Messages ────────────────────────────

  Future<void> insertGroupMessage(Map<String, dynamic> message) async {
    final db = await database;
    await db.insert('group_messages', message,
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<Map<String, dynamic>>> getGroupMessages(String groupId) async {
    final db = await database;
    return await db.query('group_messages',
        where: 'group_id = ?',
        whereArgs: [groupId],
        orderBy: 'timestamp ASC');
  }

  Future<Map<String, dynamic>?> getLastGroupMessage(String groupId) async {
    final db = await database;
    final results = await db.query('group_messages',
        where: 'group_id = ?',
        whereArgs: [groupId],
        orderBy: 'timestamp DESC',
        limit: 1);
    if (results.isEmpty) return null;
    return results.first;
  }

  Future<void> deleteGroupMessages(String groupId) async {
    final db = await database;
    await db.delete('group_messages',
        where: 'group_id = ?', whereArgs: [groupId]);
  }
}
