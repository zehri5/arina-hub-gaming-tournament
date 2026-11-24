import 'package:flutter/material.dart';

import '../services/supabase_db.dart';
import '../theme.dart';
import 'cached_image.dart';

/// MOCKUP-#27 SHARED CHAT (2026-11-21, chat-unify lane — user order:
/// ONE design in EVERY chat, printer-copy of mockup #27
/// `721593009_1795037749085535.jpg`).
///
/// The mockup is the user's own UI design — copy it without
/// hesitation. Data is ALWAYS real; the mockup's sample names,
/// counts, messages and times are layout-only, never data.
///
/// What the mockup shows, and what this file owns:
/// * [ArenaChatHeader] — back + 48px thumb + tournament name white
///   italic + "CHAT" gold + "{players} Players • {online} Online" +
///   green dot + Members (people icon) + More (three dots).
/// * [ArenaPinnedBanner] — gold left border + pin icon +
///   "PINNED: {text}" + "View" gold link.
/// * [ArenaChatMessage] — the full message row: other messages have
///   avatar + "Name [SQUAD n] time" header ABOVE a dark bubble,
///   reactions below, flag icon right; own messages are right-aligned
///   with "Name (You) [Lv.n] time" above a gold-tinted gold-border
///   bubble; ORGANIZER messages have the gold crown pill overlapping
///   the bubble top + a gold border + "Admin • time" INSIDE the
///   bubble (no avatar, full width, no flag).
/// * [ArenaChatBubble] — the bubble shell only (no tail — the mockup
///   has none): dark fill + grey border, own = gold-tinted + gold
///   border, organizer/goldBorder = gold border + soft gold glow,
///   highlight (room shout) = gold fill + gold bold text.
/// * [ArenaReactionRow] — 👍👎 chips with counts below a bubble.
/// * [ArenaChatInputBar] — rounded dark field "Type a message..." +
///   emoji + attach icons inside the field + gold round send button.
///
/// Surfaces using it: TeamChatPage (tournament + squad chat),
/// DirectMessagePage (DM), _CommunityChatTab (community chat), and
/// the room chat text bubbles (UnifiedRoomPage._chatItem — bubble
/// shell + pinned banner only; its header row, reply/gift/image/
/// voice logic are untouched by this file).
///
/// The older WhatsApp-style [ChatBubble] (chat_bubble.dart) is NOT
/// changed and stays in use by its existing tests; this file is the
/// mockup-exact design going forward. No word is ever cut: every
/// header row uses Flexible + ellipsis on the name and fixed-size
/// pills/time after it.

/// The ONE built-in emoji set for every chat (P1-7 — no new package).
/// The room's old inline list is the source; every picker/strip below
/// reads this list so the set cannot drift between chats.
class ArenaEmojis {
  static const List<String> all = [
    '😀', '😂', '😍', '😎', '🔥', '👍', '👏', '🙏',
    '🎉', '🏆', '⚡', '💪', '😢', '😡', '🤔', '👀',
    '🎮', '⚔️', '🚀', '⭐', '💯', '❤️', '😱', '🤩',
    '😴', '🤝', '👑', '🎯', '💥', '🫡', '😇', '🤣',
    '😜', '🥳', '😤', '🙌', '✌️', '🤞', '💎', '🌟',
    '🎖️', '🛡️', '🦁', '👻', '🍀', '💰', '🎁', '📣',
  ];
}

/// Insert [emoji] at the text-field cursor (or at the end when there
/// is no valid selection), keeping the caret after the emoji.
void insertEmojiAtCursor(TextEditingController ctrl, String emoji) {
  final text = ctrl.text;
  final sel = ctrl.selection;
  final start = sel.isValid ? sel.start : text.length;
  final end = sel.isValid ? sel.end : text.length;
  final next = text.replaceRange(start, end, emoji);
  ctrl.value = TextEditingValue(
    text: next,
    selection: TextSelection.collapsed(offset: start + emoji.length),
  );
}

/// Mockup #27 clock time ("07:48 PM") for the header row above a
/// bubble — the SAME formatter TeamChat uses (`_fmtClock`), shared
/// here so every chat shows the same time style instead of one chat
/// showing relative ("2h ago") times. [ts] is a `chat_messages`
/// timestamp in any stored form ([SupaDb.parseTs] normalises it);
/// unparseable timestamps render as '' (no time shown).
String formatChatClock(dynamic ts) {
  final ms = SupaDb.parseTs(ts);
  if (ms <= 0) return '';
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
  return '$h:${d.minute.toString().padLeft(2, '0')} ${d.hour >= 12 ? 'PM' : 'AM'}';
}

