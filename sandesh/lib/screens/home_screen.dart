import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:intl/intl.dart';
import 'package:flutter_contacts/flutter_contacts.dart' as fc;
import 'package:permission_handler/permission_handler.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/contact_model.dart';
import '../models/message_model.dart';
import '../models/group_model.dart';
import '../services/local_db_service.dart';
import '../services/supabase_broadcast_service.dart';
import '../services/call_service.dart';
// app_theme.dart intentionally not imported — all colors from Theme.of(context)
import '../widgets/user_avatar.dart';
import 'chat_screen.dart';
import 'profile_screen.dart';
import 'settings_screen.dart';
import 'login_screen.dart';
import 'create_group_screen.dart';
import 'group_chat_screen.dart';
import 'calls_tab.dart';
import 'dart:async';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  String _myUsername = '';
  String _myAvatarUrl = '';
  List<Contact> _contacts = [];
  List<Group> _groups = [];
  bool _isLoading = true;
  StreamSubscription<Message>? _messageSubscription;
  bool _isSearching = false;
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();
  late TabController _tabController;
  int _currentTab = 0;
  
  bool _isSelectionMode = false;
  final Set<String> _selectedUsernames = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _tabController = TabController(length: 3, vsync: this);
    _tabController.addListener(() {
      if (mounted) setState(() => _currentTab = _tabController.index);
    });
    _loadInitialData();
    _messageSubscription = SupabaseBroadcastService().messageStream.listen((_) {
      if (mounted) {
        _loadContacts();
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _messageSubscription?.cancel();
    _tabController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // When the app returns to the foreground, messages that arrived via FCM
    // while it was backgrounded were saved to the local DB by the background
    // handler — but the Realtime insert event was already consumed, so the
    // message stream never fires on resume. Without this, the new chat/message
    // only appeared after a manual app restart. Re-sync + reload so everything
    // shows up instantly on resume (no manual reload needed).
    if (state == AppLifecycleState.resumed && _myUsername.isNotEmpty) {
      // Make sure the realtime channel is still alive (idempotent).
      SupabaseBroadcastService().initialize(_myUsername);
      // Pull anything still sitting in the cloud, then refresh the lists.
      SupabaseBroadcastService().syncPendingMessages();
      _loadContacts();
      _loadGroups();
    }
  }

  Future<void> _loadInitialData() async {
    // Primary: SharedPreferences (stores the phone-number-based username)
    final prefs = await SharedPreferences.getInstance();
    _myUsername = prefs.getString('username') ?? '';

    // Fallback: Supabase session metadata (only for legacy/migration)
    if (_myUsername.isEmpty) {
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
    await _loadGroups();

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

  Future<void> _loadGroups() async {
    try {
      await _syncGroupsFromSupabase();
      final groups = await LocalDbService().getGroupsWithLastMessage();
      if (mounted) {
        setState(() => _groups = groups);
      }
    } catch (e) {
      debugPrint('Error loading groups: $e');
    }
  }

  Future<void> _syncGroupsFromSupabase() async {
    try {
      final supabase = Supabase.instance.client;
      final memberRows = await supabase
          .from('group_members')
          .select('group_id')
          .eq('username', _myUsername.toLowerCase());
      if (memberRows.isEmpty) return;

      final groupIds = (memberRows as List)
          .map((r) => r['group_id'] as String)
          .toList();

      final groupRows = await supabase
          .from('groups')
          .select()
          .inFilter('id', groupIds);

      for (final row in groupRows) {
        final group = Group(
          id: row['id'] as String,
          name: row['name'] as String,
          description: (row['description'] as String?) ?? '',
          avatarUrl: (row['avatar_url'] as String?) ?? '',
          createdBy: row['created_by'] as String,
          createdAt: DateTime.tryParse(row['created_at'] as String? ?? '')
                  ?.millisecondsSinceEpoch ??
              0,
        );
        await LocalDbService().insertGroup(group);

        final members = await supabase
            .from('group_members')
            .select()
            .eq('group_id', group.id);
        for (final m in members) {
          await LocalDbService().insertGroupMember(
            group.id,
            m['username'] as String,
            role: (m['role'] as String?) ?? 'member',
          );
        }
      }
    } catch (e) {
      debugPrint('Error syncing groups from Supabase: $e');
    }
  }

  Future<void> _refreshContacts() async {
    await SupabaseBroadcastService().discoverContacts();
    await _syncDeviceContacts();
    await _loadContacts();
    await _loadGroups();

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
        final cs = Theme.of(context).colorScheme;
        return Container(
          padding: EdgeInsets.only(
            left: 24,
            right: 24,
            top: 24,
            bottom: MediaQuery.of(context).viewInsets.bottom + 24,
          ),
          decoration: BoxDecoration(
            color: cs.surfaceContainerLowest,
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(28)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 48,
                height: 5,
                decoration: BoxDecoration(
                  color: cs.outlineVariant,
                  borderRadius: BorderRadius.circular(100),
                ),
              ),
              const SizedBox(height: 24),
              Text(
                'New Conversation',
                style: GoogleFonts.inter(
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                  color: cs.onSurface,
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: controller,
                style: GoogleFonts.inter(
                  fontSize: 16,
                  color: cs.onSurface,
                ),
                decoration: InputDecoration(
                  hintText: 'Enter username or phone number',
                  hintStyle: GoogleFonts.inter(color: cs.onSurfaceVariant),
                  filled: true,
                  fillColor: cs.surfaceContainerHigh,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(999),
                    borderSide: BorderSide.none,
                  ),
                  prefixIcon: Icon(Icons.person_outline_rounded,
                      color: cs.primary),
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: cs.primary,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                  onPressed: () async {
                    final username = controller.text.trim();
                    if (username.isNotEmpty) {
                      final exists =
                          await LocalDbService().contactExists(username);
                      if (!exists) {
                        await LocalDbService().insertContact(Contact(
                          username: username,
                          phone: '',
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
                    style: GoogleFonts.inter(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: cs.onPrimary,
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

  Future<void> _deleteSelectedChats() async {
    final cs = Theme.of(context).colorScheme;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: cs.surface,
        title: Text('Delete ${_selectedUsernames.length == 1 ? "conversation" : "conversations"}', style: GoogleFonts.inter(fontWeight: FontWeight.w700, color: cs.onSurface)),
        content: Text('Are you sure you want to delete ${_selectedUsernames.length == 1 ? "this conversation" : "these ${_selectedUsernames.length} conversations"}?', style: GoogleFonts.inter(color: cs.onSurfaceVariant)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('Cancel', style: GoogleFonts.inter(color: cs.outline))),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: cs.error),
            child: Text('Delete', style: GoogleFonts.inter(color: cs.onError)),
          ),
        ],
      ),
    );

    if (confirm == true && mounted) {
      final supabase = Supabase.instance.client;
      for (final u in _selectedUsernames) {
        await LocalDbService().deleteChatHistory(_myUsername, u);
        // Also remove the contact row so the conversation disappears from the
        // home list instead of lingering as an empty chat.
        await LocalDbService().deleteContact(u);
        try {
          await supabase.from('messages').delete().or(
            'and(sender_username.eq.$_myUsername,receiver_username.eq.$u),and(sender_username.eq.$u,receiver_username.eq.$_myUsername)'
          );
        } catch (e) {
          debugPrint('Error deleting server messages: $e');
        }
      }
      if (mounted) {
        setState(() {
          _isSelectionMode = false;
          _selectedUsernames.clear();
        });
        _loadContacts();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    final filteredContacts = _searchQuery.isEmpty
        ? _contacts
        : _contacts.where((c) {
            final query = _searchQuery.toLowerCase();
            return c.displayName.toLowerCase().contains(query) ||
                c.username.toLowerCase().contains(query);
          }).toList();

    return Scaffold(
      appBar: AppBar(
        backgroundColor: _isSelectionMode ? cs.surfaceContainerHigh : null,
        leading: _isSelectionMode
            ? IconButton(
                icon: const Icon(Icons.close_rounded),
                onPressed: () => setState(() {
                  _isSelectionMode = false;
                  _selectedUsernames.clear();
                }),
              )
            : Padding(
          padding: const EdgeInsets.only(left: 20),
          child: GestureDetector(
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const ProfileScreen()),
              ).then((_) => _loadContacts());
            },
            child: UserAvatar(
              imageUrl: _myAvatarUrl.startsWith('http') ? _myAvatarUrl : null,
              name: _myUsername,
              radius: 20,
            ),
          ),
        ),
        title: _isSelectionMode
            ? Text('${_selectedUsernames.length} Selected', style: GoogleFonts.inter(color: cs.onSurface, fontWeight: FontWeight.w700))
            : (_isSearching
                ? TextField(
                    controller: _searchController,
                    autofocus: true,
                    style: GoogleFonts.inter(color: cs.onSurface, fontSize: 16),
                    decoration: InputDecoration(
                      hintText: 'Search chats...',
                      border: InputBorder.none,
                      hintStyle: GoogleFonts.inter(color: cs.onSurfaceVariant),
                    ),
                    onChanged: (value) {
                      setState(() {
                        _searchQuery = value.toLowerCase();
                      });
                    },
                  )
                : Text(
                    'Sandesh',
                    style: GoogleFonts.inter(
                      fontWeight: FontWeight.w800,
                      fontSize: 28,
                      color: cs.primary,
                      letterSpacing: -0.01,
                    ),
                  )),
        actions: _isSelectionMode
            ? [
                IconButton(
                  icon: const Icon(Icons.select_all_rounded),
                  onPressed: () => setState(() => _selectedUsernames.addAll(filteredContacts.map((c) => c.username))),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline_rounded),
                  color: cs.error,
                  onPressed: _deleteSelectedChats,
                ),
                const SizedBox(width: 8),
              ]
            : [
          IconButton(
            icon: Icon(
              _isSearching ? Icons.close_rounded : Icons.search_rounded,
              color: cs.onSurfaceVariant,
            ),
            onPressed: () {
              setState(() {
                if (_isSearching) {
                  _isSearching = false;
                  _searchController.clear();
                  _searchQuery = '';
                } else {
                  _isSearching = true;
                }
              });
            },
          ),
          PopupMenuButton<String>(
            icon: Icon(Icons.more_vert_rounded, color: cs.onSurfaceVariant),
            color: cs.surfaceContainerLowest,
            elevation: 8,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            onSelected: (value) async {
              if (value == 'settings') {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const SettingsScreen()),
                ).then((_) => _refreshContacts());
              } else if (value == 'logout') {
                // Capture navigator BEFORE any await gap (including showDialog).
                final navigator = Navigator.of(context);
                final confirm = await showDialog<bool>(
                  context: context,
                  builder: (ctx) {
                    final dcs = Theme.of(ctx).colorScheme;
                    return AlertDialog(
                      backgroundColor: dcs.surfaceContainerLowest,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(24)),
                      title: Text('Logout',
                          style: GoogleFonts.inter(
                              fontWeight: FontWeight.w700,
                              color: dcs.onSurface)),
                      content: Text(
                          'Are you sure you want to logout? Your chat history will be preserved locally.',
                          style:
                              GoogleFonts.inter(color: dcs.onSurfaceVariant)),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: Text('Cancel',
                              style: GoogleFonts.inter(color: dcs.outline)),
                        ),
                        ElevatedButton(
                          onPressed: () => Navigator.pop(ctx, true),
                          style: ElevatedButton.styleFrom(
                              backgroundColor: dcs.error),
                          child: Text('Logout',
                              style: GoogleFonts.inter(color: dcs.onError)),
                        ),
                      ],
                    );
                  },
                );

                if (confirm == true && mounted) {
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.clear();
                  SupabaseBroadcastService().dispose();
                  try {
                    await Supabase.instance.client.auth.signOut();
                  } catch (_) {}
                  if (mounted) {
                    navigator.pushAndRemoveUntil(
                      MaterialPageRoute(builder: (_) => const LoginScreen()),
                      (route) => false,
                    );
                  }
                }
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'settings',
                child: Text('Settings', style: GoogleFonts.inter()),
              ),
              PopupMenuItem(
                value: 'logout',
                child: Text('Log Out',
                    style: GoogleFonts.inter(color: cs.error)),
              ),
            ],
          ),
          const SizedBox(width: 12),
        ],
        bottom: TabBar(
          controller: _tabController,
          labelStyle:
              GoogleFonts.inter(fontWeight: FontWeight.w700, fontSize: 15),
          unselectedLabelStyle:
              GoogleFonts.inter(fontWeight: FontWeight.w500, fontSize: 15),
          labelColor: cs.primary,
          unselectedLabelColor: cs.onSurfaceVariant,
          indicator: UnderlineTabIndicator(
            borderSide: BorderSide(width: 3.0, color: cs.primary),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(3)),
          ),
          indicatorSize: TabBarIndicatorSize.label,
          dividerHeight: 0.5,
          dividerColor: cs.outlineVariant.withValues(alpha: 0.3),
          tabs: const [
            Tab(text: 'Chats'),
            Tab(text: 'Groups'),
            Tab(text: 'Calls'),
          ],
        ),
      ),
      body: _isLoading
          ? Center(child: CircularProgressIndicator(color: cs.primary))
          : TabBarView(
              controller: _tabController,
              children: [
                // ── Chats tab ──
                filteredContacts.isEmpty
                    ? _buildEmptyState(context)
                    : RefreshIndicator(
                        onRefresh: _refreshContacts,
                        color: cs.primary,
                        backgroundColor: cs.surfaceContainerLowest,
                        child: ListView.separated(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          itemCount: filteredContacts.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 4),
                          itemBuilder: (context, index) {
                            return _buildContactTile(
                                context, filteredContacts[index]);
                          },
                        ),
                      ),
                // ── Groups tab ──
                _groups.isEmpty
                    ? _buildEmptyGroupsState(context)
                    : RefreshIndicator(
                        onRefresh: _refreshContacts,
                        color: cs.primary,
                        backgroundColor: cs.surfaceContainerLowest,
                        child: ListView.separated(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          itemCount: _groups.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 4),
                          itemBuilder: (context, index) {
                            return _buildGroupTile(context, _groups[index]);
                          },
                        ),
                      ),
                // ── Calls tab ──
                CallsTab(myUsername: _myUsername),
              ],
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: _currentTab == 0
            ? _addContactDialog
            : _currentTab == 1
                ? () async {
                    // Capture navigator BEFORE await Navigator.push to avoid
                    // BuildContext-across-async-gap lint.
                    final nav = Navigator.of(context);
                    final group = await nav.push<Group>(
                      MaterialPageRoute(
                        builder: (_) =>
                            CreateGroupScreen(myUsername: _myUsername),
                      ),
                    );
                    if (group != null) {
                      await _loadGroups();
                      if (mounted) {
                        nav.push(
                          MaterialPageRoute(
                            builder: (_) => GroupChatScreen(
                              myUsername: _myUsername,
                              groupId: group.id,
                              groupName: group.name,
                            ),
                          ),
                        ).then((_) => _loadGroups());
                      }
                    }
                  }
                : _addContactDialog,
        elevation: 3,
        backgroundColor: cs.primary,
        foregroundColor: cs.onPrimary,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Icon(
          _currentTab == 0
              ? Icons.chat_bubble_rounded
              : _currentTab == 1
                  ? Icons.group_add_rounded
                  : Icons.add_call,
          size: 24,
        ),
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 120,
            height: 120,
            decoration: BoxDecoration(
              color: cs.surfaceContainerHigh,
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.chat_bubble_outline_rounded,
                size: 56, color: cs.primary),
          ),
          const SizedBox(height: 24),
          Text('No conversations yet',
              style: GoogleFonts.inter(
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                  color: cs.onSurface)),
          const SizedBox(height: 8),
          Text('Tap the button below to start chatting',
              style: GoogleFonts.inter(
                  fontSize: 16, color: cs.onSurfaceVariant)),
        ],
      ),
    );
  }

  Widget _buildEmptyGroupsState(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 120,
            height: 120,
            decoration: BoxDecoration(
              color: cs.surfaceContainerHigh,
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.group_outlined, size: 56, color: cs.primary),
          ),
          const SizedBox(height: 24),
          Text('No groups yet',
              style: GoogleFonts.inter(
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                  color: cs.onSurface)),
          const SizedBox(height: 8),
          Text('Tap the button below to create a group',
              style: GoogleFonts.inter(
                  fontSize: 16, color: cs.onSurfaceVariant)),
        ],
      ),
    );
  }

  Widget _buildContactTile(BuildContext context, Contact contact) {
    final cs = Theme.of(context).colorScheme;
    final avatarWidget = UserAvatar(
      imageUrl: contact.avatarUrl.startsWith('http') ? contact.avatarUrl : null,
      name: contact.displayName.isNotEmpty ? contact.displayName : contact.username,
      radius: 24,
    );

    final isSelected = _selectedUsernames.contains(contact.username);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        hoverColor: cs.surfaceContainer,
        splashColor: cs.surfaceContainerHigh,
        onLongPress: () {
          if (!_isSelectionMode) {
            setState(() {
              _isSelectionMode = true;
              _selectedUsernames.add(contact.username);
            });
          }
        },
        onTap: () {
          if (_isSelectionMode) {
            setState(() {
              if (isSelected) {
                _selectedUsernames.remove(contact.username);
                if (_selectedUsernames.isEmpty) _isSelectionMode = false;
              } else {
                _selectedUsernames.add(contact.username);
              }
            });
          } else {
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
          }
        },
        child: Container(
          decoration: BoxDecoration(
            color: isSelected ? cs.primaryContainer.withValues(alpha: 0.3) : Colors.transparent,
            borderRadius: BorderRadius.circular(24),
          ),
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
                            contact.displayName.isNotEmpty
                                ? contact.displayName
                                : contact.username,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.inter(
                                fontWeight: FontWeight.w600,
                                fontSize: 16,
                                color: cs.onSurface),
                          ),
                        ),
                        if (contact.lastMessageTime != null)
                          Text(
                            _formatTime(contact.lastMessageTime),
                            style: GoogleFonts.inter(
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                                color: cs.outline),
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      contact.lastMessage ?? 'Tap to start chatting',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                          fontSize: 14,
                          color: cs.onSurfaceVariant,
                          fontWeight: FontWeight.w400),
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

  Widget _buildGroupTile(BuildContext context, Group group) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        hoverColor: cs.surfaceContainer,
        splashColor: cs.surfaceContainerHigh,
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => GroupChatScreen(
                myUsername: _myUsername,
                groupId: group.id,
                groupName: group.name,
                groupAvatarUrl:
                    group.avatarUrl.isNotEmpty ? group.avatarUrl : null,
              ),
            ),
          ).then((_) => _loadGroups());
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              CircleAvatar(
                radius: 24,
                backgroundColor: cs.primaryContainer.withValues(alpha: 0.3),
                backgroundImage: group.avatarUrl.startsWith('http')
                    ? NetworkImage(group.avatarUrl)
                    : null,
                child: group.avatarUrl.startsWith('http')
                    ? null
                    : Text(
                        group.name.isNotEmpty
                            ? group.name[0].toUpperCase()
                            : 'G',
                        style: GoogleFonts.inter(
                            color: cs.primary,
                            fontWeight: FontWeight.w700,
                            fontSize: 22),
                      ),
              ),
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
                            group.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.inter(
                                fontWeight: FontWeight.w600,
                                fontSize: 16,
                                color: cs.onSurface),
                          ),
                        ),
                        if (group.lastMessageTime != null)
                          Text(
                            _formatTime(group.lastMessageTime),
                            style: GoogleFonts.inter(
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                                color: cs.outline),
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      group.lastMessage != null
                          ? '${group.lastMessageSender ?? ''}: ${group.lastMessage}'
                          : '${group.members.length} members',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                          fontSize: 14,
                          color: cs.onSurfaceVariant,
                          fontWeight: FontWeight.w400),
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

}
