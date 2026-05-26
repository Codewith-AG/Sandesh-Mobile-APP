import 'dart:io';
import 'dart:async';
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
import '../theme/app_theme.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'profile_screen.dart';
import 'media_viewer_screen.dart';
import 'call_screen.dart';
import '../services/call_service.dart';
import 'package:permission_handler/permission_handler.dart';

class ChatScreen extends StatefulWidget {
  final String myUsername;
  final String receiverUsername;

  const ChatScreen({
    super.key,
    required this.myUsername,
    required this.receiverUsername,
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

  @override
  void initState() {
    super.initState();
    _loadMessages();
    _loadReceiverAvatar();
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
  }

  Future<void> _loadReceiverAvatar() async {
    try {
      // Fetch directly from Supabase so we always get the latest URL
      final response = await Supabase.instance.client
          .from('profiles')
          .select('avatar_url')
          .eq('username', widget.receiverUsername)
          .maybeSingle();
      final url = (response?['avatar_url'] as String?) ?? '';
      if (url.isNotEmpty && mounted) {
        setState(() => _receiverAvatarUrl = url);
      }
    } catch (_) {
      // Fallback to local DB
      final contacts = await LocalDbService().getContacts();
      try {
        final c = contacts.firstWhere((c) => c.username == widget.receiverUsername);
        if (c.avatarUrl.isNotEmpty && mounted) {
          setState(() => _receiverAvatarUrl = c.avatarUrl);
        }
      } catch (_) {}
    }
  }

  void _listenToPeerPresence() {
    final client = Supabase.instance.client;
    final peer = widget.receiverUsername.toLowerCase();

    // NOTE: We use the `.stream()` API instead of `.channel()` because it is much
    // more reliable and automatically handles fetching initial state plus all realtime
    // updates under the hood.
    _presenceSubscription = client
        .from('profiles')
        .stream(primaryKey: ['username'])
        .eq('username', peer)
        .listen((data) {
      if (data.isNotEmpty && mounted) {
        final profile = data.first;
        setState(() {
          _isPeerOnline = profile['is_online'] == true;
          final raw = profile['last_seen'] as String?;
          if (raw != null) _peerLastSeen = DateTime.tryParse(raw);
        });
      }
    }, onError: (e) {
      debugPrint('Presence stream error: $e');
    });
  }

  @override
  void dispose() {
    _presenceSubscription?.cancel();
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
    Navigator.pop(context); // close bottom sheet
    try {
      final picked = await ImagePicker().pickImage(source: source);
      if (picked == null) return;

      // Show preview — only upload if user confirms
      if (!mounted) return;
      final confirmed = await _showImagePreview(File(picked.path));
      if (confirmed != true) return;

      setState(() { _isSendingMedia = true; _uploadProgress = 0; });
      final url = await MediaUploadService().uploadChatImage(File(picked.path));
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final msg = Message(
        id: '${widget.myUsername}_$timestamp',
        senderUsername: widget.myUsername,
        receiverUsername: widget.receiverUsername,
        mediaUrl: url,
        // Sender stores the original local file path for immediate local rendering
        localPath: picked.path,
        messageType: MessageType.image,
        isMe: true,
        timestamp: timestamp,
      );
      setState(() { _messages.add(msg); _isSendingMedia = false; });
      _scrollToBottom();
      await SupabaseBroadcastService().sendMessage(msg);
    } catch (e) {
      setState(() => _isSendingMedia = false);
      if (mounted) _showError('Image upload failed: $e');
    }
  }

  Future<void> _sendVideo() async {
    Navigator.pop(context);
    try {
      final picked = await ImagePicker().pickVideo(source: ImageSource.gallery);
      if (picked == null) return;

      // Show preview thumbnail before upload
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
      final result = await FilePicker.platform.pickFiles(type: FileType.any);
      if (result == null || result.files.single.path == null) return;
      final f = result.files.single;
      setState(() { _isSendingMedia = true; _uploadProgress = 0; });
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
      setState(() { _messages.add(msg); _isSendingMedia = false; });
      _scrollToBottom();
      await SupabaseBroadcastService().sendMessage(msg);
    } catch (e) {
      setState(() => _isSendingMedia = false);
      if (mounted) _showError('Document upload failed: $e');
    }
  }

  /// Shows a fullscreen preview of a picked image with Send/Cancel buttons.
  /// Returns true if the user confirmed sending.
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
                    style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary, shape: const StadiumBorder()),
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

  /// Shows a simple confirmation dialog for video before upload.
  Future<bool?> _showVideoPreview(File videoFile) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surfaceContainerLowest,
        title: Text('Send Video?', style: GoogleFonts.outfit(fontWeight: FontWeight.w700, color: AppTheme.onSurface)),
        content: Row(
          children: [
            Icon(Icons.videocam_outlined, size: 40, color: AppTheme.primary),
            const SizedBox(width: 12),
            Expanded(child: Text('The video will be compressed and sent.', style: GoogleFonts.outfit(color: AppTheme.onSurfaceVariant))),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('Cancel', style: GoogleFonts.outfit(color: AppTheme.outline))),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary),
            child: Text('Send', style: GoogleFonts.outfit(color: AppTheme.onPrimary, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: GoogleFonts.outfit()),
      backgroundColor: AppTheme.error,
      behavior: SnackBarBehavior.floating,
    ));
  }

  void _showAttachmentSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
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
                      color: const Color(0xFFE0E0E0),
                      borderRadius: BorderRadius.circular(2))),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _attachOption(Icons.photo_library_outlined, 'Gallery', () => _sendImage(ImageSource.gallery)),
                  _attachOption(Icons.camera_alt_outlined, 'Camera', () => _sendImage(ImageSource.camera)),
                  _attachOption(Icons.videocam_outlined, 'Video', _sendVideo),
                  _attachOption(Icons.insert_drive_file_outlined, 'Document', _sendDocument),
                ],
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  Widget _attachOption(IconData icon, String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 56, height: 56,
            decoration: BoxDecoration(
              color: const Color(0xFFF0F0F5),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(icon, color: const Color(0xFF1A1A2E), size: 26),
          ),
          const SizedBox(height: 8),
          Text(label, style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w500, color: const Color(0xFF5A5A72))),
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
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surfaceContainerLowest,
        title: Text('Clear Chat', style: GoogleFonts.outfit(fontWeight: FontWeight.w700, color: AppTheme.onSurface)),
        content: Text('Are you sure you want to delete all messages? This cannot be undone locally.', style: GoogleFonts.outfit(color: AppTheme.onSurfaceVariant)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text('Cancel', style: GoogleFonts.outfit(color: AppTheme.outline))),
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
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.error),
            child: Text('Clear', style: GoogleFonts.outfit(color: AppTheme.onError)),
          ),
        ],
      ),
    );
  }

  void _showBlockUserConfirm() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surfaceContainerLowest,
        title: Text('Block User', style: GoogleFonts.outfit(fontWeight: FontWeight.w700, color: AppTheme.onSurface)),
        content: Text('Are you sure you want to block this user?', style: GoogleFonts.outfit(color: AppTheme.onSurfaceVariant)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text('Cancel', style: GoogleFonts.outfit(color: AppTheme.outline))),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('User blocked.', style: GoogleFonts.outfit()), backgroundColor: AppTheme.primary),
                );
              }
            },
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.error),
            child: Text('Block', style: GoogleFonts.outfit(color: AppTheme.onError)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final items = _buildMessageListWithDates();
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: _buildAppBar(),
      body: SafeArea(
        child: Column(
          children: [
            if (_isSendingMedia)
              LinearProgressIndicator(
                value: _uploadProgress > 0 ? _uploadProgress : null,
                backgroundColor: AppTheme.surfaceContainer,
                color: AppTheme.primary,
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
                      backgroundColor: AppTheme.background,
                      columns: 7, emojiSizeMax: 32,
                    ),
                    categoryViewConfig: const CategoryViewConfig(
                      backgroundColor: AppTheme.background,
                      indicatorColor: AppTheme.primary,
                      iconColorSelected: AppTheme.primary,
                    ),
                    bottomActionBarConfig: const BottomActionBarConfig(
                      backgroundColor: AppTheme.background,
                      buttonColor: AppTheme.background,
                      buttonIconColor: AppTheme.primary,
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
    return AppBar(
      backgroundColor: AppTheme.surfaceContainerLowest,
      titleSpacing: 0,
      leading: IconButton(
        icon: const Icon(Icons.arrow_back_ios_new, size: 20),
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
            _buildReceiverAvatar(),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.receiverUsername,
                    style: GoogleFonts.outfit(fontSize: 18, fontWeight: FontWeight.w700, color: AppTheme.onSurface)),
                Row(children: [
                  if (_isPeerOnline) ...[
                    Container(width: 8, height: 8,
                        decoration: BoxDecoration(color: Colors.green.shade400, shape: BoxShape.circle)),
                    const SizedBox(width: 4),
                    Text('Online', style: GoogleFonts.outfit(fontSize: 13, color: Colors.green.shade500, fontWeight: FontWeight.w500)),
                  ] else ...[
                    Text(_formatLastSeen(_peerLastSeen), style: GoogleFonts.outfit(fontSize: 13, color: AppTheme.onSurfaceVariant, fontWeight: FontWeight.w400)),
                  ],
                ]),
              ],
            ),
          ],
        ),
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.call_outlined, color: AppTheme.primary, size: 24),
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
            final error = await CallService().initiateCall(
              receiverUsername: widget.receiverUsername,
              callType: 'audio',
            );
            if (!mounted) return;
            if (error != null) {
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text('Call failed: $error'),
                duration: const Duration(seconds: 6),
              ));
            } else {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => _buildCallScreen('audio'),
                ),
              );
            }
          },
        ),
        IconButton(
          icon: const Icon(Icons.videocam_outlined, color: AppTheme.primary, size: 26),
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
            final error = await CallService().initiateCall(
              receiverUsername: widget.receiverUsername,
              callType: 'video',
            );
            if (!mounted) return;
            if (error != null) {
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text('Call failed: $error'),
                duration: const Duration(seconds: 6),
              ));
            } else {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => _buildCallScreen('video'),
                ),
              );
            }
          },
        ),
        PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert_rounded, color: AppTheme.onSurfaceVariant, size: 24),
          onSelected: (value) {
            if (value == 'clear') {
              _showClearChatConfirm();
            } else if (value == 'block') {
              _showBlockUserConfirm();
            }
          },
          itemBuilder: (context) => [
            PopupMenuItem(value: 'clear', child: Text('Clear Chat', style: GoogleFonts.outfit())),
            PopupMenuItem(value: 'block', child: Text('Block User', style: GoogleFonts.outfit())),
          ],
        ),
        const SizedBox(width: 4),
      ],
    );
  }

  Widget _buildReceiverAvatar() {
    if (_receiverAvatarUrl.startsWith('http')) {
      return CircleAvatar(
        radius: 20,
        backgroundColor: AppTheme.surfaceContainerHigh,
        backgroundImage: NetworkImage(_receiverAvatarUrl),
        onBackgroundImageError: (_, __) {},
      );
    }
    return CircleAvatar(
      radius: 20,
      backgroundColor: AppTheme.surfaceContainerHigh,
      child: Text(
        widget.receiverUsername.isNotEmpty ? widget.receiverUsername[0].toUpperCase() : '?',
        style: GoogleFonts.outfit(color: AppTheme.primary, fontWeight: FontWeight.w700, fontSize: 18),
      ),
    );
  }

  Widget _buildDateSeparator(String label) {
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 16),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: AppTheme.surfaceContainerLowest,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: AppTheme.surfaceVariant),
        ),
        child: Text(label, style: GoogleFonts.outfit(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.onSurfaceVariant)),
      ),
    );
  }

  Widget _buildCallScreen(String callType) {
    final sorted = [widget.myUsername.toLowerCase(), widget.receiverUsername.toLowerCase()]..sort();
    final channelName = 'call_${sorted[0]}_${sorted[1]}';
    return FutureBuilder<CallToken?>(
      future: CallService().fetchTokenForChannel(channelName),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(
            backgroundColor: AppTheme.background,
            body: Center(child: CircularProgressIndicator(color: AppTheme.primary)),
          );
        }
        final ct = snapshot.data;
        if (ct == null) {
          return Scaffold(
            backgroundColor: AppTheme.background,
            body: Center(
              child: Text(
                'Could not start the call. Please try again.',
                style: GoogleFonts.outfit(color: AppTheme.onSurface),
              ),
            ),
          );
        }
        return CallScreen(
          myUsername: widget.myUsername,
          peerUsername: widget.receiverUsername,
          channelName: channelName,
          token: ct.token,
          agoraUid: ct.uid,
          callType: callType,
          isOutgoing: true,
        );
      },
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
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
      decoration: BoxDecoration(
        color: isMe ? AppTheme.primary : AppTheme.surfaceContainer,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(24), topRight: const Radius.circular(24),
          bottomLeft: Radius.circular(isMe ? 24 : 8), bottomRight: Radius.circular(isMe ? 8 : 24),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(message.text ?? '', style: GoogleFonts.outfit(
              color: isMe ? AppTheme.onPrimary : AppTheme.onSurface, fontSize: 16, height: 1.4)),
          const SizedBox(height: 6),
          _buildTimestamp(timeString, isMe),
        ],
      ),
    );
  }

  Widget _buildImageContent(Message message, bool isMe, String timeString) {
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
            color: AppTheme.surfaceContainerHigh,
            child: Icon(Icons.broken_image_outlined, color: AppTheme.onSurfaceVariant)),
      );
    } else if (networkUrl != null && networkUrl.startsWith('http')) {
      imageWidget = Image.network(
        networkUrl,
        width: 220, height: 220, fit: BoxFit.cover,
        loadingBuilder: (_, child, progress) => progress == null
            ? child
            : Container(
                width: 220, height: 220,
                color: AppTheme.surfaceContainerHigh,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CircularProgressIndicator(
                      value: progress.expectedTotalBytes != null
                          ? progress.cumulativeBytesLoaded / progress.expectedTotalBytes!
                          : null,
                      strokeWidth: 2, color: AppTheme.primary,
                    ),
                  ],
                ),
              ),
        errorBuilder: (_, __, ___) => Container(
            width: 220, height: 100,
            color: AppTheme.surfaceContainerHigh,
            child: Icon(Icons.broken_image_outlined, color: AppTheme.onSurfaceVariant)),
      );
    } else {
      imageWidget = Container(
        width: 220, height: 220,
        color: AppTheme.surfaceContainerHigh,
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
    return Container(
      width: 220,
      decoration: BoxDecoration(
        color: isMe ? AppTheme.primary : AppTheme.surfaceContainer,
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
                Icon(Icons.videocam_outlined, size: 16, color: isMe ? AppTheme.onPrimary : AppTheme.onSurfaceVariant),
                const SizedBox(width: 6),
                Text('Video', style: GoogleFonts.outfit(
                    fontSize: 14, color: isMe ? AppTheme.onPrimary : AppTheme.onSurface, fontWeight: FontWeight.w500)),
                const Spacer(),
                _buildTimestamp(timeString, isMe),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDocumentContent(Message message, bool isMe, String timeString) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
      decoration: BoxDecoration(
        color: isMe ? AppTheme.primary : AppTheme.surfaceContainer,
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
                  color: (isMe ? AppTheme.onPrimary : AppTheme.primary).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(Icons.insert_drive_file_outlined,
                    color: isMe ? AppTheme.onPrimary : AppTheme.primary, size: 24),
              ),
              const SizedBox(width: 12),
              Flexible(
                child: Text(message.fileName ?? 'Document',
                    maxLines: 2, overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.outfit(
                        fontSize: 14, fontWeight: FontWeight.w600,
                        color: isMe ? AppTheme.onPrimary : AppTheme.onSurface)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _buildTimestamp(timeString, isMe),
        ],
      ),
    );
  }

  Widget _buildTimestamp(String timeString, bool isMe) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(timeString, style: GoogleFonts.outfit(
            color: isMe ? AppTheme.onPrimary.withValues(alpha: 0.8) : AppTheme.onSurfaceVariant,
            fontSize: 11, fontWeight: FontWeight.w500)),
        if (isMe) ...[
          const SizedBox(width: 4),
          Icon(Icons.done_all, size: 14, color: AppTheme.onPrimary.withValues(alpha: 0.8)),
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
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        color: AppTheme.surfaceContainerLowest,
        border: Border(top: BorderSide(color: AppTheme.surfaceVariant, width: 1)),
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
                  color: AppTheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: AppTheme.surfaceVariant),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    IconButton(
                      icon: Icon(_showEmojiPicker ? Icons.keyboard_outlined : Icons.emoji_emotions_outlined,
                          color: AppTheme.onSurfaceVariant, size: 24),
                      onPressed: () => setState(() {
                        _showEmojiPicker = !_showEmojiPicker;
                        if (_showEmojiPicker) FocusManager.instance.primaryFocus?.unfocus();
                        else _focusNode.requestFocus();
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
                        style: GoogleFonts.outfit(fontSize: 16, color: AppTheme.onSurface),
                        onTap: () { if (_showEmojiPicker) setState(() => _showEmojiPicker = false); },
                        decoration: InputDecoration(
                          hintText: 'Type a message...',
                          hintStyle: GoogleFonts.outfit(color: AppTheme.onSurfaceVariant, fontSize: 16),
                          border: InputBorder.none, enabledBorder: InputBorder.none, focusedBorder: InputBorder.none,
                          contentPadding: const EdgeInsets.symmetric(vertical: 14),
                          isDense: true,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.attach_file_rounded, color: AppTheme.onSurfaceVariant, size: 24),
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
                color: AppTheme.primary,
                shape: BoxShape.circle,
              ),
              child: IconButton(
                icon: _isSendingMedia
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: AppTheme.onPrimary, strokeWidth: 2))
                    : const Icon(Icons.send_rounded, color: AppTheme.onPrimary, size: 22),
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
