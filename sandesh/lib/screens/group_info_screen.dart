import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'dart:io';
import 'package:image_picker/image_picker.dart';
import '../services/local_db_service.dart';
import '../services/media_upload_service.dart';
import '../services/group_events.dart';
import '../models/group_model.dart';
// app_theme.dart intentionally not imported — all colors from Theme.of(context)

class GroupInfoScreen extends StatefulWidget {
  final String groupId;
  final String groupName;
  final String myUsername;

  const GroupInfoScreen({
    super.key,
    required this.groupId,
    required this.groupName,
    required this.myUsername,
  });

  @override
  State<GroupInfoScreen> createState() => _GroupInfoScreenState();
}

class _GroupInfoScreenState extends State<GroupInfoScreen> {
  bool _isLoading = true;
  Group? _group;

  /// Member list: each entry is { 'username': String, 'role': String }
  List<Map<String, String>> _members = [];

  /// Cache: username → display name (from local contacts DB)
  final Map<String, String> _displayNames = {};

  /// Whether the current user is an admin (or creator)
  bool _isAdmin = false;

  /// Whether the current user is the group creator
  bool _isCreator = false;

  @override
  void initState() {
    super.initState();
    _loadGroupInfo();
  }

  // ──────────────────────────── Data Loading ────────────────────────────

