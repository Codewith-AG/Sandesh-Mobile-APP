import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import '../models/message_model.dart';
import '../models/contact_model.dart';
import '../models/user_profile_model.dart';

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
    final path = join(dbPath, 'sandesh_v4.db');

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
    // Use LOWER username as the unique key to avoid duplicates
    final map = contact.toMap();
    map['username'] = (map['username'] as String).toLowerCase();
    await db.insert('contacts', map,
        conflictAlgorithm: ConflictAlgorithm.replace);
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
      enriched.add(Contact(
        id: contact.id,
        username: contact.username,
        hashedPhone: contact.hashedPhone,
        displayName: contact.displayName,
        bio: contact.bio,
        avatarUrl: contact.avatarUrl,
        lastMessage: lastMsg?.text,
        lastMessageTime: lastMsg?.timestamp,
      ));
    }

    // Sort by last message time (most recent first), contacts without messages at end
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
  }
}
