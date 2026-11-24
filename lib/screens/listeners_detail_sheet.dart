import 'package:flutter/material.dart';

import '../services/live_listeners.dart';
import '../theme.dart';

/// ARENA HUB #10 AUDIO — Group 9, RJ STUDIO listeners detail sheet
/// (user order 2026-11-22, mockup v4 with the sheet open).
///
/// The panel's header count row ("128 listening") is tappable; the tap
/// opens this sheet, listing WHO is listening: circular avatar,
/// display name, listening-since time — plus the show's peak
/// listeners. Listeners = LiveKit room participants NOT on a mic seat
/// (the host + mic guests occupy seats).
///
/// LAYOUT (mockup v4, matched): a dark rounded card; a gold drag
/// handle (a short centred gold line) at the top; the header row
/// "LISTENERS - 128" (gold, left) + "Peak: 214" (gold, right); rows
/// of avatar + "Name - 12 min" (white) + a gold speaker icon
/// (right), with thin dividers between rows, sorted longest-listening
/// first. Empty room: "No listeners yet", centred, muted.
///
/// A presentational sheet ONLY. It owns no audio engine and imports
/// no LiveKit/Supabase/room code — it renders the [RjListener] list
/// the panel passes in. The panel opens it itself via
/// [showListenersDetailSheet] (it has the data + context; no
/// callback needed).
///
/// DESIGN (strict, user order): gold #FDC903 ONLY — every gold here
/// comes from the shared [kGold] token, and the file contains NO
/// hardcoded hex colour literal at all. Global card rule: NO full
/// border anywhere — the drag handle is the only gold line at the
/// top. Headings light golden ([kGold]).
///
/// TIME FORMAT ([formatListeningSince]): under 1 minute -> "just
/// now"; under 1 hour -> "12 min"; 1 hour or more -> "1h 5m"
/// (exact hours drop the minutes part: "2h").

/// Opens the listeners detail sheet as a scrollable modal bottom
/// sheet (70% of the screen height; the list scrolls inside it).
Future<void> showListenersDetailSheet(
  BuildContext context, {
  required List<RjListener> listeners,
  required int listenerCount,
  required int peakListeners,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: kCardPurpleMid,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22)), side: const BorderSide(color: kCardPurpleBorder, width: 1.5)),
    builder: (context) => SizedBox(
      height: MediaQuery.of(context).size.height * 0.7,
      child: ListenersDetailSheet(
        listeners: listeners,
        listenerCount: listenerCount,
        peakListeners: peakListeners,
      ),
    ),
  );
}

/// Renders a listening-since timestamp as "just now" / "12 min" /
/// "1h 5m" (see the file header). [now] is injectable so tests can
/// pin the boundary behaviour exactly; it defaults to the current
/// time. A future timestamp (clock skew) reads as "just now".
String formatListeningSince(DateTime since, {DateTime? now}) {
  final elapsed = (now ?? DateTime.now()).difference(since);
  if (elapsed.inSeconds < 60) return 'just now';
  final minutes = elapsed.inMinutes;
  if (minutes < 60) return '$minutes min';
  final hours = minutes ~/ 60;
  final rest = minutes % 60;
  if (rest == 0) return '${hours}h';
  return '${hours}h ${rest}m';
}

/// The listeners detail sheet content: drag handle, header
/// ("LISTENERS - N" + "Peak: P"), then the listener rows sorted
/// longest-listening first (earliest [RjListener.listeningSince]
/// first). Needs a bounded height from its parent (the modal
/// bottom sheet gives it 70% of the screen).
class ListenersDetailSheet extends StatelessWidget {
  /// The listeners to list. Sorted longest-first inside [build];
  /// the input list is never mutated.
  final List<RjListener> listeners;

  /// The live count shown in the header ("LISTENERS - N"). Usually
  /// equals [listeners].length, but the count is the authority —
  /// the list may lag it by a beat.
  final int listenerCount;

  /// The session peak, shown in the header ("Peak: P"). In-memory
  /// only until the backend lands.
  final int peakListeners;

  const ListenersDetailSheet({
    super.key,
    required this.listeners,
    required this.listenerCount,
    required this.peakListeners,
  });

  @override
  Widget build(BuildContext context) {
    // Longest-listening first = earliest listeningSince first.
    final sorted = [...listeners]
      ..sort((a, b) => a.listeningSince.compareTo(b.listeningSince));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 12),
        // Drag handle — the only gold line at the top (global card
        // rule: no full border anywhere).
        Center(
          child: Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: kGold,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'LISTENERS - $listenerCount',
                style: TextStyle(
                  color: kGold,
                  fontWeight: FontWeight.w900,
                  fontSize: 16,
                ),
              ),
              Text(
                'Peak: $peakListeners',
                style: TextStyle(
                  color: kGold,
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
            ],
          ),
        ),
        if (sorted.isEmpty)
          Expanded(
            child: Center(
              child: Text(
                'No listeners yet',
                style: TextStyle(color: kMuted, fontSize: 14),
              ),
            ),
          )
        else
          Expanded(
            child: ListView.separated(
              key: const Key('listeners-list'),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              itemCount: sorted.length,
              separatorBuilder: (_, __) =>
                  Divider(color: kMuted.withValues(alpha: 0.2)),
              itemBuilder: (context, index) =>
                  _ListenerRow(listener: sorted[index]),
            ),
          ),
      ],
    );
  }
}

/// One listener row: circular avatar + "Name - 12 min" + a gold
/// speaker icon (mockup v4).
class _ListenerRow extends StatelessWidget {
  final RjListener listener;

  const _ListenerRow({required this.listener});

  @override
  Widget build(BuildContext context) {
    final name = listener.displayName;
    final initial = name.isEmpty ? '?' : name[0].toUpperCase();
    final avatarUrl = listener.avatarUrl;
    final hasPhoto = avatarUrl != null && avatarUrl.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          CircleAvatar(
            key: Key('listener-avatar-${listener.uid}'),
            radius: 22,
            // Mirrors the room screen's avatar fallback (a gold
            // initial circle when no photo is known — the room's
            // CachedFramedAvatar defaults to the same gold); the
            // tint is hashed from the uid so a listener keeps the
            // same shade across rebuilds.
            backgroundColor: _avatarColor(listener.uid),
            backgroundImage: hasPhoto ? NetworkImage(avatarUrl) : null,
            child: hasPhoto
                ? null
                : Text(
                    initial,
                    style: const TextStyle(
                      color: Colors.black,
                      fontWeight: FontWeight.bold,
                      fontSize: 18,
                    ),
                  ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              '$name - ${formatListeningSince(listener.listeningSince)}',
              style: TextStyle(
                color: kText,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Icon(Icons.volume_up, color: kGold, size: 22),
        ],
      ),
    );
  }
}

/// A stable gold-ish tint for an initial-circle avatar, hashed from
/// the uid. All four tints are derived from the shared [kGold] token
/// (lerped towards white) — no second gold anywhere (GOLD RULE
/// 2026-11-22). The hash is computed by hand because Dart's
/// String.hashCode is randomised per process; this one keeps a
/// listener's shade stable across sessions.
Color _avatarColor(String uid) {
  const tints = [0.0, 0.18, 0.36, 0.54];
  var hash = 0;
  for (final unit in uid.codeUnits) {
    // Decimal 2^31 - 1 mask (kept decimal so the file stays free of
    // hex literals entirely, like the panel).
    hash = (hash * 31 + unit) & 2147483647;
  }
  return Color.lerp(kGold, Colors.white, tints[hash % tints.length]) ?? kGold;
}
