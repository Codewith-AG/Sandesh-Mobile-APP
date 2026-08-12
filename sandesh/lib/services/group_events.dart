import 'package:supabase_flutter/supabase_flutter.dart';
import 'local_db_service.dart';

/// Posts a "system" notice message into a group conversation, e.g.
/// "Alice added Bob", "Alice removed Bob", "Alice created the group",
/// "Alice made Bob an admin" or "Alice changed the group photo".
///
/// The message is written both to Supabase (so every member sees it via the
/// realtime `group_messages` subscription) and to the local DB (so it shows
/// immediately for the person who performed the action).
///
/// RLS on `group_messages` requires `sender_username = username_of(auth.uid())`
/// and group membership, so [actingUsername] must be the current user.
Future<void> sendGroupSystemMessage({
  required String groupId,
  required String actingUsername,
  required String text,
}) async {
  final me = actingUsername.toLowerCase();
  final ts = DateTime.now().millisecondsSinceEpoch;
  final id = '${me}_sys_$ts';

  final row = {
    'id': id,
    'group_id': groupId,
    'sender_username': me,
    'text': text,
    'message_type': 'system',
    'timestamp': ts,
  };

  try {
    await Supabase.instance.client.from('group_messages').insert(row);
  } catch (_) {
    // Non-fatal: the action itself already succeeded.
  }

  try {
    await LocalDbService().insertGroupMessage(Map<String, dynamic>.from(row));
  } catch (_) {}
}
