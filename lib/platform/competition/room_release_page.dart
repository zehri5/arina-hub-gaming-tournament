import 'package:flutter/material.dart';
import 'package:protournament_user/platform/competition/room_release.dart';
import 'package:protournament_user/platform/core/roles.dart';
import 'package:protournament_user/utils.dart';

/// Room release page (blueprint §5-4; backend guide §5-4
/// `room_releases` + `release_room` RPC).
///
/// Admin view (only when [RoleService.canVerifyResults] allows the
/// viewer's role): set the room ID + password + release time, and
/// release to the checked-in teams. Player view: shows the released
/// credentials ONLY when the viewer's team is in the released list;
/// otherwise "Room details will appear here at release time".
///
/// The PUBG custom room is created INSIDE THE GAME by an authorized
/// person — the app only distributes the room ID and password. The
/// UI copy says so and never claims automatic room creation.
///
/// NOT wired into main.dart navigation — the coordinator wires it.
/// Push it with:
/// `Navigator.push(context, MaterialPageRoute(builder: (_) =>
/// RoomReleasePage(matchId: ..., checkedInTeamIds: ...,
/// viewerTeamId: ...)))`.
///
/// INTERIM — LOCAL STORE ONLY: credentials live in the local store
/// until the backend `room_releases` table + `release_room` RPC
/// land. [RoomReleaseService] is the ONLY reader of the stored
/// credentials — they are never exposed in a public SELECT.
class RoomReleasePage extends StatefulWidget {
  final String matchId;

  /// Teams that checked in — ONLY these teams ever receive the
  /// room credentials.
  final List<String> checkedInTeamIds;

  /// The viewer's team ID. Credentials are shown only when this
  /// team is in the released list. Null = viewer has no team here.
  final String? viewerTeamId;

  /// Role of the viewer; admins see the set/release controls.
  final AppRole viewerRole;

  const RoomReleasePage({
    super.key,
    required this.matchId,
    required this.checkedInTeamIds,
    this.viewerTeamId,
    this.viewerRole = AppRole.player,
  });

  @override
  State<RoomReleasePage> createState() => _RoomReleasePageState();
}

class _RoomReleasePageState extends State<RoomReleasePage> {
  final RoomReleaseService _service = const RoomReleaseService();
  final TextEditingController _roomIdController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _minutesController =
      TextEditingController(text: '15');

  RoomRelease? _release;
  bool _loading = true;
  bool _busy = false;
  String? _message;

