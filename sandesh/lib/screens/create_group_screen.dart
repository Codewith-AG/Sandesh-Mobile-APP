import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/contact_model.dart';
import '../models/group_model.dart';
import '../services/local_db_service.dart';
// app_theme.dart intentionally not imported — all colors from Theme.of(context)

class CreateGroupScreen extends StatefulWidget {
  final String myUsername;

  const CreateGroupScreen({super.key, required this.myUsername});

  @override
  State<CreateGroupScreen> createState() => _CreateGroupScreenState();
}

class _CreateGroupScreenState extends State<CreateGroupScreen>
    with SingleTickerProviderStateMixin {
  final _nameController = TextEditingController();
  final _descController = TextEditingController();
  final _searchController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  List<Contact> _allContacts = [];
  final Set<String> _selectedUsernames = {};
  bool _isLoading = true;
  bool _isCreating = false;
  String _searchQuery = '';

  late AnimationController _animController;
  late Animation<double> _fadeAnimation;
  late Animation<Offset> _slideAnimation;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    _fadeAnimation = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeOut),
    );
    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, 0.08),
      end: Offset.zero,
    ).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeOutCubic),
    );
    _animController.forward();
    _loadContacts();
  }

  @override
  void dispose() {
    _animController.dispose();
    _nameController.dispose();
    _descController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadContacts() async {
    final contacts = await LocalDbService().getContacts();
    if (mounted) {
      setState(() {
        _allContacts = contacts;
        _isLoading = false;
      });
    }
  }

  List<Contact> get _filteredContacts {
    if (_searchQuery.isEmpty) return _allContacts;
    return _allContacts.where((c) {
      final q = _searchQuery.toLowerCase();
      return c.displayName.toLowerCase().contains(q) ||
          c.username.toLowerCase().contains(q);
    }).toList();
  }

  List<Contact> get _selectedContacts {
    return _allContacts
        .where((c) => _selectedUsernames.contains(c.username))
        .toList();
  }

  void _toggleContact(String username) {
    setState(() {
      if (_selectedUsernames.contains(username)) {
        _selectedUsernames.remove(username);
      } else {
        _selectedUsernames.add(username);
      }
    });
  }

  Future<void> _createGroup() async {
    if (!_formKey.currentState!.validate()) return;
    if (_selectedUsernames.isEmpty) {
      final cs = Theme.of(context).colorScheme;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Select at least one member',
            style: GoogleFonts.outfit(fontWeight: FontWeight.w500),
          ),
          backgroundColor: cs.error,
          behavior: SnackBarBehavior.floating,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      );
      return;
    }

    setState(() => _isCreating = true);

    try {
      final supabase = Supabase.instance.client;
      final groupName = _nameController.text.trim();
      final groupDesc = _descController.text.trim();

      // 1. Insert into Supabase `groups` table
      final response = await supabase
          .from('groups')
          .insert({
            'name': groupName,
            'description': groupDesc,
            'avatar_url': '',
            'created_by': widget.myUsername,
          })
          .select()
          .single();

      final groupId = response['id'] as String;

      // 2. Insert all selected members + self into `group_members`
      final memberInserts = <Map<String, dynamic>>[];

      // Self as admin
      memberInserts.add({
        'group_id': groupId,
        'username': widget.myUsername,
        'role': 'admin',
      });

      // Selected contacts as members
      for (final username in _selectedUsernames) {
        memberInserts.add({
          'group_id': groupId,
          'username': username,
          'role': 'member',
        });
      }

      await supabase.from('group_members').insert(memberInserts);

      // 3. Save group locally to SQLite
      final group = Group(
        id: groupId,
        name: groupName,
        description: groupDesc,
        avatarUrl: '',
        createdBy: widget.myUsername,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      );

      await LocalDbService().insertGroup(group);

      // Save members locally
      await LocalDbService().insertGroupMember(
        groupId,
        widget.myUsername,
        role: 'admin',
      );
      for (final username in _selectedUsernames) {
        await LocalDbService().insertGroupMember(groupId, username);
      }

      // 4. Pop back with the created group so HomeScreen can use it
      if (mounted) {
        Navigator.of(context).pop(group);
      }
    } catch (e) {
      if (mounted) {
        final cs = Theme.of(context).colorScheme;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Error creating group: ${e.toString()}',
              style: GoogleFonts.outfit(fontWeight: FontWeight.w500),
            ),
            backgroundColor: cs.error,
            behavior: SnackBarBehavior.floating,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        );
        setState(() => _isCreating = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        leading: IconButton(
          icon: Icon(Icons.arrow_back_rounded, color: cs.onSurface),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          'New Group',
          style: GoogleFonts.outfit(
            fontWeight: FontWeight.w800,
            fontSize: 24,
            color: cs.onSurface,
            letterSpacing: -0.01,
          ),
        ),
        actions: [
          if (_selectedUsernames.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: cs.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  '${_selectedUsernames.length} selected',
                  style: GoogleFonts.outfit(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: cs.primary,
                  ),
                ),
              ),
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: _isLoading
          ? Center(child: CircularProgressIndicator(color: cs.primary))
          : FadeTransition(
              opacity: _fadeAnimation,
              child: SlideTransition(
                position: _slideAnimation,
                child: Column(
                  children: [
                    // ─── Group Info Form ───
                    _buildGroupInfoCard(cs),

                    // ─── Selected Members Chips ───
                    if (_selectedContacts.isNotEmpty) _buildSelectedChips(cs),

                    // ─── Search Bar ───
                    _buildSearchBar(cs),

                    // ─── Contacts List ───
                    Expanded(child: _buildContactsList(cs)),
                  ],
                ),
              ),
            ),
      floatingActionButton: _isLoading
          ? null
          : _buildCreateButton(cs),
    );
  }

  Widget _buildGroupInfoCard(ColorScheme cs) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: cs.surfaceContainerHighest),
        boxShadow: [
          BoxShadow(
            color: cs.primary.withValues(alpha: 0.06),
            blurRadius: 24,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Group icon + name row
            Row(
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: cs.primary.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.group_rounded,
                    color: cs.primary,
                    size: 28,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: TextFormField(
                    controller: _nameController,
                    style: GoogleFonts.outfit(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurface,
                    ),
                    decoration: InputDecoration(
                      hintText: 'Group name',
                      hintStyle: GoogleFonts.outfit(
                        fontSize: 18,
                        fontWeight: FontWeight.w500,
                        color: cs.onSurfaceVariant.withValues(alpha: 0.6),
                      ),
                      filled: true,
                      fillColor: cs.surfaceContainerLow,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(20),
                        borderSide: BorderSide.none,
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(20),
                        borderSide: BorderSide.none,
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(20),
                        borderSide: BorderSide(
                          color: cs.primary,
                          width: 1.5,
                        ),
                      ),
                      errorBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(20),
                        borderSide: BorderSide(
                          color: cs.error,
                          width: 1.5,
                        ),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 14,
                      ),
                    ),
                    validator: (value) {
                      if (value == null || value.trim().isEmpty) {
                        return 'Group name is required';
                      }
                      return null;
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Description field
            TextFormField(
              controller: _descController,
              maxLines: 2,
              style: GoogleFonts.outfit(
                fontSize: 15,
                color: cs.onSurface,
              ),
              decoration: InputDecoration(
                hintText: 'Group description (optional)',
                hintStyle: GoogleFonts.outfit(
                  fontSize: 15,
                  color: cs.onSurfaceVariant.withValues(alpha: 0.6),
                ),
                filled: true,
                fillColor: cs.surfaceContainerLow,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(20),
                  borderSide: BorderSide.none,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(20),
                  borderSide: BorderSide.none,
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(20),
                  borderSide: BorderSide(
                    color: cs.primary,
                    width: 1.5,
                  ),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 14,
                ),
                prefixIcon: Padding(
                  padding: const EdgeInsets.only(left: 12, right: 8),
                  child: Icon(
                    Icons.description_outlined,
                    color: cs.onSurfaceVariant,
                    size: 20,
                  ),
                ),
                prefixIconConstraints: const BoxConstraints(
                  minWidth: 40,
                  minHeight: 40,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSelectedChips(ColorScheme cs) {
    return AnimatedSize(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            children: _selectedContacts.map((contact) {
              return Padding(
                padding: const EdgeInsets.only(right: 8),
                child: _buildContactChip(cs, contact),
              );
            }).toList(),
          ),
        ),
      ),
    );
  }

  Widget _buildContactChip(ColorScheme cs, Contact contact) {
    final label = contact.displayName.isNotEmpty
        ? contact.displayName
        : contact.username;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      child: InputChip(
        label: Text(
          label,
          style: GoogleFonts.outfit(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: cs.onSecondaryContainer,
          ),
        ),
        avatar: _buildSmallAvatar(cs, contact, 14),
        deleteIcon: Icon(
          Icons.close_rounded,
          size: 16,
          color: cs.onSecondaryContainer,
        ),
        onDeleted: () => _toggleContact(contact.username),
        backgroundColor: cs.secondaryContainer.withValues(alpha: 0.5),
        selectedColor: cs.secondaryContainer,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(
            color: cs.secondaryContainer,
            width: 1,
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      ),
    );
  }

  Widget _buildSearchBar(ColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Container(
        decoration: BoxDecoration(
          color: cs.surfaceContainerLow,
          borderRadius: BorderRadius.circular(20),
        ),
        child: TextField(
          controller: _searchController,
          style: GoogleFonts.outfit(fontSize: 15, color: cs.onSurface),
          decoration: InputDecoration(
            hintText: 'Search contacts...',
            hintStyle: GoogleFonts.outfit(
              color: cs.onSurfaceVariant.withValues(alpha: 0.6),
              fontSize: 15,
            ),
            prefixIcon: Icon(
              Icons.search_rounded,
              color: cs.onSurfaceVariant,
              size: 20,
            ),
            suffixIcon: _searchQuery.isNotEmpty
                ? IconButton(
                    icon: Icon(
                      Icons.close_rounded,
                      color: cs.onSurfaceVariant,
                      size: 20,
                    ),
                    onPressed: () {
                      _searchController.clear();
                      setState(() => _searchQuery = '');
                    },
                  )
                : null,
            border: InputBorder.none,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 14,
            ),
          ),
          onChanged: (value) {
            setState(() => _searchQuery = value.trim());
          },
        ),
      ),
    );
  }

  Widget _buildContactsList(ColorScheme cs) {
    final contacts = _filteredContacts;

    if (contacts.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: cs.surfaceContainerHigh,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.person_search_rounded,
                size: 40,
                color: cs.primary,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              _searchQuery.isNotEmpty
                  ? 'No contacts match your search'
                  : 'No contacts yet',
              style: GoogleFonts.outfit(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: cs.onSurface,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _searchQuery.isNotEmpty
                  ? 'Try a different name or number'
                  : 'Add contacts first to create a group',
              style: GoogleFonts.outfit(
                fontSize: 14,
                color: cs.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 100),
      itemCount: contacts.length,
      itemBuilder: (context, index) {
        final contact = contacts[index];
        final isSelected = _selectedUsernames.contains(contact.username);
        return _buildContactTile(cs, contact, isSelected);
      },
    );
  }

  Widget _buildContactTile(
      ColorScheme cs, Contact contact, bool isSelected) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      decoration: BoxDecoration(
        color: isSelected
            ? cs.primary.withValues(alpha: 0.08)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(20),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        splashColor: cs.surfaceContainerHigh,
        onTap: () => _toggleContact(contact.username),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              // Avatar
              _buildContactAvatar(cs, contact),
              const SizedBox(width: 14),

              // Name + Username
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      contact.displayName.isNotEmpty
                          ? contact.displayName
                          : contact.username,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.outfit(
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                        color: cs.onSurface,
                      ),
                    ),
                    if (contact.displayName.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        contact.username,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.outfit(
                          fontSize: 13,
                          color: cs.onSurfaceVariant,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                    ],
                  ],
                ),
              ),

              // Checkbox
              AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeOutCubic,
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: isSelected ? cs.primary : Colors.transparent,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: isSelected
                        ? cs.primary
                        : cs.outline.withValues(alpha: 0.4),
                    width: 2,
                  ),
                ),
                child: isSelected
                    ? Icon(
                        Icons.check_rounded,
                        size: 16,
                        color: cs.onPrimary,
                      )
                    : null,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildContactAvatar(ColorScheme cs, Contact contact) {
    final url = contact.avatarUrl;

    if (url.startsWith('http')) {
      return CircleAvatar(
        radius: 24,
        backgroundColor: cs.surfaceContainerHigh,
        backgroundImage: NetworkImage(url),
        onBackgroundImageError: (_, __) {},
      );
    } else if (url.isNotEmpty) {
      try {
        final bytes = base64Decode(url);
        return CircleAvatar(
          radius: 24,
          backgroundImage: MemoryImage(bytes),
        );
      } catch (_) {
        return _buildFallbackAvatar(cs, contact);
      }
    }
    return _buildFallbackAvatar(cs, contact);
  }

  Widget _buildFallbackAvatar(ColorScheme cs, Contact contact) {
    final label = contact.displayName.isNotEmpty
        ? contact.displayName[0].toUpperCase()
        : (contact.username.isNotEmpty
            ? contact.username[0].toUpperCase()
            : '?');
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: cs.primaryContainer.withValues(alpha: 0.1),
        shape: BoxShape.circle,
      ),
      child: Center(
        child: Text(
          label,
          style: GoogleFonts.outfit(
            color: cs.primary,
            fontWeight: FontWeight.w700,
            fontSize: 20,
          ),
        ),
      ),
    );
  }

  Widget _buildSmallAvatar(ColorScheme cs, Contact contact, double radius) {
    final url = contact.avatarUrl;

    if (url.startsWith('http')) {
      return CircleAvatar(
        radius: radius,
        backgroundColor: cs.surfaceContainerHigh,
        backgroundImage: NetworkImage(url),
        onBackgroundImageError: (_, __) {},
      );
    }

    final label = contact.displayName.isNotEmpty
        ? contact.displayName[0].toUpperCase()
        : (contact.username.isNotEmpty
            ? contact.username[0].toUpperCase()
            : '?');
    return CircleAvatar(
      radius: radius,
      backgroundColor: cs.primaryContainer.withValues(alpha: 0.15),
      child: Text(
        label,
        style: GoogleFonts.outfit(
          color: cs.primary,
          fontWeight: FontWeight.w700,
          fontSize: radius * 0.9,
        ),
      ),
    );
  }

  Widget _buildCreateButton(ColorScheme cs) {
    return AnimatedScale(
      scale: _selectedUsernames.isNotEmpty ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutBack,
      child: FloatingActionButton.extended(
        onPressed: _isCreating ? null : _createGroup,
        elevation: 4,
        backgroundColor: cs.primary,
        icon: _isCreating
            ? SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  color: cs.onPrimary,
                  strokeWidth: 2.5,
                ),
              )
            : Icon(Icons.check_rounded, color: cs.onPrimary),
        label: Text(
          _isCreating ? 'Creating...' : 'Create Group',
          style: GoogleFonts.outfit(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: cs.onPrimary,
          ),
        ),
      ),
    );
  }
}