/// Built-in emoji picker grid (P1-7 — no new package): a compact
/// 8-column grid of [ArenaEmojis.all] that sits above the composer.
/// Tap inserts the emoji into the caller's controller via
/// [onSelected]; the caller hides the picker when sending.
class ArenaEmojiPicker extends StatelessWidget {
  final ValueChanged<String> onSelected;
  const ArenaEmojiPicker({super.key, required this.onSelected});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 216,
      decoration: BoxDecoration(
        color: kCard,
        border: Border(top: BorderSide(color: kBorder)),
      ),
      child: GridView.builder(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 8,
          mainAxisSpacing: 4,
          crossAxisSpacing: 4,
        ),
        itemCount: ArenaEmojis.all.length,
        itemBuilder: (_, i) => InkWell(
          onTap: () => onSelected(ArenaEmojis.all[i]),
          borderRadius: BorderRadius.circular(10),
          child: Center(
            child: Text(
              ArenaEmojis.all[i],
              style: const TextStyle(fontSize: 24),
            ),
          ),
        ),
      ),
    );
  }
}

/// Shared team-invite dialog (P1-8): resolve the invitee by username
/// via [SupaDb.findUserByUsername] and send via
/// [SupaDb.sendTeamInvite] — the same send → inbox → Accept chain the
/// My Team dialog uses, so the invite lands in the invitee's
/// Notifications with working Accept/Reject + push. [memberUids]
/// skips the already-a-member check when empty (callers that do not
/// have the roster loaded); the server still rejects duplicate
/// pending invites with a friendly message. Returns true when the
/// invite was sent.
Future<bool> showChatTeamInviteDialog({
  required BuildContext context,
  required String myUid,
  required String teamId,
  required String teamName,
  required String inviteCode,
}) async {
  final ctrl = TextEditingController();
  String? errorText;
  bool sending = false;
  final sent = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setDialogState) {
        Future<void> send() async {
          final name = ctrl.text.trim().replaceFirst(RegExp(r'^@'), '');
          if (name.isEmpty) {
            setDialogState(() => errorText = 'Username likho (e.g. zehri5).');
            return;
          }
          setDialogState(() {
            sending = true;
            errorText = null;
          });
          final found = await SupaDb.findUserByUsername(name);
          if (found.isEmpty) {
            setDialogState(() {
              sending = false;
              errorText = 'Is username ka koi player nahi mila.';
            });
            return;
          }
          final inviteeUid = SupaDb.strOf(found['firebase_uid']);
          if (inviteeUid.isEmpty) {
            setDialogState(() {
              sending = false;
              errorText = 'Is player ka account nahi mila.';
            });
            return;
          }
          if (inviteeUid == myUid) {
            setDialogState(() {
              sending = false;
              errorText = 'Apne aap ko invite nahi kar sakte.';
            });
            return;
          }
          try {
            final members = await SupaDb.getList('team_members',
                eqCol: 'team_id', eqVal: teamId, eqCol2: 'firebase_uid', eqVal2: inviteeUid, limit: 1);
            if (members.isNotEmpty) {
              setDialogState(() {
                sending = false;
                errorText = 'Ye player pehle se team mein hai.';
              });
              return;
            }
          } catch (_) {
            // Membership check is best-effort; the invite itself is
            // still guarded server-side (duplicate / RLS).
          }
          final res = await SupaDb.sendTeamInvite(
            teamId: teamId,
            teamName: teamName.isEmpty ? 'Your team' : teamName,
            invitedUid: inviteeUid,
            inviterUid: myUid,
            inviteCode: inviteCode,
          );
          if (!context.mounted) return;
          if (res['ok'] == true) {
            Navigator.pop(context, true);
          } else {
            setDialogState(() {
              sending = false;
              errorText = SupaDb.strOf(res['error'], 'Invite nahi bheji ja saki.');
            });
          }
        }

        return AlertDialog(
          backgroundColor: kCardPurpleMid,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22), side: const BorderSide(color: kCardPurpleBorder, width: 1.5)),
          title: Text('Invite Player', style: TextStyle(color: kGold)),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Player ka username likho — usko app mein Team Invitation milegi, Accept/Decline ke saath.',
                  style: TextStyle(color: kMuted, fontSize: 13),
                ),
                const SizedBox(height: 12),
                // FIX 23 item 29: card look via CardFieldShell.
                CardFieldShell(
                  child: TextField(
                  controller: ctrl,
                  style: TextStyle(color: kText),
                  textCapitalization: TextCapitalization.none,
                  decoration: InputDecoration(
                    labelText: 'Username (e.g. zehri5)',
                    labelStyle: TextStyle(color: kMuted),
                    border: const OutlineInputBorder(borderSide: BorderSide.none),
                    enabledBorder: const OutlineInputBorder(borderSide: BorderSide.none),
                    focusedBorder: const OutlineInputBorder(borderSide: BorderSide.none),
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  ),
                  onSubmitted: (_) {
                    if (!sending) send();
                  },
                ),
                ),
                if (errorText != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    errorText!,
                    style: const TextStyle(color: Colors.redAccent, fontSize: 13),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: sending ? null : () => Navigator.pop(context, false),
              child: Text('Cancel', style: TextStyle(color: kMuted)),
            ),
            TextButton(
              onPressed: sending ? null : send,
              child: sending
                  ? SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: kGold))
                  : Text('Send Invite', style: TextStyle(color: kGold)),
            ),
          ],
        );
      },
    ),
  );
  ctrl.dispose();
  return sent == true;
}

