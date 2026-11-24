import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../components/arena_chat.dart' hide ArenaChatMessage;
import '../models/voice_room_models.dart';
import '../theme.dart'; // PHASE E (update 11): kCardFillOpacity token
import '../theme/arena_theme.dart';
import '../widgets/arena_custom_graphics.dart';

class ArenaVoiceRoomScreen extends StatefulWidget {
  final String roomTitle;
  final String hostName;
  final String hostAvatar;
  final bool hostVerified;
  final List<VoiceSeatMember> initialSeats;
  final List<ArenaChatMessage> initialMessages;

  // Existing backend callbacks
  final ValueChanged<bool>? onMicToggled;
  final ValueChanged<bool>? onVoiceOutputToggled;
  final ValueChanged<String>? onSendMessage;
  final VoidCallback? onLeaveRoom;

  // FIX 31 — live wiring (all optional so the screen still mounts
  // standalone with mock props; the real room passes every one):
  // live room state, synced in didUpdateWidget.
  final int initialDurationSeconds;
  final VoiceConnectionStatus connectionStatus;
  final bool isLive;
  final bool isMicOn;
  final bool isVoiceOn;
  // FIX 22 item 7: the speaker toggle is REMOVED in the real app —
  // voice is ALWAYS on the loudspeaker. When true the voice chip
  // is display-only (tap does nothing, no routing change).
  final bool lockVoiceOutputOn;
  // FIX 23 item 16b: mic toggles only while voice is connected.
  final bool micToggleEnabled;
  // Real people count (seated + listeners) — header badge, chat
  // "N Online", host card "N Online". 0 = standalone fallback.
  final int playersCount;
  // FIX 23 item 17: false = no host on voice — card shows
  // "No host" + an empty circle, never another member's photo.
  final bool hostPresent;
  // Real scope photo (community/team/tournament banner) behind
  // the host card; null = the code's asset path (graceful fallback).
  final String? hostBannerAssetOrUrl;
  // The current user, for the optimistic sent message + own seat.
  final String? ownMemberId;
  final String ownDisplayName;
  final String? ownAvatar;
  final String ownInitials;
  final bool ownIsHost;
  // Menu (More) actions — the sheet's entries call these (pop
  // first, then the real function). Null = pop only.
  final VoidCallback? onFollowers;
  final VoidCallback? onMusic;
  final VoidCallback? onRjPanel;
  final VoidCallback? onSettings;
  // FIX 23 item 9: Followers row sub-line + Follow pill. Null
  // count = no sub-line; null followState = no pill (team scope).
  final String? followersCountLabel;
  final bool? followState;
  final bool followBusy;
  final VoidCallback? onFollowToggle;
  // RJ Panel is host-only — false hides the row.
  final bool showRjPanel;
  // PHASE E (E28): Music is host-only too — false hides the row.
  // Same RJ rule as showRjPanel; default true so other callers
  // (previews, tests) keep the old behaviour.
  final bool showMusic;
  // Extra menu rows (Power, Voice, Invite, Follow Host, Leave
  // Voice, ...) — appended after Settings, before Leave Room.
  final List<ArenaMenuEntry> menuExtras;
  // Header + podium navigation.
  final VoidCallback? onUsersTap;
  final VoidCallback? onViewAll;
  // Seat tap (empty seat = join voice, own seat = mic toggle,
  // other seat = admin menu for the host).
  final ValueChanged<VoiceSeatMember>? onSeatTap;
  // Composer: photo send (real _sendImage). Smile opens the
  // in-screen emoji strip (same ArenaEmojis set as the old room).
  final VoidCallback? onImageTap;

  const ArenaVoiceRoomScreen({
    super.key,
    required this.roomTitle,
    required this.hostName,
    required this.hostAvatar,
    this.hostVerified = true,
    required this.initialSeats,
    required this.initialMessages,
    this.onMicToggled,
    this.onVoiceOutputToggled,
    this.onSendMessage,
    this.onLeaveRoom,
    this.initialDurationSeconds = 0,
    this.connectionStatus = VoiceConnectionStatus.connected,
    this.isLive = true,
    this.isMicOn = true,
    this.isVoiceOn = true,
    this.lockVoiceOutputOn = false,
    this.micToggleEnabled = true,
    this.playersCount = 0,
    this.hostPresent = true,
    this.hostBannerAssetOrUrl,
    this.ownMemberId,
    this.ownDisplayName = 'You',
    this.ownAvatar,
    this.ownInitials = '?',
    this.ownIsHost = false,
    this.onFollowers,
    this.onMusic,
    this.onRjPanel,
    this.onSettings,
    this.followersCountLabel,
    this.followState,
    this.followBusy = false,
    this.onFollowToggle,
    this.showRjPanel = true,
    this.showMusic = true,
    this.menuExtras = const [],
    this.onUsersTap,
    this.onViewAll,
    this.onSeatTap,
    this.onImageTap,
  });

  @override
  State<ArenaVoiceRoomScreen> createState() => _ArenaVoiceRoomScreenState();
}

