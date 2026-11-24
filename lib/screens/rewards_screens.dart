import 'package:flutter/material.dart';

import '../components/arena_components.dart';
import '../components/cached_image.dart';
import '../services/supabase_db.dart';
import '../utils.dart';
import 'more_screens.dart'; // NotificationsPage for the #35 header bell.
    // NOTE: more_screens.dart imports this file (ProfilePage tiles),
    // so this is a circular import — legal in Dart (both files only
    // define classes, no import-time initialisers depend on each other).
import '../main.dart'; // ArenaBottomNav + homeTabRequest (bottom-nav
    // round 2026-11-22, #17). Same circular-import precedent as
    // above: main.dart imports more_screens.dart, which imports this
    // file — legal in Dart, no import-time initialisers involved.

/// ARENA HUB rewards screens (§6.1 #17 + #35) — Phase 3, Wave C (#17 hubahu).
///
/// UI REWORK 2026-11-20 (user order "har jagah"): every card on both
/// screens is the shared [MockupCard] (gradient fill + two rotating
/// yellow shines, NO full border — the mockups' full gold borders +
/// glows are replaced per the user's correction), and every heading
/// (screen titles + section headers) is light golden [kSectionLabel],
/// not pure white. Layout, copy and data sources are unchanged.
///
/// ROUND 7 REDO 2026-11-20 (#35 Community Rewards ONLY — #17
/// Activity History is untouched): the #35 page now matches mockup
/// 973914189 same-to-same — WHITE headings ([kText], the mockup's
/// white bold caps, NOT [kSectionLabel]), bigger hero total, italic
/// disclaimer, level-ring gap at the bottom-right, pills radius 14
/// and vertically centred, milestones as a 3-across full-width grid
/// (was a horizontal scroll). The hero's top/bottom gold rim-light
/// washes are GONE (the yellow shade on this screen) — only the
/// [MockupCard] rotating segments remain on cards. All gold/yellow
/// uses the [kGold] constant — no hardcoded gold hex on this page.
///
/// Points / rewards data lives in the Phase 4 tables (018 ledger +
/// challenges + achievements, 022 `claim_reward` RPC).
/// * #17 reads the LIVE `community_points_ledger` (018) via
///   `SupaDb.getPointsTotal` / `getPointsLedger` — totals are the real
///   SUM(delta); an empty ledger shows the designed empty state, never
///   mock values. Points crediting itself is still off (A2) so the
///   real total is 0 until the first ledger rows land.
/// * `getChallenges` / `getAchievements` return [] and the screens
///   show the designed empty state.
/// * Catalogs are EMPTY BY DESIGN (OD-08): the admin seeds challenges
///   and achievements after launch. No challenge / achievement
///   definition or point value is invented anywhere in this file.
/// * Claims go ONLY through `SupaDb.claimReward` (the `claim_reward`
///   RPC). A failed claim shows the honest error — NEVER a fake
///   success. No direct table writes, no cash logic.
/// * Level: the REAL `profiles.level` (migration 017, same source
///   Home uses for its Lv.N pill) is shown in the #35 hero ring.
///   The ring fill is REAL progress of the community-points total
///   against the OD-03 curve (next level needs level x 100 PTS —
///   the same curve the Profile screen's XP bar uses, user order
///   2026-11-20): 0 points is an EMPTY ring, never a full one.
///   The "Next Lv. N+1 at X PTS" line under the ring is that
///   curve's real target, never the mockup's sample 3,000.
/// * Milestones are the mockup's three named badges (Elite /
///   Squad Champion / Master) with states from real stats —
///   never the mockup's sample states. Names render IN FULL.
/// * NO rank-tier badge anywhere here.
///
/// Shared states (LoadingSkeleton / EmptyState / ErrorState /
/// OfflineState) are wired per §6.1. NOTE (same caveat as Phase 2
/// Teams): SupaDb read helpers swallow read errors and return []/{},
/// so a read failure is indistinguishable from "empty" — the
/// Error/Offline branches below are driven by throws that do reach
/// the FutureBuilder (e.g. the claim RPC) and are defensive for reads.

bool _isOfflineError(Object e) {
  final s = e.toString().toLowerCase();
  return s.contains('socketexception') ||
      s.contains('failed host lookup') ||
      s.contains('network is unreachable') ||
      s.contains('connection refused') ||
      s.contains('connection timed out') ||
      s.contains('no internet') ||
      s.contains('network error');
}

DateTime? _parseLedgerDate(dynamic v) {
  if (v is String && v.isNotEmpty) {
    return DateTime.tryParse(v)?.toLocal();
  } else if (v is int && v > 0) {
    // created_at may arrive as epoch ms (normalised rows) or seconds.
    return DateTime.fromMillisecondsSinceEpoch(v > 100000000000 ? v : v * 1000).toLocal();
  }
  return null;
}

const _ledgerMonths = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// "Nov 22, 2024 • 8:00 PM" — the mockup's record date format.
String _formatLedgerDateTime(dynamic v) {
  final d = _parseLedgerDate(v);
  if (d == null) return '';
  final hour12 = d.hour % 12 == 0 ? 12 : d.hour % 12;
  final ampm = d.hour < 12 ? 'AM' : 'PM';
  return '${_ledgerMonths[d.month - 1]} ${d.day}, ${d.year} • $hour12:${d.minute.toString().padLeft(2, '0')} $ampm';
}

String _formatLedgerDay(DateTime d) => '${_ledgerMonths[d.month - 1]} ${d.day}, ${d.year}';

/// Thousands-grouped points ("4,150"), shared by both screens.
String _formatPointsGrouped(int v) {
  final s = v.abs().toString();
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
    buf.write(s[i]);
  }
  return v < 0 ? '-${buf.toString()}' : buf.toString();
}

/// Record category from the ledger row's real `source_type`.
/// The mockup's record titles are category names (Event Participation,
/// Daily Challenge, Achievement Unlocked, Weekly Activity) — the
/// mapping below only labels the row's own source_type; no value is
/// invented. Unknown sources fall back to the row's real `reason`.
String _activityKind(Map<String, dynamic> r) {
  final s = SupaDb.strOf(r['source_type']).toLowerCase();
  if (s.contains('event') || s.contains('tournament') || s.contains('cup')) return 'event';
  if (s.contains('challenge')) return 'challenge';
  if (s.contains('achievement') || s.contains('badge')) return 'achievement';
  if (s.contains('week')) return 'weekly';
  if (s.contains('referral') || s.contains('invite')) return 'referral';
  if (s.contains('redeem') || s.contains('reward') || s.contains('claim')) return 'redeem';
  return 'other';
}