/// One entry of the header's More menu.
class ArenaChatMenuItem {
  final String value;
  final String label;
  const ArenaChatMenuItem(this.value, this.label);
}

/// Mockup #27 header: back + thumb + "NAME CHAT" + counts + green
/// dot + Members + More. Members/More hide when their callbacks are
/// null (DM has neither).
class ArenaChatHeader extends StatelessWidget {
  final VoidCallback onBack;
  final String thumbnailUrl;
  final String titleName;
  final String subtitle;
  final VoidCallback? onMembers;
  final String membersLabel;
  // FIX 3 (2026-11-22): the Members button's toggle state — true
  // while the inline online-in-room list is open (gold/active
  // look, same as voiceActive for the Voice button).
  final bool membersActive;
  // v2016 FIX 11(b): optional Voice circle button (team chat only —
  // toggles the inline voice panel, v2017). Null = no button
  // (DMs, tournaments).
  final VoidCallback? onVoice;
  // v2017 INLINE VOICE: the Voice button's toggle state — true
  // while the inline voice panel is open (gold/active look).
  final bool voiceActive;
  // FIX 16 (2026-11-23): optional Settings button — when set it
  // REPLACES the More popup (team chat while the voice panel is
  // open): gear icon + 'Settings' label, opens the voice settings
  // sheet (music / settings / RJ / close voice). Null = the More
  // popup as before (panel closed, DMs, tournaments).
  final VoidCallback? onSettings;
  final bool settingsActive;
  final List<ArenaChatMenuItem> moreItems;
  final ValueChanged<String>? onMoreSelected;

