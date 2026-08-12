import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
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
import 'call_screen.dart';
import '../services/call_service.dart';
import 'package:permission_handler/permission_handler.dart';
import '../widgets/user_avatar.dart';

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
  double _uploadProgress = 0;
  String _receiverAvatarUrl = '';

  StreamSubscription<List<Map<String, dynamic>>>? _presenceSubscription;
  bool _isPeerOnline = false;
  DateTime? _peerLastSeen;

  /// WhatsApp-style display name — resolved from widget param or local contacts DB.
  String? _displayName;

  /// Block status for this peer user.
  bool _isBlocked = false;

  /// Timer that periodically refreshes the "last seen X ago" text.
  Timer? _lastSeenRefreshTimer;

  /// Cached ColorScheme — set at the top of build() so all helper methods can use it.
  late ColorScheme _cs;

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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _loadMessages();
    });
    _listenToPeerPresence();
    // Auto-refresh "Last seen X ago" text every 30 seconds
    _lastSeenRefreshTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
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
    _lastSeenRefreshTimer?.cancel();
    SupabaseBroadcastService().activeChatUser = null;
    _messageSubscription?.cancel();
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
    _scrollToBottom();
  }

  Future<void> _loadMessages() async {
    final messages = await LocalDbService().getMessages(widget.myUsername, widget.receiverUsername);
    if (mounted) {
      setState(() => _messages = messages);
      _scrollToBottom();
    }
  }

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

  Future<void> _sendMessage() async {
    final text = _textController.text.trim();
    if (text.isEmpty) return;
    _textController.clear();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final msg = Message(
      id: '${widget.myUsername}_$timestamp',
      senderUsername: widget.myUsername,
      receiverUsername: widget.receiverUsername,
      text: text,
      messageType: MessageType.text,
      isMe: true,
      timestamp: timestamp,
    );
    setState(() => _messages.add(msg));
    _scrollToBottom();
    await SupabaseBroadcastService().sendMessage(msg);
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
      final confirmed = await _showImagePreview(File(pickedFiles.first.path));
      if (confirmed != true) return;

      setState(() { _isSendingMedia = true; _uploadProgress = 0; });
      
      for (int i = 0; i < pickedFiles.length; i++) {
        final picked = pickedFiles[i];
        try {
          final url = await MediaUploadService().uploadChatImage(File(picked.path));
          final timestamp = DateTime.now().millisecondsSinceEpoch;
          final msg = Message(
            id: '${widget.myUsername}_$timestamp',
            senderUsername: widget.myUsername,
            receiverUsername: widget.receiverUsername,
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
      final confirmed = await _showVideoPreview(File(picked.path));
      if (confirmed != true) return;

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

  Future<bool?> _showImagePreview(File imageFile) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.black,
        insetPadding: EdgeInsets.zero,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image.file(imageFile, fit: BoxFit.contain),
            Positioned(
              bottom: 32,
              left: 0, right: 0,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  ElevatedButton.icon(
                    onPressed: () => Navigator.pop(ctx, false),
                    icon: const Icon(Icons.close, color: Colors.white),
                    label: Text('Cancel', style: GoogleFonts.outfit(color: Colors.white, fontWeight: FontWeight.w600)),
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.black54, shape: const StadiumBorder()),
                  ),
                  ElevatedButton.icon(
                    onPressed: () => Navigator.pop(ctx, true),
                    icon: const Icon(Icons.send_rounded, color: Colors.white),
                    label: Text('Send', style: GoogleFonts.outfit(color: Colors.white, fontWeight: FontWeight.w700)),
                    style: ElevatedButton.styleFrom(backgroundColor: _cs.primary, shape: const StadiumBorder()),
                  ),
                ],
              ),
            ),
            Positioned(
              top: 40, left: 16,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white, size: 28),
                onPressed: () => Navigator.pop(ctx, false),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<bool?> _showVideoPreview(File videoFile) {
    final cs = _cs;
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: cs.surface,
        title: Text('Send Video?', style: GoogleFonts.outfit(fontWeight: FontWeight.w700, color: cs.onSurface)),
        content: Row(
          children: [
            Icon(Icons.videocam_outlined, size: 40, color: cs.primary),
            const SizedBox(width: 12),
            Expanded(child: Text('The video will be compressed and sent.', style: GoogleFonts.outfit(color: cs.onSurfaceVariant))),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('Cancel', style: GoogleFonts.outfit(color: cs.outline))),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: cs.primary),
            child: Text('Send', style: GoogleFonts.outfit(color: cs.onPrimary, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: GoogleFonts.outfit()),
      backgroundColor: _cs.error,
      behavior: SnackBarBehavior.floating,
    ));
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
          Text(label, style: GoogleFonts.outfit(fontSize: 12, fontWeight: FontWeight.w500, color: cs.onSurfaceVariant)),
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

  String _formatLastSeen(DateTime? lastSeen) {
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
        title: Text('Clear Chat', style: GoogleFonts.outfit(fontWeight: FontWeight.w700, color: cs.onSurface)),
        content: Text('Are you sure you want to delete all messages? This cannot be undone locally.', style: GoogleFonts.outfit(color: cs.onSurfaceVariant)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text('Cancel', style: GoogleFonts.outfit(color: cs.outline))),
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
            child: Text('Clear', style: GoogleFonts.outfit(color: cs.onError)),
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
          style: GoogleFonts.outfit(fontWeight: FontWeight.w700, color: cs.onSurface),
        ),
        content: Text(
          isCurrentlyBlocked
              ? 'Unblock ${_displayName ?? widget.receiverUsername}? You will start receiving messages from this user again.'
              : 'Block ${_displayName ?? widget.receiverUsername}? Blocked contacts will no longer be able to send you messages or call you.',
          style: GoogleFonts.outfit(color: cs.onSurfaceVariant, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancel', style: GoogleFonts.outfit(color: cs.outline)),
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
                          style: GoogleFonts.outfit(fontWeight: FontWeight.w500)),
                      backgroundColor: Colors.green.shade600,
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
                          style: GoogleFonts.outfit(fontWeight: FontWeight.w500)),
                      backgroundColor: cs.error,
                      behavior: SnackBarBehavior.floating,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  );
                }
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: isCurrentlyBlocked ? Colors.green.shade600 : cs.error,
            ),
            child: Text(
              isCurrentlyBlocked ? 'Unblock' : 'Block',
              style: GoogleFonts.outfit(color: cs.onError),
            ),
          ),
        ],
      ),
    );
  }

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
                        style: GoogleFonts.outfit(color: _cs.error, fontWeight: FontWeight.w500, fontSize: 14),
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
                      child: Text('Unblock', style: GoogleFonts.outfit(color: _cs.error, fontWeight: FontWeight.w600, fontSize: 13)),
                    ),
                  ],
                ),
              )
            else
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
              builder: (_) => ProfileScreen(peerUsername: widget.receiverUsername),
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
                    style: GoogleFonts.outfit(fontSize: 18, fontWeight: FontWeight.w700, color: cs.onSurface),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Row(children: [
                    if (_isPeerOnline) ...[
                      Container(width: 8, height: 8,
                          decoration: BoxDecoration(color: Colors.green.shade400, shape: BoxShape.circle)),
                      const SizedBox(width: 4),
                      Text('Online', style: GoogleFonts.outfit(fontSize: 13, color: Colors.green.shade500, fontWeight: FontWeight.w500)),
                    ] else ...[
                      Text(_formatLastSeen(_peerLastSeen), style: GoogleFonts.outfit(fontSize: 13, color: cs.onSurfaceVariant, fontWeight: FontWeight.w400)),
                    ],
                  ]),
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
          onPressed: () async {
            final statuses = await [Permission.microphone].request();
            if (statuses[Permission.microphone] != PermissionStatus.granted) {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                  content: Text('Microphone permission is required to make an audio call.'),
                ));
              }
              return;
            }
            final result = await CallService().initiateCall(
              receiverUsername: widget.receiverUsername,
              callType: 'audio',
            );
            if (!mounted) return;
            if (result.error != null) {
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text('Call failed: ${result.error}'),
                duration: const Duration(seconds: 6),
              ));
            } else {
              final sorted = [CallService.sanitizeUsername(widget.myUsername), CallService.sanitizeUsername(widget.receiverUsername)]..sort();
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
                    callType: 'audio',
                    isOutgoing: true,
                  ),
                ),
              );
            }
          },
        ),
        IconButton(
          icon: Icon(Icons.videocam_outlined, color: cs.primary, size: 26),
          tooltip: 'Video Call',
          onPressed: () async {
            final statuses = await [Permission.camera, Permission.microphone].request();
            if (statuses[Permission.camera] != PermissionStatus.granted ||
                statuses[Permission.microphone] != PermissionStatus.granted) {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                  content: Text('Camera and Microphone permissions are required to make a call.'),
                ));
              }
              return;
            }
            final result = await CallService().initiateCall(
              receiverUsername: widget.receiverUsername,
              callType: 'video',
            );
            if (!mounted) return;
            if (result.error != null) {
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text('Call failed: ${result.error}'),
                duration: const Duration(seconds: 6),
              ));
            } else {
              final sorted = [CallService.sanitizeUsername(widget.myUsername), CallService.sanitizeUsername(widget.receiverUsername)]..sort();
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
                    callType: 'video',
                    isOutgoing: true,
                  ),
                ),
              );
            }
          },
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
            PopupMenuItem(value: 'clear', child: Text('Clear Chat', style: GoogleFonts.outfit())),
            PopupMenuItem(
              value: 'block',
              child: Text(
                _isBlocked ? 'Unblock User' : 'Block User',
                style: GoogleFonts.outfit(color: _isBlocked ? Colors.green.shade600 : null),
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
        child: Text(label, style: GoogleFonts.outfit(fontSize: 12, fontWeight: FontWeight.w600, color: cs.onSurfaceVariant)),
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

    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
        child: content,
      ),
    );
  }

  Widget _buildTextContent(Message message, bool isMe, String timeString) {
    final cs = _cs;
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
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(message.text ?? '', style: GoogleFonts.outfit(
              color: isMe ? cs.onPrimary : cs.onSurface, fontSize: 16, height: 1.4)),
          const SizedBox(height: 6),
          _buildTimestamp(timeString, isMe, cs),
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
        color: isMe ? cs.primary : cs.surfaceContainerHighest,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(24), topRight: const Radius.circular(24),
          bottomLeft: Radius.circular(isMe ? 24 : 8), bottomRight: Radius.circular(isMe ? 8 : 24),
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
                  Text(title, style: GoogleFonts.outfit(
                      color: isMe ? cs.onPrimary : cs.onSurface, fontSize: 16, fontWeight: FontWeight.w600)),
                  Text(subtitle, style: GoogleFonts.outfit(
                      color: isMe ? cs.onPrimary.withValues(alpha: 0.8) : cs.onSurfaceVariant, fontSize: 13)),
                ],
              ),
            ],
          ),
          const SizedBox(height: 6),
          _buildTimestamp(timeString, isMe, cs),
        ],
      ),
    );
  }

  Widget _buildImageContent(Message message, bool isMe, String timeString) {
    final cs = _cs;
    final localPath = message.localPath;
    final networkUrl = message.mediaUrl;
    final heroTag = 'media_${message.id}';

    Widget imageWidget;
    if (localPath != null && File(localPath).existsSync()) {
      imageWidget = Image.file(
        File(localPath),
        width: 220, height: 220, fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => Container(
            width: 220, height: 220,
            color: cs.surfaceContainerHigh,
            child: Icon(Icons.broken_image_outlined, color: cs.onSurfaceVariant)),
      );
    } else if (networkUrl != null && networkUrl.startsWith('http')) {
      imageWidget = Image.network(
        networkUrl,
        width: 220, height: 220, fit: BoxFit.cover,
        loadingBuilder: (_, child, progress) => progress == null
            ? child
            : Container(
                width: 220, height: 220,
                color: cs.surfaceContainerHigh,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CircularProgressIndicator(
                      value: progress.expectedTotalBytes != null
                          ? progress.cumulativeBytesLoaded / progress.expectedTotalBytes!
                          : null,
                      strokeWidth: 2, color: cs.primary,
                    ),
                  ],
                ),
              ),
        errorBuilder: (_, __, ___) => Container(
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

    return ClipRRect(
      borderRadius: BorderRadius.only(
        topLeft: const Radius.circular(24), topRight: const Radius.circular(24),
        bottomLeft: Radius.circular(isMe ? 24 : 8), bottomRight: Radius.circular(isMe ? 8 : 24),
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
            Positioned(bottom: 8, right: 10, child: _buildTimestampOverlay(timeString, isMe)),
          ],
        ),
      ),
    );
  }

  Widget _buildVideoContent(Message message, bool isMe, String timeString) {
    final cs = _cs;
    return Container(
      width: 220,
      decoration: BoxDecoration(
        color: isMe ? cs.primary : cs.surfaceContainerHighest,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(24), topRight: const Radius.circular(24),
          bottomLeft: Radius.circular(isMe ? 24 : 8), bottomRight: Radius.circular(isMe ? 8 : 24),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Container(
              height: 100,
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Center(
                child: Icon(Icons.play_circle_filled_rounded, size: 48, color: Colors.white),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.videocam_outlined, size: 16, color: isMe ? cs.onPrimary : cs.onSurfaceVariant),
                const SizedBox(width: 6),
                Text('Video', style: GoogleFonts.outfit(
                    fontSize: 14, color: isMe ? cs.onPrimary : cs.onSurface, fontWeight: FontWeight.w500)),
                const Spacer(),
                _buildTimestamp(timeString, isMe, cs),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDocumentContent(Message message, bool isMe, String timeString) {
    final cs = _cs;
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
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
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
                    style: GoogleFonts.outfit(
                        fontSize: 14, fontWeight: FontWeight.w600,
                        color: isMe ? cs.onPrimary : cs.onSurface)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _buildTimestamp(timeString, isMe, cs),
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

  Widget _buildTimestampOverlay(String timeString, bool isMe) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(timeString, style: GoogleFonts.outfit(color: Colors.white, fontSize: 11)),
          if (isMe) ...[
            const SizedBox(width: 4),
            const Icon(Icons.done_all, size: 14, color: Colors.white),
          ],
        ],
      ),
    );
  }

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
                    IconButton(
                      icon: Icon(Icons.attach_file_rounded, color: cs.onSurfaceVariant, size: 24),
                      onPressed: _isSendingMedia ? null : _showAttachmentSheet,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 44, minHeight: 48),
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
                icon: _isSendingMedia
                    ? SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: cs.onPrimary, strokeWidth: 2))
                    : Icon(Icons.send_rounded, color: cs.onPrimary, size: 22),
                onPressed: _isSendingMedia ? null : _sendMessage,
                padding: EdgeInsets.zero,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