String _activityTitle(Map<String, dynamic> r) {
  final reason = SupaDb.strOf(r['reason']);
  switch (_activityKind(r)) {
    case 'event':
      return 'Event Participation';
    case 'challenge':
      return 'Daily Challenge';
    case 'achievement':
      return 'Achievement Unlocked';
    case 'weekly':
      return 'Weekly Activity';
    case 'referral':
      return 'Referral Reward';
    case 'redeem':
      return 'Reward Redeemed';
    default:
      return reason.isNotEmpty ? reason : 'Points activity';
  }
}

IconData _activityIcon(Map<String, dynamic> r) {
  switch (_activityKind(r)) {
    case 'event':
      return Icons.sports_esports;
    case 'challenge':
      return Icons.track_changes;
    case 'achievement':
      // Mockup #17: the achievement row icon is a CROWN, not a
      // trophy — the drawn crown (ArenaCrownIcon) is used via
      // _activityIconWidget below; this stays as the fallback.
      return Icons.emoji_events;
    case 'weekly':
      return Icons.card_giftcard;
    case 'referral':
      return Icons.group_add;
    case 'redeem':
      return Icons.redeem;
    default:
      return Icons.stars;
  }
}

/// Row icon widget (mockup #17): achievement rows show a drawn gold
/// crown; every other kind shows its plain gold glyph.
Widget _activityIconWidget(Map<String, dynamic> r) {
  if (_activityKind(r) == 'achievement') return const ArenaCrownIcon(size: 28);
  return Icon(_activityIcon(r), color: kGold, size: 28);
}

/// Detail line under the title: the row's real `reason` when it is not
/// already the title, else the raw `source_type`, else nothing.
String _activitySubtitle(Map<String, dynamic> r) {
  final title = _activityTitle(r);
  final reason = SupaDb.strOf(r['reason']);
  final source = SupaDb.strOf(r['source_type']);
  if (reason.isNotEmpty && reason != title) return reason;
  if (source.isNotEmpty && source.toLowerCase() != title.toLowerCase()) return source;
  return '';
}

Widget _rewardsSkeleton() {
  return ListView(
    padding: const EdgeInsets.all(16),
    children: const [
      LoadingSkeleton(height: 96),
      SizedBox(height: 12),
      LoadingSkeleton(height: 56),
      SizedBox(height: 12),
      LoadingSkeleton(height: 72),
      SizedBox(height: 8),
      LoadingSkeleton(height: 72),
      SizedBox(height: 8),
      LoadingSkeleton(height: 72),
    ],
  );
}

// ------------------------------------------------------------------ #17

/// Activity History (§6.1 #17) — Wave C hubahu rebuild to mockup
/// 347385475: back + ACTIVITY HISTORY + search + gold calendar header,
/// gold COMMUNITY POINTS hero (net total big, Total Earned / Used
/// split below), All / Earned / Used pill tabs, RECORDS rows (gold
/// icon tile + title + detail + "Nov 22, 2024 • 8:00 PM" + gold
/// +N / red −N + Completed).
///
/// All numbers are REAL ledger data: total = SUM(delta) over the
/// caller's `community_points_ledger` rows (net balance — the mockup's
/// +2,450 = 4,150 earned − 1,700 used), Earned = sum of positive
/// deltas, Used = sum of |negative| deltas. Tabs filter REAL rows
/// only; an empty ledger shows the designed empty state. The search
/// icon filters rows by their real title/detail text; the calendar
/// icon filters rows to one real ledger day. NEVER a mock value.
class ActivityHistoryPage extends StatefulWidget {
  final String uid;
  const ActivityHistoryPage({super.key, required this.uid});

  @override
  State<ActivityHistoryPage> createState() => _ActivityHistoryPageState();
}

class _ActivityData {
  final int total;
  final List<Map<String, dynamic>> ledger;
  const _ActivityData({required this.total, required this.ledger});

  int get earned => ledger.fold<int>(0, (s, r) {
        final d = SupaDb.intOf(r['delta']);
        return d > 0 ? s + d : s;
      });
  int get used => ledger.fold<int>(0, (s, r) {
        final d = SupaDb.intOf(r['delta']);
        return d < 0 ? s - d : s;
      });
}

class _ActivityHistoryPageState extends State<ActivityHistoryPage> {
  late Future<_ActivityData> _future;
  int _tab = 0; // 0 All, 1 Earned, 2 Used
  bool _searching = false;
  String _query = '';
  DateTime? _selectedDate;
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<_ActivityData> _load() async {
    final total = SupaDb.intOf(await SupaDb.getPointsTotal(widget.uid));
    final ledger = await SupaDb.getPointsLedger(widget.uid);
    return _ActivityData(total: total, ledger: ledger);
  }

  void _retry() => setState(() => _future = _load());

