import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:intl/intl.dart';
import 'package:flutter_contacts/flutter_contacts.dart' as fc;
import 'package:permission_handler/permission_handler.dart';
import '../models/contact_model.dart';
import '../models/message_model.dart';
import '../services/local_db_service.dart';
import '../services/supabase_broadcast_service.dart';
import '../theme/app_theme.dart';
import 'chat_screen.dart';
import 'profile_screen.dart';
import 'dart:async';
import 'dart:convert';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String _myUsername = '';
  List<Contact> _contacts = [];
  bool _isLoading = true;
  StreamSubscription<Message>? _messageSubscription;

  @override
  void initState() {
    super.initState();
    _loadInitialData();
    _messageSubscription = SupabaseBroadcastService().messageStream.listen((_) {
      if (mounted) {
        _loadContacts();
      }
    });
  }

  @override
  void dispose() {
    _messageSubscription?.cancel();
    super.dispose();
  }

  Future<void> _loadInitialData() async {
    final prefs = await SharedPreferences.getInstance();
    _myUsername = prefs.getString('username') ?? '';

    if (_myUsername.isEmpty) return;

    // Initialize broadcast service with our username
    SupabaseBroadcastService().initialize(_myUsername);

    // Auto-discover contacts from Supabase users table
    await SupabaseBroadcastService().discoverContacts();

    // Subscribe to room channels for ALL existing contacts
    // so we receive messages from any of them in real-time
    await SupabaseBroadcastService().subscribeToAllContactRooms();

    // Sync device contacts with Supabase
    await _syncDeviceContacts();

    await _loadContacts();
  }

  Future<void> _syncDeviceContacts() async {
    final status = await Permission.contacts.request();
    if (status.isGranted) {
      final contacts = await fc.FlutterContacts.getAll(
        properties: {fc.ContactProperty.phone},
      );
      final rawPhones = <String>[];
      for (final contact in contacts) {
        for (final phone in contact.phones) {
          rawPhones.add(phone.number);
        }
      }
      if (rawPhones.isNotEmpty) {
        await SupabaseBroadcastService().syncPhoneContacts(rawPhones);
      }
    }
  }

  Future<void> _loadContacts() async {
    final contacts =
        await LocalDbService().getContactsWithLastMessage(_myUsername);
    if (mounted) {
      setState(() {
        _contacts = contacts;
        _isLoading = false;
      });
    }
  }

  Future<void> _refreshContacts() async {
    await SupabaseBroadcastService().discoverContacts();
    await _syncDeviceContacts();
    await _loadContacts();
  }

  void _addContactDialog() {
    final controller = TextEditingController();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return Container(
          padding: EdgeInsets.only(
            left: 24,
            right: 24,
            top: 24,
            bottom: MediaQuery.of(context).viewInsets.bottom + 24,
          ),
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppTheme.mediumGrey,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'Start New Chat',
                style: GoogleFonts.urbanist(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.textDark,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Enter the username of the person you want to chat with',
                style: GoogleFonts.urbanist(
                  fontSize: 14,
                  color: AppTheme.textLight,
                ),
              ),
              const SizedBox(height: 20),
              TextFormField(
                controller: controller,
                autofocus: true,
                style: GoogleFonts.urbanist(fontSize: 15),
                decoration: InputDecoration(
                  hintText: 'Enter username',
                  filled: true,
                  fillColor: AppTheme.lightGrey,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                height: 52,
                child: ElevatedButton(
                  onPressed: () async {
                    final username = controller.text.trim().toLowerCase();
                    if (username.isNotEmpty && username != _myUsername) {
                      final exists =
                          await LocalDbService().contactExists(username);
                      if (!exists) {
                        await LocalDbService().insertContact(Contact(
                          username: username,
                          hashedPhone: '',
                        ));
                      }
                      if (context.mounted) Navigator.pop(context);
                      await _loadContacts();
                      if (mounted) {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => ChatScreen(
                              myUsername: _myUsername,
                              receiverUsername: username,
                            ),
                          ),
                        ).then((_) => _loadContacts());
                      }
                    }
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.primaryPurple,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  child: Text(
                    'Start Chat',
                    style: GoogleFonts.urbanist(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  String _formatTime(int? timestamp) {
    if (timestamp == null) return '';
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp);
    final now = DateTime.now();
    final diff = now.difference(date);

    if (diff.inDays == 0) {
      return DateFormat('HH:mm').format(date);
    } else if (diff.inDays == 1) {
      return 'Yesterday';
    } else if (diff.inDays < 7) {
      return DateFormat('EEE').format(date);
    } else {
      return DateFormat('dd/MM/yy').format(date);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: Padding(
          padding: const EdgeInsets.only(left: 16),
          child: GestureDetector(
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const ProfileScreen()),
              ).then((_) => _loadContacts());
            },
            child: CircleAvatar(
              backgroundColor: AppTheme.lightPurple,
              child: Text(
                _myUsername.isNotEmpty ? _myUsername[0].toUpperCase() : '?',
                style: GoogleFonts.urbanist(
                  color: AppTheme.primaryPurple,
                  fontWeight: FontWeight.w700,
                  fontSize: 18,
                ),
              ),
            ),
          ),
        ),
        title: Text(
          'Sandesh',
          style: GoogleFonts.urbanist(
            fontWeight: FontWeight.w800,
            fontSize: 24,
            color: AppTheme.textDark,
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.search_rounded, color: AppTheme.textMedium),
            onPressed: () {},
          ),
          IconButton(
            icon:
                const Icon(Icons.more_vert_rounded, color: AppTheme.textMedium),
            onPressed: () {},
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: _isLoading
          ? const Center(
              child: CircularProgressIndicator(color: AppTheme.primaryPurple))
          : _contacts.isEmpty
              ? _buildEmptyState()
              : RefreshIndicator(
                  onRefresh: _refreshContacts,
                  color: AppTheme.primaryPurple,
                  child: ListView.separated(
                    padding: const EdgeInsets.only(top: 8),
                    itemCount: _contacts.length,
                    separatorBuilder: (_, __) => const Padding(
                      padding: EdgeInsets.only(left: 80),
                      child: Divider(height: 1, color: AppTheme.lightGrey),
                    ),
                    itemBuilder: (context, index) {
                      final contact = _contacts[index];
                      return _buildContactTile(contact);
                    },
                  ),
                ),
      floatingActionButton: FloatingActionButton(
        onPressed: _addContactDialog,
        elevation: 3,
        child: const Icon(Icons.chat_bubble_outline, size: 24),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 100,
            height: 100,
            decoration: BoxDecoration(
              color: AppTheme.lightPurple,
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.chat_bubble_outline_rounded,
              size: 48,
              color: AppTheme.primaryPurple,
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'No conversations yet',
            style: GoogleFonts.urbanist(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              color: AppTheme.textDark,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Tap the button below to start chatting',
            style: GoogleFonts.urbanist(
              fontSize: 14,
              color: AppTheme.textLight,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContactTile(Contact contact) {
    Widget avatarWidget;
    if (contact.avatarUrl.isNotEmpty) {
      try {
        final bytes = base64Decode(contact.avatarUrl);
        avatarWidget = CircleAvatar(
          radius: 28,
          backgroundImage: MemoryImage(bytes),
        );
      } catch (_) {
        avatarWidget = _buildFallbackAvatar(contact);
      }
    } else {
      avatarWidget = _buildFallbackAvatar(contact);
    }

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
      leading: avatarWidget,
      title: Text(
        contact.username,
        style: GoogleFonts.urbanist(
          fontWeight: FontWeight.w700,
          fontSize: 16,
          color: AppTheme.textDark,
        ),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (contact.phone.isNotEmpty)
            Text(
              contact.phone,
              style: GoogleFonts.urbanist(
                fontSize: 12,
                color: AppTheme.primaryPurple,
                fontWeight: FontWeight.w600,
              ),
            ),
          const SizedBox(height: 2),
          Text(
            contact.lastMessage ?? 'Tap to start chatting',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.urbanist(
              fontSize: 13,
              color: AppTheme.textLight,
              fontWeight: FontWeight.w400,
            ),
          ),
        ],
      ),
      trailing: contact.lastMessageTime != null
          ? Text(
              _formatTime(contact.lastMessageTime),
              style: GoogleFonts.urbanist(
                fontSize: 12,
                color: AppTheme.textLight,
              ),
            )
          : null,
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ChatScreen(
              myUsername: _myUsername,
              receiverUsername: contact.username,
            ),
          ),
        ).then((_) => _loadContacts());
      },
    );
  }

  Widget _buildFallbackAvatar(Contact contact) {
    return CircleAvatar(
      radius: 28,
      backgroundColor: AppTheme.lightPurple,
      child: Text(
        contact.username.isNotEmpty ? contact.username[0].toUpperCase() : '?',
        style: GoogleFonts.urbanist(
          color: AppTheme.primaryPurple,
          fontWeight: FontWeight.w700,
          fontSize: 20,
        ),
      ),
    );
  }
}
