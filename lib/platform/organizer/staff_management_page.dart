import 'package:flutter/material.dart';
import 'package:protournament_user/platform/core/organization.dart';
import 'package:protournament_user/platform/organizer/organizer_service.dart';
import 'package:protournament_user/utils.dart';

/// Staff & referee management (ChatGPT blueprint §7; backend guide
/// §4 `organization_members` + §7 `invite_org_member`).
///
/// Lists the organization's members with roles, invites new staff /
/// referees (UID + role picker → PENDING invite row), and removes
/// staff. Invites are local-store rows until the `invite_org_member`
/// RPC lands — the invitee accepts in-app later (accept flow is a
/// later workstream; until then the row stays `pending` and is shown
/// as such). The owner row can never be removed.
class StaffManagementPage extends StatefulWidget {
  const StaffManagementPage({super.key, required this.organizationId});
  final String organizationId;

  @override
  State<StaffManagementPage> createState() => _StaffManagementPageState();
}

class _StaffManagementPageState extends State<StaffManagementPage> {
  final _service = const OrganizerService();

  bool _loading = true;
  bool _inviting = false;
  Organization? _org;
  List<OrganizationMember> _members = [];
  final _uidCtrl = TextEditingController();
  OrganizationMemberRole _inviteRole = OrganizationMemberRole.staff;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _uidCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final org = await _service.getOrganization(widget.organizationId);
    final members = await _service.listStaff(widget.organizationId);
    if (!mounted) return;
    setState(() {
      _org = org;
      _members = members;
      _loading = false;
    });
  }

  Future<void> _invite() async {
    final uid = _uidCtrl.text.trim();
    if (uid.isEmpty) {
      toast(context, tr('Enter the user ID to invite.', 'Invite karne ke liye user ID likhen.'));
      return;
    }
    setState(() => _inviting = true);
    final ok =
        await _service.inviteStaff(widget.organizationId, uid, _inviteRole);
    if (!mounted) return;
    setState(() => _inviting = false);
    toast(
        context,
        ok
            ? tr('Invite sent — pending until the user accepts.',
                'Invite bhej di gayi — user ke accept karne tak pending rahegi.')
            : tr('Invite could not be saved.', 'Invite save nahi ho saki.'));
    if (ok) {
      _uidCtrl.clear();
      _load();
    }
  }

  Future<void> _remove(OrganizationMember member) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kCardPurpleMid,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22), side: const BorderSide(color: kCardPurpleBorder, width: 1.5)),
        title: Text(tr('Remove staff?', 'Staff hatayen?'),
            style: TextStyle(color: kText)),
        content: Text(
          tr('This removes ${member.uid} (${member.role.label}) from the organization.',
              'Is se ${member.uid} (${member.role.label}) organization se hat jayega.'),
          style: TextStyle(color: kMuted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('Cancel', 'Cancel'), style: TextStyle(color: kMuted)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('Remove', 'Hatayen'),
                style: const TextStyle(
                    color: Color(0xFFFF3B30), fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    final ok =
        await _service.removeStaff(widget.organizationId, member.uid);
    if (!mounted) return;
    toast(
        context,
        ok
            ? tr('Removed.', 'Hata diya gaya.')
            : tr('Could not remove this member.', 'Ye member hataya nahi ja saka.'));
    if (ok) _load();
  }

  @override
  Widget build(BuildContext context) {
    final org = _org;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent, // PHASE E (E4): transparent header — poster shows through
        iconTheme: IconThemeData(color: kGold),
        title: Text(tr('Staff & Referees', 'Staff aur Referees'),
            style: TextStyle(color: kText, fontWeight: FontWeight.bold)),
      ),
      body: _loading
          ? Center(child: CircularProgressIndicator(color: kGold))
          : org == null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      tr('Organization not found on this device.',
                          'Organization is device par nahi mili.'),
                      textAlign: TextAlign.center,
                      style: TextStyle(color: kMuted),
                    ),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    // Invite form.
                    MockupCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(tr('Invite staff / referee', 'Staff / referee invite karen'),
                              style: TextStyle(
                                  color: kText,
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold)),
                          const SizedBox(height: 4),
                          Text(
                            tr('Enter the user’s ID (Firebase UID). The invite stays pending until they accept it in the app.',
                                'User ki ID (Firebase UID) likhen. Invite us ke app mein accept karne tak pending rahegi.'),
                            style: TextStyle(color: kMuted, fontSize: 12),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _uidCtrl,
                            style: TextStyle(color: kText),
                            decoration: InputDecoration(
                              hintText: tr('User ID', 'User ID'),
                              hintStyle: TextStyle(color: kMuted),
                              filled: true,
                              fillColor: kBg,
                              border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: BorderSide(
                                      color:
                                          kMuted.withValues(alpha: 0.4))),
                            ),
                          ),
                          const SizedBox(height: 12),
                          DropdownButtonFormField<OrganizationMemberRole>(
                            initialValue: _inviteRole,
                            dropdownColor: kCard,
                            style: TextStyle(color: kText),
                            decoration: InputDecoration(
                              labelText: tr('Role', 'Role'),
                              labelStyle: TextStyle(color: kMuted),
                              filled: true,
                              fillColor: kBg,
                              border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: BorderSide(
                                      color:
                                          kMuted.withValues(alpha: 0.4))),
                            ),
                            items: [
                              OrganizationMemberRole.admin,
                              OrganizationMemberRole.staff,
                              OrganizationMemberRole.referee,
                            ]
                                .map((r) => DropdownMenuItem(
                                    value: r, child: Text(r.label)))
                                .toList(),
                            onChanged: (r) {
                              if (r != null) {
                                setState(() => _inviteRole = r);
                              }
                            },
                          ),
                          const SizedBox(height: 12),
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton(
                              onPressed: _inviting ? null : _invite,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: kGold,
                                padding:
                                    const EdgeInsets.symmetric(vertical: 14),
                              ),
                              child: Text(tr('Send invite', 'Invite bhejein'),
                                  style: const TextStyle(
                                      color: Colors.black,
                                      fontWeight: FontWeight.bold)),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(tr('Team', 'Team'),
                        style: TextStyle(
                            color: kText,
                            fontSize: 16,
                            fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    // Owner row (synthesized when the member row is
                    // missing — e.g. an org created before the member
                    // row existed).
                    if (!_members.any((m) => m.uid == org.ownerUid))
                      _memberTile(OrganizationMember(
                        organizationId: org.id,
                        uid: org.ownerUid,
                        role: OrganizationMemberRole.owner,
                        status: OrganizationMemberStatus.active,
                      )),
                    for (final m in _members) _memberTile(m),
                    if (_members.isEmpty)
                      MockupCard(
                        animate: false,
                        child: Text(
                          tr('No staff yet besides the owner — invite your first team member above.',
                              'Owner ke ilawa abhi koi staff nahi — upar se pehla team member invite karen.'),
                          style: TextStyle(color: kMuted, fontSize: 13),
                        ),
                      ),
                  ],
                ),
    );
  }

  Widget _memberTile(OrganizationMember m) {
    final isOwner = m.role == OrganizationMemberRole.owner;
    final isPending = m.status == OrganizationMemberStatus.pending;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: MockupCard(
        animate: false,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            CircleAvatar(
              radius: 18,
              backgroundColor: kGold.withValues(alpha: 0.15),
              child: Icon(
                  isOwner
                      ? Icons.star
                      : m.role == OrganizationMemberRole.referee
                          ? Icons.sports
                          : Icons.person,
                  color: kGold,
                  size: 18),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(m.uid,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: kText, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(
                    '${m.role.label} · ${isPending ? tr('Invite pending', 'Invite pending') : tr('Active', 'Active')}',
                    style: TextStyle(
                        color: isPending ? kGold : kMuted, fontSize: 12),
                  ),
                ],
              ),
            ),
            if (!isOwner)
              IconButton(
                icon: const Icon(Icons.delete_outline,
                    color: Color(0xFFFF3B30)),
                tooltip: tr('Remove', 'Hatayen'),
                onPressed: () => _remove(m),
              ),
          ],
        ),
      ),
    );
  }
}