  // Bottom-nav-at-bottom round (2026-11-22, #17): a nav tap pops
  // back to HomeShell first, then posts the wanted tab — the shell
  // (mounted below this pushed page) switches to it with its
  // normal _onTap. Pop first so a maintenance dialog from the
  // switch (if any) never opens over this page.
  void _onNavTap(int i) {
    Navigator.pop(context);
    homeTabRequest.value = i;
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate ?? DateTime.now(),
      firstDate: DateTime(2024),
      lastDate: DateTime.now(),
    );
    if (picked != null) setState(() => _selectedDate = picked);
  }

  List<Map<String, dynamic>> _filtered(_ActivityData d) {
    List<Map<String, dynamic>> rows;
    switch (_tab) {
      case 1:
        rows = d.ledger.where((r) => SupaDb.intOf(r['delta']) > 0).toList();
        break;
      case 2:
        rows = d.ledger.where((r) => SupaDb.intOf(r['delta']) < 0).toList();
        break;
      default:
        rows = d.ledger;
    }
    if (_query.isNotEmpty) {
      final q = _query.toLowerCase();
      rows = rows.where((r) {
        return _activityTitle(r).toLowerCase().contains(q) || _activitySubtitle(r).toLowerCase().contains(q);
      }).toList();
    }
    if (_selectedDate != null) {
      final day = _selectedDate!;
      rows = rows.where((r) {
        final dt = _parseLedgerDate(r['created_at']);
        return dt != null && dt.year == day.year && dt.month == day.month && dt.day == day.day;
      }).toList();
    }
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Bottom-nav-at-bottom round (2026-11-22, #17): this page is
      // a pushed Profile sub-screen (Profile → Activity History
      // tile), so it shows the SHARED HomeShell nav — the same
      // ArenaBottomNav widget, not a copy — with the Profile tab
      // highlighted. The mockup's 5th tab reads "Activity", but
      // the app has no Activity tab: the shell is 6 tabs and
      // Activity lives under Profile, so no Activity tab is
      // invented and HomeShell is NOT restructured. A tap pops
      // back to the shell and switches to that tab.
      bottomNavigationBar:
          ArenaBottomNav(currentIndex: 5, onTap: _onNavTap),
      body: SafeArea(
        // Mockup #17 background: sparse gold dots — the shared
        // ArenaEmberDots drift behind the content, taps pass through.
        child: Stack(
          children: [
            const Positioned.fill(child: IgnorePointer(child: ArenaEmberDots())),
            FutureBuilder<_ActivityData>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return _rewardsSkeleton();
            }
            if (snap.hasError) {
              final e = snap.error!;
              if (_isOfflineError(e)) {
                return Center(child: OfflineState(message: 'Check your internet connection and try again.', onRetry: _retry));
              }
              return Center(child: ErrorState(message: 'Activity load nahi ho saki: $e', onRetry: _retry));
            }
            final d = snap.data ?? const _ActivityData(total: 0, ledger: []);
            final rows = _filtered(d);
            final filtering = _query.isNotEmpty || _selectedDate != null;
            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              children: [
                // #17 header (mockup): back + ACTIVITY HISTORY + search
                // + gold calendar. No AppBar — matches #35's header.
                Row(
                  children: [
                    IconButton(
                      icon: Icon(Icons.chevron_left, color: kText, size: 26),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      onPressed: () => Navigator.pop(context),
                    ),
                    Expanded(
                      child: Text(
                        'ACTIVITY HISTORY',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: kSectionLabel, fontSize: 20, fontWeight: FontWeight.w900),
                      ),
                    ),
                    IconButton(
                      icon: Icon(Icons.search, color: _searching ? kGold : kText, size: 26),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      onPressed: () => setState(() {
                        _searching = !_searching;
                        if (!_searching) {
                          _query = '';
                          _searchController.clear();
                        }
                      }),
                    ),
                    const SizedBox(width: 6),
                    IconButton(
                      icon: Icon(Icons.calendar_month, color: kGold, size: 26),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      onPressed: _pickDate,
                    ),
                  ],
                ),
                if (_searching) ...[
                  const SizedBox(height: 12),
                  // FIX 23 item 29: card look via CardFieldShell.
                  CardFieldShell(
                    child: TextField(
                    controller: _searchController,
                    autofocus: true,
                    onChanged: (v) => setState(() => _query = v),
                    style: TextStyle(color: kText),
                    decoration: InputDecoration(
                      hintText: 'Search activity…',
                      hintStyle: TextStyle(color: kMuted),
                      prefixIcon: Icon(Icons.search, color: kMuted),
                      border: const OutlineInputBorder(borderSide: BorderSide.none),
                      enabledBorder: const OutlineInputBorder(borderSide: BorderSide.none),
                      focusedBorder: const OutlineInputBorder(borderSide: BorderSide.none),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    ),
                  ),
                  ),
                ],
                if (_selectedDate != null) ...[
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: GestureDetector(
                      onTap: () => setState(() => _selectedDate = null),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        decoration: cardFillDecoration(radius: 20).copyWith(border: Border.all(color: kGold)),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.calendar_month, color: kGold, size: 16),
                            const SizedBox(width: 6),
                            Text(_formatLedgerDay(_selectedDate!), style: TextStyle(color: kText, fontSize: 13, fontWeight: FontWeight.bold)),
                            const SizedBox(width: 6),
                            Icon(Icons.close, color: kMuted, size: 16),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                _activityHero(d.total, d.earned, d.used),
                const SizedBox(height: 16),
                Row(
                  children: [
                    _activityTab('All', 0),
                    const SizedBox(width: 10),
                    _activityTab('Earned', 1),
                    const SizedBox(width: 10),
                    _activityTab('Used', 2),
                  ],
                ),
                const SizedBox(height: 20),
                Text('RECORDS', style: TextStyle(color: kSectionLabel, fontSize: 14, fontWeight: FontWeight.bold, letterSpacing: 0.5)),
                const SizedBox(height: 12),
                if (rows.isEmpty)
                  Center(
                    child: EmptyState(
                      icon: Icons.history,
                      title: filtering
                          ? 'No matching activity'
                          : _tab == 1
                              ? 'No points earned yet'
                              : _tab == 2
                                  ? 'No points used yet'
                                  : 'No activity yet',
                      body: filtering
                          ? 'Is search ya date ke liye koi entry nahi mili — filter hatakar dobara dekhein.'
                          : _tab == 0
                              ? 'Abhi koi points activity nahi — jab aap points earn ya use karenge, har entry yahan dikhegi.'
                              : _tab == 1
                                  ? 'Abhi koi earned points nahi — challenges aur rewards se points milenge.'
                                  : 'Abhi koi used points nahi.',
                    ),
                  )
                else
                  for (final r in rows) _ledgerRow(r),
              ],
            );
          },
            ),
          ],
        ),
      ),
    );
  }

  /// #17 hero (mockup): COMMUNITY POINTS card, coin + label, big net
  /// total "+2,450 PTS" (SUM(delta) — earned minus used), then "Total
  /// Earned: 4,150 PTS | Used: 1,700 PTS" below.
  ///
  /// UI rework 2026-11-20: the card is the shared [MockupCard]
  /// (gradient + two rotating yellow shines, NO full gold border —
  /// the mockup's full border + outer glow are replaced per the
  /// user's correction). FIX 3 (2026-11-20, user order): the
  /// mockup's gold light burst from the top-right corner is REMOVED
  /// — it showed as a faint yellow box/shade over the card's dark
  /// background and the user wants the background clean dark. The
  /// coin is the mockup's gold "G" coin, drawn.
  Widget _activityHero(int total, int earned, int used) {
    return MockupCard(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      radius: 20,
      child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  // Mockup #17 "G" coin (drawn, not an asset).
                  Container(
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: const LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [Color(0xFFFDC903), Color(0xFFFDC903), Color(0xFFFDC903)],
                      ),
                      border: Border.all(color: const Color(0xFFFDC903), width: 1),
                    ),
                    alignment: Alignment.center,
                    child: const Text('G', style: TextStyle(color: Color(0xFF0A0A0F), fontSize: 15, fontWeight: FontWeight.w900)),
                  ),
                  const SizedBox(width: 8),
                  Text('COMMUNITY POINTS', style: TextStyle(color: kGold, fontSize: 15, fontWeight: FontWeight.w900, letterSpacing: 0.5)),
                ],
              ),
              const SizedBox(height: 10),
              Center(
                child: RichText(
                  text: TextSpan(
                    children: [
                      TextSpan(
                        text: '${total >= 0 ? '+' : '-'}${_formatPointsGrouped(total.abs())}',
                        // Mockup #17: hero "+N PTS" ~48px (was 44).
                        style: TextStyle(color: kGold, fontSize: 48, fontWeight: FontWeight.w900, height: 1.0),
                      ),
                      TextSpan(text: ' PTS', style: TextStyle(color: kGold, fontSize: 20, fontWeight: FontWeight.w900)),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: RichText(
                      textAlign: TextAlign.center,
                      text: TextSpan(
                        children: [
                          TextSpan(text: 'Total Earned: ', style: TextStyle(color: kMuted, fontSize: 13)),
                          TextSpan(text: '${_formatPointsGrouped(earned)} PTS', style: TextStyle(color: kText, fontSize: 13, fontWeight: FontWeight.bold)),
                        ],
                      ),
                    ),
                  ),
                  Container(width: 1, height: 16, color: kBorder),
                  Expanded(
                    child: RichText(
                      textAlign: TextAlign.center,
                      text: TextSpan(
                        children: [
                          TextSpan(text: 'Used: ', style: TextStyle(color: kMuted, fontSize: 13)),
                          TextSpan(text: '${_formatPointsGrouped(used)} PTS', style: TextStyle(color: kText, fontSize: 13, fontWeight: FontWeight.bold)),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
    );
  }

  /// #17 pill tab (mockup): gold-filled selected, dark unselected,
  /// full-width thirds, 48 tall, radius 24.
  Widget _activityTab(String label, int index) {
    final selected = _tab == index;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _tab = index),
        child: Container(
          height: 48,
          alignment: Alignment.center,
          // PHASE E (E24, CORRECTED 2026-11-24): selected tab
          // is gold-filled (Sameer: "click pe yellow hona
          // chahiye"); the rest are the card fill — never black.
          decoration: selected
              ? BoxDecoration(
                  color: kGold,
                  borderRadius: BorderRadius.circular(24),
                )
              : cardFillDecoration(radius: 24).copyWith(
                  border: Border.all(color: kBorder, width: 1),
                ),
          child: Text(label, style: TextStyle(color: selected ? Colors.black : kText, fontWeight: FontWeight.bold, fontSize: 16)),
        ),
      ),
    );
  }

  /// #17 record row (mockup): gold icon tile + bold title + muted
  /// detail + "Nov 22, 2024 • 8:00 PM", right side gold +N (red −N)
  /// over muted "Completed". A posted ledger entry is complete by
  /// definition — the status is the row's state, not invented data.
  /// UI rework 2026-11-20: the row card is the shared [MockupCard]
  /// (no full border — two rotating yellow shines instead).
  Widget _ledgerRow(Map<String, dynamic> r) {
    final delta = SupaDb.intOf(r['delta']);
    final title = _activityTitle(r);
    final subtitle = _activitySubtitle(r);
    final dateTime = _formatLedgerDateTime(r['created_at']);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: MockupCard(
        padding: const EdgeInsets.all(12),
        radius: 16,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: kGold.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(12),
                // Mockup #17: the record-row icon tile border is a
                // strong gold outline, not a faint wash (was alpha
                // 0.4, width 1 — barely visible on the dark card).
                border: Border.all(color: kGold.withValues(alpha: 0.8), width: 1.5),
              ),
              alignment: Alignment.center,
              child: _activityIconWidget(r),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: TextStyle(color: kText, fontWeight: FontWeight.bold, fontSize: 16)),
                  if (subtitle.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(subtitle, style: TextStyle(color: kMuted, fontSize: 13), maxLines: 1, overflow: TextOverflow.ellipsis),
                  ],
                  if (dateTime.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(dateTime, style: TextStyle(color: kMuted, fontSize: 13)),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  delta >= 0 ? '+$delta' : '$delta',
                  style: TextStyle(color: delta >= 0 ? kGold : kRed, fontWeight: FontWeight.w900, fontSize: 22),
                ),
                const SizedBox(height: 2),
                Text('Completed', style: TextStyle(color: kMuted, fontSize: 12)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ #35
// Level curve (OD-03, user order 2026-11-20 "kro") — the SAME curve
// the Profile screen's XP bar uses (more_screens.dart): the next
// level needs level x 100 PTS (level 1 -> 100, level 5 -> 500).
// The #35 ring tracks the community-points total shown in this
// hero against that curve, so 0 points is an EMPTY ring and the
// fill grows with the real total. profiles.xp is a SEPARATE column
// the Profile bar reads; until the server unifies XP and community
// points, this hero stays on the points total it displays.
// Public (no underscore) so widget/unit tests can pin the math.

/// Points needed to reach the next level from [level].
int communityLevelTarget(int level) => (level < 1 ? 1 : level) * 100;

/// The level after [level].
int communityNextLevel(int level) => (level < 1 ? 1 : level) + 1;

/// Ring fill 0.0–1.0 for [points] against the OD-03 target for
/// [level]. Clamped — 0 points is exactly 0.0 (empty ring).
double communityLevelProgress(int points, int level) {
  final target = communityLevelTarget(level);
  if (target <= 0) return 0.0;
  return (points / target).clamp(0.0, 1.0);
}

/// Real state of one milestone rung ([current] vs [goal]):
/// Unlocked at goal, "In progress | N%" while earning, Locked at 0.
/// The % is the same number shown ON the badge.
({bool unlocked, bool inProgress, int pct, String label}) milestoneProgress(int current, int goal) {
  if (goal <= 0) return (unlocked: false, inProgress: false, pct: 0, label: 'Locked');
  if (current >= goal) return (unlocked: true, inProgress: false, pct: 100, label: 'Unlocked');
  if (current <= 0) return (unlocked: false, inProgress: false, pct: 0, label: 'Locked');
  final pct = ((current / goal) * 100).clamp(0, 100).round();
  return (unlocked: false, inProgress: true, pct: pct, label: 'In progress | $pct%');
}

/// Community Rewards (§6.1 #35) — Wave B restyle, hubahu to mockup
/// 973914189: back + COMMUNITY REWARDS + avatar + bell header, gold
/// points hero, DAILY COMMUNITY CHALLENGES / ACHIEVEMENT REWARDS rows
/// (title + +N PTS, real progress bar + p/goal, In Progress pill or
/// gold Claim pill), PARTICIPATION MILESTONES badge cards.
///
/// ROUND 7 REDO 2026-11-20: white headings (mockup white caps),
/// hero total 44 + italic disclaimer, ring gap bottom-right, pills
/// radius 14 vertically centred, milestones as a 3-across grid.
/// 2026-11-21 REWORK (mockup side-by-side, user voice call
/// 2026-11-21 ~22:43 PKT): the ring is REAL progress (OD-03 curve,
/// level x 100 PTS — the same curve the Profile screen's XP bar
/// uses; 0 points = EMPTY ring, fixing the fixed-270°-sweep bug
/// that showed a full ring at 0 points), "Next Lv. N+1 at X PTS"
/// sits under the ring, and the milestones are the mockup's three
/// named badges (Elite / Squad Champion / Master) with real states.
/// Still NO invented values: no mockup sample numbers (2,450 /
/// Level 5 / 3,000 PTS / sample challenge names), no achievement
/// progress bars (no progress rows). Referral milestones
/// (5/10/15 friends, `referral_milestones` table, recharge+play
/// rule) live on the Invites screen (more_screens.dart), NOT here —
/// nothing about them is hardcoded or changed in this file.
///
/// Points total (same source as #17, honest 0 until the ledger
/// exists); Daily Challenges from `SupaDb.getChallenges()` with REAL
/// progress from `getChallengeProgress(uid, periodKey)`; Achievements
/// from `SupaDb.getAchievements()` / `getMyAchievements(uid)`.
/// Catalogs are EMPTY BY DESIGN (OD-08 — admin seeds after launch),
/// so until then both lists show the designed empty state. Claim
/// buttons appear ONLY on a real challenge/achievement row and claim
/// via `SupaDb.claimReward` (RPC only); a failed claim shows the
/// honest error, never a fake success.
///
/// A3 (corrected Wave C): the level IS real — `profiles.level`
/// (migration 017, verified on staging, same source Home uses for
/// its Lv.N pill) is shown in the hero ring, with the ring fill and
/// the "Next Lv. N+1 at X PTS" line from the OD-03 curve (level x
/// 100 PTS — see [communityLevelTarget]). NO rank-tier badge.
/// Achievements have no progress rows either (only the unlocked
/// set), so their rows show no progress bar — a bar would be
/// invented. Milestones (OD-06, fix round I-all-fix1-C) are the
/// mockup's three named badges over REAL stats the app already
/// has (matches played, wins, ledger points) — display only,
/// never a Claim, never wired to the claim_reward RPC.
class CommunityRewardsPage extends StatefulWidget {
  final String uid;
  const CommunityRewardsPage({super.key, required this.uid});

  @override
  State<CommunityRewardsPage> createState() => _CommunityRewardsPageState();
}

class _RewardsData {
  final int total;
  final int level;
  final List<Map<String, dynamic>> challenges;
  final List<Map<String, dynamic>> achievements;
  final Set<String> myAchievementKeys;
  final String avatarUrl;
  final Map<String, Map<String, dynamic>> progressByKey;
  // OD-06 milestone stats (real player stats, see _load).
  final int matches;
  final int wins;
  final int kills;
  const _RewardsData({
    required this.total,
    this.level = 1,
    required this.challenges,
    required this.achievements,
    required this.myAchievementKeys,
    this.avatarUrl = '',
    this.progressByKey = const {},
    this.matches = 0,
    this.wins = 0,
    this.kills = 0,
  });
}

class _CommunityRewardsPageState extends State<CommunityRewardsPage> {
  late Future<_RewardsData> _future;
  final Set<String> _claimedKeys = {};
  final Set<String> _claimingKeys = {};
  String? _claimError;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<_RewardsData> _load() async {
    final total = SupaDb.intOf(await SupaDb.getPointsTotal(widget.uid));
    final challenges = await SupaDb.getChallenges();
    final achievements = await SupaDb.getAchievements();
    final mine = await SupaDb.getMyAchievements(widget.uid);
    final myKeys = mine
        .map((r) => SupaDb.strOf(r['achievement_key'], SupaDb.strOf(r['key'], SupaDb.strOf(r['achievement_id']))))
        .where((k) => k.isNotEmpty)
        .toSet();
    // Header avatar: the user's real profiles.photo_url (never a
    // mock photo — the mockup's soldier portrait is PUBG art).
    // Level: the REAL profiles.level (migration 017, same source
    // Home uses) — default 1 when the row/column is absent.
    String avatarUrl = '';
    int level = 1;
    try {
      final profile = await SupaDb.getRow('profiles', 'firebase_uid', widget.uid);
      avatarUrl = SupaDb.strOf(profile['photo_url']);
      level = SupaDb.intOf(profile['level'], 1);
    } catch (_) {}
    // Real challenge progress for the current period. Challenges may
    // be daily or weekly, so both period keys are read and merged;
    // rows are keyed by challenge_id AND key (whichever the row has).
    final progressByKey = <String, Map<String, dynamic>>{};
    final now = DateTime.now();
    for (final period in ['daily', 'weekly']) {
      try {
        final rows = await SupaDb.getChallengeProgress(widget.uid, SupaDb.periodKeyFor(now, period));
        for (final r in rows) {
          for (final k in [SupaDb.strOf(r['challenge_id']), SupaDb.strOf(r['challenge_key']), SupaDb.strOf(r['key'])]) {
            if (k.isNotEmpty) progressByKey[k] = r;
          }
        }
      } catch (_) {}
    }
    // OD-06 milestone stats: matches / wins / kills from the same
    // live sources the Profile/Stats screens use (profile counters
    // with match_history fallback; kills summed from history).
    // Points come from the ledger total above. All defensive — a
    // failed read leaves 0, never an invented value.
    int matches = 0;
    int wins = 0;
    int kills = 0;
    try {
      final profile = await SupaDb.getProfile(widget.uid);
      final history = await SupaDb.getMatchHistory(widget.uid);
      matches = SupaDb.intOf(profile['totalMatches'], history.length);
      wins = SupaDb.intOf(profile['wonMatches'], history.where((h) => SupaDb.intOf(h['rank']) == 1).length);
      kills = history.fold<int>(0, (s, h) => s + SupaDb.intOf(h['kills']));
    } catch (_) {}
    return _RewardsData(total: total, level: level, challenges: challenges, achievements: achievements, myAchievementKeys: myKeys, avatarUrl: avatarUrl, progressByKey: progressByKey, matches: matches, wins: wins, kills: kills);
  }

  void _retry() => setState(() {
        _claimError = null;
        _future = _load();
      });

  Future<void> _claim(String rewardKey, String period) async {
    if (rewardKey.isEmpty || _claimingKeys.contains(rewardKey)) return;
    setState(() {
      _claimingKeys.add(rewardKey);
      _claimError = null;
    });
    try {
      // periodKeyFor lives in SupaDb (Worker S) — never duplicated here.
      final periodKey = SupaDb.periodKeyFor(DateTime.now(), period);
      final res = await SupaDb.claimReward(rewardKey, periodKey);
      if (!mounted) return;
      final ok = res['ok'] == true;
      if (ok) {
        setState(() {
          _claimedKeys.add(rewardKey);
          _claimingKeys.remove(rewardKey);
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Reward claimed! Points total refresh ho raha hai.')),
        );
        // Re-read the real total + catalogs after a successful claim.
        setState(() => _future = _load());
      } else {
        // Honest failure — the RPC is NOT applied yet, so ok:false is
        // the expected result until Phase 4. Never a fake success,
        // and never raw backend text: a missing claim_reward RPC
        // (PGRST202) means the reward system is not live yet.
        final raw = SupaDb.strOf(res['error'], SupaDb.strOf(res['message'], ''));
        final msg = _claimFailureMessage(raw);
        setState(() {
          _claimingKeys.remove(rewardKey);
          _claimError = msg;
        });
        // v2011 fix: NO SnackBar here — the same message already
        // renders inline as ErrorState (with Retry) below the hero;
        // showing it twice was a duplicate-toast bug.
      }
    } catch (_) {
      if (!mounted) return;
      const msg = 'Claim nahi ho saka — thori der baad koshish karein.';
      setState(() {
        _claimingKeys.remove(rewardKey);
        _claimError = msg;
      });
      // v2011 fix: same as above — the inline ErrorState shows it.
    }
  }

  /// Plain-language claim failure — raw PostgrestException text is
  /// never shown to the user. A missing claim_reward function
  /// (PGRST202 / "Could not find the function") means the reward
  /// system is not live yet (Phase 4 migrations unapplied).
  static String _claimFailureMessage(String err) {
    final lower = err.toLowerCase();
    if (lower.contains('already claimed')) return 'Yeh reward pehle claim ho chuka hai.';
    if (lower.contains('pgrst202') || lower.contains('could not find the function') || lower.contains('claim_reward')) {
      return 'Reward system abhi tayyar ho raha hai — thori der baad koshish karein';
    }
    return 'Claim nahi ho saka — thori der baad koshish karein.';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        // Mockup #35 background: sparse gold dots — the shared
        // ArenaEmberDots drift behind the content, taps pass through.
        child: Stack(
          children: [
            const Positioned.fill(child: IgnorePointer(child: ArenaEmberDots())),
            FutureBuilder<_RewardsData>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return _rewardsSkeleton();
            }
            if (snap.hasError) {
              final e = snap.error!;
              if (_isOfflineError(e)) {
                return Center(child: OfflineState(message: 'Check your internet connection and try again.', onRetry: _retry, onGoBack: () => Navigator.pop(context)));
              }
              return Center(child: ErrorState(message: 'Rewards load nahi ho sake: $e', onRetry: _retry));
            }
            final d = snap.data ?? const _RewardsData(total: 0, challenges: [], achievements: [], myAchievementKeys: {});
            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              children: [
                // #35 header: back + COMMUNITY REWARDS + real avatar + bell.
                Row(
                  children: [
                    // Mockup #35 header: plain chevron-left, no box.
                    IconButton(
                      icon: Icon(Icons.chevron_left, color: kText, size: 26),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      onPressed: () => Navigator.pop(context),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      // Mockup #35: white bold caps title, 20. The
                      // FittedBox shrinks it on narrow screens
                      // instead of wrapping onto a second line.
                      // 2026-11-21 FIX: the SizedBox(12) after the
                      // title is load-bearing — the FittedBox scales
                      // the text to fill the Expanded width, so
                      // without a gap the title's last letter sat
                      // flush against (visually under) the avatar
                      // ring. The gap keeps title and avatar apart
                      // at every width.
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text('COMMUNITY REWARDS', maxLines: 1, softWrap: false, style: TextStyle(color: kText, fontSize: 20, fontWeight: FontWeight.w900, letterSpacing: 0.5)),
                      ),
                    ),
                    const SizedBox(width: 12),
                    GestureDetector(
                      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => NotificationsPage(uid: widget.uid))),
                      child: Container(
                        padding: const EdgeInsets.all(2),
                        decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: kGold, width: 2)),
                        child: ArenaCachedAvatar(
                          photoUrl: d.avatarUrl,
                          radius: 17,
                          backgroundColor: kSurface,
                          fallback: Icon(Icons.person, color: kGold, size: 20),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    IconButton(
                      icon: Icon(Icons.notifications_outlined, color: kText, size: 26),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => NotificationsPage(uid: widget.uid))),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                _pointsHero(d.total, d.level),
                if (_claimError != null) ...[
                  const SizedBox(height: 12),
                  ErrorState(message: _claimError!, onRetry: _retry),
                ],
                const SizedBox(height: 20),
                _sectionHeader('DAILY COMMUNITY CHALLENGES'),
                const SizedBox(height: 16),
                if (d.challenges.isEmpty)
                  const Center(
                    child: EmptyState(
                      icon: Icons.emoji_events,
                      title: 'No challenges yet',
                      body: 'Abhi koi challenge nahi — admin launch ke baad challenges add karega, phir yahan daily challenges dikhenge.',
                    ),
                  )
                else
                  for (final c in d.challenges) _challengeRow(c, d.progressByKey),
                const SizedBox(height: 20),
                _sectionHeader('ACHIEVEMENT REWARDS'),
                const SizedBox(height: 16),
                if (d.achievements.isEmpty)
                  const Center(
                    child: EmptyState(
                      icon: Icons.military_tech,
                      title: 'No achievements yet',
                      body: 'Abhi koi achievement nahi — admin launch ke baad achievements add karega, phir yahan unlocked achievements dikhenge.',
                    ),
                  )
                else
                  for (final a in d.achievements) _achievementRow(a, d.myAchievementKeys),
                // OD-06: milestones always render — they come from
                // real player stats, not the (empty-by-design)
                // achievements catalog.
                const SizedBox(height: 20),
                _sectionHeader('PARTICIPATION MILESTONES'),
                const SizedBox(height: 16),
                // Mockup #35: 3 badge cards in a row, full width
                // (was a horizontal scroll — Round 7 redo).
                GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    crossAxisSpacing: 10,
                    mainAxisSpacing: 10,
                    childAspectRatio: 0.62,
                  ),
                  itemCount: _milestones.length,
                  itemBuilder: (_, i) => _milestoneCard(_milestones[i], d),
                ),
              ],
            );
          },
            ),
          ],
        ),
      ),
    );
  }

  /// #35 section header: gold bar + white bold caps title (mockup
  /// #35 — Round 7 redo: white [kText], NOT light-golden
  /// [kSectionLabel] as the 2026-11-20 rework had it).
  Widget _sectionHeader(String title) {
    return Row(
      children: [
        Container(width: 5, height: 22, decoration: BoxDecoration(color: kGold, borderRadius: BorderRadius.circular(2))),
        const SizedBox(width: 8),
        Expanded(child: Text(title, style: TextStyle(color: kText, fontSize: 19, fontWeight: FontWeight.w900, letterSpacing: 0.5))),
      ],
    );
  }

  /// #35 points hero: featured card, big gold total + YOUR COMMUNITY
  /// POINTS + the non-cash footnote. The ring slot holds the REAL
  /// profiles.level ("LEVEL" + the number); the ring FILL is real
  /// progress of the points total against the OD-03 curve
  /// ([communityLevelProgress] — level x 100 PTS, the same curve
  /// the Profile screen's XP bar uses), and "Next Lv. N+1 at X PTS"
  /// under the ring is that curve's real target — never the
  /// mockup's sample "Next Lv. 6 at 3,000 PTS". At 0 points the
  /// ring is EMPTY (2026-11-21 fix: the old painter drew a fixed
  /// 270° sweep, so 0 points showed a ~75%-full ring).
  ///
  /// UI rework 2026-11-20: the card is the shared [MockupCard]
  /// (gradient + two rotating yellow shines, NO full gold border —
  /// the mockup's full border + outer glow are replaced per the
  /// user's correction). ROUND 7: the top/bottom gold rim-light
  /// washes are REMOVED — they were a full-width yellow shade on
  /// this card, and only the two rotating segments remain. The
  /// level ring keeps its soft circular gold glow (mockup #35's
  /// ring glow, not a box shade). Total is 44 (mockup giant) with
  /// a FittedBox so a big real total shrinks instead of wrapping;
  /// the disclaimer is italic like the mockup. The "Next Lv." line
  /// is FittedBox scaleDown inside its 124-wide column so a big
  /// target (e.g. 1,000 PTS) shrinks instead of cutting.
  Widget _pointsHero(int total, int level) {
    final progress = communityLevelProgress(total, level);
    final next = communityNextLevel(level);
    final target = communityLevelTarget(level);
    return MockupCard(
      padding: const EdgeInsets.all(18),
      radius: 20,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // FittedBox: a big real total (e.g. 12,450) shrinks
                // instead of wrapping "POINTS" onto a second line.
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(text: _formatPoints(total), style: TextStyle(color: kGold, fontSize: 44, fontWeight: FontWeight.w900, height: 1.0)),
                        TextSpan(text: ' POINTS', style: TextStyle(color: kGold, fontSize: 20, fontWeight: FontWeight.w900)),
                      ],
                    ),
                    maxLines: 1,
                    softWrap: false,
                  ),
                ),
                const SizedBox(height: 4),
                Text('YOUR COMMUNITY POINTS', style: TextStyle(color: kText, fontSize: 14, fontWeight: FontWeight.bold)),
                const SizedBox(height: 10),
                Text(
                  '*Points are non-cash community recognition used to level up and unlock virtual badges.',
                  style: TextStyle(color: kMuted, fontSize: 11, height: 1.4, fontStyle: FontStyle.italic),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          // Ring + "Next Lv." line (mockup #35): the line sits
          // directly under the ring, inside the same column.
          SizedBox(
            width: 124,
            child: Column(
              children: [
                Container(
                  width: 92,
                  height: 92,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    boxShadow: goldGlow(alpha: 0.40, blur: 16, spread: 0, offset: Offset.zero),
                  ),
                  child: SizedBox(
                    width: 92,
                    height: 92,
                    child: CustomPaint(
                      painter: LevelRingPainter(progress: progress),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text('LEVEL', style: TextStyle(color: kMuted, fontSize: 11, fontWeight: FontWeight.bold)),
                          Text('$level', style: TextStyle(color: kText, fontSize: 30, fontWeight: FontWeight.w900, height: 1.0)),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    'Next Lv. $next at ${_formatPointsGrouped(target)} PTS',
                    maxLines: 1,
                    softWrap: false,
                    style: TextStyle(color: kText, fontSize: 12, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _formatPoints(int v) => _formatPointsGrouped(v);

  /// #35 pill: dark "In Progress" (grey border, muted text) or gold
  /// "Claim" (gold fill, dark text), rounded 14 like the mockup's
  /// rounded-rect buttons (was 20 — Round 7 redo).
  Widget _challengePill({required String label, required bool isClaim, required VoidCallback? onPressed, bool busy = false}) {
    if (!isClaim) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(color: kCardFillColor, borderRadius: BorderRadius.circular(14), border: Border.all(color: kBorder)),
        child: Text(label, style: TextStyle(color: kMuted, fontWeight: FontWeight.bold, fontSize: 13)),
      );
    }
    return Container(
      height: 44,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        // Mockup #35: the gold Claim pills carry a soft gold glow.
        boxShadow: goldGlow(alpha: 0.45, blur: 16, spread: 1, offset: const Offset(0, 4)),
      ),
      child: ElevatedButton(
        onPressed: busy ? null : onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: kGold,
          foregroundColor: const Color(0xFF0A0A0F),
          disabledBackgroundColor: kGold.withValues(alpha: 0.45),
          padding: const EdgeInsets.symmetric(horizontal: 20),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          elevation: 0,
        ),
        child: busy
            ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF0A0A0F)))
            : Text(label, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
      ),
    );
  }

  Widget _challengeRow(Map<String, dynamic> c, Map<String, Map<String, dynamic>> progressByKey) {
    final key = SupaDb.strOf(c['key']);
    final id = SupaDb.strOf(c['id']);
    final title = SupaDb.strOf(c['title'], key.isEmpty ? 'Challenge' : key);
    final points = SupaDb.intOf(c['points']);
    final period = SupaDb.strOf(c['period'], 'daily');
    final goal = SupaDb.intOf(c['goal']);
    final prog = progressByKey[id] ?? progressByKey[key];
    final progress = prog == null ? 0 : SupaDb.intOf(prog['progress']);
    final claimed = (prog != null && prog['claimed'] == true) || _claimedKeys.contains(key);
    final complete = goal > 0 && progress >= goal;
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Row(
        // Mockup #35: the pill is vertically centred against the
        // title + progress-bar block (was top-aligned).
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(child: Text(title, style: TextStyle(color: kText, fontWeight: FontWeight.w600, fontSize: 16))),
                    Text('+$points PTS', style: TextStyle(color: kGold, fontWeight: FontWeight.bold, fontSize: 15)),
                  ],
                ),
                if (goal > 0) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(child: ProgressBar(value: progress / goal, height: 10)),
                      const SizedBox(width: 10),
                      Text('$progress/$goal', style: TextStyle(color: kText, fontSize: 14)),
                    ],
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          // Claim button ONLY on a real catalog row, and only once
          // the real progress reaches the goal.
          if (claimed)
            const StatusBadge(label: 'Claimed', kind: StatusKind.verified)
          else if (complete)
            _challengePill(label: _claimingKeys.contains(key) ? 'Claiming…' : 'Claim', isClaim: true, busy: _claimingKeys.contains(key), onPressed: key.isEmpty ? null : () => _claim(key, period))
          else
            _challengePill(label: 'In Progress', isClaim: false, onPressed: null),
        ],
      ),
    );
  }

  Widget _achievementRow(Map<String, dynamic> a, Set<String> myKeys) {
    final key = SupaDb.strOf(a['key']);
    final title = SupaDb.strOf(a['title'], key.isEmpty ? 'Achievement' : key);
    final points = SupaDb.intOf(a['points']);
    final unlocked = myKeys.contains(key) || _claimedKeys.contains(key);
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Row(
        // Mockup #35: the pill is vertically centred against the
        // title + progress-bar block (was top-aligned).
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(child: Text(title, style: TextStyle(color: kText, fontWeight: FontWeight.w600, fontSize: 16))),
                    Text('+$points PTS', style: TextStyle(color: kGold, fontWeight: FontWeight.bold, fontSize: 15)),
                  ],
                ),
                // No progress bar here: achievements have no progress
                // rows (only the unlocked set), so a bar would be
                // invented. Unlocked rows show a full gold bar — the
                // requirement is really complete.
                if (unlocked) ...[
                  const SizedBox(height: 8),
                  const ProgressBar(value: 1.0, height: 10),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          // Already unlocked (real user_achievements row) → badge,
          // not a second claim. Otherwise "In Progress" — achievements
          // have no progress rows (only the unlocked set), so a
          // non-unlocked row is unearned as far as the app knows and
          // must never show a tappable Claim (mockup #35 shows
          // "In Progress" on the incomplete achievement).
          if (unlocked)
            const StatusBadge(label: 'Unlocked', kind: StatusKind.verified)
          else
            _challengePill(label: 'In Progress', isClaim: false, onPressed: null),
        ],
      ),
    );
  }

  /// OD-06 PARTICIPATION MILESTONES (mockup #35): the mockup's
  /// three named badges, with states from the REAL stats the app
  /// already has — never the mockup's sample states (its "Unlocked
  /// / 80% / Locked" are sample values for a sample user). Thresholds
  /// are display rungs, not payouts: no reward is attached to any
  /// milestone, no Claim pill ever renders, and nothing here wires
  /// to the claim_reward RPC. The KIND is the badge's identity
  /// (crown for Elite / Master, people for Squad Champion); a locked
  /// badge shows the lock kind + desaturated crest, an in-progress
  /// badge shows its real % ON the badge, an unlocked badge glows
  /// gold. Squad Champion counts wins = rank-1 finishes — the app
  /// tracks no squad-only win counter, so all wins count.
  static const _milestones = [
    {'title': 'Elite Badge', 'stat': 'matches', 'goal': 10, 'kind': ArenaBadgeKind.crown},
    {'title': 'Squad Champion', 'stat': 'wins', 'goal': 5, 'kind': ArenaBadgeKind.people},
    {'title': 'Master Badge', 'stat': 'points', 'goal': 1000, 'kind': ArenaBadgeKind.crown},
  ];

  int _statValue(String stat, _RewardsData d) {
    switch (stat) {
      case 'wins':
        return d.wins;
      case 'kills':
        return d.kills;
      case 'points':
        return d.total;
      case 'matches':
      default:
        return d.matches;
    }
  }

  /// #35 milestone badge card: winged-shield emblem (the user's
  /// premium crest art via [ArenaWingedBadge] — mockup #35's
  /// detailed winged badge is an asset gap), name, and the real
  /// progress state — "Unlocked", "In progress | NN%", or "Locked"
  /// (mockup #35). Display only: no tap handler, no Claim pill,
  /// no reward. The UNLOCKED badge glows gold like the mockup;
  /// the in-progress badge shows its real % at the shield's bottom
  /// point; the locked badge is silver/grey and flat.
  /// UI rework 2026-11-20: the card is the shared [MockupCard]
  /// (no full border — two rotating yellow shines instead).
  /// ROUND 7: the card fills a 3-across grid cell (mockup #35 —
  /// was a fixed 112-wide horizontal-scroll card).
  /// 2026-11-21: the badge NAME renders IN FULL (maxLines 2,
  /// no ellipsis — the mockup itself cuts "Squad Champion Bad…"
  /// and that cut is NOT copied), the status line is FittedBox
  /// scaleDown so "In progress | NN%" never cuts, and the grid
  /// aspect is 0.62 so the taller two-line names + the glowing
  /// badge never overflow a narrow cell.
  Widget _milestoneCard(Map<String, Object> m, _RewardsData d) {
    final title = m['title'] as String;
    final goal = m['goal'] as int;
    final current = _statValue(m['stat'] as String, d);
    final kind = m['kind'] as ArenaBadgeKind;
    final state = milestoneProgress(current, goal);
    return MockupCard(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
      radius: 16,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          ArenaWingedBadge(
            size: 64,
            kind: state.unlocked || state.inProgress ? kind : ArenaBadgeKind.lock,
            locked: !state.unlocked && !state.inProgress,
            pct: state.inProgress ? state.pct : null,
            glow: state.unlocked,
          ),
          const SizedBox(height: 8),
          Text(title, textAlign: TextAlign.center, maxLines: 2, style: TextStyle(color: kText, fontWeight: FontWeight.bold, fontSize: 12, height: 1.2)),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(state.label, textAlign: TextAlign.center, maxLines: 1, softWrap: false, style: TextStyle(color: state.unlocked || state.inProgress ? kGold : kMuted, fontSize: 11, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }
}

/// #35 LEVEL ring (mockup): a gold arc over a dark track around the
/// LEVEL number. The arc is REAL progress — [progress] is the
/// community-points fill from [communityLevelProgress] (0.0 = empty
/// track only, 1.0 = full circle), starting at the top and sweeping
/// clockwise. 2026-11-21 FIX: the old painter drew a FIXED 270°
/// sweep, so a user with 0 points saw a ~75%-full ring; at 0
/// points the ring now shows the bare track. Public so tests can
/// pin the progress value the hero passes in.
class LevelRingPainter extends CustomPainter {
  final double progress;
  const LevelRingPainter({required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 3;
    final track = Paint()
      ..color = kBorder
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round;
    canvas.drawCircle(center, radius, track);
    final p = progress.clamp(0.0, 1.0);
    if (p <= 0) return;
    final arc = Paint()
      ..color = kGold
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round;
    // Real progress sweep from the top, clockwise.
    canvas.drawArc(Rect.fromCircle(center: center, radius: radius), -1.5708, p * 6.2832, false, arc);
  }

  @override
  bool shouldRepaint(covariant LevelRingPainter oldDelegate) => oldDelegate.progress != progress;
}
