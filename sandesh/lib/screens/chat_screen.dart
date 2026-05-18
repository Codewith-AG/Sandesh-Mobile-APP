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

  @override
  void dispose() {
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
      setState(() { _isSendingMedia = true; _uploadProgress = 0; });
      final url = await MediaUploadService().uploadChatImage(File(picked.path));
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final msg = Message(
        id: '${widget.myUsername}_$timestamp',
        senderUsername: widget.myUsername,
        receiverUsername: widget.receiverUsername,
        mediaUrl: url,
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

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: GoogleFonts.inter()),
      backgroundColor: AppTheme.errorRed,
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

  @override
  Widget build(BuildContext context) {
    final items = _buildMessageListWithDates();
    return Scaffold(
      backgroundColor: AppTheme.chatBackground,
      appBar: _buildAppBar(),
      body: SafeArea(
        child: Column(
          children: [
            if (_isSendingMedia)
              LinearProgressIndicator(
                value: _uploadProgress > 0 ? _uploadProgress : null,
                backgroundColor: const Color(0xFFE8E8EC),
                color: AppTheme.primaryPurple,
                minHeight: 3,
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
                      backgroundColor: AppTheme.chatBackground,
                      columns: 7, emojiSizeMax: 32,
                    ),
                    categoryViewConfig: const CategoryViewConfig(
                      backgroundColor: AppTheme.chatBackground,
                      indicatorColor: AppTheme.primaryPurple,
                      iconColorSelected: AppTheme.primaryPurple,
                    ),
                    bottomActionBarConfig: const BottomActionBarConfig(
                      backgroundColor: AppTheme.chatBackground,
                      buttonColor: AppTheme.chatBackground,
                      buttonIconColor: AppTheme.primaryPurple,
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
      backgroundColor: AppTheme.surfaceWhite,
      titleSpacing: 0,
      leading: IconButton(
        icon: const Icon(Icons.arrow_back_ios_new, size: 20),
        onPressed: () => Navigator.pop(context),
      ),
      title: Row(
        children: [
          _buildReceiverAvatar(),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.receiverUsername,
                  style: GoogleFonts.urbanist(fontSize: 16, fontWeight: FontWeight.w700, color: AppTheme.textDark)),
              Row(children: [
                Container(width: 8, height: 8,
                    decoration: const BoxDecoration(color: AppTheme.onlineGreen, shape: BoxShape.circle)),
                const SizedBox(width: 4),
                Text('Online', style: GoogleFonts.urbanist(fontSize: 12, color: AppTheme.onlineGreen, fontWeight: FontWeight.w500)),
              ]),
            ],
          ),
        ],
      ),
      actions: [
        IconButton(icon: const Icon(Icons.videocam_outlined, color: AppTheme.primaryPurple, size: 24), onPressed: () {}),
        IconButton(icon: const Icon(Icons.call_outlined, color: AppTheme.primaryPurple, size: 22), onPressed: () {}),
        IconButton(icon: const Icon(Icons.more_vert_rounded, color: AppTheme.textMedium, size: 22), onPressed: () {}),
        const SizedBox(width: 4),
      ],
    );
  }

  Widget _buildReceiverAvatar() {
    if (_receiverAvatarUrl.startsWith('http')) {
      return CircleAvatar(
        radius: 20,
        backgroundColor: AppTheme.lightPurple,
        backgroundImage: NetworkImage(_receiverAvatarUrl),
        onBackgroundImageError: (_, __) {},
      );
    }
    return CircleAvatar(
      radius: 20,
      backgroundColor: AppTheme.lightPurple,
      child: Text(
        widget.receiverUsername.isNotEmpty ? widget.receiverUsername[0].toUpperCase() : '?',
        style: GoogleFonts.urbanist(color: AppTheme.primaryPurple, fontWeight: FontWeight.w700, fontSize: 17),
      ),
    );
  }

  Widget _buildDateSeparator(String label) {
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 16),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: AppTheme.surfaceWhite,
          borderRadius: BorderRadius.circular(12),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 4, offset: const Offset(0, 1))],
        ),
        child: Text(label, style: GoogleFonts.urbanist(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.textLight)),
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
      case MessageType.text:
      default:
        content = _buildTextContent(message, isMe, timeString);
    }

    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
        child: content,
      ),
    );
  }

  Widget _buildTextContent(Message message, bool isMe, String timeString) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
      decoration: BoxDecoration(
        color: isMe ? AppTheme.chatBubbleSender : AppTheme.chatBubbleReceiver,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(18), topRight: const Radius.circular(18),
          bottomLeft: Radius.circular(isMe ? 18 : 4), bottomRight: Radius.circular(isMe ? 4 : 18),
        ),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 4, offset: const Offset(0, 2))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(message.text ?? '', style: GoogleFonts.urbanist(
              color: isMe ? Colors.white : AppTheme.textDark, fontSize: 15, height: 1.4)),
          const SizedBox(height: 4),
          _buildTimestamp(timeString, isMe),
        ],
      ),
    );
  }

  Widget _buildImageContent(Message message, bool isMe, String timeString) {
    return ClipRRect(
      borderRadius: BorderRadius.only(
        topLeft: const Radius.circular(18), topRight: const Radius.circular(18),
        bottomLeft: Radius.circular(isMe ? 18 : 4), bottomRight: Radius.circular(isMe ? 4 : 18),
      ),
      child: Stack(
        children: [
          message.mediaUrl != null
              ? Image.network(message.mediaUrl!,
                  width: 220, height: 220, fit: BoxFit.cover,
                  loadingBuilder: (_, child, progress) => progress == null
                      ? child
                      : Container(width: 220, height: 220,
                          color: const Color(0xFFE8E8EC),
                          child: const Center(child: CircularProgressIndicator(strokeWidth: 2))),
                  errorBuilder: (_, __, ___) => Container(width: 220, height: 100,
                      color: const Color(0xFFE8E8EC),
                      child: const Icon(Icons.broken_image_outlined)))
              : Container(width: 220, height: 220, color: const Color(0xFFE8E8EC)),
          Positioned(bottom: 6, right: 8, child: _buildTimestampOverlay(timeString, isMe)),
        ],
      ),
    );
  }

  Widget _buildVideoContent(Message message, bool isMe, String timeString) {
    return Container(
      width: 220,
      decoration: BoxDecoration(
        color: isMe ? AppTheme.chatBubbleSender : AppTheme.chatBubbleReceiver,
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
            Container(
              height: 100,
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Center(
                child: Icon(Icons.play_circle_filled_rounded, size: 48, color: Colors.white),
              ),
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.videocam_outlined, size: 14, color: isMe ? Colors.white70 : AppTheme.textLight),
                const SizedBox(width: 4),
                Text('Video', style: GoogleFonts.urbanist(
                    fontSize: 13, color: isMe ? Colors.white : AppTheme.textDark)),
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
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
      decoration: BoxDecoration(
        color: isMe ? AppTheme.chatBubbleSender : AppTheme.chatBubbleReceiver,
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
                  color: (isMe ? Colors.white : AppTheme.primaryPurple).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(Icons.insert_drive_file_outlined,
                    color: isMe ? Colors.white : AppTheme.primaryPurple, size: 24),
              ),
              const SizedBox(width: 10),
              Flexible(
                child: Text(message.fileName ?? 'Document',
                    maxLines: 2, overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.urbanist(
                        fontSize: 13, fontWeight: FontWeight.w600,
                        color: isMe ? Colors.white : AppTheme.textDark)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          _buildTimestamp(timeString, isMe),
        ],
      ),
    );
  }

  Widget _buildTimestamp(String timeString, bool isMe) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(timeString, style: GoogleFonts.urbanist(
            color: isMe ? Colors.white.withValues(alpha: 0.7) : AppTheme.textLight,
            fontSize: 11, fontWeight: FontWeight.w500)),
        if (isMe) ...[
          const SizedBox(width: 4),
          Icon(Icons.done_all, size: 14, color: Colors.white.withValues(alpha: 0.7)),
        ],
      ],
    );
  }

  Widget _buildTimestampOverlay(String timeString, bool isMe) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(timeString, style: GoogleFonts.urbanist(color: Colors.white, fontSize: 10)),
          if (isMe) ...[
            const SizedBox(width: 3),
            const Icon(Icons.done_all, size: 12, color: Colors.white),
          ],
        ],
      ),
    );
  }

  Widget _buildInputBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 10, 8, 12),
      decoration: BoxDecoration(
        color: AppTheme.surfaceWhite,
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 8, offset: const Offset(0, -2))],
      ),
      child: SafeArea(
        top: false,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Container(
                constraints: const BoxConstraints(maxHeight: 120),
                decoration: BoxDecoration(color: AppTheme.lightGrey, borderRadius: BorderRadius.circular(24)),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    IconButton(
                      icon: Icon(_showEmojiPicker ? Icons.keyboard_outlined : Icons.emoji_emotions_outlined,
                          color: AppTheme.textLight, size: 24),
                      onPressed: () => setState(() {
                        _showEmojiPicker = !_showEmojiPicker;
                        if (_showEmojiPicker) FocusManager.instance.primaryFocus?.unfocus();
                        else _focusNode.requestFocus();
                      }),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                    ),
                    Expanded(
                      child: TextField(
                        controller: _textController,
                        focusNode: _focusNode,
                        maxLines: null,
                        textInputAction: TextInputAction.newline,
                        style: GoogleFonts.urbanist(fontSize: 15),
                        onTap: () { if (_showEmojiPicker) setState(() => _showEmojiPicker = false); },
                        decoration: InputDecoration(
                          hintText: 'Type your message...',
                          hintStyle: GoogleFonts.urbanist(color: AppTheme.textLight, fontSize: 15),
                          border: InputBorder.none, enabledBorder: InputBorder.none, focusedBorder: InputBorder.none,
                          contentPadding: const EdgeInsets.symmetric(vertical: 12),
                          isDense: true,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.attach_file_rounded, color: AppTheme.textLight, size: 22),
                      onPressed: _isSendingMedia ? null : _showAttachmentSheet,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 36, minHeight: 44),
                    ),
                    const SizedBox(width: 4),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            Container(
              width: 44, height: 44,
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                    colors: [AppTheme.primaryPurple, AppTheme.accentPurple],
                    begin: Alignment.topLeft, end: Alignment.bottomRight),
                shape: BoxShape.circle,
              ),
              child: IconButton(
                icon: _isSendingMedia
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                    : const Icon(Icons.send_rounded, color: Colors.white, size: 20),
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