  Future<void> _loadGroupInfo() async {
    try {
      final db = LocalDbService();

      // Load group metadata from local DB
      final groups = await db.getGroups();
      Group? group;
      try {
        group = groups.firstWhere((g) => g.id == widget.groupId);
      } catch (_) {
        // Fallback: build a minimal group from the passed-in params
        group = Group(
          id: widget.groupId,
          name: widget.groupName,
          createdBy: '',
          createdAt: 0,
        );
      }

      // Load members with roles from local DB
      final dbObj = await db.database;
      final memberRows = await dbObj.query(
        'group_members',
        where: 'group_id = ?',
        whereArgs: [widget.groupId],
      );

      final members = <Map<String, String>>[];
      for (final row in memberRows) {
        members.add({
          'username': row['username'] as String,
          'role': (row['role'] as String?) ?? 'member',
        });
      }

      // Resolve display names from contacts DB
      for (final member in members) {
        final username = member['username']!;
        final displayName = await db.getContactDisplayName(username);
        if (displayName != null) {
          _displayNames[username] = displayName;
        }
      }

      // Sort: admins first, then alphabetical by display name
      members.sort((a, b) {
        final aAdmin = a['role'] == 'admin' ? 0 : 1;
        final bAdmin = b['role'] == 'admin' ? 0 : 1;
        if (aAdmin != bAdmin) return aAdmin.compareTo(bAdmin);
        final aName = _displayNames[a['username']!] ?? a['username']!;
        final bName = _displayNames[b['username']!] ?? b['username']!;
        return aName.toLowerCase().compareTo(bName.toLowerCase());
      });

      // Check current user's role
      final myRole = await db.getGroupMemberRole(
          widget.groupId, widget.myUsername);
      final isAdmin = myRole == 'admin';
      final isCreator = group.createdBy.toLowerCase() ==
          widget.myUsername.toLowerCase();

      if (mounted) {
        setState(() {
          _group = group;
          _members = members;
          _isAdmin = isAdmin || isCreator;
          _isCreator = isCreator;
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('GroupInfoScreen load error: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // ──────────────────────────── Actions ────────────────────────────

  Future<void> _leaveGroup() async {
    final cs = Theme.of(context).colorScheme;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final dcs = Theme.of(ctx).colorScheme;
        return AlertDialog(
          backgroundColor: dcs.surface,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20)),
          title: Text('Leave Group',
              style: GoogleFonts.inter(
                  fontWeight: FontWeight.w700, color: dcs.onSurface)),
          content: Text(
            'Are you sure you want to leave "${_group?.name ?? widget.groupName}"? You won\'t receive new messages from this group.',
            style: GoogleFonts.inter(color: dcs.onSurfaceVariant),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text('Cancel',
                  style: GoogleFonts.inter(color: dcs.outline)),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style:
                  ElevatedButton.styleFrom(backgroundColor: dcs.error),
              child: Text('Leave',
                  style: GoogleFonts.inter(color: dcs.onError)),
            ),
          ],
        );
      },
    );

    if (confirm != true || !mounted) return;

    try {
      // Remove from Supabase
      await Supabase.instance.client
          .from('group_members')
          .delete()
          .eq('group_id', widget.groupId)
          .eq('username', widget.myUsername.toLowerCase());

      // Remove from local DB
      await LocalDbService()
          .removeGroupMember(widget.groupId, widget.myUsername);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('You left the group',
                style: GoogleFonts.inter(fontWeight: FontWeight.w500)),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12)),
          ),
        );
        // Pop back twice: info screen + chat screen
        Navigator.of(context).pop();
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error leaving group: $e',
                style: GoogleFonts.inter()),
            backgroundColor: cs.error,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  Future<void> _deleteGroup() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final dcs = Theme.of(ctx).colorScheme;
        return AlertDialog(
          backgroundColor: dcs.surface,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20)),
          title: Text('Delete Group',
              style: GoogleFonts.inter(
                  fontWeight: FontWeight.w700, color: dcs.onSurface)),
          content: Text(
            'This will permanently delete the group "${_group?.name ?? widget.groupName}" for all members. This action cannot be undone.',
            style: GoogleFonts.inter(color: dcs.onSurfaceVariant),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text('Cancel',
                  style: GoogleFonts.inter(color: dcs.outline)),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style:
                  ElevatedButton.styleFrom(backgroundColor: dcs.error),
              child: Text('Delete',
                  style: GoogleFonts.inter(color: dcs.onError)),
            ),
          ],
        );
      },
    );

    if (confirm != true || !mounted) return;

    try {
      // Delete from Supabase (cascade: members removed via RLS/triggers)
      await Supabase.instance.client
          .from('groups')
          .delete()
          .eq('id', widget.groupId);

      // Delete from local DB (removes group + members + messages)
      await LocalDbService().deleteGroup(widget.groupId);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Group deleted',
                style: GoogleFonts.inter(fontWeight: FontWeight.w500)),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12)),
          ),
        );
        Navigator.of(context).pop();
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        final cs = Theme.of(context).colorScheme;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error deleting group: $e',
                style: GoogleFonts.inter()),
            backgroundColor: cs.error,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  Future<void> _removeMember(String username) async {
    final displayName = _displayNames[username] ?? username;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final dcs = Theme.of(ctx).colorScheme;
        return AlertDialog(
          backgroundColor: dcs.surface,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20)),
          title: Text('Remove Member',
              style: GoogleFonts.inter(
                  fontWeight: FontWeight.w700, color: dcs.onSurface)),
          content: Text(
            'Remove $displayName from the group?',
            style: GoogleFonts.inter(color: dcs.onSurfaceVariant),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text('Cancel',
                  style: GoogleFonts.inter(color: dcs.outline)),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style:
                  ElevatedButton.styleFrom(backgroundColor: dcs.error),
              child: Text('Remove',
                  style: GoogleFonts.inter(color: dcs.onError)),
            ),
          ],
        );
      },
    );

    if (confirm != true || !mounted) return;

    try {
      await Supabase.instance.client
          .from('group_members')
          .delete()
          .eq('group_id', widget.groupId)
          .eq('username', username.toLowerCase());

      await LocalDbService()
          .removeGroupMember(widget.groupId, username);

      // Post a system notice into the group chat.
      final actorName =
          _displayNames[widget.myUsername.toLowerCase()] ?? widget.myUsername;
      await sendGroupSystemMessage(
        groupId: widget.groupId,
        actingUsername: widget.myUsername,
        text: '$actorName removed $displayName',
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('$displayName removed',
                style: GoogleFonts.inter(fontWeight: FontWeight.w500)),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12)),
          ),
        );
      }
      await _loadGroupInfo();
    } catch (e) {
      if (mounted) {
        final cs = Theme.of(context).colorScheme;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e', style: GoogleFonts.inter()),
            backgroundColor: cs.error,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  Future<void> _makeAdmin(String username) async {
    final displayName = _displayNames[username] ?? username;
    try {
      await Supabase.instance.client
          .from('group_members')
          .update({'role': 'admin'})
          .eq('group_id', widget.groupId)
          .eq('username', username.toLowerCase());
      await LocalDbService()
          .insertGroupMember(widget.groupId, username, role: 'admin');

      final actorName =
          _displayNames[widget.myUsername.toLowerCase()] ?? widget.myUsername;
      await sendGroupSystemMessage(
        groupId: widget.groupId,
        actingUsername: widget.myUsername,
        text: '$actorName made $displayName an admin',
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('$displayName is now an admin',
                style: GoogleFonts.inter(fontWeight: FontWeight.w500)),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12)),
          ),
        );
      }
      await _loadGroupInfo();
    } catch (e) {
      if (mounted) {
        final cs = Theme.of(context).colorScheme;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e', style: GoogleFonts.inter()),
            backgroundColor: cs.error,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  /// Lets an admin pick an image and set it as the group's display picture.
  Future<void> _changeGroupPhoto() async {
    try {
      final picked = await ImagePicker()
          .pickImage(source: ImageSource.gallery, imageQuality: 85);
      if (picked == null) return;

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Uploading group photo…',
                style: GoogleFonts.inter(fontWeight: FontWeight.w500)),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }

      // Reuse the public `avatars` bucket, scoped under a group-specific key.
      final url = await MediaUploadService()
          .uploadAvatar(File(picked.path), 'group_${widget.groupId}');

      await Supabase.instance.client
          .from('groups')
          .update({'avatar_url': url}).eq('id', widget.groupId);

      // Update local copy so it reflects immediately.
      final g = _group;
      if (g != null) {
        await LocalDbService().insertGroup(g.copyWith(avatarUrl: url));
      }

      final actorName =
          _displayNames[widget.myUsername.toLowerCase()] ?? widget.myUsername;
      await sendGroupSystemMessage(
        groupId: widget.groupId,
        actingUsername: widget.myUsername,
        text: '$actorName changed the group photo',
      );

      await _loadGroupInfo();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Group photo updated',
                style: GoogleFonts.inter(fontWeight: FontWeight.w500)),
            backgroundColor: AppTheme.primary,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        final cs = Theme.of(context).colorScheme;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content:
                Text('Error updating photo: $e', style: GoogleFonts.inter()),
            backgroundColor: cs.error,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  Future<void> _showAddMemberDialog() async {
    final cs = Theme.of(context).colorScheme;

    // Get all contacts
    final contacts = await LocalDbService().getContacts();

    // Get current member usernames (lowercase) for filtering
    final currentMembers =
        _members.map((m) => m['username']!.toLowerCase()).toSet();

    // Filter out contacts already in the group
    final available = contacts
        .where((c) => !currentMembers.contains(c.username.toLowerCase()))
        .toList();

    if (!mounted) return;

    if (available.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('All your contacts are already in this group',
              style: GoogleFonts.inter(fontWeight: FontWeight.w500)),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12)),
        ),
      );
      return;
    }

    // Track selected contacts
    final selected = <String>{};

    await showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            final dcs = Theme.of(ctx).colorScheme;
            return AlertDialog(
              backgroundColor: dcs.surface,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20)),
              title: Text('Add Members',
                  style: GoogleFonts.inter(
                      fontWeight: FontWeight.w700,
                      color: dcs.onSurface)),
              content: SizedBox(
                width: double.maxFinite,
                height: 400,
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: available.length,
                  itemBuilder: (_, i) {
                    final contact = available[i];
                    final name = contact.displayName.isNotEmpty
                        ? contact.displayName
                        : contact.username;
                    final isSelected =
                        selected.contains(contact.username);
                    return ListTile(
                      leading: CircleAvatar(
                        backgroundColor: dcs.surfaceContainerHigh,
                        backgroundImage:
                            contact.avatarUrl.isNotEmpty &&
                                    contact.avatarUrl
                                        .startsWith('http')
                                ? NetworkImage(contact.avatarUrl)
                                : null,
                        child: contact.avatarUrl.isEmpty ||
                                !contact.avatarUrl
                                    .startsWith('http')
                            ? Text(
                                name[0].toUpperCase(),
                                style: GoogleFonts.inter(
                                  fontWeight: FontWeight.w600,
                                  color: dcs.primary,
                                ),
                              )
                            : null,
                      ),
                      title: Text(name,
                          style: GoogleFonts.inter(
                              fontWeight: FontWeight.w500,
                              color: dcs.onSurface)),
                      subtitle: contact.displayName.isNotEmpty
                          ? Text('@${contact.username}',
                              style: GoogleFonts.inter(
                                  fontSize: 12,
                                  color: dcs.onSurfaceVariant))
                          : null,
                      trailing: Checkbox(
                        value: isSelected,
                        activeColor: dcs.primary,
                        shape: RoundedRectangleBorder(
                            borderRadius:
                                BorderRadius.circular(4)),
                        onChanged: (val) {
                          setDialogState(() {
                            if (val == true) {
                              selected.add(contact.username);
                            } else {
                              selected.remove(contact.username);
                            }
                          });
                        },
                      ),
                      onTap: () {
                        setDialogState(() {
                          if (isSelected) {
                            selected.remove(contact.username);
                          } else {
                            selected.add(contact.username);
                          }
                        });
                      },
                    );
                  },
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text('Cancel',
                      style: GoogleFonts.inter(color: dcs.outline)),
                ),
                ElevatedButton(
                  onPressed: selected.isEmpty
                      ? null
                      : () => Navigator.pop(ctx),
                  style: ElevatedButton.styleFrom(
                      backgroundColor: dcs.primary),
                  child: Text(
                      'Add${selected.isNotEmpty ? ' (${selected.length})' : ''}',
                      style: GoogleFonts.inter(color: dcs.onPrimary)),
                ),
              ],
            );
          },
        );
      },
    );

    // Add selected members
    if (selected.isNotEmpty && mounted) {
      try {
        for (final username in selected) {
          await Supabase.instance.client
              .from('group_members')
              .insert({
            'group_id': widget.groupId,
            'username': username.toLowerCase(),
            'role': 'member',
          });
          await LocalDbService()
              .insertGroupMember(widget.groupId, username);
        }

        // Post a system notice for each added member.
        final actorName =
            _displayNames[widget.myUsername.toLowerCase()] ?? widget.myUsername;
        for (final username in selected) {
          final addedName = _displayNames[username] ?? username;
          await sendGroupSystemMessage(
            groupId: widget.groupId,
            actingUsername: widget.myUsername,
            text: '$actorName added $addedName',
          );
        }

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                  '${selected.length} member${selected.length > 1 ? 's' : ''} added',
                  style:
                      GoogleFonts.inter(fontWeight: FontWeight.w500)),
              backgroundColor: AppTheme.primary,
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
          );
        }
        await _loadGroupInfo();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error adding members: $e',
                  style: GoogleFonts.inter()),
              backgroundColor: cs.error,
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      }
    }
  }

  // ──────────────────────────── UI Helpers ────────────────────────────

  Widget _buildGroupAvatar(ColorScheme cs) {
    final group = _group;
    if (group != null &&
        group.avatarUrl.isNotEmpty &&
        group.avatarUrl.startsWith('http')) {
      return CircleAvatar(
        radius: 56,
        backgroundImage: NetworkImage(group.avatarUrl),
        onBackgroundImageError: (_, __) {},
      );
    }
    return CircleAvatar(
      radius: 56,
      backgroundColor: cs.surfaceContainerHigh,
      child: Text(
        (group?.name ?? widget.groupName).isNotEmpty
            ? (group?.name ?? widget.groupName)[0].toUpperCase()
            : '?',
        style: GoogleFonts.inter(
          fontSize: 40,
          fontWeight: FontWeight.w600,
          color: cs.primary,
        ),
      ),
    );
  }

  Widget _buildMemberTile(
      Map<String, String> member, ColorScheme cs) {
    final username = member['username']!;
    final role = member['role'] ?? 'member';
    final displayName = _displayNames[username] ?? username;
    final isMe =
        username.toLowerCase() == widget.myUsername.toLowerCase();
    final isAdmin = role == 'admin';

    return ListTile(
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 24, vertical: 2),
      leading: CircleAvatar(
        radius: 22,
        backgroundColor: cs.surfaceContainerHigh,
        child: Text(
          displayName[0].toUpperCase(),
          style: GoogleFonts.inter(
            fontWeight: FontWeight.w600,
            color: cs.primary,
            fontSize: 16,
          ),
        ),
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              isMe ? '$displayName (You)' : displayName,
              style: GoogleFonts.inter(
                fontWeight: FontWeight.w500,
                fontSize: 15,
                color: cs.onSurface,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (isAdmin) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: cs.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                'Admin',
                style: GoogleFonts.inter(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: cs.primary,
                  letterSpacing: 0.3,
                ),
              ),
            ),
          ],
        ],
      ),
      subtitle: displayName != username
          ? Text(
              '@$username',
              style: GoogleFonts.inter(
                fontSize: 12,
                color: cs.onSurfaceVariant,
              ),
            )
          : null,
      trailing: (_isAdmin && !isMe)
          ? PopupMenuButton<String>(
              icon: Icon(Icons.more_vert_rounded, color: cs.onSurfaceVariant),
              onSelected: (value) {
                if (value == 'make_admin') {
                  _makeAdmin(username);
                } else if (value == 'remove') {
                  _removeMember(username);
                }
              },
              itemBuilder: (context) => [
                if (!isAdmin)
                  PopupMenuItem(
                      value: 'make_admin',
                      child: Text('Make admin', style: GoogleFonts.inter())),
                PopupMenuItem(
                    value: 'remove',
                    child: Text('Remove', style: GoogleFonts.inter())),
              ],
            )
          : null,
      onLongPress: (_isAdmin && !isMe)
          ? () => _removeMember(username)
          : null,
    );
  }

  Widget _buildSectionHeader(String title, ColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.only(left: 28, top: 24, bottom: 8),
      child: Text(
        title,
        style: GoogleFonts.inter(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: cs.onSurfaceVariant,
          letterSpacing: 0.4,
        ),
      ),
    );
  }

  // ──────────────────────────── Build ────────────────────────────

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        backgroundColor: cs.surface,
        elevation: 0,
        title: Text(
          'Group Info',
          style: GoogleFonts.inter(
              fontWeight: FontWeight.w700, color: cs.onSurface),
        ),
        iconTheme: IconThemeData(color: cs.onSurface),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── Group header (avatar + name + description) ──
                  const SizedBox(height: 12),
                  Center(
                    child: GestureDetector(
                      onTap: _isAdmin ? _changeGroupPhoto : null,
                      child: Stack(
                        children: [
                          _buildGroupAvatar(cs),
                          if (_isAdmin)
                            Positioned(
                              right: 0,
                              bottom: 0,
                              child: Container(
                                padding: const EdgeInsets.all(6),
                                decoration: BoxDecoration(
                                  color: cs.primary,
                                  shape: BoxShape.circle,
                                  border:
                                      Border.all(color: cs.surface, width: 2),
                                ),
                                child: Icon(Icons.camera_alt_rounded,
                                    size: 16, color: cs.onPrimary),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Center(
                    child: Text(
                      _group?.name ?? widget.groupName,
                      style: GoogleFonts.inter(
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                        color: cs.onSurface,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Center(
                    child: Text(
                      '${_members.length} member${_members.length != 1 ? 's' : ''}',
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                  if (_group?.description.isNotEmpty == true) ...[
                    const SizedBox(height: 16),
                    Padding(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 24),
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: cs.surfaceContainer,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Column(
                          crossAxisAlignment:
                              CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Description',
                              style: GoogleFonts.inter(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: cs.onSurfaceVariant,
                                letterSpacing: 0.4,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              _group!.description,
                              style: GoogleFonts.inter(
                                fontSize: 14,
                                color: cs.onSurface,
                                height: 1.4,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],

                  const SizedBox(height: 8),
                  const Divider(height: 1),

                  // ── Members section ──
                  _buildSectionHeader(
                      'MEMBERS · ${_members.length}', cs),

                  // Add Member button (admin only)
                  if (_isAdmin)
                    ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 24, vertical: 2),
                      leading: CircleAvatar(
                        radius: 22,
                        backgroundColor:
                            cs.primary.withValues(alpha: 0.12),
                        child: Icon(Icons.person_add_rounded,
                            color: cs.primary, size: 20),
                      ),
                      title: Text(
                        'Add Member',
                        style: GoogleFonts.inter(
                          fontWeight: FontWeight.w600,
                          fontSize: 15,
                          color: cs.primary,
                        ),
                      ),
                      onTap: _showAddMemberDialog,
                    ),

                  // Member list
                  ...List.generate(
                    _members.length,
                    (i) => _buildMemberTile(_members[i], cs),
                  ),

                  const SizedBox(height: 8),
                  const Divider(height: 1),

                  // ── Danger zone ──
                  const SizedBox(height: 16),
                  Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 24),
                    child: SizedBox(
                      width: double.infinity,
                      height: 54,
                      child: OutlinedButton.icon(
                        onPressed: _leaveGroup,
                        icon: Icon(Icons.exit_to_app_rounded,
                            color: cs.error),
                        label: Text(
                          'Leave Group',
                          style: GoogleFonts.inter(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: cs.error,
                          ),
                        ),
                        style: OutlinedButton.styleFrom(
                          side: BorderSide(
                              color: cs.error.withValues(alpha: 0.5)),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(999),
                          ),
                        ),
                      ),
                    ),
                  ),

                  // Delete Group (creator only)
                  if (_isCreator) ...[
                    const SizedBox(height: 12),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 24),
                      child: SizedBox(
                        width: double.infinity,
                        height: 54,
                        child: ElevatedButton.icon(
                          onPressed: _deleteGroup,
                          icon: Icon(Icons.delete_forever_rounded,
                              color: cs.onError),
                          label: Text(
                            'Delete Group',
                            style: GoogleFonts.inter(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: cs.onError,
                            ),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: cs.error,
                            shape: RoundedRectangleBorder(
                              borderRadius:
                                  BorderRadius.circular(999),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],

                  const SizedBox(height: 48),
                ],
              ),
            ),
    );
  }
}