  const ArenaChatHeader({
    super.key,
    required this.onBack,
    this.thumbnailUrl = '',
    required this.titleName,
    this.subtitle = '',
    this.onMembers,
    this.membersLabel = 'Members',
    this.membersActive = false,
    this.onVoice,
    this.voiceActive = false,
    this.onSettings,
    this.settingsActive = false,
    this.moreItems = const [],
    this.onMoreSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 12, 8),
      child: Row(
        children: [
          IconButton(
            icon: Icon(Icons.arrow_back, color: kText, size: 26),
            onPressed: onBack,
          ),
          if (thumbnailUrl.isNotEmpty)
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: ArenaCachedImage(
                imageUrl: thumbnailUrl,
                width: 48,
                height: 48,
                fit: BoxFit.cover,
                placeholderIcon: Icons.shield,
              ),
            )
          else
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: kGold.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: kGold),
              ),
              child: Icon(Icons.shield, color: kGold, size: 28),
            ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                RichText(
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  text: TextSpan(
                    style: const TextStyle(
                      fontStyle: FontStyle.italic,
                      fontWeight: FontWeight.w900,
                      fontSize: 17,
                      letterSpacing: 0.3,
                    ),
                    children: [
                      TextSpan(text: '$titleName ', style: TextStyle(color: kText)),
                      TextSpan(text: 'CHAT', style: TextStyle(color: kGold)),
                    ],
                  ),
                ),
                if (subtitle.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          subtitle,
                          style: TextStyle(color: kMuted, fontSize: 12),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 5),
                      Container(
                        width: 8,
                        height: 8,
                        decoration: const BoxDecoration(
                          color: Colors.green,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          if (onMembers != null) ...[
            _HeaderCircleButton(
              icon: Icons.group,
              label: membersLabel,
              onTap: onMembers!,
              // FIX 3: gold/active while the online list is open.
              selected: membersActive,
            ),
            const SizedBox(width: 10),
          ],
          if (onVoice != null) ...[
            _HeaderCircleButton(
              icon: Icons.headset_mic,
              label: 'Voice',
              onTap: onVoice!,
              // v2017 INLINE VOICE: gold/active while the inline
              // voice panel is open.
              selected: voiceActive,
            ),
            const SizedBox(width: 10),
          ],
          // FIX 16: Settings REPLACES More while the voice panel is
          // open (onSettings set) — otherwise the More popup.
          if (onSettings != null)
            _HeaderCircleButton(
              icon: Icons.settings,
              label: 'Settings',
              onTap: onSettings!,
              selected: settingsActive,
            )
          else if (moreItems.isNotEmpty)
            PopupMenuButton<String>(
              color: kCard,
              onSelected: onMoreSelected,
              itemBuilder: (_) => [
                for (final item in moreItems)
                  PopupMenuItem(
                    value: item.value,
                    child: Text(item.label, style: TextStyle(color: kText)),
                  ),
              ],
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: kCard,
                      border: Border.all(color: kBorder),
                    ),
                    child: Icon(Icons.more_horiz, color: kText, size: 22),
                  ),
                  const SizedBox(height: 2),
                  Text('More', style: TextStyle(color: kText, fontSize: 11)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _HeaderCircleButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  // v2017 INLINE VOICE: selected = gold-filled circle + gold
  // glow (the Voice button while voice is ON).
  // PHASE E (E24, CORRECTED 2026-11-24): the selected circle is
  // gold-filled again (Sameer: "click pe yellow hona chahiye");
  // the rest state is the card fill — never black.
  final bool selected;
  const _HeaderCircleButton({required this.icon, required this.label, required this.onTap, this.selected = false});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: selected ? kGold : kCardFillColor,
              border: Border.all(color: selected ? kGold : kBorder),
              boxShadow: selected ? [BoxShadow(color: kGold.withValues(alpha: 0.4), blurRadius: 10, spreadRadius: 1)] : null,
            ),
            child: Icon(icon, color: selected ? Colors.black : kText, size: 22),
          ),
          const SizedBox(height: 2),
          Text(label, style: TextStyle(color: selected ? kGold : kText, fontSize: 11, fontWeight: selected ? FontWeight.w800 : FontWeight.normal)),
        ],
      ),
    );
  }
}

/// Mockup #27 pinned banner: gold left border, pin icon,
/// "PINNED: {message}" (the mockup's own phrase "Check lobby" renders
/// gold inside the white sentence; any other text stays plain white),
/// "View" gold link right.
class ArenaPinnedBanner extends StatelessWidget {
  final String message;
  final VoidCallback onView;
  const ArenaPinnedBanner({super.key, required this.message, required this.onView});

