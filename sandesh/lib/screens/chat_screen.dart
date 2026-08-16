import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart' hide Config;
import 'package:intl/intl.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/message_model.dart';
import '../services/local_db_service.dart';
import '../services/supabase_broadcast_service.dart';
import '../services/media_upload_service.dart';
// app_theme.dart intentionally not imported — all colors from Theme.of(context)
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'profile_screen.dart';
import 'media_viewer_screen.dart';
import 'camera_screen.dart';
import 'media_preview_screen.dart';
import 'call_screen.dart';
import '../services/call_service.dart';
import 'package:permission_handler/permission_handler.dart';
import '../widgets/user_avatar.dart';
import '../widgets/linkified_text.dart';
import 'package:cached_network_image/cached_network_image.dart';

class ChatScreen extends StatefulWidget {
  final String myUsername;
  final String receiverUsername;
  final String? receiverDisplayName;

  const ChatScreen({
    super.key,
    required this.myUsername,
    required this.receiverUsername,
    this.receiverDisplayName,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _textController = TextEditingController();
  final _scrollController = ScrollController();
  final _focusNode = FocusNode();
  List<Message> _messages = [];
  StreamSubscription<Message>? _messageSubscription;
  bool _showEmojiPicker = false;
  bool _isSendingMedia = false;
  bool _hasText = false;
  double _uploadProgress = 0;
  String _receiverAvatarUrl = '';

  StreamSubscription<List<Map<String, dynamic>>>? _presenceSubscription;
  bool _isPeerOnline = false;
  DateTime? _peerLastSeen;

  /// WhatsApp-style display name — resolved from widget param or local contacts DB.
  String? _displayName;

  /// Block status for this peer user.
  bool _isBlocked = false;

  bool _isLoadingMore = false;
  bool _hasMore = true;

  /// Cached ColorScheme — set at the top of build() so all helper methods can use it.
  late ColorScheme _cs;

  /// #1 Selection mode — ids of messages currently multi-selected.
  final Set<String> _selectedIds = {};
  bool get _selectionMode => _selectedIds.isNotEmpty;

  /// #2 The message currently being replied to (null when not replying).
  Message? _replyTo;

  /// #4 Listens for delivery/read receipts of our sent messages.
  StreamSubscription<MessageStatusUpdate>? _statusSub;

  /// #1 Listens for delete-for-everyone signals from the peer.
  StreamSubscription<String>? _deletionSub;

  @override
  void initState() {
    super.initState();
    _loadMessages();
    _loadReceiverAvatar();
    _loadDisplayName();
    _checkBlockStatus();
    SupabaseBroadcastService().activeChatUser = widget.receiverUsername;
    SupabaseBroadcastService().subscribeToRoom(widget.receiverUsername);
    _messageSubscription = SupabaseBroadcastService()
        .messageStream
        .listen(_handleNewMessage);
    // #4: repaint ticks when a receipt for one of our messages arrives.
    _statusSub = SupabaseBroadcastService().statusStream.listen((u) {
      if (!mounted) return;
      final i = _messages.indexWhere((m) => m.id == u.messageId);
      if (i != -1) {
        setState(() => _messages[i] = _messages[i].copyWith(status: u.status));
      }
    });
    // #1: remove a message live when the peer deletes it for everyone.
    _deletionSub = SupabaseBroadcastService().deletionStream.listen((id) {
      if (!mounted) return;
      setState(() {
        _messages.removeWhere((m) => m.id == id);
        _selectedIds.remove(id);
      });
    });
    _scrollController.addListener(_onScroll);
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
    _listenToPeerPresence();
  }

  void _onScroll() {
    if (_scrollController.position.pixels < 200 && !_isLoadingMore && _hasMore) {
      _loadMoreMessages();
    }
  }

  /// Resolves the display name: uses widget param if provided, otherwise
  /// looks up the saved contact name from the local DB (WhatsApp-style).
  Future<void> _loadDisplayName() async {
    if (widget.receiverDisplayName != null && widget.receiverDisplayName!.isNotEmpty) {
      if (mounted) setState(() => _displayName = widget.receiverDisplayName);
      return;
    }
    final name = await LocalDbService().getContactDisplayName(widget.receiverUsername);
    if (name != null && mounted) {
      setState(() => _displayName = name);
    }
  }

  Future<void> _loadReceiverAvatar() async {
    try {
      final response = await Supabase.instance.client
          .from('profiles')
          .select('avatar_url')
          .ilike('username', widget.receiverUsername)
          .maybeSingle();
      final url = (response?['avatar_url'] as String?) ?? '';
      if (url.isNotEmpty && mounted) {
        setState(() => _receiverAvatarUrl = url);
      }
    } catch (_) {
      final contacts = await LocalDbService().getContacts();
      try {
        final c = contacts.firstWhere((c) => c.username == widget.receiverUsername);
        if (c.avatarUrl.isNotEmpty && mounted) {
          setState(() => _receiverAvatarUrl = c.avatarUrl);
        }
      } catch (_) {}
    }
  }

  void _listenToPeerPresence() async {
    final client = Supabase.instance.client;
    
    // First, find the exact casing of the username from the DB.
    // Supabase .stream().eq() is case-sensitive, so if they are saved as "Sandesh",
    // "sandesh" will not match.
    String exactUsername = widget.receiverUsername;
    try {
      final res = await client
          .from('profiles')
          .select('username')
          .ilike('username', widget.receiverUsername)
          .maybeSingle();
      if (res != null && res['username'] != null) {
        exactUsername = res['username'] as String;
      }
    } catch (_) {}

    if (!mounted) return;

    _presenceSubscription = client
        .from('profiles')
        .stream(primaryKey: ['id'])
        .eq('username', exactUsername)
        .listen((data) {
      if (data.isNotEmpty && mounted) {
        final profile = data.first;
        final isOnline = profile['is_online'] == true;
        final raw = profile['last_seen'] as String?;
        final lastSeen = raw != null ? DateTime.tryParse(raw) : null;

        // Client-side staleness check: if is_online=true but last_seen
        // is >60 seconds old, the user's app likely crashed or lost
        // connectivity without properly going offline.
        bool effectiveOnline = isOnline;
        if (isOnline && lastSeen != null) {
          final staleness = DateTime.now().toUtc().difference(lastSeen);
          if (staleness.inSeconds > 60) {
            effectiveOnline = false;
          }
        }

        setState(() {
          _isPeerOnline = effectiveOnline;
          _peerLastSeen = lastSeen;
        });
      }
    }, onError: (e) {
      debugPrint('Presence stream error: $e');
    });
  }

  /// Check if this peer is blocked.
  Future<void> _checkBlockStatus() async {
    final blocked = await LocalDbService().isBlocked(widget.receiverUsername);
    if (mounted) setState(() => _isBlocked = blocked);
  }

  @override
  void dispose() {
    _presenceSubscription?.cancel();
    SupabaseBroadcastService().activeChatUser = null;
    _messageSubscription?.cancel();
    _statusSub?.cancel();
    _deletionSub?.cancel();
    _textController.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _handleNewMessage(Message message) {
    if (message.senderUsername.toLowerCase() != widget.receiverUsername.toLowerCase()) return;
    if (!mounted) return;
    setState(() {
      if (!_messages.any((m) => m.id == message.id)) {
        _messages.add(message);
      }
    });
    // #4: chat is open, so tell the sender we've read it right away.
    SupabaseBroadcastService()
        .sendReadReceipt(message.id, widget.receiverUsername);
    _scrollToBottom();
  }

  /// #4: mark every message received from the peer as read, so their ticks
  /// turn blue. Called whenever this chat is opened / messages (re)load.
  void _markPeerMessagesRead() {
    for (final m in _messages) {
      if (!m.isMe) {
        SupabaseBroadcastService()
            .sendReadReceipt(m.id, widget.receiverUsername);
      }
    }
  }

  Future<void> _loadMessages() async {
    final messages = await LocalDbService().getMessages(widget.myUsername, widget.receiverUsername, limit: 50);
    if (mounted) {
      setState(() {
        _messages = messages.reversed.toList();
        _hasMore = messages.length == 50;
      });
      _markPeerMessagesRead();
      _scrollToBottom();
    }
  }

  Future<void> _loadMoreMessages() async {
    if (_messages.isEmpty) return;
    setState(() => _isLoadingMore = true);
    final oldestTimestamp = _messages.first.timestamp;
    final olderMessages = await LocalDbService().getMessages(
      widget.myUsername, 
      widget.receiverUsername, 
      limit: 50, 
      beforeTimestamp: oldestTimestamp
    );
    if (mounted) {
      setState(() {
        _messages.insertAll(0, olderMessages.reversed.toList());
        _hasMore = olderMessages.length == 50;
        _isLoadingMore = false;
      });
    }
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
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

  Future<void> _sendMessage() async {
    final text = _textController.text.trim();
    if (text.isEmpty) return;
    _textController.clear();
    final reply = _replyTo;
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final msg = Message(
      id: '${widget.myUsername}_$timestamp',
      senderUsername: widget.myUsername,
      receiverUsername: widget.receiverUsername,
      text: text,
      messageType: MessageType.text,
      isMe: true,
      timestamp: timestamp,
      status: 'sent',
      replyToId: reply?.id,
      replyToSender: reply == null
          ? null
          : (reply.isMe ? widget.myUsername : widget.receiverUsername),
      replyToText: reply == null ? null : _replyPreviewText(reply),
      replyToType: reply?.messageType.value,
    );
    setState(() {
      _messages.add(msg);
      _replyTo = null;
    });
    _scrollToBottom();
    await SupabaseBroadcastService().sendMessage(msg);
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

  /// #2: begin replying to [m] — shows the reply preview bar above the input.
  void _startReply(Message m) {
    if (m.messageType == MessageType.call) return; // can't reply to a call
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
        .where((m) => m.messageType == MessageType.text || m.text != null)
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
                  for (final m in selected) {
                    await SupabaseBroadcastService()
                        .deleteMessageForEveryone(m);
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
                  await LocalDbService().deleteMessageById(id);
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

  Future<void> _sendImage(ImageSource source) async {
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

      if (!mounted) return;
      // Full-screen preview + optional caption (video-sharing-ui-3.html).
      final caption = await _showMediaPreview(File(pickedFiles.first.path), isVideo: false);
      if (caption == null) return; // user cancelled

      setState(() { _isSendingMedia = true; _uploadProgress = 0; });
      
      for (int i = 0; i < pickedFiles.length; i++) {
        final picked = pickedFiles[i];
        try {
          final url = await MediaUploadService().uploadChatImage(File(picked.path));
          final timestamp = DateTime.now().millisecondsSinceEpoch + i;
          final msg = Message(
            id: '${widget.myUsername}_$timestamp',
            senderUsername: widget.myUsername,
            receiverUsername: widget.receiverUsername,
            // Caption applies to the first image only (WhatsApp-style).
            text: (i == 0 && caption.isNotEmpty) ? caption : null,
            mediaUrl: url,
            localPath: picked.path,
            messageType: MessageType.image,
            isMe: true,
            timestamp: timestamp,
          );
          if (mounted) {
            setState(() { _messages.add(msg); });
            _scrollToBottom();
          }
          await SupabaseBroadcastService().sendMessage(msg);
        } catch (e) {
          if (mounted) _showError('Failed to upload image ${i+1}: $e');
        }
      }
      if (mounted) setState(() => _isSendingMedia = false);
    } catch (e) {
      if (mounted) setState(() => _isSendingMedia = false);
      if (mounted) _showError('Image selection failed: $e');
    }
  }

  Future<void> _sendVideo() async {
    Navigator.pop(context);
    try {
      final picked = await ImagePicker().pickVideo(source: ImageSource.gallery);
      if (picked == null) return;

      if (!mounted) return;
      // Full-screen video preview (autoplay/loop/muted) + optional caption.
      final caption = await _showMediaPreview(File(picked.path), isVideo: true);
      if (caption == null) return; // user cancelled

      setState(() { _isSendingMedia = true; _uploadProgress = 0; });
      final url = await MediaUploadService().uploadChatVideo(
        File(picked.path),
        onProgress: (p) => setState(() => _uploadProgress = p),
      );
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final msg = Message(
        id: '${widget.myUsername}_$timestamp',
        senderUsername: widget.myUsername,
        receiverUsername: widget.receiverUsername,
        text: caption.isNotEmpty ? caption : null,
        mediaUrl: url,
        localPath: picked.path,
        messageType: MessageType.video,
        isMe: true,
        timestamp: timestamp,
      );
      setState(() { _messages.add(msg); _isSendingMedia = false; });
      _scrollToBottom();
      await SupabaseBroadcastService().sendMessage(msg);
    } catch (e) {
      setState(() => _isSendingMedia = false);
      if (mounted) _showError('Video upload failed: $e');
    }
  }

  Future<void> _sendDocument() async {
    Navigator.pop(context);
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        allowMultiple: true,
      );
      if (result == null || result.files.isEmpty) return;
      
      setState(() { _isSendingMedia = true; _uploadProgress = 0; });
      
      for (int i = 0; i < result.files.length; i++) {
        final f = result.files[i];
        if (f.path == null) continue;
        try {
          final url = await MediaUploadService().uploadDocument(File(f.path!), f.name);
          final timestamp = DateTime.now().millisecondsSinceEpoch;
          final msg = Message(
            id: '${widget.myUsername}_$timestamp',
            senderUsername: widget.myUsername,
            receiverUsername: widget.receiverUsername,
            fileName: f.name,
            mediaUrl: url,
            messageType: MessageType.document,
            isMe: true,
            timestamp: timestamp,
          );
          if (mounted) {
            setState(() { _messages.add(msg); });
            _scrollToBottom();
          }
          await SupabaseBroadcastService().sendMessage(msg);
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

  /// Full-screen "review before send" for a photo or video, matching
  /// `Sandesh_UI/video-sharing-ui-3.html` (media + "Add a caption..." field +
  /// circular send). Returns the trimmed caption (possibly empty `''`) when the
  /// user taps Send, or `null` if they cancel / back out.
  Future<String?> _showMediaPreview(File file, {required bool isVideo}) {
    return Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        fullscreenDialog: true,
        builder: (_) => MediaPreviewScreen(
          file: file,
          isVideo: isVideo,
          sendToLabel: _displayName ?? widget.receiverUsername,
        ),
      ),
    );
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: GoogleFonts.inter()),
      backgroundColor: _cs.error,
      behavior: SnackBarBehavior.floating,
    ));
  }

  /// Starts an audio (isVideo=false) or video (isVideo=true) call with the
  /// current peer. Shared by the app-bar call buttons and the Contact Info
  /// (profile) overlay's Audio/Video actions so both behave identically.
  Future<void> _startCall(bool isVideo) async {
    final perms = isVideo
        ? [Permission.camera, Permission.microphone]
        : [Permission.microphone];
    final statuses = await perms.request();
    if (statuses.values.any((s) => s != PermissionStatus.granted)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(isVideo
              ? 'Camera and Microphone permissions are required to make a call.'
              : 'Microphone permission is required to make an audio call.'),
        ));
      }
      return;
    }

    final result = await CallService().initiateCall(
      receiverUsername: widget.receiverUsername,
      callType: isVideo ? 'video' : 'audio',
    );
    if (!mounted) return;
    if (result.error != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Call failed: ${result.error}'),
        duration: const Duration(seconds: 6),
      ));
      return;
    }

    final sorted = [
      CallService.sanitizeUsername(widget.myUsername),
      CallService.sanitizeUsername(widget.receiverUsername)
    ]..sort();
    final channelName = 'call_${sorted[0]}_${sorted[1]}';
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CallScreen(
          myUsername: widget.myUsername,
          peerUsername: widget.receiverUsername,
          channelName: channelName,
          token: result.token!.token,
          agoraUid: result.token!.uid,
          callType: isVideo ? 'video' : 'audio',
          isOutgoing: true,
        ),
      ),
    );
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
                  _attachOption(Icons.photo_library_outlined, 'Gallery', () => _sendImage(ImageSource.gallery), cs),
                  _attachOption(Icons.camera_alt_outlined, 'Camera', () => _sendImage(ImageSource.camera), cs),
                  _attachOption(Icons.videocam_outlined, 'Video', _sendVideo, cs),
                  _attachOption(Icons.insert_drive_file_outlined, 'Document', _sendDocument, cs),
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

  static String _formatLastSeen(DateTime? lastSeen) {
    if (lastSeen == null) return 'Offline';
    final now = DateTime.now();
    final local = lastSeen.toLocal();
    final diff = now.difference(local);

    if (diff.inMinutes < 1) return 'Last seen just now';
    if (diff.inMinutes < 60) return 'Last seen ${diff.inMinutes} mins ago';
    if (diff.inHours < 24 && now.day == local.day) {
      return 'Last seen today at ${DateFormat('h:mm a').format(local)}';
    }
    if (diff.inHours < 48 && now.day - local.day == 1) {
      return 'Last seen yesterday at ${DateFormat('h:mm a').format(local)}';
    }
    return 'Last seen on ${DateFormat('MMM d, yyyy').format(local)}';
  }

  void _showClearChatConfirm() {
    final cs = _cs;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: cs.surface,
        title: Text('Clear Chat', style: GoogleFonts.inter(fontWeight: FontWeight.w700, color: cs.onSurface)),
        content: Text('Are you sure you want to delete all messages? This cannot be undone locally.', style: GoogleFonts.inter(color: cs.onSurfaceVariant)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text('Cancel', style: GoogleFonts.inter(color: cs.outline))),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await LocalDbService().deleteChatHistory(widget.myUsername, widget.receiverUsername);
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

  void _showBlockUserConfirm() {
    final cs = _cs;
    final isCurrentlyBlocked = _isBlocked;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: cs.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: Text(
          isCurrentlyBlocked ? 'Unblock User' : 'Block User',
          style: GoogleFonts.inter(fontWeight: FontWeight.w700, color: cs.onSurface),
        ),
        content: Text(
          isCurrentlyBlocked
              ? 'Unblock ${_displayName ?? widget.receiverUsername}? You will start receiving messages from this user again.'
              : 'Block ${_displayName ?? widget.receiverUsername}? Blocked contacts will no longer be able to send you messages or call you.',
          style: GoogleFonts.inter(color: cs.onSurfaceVariant, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancel', style: GoogleFonts.inter(color: cs.outline)),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(ctx);
              if (isCurrentlyBlocked) {
                await LocalDbService().unblockUser(widget.receiverUsername);
                if (mounted) {
                  setState(() => _isBlocked = false);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('${_displayName ?? widget.receiverUsername} unblocked',
                          style: GoogleFonts.inter(fontWeight: FontWeight.w500)),
                      backgroundColor: Theme.of(context).colorScheme.primary,
                      behavior: SnackBarBehavior.floating,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  );
                }
              } else {
                await LocalDbService().blockUser(widget.receiverUsername);
                if (mounted) {
                  setState(() => _isBlocked = true);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('${_displayName ?? widget.receiverUsername} blocked',
                          style: GoogleFonts.inter(fontWeight: FontWeight.w500)),
                      backgroundColor: cs.error,
                      behavior: SnackBarBehavior.floating,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  );
                }
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: isCurrentlyBlocked ? Theme.of(context).colorScheme.primary : cs.error,
            ),
            child: Text(
              isCurrentlyBlocked ? 'Unblock' : 'Block',
              style: GoogleFonts.inter(color: cs.onError),
            ),
          ),
        ],
      ),
    );
  }

  // ──────────────────────────── #2/#3 Reply widgets ────────────────────────────

  /// The small quoted-reply chip shown INSIDE a bubble when it is a reply.
  Widget _buildReplyChip(Message message, bool isMe) {
    if (message.replyToId == null) return const SizedBox.shrink();
    final cs = _cs;
    final onBubble = isMe ? cs.onPrimary : cs.onSurface;
    final accent = isMe ? cs.onPrimary : cs.primary;
    final who = (message.replyToSender != null &&
            message.replyToSender!.toLowerCase() ==
                widget.myUsername.toLowerCase())
        ? 'You'
        : (_displayName ?? message.replyToSender ?? widget.receiverUsername);
    final type = message.replyToType;
    IconData? icon;
    if (type == 'image') {
      icon = Icons.photo_outlined;
    } else if (type == 'video') {
      icon = Icons.videocam_outlined;
    } else if (type == 'document') {
      icon = Icons.insert_drive_file_outlined;
    }
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
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: accent)),
          const SizedBox(height: 2),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 14, color: onBubble.withValues(alpha: 0.8)),
                const SizedBox(width: 4),
              ],
              Flexible(
                child: Text(
                  message.replyToText ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                      fontSize: 13, color: onBubble.withValues(alpha: 0.85)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// #4: renders the correct tick(s) for one of OUR messages based on status.
  Widget _statusTicks(String? status, {required bool onColored}) {
    // Read → blue double tick. Delivered → grey/onColor double tick.
    // Sent (or legacy null) → single tick.
    final base = onColored ? _cs.onPrimary.withValues(alpha: 0.8) : _cs.onSurfaceVariant;
    switch (status) {
      case 'read':
        return const Icon(Icons.done_all, size: 14, color: Color(0xFF34B7F1));
      case 'delivered':
        return Icon(Icons.done_all, size: 14, color: base);
      case 'sent':
        return Icon(Icons.done, size: 14, color: base);
      default:
        // Legacy messages with no tracked status — show delivered-style.
        return Icon(Icons.done_all, size: 14, color: base);
    }
  }

  /// #2: the reply preview bar shown above the input while composing a reply.
  Widget _buildReplyPreviewBar() {
    final cs = _cs;
    final r = _replyTo!;
    final who = r.isMe ? 'You' : (_displayName ?? widget.receiverUsername);
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

  /// #1: the contextual app bar shown while messages are selected.
  PreferredSizeWidget _buildSelectionAppBar() {
    final cs = _cs;
    final selected = _selectedMessages;
    final anyText =
        selected.any((m) => m.messageType == MessageType.text || m.text != null);
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

  @override
  Widget build(BuildContext context) {
    _cs = Theme.of(context).colorScheme;
    final items = _buildMessageListWithDates();
    return Scaffold(
      backgroundColor: _cs.surfaceContainerLow,
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
                  return KeyedSubtree(
                    key: ValueKey((item as Message).id),
                    child: _buildMessageBubble(item),
                  );
                },
              ),
            ),
            if (_isBlocked)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                decoration: BoxDecoration(
                  color: _cs.errorContainer.withValues(alpha: 0.3),
                  border: Border(top: BorderSide(color: _cs.error.withValues(alpha: 0.2))),
                ),
                child: Row(
                  children: [
                    Icon(Icons.block_rounded, color: _cs.error, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'You blocked this contact',
                        style: GoogleFonts.inter(color: _cs.error, fontWeight: FontWeight.w500, fontSize: 14),
                      ),
                    ),
                    TextButton(
                      onPressed: () async {
                        await LocalDbService().unblockUser(widget.receiverUsername);
                        if (mounted) setState(() => _isBlocked = false);
                      },
                      style: TextButton.styleFrom(
                        backgroundColor: _cs.error.withValues(alpha: 0.1),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                      ),
                      child: Text('Unblock', style: GoogleFonts.inter(color: _cs.error, fontWeight: FontWeight.w600, fontSize: 13)),
                    ),
                  ],
                ),
              )
            else ...[
              if (_replyTo != null) _buildReplyPreviewBar(),
              _buildInputBar(),
            ],
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
          showModalBottomSheet(
            context: context,
            isScrollControlled: true,
            useSafeArea: true,
            builder: (_) => ClipRRect(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
              child: ProfileScreen(
                peerUsername: widget.receiverUsername,
                onStartCall: (isVideo) => _startCall(isVideo),
              ),
            ),
          );
        },
        child: Row(
          children: [
            _buildReceiverAvatar(cs),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _displayName ?? widget.receiverUsername,
                    style: GoogleFonts.inter(fontSize: 18, fontWeight: FontWeight.w700, color: cs.onSurface),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  _LastSeenSubtitle(isOnline: _isPeerOnline, lastSeen: _peerLastSeen, cs: cs),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        IconButton(
          icon: Icon(Icons.call_outlined, color: cs.primary, size: 24),
          tooltip: 'Audio Call',
          onPressed: () => _startCall(false),
        ),
        IconButton(
          icon: Icon(Icons.videocam_outlined, color: cs.primary, size: 26),
          tooltip: 'Video Call',
          onPressed: () => _startCall(true),
        ),
        PopupMenuButton<String>(
          icon: Icon(Icons.more_vert_rounded, color: cs.onSurfaceVariant, size: 24),
          onSelected: (value) {
            if (value == 'clear') {
              _showClearChatConfirm();
            } else if (value == 'block') {
              _showBlockUserConfirm();
            }
          },
          itemBuilder: (context) => [
            PopupMenuItem(value: 'clear', child: Text('Clear Chat', style: GoogleFonts.inter())),
            PopupMenuItem(
              value: 'block',
              child: Text(
                _isBlocked ? 'Unblock User' : 'Block User',
                style: GoogleFonts.inter(color: _isBlocked ? Theme.of(context).colorScheme.primary : null),
              ),
            ),
          ],
        ),
        const SizedBox(width: 4),
      ],
    );
  }

  Widget _buildReceiverAvatar(ColorScheme cs) {
    return UserAvatar(
      imageUrl: _receiverAvatarUrl.startsWith('http') ? _receiverAvatarUrl : null,
      name: _displayName ?? widget.receiverUsername,
      radius: 20,
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



  Widget _buildMessageBubble(Message message) {
    final isMe = message.isMe;
    final timeString = DateFormat('h:mm a').format(DateTime.fromMillisecondsSinceEpoch(message.timestamp));

    Widget content;
    switch (message.messageType) {
      case MessageType.image:
        content = _buildImageContent(message, isMe, timeString);
        break;
      case MessageType.video:
        content = _buildVideoContent(message, isMe, timeString);
        break;
      case MessageType.document:
        content = _buildDocumentContent(message, isMe, timeString);
        break;
      case MessageType.call:
        content = _buildCallContent(message, isMe, timeString);
        break;
      case MessageType.text:
      default:
        content = _buildTextContent(message, isMe, timeString);
    }

    final selected = _selectedIds.contains(message.id);

    // #1 tap/long-press selection + highlight, #2 swipe-right-to-reply.
    Widget bubble = Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onLongPress: () => _toggleSelect(message),
        onTap: _selectionMode ? () => _toggleSelect(message) : null,
        child: Container(
          margin: const EdgeInsets.only(bottom: 8),
          constraints:
              BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
          // In selection mode we absorb inner taps (e.g. opening media) so the
          // whole row toggles selection instead.
          child: AbsorbPointer(absorbing: _selectionMode, child: content),
        ),
      ),
    );

    // Whole-width row so the highlight + swipe cover the full line.
    Widget row = Container(
      color: selected ? _cs.primary.withValues(alpha: 0.12) : Colors.transparent,
      child: bubble,
    );

    if (!_selectionMode && message.messageType != MessageType.call) {
      row = Dismissible(
        key: ValueKey('reply_${message.id}'),
        direction: DismissDirection.startToEnd,
        dismissThresholds: const {DismissDirection.startToEnd: 0.25},
        confirmDismiss: (_) async {
          _startReply(message);
          return false; // snap back — we only want the swipe as a trigger
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

  Widget _buildTextContent(Message message, bool isMe, String timeString) {
    final cs = _cs;
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
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
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
            child: _buildTimestamp(timeString, isMe, cs, status: message.status),
          ),
        ],
      ),
    );
  }

  Widget _buildCallContent(Message message, bool isMe, String timeString) {
    final cs = _cs;
    Map<String, dynamic>? data;
    try {
      if (message.text != null) {
        data = jsonDecode(message.text!);
      }
    } catch (_) {}

    final status = data?['status'] ?? 'ended';
    final duration = data?['duration'] as int? ?? 0;
    final callType = data?['call_type'] ?? 'audio';

    final isMissed = status == 'missed' || status == 'declined';
    final iconColor = isMissed ? cs.error : (isMe ? cs.onPrimary : cs.primary);
    final iconData = callType == 'video' ? Icons.videocam_rounded : Icons.call_rounded;

    String title;
    if (isMissed) {
      title = isMe ? 'Unanswered $callType call' : 'Missed $callType call';
    } else {
      title = '${callType.substring(0, 1).toUpperCase()}${callType.substring(1)} call';
    }

    String subtitle = duration > 0 
        ? '${duration ~/ 60}:${(duration % 60).toString().padLeft(2, '0')}'
        : (isMissed ? 'Missed' : 'Ended');

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
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: isMe ? Colors.white.withValues(alpha: 0.2) : cs.primary.withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(iconData, color: iconColor, size: 20),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: GoogleFonts.inter(
                      color: isMe ? cs.onPrimary : cs.onSurface, fontSize: 16, fontWeight: FontWeight.w600)),
                  Text(subtitle, style: GoogleFonts.inter(
                      color: isMe ? cs.onPrimary.withValues(alpha: 0.8) : cs.onSurfaceVariant, fontSize: 13)),
                ],
              ),
            ],
          ),
          const SizedBox(height: 6),
          _buildTimestamp(timeString, isMe, cs, status: message.status),
        ],
      ),
    );
  }

  Widget _buildImageContent(Message message, bool isMe, String timeString) {
    final cs = _cs;
    final localPath = message.localPath;
    final networkUrl = message.mediaUrl;
    final heroTag = 'media_${message.id}';
    final hasCaption = message.text != null && message.text!.trim().isNotEmpty;

    Widget imageWidget;
    if (localPath != null && File(localPath).existsSync()) {
      imageWidget = Image.file(
        File(localPath),
        width: 220, height: 220, fit: BoxFit.cover,
        cacheWidth: 440, cacheHeight: 440,
        errorBuilder: (_, __, ___) => Container(
            width: 220, height: 220,
            color: cs.surfaceContainerHigh,
            child: Icon(Icons.broken_image_outlined, color: cs.onSurfaceVariant)),
      );
    } else if (networkUrl != null && networkUrl.startsWith('http')) {
      imageWidget = CachedNetworkImage(
        imageUrl: networkUrl,
        width: 220, height: 220, fit: BoxFit.cover,
        memCacheWidth: 440, memCacheHeight: 440,
        placeholder: (_, __) => Container(
                width: 220, height: 220,
                color: cs.surfaceContainerHigh,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CircularProgressIndicator(strokeWidth: 2, color: cs.primary),
                  ],
                ),
              ),
        errorWidget: (_, __, ___) => Container(
            width: 220, height: 100,
            color: cs.surfaceContainerHigh,
            child: Icon(Icons.broken_image_outlined, color: cs.onSurfaceVariant)),
      );
    } else {
      imageWidget = Container(
        width: 220, height: 220,
        color: cs.surfaceContainerHigh,
        child: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }

    final clip = ClipRRect(
      borderRadius: BorderRadius.only(
        topLeft: const Radius.circular(18), topRight: const Radius.circular(18),
        bottomLeft: Radius.circular(isMe ? 18 : 4), bottomRight: Radius.circular(isMe ? 4 : 18),
      ),
      child: GestureDetector(
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => MediaViewerScreen(
                heroTag: heroTag,
                localPath: localPath,
                networkUrl: networkUrl,
              ),
            ),
          );
        },
        child: Stack(
          children: [
            Hero(tag: heroTag, child: imageWidget),
            // When a caption is present the time/ticks move BELOW the caption,
            // so we drop the on-image overlay to avoid showing the time twice.
            if (!hasCaption)
              Positioned(
                  bottom: 8,
                  right: 10,
                  child: _buildTimestampOverlay(timeString, isMe,
                      status: message.status)),
          ],
        ),
      ),
    );
    // Plain photo (no caption, not a reply) → just the rounded image w/ overlay.
    if (message.replyToId == null && !hasCaption) return clip;
    // Otherwise wrap the photo in a bubble so the quoted reply chip and/or the
    // caption (+ time/ticks) can sit above/below it (WhatsApp-style).
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: isMe ? cs.primary : cs.surface,
        border: isMe ? null : Border.all(color: cs.outlineVariant, width: 1),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (message.replyToId != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 4, 6, 0),
              child: _buildReplyChip(message, isMe),
            ),
          clip,
          if (hasCaption)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
              child: Text(
                message.text!.trim(),
                style: GoogleFonts.inter(
                    fontSize: 15,
                    height: 1.35,
                    color: isMe ? cs.onPrimary : cs.onSurface),
              ),
            ),
          if (hasCaption)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
              child: Align(
                alignment: Alignment.centerRight,
                child: _buildTimestamp(timeString, isMe, cs, status: message.status),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildVideoContent(Message message, bool isMe, String timeString) {
    final cs = _cs;
    return GestureDetector(
      onTap: () {
        final heroTag = 'media_${message.id}';
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => MediaViewerScreen(
              heroTag: heroTag,
              localPath: message.localPath,
              networkUrl: message.mediaUrl,
              isVideo: true,
            ),
          ),
        );
      },
      child: Container(
        width: 260,
        decoration: BoxDecoration(
          color: isMe ? cs.primary : cs.surface,
          border: isMe ? null : Border.all(color: cs.outlineVariant, width: 1),
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(18), topRight: const Radius.circular(18),
            bottomLeft: Radius.circular(isMe ? 18 : 4), bottomRight: Radius.circular(isMe ? 4 : 18),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (message.replyToId != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(6, 4, 6, 0),
                  child: _buildReplyChip(message, isMe),
                ),
              // 180px rounded video thumbnail with a circular play overlay
              // (video-sharing-ui-3.html .video-thumb + .play-overlay).
              Hero(
                tag: 'media_${message.id}',
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: SizedBox(
                    height: 180,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        const DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [Color(0xFF2A2A2E), Color(0xFF000000)],
                            ),
                          ),
                        ),
                        Center(
                          child: Container(
                            width: 52,
                            height: 52,
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.5),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.play_arrow_rounded,
                                color: Colors.white, size: 32),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (message.text != null && message.text!.trim().isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                  child: Text(
                    message.text!.trim(),
                    style: GoogleFonts.inter(
                        fontSize: 15,
                        height: 1.35,
                        color: isMe ? cs.onPrimary : cs.onSurface),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: _buildTimestamp(timeString, isMe, cs, status: message.status),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDocumentContent(Message message, bool isMe, String timeString) {
    final cs = _cs;
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
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildReplyChip(message, isMe),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: (isMe ? cs.onPrimary : cs.primary).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(Icons.insert_drive_file_outlined,
                    color: isMe ? cs.onPrimary : cs.primary, size: 24),
              ),
              const SizedBox(width: 12),
              Flexible(
                child: Text(message.fileName ?? 'Document',
                    maxLines: 2, overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.inter(
                        fontSize: 14, fontWeight: FontWeight.w600,
                        color: isMe ? cs.onPrimary : cs.onSurface)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _buildTimestamp(timeString, isMe, cs, status: message.status),
        ],
      ),
    );
  }

  Widget _buildTimestamp(String timeString, bool isMe, ColorScheme cs,
      {String? status}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(timeString, style: GoogleFonts.inter(
            color: isMe ? cs.onPrimary.withValues(alpha: 0.8) : cs.onSurfaceVariant,
            fontSize: 11, fontWeight: FontWeight.w500)),
        if (isMe) ...[
          const SizedBox(width: 4),
          _statusTicks(status, onColored: true),
        ],
      ],
    );
  }

  Widget _buildTimestampOverlay(String timeString, bool isMe, {String? status}) {
    // On dark image overlays, read stays blue but sent/delivered are white.
    Widget ticks;
    if (status == 'read') {
      ticks = const Icon(Icons.done_all, size: 14, color: Color(0xFF34B7F1));
    } else if (status == 'sent') {
      ticks = const Icon(Icons.done, size: 14, color: Colors.white);
    } else {
      ticks = const Icon(Icons.done_all, size: 14, color: Colors.white);
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(timeString, style: GoogleFonts.inter(color: Colors.white, fontSize: 11)),
          if (isMe) ...[
            const SizedBox(width: 4),
            ticks,
          ],
        ],
      ),
    );
  }

  Widget _buildInputBar() {
    final cs = _cs;
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLowest,
        border: Border(top: BorderSide(color: cs.outlineVariant, width: 1)),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            // ── The typing pill: emoji · roomy text field · attach · camera ──
            Expanded(
              child: Container(
                // Large & horizontal: taller minimum, grows up to ~6 lines
                // before scrolling. Everything (emoji · text · attach · camera ·
                // mic/send) lives inside this one roomy bar. Side icons are kept
                // compact so the text field keeps the maximum horizontal room
                // and can be typed in freely.
                constraints: const BoxConstraints(minHeight: 56, maxHeight: 160),
                padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
                decoration: BoxDecoration(
                  color: cs.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(28),
                  border: Border.all(color: cs.outlineVariant),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    IconButton(
                      icon: Icon(
                          _showEmojiPicker
                              ? Icons.keyboard_outlined
                              : Icons.emoji_emotions_outlined,
                          color: cs.onSurfaceVariant,
                          size: 24),
                      onPressed: () => setState(() {
                        _showEmojiPicker = !_showEmojiPicker;
                        if (_showEmojiPicker) {
                          FocusManager.instance.primaryFocus?.unfocus();
                        } else {
                          _focusNode.requestFocus();
                        }
                      }),
                      padding: EdgeInsets.zero,
                      constraints:
                          const BoxConstraints(minWidth: 36, minHeight: 44),
                    ),
                    Expanded(
                      child: TextField(
                        controller: _textController,
                        focusNode: _focusNode,
                        minLines: 1,
                        maxLines: 6,
                        keyboardType: TextInputType.multiline,
                        textInputAction: TextInputAction.newline,
                        textCapitalization: TextCapitalization.sentences,
                        style: GoogleFonts.inter(
                            fontSize: 16, color: cs.onSurface, height: 1.35),
                        onTap: () {
                          if (_showEmojiPicker) {
                            setState(() => _showEmojiPicker = false);
                          }
                        },
                        decoration: InputDecoration(
                          hintText: 'Type a message...',
                          hintStyle: GoogleFonts.inter(
                              color: cs.onSurfaceVariant, fontSize: 16),
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          contentPadding:
                              const EdgeInsets.fromLTRB(4, 14, 4, 14),
                          isDense: false,
                        ),
                      ),
                    ),
                    // Attachments (gallery / video / document / camera sheet)
                    IconButton(
                      icon: Icon(Icons.attach_file_rounded,
                          color: cs.onSurfaceVariant, size: 22),
                      onPressed: _isSendingMedia ? null : _showAttachmentSheet,
                      padding: EdgeInsets.zero,
                      constraints:
                          const BoxConstraints(minWidth: 36, minHeight: 44),
                    ),
                    // Camera — opens the in-app camera capture screen.
                    IconButton(
                      icon: Icon(Icons.camera_alt_rounded,
                          color: cs.primary, size: 23),
                      tooltip: 'Camera',
                      onPressed: _isSendingMedia ? null : _openCamera,
                      padding: EdgeInsets.zero,
                      constraints:
                          const BoxConstraints(minWidth: 36, minHeight: 44),
                    ),
                    const SizedBox(width: 2),
                    // ── Mic / Send — merged INTO the bar as a filled circle so
                    //    the composer is one large horizontal control ──
                    Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: cs.primary,
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                                color: Colors.black.withValues(alpha: 0.1),
                                blurRadius: 4,
                                offset: const Offset(0, 2))
                          ],
                        ),
                        child: IconButton(
                          icon: _isSendingMedia
                              ? SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                      color: cs.onPrimary, strokeWidth: 2))
                              : Icon(
                                  _hasText
                                      ? Icons.send_rounded
                                      : Icons.mic_none_rounded,
                                  color: cs.onPrimary,
                                  size: 22),
                          onPressed: _isSendingMedia
                              ? null
                              : (_hasText
                                  ? _sendMessage
                                  : () {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                          const SnackBar(
                                              content: Text(
                                                  'Voice messages coming soon')));
                                    }),
                          padding: EdgeInsets.zero,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Opens the in-app camera capture screen. On a successful capture the photo
  /// is shown in the existing preview dialog and then uploaded + sent through
  /// the normal media pipeline.
  ///
  /// NOTE: unlike [_sendImage], this does NOT call Navigator.pop() at the start
  /// — the old camera button reused [_sendImage] whose first line popped the
  /// route, which (when triggered from the input bar rather than the attachment
  /// sheet) closed the whole chat screen instead of opening the camera.
  Future<void> _openCamera() async {
    // Camera + mic permissions (mic lets the same screen capture video too).
    final statuses = await [Permission.camera].request();
    if (statuses[Permission.camera] != PermissionStatus.granted) {
      if (mounted) _showError('Camera permission is required to take photos.');
      return;
    }

    if (!mounted) return;

    final String? path = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const CameraScreen()),
    );
    if (path == null || path.isEmpty) return;
    if (!mounted) return;

    final caption = await _showMediaPreview(File(path), isVideo: false);
    if (caption == null) return; // user cancelled

    setState(() {
      _isSendingMedia = true;
      _uploadProgress = 0;
    });
    try {
      final url = await MediaUploadService().uploadChatImage(File(path));
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final msg = Message(
        id: '${widget.myUsername}_$timestamp',
        senderUsername: widget.myUsername,
        receiverUsername: widget.receiverUsername,
        text: caption.isNotEmpty ? caption : null,
        mediaUrl: url,
        localPath: path,
        messageType: MessageType.image,
        isMe: true,
        timestamp: timestamp,
      );
      if (mounted) {
        setState(() => _messages.add(msg));
        _scrollToBottom();
      }
      await SupabaseBroadcastService().sendMessage(msg);
    } catch (e) {
      if (mounted) _showError('Failed to send photo: $e');
    } finally {
      if (mounted) setState(() => _isSendingMedia = false);
    }
  }
}

class _LastSeenSubtitle extends StatefulWidget {
  final bool isOnline;
  final DateTime? lastSeen;
  final ColorScheme cs;

  const _LastSeenSubtitle({required this.isOnline, this.lastSeen, required this.cs});

  @override
  State<_LastSeenSubtitle> createState() => _LastSeenSubtitleState();
}

class _LastSeenSubtitleState extends State<_LastSeenSubtitle> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      if (widget.isOnline) ...[
        Container(width: 8, height: 8,
            decoration: BoxDecoration(color: widget.cs.primary, shape: BoxShape.circle)),
        const SizedBox(width: 4),
        Text('Online', style: GoogleFonts.inter(fontSize: 13, color: widget.cs.primary, fontWeight: FontWeight.w500)),
      ] else ...[
        Text(_ChatScreenState._formatLastSeen(widget.lastSeen), style: GoogleFonts.inter(fontSize: 13, color: widget.cs.onSurfaceVariant, fontWeight: FontWeight.w400)),
      ],
    ]);
  }
}

