import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart' hide Config;
import 'package:intl/intl.dart';
import '../models/message_model.dart';
import '../services/local_db_service.dart';
import '../services/supabase_broadcast_service.dart';
import '../theme/app_theme.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'dart:convert';
import 'dart:async';

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
  String? _receiverAvatarBase64;

  @override
  void initState() {
    super.initState();
    _loadMessages();
    _loadReceiverAvatar();

    // Set active chat user to prevent local notifications while chatting
    SupabaseBroadcastService().activeChatUser = widget.receiverUsername;

    // Subscribe to the shared room for this conversation
    SupabaseBroadcastService().subscribeToRoom(widget.receiverUsername);

    // Delay stream subscription until after first frame so widget is fully mounted
    // and the stream listener is guaranteed to be attached before any messages fire.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _messageSubscription = SupabaseBroadcastService()
          .messageStream
          .listen(_handleNewMessage);
      // Re-load from DB to catch any messages that arrived between
      // the initial load and the subscription being active.
      _loadMessages();
    });
  }

  Future<void> _loadReceiverAvatar() async {
    final contacts = await LocalDbService().getContacts();
    try {
      final contact = contacts.firstWhere(
          (c) => c.username == widget.receiverUsername);
      if (contact.avatarUrl.isNotEmpty && mounted) {
        setState(() {
          _receiverAvatarBase64 = contact.avatarUrl;
        });
      }
    } catch (_) {
      // Contact not found locally or no avatar
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
    // Only handle messages FROM the peer we're chatting with (strict incoming filter)
    if (message.senderUsername.toLowerCase() !=
        widget.receiverUsername.toLowerCase()) {
      return;
    }
    if (!mounted) return;
    setState(() {
      // Guard against duplicates
      final exists = _messages.any((m) => m.id == message.id);
      if (!exists) {
        _messages.add(message);
      }
    });
    _scrollToBottom();
  }

  Future<void> _loadMessages() async {
    final messages = await LocalDbService()
        .getMessages(widget.myUsername, widget.receiverUsername);
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
    final messageId = '${widget.myUsername}_$timestamp';
    
    final newMessage = Message(
      id: messageId,
      senderUsername: widget.myUsername,
      receiverUsername: widget.receiverUsername,
      text: text,
      isMe: true,
      timestamp: timestamp,
    );

    // Optimistically update UI instantly
    setState(() {
      _messages.add(newMessage);
    });
    _scrollToBottom();

    // Fire and forget broadcast
    SupabaseBroadcastService().sendMessage(newMessage);
  }

  /// Groups messages by date and inserts date separator keys
  List<dynamic> _buildMessageListWithDates() {
    if (_messages.isEmpty) return [];

    final List<dynamic> items = [];
    String? lastDateLabel;

    for (final msg in _messages) {
      final date = DateTime.fromMillisecondsSinceEpoch(msg.timestamp);
      final now = DateTime.now();
      final diff = DateTime(now.year, now.month, now.day)
          .difference(DateTime(date.year, date.month, date.day))
          .inDays;

      String dateLabel;
      if (diff == 0) {
        dateLabel = 'Today';
      } else if (diff == 1) {
        dateLabel = 'Yesterday';
      } else {
        dateLabel = DateFormat('MMMM dd, yyyy').format(date);
      }

      if (dateLabel != lastDateLabel) {
        items.add(dateLabel); // String = date separator
        lastDateLabel = dateLabel;
      }
      items.add(msg); // Message = chat bubble
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
            Expanded(
              child: ListView.builder(
                controller: _scrollController,
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                itemCount: items.length,
                itemBuilder: (context, index) {
                  final item = items[index];
                  if (item is String) {
                    return _buildDateSeparator(item);
                  }
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
                      columns: 7,
                      emojiSizeMax: 32,
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
          _buildAvatar(),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.receiverUsername,
                style: GoogleFonts.urbanist(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.textDark,
                ),
              ),
              Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(
                      color: AppTheme.onlineGreen,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    'Online',
                    style: GoogleFonts.urbanist(
                      fontSize: 12,
                      color: AppTheme.onlineGreen,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.videocam_outlined,
              color: AppTheme.primaryPurple, size: 24),
          onPressed: () {},
        ),
        IconButton(
          icon: const Icon(Icons.call_outlined,
              color: AppTheme.primaryPurple, size: 22),
          onPressed: () {},
        ),
        IconButton(
          icon: const Icon(Icons.more_vert_rounded,
              color: AppTheme.textMedium, size: 22),
          onPressed: () {},
        ),
        const SizedBox(width: 4),
      ],
    );
  }

  Widget _buildAvatar() {
    if (_receiverAvatarBase64 != null && _receiverAvatarBase64!.isNotEmpty) {
      try {
        final bytes = base64Decode(_receiverAvatarBase64!);
        return CircleAvatar(
          radius: 20,
          backgroundImage: MemoryImage(bytes),
        );
      } catch (_) {}
    }
    return CircleAvatar(
      radius: 20,
      backgroundColor: AppTheme.lightPurple,
      child: Text(
        widget.receiverUsername.isNotEmpty ? widget.receiverUsername[0].toUpperCase() : '?',
        style: GoogleFonts.urbanist(
          color: AppTheme.primaryPurple,
          fontWeight: FontWeight.w700,
          fontSize: 17,
        ),
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
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 4,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        child: Text(
          label,
          style: GoogleFonts.urbanist(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: AppTheme.textLight,
          ),
        ),
      ),
    );
  }

  Widget _buildMessageBubble(Message message) {
    final isMe = message.isMe;
    final time = DateTime.fromMillisecondsSinceEpoch(message.timestamp);
    final timeString = DateFormat('h:mm a').format(time);

    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.75,
        ),
        decoration: BoxDecoration(
          color: isMe ? AppTheme.chatBubbleSender : AppTheme.chatBubbleReceiver,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(18),
            topRight: const Radius.circular(18),
            bottomLeft: Radius.circular(isMe ? 18 : 4),
            bottomRight: Radius.circular(isMe ? 4 : 18),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 4,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              message.text ?? '',
              style: GoogleFonts.urbanist(
                color: isMe ? Colors.white : AppTheme.textDark,
                fontSize: 15,
                fontWeight: FontWeight.w400,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  timeString,
                  style: GoogleFonts.urbanist(
                    color: isMe
                        ? Colors.white.withValues(alpha: 0.7)
                        : AppTheme.textLight,
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (isMe) ...[
                  const SizedBox(width: 4),
                  Icon(
                    Icons.done_all,
                    size: 14,
                    color: Colors.white.withValues(alpha: 0.7),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInputBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 10, 8, 12),
      decoration: BoxDecoration(
        color: AppTheme.surfaceWhite,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 8,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            // Text field and internal icons (WhatsApp style)
            Expanded(
              child: Container(
                constraints: const BoxConstraints(maxHeight: 120),
                decoration: BoxDecoration(
                  color: AppTheme.lightGrey,
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    IconButton(
                      icon: Icon(
                        _showEmojiPicker ? Icons.keyboard_outlined : Icons.emoji_emotions_outlined,
                        color: AppTheme.textLight, size: 24
                      ),
                      onPressed: () {
                        setState(() {
                          _showEmojiPicker = !_showEmojiPicker;
                          if (_showEmojiPicker) {
                            FocusManager.instance.primaryFocus?.unfocus();
                          } else {
                            _focusNode.requestFocus();
                          }
                        });
                      },
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
                        onTap: () {
                          if (_showEmojiPicker) {
                            setState(() => _showEmojiPicker = false);
                          }
                        },
                        decoration: InputDecoration(
                          hintText: 'Type your message...',
                          hintStyle: GoogleFonts.urbanist(
                              color: AppTheme.textLight, fontSize: 15),
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          contentPadding: const EdgeInsets.symmetric(vertical: 12),
                          isDense: true,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.attach_file_rounded,
                          color: AppTheme.textLight, size: 22),
                      onPressed: () {},
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 36, minHeight: 44),
                    ),
                    IconButton(
                      icon: const Icon(Icons.camera_alt_outlined,
                          color: AppTheme.textLight, size: 22),
                      onPressed: () {},
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 36, minHeight: 44),
                    ),
                    const SizedBox(width: 4),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            // Send button
            Container(
              width: 44,
              height: 44,
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [AppTheme.primaryPurple, AppTheme.accentPurple],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                shape: BoxShape.circle,
              ),
              child: IconButton(
                icon:
                    const Icon(Icons.send_rounded, color: Colors.white, size: 20),
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
