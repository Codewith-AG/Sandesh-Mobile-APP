import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart' hide Config;
import 'package:intl/intl.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/message_model.dart';
import '../services/local_db_service.dart';
import '../services/media_upload_service.dart';
import '../services/supabase_broadcast_service.dart';
// app_theme.dart intentionally not imported — all colors from Theme.of(context)
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'group_info_screen.dart';
import 'media_viewer_screen.dart';
import '../widgets/linkified_text.dart';

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
  bool _hasText = false;
  bool _isSendingMedia = false;
  double _uploadProgress = 0;

  /// Supabase Realtime channel for this group
  RealtimeChannel? _groupChannel;

  /// Member count — fetched from Supabase
  int _memberCount = 0;

  /// Cache: sender username → display name (from local contacts DB)
  final Map<String, String> _senderDisplayNames = {};

  /// Cached ColorScheme — set at the top of build() so all helper methods can use it.
  late ColorScheme _cs;

  /// #1 Selection mode — ids of messages currently multi-selected.
  final Set<String> _selectedIds = {};
  bool get _selectionMode => _selectedIds.isNotEmpty;

  /// #2 The message currently being replied to (null when not replying).
  Message? _replyTo;

  /// #1 Listens for delete-for-everyone signals (group) from the service.
  StreamSubscription<String>? _deletionSub;

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
    _syncGroupMessagesFromServer();
    _loadMemberCount();
    _subscribeToGroupChannel();
    // #1: mirror delete-for-everyone signals that reach this device.
    _deletionSub = SupabaseBroadcastService().deletionStream.listen((id) {
      if (!mounted) return;
      setState(() {
        _messages.removeWhere((m) => m.id == id);
        _selectedIds.remove(id);
      });
    });
    _textController.addListener(() {
      final hasText = _textController.text.trim().isNotEmpty;
      if (_hasText != hasText) {
        if (mounted) setState(() => _hasText = hasText);
      }
    });
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
    _deletionSub?.cancel();
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
        mediaUrl: row['media_url'] as String?,
        fileName: row['file_name'] as String?,
        localPath: row['local_path'] as String?,
        messageType: MessageTypeX.fromString(row['message_type'] as String?),
        isMe: (row['sender_username'] as String).toLowerCase() == widget.myUsername.toLowerCase(),
        timestamp: row['timestamp'] as int,
        replyToId: row['reply_to_id'] as String?,
        replyToSender: row['reply_to_sender'] as String?,
        replyToText: row['reply_to_text'] as String?,
        replyToType: row['reply_to_type'] as String?,
      )).toList();
      // Ensure chronological order (oldest → newest) regardless of query order.
      messages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
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

  /// Pulls the full group message history from Supabase and stores it locally,
  /// then refreshes the UI. Without this, a member only ever sees messages that
  /// arrived via Realtime while they had this screen open (plus their own),
  /// which is why group members previously couldn't see the conversation
  /// history. RLS ("Members can read group messages") ensures a user only
  /// receives messages for groups they belong to.
  Future<void> _syncGroupMessagesFromServer() async {
    try {
      final rows = await Supabase.instance.client
          .from('group_messages')
          .select()
          .eq('group_id', widget.groupId)
          .order('timestamp', ascending: true);

      for (final row in (rows as List)) {
        await LocalDbService().insertGroupMessage({
          'id': row['id'],
          'group_id': row['group_id'],
          'sender_username': row['sender_username'],
          'text': row['text'],
          'media_url': row['media_url'],
          'file_name': row['file_name'],
          'message_type': row['message_type'] ?? 'text',
          'timestamp': row['timestamp'],
          'reply_to_id': row['reply_to_id'],
          'reply_to_sender': row['reply_to_sender'],
          'reply_to_text': row['reply_to_text'],
          'reply_to_type': row['reply_to_type'],
        });
      }

      if (mounted) await _loadMessages();
    } catch (e) {
      debugPrint('Error syncing group messages from server: $e');
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
        .onPostgresChanges(
          // #1: when a member deletes their group message for everyone the
          // cloud row is removed — mirror that removal live for everyone.
          event: PostgresChangeEvent.delete,
          schema: 'public',
          table: 'group_messages',
          callback: (payload) {
            final id = payload.oldRecord['id'] as String?;
            if (id == null) return;
            LocalDbService().deleteGroupMessageById(id);
            if (!mounted) return;
            setState(() {
              _messages.removeWhere((m) => m.id == id);
              _selectedIds.remove(id);
            });
          },
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
      mediaUrl: row['media_url'] as String?,
      fileName: row['file_name'] as String?,
      messageType: MessageTypeX.fromString(row['message_type'] as String?),
      isMe: false,
      timestamp: row['timestamp'] as int,
      replyToId: row['reply_to_id'] as String?,
      replyToSender: row['reply_to_sender'] as String?,
      replyToText: row['reply_to_text'] as String?,
      replyToType: row['reply_to_type'] as String?,
    );

    // Save locally
    try {
      await LocalDbService().insertGroupMessage({
        'id': message.id,
        'group_id': widget.groupId,
        'sender_username': message.senderUsername,
        'text': message.text,
        'media_url': message.mediaUrl,
        'file_name': message.fileName,
        'message_type': message.messageType.value,
        'timestamp': message.timestamp,
        'reply_to_id': message.replyToId,
        'reply_to_sender': message.replyToSender,
        'reply_to_text': message.replyToText,
        'reply_to_type': message.replyToType,
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

    final reply = _replyTo;
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final msg = Message(
      id: '${widget.myUsername}_$timestamp',
      senderUsername: widget.myUsername,
      receiverUsername: widget.groupId,
      text: text,
      messageType: MessageType.text,
      isMe: true,
      timestamp: timestamp,
      replyToId: reply?.id,
      replyToSender: reply == null
          ? null
          : (reply.isMe ? widget.myUsername : reply.senderUsername),
      replyToText: reply == null ? null : _replyPreviewText(reply),
      replyToType: reply?.messageType.value,
    );

    setState(() {
      _messages.add(msg);
      _replyTo = null;
    });
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
        'reply_to_id': msg.replyToId,
        'reply_to_sender': msg.replyToSender,
        'reply_to_text': msg.replyToText,
        'reply_to_type': msg.replyToType,
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
        'reply_to_id': msg.replyToId,
        'reply_to_sender': msg.replyToSender,
        'reply_to_text': msg.replyToText,
        'reply_to_type': msg.replyToType,
      });

      // Fan out an FCM push to the other members. The server-side function
      // skips any member whose "Group Messages" toggle is off. Fire-and-forget.
      _sendGroupPushFallback(
        messageId: msg.id,
        text: msg.text ?? '',
        messageType: msg.messageType.value,
      );
    } catch (e) {
      debugPrint('Error sending group message to Supabase: $e');
      if (mounted) _showError('Failed to send message: $e');
    }
  }

  /// Fire-and-forget: asks the `send-group-push` Edge Function to deliver an
  /// FCM push to every OTHER group member. The function verifies the caller and
  /// skips members whose `groups_enabled` toggle is off. Never blocks sending.
  void _sendGroupPushFallback({
    required String messageId,
    required String text,
    required String messageType,
  }) {
    Future(() async {
      try {
        await Supabase.instance.client.functions.invoke(
          'send-group-push',
          body: {
            'group_id': widget.groupId,
            'group_name': widget.groupName,
            'sender_username': widget.myUsername.toLowerCase(),
            'message_id': messageId,
            'text': text,
            'message_type': messageType,
          },
        );
      } catch (e) {
        debugPrint('[group-push] non-fatal: $e');
      }
    });
  }

  /// #2/#3: short human-readable preview of a message for the reply chip.
  String _replyPreviewText(Message m) {
    switch (m.messageType) {
      case MessageType.image:
        return '📷 Photo';
      case MessageType.video:
        return '🎥 Video';
      case MessageType.document:
        return '📄 ${m.fileName ?? 'Document'}';
      default:
        return m.text ?? '';
    }
  }

  void _startReply(Message m) {
    if (m.messageType == MessageType.system) return;
    setState(() {
      _replyTo = m;
      _selectedIds.clear();
    });
    _focusNode.requestFocus();
  }

  // ──────────────────────────── #1 Selection ────────────────────────────

  void _toggleSelect(Message m) {
    setState(() {
      if (_selectedIds.contains(m.id)) {
        _selectedIds.remove(m.id);
      } else {
        _selectedIds.add(m.id);
      }
    });
  }

  void _clearSelection() => setState(() => _selectedIds.clear());

  List<Message> get _selectedMessages =>
      _messages.where((m) => _selectedIds.contains(m.id)).toList();

  void _copySelected() {
    final text = _selectedMessages
        .map((m) => m.text ?? '')
        .where((t) => t.isNotEmpty)
        .join('\n');
    if (text.isNotEmpty) {
      Clipboard.setData(ClipboardData(text: text));
    }
    _clearSelection();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Copied', style: GoogleFonts.inter()),
      behavior: SnackBarBehavior.floating,
    ));
  }

  void _showDeleteSelectedSheet() {
    final cs = _cs;
    final selected = _selectedMessages;
    if (selected.isEmpty) return;
    final allMine = selected.every((m) => m.isMe);
    showModalBottomSheet(
      context: context,
      backgroundColor: cs.surfaceContainerLow,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                    color: cs.outlineVariant,
                    borderRadius: BorderRadius.circular(2))),
            const SizedBox(height: 8),
            if (allMine)
              ListTile(
                leading: Icon(Icons.delete_forever_outlined, color: cs.error),
                title: Text('Delete for everyone',
                    style: GoogleFonts.inter(
                        color: cs.error, fontWeight: FontWeight.w600)),
                onTap: () async {
                  Navigator.pop(context);
                  final ids = selected.map((m) => m.id).toSet();
                  for (final id in ids) {
                    await SupabaseBroadcastService()
                        .deleteGroupMessageForEveryone(id, widget.groupId);
                  }
                  if (mounted) {
                    setState(() {
                      _messages.removeWhere((m) => ids.contains(m.id));
                      _selectedIds.clear();
                    });
                  }
                },
              ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: cs.onSurface),
              title: Text('Delete for me',
                  style: GoogleFonts.inter(color: cs.onSurface)),
              onTap: () async {
                Navigator.pop(context);
                final ids = selected.map((m) => m.id).toSet();
                for (final id in ids) {
                  await LocalDbService().deleteGroupMessageById(id);
                }
                if (mounted) {
                  setState(() {
                    _messages.removeWhere((m) => ids.contains(m.id));
                    _selectedIds.clear();
                  });
                }
              },
            ),
            ListTile(
              leading: Icon(Icons.close, color: cs.onSurfaceVariant),
              title: Text('Cancel',
                  style: GoogleFonts.inter(color: cs.onSurfaceVariant)),
              onTap: () => Navigator.pop(context),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// The small quoted-reply chip shown INSIDE a group bubble.
  Widget _buildReplyChip(Message message, bool isMe) {
    if (message.replyToId == null) return const SizedBox.shrink();
    final cs = _cs;
    final onBubble = isMe ? cs.onPrimary : cs.onSurface;
    final accent = isMe ? cs.onPrimary : cs.primary;
    final who = (message.replyToSender != null &&
            message.replyToSender!.toLowerCase() ==
                widget.myUsername.toLowerCase())
        ? 'You'
        : _getSenderDisplayName(message.replyToSender ?? '');
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: (isMe ? cs.onPrimary : cs.primary).withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border(left: BorderSide(color: accent, width: 3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(who,
              style: GoogleFonts.inter(
                  fontSize: 12, fontWeight: FontWeight.w700, color: accent)),
          const SizedBox(height: 2),
          Text(message.replyToText ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.inter(
                  fontSize: 13, color: onBubble.withValues(alpha: 0.85))),
        ],
      ),
    );
  }

  Widget _buildReplyPreviewBar() {
    final cs = _cs;
    final r = _replyTo!;
    final who = r.isMe ? 'You' : _getSenderDisplayName(r.senderUsername);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        border: Border(
          top: BorderSide(color: cs.outlineVariant),
          left: BorderSide(color: cs.primary, width: 4),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Replying to $who',
                    style: GoogleFonts.inter(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: cs.primary)),
                const SizedBox(height: 2),
                Text(_replyPreviewText(r),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.inter(
                        fontSize: 13, color: cs.onSurfaceVariant)),
              ],
            ),
          ),
          IconButton(
            icon: Icon(Icons.close, size: 20, color: cs.onSurfaceVariant),
            onPressed: () => setState(() => _replyTo = null),
          ),
        ],
      ),
    );
  }

  PreferredSizeWidget _buildSelectionAppBar() {
    final cs = _cs;
    final selected = _selectedMessages;
    final anyText = selected.any((m) => m.text != null && m.text!.isNotEmpty);
    return AppBar(
      backgroundColor: cs.surfaceContainerLowest,
      leading: IconButton(
        icon: Icon(Icons.close, color: cs.onSurface),
        onPressed: _clearSelection,
      ),
      title: Text('${_selectedIds.length}',
          style: GoogleFonts.inter(
              fontWeight: FontWeight.w700, color: cs.onSurface)),
      actions: [
        if (selected.length == 1)
          IconButton(
            tooltip: 'Reply',
            icon: Icon(Icons.reply_rounded, color: cs.onSurface),
            onPressed: () => _startReply(selected.first),
          ),
        if (anyText)
          IconButton(
            tooltip: 'Copy',
            icon: Icon(Icons.copy_rounded, color: cs.onSurface),
            onPressed: _copySelected,
          ),
        IconButton(
          tooltip: 'Delete',
          icon: Icon(Icons.delete_outline, color: cs.onSurface),
          onPressed: _showDeleteSelectedSheet,
        ),
        const SizedBox(width: 4),
      ],
    );
  }

  // ──────────────────────────── Media Sending (#5) ────────────────────────────

  /// Persists a media/group message both locally and to Supabase, then
  /// updates the UI. Shared by the image / video / document senders.
  Future<void> _persistGroupMediaMessage(Message msg) async {
    if (mounted) {
      setState(() => _messages.add(msg));
      _scrollToBottom();
    }
    try {
      await LocalDbService().insertGroupMessage({
        'id': msg.id,
        'group_id': widget.groupId,
        'sender_username': msg.senderUsername,
        'text': msg.text,
        'media_url': msg.mediaUrl,
        'file_name': msg.fileName,
        'message_type': msg.messageType.value,
        'timestamp': msg.timestamp,
      });
    } catch (e) {
      debugPrint('Error saving group media message locally: $e');
    }
    try {
      await Supabase.instance.client.from('group_messages').insert({
        'id': msg.id,
        'group_id': widget.groupId,
        'sender_username': msg.senderUsername.toLowerCase(),
        'text': msg.text,
        'media_url': msg.mediaUrl,
        'file_name': msg.fileName,
        'message_type': msg.messageType.value,
        'timestamp': msg.timestamp,
      });
    } catch (e) {
      debugPrint('Error sending group media message to Supabase: $e');
      if (mounted) _showError('Failed to send: $e');
    }
  }

  Future<void> _sendGroupImage(ImageSource source) async {
    Navigator.pop(context);
    try {
      List<XFile> pickedFiles = [];
      if (source == ImageSource.gallery) {
        pickedFiles = await ImagePicker().pickMultiImage();
      } else {
        final picked = await ImagePicker().pickImage(source: source);
        if (picked != null) pickedFiles.add(picked);
      }
      if (pickedFiles.isEmpty) return;

      setState(() { _isSendingMedia = true; _uploadProgress = 0; });
      for (final picked in pickedFiles) {
        try {
          final url = await MediaUploadService().uploadChatImage(File(picked.path));
          final timestamp = DateTime.now().millisecondsSinceEpoch;
          await _persistGroupMediaMessage(Message(
            id: '${widget.myUsername}_$timestamp',
            senderUsername: widget.myUsername,
            receiverUsername: widget.groupId,
            mediaUrl: url,
            localPath: picked.path,
            messageType: MessageType.image,
            isMe: true,
            timestamp: timestamp,
          ));
        } catch (e) {
          if (mounted) _showError('Failed to upload image: $e');
        }
      }
      if (mounted) setState(() => _isSendingMedia = false);
    } catch (e) {
      if (mounted) setState(() => _isSendingMedia = false);
      if (mounted) _showError('Image selection failed: $e');
    }
  }

  Future<void> _sendGroupVideo() async {
    Navigator.pop(context);
    try {
      final picked = await ImagePicker().pickVideo(source: ImageSource.gallery);
      if (picked == null) return;
      setState(() { _isSendingMedia = true; _uploadProgress = 0; });
      final url = await MediaUploadService().uploadChatVideo(
        File(picked.path),
        onProgress: (p) { if (mounted) setState(() => _uploadProgress = p); },
      );
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      await _persistGroupMediaMessage(Message(
        id: '${widget.myUsername}_$timestamp',
        senderUsername: widget.myUsername,
        receiverUsername: widget.groupId,
        mediaUrl: url,
        localPath: picked.path,
        messageType: MessageType.video,
        isMe: true,
        timestamp: timestamp,
      ));
      if (mounted) setState(() => _isSendingMedia = false);
    } catch (e) {
      if (mounted) setState(() => _isSendingMedia = false);
      if (mounted) _showError('Video upload failed: $e');
    }
  }

  Future<void> _sendGroupDocument() async {
    Navigator.pop(context);
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        allowMultiple: true,
      );
      if (result == null || result.files.isEmpty) return;
      setState(() { _isSendingMedia = true; _uploadProgress = 0; });
      for (final f in result.files) {
        if (f.path == null) continue;
        try {
          final url = await MediaUploadService().uploadDocument(File(f.path!), f.name);
          final timestamp = DateTime.now().millisecondsSinceEpoch;
          await _persistGroupMediaMessage(Message(
            id: '${widget.myUsername}_$timestamp',
            senderUsername: widget.myUsername,
            receiverUsername: widget.groupId,
            fileName: f.name,
            mediaUrl: url,
            messageType: MessageType.document,
            isMe: true,
            timestamp: timestamp,
          ));
        } catch (e) {
          if (mounted) _showError('Failed to upload ${f.name}: $e');
        }
      }
      if (mounted) setState(() => _isSendingMedia = false);
    } catch (e) {
      if (mounted) setState(() => _isSendingMedia = false);
      if (mounted) _showError('Document selection failed: $e');
    }
  }

  void _showAttachmentSheet() {
    final cs = _cs;
    showModalBottomSheet(
      context: context,
      backgroundColor: cs.surfaceContainerLow,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(width: 36, height: 4,
                  decoration: BoxDecoration(
                      color: cs.outlineVariant,
                      borderRadius: BorderRadius.circular(2))),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _attachOption(Icons.photo_library_outlined, 'Gallery', () => _sendGroupImage(ImageSource.gallery), cs),
                  _attachOption(Icons.camera_alt_outlined, 'Camera', () => _sendGroupImage(ImageSource.camera), cs),
                  _attachOption(Icons.videocam_outlined, 'Video', _sendGroupVideo, cs),
                  _attachOption(Icons.insert_drive_file_outlined, 'Document', _sendGroupDocument, cs),
                ],
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  Widget _attachOption(IconData icon, String label, VoidCallback onTap, ColorScheme cs) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 56, height: 56,
            decoration: BoxDecoration(
              color: cs.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(icon, color: cs.onSurface, size: 26),
          ),
          const SizedBox(height: 8),
          Text(label, style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w500, color: cs.onSurfaceVariant)),
        ],
      ),
    );
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
      content: Text(msg, style: GoogleFonts.inter()),
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
        title: Text('Clear Chat', style: GoogleFonts.inter(fontWeight: FontWeight.w700, color: cs.onSurface)),
        content: Text('Are you sure you want to delete all group messages locally? This cannot be undone.', style: GoogleFonts.inter(color: cs.onSurfaceVariant)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text('Cancel', style: GoogleFonts.inter(color: cs.outline))),
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
            child: Text('Clear', style: GoogleFonts.inter(color: cs.onError)),
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
      appBar: _selectionMode ? _buildSelectionAppBar() : _buildAppBar(),
      body: SafeArea(
        child: Column(
          children: [
            if (_isSendingMedia)
              LinearProgressIndicator(
                value: _uploadProgress > 0 ? _uploadProgress : null,
                backgroundColor: _cs.surfaceContainerHighest,
                color: _cs.primary,
                minHeight: 4,
              ),
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
            if (_replyTo != null) _buildReplyPreviewBar(),
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
                    style: GoogleFonts.inter(fontSize: 18, fontWeight: FontWeight.w700, color: cs.onSurface),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    _memberCount > 0 ? '$_memberCount members' : 'Group',
                    style: GoogleFonts.inter(fontSize: 13, color: cs.onSurfaceVariant, fontWeight: FontWeight.w400),
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
            PopupMenuItem(value: 'info', child: Text('Group Info', style: GoogleFonts.inter())),
            PopupMenuItem(value: 'clear', child: Text('Clear Chat', style: GoogleFonts.inter())),
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
        child: Text(label, style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w600, color: cs.onSurfaceVariant)),
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
            style: GoogleFonts.inter(
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

    final selected = _selectedIds.contains(message.id);

    Widget bubble = Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onLongPress: () => _toggleSelect(message),
        onTap: _selectionMode ? () => _toggleSelect(message) : null,
        child: Container(
          margin: EdgeInsets.only(bottom: 8, top: showSenderName ? 4 : 0),
          constraints:
              BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
          child: AbsorbPointer(
            absorbing: _selectionMode,
            child: _buildBubbleForType(message, isMe, timeString, showSenderName),
          ),
        ),
      ),
    );

    Widget row = Container(
      color: selected ? _cs.primary.withValues(alpha: 0.12) : Colors.transparent,
      child: bubble,
    );

    if (!_selectionMode) {
      row = Dismissible(
        key: ValueKey('greply_${message.id}'),
        direction: DismissDirection.startToEnd,
        dismissThresholds: const {DismissDirection.startToEnd: 0.25},
        confirmDismiss: (_) async {
          _startReply(message);
          return false;
        },
        background: Padding(
          padding: const EdgeInsets.only(left: 24),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Icon(Icons.reply_rounded, color: _cs.primary),
          ),
        ),
        child: row,
      );
    }
    return row;
  }

  /// Chooses the correct bubble widget based on the message content type.
  Widget _buildBubbleForType(Message message, bool isMe, String timeString, bool showSenderName) {
    switch (message.messageType) {
      case MessageType.image:
        return _buildGroupImageBubble(message, isMe, timeString, showSenderName);
      case MessageType.video:
        return _buildGroupVideoBubble(message, isMe, timeString, showSenderName);
      case MessageType.document:
        return _buildGroupDocumentBubble(message, isMe, timeString, showSenderName);
      case MessageType.text:
      default:
        return _buildTextBubble(message, isMe, timeString, showSenderName);
    }
  }

  /// A small sender-name label shown above non-self media bubbles in groups.
  Widget _senderLabel(Message message, bool isMe, bool showSenderName) {
    if (isMe || !showSenderName) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 2),
      child: Text(
        _getSenderDisplayName(message.senderUsername),
        style: GoogleFonts.inter(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: _getSenderColor(message.senderUsername),
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  Widget _buildGroupImageBubble(Message message, bool isMe, String timeString, bool showSenderName) {
    final cs = _cs;
    final localPath = message.localPath;
    final networkUrl = message.mediaUrl;
    final heroTag = 'gmedia_${message.id}';

    Widget imageWidget;
    if (localPath != null && File(localPath).existsSync()) {
      imageWidget = Image.file(File(localPath),
          width: 220, height: 220, fit: BoxFit.cover, cacheWidth: 440, cacheHeight: 440,
          errorBuilder: (_, __, ___) => Container(width: 220, height: 220, color: cs.surfaceContainerHigh,
              child: Icon(Icons.broken_image_outlined, color: cs.onSurfaceVariant)));
    } else if (networkUrl != null && networkUrl.startsWith('http')) {
      imageWidget = CachedNetworkImage(
        imageUrl: networkUrl,
        width: 220, height: 220, fit: BoxFit.cover, memCacheWidth: 440, memCacheHeight: 440,
        placeholder: (_, __) => Container(width: 220, height: 220, color: cs.surfaceContainerHigh,
            child: Center(child: CircularProgressIndicator(strokeWidth: 2, color: cs.primary))),
        errorWidget: (_, __, ___) => Container(width: 220, height: 100, color: cs.surfaceContainerHigh,
            child: Icon(Icons.broken_image_outlined, color: cs.onSurfaceVariant)),
      );
    } else {
      imageWidget = Container(width: 220, height: 220, color: cs.surfaceContainerHigh,
          child: const Center(child: CircularProgressIndicator(strokeWidth: 2)));
    }

    return Column(
      crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        _senderLabel(message, isMe, showSenderName),
        _buildReplyChip(message, isMe),
        ClipRRect(
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(18), topRight: const Radius.circular(18),
            bottomLeft: Radius.circular(isMe ? 18 : 4), bottomRight: Radius.circular(isMe ? 4 : 18),
          ),
          child: GestureDetector(
            onTap: () => Navigator.push(context, MaterialPageRoute(
              builder: (_) => MediaViewerScreen(heroTag: heroTag, localPath: localPath, networkUrl: networkUrl))),
            child: Stack(children: [
              Hero(tag: heroTag, child: imageWidget),
              Positioned(bottom: 8, right: 10, child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.5), borderRadius: BorderRadius.circular(12)),
                child: Text(timeString, style: GoogleFonts.inter(color: Colors.white, fontSize: 11)),
              )),
            ]),
          ),
        ),
      ],
    );
  }

  Widget _buildGroupVideoBubble(Message message, bool isMe, String timeString, bool showSenderName) {
    final cs = _cs;
    return Column(
      crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        _senderLabel(message, isMe, showSenderName),
        _buildReplyChip(message, isMe),
        GestureDetector(
          onTap: () => Navigator.push(context, MaterialPageRoute(
            builder: (_) => MediaViewerScreen(
              heroTag: 'gmedia_${message.id}', localPath: message.localPath,
              networkUrl: message.mediaUrl, isVideo: true))),
          child: Container(
            width: 220,
            decoration: BoxDecoration(
              color: isMe ? cs.primary : cs.surface,
              border: isMe ? null : Border.all(color: cs.outlineVariant, width: 1),
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(18), topRight: const Radius.circular(18),
                bottomLeft: Radius.circular(isMe ? 18 : 4), bottomRight: Radius.circular(isMe ? 4 : 18),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Hero(
                    tag: 'gmedia_${message.id}',
                    child: Container(
                      height: 100,
                      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(16)),
                      child: const Center(child: Icon(Icons.play_circle_filled_rounded, size: 48, color: Colors.white)),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.videocam_outlined, size: 16, color: isMe ? cs.onPrimary : cs.onSurfaceVariant),
                    const SizedBox(width: 6),
                    Text('Video', style: GoogleFonts.inter(fontSize: 14, color: isMe ? cs.onPrimary : cs.onSurface, fontWeight: FontWeight.w500)),
                    const Spacer(),
                    _buildTimestamp(timeString, isMe, cs),
                  ]),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildGroupDocumentBubble(Message message, bool isMe, String timeString, bool showSenderName) {
    final cs = _cs;
    return Column(
      crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        _senderLabel(message, isMe, showSenderName),
        _buildReplyChip(message, isMe),
        Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
          decoration: BoxDecoration(
            color: isMe ? cs.primary : cs.surface,
            border: isMe ? null : Border.all(color: cs.outlineVariant, width: 1),
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(18), topRight: const Radius.circular(18),
              bottomLeft: Radius.circular(isMe ? 18 : 4), bottomRight: Radius.circular(isMe ? 4 : 18),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Row(mainAxisSize: MainAxisSize.min, children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: (isMe ? cs.onPrimary : cs.primary).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(Icons.insert_drive_file_outlined, color: isMe ? cs.onPrimary : cs.primary, size: 24),
                ),
                const SizedBox(width: 12),
                Flexible(
                  child: Text(message.fileName ?? 'Document', maxLines: 2, overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w600, color: isMe ? cs.onPrimary : cs.onSurface)),
                ),
              ]),
              const SizedBox(height: 8),
              _buildTimestamp(timeString, isMe, cs),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildTextBubble(Message message, bool isMe, String timeString, bool showSenderName) {
    final cs = _cs;
    final senderColor = _getSenderColor(message.senderUsername);
    final senderName = _getSenderDisplayName(message.senderUsername);

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
      decoration: BoxDecoration(
        color: isMe ? cs.primary : cs.surface,
        border: isMe ? null : Border.all(color: cs.outlineVariant, width: 1),
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(18), topRight: const Radius.circular(18),
          bottomLeft: Radius.circular(isMe ? 18 : 4), bottomRight: Radius.circular(isMe ? 4 : 18),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Sender name label for non-self messages
          if (showSenderName && !isMe) ...[
            Text(
              senderName,
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: senderColor,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 4),
          ],
          _buildReplyChip(message, isMe),
          LinkifiedText(
            text: message.text ?? '',
            style: GoogleFonts.inter(
                color: isMe ? cs.onPrimary : cs.onSurface, fontSize: 16, height: 1.4),
            linkColor: isMe ? cs.onPrimary : cs.primary,
          ),
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
        Text(timeString, style: GoogleFonts.inter(
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
                  borderRadius: BorderRadius.circular(24),
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
                        style: GoogleFonts.inter(fontSize: 16, color: cs.onSurface),
                        onTap: () { if (_showEmojiPicker) setState(() => _showEmojiPicker = false); },
                        decoration: InputDecoration(
                          hintText: 'Type a message...',
                          hintStyle: GoogleFonts.inter(color: cs.onSurfaceVariant, fontSize: 16),
                          border: InputBorder.none, enabledBorder: InputBorder.none, focusedBorder: InputBorder.none,
                          contentPadding: const EdgeInsets.symmetric(vertical: 14),
                          isDense: true,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: Icon(Icons.attach_file_rounded, color: cs.onSurfaceVariant, size: 24),
                      tooltip: 'Attach',
                      onPressed: _isSendingMedia ? null : _showAttachmentSheet,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
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
                icon: Icon(_hasText ? Icons.send_rounded : Icons.mic_none_rounded, color: cs.onPrimary, size: 22),
                onPressed: _hasText ? _sendMessage : () {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Voice messages coming soon')));
                },
                padding: EdgeInsets.zero,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
