import 'dart:async';
import 'package:flutter/material.dart';
import '../services/squad.dart';
import '../services/supabase_db.dart';
import '../utils.dart';
import 'frames_widgets.dart';

/// ONLINE STATUS — bottom sheet, NOT an inline list.
///
/// The full player list lives ONLY inside this sheet (draggable,
/// vertically scrollable) so the Detail page stays short no matter how
/// many players joined. Opened from a compact "Status" side button on
/// the Detail page (beside the Players header) and from the unified
/// room's AppBar. Scoped: only registrations of THIS tournament (or
/// this squad when squadId is given) are shown — presence is never
/// exposed as a global online list.
///
/// Presence source: the existing `presence` table + ONE 2-minute
/// freshness rule (SupaDb.presenceIsOnline: last_seen within 2 min
/// = Online, counted, green dot; older = grey + "Last seen ...").
/// Count, dots and Last-seen text all derive from the same
/// last_seen, so the sheet can never say 0 while listing a
/// Just-now player (round 11 fix).
/// Explicit offline writes also fire on room exit, Detail exit, app
/// background/close, and logout — so a user who leaves flips grey
/// promptly instead of lingering green.
/// Heartbeats are written on login/foreground/resume by
/// PresenceService; no new table, no new presence system.
///
/// Professional layout (original design; no screenshot art copied):
///   * Header: "Online Users: X" + a close button.
///   * Scrollable rows separated by DASHED dividers.
///   * Each row: framed avatar, display name, small badges, presence dot.
/// Badges, mapped honestly onto data this app actually has:
///   * Lv N — a DISPLAY-ONLY level derived from matches played
///     (1 + totalMatches ~/ 10). This app has no level system in the
///     backend; the badge is cosmetic and never gates anything.
///   * Mic icon — only when the player is currently UNMUTED in this
///     room's voice session (voice_signaling_peers, same room id).
///   * Crown — only for admins (profiles.is_admin).
/// Admin controls in the ROOM only: when [isAdmin] is true, long-pressing
/// a participant row opens the room admin action menu via
/// [onAdminAction]. Other call sites (Detail page) pass nothing, so
/// non-admins and non-room sheets never see admin controls.
/// v2016 FIX 11: [teamId] — team rooms pass their team id; the sheet
/// then lists team_members and reads voice peers from community_<id>.
/// FIX 12 G6 (verifier 4 F2): [communityId] — community rooms pass
/// their community id; the sheet then lists community_members and
/// reads voice peers from community_<id>. community_members rows
/// carry no username, so names fall back to profiles.
Future<void> showOnlineStatusSheet(BuildContext context, String tournamentId, {String squadId = '', String teamId = '', String communityId = '', bool isAdmin = false, void Function(String uid, String name)? onAdminAction}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: kCardPurpleMid,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22)), side: const BorderSide(color: kCardPurpleBorder, width: 1.5)),
    builder: (ctx) => DraggableScrollableSheet(
      initialChildSize: 0.65,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (ctx, scrollController) => OnlineStatusSheet(
        tournamentId: tournamentId,
        squadId: squadId,
        teamId: teamId,
        communityId: communityId,
        scrollController: scrollController,
        isAdmin: isAdmin,
        onAdminAction: onAdminAction,
      ),
    ),
  );
}

class OnlineStatusSheet extends StatefulWidget {
  final String tournamentId;
  final String squadId;
  final String teamId;
  final String communityId;
  final ScrollController scrollController;
  final bool isAdmin;
  final void Function(String uid, String name)? onAdminAction;
  const OnlineStatusSheet({super.key, required this.tournamentId, this.squadId = '', this.teamId = '', this.communityId = '', required this.scrollController, this.isAdmin = false, this.onAdminAction});

  @override
  State<OnlineStatusSheet> createState() => _OnlineStatusSheetState();
}

class _OnlineStatusSheetState extends State<OnlineStatusSheet> {
  Map<String, Map<String, dynamic>> _presence = {};
  Map<String, Map<String, dynamic>> _profiles = {};
  Map<String, bool> _unmuted = {};
  String _query = '';
  String _lastUidsKey = '';
  Timer? _timer;

  // v2016 FIX 11: this id MUST match UnifiedRoomPage._voiceRoomId
  // (team rooms are squad_<teamId>) — presence/voice-peer lookups
  // in this sheet use it.
  // FIX 12 G6 (verifier 4 F2): community rooms are community_<id>
  // (same id as UnifiedRoomPage._voiceRoomId) so the mic icons
  // read the community room's voice peers.
  String get _roomId => widget.communityId.isNotEmpty ? communityRoomId(widget.communityId) : widget.teamId.isNotEmpty ? squadRoomId(widget.teamId) : widget.squadId.isNotEmpty ? squadRoomId(widget.squadId) : tournamentRoomId(widget.tournamentId);