class _ArenaVoiceRoomScreenState extends State<ArenaVoiceRoomScreen>
    with SingleTickerProviderStateMixin {
  late List<VoiceSeatMember> _seats;
  late List<ArenaChatMessage> _messages;

  bool _isLive = true;
  bool _isMicOn = true;
  bool _isVoiceOn = true;
  VoiceConnectionStatus _connectionStatus = VoiceConnectionStatus.connected;
  // FIX 31: 0 here — the parent passes the real elapsed time
  // since room entry (the demo's hardcoded 12:45 was fake data).
  int _durationSeconds = 0;
  int? _selectedSeatNumber;
  Timer? _timer;
  // FIX 31: emoji strip state (same ArenaEmojis set as the old room).
  bool _showEmojiStrip = false;

  final TextEditingController _msgController = TextEditingController();
  final ScrollController _chatScrollController = ScrollController();
  late final AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _seats = List.of(widget.initialSeats);
    _messages = List.of(widget.initialMessages);
    // FIX 31: live state comes from the parent (real room) — the
    // field defaults above are only the standalone fallback.
    _isLive = widget.isLive;
    _isMicOn = widget.isMicOn;
    _isVoiceOn = widget.isVoiceOn;
    _connectionStatus = widget.connectionStatus;
    _durationSeconds = widget.initialDurationSeconds;
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat(reverse: true);

    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_isLive && mounted) {
        setState(() => _durationSeconds++);
      }
    });
  }

  @override
  void didUpdateWidget(covariant ArenaVoiceRoomScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // FIX 31: live sync from the parent. Seats/messages only
    // replace local state when their content actually changed
    // (the chat stream re-emits on its 3 s poll) — otherwise
    // every poll would reset scroll + selection.
    if (!_sameSeats(widget.initialSeats, _seats)) {
      _seats = List.of(widget.initialSeats);
    }
    final messagesChanged = !_sameMessages(widget.initialMessages, _messages);
    if (messagesChanged) {
      final grew = widget.initialMessages.length > _messages.length;
      final nearBottom = !_chatScrollController.hasClients ||
          _chatScrollController.position.maxScrollExtent -
                  _chatScrollController.position.pixels <
              120;
      _messages = List.of(widget.initialMessages);
      if (grew && nearBottom) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_chatScrollController.hasClients) {
            _chatScrollController.animateTo(
              _chatScrollController.position.maxScrollExtent,
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeOut,
            );
          }
        });
      }
    }
    if (widget.connectionStatus != _connectionStatus) {
      _connectionStatus = widget.connectionStatus;
    }
    if (widget.isLive != _isLive) _isLive = widget.isLive;
    // Controlled mic/voice: the parent owns the real state, so a
    // failed toggle (e.g. mic gated while disconnected) reverts
    // the optimistic local flip on the next rebuild.
    if (widget.isMicOn != _isMicOn) _isMicOn = widget.isMicOn;
    if (widget.isVoiceOn != _isVoiceOn) _isVoiceOn = widget.isVoiceOn;
  }

  // FIX 31: content-equality helpers for didUpdateWidget.
  static bool _sameSeats(List<VoiceSeatMember> a, List<VoiceSeatMember> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      final x = a[i], y = b[i];
      if (x.seatNumber != y.seatNumber ||
          x.memberId != y.memberId ||
          x.isMuted != y.isMuted ||
          x.isSpeaking != y.isSpeaking ||
          x.requestToSpeak != y.requestToSpeak) {
        return false;
      }
    }
    return true;
  }

  static bool _sameMessages(List<ArenaChatMessage> a, List<ArenaChatMessage> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id || a[i].text != b[i].text) return false;
    }
    return true;
  }

  // FIX 31: compact count for the header badge / "N Online"
  // (124 -> "124", 1500 -> "1.5K") — never a fake number.
  static String _compactCount(int n) {
    if (n < 1000) return '$n';
    if (n < 1000000) {
      final v = n / 1000;
      return '${v.toStringAsFixed(v >= 10 ? 0 : 1)}K';
    }
    return '${(n / 1000000).toStringAsFixed(1)}M';
  }

  @override
  void dispose() {
    _timer?.cancel();
    _pulseController.dispose();
    _msgController.dispose();
    _chatScrollController.dispose();
    super.dispose();
  }

  String _formatDuration(int totalSeconds) {
    final h = (totalSeconds ~/ 3600).toString().padLeft(2, '0');
    final m = ((totalSeconds % 3600) ~/ 60).toString().padLeft(2, '0');
    final s = (totalSeconds % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  void _toggleMic() {
    // FIX 31 (item 16b): mic toggles only while voice is
    // connected — a dead tap while disconnected stays silent
    // instead of flipping the local mic icon.
    if (!widget.micToggleEnabled) return;
    setState(() {
      _isMicOn = !_isMicOn;
      // FIX 31: flip the CURRENT USER's seat, not always the
      // host seat (the demo assumed the user is the host).
      final targetId = widget.ownMemberId;
      _seats = _seats.map((seat) {
        final isTarget =
            targetId != null ? seat.memberId == targetId : seat.isHost;
        if (isTarget) {
          return seat.copyWith(isMuted: !_isMicOn, isSpeaking: _isMicOn);
        }
        return seat;
      }).toList();
    });
    widget.onMicToggled?.call(_isMicOn);
  }

  void _toggleVoice() {
    // FIX 31 (fix22 item 7): voice output is ALWAYS on the
    // loudspeaker in the real app — when locked, the chip is
    // display-only; no routing change is ever introduced.
    if (widget.lockVoiceOutputOn) return;
    setState(() => _isVoiceOn = !_isVoiceOn);
    widget.onVoiceOutputToggled?.call(_isVoiceOn);
  }

  void _sendChat() {
    final text = _msgController.text.trim();
    if (text.isEmpty) return;

    setState(() {
      // FIX 31: the optimistic row is the CURRENT user (real
      // name/avatar/initials from the parent), never the host —
      // the demo hardcoded the host + 'SZ'. The live row from
      // the parent replaces this on the next stream emission.
      _messages.add(
        ArenaChatMessage(
          id: 'local-${DateTime.now().millisecondsSinceEpoch}',
          senderName: widget.ownDisplayName,
          avatarAssetOrUrl: widget.ownAvatar,
          initials: widget.ownInitials,
          timestamp: 'Now',
          text: text,
          isHost: widget.ownIsHost,
          isOwn: true,
          level: 1,
        ),
      );
      _msgController.clear();
    });

    widget.onSendMessage?.call(text);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_chatScrollController.hasClients) {
        _chatScrollController.animateTo(
          _chatScrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _openMoreBottomSheet() {
    // FIX 31: the sheet's entries now call the REAL functions
    // (pop first, then the parent callback) instead of only
    // popping the sheet.
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => _MoreActionsSheet(
        onFollowers: () {
          Navigator.pop(ctx);
          widget.onFollowers?.call();
        },
        onMusic: () {
          Navigator.pop(ctx);
          widget.onMusic?.call();
        },
        onRjPanel: () {
          Navigator.pop(ctx);
          widget.onRjPanel?.call();
        },
        onSettings: () {
          Navigator.pop(ctx);
          widget.onSettings?.call();
        },
        onLeaveRoom: () {
          Navigator.pop(ctx);
          _confirmLeaveRoom();
        },
        followersCountLabel: widget.followersCountLabel,
        followState: widget.followState,
        followBusy: widget.followBusy,
        onFollowToggle: widget.onFollowToggle == null
            ? null
            : () {
                Navigator.pop(ctx);
                widget.onFollowToggle?.call();
              },
        showRjPanel: widget.showRjPanel,
        showMusic: widget.showMusic,
        menuExtras: widget.menuExtras,
      ),
    );
  }

  void _confirmLeaveRoom() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ArenaColors.cardBg,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: ArenaColors.purple),
        ),
        title: Text('Leave Voice Room?', style: ArenaTypography.heading(20)),
        content: Text(
          'Your microphone and room audio will disconnect.',
          style: ArenaTypography.body(14, color: ArenaColors.secondaryText),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Stay', style: TextStyle(color: ArenaColors.secondaryText)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: ArenaColors.liveRed),
            onPressed: () {
              Navigator.pop(ctx);
              widget.onLeaveRoom?.call();
            },
            child: const Text('Leave Room', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ArenaColors.primaryBg,
      resizeToAvoidBottomInset: true,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Full-Screen Gaming Background
          Image.asset(
            'assets/images/arena_voice_background.png',
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [Color(0xFF1A0B3B), ArenaColors.primaryBg, Color(0xFF0A0D1C)],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                ),
              ),
            ),
          ),
          // Controlled readability scrim
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  ArenaColors.primaryBg.withValues(alpha: 0.45),
                  ArenaColors.primaryBg.withValues(alpha: 0.55),
                  ArenaColors.primaryBg.withValues(alpha: 0.85),
                ],
              ),
            ),
          ),

          // Main Safe Content Column
          SafeArea(
            child: Column(
              children: [
                // 1. Compact Premium Header
                _buildTopHeader(),

                // FIX 31: scrollable body. The as-sent fixed sections
                // (host card + stage + podium) measure ~844px tall, which
                // overflows every real phone viewport (~124px on an
                // 844px phone, 368px in the 600px test viewport) because
                // the chat panel was Expanded into negative space. The
                // sections keep their design and order; they scroll above
                // a fixed 260px chat slot so chat stays visible.
                Expanded(
                  child: Column(
                    children: [
                      Expanded(
                        child: SingleChildScrollView(
                          child: Padding(
                            padding:
                                const EdgeInsets.symmetric(horizontal: 12),
                            child: Column(
                              children: [
                                const SizedBox(height: 8),
                                // 2. Elite Host Profile Banner
                                _buildHostProfileCard(),
                                const SizedBox(height: 10),
                                // 3. Central Voice Control Stage
                                _buildVoiceStage(),
                                const SizedBox(height: 10),
                                // 4. Voice Seats 3x2 Podium Grid
                                _buildSeatsPodiumCard(),
                                const SizedBox(height: 10),
                              ],
                            ),
                          ),
                        ),
                      ),
                      // 5. Chat Messages Panel (fixed slot, always visible)
                      Padding(
                        padding:
                            const EdgeInsets.symmetric(horizontal: 12),
                        child: SizedBox(
                          height: 260,
                          child: _buildChatPanel(),
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                  ),
                ),

                // 6. Fixed Message Composer
                _buildMessageComposer(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// FIX 31: avatar from a URL (NetworkImage) or an asset path
  /// (Image.asset) — the usage example passes a URL while the
  /// code assumed an asset. Icon fallback on any failure.
  Widget _avatarImage(String path, {double iconSize = 24}) {
    if (path.startsWith('http')) {
      return Image.network(
        path,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => Container(
          color: ArenaColors.glassSurface,
          child: Icon(LucideIcons.user, color: Colors.white, size: iconSize),
        ),
      );
    }
    return Image.asset(
      path,
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => Container(
        color: ArenaColors.glassSurface,
        child: Icon(LucideIcons.user, color: Colors.white, size: iconSize),
      ),
    );
  }

  /// FIX 31: host banner — the real scope photo when the parent
  /// passes one, else the code's asset path (missing file ->
  /// graceful empty banner, as sent).
  Widget _bannerImage() {
    final url = widget.hostBannerAssetOrUrl;
    if (url != null && url.isNotEmpty) {
      if (url.startsWith('http')) {
        return Image.network(
          url,
          fit: BoxFit.cover,
          alignment: Alignment.centerRight,
          errorBuilder: (_, __, ___) => const SizedBox.shrink(),
        );
      }
      return Image.asset(
        url,
        fit: BoxFit.cover,
        alignment: Alignment.centerRight,
        errorBuilder: (_, __, ___) => const SizedBox.shrink(),
      );
    }
    return Image.asset(
      'assets/images/arena_host_banner.png',
      fit: BoxFit.cover,
      alignment: Alignment.centerRight,
      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
    );
  }

  /// FIX 31: seat avatar — URL (NetworkImage) or asset path,
  /// initial-letter fallback on failure (as sent).
  Widget _seatAvatarImage(VoiceSeatMember seat) {
    final path = seat.avatarAssetOrUrl!;
    final fallback = Container(
      color: ArenaColors.glassSurface,
      alignment: Alignment.center,
      child: Text(
          seat.name?.isNotEmpty == true ? seat.name![0] : 'M',
          style: ArenaTypography.heading(16)),
    );
    if (path.startsWith('http')) {
      return Image.network(path,
          fit: BoxFit.cover, errorBuilder: (_, __, ___) => fallback);
    }
    return Image.asset(path,
        fit: BoxFit.cover, errorBuilder: (_, __, ___) => fallback);
  }

  Widget _buildTopHeader() {
    // FIX 31 (Sameer 01:50 voice call): NO back arrow, NO
    // three-dots. Top line = the full "Arena Hub Voice Chat
    // Room" title + the real players count (badge on the people
    // icon) up top. The share button is GONE too — it had an
    // empty onTap and no real share function exists in the room.
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      // PHASE E (E4): the header bar is transparent now (was a
      // 0.78 dark band) — the room background shows through;
      // the purple bottom divider stays.
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: ArenaColors.purple.withValues(alpha: 0.35)),
        ),
      ),
      child: Row(
        children: [
          const Icon(LucideIcons.crown, color: ArenaColors.royalGold, size: 24),
          const SizedBox(width: 8),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: 'ARENA HUB ', style: ArenaTypography.orbitron(13)),
                  TextSpan(
                      text: 'VOICE CHAT ROOM',
                      style: ArenaTypography.orbitron(13, color: ArenaColors.royalGold)),
                ],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          Stack(
            clipBehavior: Clip.none,
            children: [
              _circleIconButton(icon: LucideIcons.usersRound, onTap: widget.onUsersTap ?? () {}),
              Positioned(
                top: -3,
                right: -3,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: ArenaColors.liveRed,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: ArenaColors.primaryBg, width: 1.5),
                  ),
                  child: Text(
                    _compactCount(widget.playersCount),
                    style: ArenaTypography.body(9, weight: FontWeight.w700),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _circleIconButton({required IconData icon, required VoidCallback onTap}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: ArenaColors.cardBg.withValues(alpha: kCardFillOpacity),
          shape: BoxShape.circle,
          border: Border.all(color: ArenaColors.purple.withValues(alpha: 0.65), width: 1.3),
        ),
        child: Icon(icon, color: Colors.white, size: 18),
      ),
    );
  }

  Widget _buildHostProfileCard() {
    final seated = _seats.where((s) => s.isOccupied).length;
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: Container(
        decoration: BoxDecoration(
          color: ArenaColors.cardBg.withValues(alpha: kCardFillOpacity),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: ArenaColors.royalGold.withValues(alpha: 0.75), width: 1.4),
          boxShadow: [
            BoxShadow(
              color: ArenaColors.purple.withValues(alpha: 0.30),
              blurRadius: 16,
            ),
          ],
        ),
        child: Stack(
          children: [
            // FIX 31: the real scope photo (community/team/
            // tournament banner) when the parent passes one;
            // otherwise the code's asset path (missing file ->
            // graceful empty banner, as sent).
            Positioned.fill(
              child: _bannerImage(),
            ),
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      const Color(0xFF0A071C).withValues(alpha: 0.94),
                      const Color(0xFF15102B).withValues(alpha: 0.76),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 14, 12, 12),
              child: Row(
                children: [
                  // Host Avatar + Crown + Online Dot
                  Stack(
                    clipBehavior: Clip.none,
                    alignment: Alignment.center,
                    children: [
                      // FIX 31 (item 17): no host on voice -> an
                      // EMPTY circle (no face, no crown, no dot).
                      if (!widget.hostPresent)
                        Container(
                          width: 62,
                          height: 62,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: ArenaColors.glassSurface,
                            border: Border.all(
                                color: ArenaColors.purple.withValues(alpha: 0.5), width: 1.5),
                          ),
                        )
                      else
                        Container(
                          width: 62,
                          height: 62,
                          padding: const EdgeInsets.all(2.5),
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: LinearGradient(
                              colors: [ArenaColors.royalGold, ArenaColors.electricBlue],
                            ),
                          ),
                          child: ClipOval(
                            child: _avatarImage(widget.hostAvatar),
                          ),
                        ),
                      if (widget.hostPresent)
                        const Positioned(
                          top: -12,
                          child: Icon(LucideIcons.crown,
                              color: ArenaColors.royalGold, size: 22),
                        ),
                      if (widget.hostPresent)
                        Positioned(
                          bottom: 0,
                          right: 0,
                          child: Container(
                            width: 14,
                            height: 14,
                            decoration: BoxDecoration(
                              color: ArenaColors.connectedGreen,
                              shape: BoxShape.circle,
                              border: Border.all(color: ArenaColors.primaryBg, width: 2),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(width: 12),
                  // Center Details
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: ArenaColors.royalGold,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(LucideIcons.crown,
                                  size: 11, color: ArenaColors.primaryBg),
                              const SizedBox(width: 4),
                              Text('Host',
                                  style: ArenaTypography.body(10,
                                      color: ArenaColors.primaryBg, weight: FontWeight.w800)),
                            ],
                          ),
                        ),
                        const SizedBox(height: 3),
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                // FIX 31 (item 17): offline host
                                // reads "No host", never a name.
                                widget.hostPresent ? widget.hostName : 'No host',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: ArenaTypography.heading(19),
                              ),
                            ),
                            if (widget.hostPresent && widget.hostVerified) ...[
                              const SizedBox(width: 4),
                              const Icon(LucideIcons.badgeCheck,
                                  size: 16, color: ArenaColors.electricBlue),
                            ],
                          ],
                        ),
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                widget.roomTitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: ArenaTypography.body(12,
                                    color: ArenaColors.secondaryText),
                              ),
                            ),
                            const SizedBox(width: 4),
                            const Icon(LucideIcons.headphones,
                                size: 13, color: ArenaColors.electricBlue),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            const Icon(LucideIcons.usersRound,
                                size: 12, color: ArenaColors.royalGold),
                            const SizedBox(width: 4),
                            // FIX 31: no "Members" word (fix23
                            // item 12) — "N Seated"; the online
                            // count is the real players count.
                            // FIX 31: Flexible + ellipsis — this row
                            // overflowed 27px on a 360px phone.
                            Flexible(
                              child: Text('$seated Seated',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: ArenaTypography.body(11,
                                      weight: FontWeight.w600)),
                            ),
                            const SizedBox(width: 8),
                            Container(
                              width: 6,
                              height: 6,
                              decoration: const BoxDecoration(
                                color: ArenaColors.connectedGreen,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 4),
                            Flexible(
                              child: Text(
                                  '${_compactCount(widget.playersCount)} Online',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: ArenaTypography.body(11,
                                      weight: FontWeight.w600)),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  // FIX 31 (Sameer 01:50): ONE menu button in the
                  // host card — opens the menu screen with ALL
                  // functions (the header three-dots is gone).
                  _circleIconButton(icon: LucideIcons.menu, onTap: _openMoreBottomSheet),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVoiceStage() {
    final active = _isMicOn && _connectionStatus == VoiceConnectionStatus.connected;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      decoration: BoxDecoration(
        color: ArenaColors.cardBg.withValues(alpha: kCardFillOpacity),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: ArenaColors.purple.withValues(alpha: 0.65), width: 1.4),
      ),
      child: Row(
        children: [
          // LEFT STATUS COLUMN
          Expanded(
            child: Column(
              children: [
                _statusChip(
                  icon: LucideIcons.radio,
                  label: _isLive ? 'LIVE' : 'OFF',
                  iconColor: _isLive ? ArenaColors.liveRed : ArenaColors.secondaryText,
                  borderColor:
                      _isLive ? ArenaColors.liveRed : ArenaColors.purple.withValues(alpha: 0.5),
                ),
                const SizedBox(height: 6),
                _statusChip(
                  icon: LucideIcons.clock,
                  label: _formatDuration(_durationSeconds),
                  iconColor: ArenaColors.electricBlue,
                  borderColor: ArenaColors.purple.withValues(alpha: 0.55),
                ),
                const SizedBox(height: 6),
                GestureDetector(
                  onTap: _toggleMic,
                  child: _statusChip(
                    icon: active ? LucideIcons.mic : LucideIcons.micOff,
                    label: active ? 'Mic On' : 'Mic Off',
                    iconColor: active ? ArenaColors.electricBlue : ArenaColors.liveRed,
                    borderColor:
                        active ? ArenaColors.electricBlue : ArenaColors.liveRed,
                  ),
                ),
              ],
            ),
          ),

          // CENTERPIECE MICROPHONE STAGE
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Column(
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CustomPaint(
                      size: const Size(34, 42),
                      painter: MicWingPainter(active: active),
                    ),
                    GestureDetector(
                      onTap: _toggleMic,
                      child: AnimatedBuilder(
                        animation: _pulseController,
                        builder: (_, child) {
                          final glowAlpha = active ? 0.35 + (_pulseController.value * 0.25) : 0.12;
                          return Container(
                            width: 82,
                            height: 82,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: const RadialGradient(
                                colors: [Color(0xFF4D1D95), Color(0xFF140B2E)],
                              ),
                              border: Border.all(
                                color: active ? ArenaColors.royalGold : ArenaColors.purple,
                                width: 2.6,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: ArenaColors.royalGold.withValues(alpha: glowAlpha),
                                  blurRadius: 18,
                                ),
                              ],
                            ),
                            child: Container(
                              margin: const EdgeInsets.all(4),
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: active
                                      ? ArenaColors.electricBlue
                                      : ArenaColors.purple.withValues(alpha: 0.4),
                                  width: 1.5,
                                ),
                              ),
                              child: Icon(
                                active ? LucideIcons.mic : LucideIcons.micOff,
                                color: Colors.white,
                                size: 32,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    CustomPaint(
                      size: const Size(34, 42),
                      painter: MicWingPainter(flipRight: true, active: active),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                GestureDetector(
                  onTap: _toggleMic,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFF331D05), Color(0xFF543207), Color(0xFF331D05)],
                      ),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: ArenaColors.royalGold, width: 1.4),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          active ? LucideIcons.audioLines : LucideIcons.hand,
                          size: 14,
                          color: ArenaColors.royalGold,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          active ? 'Speaking Live' : 'Tap to Speak',
                          style: ArenaTypography.heading(13, color: ArenaColors.royalGold),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),

          // RIGHT STATUS COLUMN
          Expanded(
            child: Column(
              children: [
                GestureDetector(
                  // FIX 31: locked-on (fix22 item 7) = display only.
                  onTap: widget.lockVoiceOutputOn ? null : _toggleVoice,
                  child: _statusChip(
                    icon: _isVoiceOn ? LucideIcons.volume2 : LucideIcons.volumeX,
                    label: _isVoiceOn ? 'Voice On' : 'Voice Off',
                    iconColor: _isVoiceOn ? ArenaColors.connectedGreen : ArenaColors.liveRed,
                    borderColor:
                        _isVoiceOn ? ArenaColors.connectedGreen : ArenaColors.liveRed,
                  ),
                ),
                const SizedBox(height: 8),
                _statusChip(
                  icon: _connectionStatus == VoiceConnectionStatus.connected
                      ? LucideIcons.badgeCheck
                      : LucideIcons.wifiOff,
                  label: _connectionStatus == VoiceConnectionStatus.connected
                      ? 'Connected'
                      : 'Offline',
                  iconColor: _connectionStatus == VoiceConnectionStatus.connected
                      ? ArenaColors.connectedGreen
                      : ArenaColors.liveRed,
                  borderColor: _connectionStatus == VoiceConnectionStatus.connected
                      ? ArenaColors.connectedGreen
                      : ArenaColors.liveRed,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusChip({
    required IconData icon,
    required String label,
    required Color iconColor,
    required Color borderColor,
  }) {
    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: ArenaColors.secondaryBg.withValues(alpha: 0.88),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: borderColor.withValues(alpha: 0.7)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 13, color: iconColor),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: ArenaTypography.body(11, weight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSeatsPodiumCard() {
    final occupiedCount = _seats.where((s) => s.isOccupied).length;
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: Container(
        decoration: BoxDecoration(
          color: ArenaColors.cardBg.withValues(alpha: kCardFillOpacity),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: ArenaColors.purple.withValues(alpha: 0.7), width: 1.4),
        ),
        child: Column(
          children: [
            // Cyber-Notched Header
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // FIX 31: Flexible + ellipsis — the two notch chips
                // overflow a 360px phone otherwise (test font: 96px).
                Flexible(
                  child: ClipPath(
                    clipper: LeftCyberNotchClipper(),
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(12, 7, 24, 7),
                      color: const Color(0xFF281456),
                      child: Row(
                        children: [
                          const Icon(LucideIcons.usersRound,
                              size: 16, color: ArenaColors.neonPink),
                          const SizedBox(width: 6),
                          // FIX 31: no "Members" word (fix23 item 12).
                          Flexible(
                            child: Text('Voice Seats ($occupiedCount)',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: ArenaTypography.heading(16)),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                ClipPath(
                  clipper: RightCyberNotchClipper(),
                  child: InkWell(
                    onTap: widget.onViewAll ?? () {},
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(22, 7, 12, 7),
                      color: const Color(0xFF281C08),
                      child: Row(
                        children: [
                          Text('View All',
                              style: ArenaTypography.heading(13, color: ArenaColors.royalGold)),
                          const SizedBox(width: 3),
                          const Icon(LucideIcons.chevronRight,
                              size: 14, color: ArenaColors.royalGold),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),

            // 3x2 Podium Grid
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 12, 8, 10),
              child: GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: 6,
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                  childAspectRatio: 1.02,
                ),
                itemBuilder: (_, index) => _buildSeatTile(_seats[index]),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSeatTile(VoiceSeatMember seat) {
    final frameColor = seat.isHost
        ? ArenaColors.royalGold
        : (seat.isSpeaking && !seat.isMuted)
            ? ArenaColors.neonPink
            : ArenaColors.electricBlue;

    return GestureDetector(
      onTap: () {
        setState(() => _selectedSeatNumber = seat.seatNumber);
        widget.onSeatTap?.call(seat);
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              Container(
                width: 52,
                height: 52,
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: _selectedSeatNumber == seat.seatNumber
                        ? ArenaColors.royalGold
                        : frameColor,
                    width: 2.2,
                  ),
                ),
                child: ClipOval(
                  child: seat.isOccupied && seat.avatarAssetOrUrl != null
                      ? _seatAvatarImage(seat)
                      : Container(
                          color: ArenaColors.secondaryBg,
                          child: const Icon(LucideIcons.plus,
                              color: ArenaColors.electricBlue, size: 20),
                        ),
                ),
              ),
              if (seat.isHost)
                const Positioned(
                  top: -10,
                  child: Icon(LucideIcons.crown, size: 17, color: ArenaColors.royalGold),
                ),
              if (seat.isOccupied)
                Positioned(
                  bottom: -1,
                  right: -1,
                  child: Container(
                    width: 18,
                    height: 18,
                    decoration: BoxDecoration(
                      color: seat.isMuted
                          ? const Color(0xFFD69E00)
                          : ArenaColors.connectedGreen,
                      shape: BoxShape.circle,
                      border: Border.all(color: ArenaColors.primaryBg, width: 1.5),
                    ),
                    child: Icon(
                      seat.isMuted ? LucideIcons.micOff : LucideIcons.mic,
                      size: 10,
                      color: ArenaColors.primaryBg,
                    ),
                  ),
                ),
            ],
          ),
          CustomPaint(
            size: const Size(86, 16),
            painter: PodiumDiscPainter(
              outerColor: frameColor,
              active: seat.isSpeaking && !seat.isMuted,
            ),
          ),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: ArenaColors.secondaryBg.withValues(alpha: 0.92),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: frameColor.withValues(alpha: 0.7)),
            ),
            child: Text(
              seat.name ?? 'Tap to Join',
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: ArenaTypography.body(10.5, weight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChatPanel() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: Container(
        decoration: BoxDecoration(
          color: ArenaColors.secondaryBg.withValues(alpha: 0.88),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: ArenaColors.purple.withValues(alpha: 0.7), width: 1.4),
        ),
        child: Column(
          children: [
            // Chat Header
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // FIX 31: Flexible + ellipsis — same narrow-phone guard
                // as the podium header (test font: 17px overflow).
                Flexible(
                  child: ClipPath(
                    clipper: LeftCyberNotchClipper(),
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(12, 6, 22, 6),
                      color: const Color(0xFF281456),
                      child: Row(
                        children: [
                          const Icon(LucideIcons.messageCircle,
                              size: 15, color: ArenaColors.electricBlue),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text('Chat Messages',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: ArenaTypography.heading(15.5)),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                ClipPath(
                  clipper: RightCyberNotchClipper(),
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(18, 6, 12, 6),
                    color: const Color(0xFF24163E),
                    child: Text('${_compactCount(widget.playersCount)} Online',
                        style: ArenaTypography.body(11,
                            color: ArenaColors.royalGold, weight: FontWeight.w700)),
                  ),
                ),
              ],
            ),

            // Scrollable Messages
            Expanded(
              child: _messages.isEmpty
                  // FIX 31: empty chat state (same copy as the old
                  // room) instead of a blank panel.
                  ? Center(
                      child: Text(
                        'No messages yet. Say hi!',
                        style: ArenaTypography.body(13,
                            color: ArenaColors.secondaryText,
                            weight: FontWeight.w600),
                      ),
                    )
                  : ListView.separated(
                      controller: _chatScrollController,
                      padding: const EdgeInsets.all(10),
                      itemCount: _messages.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (_, index) => _buildMessageRow(_messages[index]),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMessageRow(ArenaChatMessage msg) {
    if (msg.isAnnouncement) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFF23154A), Color(0xFF341B69), Color(0xFF23154A)],
          ),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: ArenaColors.royalGold.withValues(alpha: 0.65)),
        ),
        child: Text(
          msg.text,
          textAlign: TextAlign.center,
          style: ArenaTypography.body(12.5, weight: FontWeight.w600),
        ),
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: msg.isOwn ? MainAxisAlignment.end : MainAxisAlignment.start,
      children: [
        if (!msg.isOwn) ...[
          CircleAvatar(
            radius: 15,
            backgroundColor: ArenaColors.purple,
            child: Text(msg.initials, style: ArenaTypography.body(11, weight: FontWeight.w700)),
          ),
          const SizedBox(width: 8),
        ],
        Flexible(
          child: Column(
            crossAxisAlignment:
                msg.isOwn ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: [
              Text(
                '${msg.senderName}  ${msg.timestamp}',
                style: ArenaTypography.body(10.5, color: ArenaColors.secondaryText),
              ),
              const SizedBox(height: 3),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                decoration: BoxDecoration(
                  color: msg.isOwn ? const Color(0xFF2D1959) : const Color(0xFF1D183B),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: (msg.isOwn ? ArenaColors.royalGold : ArenaColors.purple)
                        .withValues(alpha: 0.5),
                  ),
                ),
                child: Text(msg.text, style: ArenaTypography.body(13.5)),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildMessageComposer() {
    // FIX 31: emoji strip (same ArenaEmojis set as the old room)
    // toggled by the smile button; the gift button is GONE (no
    // gift economy — removed by user order 2026-10-30); the image
    // button sends a photo via the parent's onImageTap.
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_showEmojiStrip)
          Container(
            height: 48,
            decoration: BoxDecoration(
              color: ArenaColors.cardBg,
              border: Border(top: BorderSide(color: ArenaColors.purple.withValues(alpha: 0.35))),
            ),
            child: Row(
              children: [
                Expanded(
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    itemCount: ArenaEmojis.all.length,
                    itemBuilder: (_, i) => InkWell(
                      onTap: () =>
                          insertEmojiAtCursor(_msgController, ArenaEmojis.all[i]),
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          child: Text(ArenaEmojis.all[i],
                              style: const TextStyle(fontSize: 20)),
                        ),
                      ),
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close,
                      color: ArenaColors.secondaryText, size: 18),
                  onPressed: () => setState(() => _showEmojiStrip = false),
                ),
              ],
            ),
          ),
        Container(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
          decoration: BoxDecoration(
            color: ArenaColors.primaryBg.withValues(alpha: 0.92),
            border: Border(top: BorderSide(color: ArenaColors.purple.withValues(alpha: 0.35))),
          ),
          child: Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: const Color(0xFF100C24),
              borderRadius: BorderRadius.circular(30),
              border: Border.all(color: ArenaColors.purple.withValues(alpha: 0.8), width: 1.4),
            ),
            child: Row(
              children: [
                _circleIconButton(
                    icon: LucideIcons.smile,
                    onTap: () => setState(() => _showEmojiStrip = !_showEmojiStrip)),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _msgController,
                    style: ArenaTypography.body(14),
                    onSubmitted: (_) => _sendChat(),
                    decoration: InputDecoration(
                      hintText: 'Type a message...',
                      hintStyle: ArenaTypography.body(14, color: ArenaColors.secondaryText),
                      border: InputBorder.none,
                      isDense: true,
                    ),
                  ),
                ),
                _circleIconButton(icon: LucideIcons.image, onTap: widget.onImageTap ?? () {}),
                const SizedBox(width: 6),
                GestureDetector(
                  onTap: _sendChat,
                  child: Container(
                    width: 42,
                    height: 42,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        colors: [Color(0xFFFFF08A), ArenaColors.royalGold, Color(0xFFE68A00)],
                      ),
                    ),
                    child: const Icon(LucideIcons.send, color: ArenaColors.primaryBg, size: 18),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _MoreActionsSheet extends StatelessWidget {
  final VoidCallback onFollowers;
  final VoidCallback onMusic;
  final VoidCallback onRjPanel;
  final VoidCallback onSettings;
  final VoidCallback onLeaveRoom;
  // FIX 31: Followers count + Follow pill, host-gated RJ row,
  // extra menu rows (Power, Voice, Invite, Follow Host, Leave
  // Voice, ...) — all wired by the parent to the real functions.
  final String? followersCountLabel;
  final bool? followState;
  final bool followBusy;
  final VoidCallback? onFollowToggle;
  final bool showRjPanel;
  // PHASE E (E28): Music is host-only — false hides the row.
  final bool showMusic;
  final List<ArenaMenuEntry> menuExtras;

  const _MoreActionsSheet({
    required this.onFollowers,
    required this.onMusic,
    required this.onRjPanel,
    required this.onSettings,
    required this.onLeaveRoom,
    this.followersCountLabel,
    this.followState,
    this.followBusy = false,
    this.onFollowToggle,
    this.showRjPanel = true,
    this.showMusic = true,
    this.menuExtras = const [],
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          decoration: BoxDecoration(
            color: ArenaColors.cardBg.withValues(alpha: 0.96),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            border: Border.all(color: ArenaColors.purple.withValues(alpha: 0.65)),
          ),
          child: SafeArea(
            top: false,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.85,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 40,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 14),
                      decoration: BoxDecoration(
                        color: Colors.white24,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    // FIX 31: menu header — the sheet is the room's
                    // function menu (Sameer 01:50: "sab kuch us ke
                    // andar ho").
                    Row(
                      children: [
                        const Icon(LucideIcons.menu, color: ArenaColors.royalGold, size: 20),
                        const SizedBox(width: 8),
                        Text('Room Menu', style: ArenaTypography.heading(18)),
                      ],
                    ),
                    const SizedBox(height: 12),
                    _sheetItem(LucideIcons.usersRound, 'Followers', ArenaColors.electricBlue, onFollowers,
                        subtitle: followersCountLabel, trailing: _followPill()),
                    if (showMusic)
                      _sheetItem(LucideIcons.music2, 'Music', ArenaColors.royalGold, onMusic),
                    if (showRjPanel)
                      _sheetItem(LucideIcons.audioLines, 'RJ Panel', ArenaColors.neonPink, onRjPanel),
                    _sheetItem(LucideIcons.settings, 'Settings', ArenaColors.royalGold, onSettings),
                    for (final e in menuExtras)
                      if (e.visible)
                        _sheetItem(e.icon, e.label, e.color, () {
                          Navigator.pop(context);
                          e.onTap?.call();
                        }, subtitle: e.subtitle),
                    const SizedBox(height: 4),
                    Container(height: 1, color: ArenaColors.purple.withValues(alpha: 0.4)),
                    const SizedBox(height: 12),
                    _sheetItem(LucideIcons.logOut, 'Leave Room', ArenaColors.liveRed, onLeaveRoom),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// FIX 31 (item 9): the Follow pill on the Followers row —
  /// gold Follow / dark Following / gold JOINED (creator, no tap);
  /// absent when the parent passes no follow state (team scope).
  Widget? _followPill() {
    final state = followState;
    if (state == null && onFollowToggle == null) return null;
    final label = state == null ? 'JOINED' : (state ? 'Following' : 'Follow');
    final pill = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: state == true ? ArenaColors.glassSurface : ArenaColors.royalGold,
        borderRadius: BorderRadius.circular(12),
        border: state == true
            ? Border.all(color: ArenaColors.royalGold.withValues(alpha: 0.6))
            : null,
      ),
      child: Text(label,
          style: ArenaTypography.body(10,
              color: state == true ? ArenaColors.royalGold : ArenaColors.primaryBg,
              weight: FontWeight.w800)),
    );
    // Creator (null state): JOINED, never tappable. Busy: dimmed.
    if (state == null || followBusy || onFollowToggle == null) {
      return followBusy ? Opacity(opacity: 0.5, child: pill) : pill;
    }
    return InkWell(
      onTap: onFollowToggle,
      borderRadius: BorderRadius.circular(12),
      child: pill,
    );
  }

  Widget _sheetItem(IconData icon, String title, Color color, VoidCallback onTap,
      {String? subtitle, Widget? trailing}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      // FIX 31: the sheet container is a DecoratedBox with a background
      // colour; a bare ListTile under it asserts (tile colour / ink
      // invisible). Its own Material ancestor fixes it.
      child: Material(
        color: Colors.transparent,
        clipBehavior: Clip.antiAlias,
        borderRadius: BorderRadius.circular(16),
        child: ListTile(
          onTap: onTap,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: ArenaColors.purple.withValues(alpha: 0.45)),
          ),
          tileColor: ArenaColors.glassSurface,
          leading: Icon(icon, color: color),
          title: Text(title, style: ArenaTypography.heading(17)),
          subtitle: subtitle == null
              ? null
              : Text(subtitle,
                  style: ArenaTypography.body(11, color: ArenaColors.secondaryText)),
          trailing: trailing ??
              const Icon(LucideIcons.chevronRight, color: ArenaColors.secondaryText),
        ),
      ),
    );
  }
}