  List<TextSpan> _messageSpans(String msg) {
    const phrase = 'Check lobby';
    final idx = msg.toLowerCase().indexOf(phrase.toLowerCase());
    if (idx < 0) {
      return [TextSpan(text: msg, style: TextStyle(color: kText, fontSize: 13))];
    }
    return [
      if (idx > 0) TextSpan(text: msg.substring(0, idx), style: TextStyle(color: kText, fontSize: 13)),
      TextSpan(
        text: msg.substring(idx, idx + phrase.length),
        style: TextStyle(color: kGold, fontWeight: FontWeight.bold, fontSize: 13),
      ),
      if (idx + phrase.length < msg.length)
        TextSpan(text: msg.substring(idx + phrase.length), style: TextStyle(color: kText, fontSize: 13)),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 10, 14, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: kGold.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border(left: BorderSide(color: kGold, width: 4)),
      ),
      child: Row(
        children: [
          Icon(Icons.push_pin, color: kGold, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: RichText(
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              text: TextSpan(
                children: [
                  TextSpan(
                    text: 'PINNED: ',
                    style: TextStyle(color: kGold, fontWeight: FontWeight.bold, fontSize: 13),
                  ),
                  ..._messageSpans(message),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: onView,
            child: Text(
              'View',
              style: TextStyle(color: kGold, fontWeight: FontWeight.bold, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

/// Flat gold crown (mockup #27 ORGANIZER pill). Same flat path the
/// leaderboard crown uses — no glow, no trophy.
class _ArenaCrownPainter extends CustomPainter {
  final Color color;
  _ArenaCrownPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final paint = Paint()..color = color;
    final path = Path()
      ..moveTo(0, h * 0.95)
      ..lineTo(0, h * 0.45)
      ..lineTo(w * 0.22, h * 0.68)
      ..lineTo(w * 0.5, h * 0.08)
      ..lineTo(w * 0.78, h * 0.68)
      ..lineTo(w, h * 0.45)
      ..lineTo(w, h * 0.95)
      ..close();
    canvas.drawPath(path, paint);
    canvas.drawRect(Rect.fromLTWH(0, h * 0.8, w, h * 0.17), paint);
  }

  @override
  bool shouldRepaint(covariant _ArenaCrownPainter old) => old.color != color;
}

/// Gold crown role pill (mockup #27 ORGANIZER). It STRADDLES the
/// bubble's top edge — the caller pushes the bubble 10px down and
/// positions this over its top border.
class ArenaRolePill extends StatelessWidget {
  final String label;
  const ArenaRolePill(this.label, {super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: kGold,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          CustomPaint(
            size: const Size(11, 8.25),
            painter: _ArenaCrownPainter(Colors.black),
          ),
          const SizedBox(width: 4),
          Text(
            label,
            style: const TextStyle(
              color: Colors.black,
              fontSize: 10,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}

// FIX 23 item 10 — the neon bubble palette (same values as the
// room's item-6 palette in room_screen.dart; file-private copies
// so the shared chat component stays independent of the room).
const Color _neonBubblePink = Color(0xFFFF2E88);
const Color _neonBubblePurple = Color(0xFFB537F2);

/// The mockup #27 bubble shell only — no tail, no header, no time.
/// Other = dark fill + grey border; own = gold-tinted + gold border;
/// [goldBorder] (organizer) = gold border + soft gold glow;
/// [highlight] (room shout) = gold fill + gold bold text.
/// [neon] (FIX 23 item 10, community room only) = neon-tinted
/// bubbles in the item-6 palette: own = magenta tint + magenta
/// border + soft magenta glow; other = dark purple-tinted glass +
/// subtle purple border. Organizer keeps the gold border.
class ArenaChatBubble extends StatelessWidget {
  final bool isMine;
  final bool alignEnd;
  final String text;
  final String imageUrl;
  final VoidCallback? onImageTap;
  final bool goldBorder;
  final bool highlight;
  final Widget? headerLine;
  // FIX 12 G10 — polished bubbles (community chat only): rounder
  // corners, a touch more padding, a deeper soft shadow and a
  // richer gold tint on own messages. Default false — every other
  // chat keeps its exact current look.
  final bool polished;
  // FIX 23 item 10 — neon bubbles (community room only).
  final bool neon;

  const ArenaChatBubble({
    super.key,
    required this.isMine,
    this.alignEnd = true,
    this.text = '',
    this.imageUrl = '',
    this.onImageTap,
    this.goldBorder = false,
    this.highlight = false,
    this.headerLine,
    this.polished = false,
    this.neon = false,
  });

  @override
  Widget build(BuildContext context) {
    final end = alignEnd;
    final Color fill = highlight
        ? kGold.withValues(alpha: 0.22)
        : neon
            ? (isMine
                ? _neonBubblePink.withValues(alpha: 0.18)
                : const Color(0xFF241A38))
            : isMine
                ? kGold.withValues(alpha: polished ? 0.20 : 0.16)
                : kCard;
    final Color border = highlight || goldBorder
        ? kGold
        : neon
            ? (isMine
                ? _neonBubblePink.withValues(alpha: 0.7)
                : _neonBubblePurple.withValues(alpha: 0.45))
            : isMine
                ? kGold.withValues(alpha: 0.65)
                : kBorder;
    final Color textColor = highlight ? kGold : kText;
    return LayoutBuilder(
      builder: (context, constraints) {
        final avail = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : MediaQuery.of(context).size.width;
        return Align(
          alignment: end ? Alignment.centerRight : Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: avail * 0.85),
            child: Container(
              padding: EdgeInsets.symmetric(
                  horizontal: polished ? 11 : 10,
                  vertical: polished
                      ? kChatBubblePaddingVPolished
                      : kChatBubblePaddingV),
              decoration: BoxDecoration(
                color: fill,
                borderRadius: BorderRadius.circular(polished ? 16 : 14),
                border: Border.all(
                  color: border,
                  width: highlight || goldBorder ? 1.0 : 1.0,
                ),
                boxShadow: [
                  if (goldBorder)
                    BoxShadow(
                      color: kGold.withValues(alpha: 0.28),
                      blurRadius: 10,
                      spreadRadius: 1,
                    )
                  else if (neon)
                    BoxShadow(
                      color: (isMine ? _neonBubblePink : _neonBubblePurple)
                          .withValues(alpha: isMine ? 0.25 : 0.20),
                      blurRadius: 10,
                      spreadRadius: 1,
                    )
                  else
                    BoxShadow(
                      color: Colors.black.withValues(
                          alpha: polished ? 0.30 : 0.22),
                      blurRadius: polished ? 8 : 4,
                      offset: Offset(0, polished ? 2 : 1),
                    ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (headerLine != null) ...[
                    headerLine!,
                    if (text.isNotEmpty || imageUrl.isNotEmpty)
                      const SizedBox(height: 3),
                  ],
                  if (imageUrl.isNotEmpty) ...[
                    GestureDetector(
                      onTap: onImageTap,
                      child: ArenaCachedImage(
                        imageUrl: imageUrl,
                        width: 220,
                        height: 160,
                        fit: BoxFit.cover,
                        borderRadius: BorderRadius.circular(10),
                        placeholderIcon: Icons.image,
                      ),
                    ),
                    if (text.isNotEmpty) const SizedBox(height: 6),
                  ],
                  if (text.isNotEmpty)
                    Text(
                      text,
                      style: TextStyle(
                        color: textColor,
                        fontSize: 13,
                        height: 1.35,
                        fontWeight: highlight ? FontWeight.bold : FontWeight.normal,
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 👍👎 chips with counts below a bubble. [reactions] is the raw
/// `chat_messages.reactions` jsonb (emoji -> [uids]); tap toggles the
/// caller's own reaction via [onToggle].
class ArenaReactionRow extends StatelessWidget {
  final Map<String, dynamic> reactions;
  final String myUid;
  final List<String> emojis;
  final bool alignEnd;
  final ValueChanged<String> onToggle;

  const ArenaReactionRow({
    super.key,
    required this.reactions,
    required this.myUid,
    this.emojis = const ['👍', '👎'],
    this.alignEnd = false,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment:
          alignEnd ? MainAxisAlignment.end : MainAxisAlignment.start,
      children: [
        for (final e in emojis)
          Padding(
            padding: const EdgeInsets.only(right: 6, top: 6),
            child: _ReactionChip(
              emoji: e,
              uids: (reactions[e] as List?)
                      ?.map((x) => x.toString())
                      .toList() ??
                  const <String>[],
              mine: ((reactions[e] as List?)
                          ?.map((x) => x.toString())
                          .toList() ??
                      const <String>[])
                  .contains(myUid),
              onTap: () => onToggle(e),
            ),
          ),
      ],
    );
  }
}

class _ReactionChip extends StatelessWidget {
  final String emoji;
  final List<String> uids;
  final bool mine;
  final VoidCallback onTap;
  const _ReactionChip({
    required this.emoji,
    required this.uids,
    required this.mine,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final count = uids.length;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: mine ? kGold.withValues(alpha: 0.25) : kCard,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: mine ? kGold : kBorder),
        ),
        child: Text(
          count > 0 ? '$emoji $count' : emoji,
          style: const TextStyle(fontSize: 12),
        ),
      ),
    );
  }
}

/// The full mockup #27 message row.
///
/// * Other: avatar left + "Name [SQUAD n] time" header ABOVE the
///   dark bubble + [reactions] below + flag icon right ([onReport]).
/// * Own: "Name (You) [Lv.n] time" header ABOVE the right-aligned
///   gold-tinted bubble + [reactions] below, right-aligned.
/// * Organizer ([isOrganizer]): no avatar, full-width gold-border
///   bubble, crown [roleLabel] pill overlapping the top edge, and
///   "Name • time" INSIDE the bubble above the body. No flag.
/// * [alignEnd] false keeps own bubbles left-aligned (room group
///   layout) — the fill still follows [isMine].
/// * [neon] (FIX 23 item 10, community room only) renders the
///   neon bubbles and tightens the between-message gap to
///   [kChatRowBottomGapNeon]. Default false — team chat is
///   unchanged.
class ArenaChatMessage extends StatelessWidget {
  final bool isMine;
  final bool alignEnd;
  final String text;
  final String imageUrl;
  final VoidCallback? onImageTap;
  final String timeLabel;
  final String senderName;
  final bool showYouSuffix;
  final int? level;
  final String squadLabel;
  final Widget? avatar;
  final bool isOrganizer;
  final String roleLabel;
  final bool highlight;
  final Widget? reactions;
  final VoidCallback? onReport;
  final VoidCallback? onLongPress;
  // FIX 12 G10 — polished bubbles (see ArenaChatBubble.polished).
  final bool polished;
  // FIX 23 item 10 — neon bubbles + tighter gap (community only).
  final bool neon;

  const ArenaChatMessage({
    super.key,
    required this.isMine,
    this.alignEnd = true,
    this.text = '',
    this.imageUrl = '',
    this.onImageTap,
    this.timeLabel = '',
    this.senderName = '',
    this.showYouSuffix = false,
    this.level,
    this.squadLabel = '',
    this.avatar,
    this.isOrganizer = false,
    this.roleLabel = 'ORGANIZER',
    this.highlight = false,
    this.reactions,
    this.onReport,
    this.onLongPress,
    this.polished = false,
    this.neon = false,
  });

  Widget _squadPill() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: kField,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kBorder),
      ),
      child: Text(
        squadLabel,
        style: TextStyle(color: kMuted, fontSize: 10, fontWeight: FontWeight.bold),
      ),
    );
  }

  Widget _levelPill() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: kGold),
      ),
      child: Text(
        'Lv.$level',
        style: TextStyle(color: kGold, fontSize: 10, fontWeight: FontWeight.bold),
      ),
    );
  }

  Widget _bubble() {
    // Organizer: "Name • time" lives INSIDE the bubble, above the
    // body — exactly as the mockup shows ("Admin • 07:45 PM").
    final Widget? headerLine = isOrganizer
        ? Row(
            children: [
              Flexible(
                child: Text(
                  senderName,
                  style: TextStyle(
                    color: kText,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (timeLabel.isNotEmpty) ...[
                Text(' • ', style: TextStyle(color: kMuted, fontSize: 13)),
                Text(timeLabel, style: TextStyle(color: kMuted, fontSize: 11)),
              ],
            ],
          )
        : null;
    final bubble = ArenaChatBubble(
      isMine: isMine,
      alignEnd: alignEnd,
      text: text,
      imageUrl: imageUrl,
      onImageTap: onImageTap,
      goldBorder: isOrganizer,
      highlight: highlight,
      headerLine: headerLine,
      polished: polished,
      neon: neon,
    );
    if (!isOrganizer) return bubble;
    // The crown pill STRADDLES the bubble's top edge.
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: bubble,
        ),
        Positioned(
          top: 0,
          left: 12,
          child: ArenaRolePill(roleLabel),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final Widget body = isMine ? _mineBody() : _otherBody();
    if (onLongPress == null) return body;
    return GestureDetector(onLongPress: onLongPress, child: body);
  }

  Widget _mineBody() {
    return Padding(
        padding: EdgeInsets.only(
            bottom: neon ? kChatRowBottomGapNeon : kChatRowBottomGap),
        child: Column(
          crossAxisAlignment:
              alignEnd ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment:
                  alignEnd ? MainAxisAlignment.end : MainAxisAlignment.start,
              children: [
                Flexible(
                  child: Text(
                    showYouSuffix ? '$senderName (You)' : senderName,
                    style: TextStyle(
                      color: kText,
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (level != null) ...[
                  const SizedBox(width: 6),
                  _levelPill(),
                ],
                if (timeLabel.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  Text(
                    timeLabel,
                    style: TextStyle(color: kMuted, fontSize: 11),
                  ),
                ],
              ],
            ),
            const SizedBox(height: kChatNameBubbleGap),
            _bubble(),
            if (reactions != null) reactions!,
          ],
        ),
      );
  }

  Widget _otherBody() {
    // Other-player row (organizer included): avatar left, header
    // above the bubble — except the organizer, whose bubble is
    // full-width with no avatar and no flag.
    return Padding(
      padding: EdgeInsets.only(
          bottom: neon ? kChatRowBottomGapNeon : kChatRowBottomGap),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isOrganizer && avatar != null) ...[
            avatar!,
            const SizedBox(width: kChatAvatarGap),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!isOrganizer) ...[
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          senderName,
                          style: TextStyle(
                            color: kText,
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (squadLabel.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        _squadPill(),
                      ],
                      if (timeLabel.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        Text(
                          timeLabel,
                          style: TextStyle(color: kMuted, fontSize: 11),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: kChatNameBubbleGap),
                ],
                _bubble(),
                if (reactions != null) reactions!,
              ],
            ),
          ),
          if (!isOrganizer && onReport != null)
            Padding(
              padding: const EdgeInsets.only(left: 4, top: 2),
              child: InkWell(
                onTap: onReport,
                borderRadius: BorderRadius.circular(12),
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(Icons.flag_outlined, color: kMuted, size: 14),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// FIX 22 (2026-11-23, user order: "in icon ke beach mai space kam
/// kro") — composer icon gaps, tightened. Pinned by
/// fix22_tabs_composer_test so they can't regress silently. The
/// icons themselves are unchanged (22px, same tap targets); only
/// the gaps shrank (was 8 / 10 / 10).
const double kComposerIconGap = 4; // emoji ↔ attach inside the pill
const double kComposerIconEdgeGap = 6; // attach ↔ pill edge
const double kComposerSendGap = 6; // pill ↔ send button

/// FIX 22 item 13 (2026-11-23, user order: chat "bohot hi
/// bare-bare spaces" — make it tight like the reference) —
/// compact message rows, shared by community + team chat (both
/// render [ArenaChatMessage]). Pinned by fix22_chat_density_test
/// so the density can't regress silently. Layout unchanged
/// (avatar left, name + time on one line above the bubble);
/// only the gaps shrank (was 14 / 6 / 8 / 9/10).
/// PHASE E (E13): tightened once more (6 / 3 / 2 / 5/6) —
/// Sameer's order: bubbles chhote, patli border, halki likhai.
const double kChatRowBottomGap = 6; // gap between message rows
/// FIX 23 item 10b — the BETWEEN-message gap in the neon
/// community chat only (tighter than [kChatRowBottomGap]; team
/// chat keeps 8). Pinned by fix23_community_chat_test.
const double kChatRowBottomGapNeon = 3; // neon gap between rows
const double kChatNameBubbleGap = 2; // name/time line -> bubble
const double kChatAvatarGap = 5; // avatar -> message column
const double kChatBubblePaddingV = 5; // bubble vertical padding
const double kChatBubblePaddingVPolished = 6; // polished variant

/// Mockup #27 composer: pill field (emoji + attach inside), gold
/// circular send button. [busy] shows a spinner in place of the
/// attach icon (DM photo upload) and disables send. A null [onSend]
/// disables the send button; a null [onEmoji]/[onAttach] disables
/// that icon (the icon stays visible — the mockup always shows it).
class ArenaChatInputBar extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final VoidCallback? onSend;
  final VoidCallback? onEmoji;
  final VoidCallback? onAttach;
  final IconData attachIcon;
  final String attachTooltip;
  final bool enabled;
  final bool busy;

  const ArenaChatInputBar({
    super.key,
    required this.controller,
    this.hint = 'Type a message...',
    required this.onSend,
    this.onEmoji,
    this.onAttach,
    this.attachIcon = Icons.add_circle_outline,
    this.attachTooltip = 'Attach',
    this.enabled = true,
    this.busy = false,
  });

  @override
  Widget build(BuildContext context) {
    final canSend = enabled && !busy && onSend != null;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      decoration: BoxDecoration(
        color: kCard,
        border: Border(top: BorderSide(color: kField)),
      ),
      child: Row(
        children: [
          Expanded(
            // FIX 23 item 29 — STYLE ONLY: the composer field wears
            // the card look (gradient + purple border + glow via
            // CardFieldShell, radius 24 like before). Layout is
            // untouched: same Expanded, same icon gaps
            // (kComposerIconGap / kComposerIconEdgeGap /
            // kComposerSendGap), same send behaviour.
            child: CardFieldShell(
              radius: 24,
              child: TextField(
                controller: controller,
                enabled: enabled,
                style: TextStyle(color: kText),
                textInputAction: TextInputAction.send,
                onSubmitted: (_) {
                  if (canSend) onSend!();
                },
                decoration: InputDecoration(
                  hintText: hint,
                  hintStyle: TextStyle(color: kMuted),
                  contentPadding:
                      const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                  border: const OutlineInputBorder(borderSide: BorderSide.none),
                  enabledBorder: const OutlineInputBorder(borderSide: BorderSide.none),
                  focusedBorder: const OutlineInputBorder(borderSide: BorderSide.none),
                suffixIcon: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: Icon(
                        Icons.emoji_emotions_outlined,
                        color: kMuted,
                        size: 22,
                      ),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      tooltip: 'Emoji',
                      onPressed: enabled ? onEmoji : null,
                    ),
                    const SizedBox(width: kComposerIconGap),
                    if (busy)
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 4),
                        child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            color: Color(0xFFFDC903),
                            strokeWidth: 2,
                          ),
                        ),
                      )
                    else
                      IconButton(
                        icon: Icon(attachIcon, color: kMuted, size: 22),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        tooltip: attachTooltip,
                        onPressed: enabled ? onAttach : null,
                      ),
                    const SizedBox(width: kComposerIconEdgeGap),
                  ],
                ),
              ),
              ),
            ),
          ),
          const SizedBox(width: kComposerSendGap),
          InkWell(
            onTap: canSend ? onSend : null,
            borderRadius: BorderRadius.circular(24),
            child: Container(
              width: 48,
              height: 48,
              decoration: const BoxDecoration(
                color: Color(0xFFFDC903),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.send, color: Colors.black, size: 22),
            ),
          ),
        ],
      ),
    );
  }
}