  @override
  void initState() {
    super.initState();
    // Live refresh: presence staleness flips online->offline with time,
    // so re-fetch every 5 s while the sheet is open (same safety-net
    // style as the room's poll; realtime events also rebuild via the
    // registrations stream below).
    _timer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (mounted && _lastUidsKey.isNotEmpty) _load(_lastUidsKey.split(','));
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load(List<String> uids) async {
    final presence = await SupaDb.getPresenceMap(uids);
    final profiles = await SupaDb.getProfilesMap(uids);
    final peers = await SupaDb.getVoicePeers(_roomId);
    final unmuted = <String, bool>{};
    for (final p in peers) {
      final u = strVal(p['firebase_uid']);
      if (u.isNotEmpty && p['muted'] != true) unmuted[u] = true;
    }
    if (mounted) setState(() { _presence = presence; _profiles = profiles; _unmuted = unmuted; });
  }

  @override
  Widget build(BuildContext context) {
    // v2016 FIX 11: team rooms list team_members (rows carry
    // firebase_uid + user_name); the search + name reads below
    // accept user_name as well as username.
    // FIX 12 G6 (verifier 4 F2): community rooms list
    // community_members (rows carry firebase_uid + role only —
    // names come from profiles, see the row builder below).
    final stream = widget.communityId.isNotEmpty
        ? SupaDb.streamList('community_members', eqCol: 'community_id', eqVal: widget.communityId)
        : widget.teamId.isNotEmpty
        ? SupaDb.streamList('team_members', eqCol: 'team_id', eqVal: widget.teamId)
        : widget.squadId.isNotEmpty
            ? SupaDb.streamSquadRegistrations(widget.tournamentId, widget.squadId)
            : SupaDb.streamRegistrations(widget.tournamentId);
    // ROUND 7 QA: the sheet content previously had NO background of
    // its own — the DraggableScrollableSheet paints nothing, so on
    // some frames the chat list showed through around/above the sheet
    // and read as "sheet overlapping chat". Now the sheet is an
    // explicitly opaque rounded card, so chat can never show through.
    // 2026-11-20 (user order, "har jagah"): the sheet itself is a
    // MockupCard — gradient fill + the two rotating gold corner
    // shines. Its bottom corners sit at the screen edge, so the
    // all-corner radius is invisible there.
    return MockupCard(
      padding: EdgeInsets.zero,
      radius: 20,
      child: Column(
        children: [
          const SizedBox(height: 10),
          Container(width: 40, height: 4, decoration: BoxDecoration(color: kMuted, borderRadius: BorderRadius.circular(2))),
        const SizedBox(height: 12),
        Expanded(
          child: StreamBuilder<List<Map<String, dynamic>>>(
            stream: stream,
            builder: (context, snap) {
              final allRegs = snap.data ?? [];
              final regs = _query.isEmpty ? allRegs : allRegs.where((r) {
                final uid = strVal(r['firebase_uid']);
                final prof = _profiles[uid];
                final name = strVal(r['display_name'], strVal(r['username'], strVal(r['user_name'], strVal(prof?['display_name'], strVal(prof?['username'], ''))))).toLowerCase();
                return name.contains(_query);
              }).toList();
              final uids = regs.map((r) => strVal(r['firebase_uid'])).where((u) => u.isNotEmpty).toList();
              final key = uids.join(',');
              if (key != _lastUidsKey) {
                _lastUidsKey = key;
                WidgetsBinding.instance.addPostFrameCallback((_) => _load(uids));
              }
              var onlineCount = 0;
              for (final r in regs) {
                if (SupaDb.presenceIsOnline(_presence[strVal(r['firebase_uid'])] ?? {})) onlineCount++;
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Header: "Online Users: X" + close button.
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 8, 4),
                    child: Row(
                      children: [
                        Text('Online Users: $onlineCount', style: TextStyle(color: kGold, fontSize: 18, fontWeight: FontWeight.bold)),
                        const Spacer(),
                        IconButton(icon: Icon(Icons.close, color: kMuted), onPressed: () => Navigator.pop(context)),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(widget.communityId.isNotEmpty ? '${regs.length} members in this community • Only members in this community can see this list.' : widget.teamId.isNotEmpty ? '${regs.length} members in this team • Only members in this team can see this list.' : '${regs.length} players in this ${widget.squadId.isNotEmpty ? 'squad' : 'tournament'} • Only players in this ${widget.squadId.isNotEmpty ? 'squad' : 'tournament'} can see this list.', style: TextStyle(color: kMuted, fontSize: 12)),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    // FIX 23 item 29: card look via CardFieldShell.
                    child: CardFieldShell(
                      radius: 20,
                      child: TextField(
                      onChanged: (v) => setState(() => _query = v.trim().toLowerCase()),
                      style: TextStyle(color: kText),
                      decoration: InputDecoration(hintText: 'Search participants…', hintStyle: TextStyle(color: kMuted), prefixIcon: Icon(Icons.search, color: kMuted, size: 18), border: const OutlineInputBorder(borderSide: BorderSide.none), contentPadding: const EdgeInsets.symmetric(vertical: 8)),
                    ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: regs.isEmpty
                        ? Center(child: Text(widget.communityId.isNotEmpty ? 'No members yet.' : 'No players joined yet.', style: TextStyle(color: kMuted)))
                        : ListView.separated(
                            controller: widget.scrollController,
                            itemCount: regs.length,
                            separatorBuilder: (_, __) => const Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: _DashedDivider()),
                            itemBuilder: (_, i) {
                              final p = regs[i];
                              final uid = strVal(p['firebase_uid']);
                              final pres = _presence[uid] ?? {};
                              final online = SupaDb.presenceIsOnline(pres);
                              final prof = _profiles[uid];
                              // FIX 12 G6 (verifier 4 F2):
                              // community_members rows carry no
                              // username — fall back to the
                              // profile's display name, never a
                              // fake 'Player' for every row.
                              final name = strVal(p['username'], strVal(p['user_name'], strVal(prof?['display_name'], strVal(prof?['username'], 'Player'))));
                              final team = strVal(p['team_name']);
                              final slot = SupaDb.slotOf(p) > 0 ? SupaDb.slotOf(p).toString() : '-';
                              final isAdmin = prof != null && (prof['is_admin'] == true || prof['isAdmin'] == true);
                              final matches = prof == null ? 0 : SupaDb.intOf(prof['total_matches']);
                              final level = 1 + (matches ~/ 10);
                              final onMic = _unmuted[uid] == true;
                              return ListTile(
                                onLongPress: widget.isAdmin && widget.onAdminAction != null ? () => widget.onAdminAction!(uid, name) : null,
                                leading: CachedFramedAvatar(uid: uid, name: name, radius: 20),
                                title: Row(
                                  children: [
                                    Flexible(child: Text(name, style: TextStyle(color: kText, fontWeight: FontWeight.bold), overflow: TextOverflow.ellipsis)),
                                    const SizedBox(width: 6),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                      decoration: BoxDecoration(color: kGold.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(8)),
                                      child: Text('Lv $level', style: TextStyle(color: kGold, fontSize: 11, fontWeight: FontWeight.bold)),
                                    ),
                                    if (onMic) const Padding(padding: EdgeInsets.only(left: 4), child: Icon(Icons.mic, color: Colors.greenAccent, size: 15)),
                                    if (isAdmin) Padding(padding: EdgeInsets.only(left: 4), child: Icon(Icons.emoji_events, color: kGold, size: 16)),
                                  ],
                                ),
                                subtitle: Text(team.isNotEmpty ? 'Squad: $team • Slot $slot' : 'Slot $slot', style: TextStyle(color: kMuted, fontSize: 12)),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    ConstrainedBox(
                                      constraints: const BoxConstraints(maxWidth: 110),
                                      child: Text(
                                        online ? 'Online' : (pres.isEmpty ? 'Last seen —' : 'Last seen ${timeAgo(SupaDb.parseTs(pres['last_seen']))}'),
                                        style: TextStyle(color: online ? Colors.greenAccent : kMuted, fontSize: 12, fontWeight: online ? FontWeight.bold : FontWeight.normal),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    Container(width: 10, height: 10, decoration: BoxDecoration(shape: BoxShape.circle, color: online ? Colors.greenAccent : Colors.grey)),
                                  ],
                                ),
                              );
                            },
                          ),
                  ),
                ],
              );
            },
          ),
        ),
        ],
      ),
    );
  }
}

/// Dashed horizontal divider (Flutter has no built-in dashed divider).
class _DashedDivider extends StatelessWidget {
  const _DashedDivider();
  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size(double.infinity, 1),
      painter: _DashedPainter(),
    );
  }
}

class _DashedPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = const Color(0xFF475569)..strokeWidth = 1;
    const dash = 5.0;
    const gap = 4.0;
    double x = 0;
    while (x < size.width) {
      canvas.drawLine(Offset(x, 0), Offset(x + dash, 0), paint);
      x += dash + gap;
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
