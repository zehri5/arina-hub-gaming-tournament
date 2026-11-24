import 'package:flutter/material.dart';
import 'package:protournament_user/platform/competition/waitlist_service.dart';
import 'package:protournament_user/platform/core/roles.dart';
import 'package:protournament_user/utils.dart';

/// Waitlist page (blueprint §5-1; backend guide §5-1
/// `waitlist_entries`).
///
/// Player view: my position (if waiting), join / cancel. Admin
/// view (only when [RoleService.canVerifyResults] allows the
/// viewer's role): the ordered queue + promote-next button.
///
/// NOT wired into main.dart navigation — the coordinator wires it.
/// Push it with:
/// `Navigator.push(context, MaterialPageRoute(builder: (_) =>
/// WaitlistPage(tournamentId: ..., myUid: ..., myTeamId: ...)))`.
/// Pass `myUid` (the viewer's Firebase UID) so the page can show
/// their position and let them join/cancel.
///
/// INTERIM — LOCAL STORE ONLY: entries live in the local store
/// until the backend `waitlist_entries` table + `register_team`
/// RPC land.
class WaitlistPage extends StatefulWidget {
  final String tournamentId;

  /// The viewer's Firebase UID (solo) or captain UID (team).
  /// Null = signed-out viewer; join/cancel are disabled.
  final String? myUid;

  /// The viewer's team ID, for team registrations.
  final String? myTeamId;

  /// Role of the viewer; admins see the queue + promote button.
  final AppRole viewerRole;

  const WaitlistPage({
    super.key,
    required this.tournamentId,
    this.myUid,
    this.myTeamId,
    this.viewerRole = AppRole.player,
  });

  @override
  State<WaitlistPage> createState() => _WaitlistPageState();
}

class _WaitlistPageState extends State<WaitlistPage> {
  final WaitlistService _service = const WaitlistService();

  List<WaitlistEntry> _entries = [];
  WaitlistEntry? _myEntry;
  bool _loading = true;
  bool _busy = false;
  String? _message;

  bool get _isAdmin => RoleService.canVerifyResults(widget.viewerRole);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final entries = await _service.getWaitlist(widget.tournamentId);
    final myUid = widget.myUid;
    final myEntry = myUid == null
        ? null
        : await _service.getEntryFor(widget.tournamentId, myUid);
    if (!mounted) return;
    setState(() {
      _entries = entries;
      _myEntry = myEntry;
      _loading = false;
    });
  }

  Future<void> _join() async {
    final uid = widget.myUid;
    if (uid == null) return;
    setState(() => _busy = true);
    final position = await _service.joinWaitlist(widget.tournamentId, uid,
        teamId: widget.myTeamId);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _message = tr('You joined the waitlist at position $position.',
          'Aap waitlist mein position $position par shamil ho gaye.');
    });
    await _load();
  }

  Future<void> _cancel() async {
    final uid = widget.myUid;
    if (uid == null) return;
    setState(() => _busy = true);
    await _service.cancelEntry(widget.tournamentId, uid);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _message = tr('You left the waitlist.',
          'Aap waitlist se nikal gaye.');
    });
    await _load();
  }

  Future<void> _promoteNext() async {
    setState(() => _busy = true);
    final promoted = await _service.promoteNext(widget.tournamentId);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _message = promoted == null
          ? tr('The waitlist is empty.', 'Waitlist khaali hai.')
          : tr('Promoted ${promoted.uid} from the waitlist.',
              '${promoted.uid} waitlist se promote ho gaya.');
    });
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final myPosition = _myEntry?.position;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent, // PHASE E (E4): transparent header — poster shows through
        iconTheme: IconThemeData(color: kGold),
        title: Text(tr('Waitlist', 'Waitlist'),
            style: TextStyle(color: kText)),
      ),
      body: _loading
          ? Center(child: CircularProgressIndicator(color: kGold))
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  MockupCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          myPosition == null
                              ? tr('You are not on the waitlist.',
                                  'Aap waitlist mein nahi hain.')
                              : tr('Your position: $myPosition',
                                  'Aap ki position: $myPosition'),
                          style: TextStyle(
                              color: kGold,
                              fontSize: 16,
                              fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          tr(
                            '${_entries.length} team(s) waiting. When a slot frees up, the first waiting team is promoted.',
                            '${_entries.length} team(s) wait kar rahe hain. Slot khaali hote hi pehli waiting team promote ho jayegi.',
                          ),
                          style: TextStyle(color: kMuted, fontSize: 13),
                        ),
                        const SizedBox(height: 16),
                        if (widget.myUid == null)
                          Text(
                            tr('Sign in to join the waitlist.',
                                'Waitlist join karne ke liye sign in karen.'),
                            style: TextStyle(color: kMuted, fontSize: 13),
                          )
                        else if (myPosition == null)
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: kGold,
                                foregroundColor: Colors.black,
                              ),
                              onPressed: _busy ? null : _join,
                              child: Text(tr('Join waitlist',
                                  'Waitlist join karen')),
                            ),
                          )
                        else
                          SizedBox(
                            width: double.infinity,
                            child: OutlinedButton(
                              style: OutlinedButton.styleFrom(
                                foregroundColor: kText,
                                side: BorderSide(color: kBorder),
                              ),
                              onPressed: _busy ? null : _cancel,
                              child: Text(tr('Leave waitlist',
                                  'Waitlist se nikal jayen')),
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (_message != null) ...[
                    const SizedBox(height: 12),
                    Text(_message!,
                        style: TextStyle(color: kMuted, fontSize: 13)),
                  ],
                  if (_isAdmin) ...[
                    const SizedBox(height: 20),
                    Text(tr('Admin — waitlist queue',
                            'Admin — waitlist queue'),
                        style: TextStyle(
                            color: kSectionLabel,
                            fontSize: 14,
                            fontWeight: FontWeight.bold)),
                    const SizedBox(height: 12),
                    MockupCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (_entries.isEmpty)
                            Text(
                              tr('No one is waiting.',
                                  'Koi wait nahi kar raha.'),
                              style:
                                  TextStyle(color: kMuted, fontSize: 13),
                            )
                          else
                            for (final entry in _entries)
                              Padding(
                                padding:
                                    const EdgeInsets.only(bottom: 8),
                                child: Row(
                                  children: [
                                    Text('#${entry.position}',
                                        style: TextStyle(
                                            color: kGold,
                                            fontSize: 14,
                                            fontWeight: FontWeight.bold)),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Text(
                                        entry.teamId.isNotEmpty
                                            ? entry.teamId
                                            : entry.uid,
                                        style: TextStyle(
                                            color: kText, fontSize: 14),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                          const SizedBox(height: 12),
                          ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: kGold,
                              foregroundColor: Colors.black,
                            ),
                            onPressed:
                                (_busy || _entries.isEmpty) ? null : _promoteNext,
                            child: Text(tr('Promote next',
                                'Agla promote karen')),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
    );
  }
}
