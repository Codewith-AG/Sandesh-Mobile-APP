import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:intl/intl.dart';
import 'package:flutter_contacts/flutter_contacts.dart' as fc;
import 'package:permission_handler/permission_handler.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/contact_model.dart';
import '../models/message_model.dart';
import '../services/local_db_service.dart';
import '../services/supabase_broadcast_service.dart';
import '../services/call_service.dart';
import '../theme/app_theme.dart';
import 'chat_screen.dart';
import 'profile_screen.dart';
import 'login_screen.dart';
import 'dart:async';
import 'dart:convert';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String _myUsername = '';
  String _myAvatarUrl = '';
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
    // Primary: get username from Supabase session metadata
    final supabase = Supabase.instance.client;
    final session = supabase.auth.currentSession;

    if (session != null) {
      final meta = session.user.userMetadata ?? {};
      final sessionName = (meta['full_name'] as String? ??
              meta['name'] as String? ??
              session.user.email?.split('@').first ??
              '')
          .trim();
      if (sessionName.isNotEmpty) {
        _myUsername = sessionName;
      }
    }

    // Fallback: SharedPreferences
    if (_myUsername.isEmpty) {
      final prefs = await SharedPreferences.getInstance();
      _myUsername = prefs.getString('username') ?? '';
    }

    if (_myUsername.isEmpty) return;

    // Initialize broadcast service with our username
    SupabaseBroadcastService().initialize(_myUsername);
    // Initialize Agora calling engine
    CallService().initialize(_myUsername);

    // Auto-discover contacts from Supabase users table
    await SupabaseBroadcastService().discoverContacts();

    // Subscribe to room channels for ALL existing contacts
    // so we receive messages from any of them in real-time
    await SupabaseBroadcastService().subscribeToAllContactRooms();

    // Sync device contacts with Supabase
    await _syncDeviceContacts();

    await _loadContacts();

    // Fetch own profile for avatar
    final profile = await LocalDbService().getProfile();
    if (profile != null && mounted) {
      setState(() {
        _myAvatarUrl = profile.avatarUrl;
      });
    }
  }

  Future<void> _syncDeviceContacts() async {
    final status = await Permission.contacts.request();
    if (status.isGranted) {
      final contacts = await fc.FlutterContacts.getAll(
        properties: {fc.ContactProperty.phone},
      );
      final phoneToName = <String, String>{};
      for (final contact in contacts) {
        for (final phone in contact.phones) {
          phoneToName[phone.number] = contact.displayName ?? 'Unknown';
        }
      }
      if (phoneToName.isNotEmpty) {
        await SupabaseBroadcastService().syncPhoneContacts(phoneToName);
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
    
    final profile = await LocalDbService().getProfile();
    if (profile != null && mounted) {
      setState(() {
        _myAvatarUrl = profile.avatarUrl;
      });
    }
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
            color: AppTheme.surfaceContainerLowest,
            borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 48,
                  height: 6,
                  decoration: BoxDecoration(
                    color: AppTheme.surfaceVariant,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              Text(
                'Start New Chat',
                style: GoogleFonts.outfit(
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.onSurface,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Enter the username of the person you want to chat with',
                style: GoogleFonts.outfit(
                  fontSize: 16,
                  color: AppTheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 24),
              TextFormField(
                controller: controller,
                autofocus: true,
                style: GoogleFonts.outfit(fontSize: 16, color: AppTheme.onSurface),
                decoration: InputDecoration(
                  hintText: 'Enter username',
                  // Styling is handled by AppTheme.inputDecorationTheme
                ),
              ),
              const SizedBox(height: 24),
              SizedBox(
                height: 56,
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
                      if (!context.mounted) return;
                      final nav = Navigator.of(context);
                      nav.pop();
                      await _loadContacts();
                      if (!mounted) return;
                      nav.push(
                        MaterialPageRoute(
                          builder: (_) => ChatScreen(
                            myUsername: _myUsername,
                            receiverUsername: username,
                          ),
                        ),
                      ).then((_) => _loadContacts());
                    }
                  },
                  child: Text(
                    'Start Chat',
                    style: GoogleFonts.outfit(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.onPrimary,
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
          padding: const EdgeInsets.only(left: 20),
          child: GestureDetector(
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const ProfileScreen()),
              ).then((_) => _loadContacts());
            },
            child: _myAvatarUrl.startsWith('http')
                ? CircleAvatar(
                    radius: 20,
                    backgroundColor: AppTheme.surfaceContainerHigh,
                    backgroundImage: NetworkImage(_myAvatarUrl),
                    onBackgroundImageError: (_, __) {},
                  )
                : CircleAvatar(
                    backgroundColor: AppTheme.surfaceContainerHigh,
                    child: Text(
                      _myUsername.isNotEmpty ? _myUsername[0].toUpperCase() : '?',
                      style: GoogleFonts.outfit(
                        color: AppTheme.primary,
                        fontWeight: FontWeight.w700,
                        fontSize: 20,
                      ),
                    ),
                  ),
          ),
        ),
        title: Text(
          'Sandesh',
          style: GoogleFonts.outfit(
            fontWeight: FontWeight.w800,
            fontSize: 28,
            color: AppTheme.onSurface,
            letterSpacing: -0.01,
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.search_rounded, color: AppTheme.onSurfaceVariant),
            onPressed: () {},
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert_rounded, color: AppTheme.onSurfaceVariant),
            onSelected: (value) async {
              if (value == 'profile') {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const ProfileScreen()),
                ).then((_) => _refreshContacts());
              } else if (value == 'logout') {
                final confirm = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    backgroundColor: AppTheme.surfaceContainerLowest,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                    title: Text('Logout', style: GoogleFonts.outfit(fontWeight: FontWeight.w700, color: AppTheme.onSurface)),
                    content: Text('Are you sure you want to logout? Your chat history will be preserved locally.', style: GoogleFonts.outfit(color: AppTheme.onSurfaceVariant)),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('Cancel', style: GoogleFonts.outfit(color: AppTheme.outline))),
                      ElevatedButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        style: ElevatedButton.styleFrom(backgroundColor: AppTheme.error),
                        child: Text('Logout', style: GoogleFonts.outfit(color: AppTheme.onError)),
                      ),
                    ],
                  ),
                );

                if (confirm == true && mounted) {
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.clear();
                  SupabaseBroadcastService().dispose();
                  try {
                    await Supabase.instance.client.auth.signOut();
                  } catch (_) {}
                  if (mounted) {
                    Navigator.of(context).pushAndRemoveUntil(
                      MaterialPageRoute(builder: (_) => const LoginScreen()),
                      (route) => false,
                    );
                  }
                }
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(value: 'profile', child: Text('My Profile', style: GoogleFonts.outfit())),
              PopupMenuItem(value: 'logout', child: Text('Log Out', style: GoogleFonts.outfit(color: AppTheme.error))),
            ],
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: _isLoading
          ? const Center(
              child: CircularProgressIndicator(color: AppTheme.primary))
          : _contacts.isEmpty
              ? _buildEmptyState()
              : RefreshIndicator(
                  onRefresh: _refreshContacts,
                  color: AppTheme.primary,
                  backgroundColor: AppTheme.surfaceContainerLowest,
                  child: ListView.separated(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    itemCount: _contacts.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 4),
                    itemBuilder: (context, index) {
                      final contact = _contacts[index];
                      return _buildContactTile(contact);
                    },
                  ),
                ),
      floatingActionButton: FloatingActionButton(
        onPressed: _addContactDialog,
        elevation: 3,
        child: const Icon(Icons.edit_square, size: 24),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 120,
            height: 120,
            decoration: BoxDecoration(
              color: AppTheme.surfaceContainerHigh,
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.chat_bubble_outline_rounded,
              size: 56,
              color: AppTheme.primary,
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'No conversations yet',
            style: GoogleFonts.outfit(
              fontSize: 24,
              fontWeight: FontWeight.w700,
              color: AppTheme.onSurface,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Tap the button below to start chatting',
            style: GoogleFonts.outfit(
              fontSize: 16,
              color: AppTheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContactTile(Contact contact) {
    Widget avatarWidget;
    final url = contact.avatarUrl;

    if (url.startsWith('http')) {
      avatarWidget = CircleAvatar(
        radius: 28,
        backgroundColor: AppTheme.surfaceContainerHigh,
        backgroundImage: NetworkImage(url),
        onBackgroundImageError: (_, __) {},
      );
    } else if (url.isNotEmpty) {
      try {
        final bytes = base64Decode(url);
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

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(24),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        hoverColor: AppTheme.surfaceContainer,
        splashColor: AppTheme.surfaceContainerHigh,
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => ChatScreen(
                myUsername: _myUsername,
                receiverUsername: contact.username,
                receiverDisplayName: contact.displayName,
              ),
            ),
          ).then((_) => _loadContacts());
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              avatarWidget,
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Text(
                            contact.displayName.isNotEmpty ? contact.displayName : contact.username,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.outfit(
                              fontWeight: FontWeight.w700,
                              fontSize: 18,
                              color: AppTheme.onSurface,
                            ),
                          ),
                        ),
                        if (contact.lastMessageTime != null)
                          Text(
                            _formatTime(contact.lastMessageTime),
                            style: GoogleFonts.outfit(
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                              color: AppTheme.outline,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      contact.lastMessage ?? 'Tap to start chatting',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.outfit(
                        fontSize: 15,
                        color: AppTheme.onSurfaceVariant,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFallbackAvatar(Contact contact) {
    return Container(
      width: 56,
      height: 56,
      decoration: BoxDecoration(
        color: AppTheme.primaryContainer.withValues(alpha: 0.1),
        shape: BoxShape.circle,
      ),
      child: Center(
        child: Text(
          contact.username.isNotEmpty ? contact.username[0].toUpperCase() : '?',
          style: GoogleFonts.outfit(
            color: AppTheme.primary,
            fontWeight: FontWeight.w700,
            fontSize: 24,
          ),
        ),
      ),
    );
  }
}
