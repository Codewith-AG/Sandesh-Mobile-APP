import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart' hide Config;
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/message_model.dart';
import '../services/local_db_service.dart';
// app_theme.dart intentionally not imported — all colors from Theme.of(context)
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'group_info_screen.dart';

class GroupChatScreen extends StatefulWidget {
  final String myUsername;
  final String groupId;
  final String groupName;
  final String? groupAvatarUrl;

  const GroupChatScreen({
    super.key,
    required this.myUsername,
    required this.groupId,
    required this.groupName,
    this.groupAvatarUrl,
  });

  @override
  State<GroupChatScreen> createState() => _GroupChatScreenState();
}

class _GroupChatScreenState extends State<GroupChatScreen> {
  final _textController = TextEditingController();
  final _scrollController = ScrollController();
  final _focusNode = FocusNode();
  List<Message> _messages = [];
  bool _showEmojiPicker = false;

  /// Supabase Realtime channel for this group
  RealtimeChannel? _groupChannel;

  /// Member count — fetched from Supabase
  int _memberCount = 0;

  /// Cache: sender username → display name (from local contacts DB)
  final Map<String, String> _senderDisplayNames = {};

  /// Cached ColorScheme — set at the top of build() so all helper methods can use it.
  late ColorScheme _cs;

  /// Deterministic color palette for group sender names
  static const List<Color> _senderColors = [
    Color(0xFF1565C0), // Blue 800
    Color(0xFF2E7D32), // Green 800
    Color(0xFFC62828), // Red 800
    Color(0xFF6A1B9A), // Purple 800
    Color(0xFFEF6C00), // Orange 800
    Color(0xFF00838F), // Cyan 800
    Color(0xFFAD1457), // Pink 800
    Color(0xFF4527A0), // Deep Purple 800
    Color(0xFF283593), // Indigo 800
    Color(0xFF558B2F), // Light Green 800
    Color(0xFFD84315), // Deep Orange 800
    Color(0xFF00695C), // Teal 800
  ];