  bool get _isAdmin => RoleService.canVerifyResults(widget.viewerRole);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _roomIdController.dispose();
    _passwordController.dispose();
    _minutesController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final release = await _service.getRelease(widget.matchId);
    if (!mounted) return;
    setState(() {
      _release = release;
      _loading = false;
      if (release != null) {
        _roomIdController.text = release.roomId;
        _passwordController.text = release.roomPassword;
      }
    });
  }

  Future<void> _setCredentials() async {
    final roomId = _roomIdController.text.trim();
    final password = _passwordController.text.trim();
    if (roomId.isEmpty || password.isEmpty) {
      setState(() => _message = tr('Enter the room ID and password.',
          'Room ID aur password likhen.'));
      return;
    }
    final minutes = int.tryParse(_minutesController.text.trim()) ?? 15;
    setState(() => _busy = true);
    await _service.setCredentials(
      widget.matchId,
      roomId,
      password,
      DateTime.now().add(Duration(minutes: minutes)),
      '',
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _message = tr('Room credentials saved. They will release at the set time.',
          'Room details save ho gayi hain. Set time par release hongi.');
    });
    await _load();
  }

  Future<void> _releaseNow() async {
    setState(() => _busy = true);
    final released = await _service.releaseRoom(
        widget.matchId, widget.checkedInTeamIds, DateTime.now());
    if (!mounted) return;
    setState(() {
      _busy = false;
      _message = released.isEmpty
          ? tr(
              'Not released yet — the release time has not come, or no credentials are set.',
              'Abhi release nahi hua — release time nahi aaya, ya details set nahi hain.')
          : tr('Room released to ${released.length} checked-in team(s).',
              'Room ${released.length} checked-in team(s) ko release ho gaya.');
    });
    await _load();
  }

  String _releaseTimeText(DateTime releaseAt) {
    final time =
        '${releaseAt.hour.toString().padLeft(2, '0')}:${releaseAt.minute.toString().padLeft(2, '0')}';
    return tr('Release time: $time', 'Release time: $time');
  }

  @override
  Widget build(BuildContext context) {
    final release = _release;
    final viewerTeamId = widget.viewerTeamId;
    final showCredentials = release != null &&
        viewerTeamId != null &&
        release.releasedToTeam(viewerTeamId);
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent, // PHASE E (E4): transparent header — poster shows through
        iconTheme: IconThemeData(color: kGold),
        title: Text(tr('Room details', 'Room details'),
            style: TextStyle(color: kText)),
      ),
      body: _loading
          ? Center(child: CircularProgressIndicator(color: kGold))
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Player view: credentials only for released teams.
                  MockupCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (showCredentials) ...[
                          Text(tr('Room ID', 'Room ID'),
                              style: TextStyle(
                                  color: kMuted, fontSize: 13)),
                          Text(release.roomId,
                              style: TextStyle(
                                  color: kGold,
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold)),
                          const SizedBox(height: 12),
                          Text(tr('Password', 'Password'),
                              style: TextStyle(
                                  color: kMuted, fontSize: 13)),
                          Text(release.roomPassword,
                              style: TextStyle(
                                  color: kText,
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold)),
                        ] else ...[
                          Text(
                            tr('Room details will appear here at release time.',
                                'Room details release time par yahan nazar aayengi.'),
                            style: TextStyle(color: kText, fontSize: 14),
                          ),
                          if (release != null) ...[
                            const SizedBox(height: 8),
                            Text(_releaseTimeText(release.releaseAt),
                                style: TextStyle(
                                    color: kMuted, fontSize: 13)),
                          ],
                        ],
                        const SizedBox(height: 12),
                        Text(
                          tr(
                            'The custom room is created inside the game by an authorized person — this app only shares the room ID and password.',
                            'Custom room game ke andar authorized shakhs banata hai — ye app sirf room ID aur password share karti hai.',
                          ),
                          style: TextStyle(color: kMuted, fontSize: 12),
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
                    Text(tr('Admin — set room & release',
                            'Admin — room set karen & release karen'),
                        style: TextStyle(
                            color: kSectionLabel,
                            fontSize: 14,
                            fontWeight: FontWeight.bold)),
                    const SizedBox(height: 12),
                    MockupCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          TextField(
                            controller: _roomIdController,
                            style: TextStyle(color: kText),
                            decoration: InputDecoration(
                              labelText: tr('Room ID', 'Room ID'),
                              labelStyle: TextStyle(color: kMuted),
                            ),
                          ),
                          const SizedBox(height: 8),
                          TextField(
                            controller: _passwordController,
                            style: TextStyle(color: kText),
                            decoration: InputDecoration(
                              labelText: tr('Room password', 'Room password'),
                              labelStyle: TextStyle(color: kMuted),
                            ),
                          ),
                          const SizedBox(height: 8),
                          TextField(
                            controller: _minutesController,
                            keyboardType: TextInputType.number,
                            style: TextStyle(color: kText),
                            decoration: InputDecoration(
                              labelText: tr(
                                  'Release in (minutes from now)',
                                  'Release kitne minute baad (abhi se)'),
                              labelStyle: TextStyle(color: kMuted),
                            ),
                          ),
                          const SizedBox(height: 12),
                          ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: kGold,
                              foregroundColor: Colors.black,
                            ),
                            onPressed: _busy ? null : _setCredentials,
                            child: Text(tr('Save room credentials',
                                'Room details save karen')),
                          ),
                          const SizedBox(height: 8),
                          OutlinedButton(
                            style: OutlinedButton.styleFrom(
                              foregroundColor: kText,
                              side: BorderSide(color: kBorder),
                            ),
                            onPressed: _busy ? null : _releaseNow,
                            child: Text(
                                tr('Release to checked-in teams',
                                    'Checked-in teams ko release karen')),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            tr(
                              '${widget.checkedInTeamIds.length} checked-in team(s) will receive the room. Only checked-in teams ever see the credentials, and never before the release time.',
                              '${widget.checkedInTeamIds.length} checked-in team(s) ko room milega. Sirf checked-in teams ko hi details nazar aati hain, aur release time se pehle kabhi nahi.',
                            ),
                            style: TextStyle(color: kMuted, fontSize: 12),
                          ),
                          if (release != null && release.isReleased) ...[
                            const SizedBox(height: 8),
                            Text(
                              tr('Released to: ${release.releasedTo.join(', ')}',
                                  'Release ho gaya: ${release.releasedTo.join(', ')}'),
                              style:
                                  TextStyle(color: kText, fontSize: 13),
                            ),
                          ],
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
