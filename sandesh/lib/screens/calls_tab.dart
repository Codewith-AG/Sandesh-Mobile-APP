import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import '../widgets/user_avatar.dart';
import 'chat_screen.dart'; 

class CallsTab extends StatefulWidget {
  final String myUsername;
  const CallsTab({super.key, required this.myUsername});

  @override
  State<CallsTab> createState() => _CallsTabState();
}

class _CallsTabState extends State<CallsTab> {
  bool _isLoading = true;
  List<Map<String, dynamic>> _calls = [];

  @override
  void initState() {
    super.initState();
    _fetchCalls();
  }

  Future<void> _fetchCalls() async {
    try {
      final supabase = Supabase.instance.client;
      final response = await supabase
          .from('calls')
          .select()
          .or('caller_username.eq.${widget.myUsername},receiver_username.eq.${widget.myUsername}')
          .order('started_at', ascending: false);
      
      if (mounted) {
        setState(() {
          _calls = List<Map<String, dynamic>>.from(response);
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('Error fetching calls: $e');
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  String _formatDate(DateTime date) {
    final now = DateTime.now();
    final difference = now.difference(date);
    if (difference.inDays == 0 && now.day == date.day) {
      return DateFormat('hh:mm a').format(date);
    } else if (difference.inDays == 1 || (difference.inDays == 0 && now.day != date.day)) {
      return 'Yesterday';
    } else if (difference.inDays < 7) {
      return DateFormat('EEE').format(date);
    } else {
      return DateFormat('dd/MM/yy').format(date);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    if (_isLoading) {
      return Center(child: CircularProgressIndicator(color: cs.primary));
    }

    if (_calls.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.phone_missed_rounded, size: 64, color: cs.onSurfaceVariant.withValues(alpha: 0.3)),
            const SizedBox(height: 16),
            Text(
              'No call history',
              style: GoogleFonts.outfit(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: cs.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _fetchCalls,
      color: cs.primary,
      backgroundColor: cs.surfaceContainerLowest,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 16),
        itemCount: _calls.length,
        separatorBuilder: (_, __) => const SizedBox(height: 12),
        itemBuilder: (context, index) {
          final call = _calls[index];
          final isOutgoing = call['caller_username'] == widget.myUsername;
          final peerUsername = isOutgoing ? call['receiver_username'] : call['caller_username'];
          final status = call['status'] as String;
          final callType = call['call_type'] as String;
          final startedAt = DateTime.tryParse(call['started_at'] ?? '')?.toLocal() ?? DateTime.now();

          Color iconColor;
          IconData statusIcon;

          if (isOutgoing) {
            iconColor = status == 'answered' ? cs.primary : cs.onSurfaceVariant;
            statusIcon = Icons.call_made_rounded;
          } else {
            iconColor = status == 'missed' || status == 'declined' ? cs.error : cs.primary;
            statusIcon = Icons.call_received_rounded;
          }

          final typeIcon = callType == 'video' ? Icons.videocam_rounded : Icons.call_rounded;

          return ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 20),
            leading: UserAvatar(
              imageUrl: null, 
              name: peerUsername,
              radius: 26,
            ),
            title: Text(
              peerUsername,
              style: GoogleFonts.outfit(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: status == 'missed' && !isOutgoing ? cs.error : cs.onSurface,
              ),
            ),
            subtitle: Row(
              children: [
                Icon(statusIcon, size: 14, color: iconColor),
                const SizedBox(width: 4),
                Text(
                  _formatDate(startedAt),
                  style: GoogleFonts.outfit(
                    fontSize: 13,
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            trailing: IconButton(
              icon: Icon(typeIcon, color: cs.primary),
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ChatScreen(
                      myUsername: widget.myUsername,
                      receiverUsername: peerUsername,
                    ),
                  ),
                );
              },
            ),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ChatScreen(
                    myUsername: widget.myUsername,
                    receiverUsername: peerUsername,
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