  @override
  void initState() {
    super.initState();
    _loadMessages();
    _loadMemberCount();
    _subscribeToGroupChannel();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _loadMessages();
    });
  }

  @override
  void dispose() {
    if (_groupChannel != null) {
      Supabase.instance.client.removeChannel(_groupChannel!);
      _groupChannel = null;
    }
    _textController.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  // ──────────────────────────── Data Loading ────────────────────────────

  Future<void> _loadMessages() async {
    try {
      final rows = await LocalDbService().getGroupMessages(widget.groupId);
      final messages = rows.map((row) => Message(
        id: row['id'] as String,
        senderUsername: row['sender_username'] as String,
        receiverUsername: widget.groupId,
        text: row['text'] as String?,
        messageType: MessageTypeX.fromString(row['message_type'] as String?),
        isMe: (row['sender_username'] as String).toLowerCase() == widget.myUsername.toLowerCase(),
        timestamp: row['timestamp'] as int,
      )).toList();
      if (mounted) {
        setState(() => _messages = messages);
        // Pre-load display names for all senders
        _preloadSenderNames();
        _scrollToBottom();
      }
    } catch (e) {
      debugPrint('Error loading group messages: $e');
    }
  }

  Future<void> _loadMemberCount() async {
    try {
      final response = await Supabase.instance.client
          .from('group_members')
          .select('id')
          .eq('group_id', widget.groupId);
      if (mounted) {
        setState(() => _memberCount = (response as List).length);
      }
    } catch (e) {
      debugPrint('Error loading member count: $e');
    }
  }

  /// Pre-loads display names for all unique senders in the current messages
  Future<void> _preloadSenderNames() async {
    final senders = _messages
        .where((m) => !m.isMe)
        .map((m) => m.senderUsername.toLowerCase())
        .toSet();
    for (final sender in senders) {
      if (!_senderDisplayNames.containsKey(sender)) {
        final name = await LocalDbService().getContactDisplayName(sender);
        if (name != null && mounted) {
          setState(() => _senderDisplayNames[sender] = name);
        }
      }
    }
  }

  /// Resolves display name for a sender: cached display name > username
  String _getSenderDisplayName(String username) {
    return _senderDisplayNames[username.toLowerCase()] ?? username;
  }

  /// Returns a deterministic color for a given sender username
  Color _getSenderColor(String username) {
    final hash = username.toLowerCase().hashCode.abs();
    return _senderColors[hash % _senderColors.length];
  }

  // ──────────────────────────── Realtime ────────────────────────────

  void _subscribeToGroupChannel() {
    _groupChannel = Supabase.instance.client
        .channel('group_${widget.groupId}')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'group_messages',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'group_id',
            value: widget.groupId,
          ),
          callback: _handleGroupMessage,
        )
        .subscribe((status, [error]) {
      debugPrint('Group channel status: $status${error != null ? " | $error" : ""}');
    });
  }

  void _handleGroupMessage(PostgresChangePayload payload) async {
    final row = payload.newRecord;
    if (row.isEmpty) return;

    final senderUsername = row['sender_username'] as String;
    // Ignore messages sent by self — we already added them locally in _sendMessage()
    if (senderUsername.toLowerCase() == widget.myUsername.toLowerCase()) return;

    final message = Message(
      id: row['id'] as String,
      senderUsername: senderUsername,
      receiverUsername: widget.groupId, // group_id stored in receiver field
      text: row['text'] as String?,
      messageType: MessageTypeX.fromString(row['message_type'] as String?),
      isMe: false,
      timestamp: row['timestamp'] as int,
    );

    // Save locally
    try {
      await LocalDbService().insertGroupMessage({
        'id': message.id,
        'group_id': widget.groupId,
        'sender_username': message.senderUsername,
        'text': message.text,
        'message_type': message.messageType.value,
        'timestamp': message.timestamp,
      });
    } catch (e) {
      debugPrint('Error saving incoming group message locally: $e');
    }

    // Resolve sender display name if needed
    if (!_senderDisplayNames.containsKey(senderUsername.toLowerCase())) {
      final name = await LocalDbService().getContactDisplayName(senderUsername);
      if (name != null && mounted) {
        _senderDisplayNames[senderUsername.toLowerCase()] = name;
      }
    }

    if (!mounted) return;
    setState(() {
      if (!_messages.any((m) => m.id == message.id)) {
        _messages.add(message);
      }
    });
    _scrollToBottom();
  }

  // ──────────────────────────── Sending ────────────────────────────

  Future<void> _sendMessage() async {
    final text = _textController.text.trim();
    if (text.isEmpty) return;
    _textController.clear();

    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final msg = Message(
      id: '${widget.myUsername}_$timestamp',
      senderUsername: widget.myUsername,
      receiverUsername: widget.groupId,
      text: text,
      messageType: MessageType.text,
      isMe: true,
      timestamp: timestamp,
    );

    setState(() => _messages.add(msg));
    _scrollToBottom();

    // Save locally
    try {
      await LocalDbService().insertGroupMessage({
        'id': msg.id,
        'group_id': widget.groupId,
        'sender_username': msg.senderUsername,
        'text': msg.text,
        'message_type': msg.messageType.value,
        'timestamp': msg.timestamp,
      });
    } catch (e) {
      debugPrint('Error saving group message locally: $e');
    }

    // Insert into Supabase group_messages table
    try {
      await Supabase.instance.client.from('group_messages').insert({
        'id': msg.id,
        'group_id': widget.groupId,
        'sender_username': msg.senderUsername.toLowerCase(),
        'text': msg.text,
        'message_type': msg.messageType.value,
        'timestamp': msg.timestamp,
      });
    } catch (e) {
      debugPrint('Error sending group message to Supabase: $e');
      if (mounted) _showError('Failed to send message: $e');
    }
  }

  // ──────────────────────────── UI Helpers ────────────────────────────

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      Future.delayed(const Duration(milliseconds: 80), () {
        if (_scrollController.hasClients) {
          _scrollController.animateTo(
            _scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut,
          );
        }
      });
    }
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: GoogleFonts.outfit()),
      backgroundColor: _cs.error,
      behavior: SnackBarBehavior.floating,
    ));
  }

  List<dynamic> _buildMessageListWithDates() {
    if (_messages.isEmpty) return [];
    final List<dynamic> items = [];
    String? lastDateLabel;
    for (final msg in _messages) {
      final date = DateTime.fromMillisecondsSinceEpoch(msg.timestamp);
      final now = DateTime.now();
      final diff = DateTime(now.year, now.month, now.day)
          .difference(DateTime(date.year, date.month, date.day)).inDays;
      final dateLabel = diff == 0 ? 'Today' : diff == 1 ? 'Yesterday' : DateFormat('MMMM dd, yyyy').format(date);
      if (dateLabel != lastDateLabel) { items.add(dateLabel); lastDateLabel = dateLabel; }
      items.add(msg);
    }
    return items;
  }

  void _showClearChatConfirm() {
    final cs = _cs;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: cs.surface,
        title: Text('Clear Chat', style: GoogleFonts.outfit(fontWeight: FontWeight.w700, color: cs.onSurface)),
        content: Text('Are you sure you want to delete all group messages locally? This cannot be undone.', style: GoogleFonts.outfit(color: cs.onSurfaceVariant)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text('Cancel', style: GoogleFonts.outfit(color: cs.outline))),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(ctx);
              try {
                await LocalDbService().deleteGroupMessages(widget.groupId);
              } catch (_) {}
              if (mounted) {
                setState(() {
                  _messages.clear();
                });
              }
            },
            style: ElevatedButton.styleFrom(backgroundColor: cs.error),
            child: Text('Clear', style: GoogleFonts.outfit(color: cs.onError)),
          ),
        ],
      ),
    );
  }

  // ──────────────────────────── Build ────────────────────────────

  @override
  Widget build(BuildContext context) {
    _cs = Theme.of(context).colorScheme;
    final items = _buildMessageListWithDates();
    return Scaffold(
      backgroundColor: _cs.surface,
      appBar: _buildAppBar(),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView.builder(
                controller: _scrollController,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                itemCount: items.length,
                itemBuilder: (context, index) {
                  final item = items[index];
                  if (item is String) return _buildDateSeparator(item);
                  return _buildMessageBubble(item as Message);
                },
              ),
            ),
            _buildInputBar(),
            if (_showEmojiPicker)
              SizedBox(
                height: 250,
                child: EmojiPicker(
                  textEditingController: _textController,
                  config: Config(
                    height: 250,
                    checkPlatformCompatibility: true,
                    emojiViewConfig: EmojiViewConfig(
                      backgroundColor: _cs.surfaceContainerLow,
                      columns: 7, emojiSizeMax: 32,
                    ),
                    categoryViewConfig: CategoryViewConfig(
                      backgroundColor: _cs.surfaceContainerLow,
                      indicatorColor: _cs.primary,
                      iconColorSelected: _cs.primary,
                    ),
                    bottomActionBarConfig: BottomActionBarConfig(
                      backgroundColor: _cs.surfaceContainerLow,
                      buttonColor: _cs.surfaceContainerLow,
                      buttonIconColor: _cs.primary,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    final cs = _cs;
    return AppBar(
      backgroundColor: cs.surfaceContainerLowest,
      titleSpacing: 0,
      leading: IconButton(
        icon: Icon(Icons.arrow_back_ios_new, size: 20, color: cs.onSurface),
        onPressed: () => Navigator.pop(context),
      ),
      title: GestureDetector(
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => GroupInfoScreen(
                groupId: widget.groupId,
                groupName: widget.groupName,
                myUsername: widget.myUsername,
              ),
            ),
          );
        },
        child: Row(
          children: [
            _buildGroupAvatar(cs),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.groupName,
                    style: GoogleFonts.outfit(fontSize: 18, fontWeight: FontWeight.w700, color: cs.onSurface),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    _memberCount > 0 ? '$_memberCount members' : 'Group',
                    style: GoogleFonts.outfit(fontSize: 13, color: cs.onSurfaceVariant, fontWeight: FontWeight.w400),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        PopupMenuButton<String>(
          icon: Icon(Icons.more_vert_rounded, color: cs.onSurfaceVariant, size: 24),
          onSelected: (value) {
            if (value == 'clear') {
              _showClearChatConfirm();
            } else if (value == 'info') {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => GroupInfoScreen(
                    groupId: widget.groupId,
                    groupName: widget.groupName,
                    myUsername: widget.myUsername,
                  ),
                ),
              );
            }
          },
          itemBuilder: (context) => [
            PopupMenuItem(value: 'info', child: Text('Group Info', style: GoogleFonts.outfit())),
            PopupMenuItem(value: 'clear', child: Text('Clear Chat', style: GoogleFonts.outfit())),
          ],
        ),
        const SizedBox(width: 4),
      ],
    );
  }

  Widget _buildGroupAvatar(ColorScheme cs) {
    final url = widget.groupAvatarUrl;
    if (url != null && url.startsWith('http')) {
      return CircleAvatar(
        radius: 20,
        backgroundColor: cs.surfaceContainerHigh,
        backgroundImage: NetworkImage(url),
        onBackgroundImageError: (_, __) {},
      );
    }
    return CircleAvatar(
      radius: 20,
      backgroundColor: cs.surfaceContainerHigh,
      child: Icon(Icons.group_rounded, color: cs.primary, size: 22),
    );
  }

  Widget _buildDateSeparator(String label) {
    final cs = _cs;
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 16),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: cs.surfaceContainerLowest,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: cs.outlineVariant),
        ),
        child: Text(label, style: GoogleFonts.outfit(fontSize: 12, fontWeight: FontWeight.w600, color: cs.onSurfaceVariant)),
      ),
    );
  }

  // ──────────────────────────── Message Bubbles ────────────────────────────

  Widget _buildMessageBubble(Message message) {
    final isMe = message.isMe;
    final timeString = DateFormat('h:mm a').format(DateTime.fromMillisecondsSinceEpoch(message.timestamp));

    // System notices (member added/removed, group created, admin changes,
    // photo changed) render as a centered pill, WhatsApp-style.
    if (message.messageType == MessageType.system) {
      return Center(
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 8),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
            color: _cs.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            message.text ?? '',
            textAlign: TextAlign.center,
            style: GoogleFonts.outfit(
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
                color: _cs.onSurfaceVariant),
          ),
        ),
      );
    }

    // Check if previous message is from the same sender (for grouping)
    final msgIndex = _messages.indexOf(message);
    final showSenderName = !isMe && (msgIndex == 0 ||
        _messages[msgIndex - 1].senderUsername.toLowerCase() != message.senderUsername.toLowerCase() ||
        _messages[msgIndex - 1].isMe);

    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: EdgeInsets.only(bottom: 8, top: showSenderName ? 4 : 0),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
        child: _buildTextBubble(message, isMe, timeString, showSenderName),
      ),
    );
  }

  Widget _buildTextBubble(Message message, bool isMe, String timeString, bool showSenderName) {
    final cs = _cs;
    final senderColor = _getSenderColor(message.senderUsername);
    final senderName = _getSenderDisplayName(message.senderUsername);

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
      decoration: BoxDecoration(
        color: isMe ? cs.primary : cs.surfaceContainerHighest,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(24), topRight: const Radius.circular(24),
          bottomLeft: Radius.circular(isMe ? 24 : 8), bottomRight: Radius.circular(isMe ? 8 : 24),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Sender name label for non-self messages
          if (showSenderName && !isMe) ...[
            Text(
              senderName,
              style: GoogleFonts.outfit(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: senderColor,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 4),
          ],
          Text(message.text ?? '', style: GoogleFonts.outfit(
              color: isMe ? cs.onPrimary : cs.onSurface, fontSize: 16, height: 1.4)),
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerRight,
            child: _buildTimestamp(timeString, isMe, cs),
          ),
        ],
      ),
    );
  }

  Widget _buildTimestamp(String timeString, bool isMe, ColorScheme cs) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(timeString, style: GoogleFonts.outfit(
            color: isMe ? cs.onPrimary.withValues(alpha: 0.8) : cs.onSurfaceVariant,
            fontSize: 11, fontWeight: FontWeight.w500)),
        if (isMe) ...[
          const SizedBox(width: 4),
          Icon(Icons.done_all, size: 14, color: cs.onPrimary.withValues(alpha: 0.8)),
        ],
      ],
    );
  }

  // ──────────────────────────── Input Bar ────────────────────────────

  Widget _buildInputBar() {
    final cs = _cs;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLowest,
        border: Border(top: BorderSide(color: cs.outlineVariant, width: 1)),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Container(
                constraints: const BoxConstraints(maxHeight: 120),
                decoration: BoxDecoration(
                  color: cs.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: cs.outlineVariant),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    IconButton(
                      icon: Icon(_showEmojiPicker ? Icons.keyboard_outlined : Icons.emoji_emotions_outlined,
                          color: cs.onSurfaceVariant, size: 24),
                      onPressed: () => setState(() {
                        _showEmojiPicker = !_showEmojiPicker;
                        if (_showEmojiPicker) {
                          FocusManager.instance.primaryFocus?.unfocus();
                        } else {
                          _focusNode.requestFocus();
                        }
                      }),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                    ),
                    Expanded(
                      child: TextField(
                        controller: _textController,
                        focusNode: _focusNode,
                        maxLines: null,
                        textInputAction: TextInputAction.newline,
                        style: GoogleFonts.outfit(fontSize: 16, color: cs.onSurface),
                        onTap: () { if (_showEmojiPicker) setState(() => _showEmojiPicker = false); },
                        decoration: InputDecoration(
                          hintText: 'Type a message...',
                          hintStyle: GoogleFonts.outfit(color: cs.onSurfaceVariant, fontSize: 16),
                          border: InputBorder.none, enabledBorder: InputBorder.none, focusedBorder: InputBorder.none,
                          contentPadding: const EdgeInsets.symmetric(vertical: 14),
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 12),
            Container(
              width: 48, height: 48,
              decoration: BoxDecoration(
                color: cs.primary,
                shape: BoxShape.circle,
              ),
              child: IconButton(
                icon: Icon(Icons.send_rounded, color: cs.onPrimary, size: 22),
                onPressed: _sendMessage,
                padding: EdgeInsets.zero,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
