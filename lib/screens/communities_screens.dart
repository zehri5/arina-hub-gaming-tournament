import 'dart:async';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../community_service.dart';
import '../components/arena_chat.dart';
import '../components/arena_components.dart';
import '../components/cached_image.dart';
import '../components/chat_bubble.dart';
import '../services/imgbb_service.dart';
import '../services/message_sounds.dart';
import '../services/supabase_db.dart';
import '../utils.dart';
import '../widgets/arena_ui.dart';
import '../widgets/voice_settings_sheet.dart'; // FIX 20 (fix 7): header Settings sheet + its panel bridge
import 'community_screens.dart';
import 'room_screen.dart';
import 'pro_features.dart'; // FIX 12 G13: saveTeamPhotoLocal for a squad's picked photo (import cycle already exists transitively via community_screens.dart — same precedent as pro_features.dart importing this file).

/// COMMUNITIES UI (2026-11-21, user design — WhatsApp-channel style).
///
///   * [CommunitiesListPage] — all communities + search + create.
///   * [CreateCommunityPage] — FIX 12 G13 unified create form:
///     name, description, photo (ImgBB) + [Community] [Squad]
///     submit boxes. Same class name/constructor as Fix 11.
///   * [CommunityDetailPage] — header + Follow/Unfollow + tabs:
///     Chat (realtime) | Members. (Posts tab removed 2026-11-23,
///     FIX-12 G1 — the community_posts table stays on the server.)
///
/// Data comes ONLY from [CommunityGroups] (lib/community_service.dart).
/// BEFORE draft migration 073 is applied the list shows the
/// "coming online" state instead of crashing — every read degrades
/// to [] and every write reports {'offline': true}.
///
/// NAVIGATION (no routing changes — direct push, like the existing
/// Community hub): see the hook snippet in the delivery report.
/// Theme: gold #FDC903 ([kGold]) on black ([_cBg]/[_cCard]) — the
/// locked gold, via the read-only theme (this file sets no colours
/// of its own except through [kGold]/[_cBg]/[_cCard]/[kMuted]/[kText]).

// COMMUNITIES GUIDE §5 — guide colors for the communities UI ONLY
// (gold #FDC903 is kGold already; bg/card/border are the guide values,
// a few hex steps off the app theme tokens — the rest of the app is
// NOT rethemed, these locals apply to this file only).
const Color _cBg = Color(0xFF0A0D14);
const Color _cCard = Color(0xFF1B1D29);
const Color _cBorder = Color(0xFF2A2E3A);
// FIX 23 item 14 — the neon glow colours for the detail page's
// code-drawn background (same values as the room's item-6
// palette in room_screen.dart; file-private copies).
const Color _cNeonPink = Color(0xFFFF2E88);
const Color _cNeonPurple = Color(0xFFB537F2);

/// Mockup #27 chat clock ("07:46 PM") — the SAME format TeamChatPage
/// uses (`pro_features.dart:507` `_fmtClock`, a private function that
/// cannot be imported). The mockup and the one #27 design show the
/// absolute clock time above the bubble.
String _chatClock(int ms) {
  if (ms <= 0) return '';
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
  return '$h:${d.minute.toString().padLeft(2, '0')} ${d.hour >= 12 ? 'PM' : 'AM'}';
}

/// FIX 12 G4 — About sheet date ("21 Nov 2026"). No intl in this
/// app, so the month names are local. '' when the timestamp is
/// missing/invalid — the sheet shows 'Unknown' instead of a
/// guessed date.
String _aboutDate(int ms) {
  if (ms <= 0) return '';
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  return '${d.day} ${months[d.month - 1]} ${d.year}';
}

Widget _initialAvatar(String name, String photoUrl, {double radius = 22}) {
  final initial = name.trim().isEmpty ? 'C' : name.trim()[0].toUpperCase();
  return CircleAvatar(
    radius: radius,
    backgroundColor: kGold.withValues(alpha: 0.18),
    backgroundImage:
        photoUrl.isEmpty ? null : CachedNetworkImageProvider(photoUrl),
    onBackgroundImageError: photoUrl.isEmpty ? null : (_, __) {},
    child: photoUrl.isEmpty
        ? Text(initial,
            style: TextStyle(
                color: kGold, fontWeight: FontWeight.w900, fontSize: radius))
        : null,
  );
}

/// FIX 12 G15 (STAN-style list, 2026-11-23 user orders 01:33 +
/// 01:34 + 01:35): the Community tab list shows ALL communities
/// as ROWS in the STAN "Communities You Joined" row style — round
/// photo, name, member count, arrow — ordered by the existing
/// COUNT-based member count, DESCENDING. The top [kTopCommunitiesCount]
/// sit at the top in a "Top Communities" section. NO BANNER GRID —
/// the user cancelled it (01:34); its absence is a PASS condition,
/// so no banner/grid widget exists anywhere in this list. Gold
/// #FDC903 ([kGold]) + black ONLY — the LAYOUT is STAN's, the
/// purple is not. Shared by [CommunitiesListPage] (deep links)
/// and the Community tab's embedded list in pro_features.dart
/// (`_buildCommunityList`, the list the user actually sees).

/// How many of the largest communities the "Top Communities"
/// section shows. A NAMED CONSTANT by spec — never a literal 5.
const int kTopCommunitiesCount = 5;

/// Sort a community list by COUNT-based member count, DESCENDING
/// (ties: name ascending, so the order is stable). Returns a NEW
/// list; the input is untouched. Pure — unit-tested in
/// test/fix12_g15_stan_list_test.dart.
List<Map<String, dynamic>> sortCommunitiesByMembers(
    List<Map<String, dynamic>> items) {
  final sorted = [...items];
  sorted.sort((a, b) {
    final byCount = SupaDb.intOf(b['memberCount'])
        .compareTo(SupaDb.intOf(a['memberCount']));
    if (byCount != 0) return byCount;
    return SupaDb.strOf(a['name'])
        .toLowerCase()
        .compareTo(SupaDb.strOf(b['name']).toLowerCase());
  });
  return sorted;
}

/// Compact member count, STAN-style: 15700 -> "15.7K",
/// 32800000 -> "32.8M", 999 -> "999", 1000 -> "1K".
/// Pure — unit-tested in test/fix12_g15_stan_list_test.dart.
String formatMemberCount(int count) {
  if (count < 0) return '0';
  String trim1(double v, String suffix) {
    final s = v.toStringAsFixed(1);
    final t = s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
    return '$t$suffix';
  }

  if (count >= 1000000) return trim1(count / 1000000, 'M');
  if (count >= 1000) return trim1(count / 1000, 'K');
  return '$count';
}

/// One slot in a STAN-style community list: a section header
/// ([isHeader], [header] holds its title) or one community row
/// ([community] holds the community map).
class CommunityListSlot {
  final String header;
  final Map<String, dynamic>? community;
  const CommunityListSlot.header(this.header) : community = null;
  const CommunityListSlot.row(this.community) : header = '';
  bool get isHeader => header.isNotEmpty;
}

/// Section slots for a member-count-sorted community list
/// (FIX 12 G15). Browsing: "Top Communities" header + the top
/// [kTopCommunitiesCount] rows, then — only when more rows
/// remain — an "All Communities" header + the rest. Searching:
/// plain rows, no section headers (a filtered result is not a
/// "top" list). [] for an empty list (the caller shows its empty
/// state). Pure — unit-tested in test/fix12_g15_stan_list_test.dart.
List<CommunityListSlot> communityListSlots(
    List<Map<String, dynamic>> items, {required bool searching}) {
  if (items.isEmpty) return const [];
  if (searching) {
    return items.map((c) => CommunityListSlot.row(c)).toList();
  }
  final slots = <CommunityListSlot>[
    const CommunityListSlot.header('Top Communities'),
  ];
  slots.addAll(items
      .take(kTopCommunitiesCount)
      .map((c) => CommunityListSlot.row(c)));
  if (items.length > kTopCommunitiesCount) {
    slots.add(const CommunityListSlot.header('All Communities'));
    slots.addAll(items
        .skip(kTopCommunitiesCount)
        .map((c) => CommunityListSlot.row(c)));
  }
  return slots;
}

/// A section header inside a STAN-style community list —
/// "Top Communities" (gold star) or "All Communities".
/// REDESIGN B-S8: contract typography ([kStyleSection]) + spacing
/// tokens; the star and titles are unchanged.
class CommunitySectionHeader extends StatelessWidget {
  final String title;
  final bool star;
  const CommunitySectionHeader(
      {super.key, required this.title, this.star = false});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: kSpace4, bottom: kSpace12),
      child: Row(
        children: [
          if (star) ...[
            Icon(Icons.star, color: kGold, size: 18),
            const SizedBox(width: 6),
          ],
          Text(title, style: kStyleSection),
        ],
      ),
    );
  }
}

/// FIX 12 G15 — one community ROW, STAN "Communities You Joined"
/// style, gold #FDC903 + black: ROUND photo (initial fallback),
/// bold name (+ CREATOR badge), a member-count chip with the
/// compact count, and a GOLD arrow circle (STAN's purple arrow,
/// recoloured — never purple). The whole row is tappable and
/// opens the community's detail page. FOLLOW/JOINED is NOT in
/// the row (STAN rows have no follow button) — follow/unfollow
/// lives on the detail page, as before. On the standard
/// [MockupCard] (gradient + parked gold shines, no full border),
/// like every other list row in the app.
///
/// REDESIGN B-S8 (styling only): contract tokens throughout —
/// [kStyleCardTitle] for the name, [kStyleLabel] for the count,
/// [kSpace12]/[kSpace8] gaps, [kRadiusInput] card radius. The row
/// STRUCTURE (photo radius 28 / name + badge / count chip / gold
/// arrow circle radius 20) is unchanged, so the TeamsPage
/// embedded list inherits the polish via this one shared widget.
class StanCommunityRow extends StatelessWidget {
  final Map<String, dynamic> community;
  final VoidCallback onOpen;
  // FIX 23 item 19 — the card Follow button (direct join from
  // outside). The parent passes [onFollow] + [showFollow]; the
  // row itself hides the button for the creator and for users
  // who are already members. After a successful follow the
  // parent stops passing showFollow — the button DISAPPEARS
  // (no "Following" state on the card; unfollow lives inside
  // the room, in the sidebar Followers spot).
  final VoidCallback? onFollow;
  final bool showFollow;
  const StanCommunityRow(
      {super.key,
      required this.community,
      required this.onOpen,
      this.onFollow,
      this.showFollow = false});

  @override
  Widget build(BuildContext context) {
    final c = community;
    final isCreator = SupaDb.strOf(c['myRole']) == 'creator';
    final isMember = c['isMember'] == true;
    final showFollowBtn =
        showFollow && onFollow != null && !isCreator && !isMember;
    final count = SupaDb.intOf(c['memberCount']);
    return MockupCard(
      padding: const EdgeInsets.all(kSpace12),
      radius: kRadiusInput,
      animate: false,
      child: InkWell(
        onTap: onOpen,
        borderRadius: BorderRadius.circular(kRadiusInput),
        child: Row(
          children: [
            _initialAvatar(SupaDb.strOf(c['name'], 'Community'),
                SupaDb.strOf(c['photo_url']),
                radius: 28),
            const SizedBox(width: kSpace12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(SupaDb.strOf(c['name'], 'Community'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: kStyleCardTitle.copyWith(
                                fontWeight: FontWeight.w800)),
                      ),
                      if (isCreator)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                              color: kGold,
                              borderRadius: BorderRadius.circular(6)),
                          child: const Text('CREATOR',
                              style: TextStyle(
                                  color: Colors.black,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w900)),
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  // FIX 23 item 19: the Follow pill shrank the
                  // middle column, so the count pill must never
                  // exceed it — constrain to the column width and
                  // ellipsize the count text (it overflowed by
                  // 76px at 360px with the wide test font).
                  LayoutBuilder(
                    builder: (context, constraints) => ConstrainedBox(
                      constraints:
                          BoxConstraints(maxWidth: constraints.maxWidth),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                            color: kGold.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(20)),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.people, color: kGold, size: 13),
                            const SizedBox(width: 4),
                            Flexible(
                              child: Text(
                                  '${formatMemberCount(count)} member${count == 1 ? '' : 's'}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: kStyleLabel.copyWith(
                                      color: kMuted,
                                      fontWeight: FontWeight.w700)),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: kSpace8),
            // FIX 23 item 19 — Follow (direct join). Gold pill;
            // hidden for the creator / members / after a
            // successful follow (see showFollowBtn above).
            if (showFollowBtn)
              Padding(
                padding: const EdgeInsets.only(right: kSpace8),
                child: InkWell(
                  onTap: onFollow,
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                        color: kGold,
                        borderRadius: BorderRadius.circular(12)),
                    child: const Text('Follow',
                        style: TextStyle(
                            color: Colors.black,
                            fontSize: 12,
                            fontWeight: FontWeight.w900)),
                  ),
                ),
              ),
            CircleAvatar(
              radius: 20,
              backgroundColor: kGold,
              child: const Icon(Icons.arrow_forward,
                  color: Colors.black, size: 20),
            ),
          ],
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------
// LIST
// ------------------------------------------------------------------

class CommunitiesListPage extends StatefulWidget {
  final String uid;
  const CommunitiesListPage({super.key, required this.uid});

  @override
  State<CommunitiesListPage> createState() => _CommunitiesListPageState();
}

class _CommunitiesListPageState extends State<CommunitiesListPage> {
  final _searchCtrl = TextEditingController();
  final _scroll = ScrollController();
  Timer? _searchTimer;

  // Guide §4.1 — paginated (50/page) + server-side search +
  // cached-first: the last saved list renders IMMEDIATELY, fresh
  // data replaces it in the background. The spinner shows only
  // when there is nothing cached to show.
  List<Map<String, dynamic>> _items = [];
  bool _ready = true;
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  int _offset = 0;
  String _query = '';
  int _refreshTick = 0;
  // FIX 23 item 19 — ids followed from a card this session (the
  // Follow button stays hidden for them) + ids with a follow
  // request in flight (double-tap guard).
  final Set<String> _followedIds = {};
  final Set<String> _followBusyIds = {};

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _loadCachedThenFresh();
  }

  @override
  void dispose() {
    _searchTimer?.cancel();
    _searchCtrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients || _loadingMore || !_hasMore || _loading) {
      return;
    }
    if (_scroll.position.pixels >=
        _scroll.position.maxScrollExtent - 200) {
      _loadMore();
    }
  }

  Future<void> _loadCachedThenFresh() async {
    final cached = await CommunityGroups.loadCachedCommunities();
    if (mounted && cached.isNotEmpty) {
      // FIX 12 G15: cached-first list is member-count sorted too.
      setState(() => _items = sortCommunitiesByMembers(cached));
    }
    await _loadPage(0);
  }

  /// Load page 0 (fresh). When [search] is empty the result is
  /// also saved as the cached-first list.
  Future<void> _loadPage(int offset, {String? search}) async {
    final q = (search ?? _query).trim();
    final firstPage = offset == 0;
    if (firstPage) {
      setState(() {
        _loading = _items.isEmpty;
        _hasMore = true;
      });
    }
    final ready = await CommunityGroups.communitiesBackendReady();
    // FIX 12 G15: the server returns newest-first; the list shows
    // member-count DESCENDING (COUNT-based memberCount, attached
    // by _enrich). Sort the page before caching AND the merged
    // list after appending, so paging never breaks the order.
    final list = sortCommunitiesByMembers(
        await CommunityGroups.listCommunities(
            myUid: widget.uid, search: q, offset: offset));
    if (!mounted) return;
    if (firstPage && q.isEmpty) {
      unawaited(CommunityGroups.cacheCommunities(list));
    }
    setState(() {
      _ready = ready;
      _loading = false;
      _loadingMore = false;
      _offset = offset + list.length;
      _hasMore = list.length >= CommunityGroups.pageSize;
      if (firstPage) {
        _items = list;
      } else {
        _items = sortCommunitiesByMembers([..._items, ...list]);
      }
    });
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    setState(() => _loadingMore = true);
    await _loadPage(_offset);
  }

  void _refresh() {
    setState(() => _refreshTick++);
    _loadPage(0);
  }

  void _onSearchChanged(String v) {
    _searchTimer?.cancel();
    _searchTimer = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      setState(() => _query = v.trim());
      _loadPage(0);
    });
  }

  Future<void> _openCreate() async {
    final created = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
          builder: (_) => CreateCommunityPage(uid: widget.uid)),
    );
    if (created == true && mounted) _refresh();
  }

  /// FIX 23 item 19 — Follow from a card = a REAL JOIN:
  /// [CommunityGroups.followCommunity] inserts the
  /// community_members row (verified 2026-11-23), so the tap
  /// joins directly from outside. Success -> the button
  /// DISAPPEARS (no "Following" state on the card; unfollow
  /// lives inside the room). Failure -> the button stays + an
  /// honest toast, never fake success.
  Future<void> _followFromCard(Map<String, dynamic> c) async {
    final id = SupaDb.strOf(c['id']);
    if (id.isEmpty || _followBusyIds.contains(id)) return;
    setState(() => _followBusyIds.add(id));
    final res = await CommunityGroups.followCommunity(widget.uid, id);
    if (!mounted) return;
    setState(() => _followBusyIds.remove(id));
    if (res['ok'] == true) {
      setState(() {
        _followedIds.add(id);
        for (final item in _items) {
          if (SupaDb.strOf(item['id']) == id) {
            item['isMember'] = true;
          }
        }
      });
      toast(context, 'Follow ho gaya — community join ho gayi!');
    } else {
      toast(
          context,
          res['offline'] == true
              ? 'Communities backend abhi online nahi hua (migration 073 pending).'
              : 'Failed: ${res['error']}');
    }
  }

  @override
  Widget build(BuildContext context) {
    // FIX 12 G15: section slots for the STAN-style list — "Top
    // Communities" (top 5 by member count) + "All Communities"
    // when browsing; plain rows when searching.
    //
    // REDESIGN B-S8 (styling only): contract tokens + shared
    // components — [ArenaBackground] gradient, [kStyleTitle] gold
    // header, [ArenaTextField] search, [ArenaLoadingIndicator]
    // spinners, [kSpace16]/[kSpace12]/[kSpace8] spacing. Search,
    // pull-to-refresh, paging, create and the empty state keep
    // their exact behaviour; the FAB stays extended + gold and
    // the 96dp list bottom padding keeps it off the content.
    final slots =
        communityListSlots(_items, searching: _query.isNotEmpty);
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent, // PHASE E (E4): transparent header — poster shows through
        title: Text('COMMUNITIES',
            style: kStyleTitle.copyWith(
                color: kGold,
                fontWeight: FontWeight.w900,
                fontStyle: FontStyle.italic)),
        actions: [
          IconButton(
            icon: Icon(Icons.add_circle, color: kGold),
            tooltip: 'Nayi community banayen',
            onPressed: _openCreate,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: kGold,
        onPressed: _openCreate,
        icon: const Icon(Icons.group_add, color: Colors.black),
        label: const Text('CREATE',
            style: TextStyle(
                color: Colors.black,
                fontSize: 14,
                fontWeight: FontWeight.w900)),
      ),
      body: ArenaBackground(
        showGoldenGlow: true,
        child: _loading && _items.isEmpty
            ? const Center(child: ArenaLoadingIndicator())
            : RefreshIndicator(
                onRefresh: () => _loadPage(0),
                color: kGold,
                child: ListView.builder(
                  key: ValueKey(_refreshTick),
                  controller: _scroll,
                  padding:
                      const EdgeInsets.fromLTRB(kSpace16, kSpace8, kSpace16, 96),
                  // 1 search field + 1 offline banner (when backend is
                  // not ready) + list slots (or the empty state) + 1
                  // load-more spinner while the next page loads.
                  itemCount: 1 +
                      (!_ready ? 1 : 0) +
                      (_items.isEmpty ? 1 : slots.length) +
                      (_loadingMore ? 1 : 0),
                  itemBuilder: (context, index) {
                    if (index == 0) {
                      return Padding(
                        padding: const EdgeInsets.only(bottom: kSpace12),
                        child: ArenaTextField(
                          controller: _searchCtrl,
                          onChanged: _onSearchChanged,
                          hintText: 'Community dhoonden...',
                          suffixIcon: Icon(Icons.search, color: kGold),
                        ),
                      );
                    }
                  final bannerShown = !_ready;
                  if (index == 1 && bannerShown) {
                    return const _OfflineBanner(
                        text:
                            'Communities backend abhi online nahi hua (migration 073 pending) — list jald aa jayegi.');
                  }
                  final slotIndex = index - 1 - (bannerShown ? 1 : 0);
                  if (_items.isEmpty) {
                    return EmptyState(
                      icon: Icons.groups,
                      title: 'Abhi koi community nahi',
                      body:
                          'Pehli community aap banayen — naam, photo aur description dein, baaki players follow karenge.',
                      actionLabel: 'CREATE COMMUNITY',
                      onAction: _openCreate,
                    );
                  }
                  if (slotIndex >= slots.length) {
                    return const Padding(
                      padding: EdgeInsets.symmetric(vertical: kSpace16),
                      child: Center(child: ArenaLoadingIndicator()),
                    );
                  }
                  final slot = slots[slotIndex];
                  if (slot.isHeader) {
                    return CommunitySectionHeader(
                        title: slot.header,
                        star: slot.header == 'Top Communities');
                  }
                  final c = slot.community!;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: kSpace12),
                    child: StanCommunityRow(
                      community: c,
                      // FIX 23 item 19 — Follow (direct join);
                      // hidden after a successful follow.
                      showFollow:
                          !_followedIds.contains(SupaDb.strOf(c['id'])),
                      onFollow: () => unawaited(_followFromCard(c)),
                      onOpen: () async {
                        await Navigator.push(
                          context,
                          MaterialPageRoute(
                              // FIX 22 — the detail page IS the
                              // chat now (tabs removed); tap opens
                              // it directly.
                              builder: (_) => CommunityDetailPage(
                                  uid: widget.uid,
                                  communityId: SupaDb.strOf(c['id']),
                                  community: c)),
                        );
                        if (mounted) _refresh();
                      },
                    ),
                  );
                },
              ),
            ),
      ),
    );
  }
}

class _OfflineBanner extends StatelessWidget {
  final String text;
  const _OfflineBanner({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: kSpace12),
      padding: const EdgeInsets.all(kSpace12),
      decoration: BoxDecoration(
        color: kGold.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(kRadiusChip),
        border: Border.all(color: kGold.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          Icon(Icons.cloud_off, color: kGold, size: 20),
          const SizedBox(width: 10),
          Expanded(
              child: Text(text,
                  style: kStyleBody.copyWith(fontSize: 13))),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------
// CREATE
// ------------------------------------------------------------------

/// FIX 12 G13 (2026-11-23, user order: ONE create form) — the
/// SINGLE entry point for creating a Community or a Squad:
/// name/description/photo fields, then two option boxes that ARE
/// the submit action for their type. The class name and constructor
/// are UNCHANGED from Fix 11 on purpose: TeamsPage,
/// CommunitiesListPage and group G11's Create button all call
/// `CreateCommunityPage(uid: ...)` — no rename.
class CreateCommunityPage extends StatefulWidget {
  final String uid;
  const CreateCommunityPage({super.key, required this.uid});

  @override
  State<CreateCommunityPage> createState() => _CreateCommunityPageState();
}

/// FIX 12 G13 — which box the user tapped (the submit action).
enum _CreateKind { community, squad }

class _CreateCommunityPageState extends State<CreateCommunityPage> {
  final _nameCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  File? _photoFile;
  String _photoUrl = '';
  bool _uploadingPhoto = false;
  bool _creating = false;
  _CreateKind? _creatingKind;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
  }

  /// Photo pick — same pattern as the DM composer (ImagePicker,
  /// compressed at pick time, file_picker fallback when the plugin
  /// is missing), then ImgBB upload.
  Future<void> _pickPhoto() async {
    try {
      String? path;
      try {
        final picked = await ImagePicker().pickImage(
            source: ImageSource.gallery, imageQuality: 85, maxWidth: 1024);
        if (picked == null) return;
        path = picked.path;
      } on MissingPluginException {
        final res = await FilePicker.platform
            .pickFiles(type: FileType.image, allowMultiple: false);
        if (res == null || res.files.isEmpty) {
          return;
        }
        path = res.files.single.path;
      }
      if (path == null) return;
      setState(() {
        _photoFile = File(path!);
        _uploadingPhoto = true;
      });
      final url = await ImgbbService.uploadImage(_photoFile!);
      if (!mounted) return;
      setState(() {
        _uploadingPhoto = false;
        if (url.isNotEmpty) _photoUrl = url;
      });
      if (url.isEmpty) toast(context, 'Photo upload nahi hui — dobara try karen.');
    } catch (e) {
      if (!mounted) return;
      setState(() => _uploadingPhoto = false);
      toast(context, 'Photo pick nahi hui: $e');
    }
  }

  /// FIX 12 G13: the tapped box IS the submit. Community → a
  /// communities row (+ creator member row); Squad → a teams row
  /// (+ captain member row, no is_clan — see
  /// CommunityGroups.createSquad). The name is validated here so
  /// both types share one plain message.
  Future<void> _create(_CreateKind kind) async {
    if (_creating || _uploadingPhoto) return;
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      toast(context, 'Naam likhen.');
      return;
    }
    setState(() {
      _creating = true;
      _creatingKind = kind;
    });
    if (kind == _CreateKind.community) {
      final res = await CommunityGroups.createCommunity(
        creatorUid: widget.uid,
        name: name,
        description: _descCtrl.text,
        photoUrl: _photoUrl,
      );
      if (!mounted) return;
      setState(() {
        _creating = false;
        _creatingKind = null;
      });
      if (res['ok'] == true) {
        toast(context, 'Community ban gayi — mubarak ho!');
        Navigator.pop(context, true);
      } else {
        toast(
            context,
            res['offline'] == true
                ? 'Communities backend abhi online nahi hua (migration 073 pending).'
                : 'Failed: ${res['error']}');
      }
      return;
    }
    final res = await CommunityGroups.createSquad(
      creatorUid: widget.uid,
      name: name,
    );
    if (!mounted) return;
    setState(() {
      _creating = false;
      _creatingKind = null;
    });
    if (res['ok'] == true) {
      // Teams have no photo column — keep the picked photo
      // device-local (FIX 7 mechanism) so the squad card shows it.
      if (_photoUrl.isNotEmpty) {
        await saveTeamPhotoLocal(SupaDb.strOf(res['id']), _photoUrl);
        if (!mounted) return;
      }
      toast(context, 'Squad ban gayi! Invite code: ${res['inviteCode']}');
      Navigator.pop(context, true);
    } else {
      toast(context, 'Failed: ${res['error']}');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent, // PHASE E (E4): transparent header — poster shows through
        title: Text('CREATE',
            style: TextStyle(
                color: kGold,
                fontSize: 20,
                fontWeight: FontWeight.w900,
                fontStyle: FontStyle.italic)),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: GestureDetector(
                onTap: _pickPhoto,
                child: Stack(
                  children: [
                    Container(
                      width: 110,
                      height: 110,
                      decoration: BoxDecoration(
                        color: _cCard,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: kGold, width: 1.5),
                      ),
                      child: _photoFile != null
                          ? ClipRRect(
                              borderRadius: BorderRadius.circular(15),
                              child: Image.file(_photoFile!,
                                  width: 110, height: 110, fit: BoxFit.cover))
                          : Icon(Icons.add_a_photo,
                              color: kGold, size: 40),
                    ),
                    if (_uploadingPhoto)
                      const Positioned.fill(
                          child: Center(
                              child: CircularProgressIndicator())),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 6),
            Center(
                child: Text('Photo (optional)',
                    style: TextStyle(color: kMuted, fontSize: 13))),
            const SizedBox(height: 20),
            ArenaFormField(
                key: const Key('g13_create_name_field'),
                controller: _nameCtrl,
                label: 'Naam',
                hint: 'e.g. PUBG Pro Players'),
            ArenaFormField(
                key: const Key('g13_create_desc_field'),
                controller: _descCtrl,
                label: 'Description',
                hint: 'Is mein kya hota hai?',
                maxLines: 3),
            const SizedBox(height: 8),
            // FIX 12 G13: the two option boxes ARE the submit —
            // Community creates a community, Squad creates a teams
            // row. No separate per-type forms, no Squad/Clan toggle.
            Row(
              children: [
                Expanded(
                  child: _CreateTypeBox(
                    key: const Key('g13_create_community_box'),
                    icon: Icons.groups,
                    label: 'Community',
                    sublabel: 'Posts + chat',
                    busy: _creating &&
                        _creatingKind == _CreateKind.community,
                    enabled: !_creating && !_uploadingPhoto,
                    onTap: () => _create(_CreateKind.community),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _CreateTypeBox(
                    key: const Key('g13_create_squad_box'),
                    icon: Icons.shield,
                    label: 'Squad',
                    sublabel: 'Team + voice room',
                    busy: _creating &&
                        _creatingKind == _CreateKind.squad,
                    enabled: !_creating && !_uploadingPhoto,
                    onTap: () => _create(_CreateKind.squad),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
                'Community chunen to posts aur chat wali public community banegi — aap uske creator ban jayenge. Squad chunen to team banegi, jisme members invite code se join karenge.',
                style: TextStyle(color: kMuted, fontSize: 13)),
          ],
        ),
      ),
    );
  }
}

/// FIX 12 G13 — one of the two submit boxes at the end of the
/// unified create form. A box is a submit action for its type, not
/// a selector: tapping it creates that type at once. Gold #FDC903
/// + black only (kGold / _cCard).
class _CreateTypeBox extends StatelessWidget {
  const _CreateTypeBox({
    super.key,
    required this.icon,
    required this.label,
    required this.sublabel,
    required this.busy,
    required this.enabled,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final String sublabel;
  final bool busy;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 8),
        decoration: BoxDecoration(
          color: _cCard,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: kGold, width: 1.5),
        ),
        child: Column(
          children: [
            if (busy)
              const SizedBox(
                  height: 32,
                  width: 32,
                  child: CircularProgressIndicator(strokeWidth: 2.5))
            else
              Icon(icon, color: kGold, size: 32),
            const SizedBox(height: 8),
            Text(label,
                style: TextStyle(
                    color: kGold,
                    fontSize: 16,
                    fontWeight: FontWeight.w900)),
            const SizedBox(height: 2),
            Text(sublabel,
                textAlign: TextAlign.center,
                style: TextStyle(color: kMuted, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------
// DETAIL — header + Chat / Members tabs
// ------------------------------------------------------------------

/// FIX 15 — community chat kick rule (mirrors watch_live's
/// shouldKickFromWatchLive): a member is kicked out of community
/// chat when restricted AND logged in AND not the designated admin.
/// Organizers are NOT exempt — a global restriction from the app
/// admin kicks anyone, organizer included.
bool shouldKickFromCommunityChat({
  required bool loggedIn,
  required bool isAdmin,
  required bool isRestricted,
}) =>
    loggedIn && !isAdmin && isRestricted;

// ------------------------------------------------------------------
// FIX 22 (2026-11-23, user order: "ye hata do, direct chat nazar
// aye") — the CHAT/MEMBERS tab bar is DELETED: CommunityDetailTab,
// communityDetailTabs, communityDetailTabIndex and _detailTabWidget
// are gone with it. CommunityDetailPage shows the chat directly;
// the members list opens as a pushed page from the header Members
// button (_openMembers → _CommunityMembersPage).
// ------------------------------------------------------------------

// ------------------------------------------------------------------
// FIX 20 (fix 6, user order 2026-11-23): the FIX 12 G10
// live-members strip is deleted — CommunityLiveMember,
// onlineCommunityMembers and LiveMembersStrip are gone with it.
// FIX 23 item 12b: the detail header's own online count is gone
// too (its consumers were removed with the top bar) — the detail
// page now reads only the fresh member count (_loadMemberCount).
// ------------------------------------------------------------------

/// FIX 12 G4 — About sheet for a community (More ⋮ menu → About).
/// Shows the community name, description, CREATED BY (the
/// creator's display name), created date and member count — so
/// anyone can see who created the community. Gold #FDC903
/// ([kGold]) on black, matching the communities guide palette.
/// Values are passed in already resolved (the detail page fetches
/// the creator name + fresh member count before opening the
/// sheet); unknown creator/date read 'Unknown', never a fake.
class CommunityAboutSheet extends StatelessWidget {
  final String name;
  final String description;
  final String creatorName;
  final int createdAtMs;
  final int memberCount;
  const CommunityAboutSheet({
    super.key,
    required this.name,
    required this.description,
    required this.creatorName,
    required this.createdAtMs,
    required this.memberCount,
  });

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(label,
                style: TextStyle(
                    color: kMuted,
                    fontSize: 12,
                    fontWeight: FontWeight.w700)),
          ),
          Expanded(
            child: Text(value,
                style: TextStyle(
                    color: kText,
                    fontSize: 15,
                    fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final date = _aboutDate(createdAtMs);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: _cBorder,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Text('About',
                style: TextStyle(
                    color: kGold,
                    fontSize: 18,
                    fontWeight: FontWeight.w900)),
            const SizedBox(height: 12),
            Text(name,
                style: TextStyle(
                    color: kText,
                    fontSize: 20,
                    fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            Text(
                description.isEmpty
                    ? 'No description yet.'
                    : description,
                style: TextStyle(color: kMuted, fontSize: 14)),
            const SizedBox(height: 14),
            Divider(color: _cBorder, height: 1),
            const SizedBox(height: 8),
            _row('CREATED BY',
                creatorName.isEmpty ? 'Unknown' : creatorName),
            _row('CREATED ON', date.isEmpty ? 'Unknown' : date),
            _row('MEMBERS',
                '$memberCount member${memberCount == 1 ? '' : 's'}'),
          ],
        ),
      ),
    );
  }
}

class CommunityDetailPage extends StatefulWidget {
  final String uid;
  final String communityId;
  final Map<String, dynamic> community;
  // Admin view (guide §4.7): true ONLY when opened from the admin
  // panel (after verifyDesignatedAdmin) — lets the admin moderate
  // the community. Defaults false for normal users.
  final bool isAdmin;
  // FIX 22 — no tabs: the page IS the chat. Every route (list tap,
  // TeamsPage, admin panel) lands on the chat directly.
  const CommunityDetailPage(
      {super.key,
      required this.uid,
      required this.communityId,
      required this.community,
      this.isAdmin = false});

  @override
  State<CommunityDetailPage> createState() => _CommunityDetailPageState();
}

class _CommunityDetailPageState extends State<CommunityDetailPage> {
  late Map<String, dynamic> _community;
  bool _followBusy = false;
  bool _deleteBusy = false;
  // FIX 12 G6 (2026-11-23) — COMMUNITY VOICE ROOM: the FULL voice
  // system moved here from the old clan room (UnifiedRoomPage,
  // embedded, same as the v2017 team panel): host panel + 6 mic
  // seats + mic-request flow + music player/library + RJ Studio
  // + soundboard + listeners. The old single-voice LiveKit
  // connect (_lkVoice + bottom sheet) is DELETED — the room page
  // owns the whole voice session now.
  // FIX 23 item 16a: the panel is mounted ALWAYS for members
  // (the host card is STICKY — never closed, never hidden).
  // Voice connects on mount when unlocked; when locked the
  // panel shows the "Voice locked" line instead of seats
  // (voiceLocked). Leaving the page unmounts the panel, which
  // leaves voice. The old Voice toggle is gone with the top
  // bar (item 1).
  // FIX 20 (fix 7): the header Settings sheet's bridge — the
  // embedded voice panel binds its Music / Room Settings / RJ /
  // Close actions into this controller (the room's
  // _bindVoiceController, item-16 wiring), and the More menu's
  // Voice Settings entry opens the sheet that calls them. Same
  // pattern as TeamChatPage; disposed with the detail page.
  final _voiceController = VoicePanelController();
  // FIX 14 — voice-approval state: this community's request status
  // ('' = none filed, 'pending' | 'approved' | 'rejected'). Loaded
  // in _init only while voice is locked; drives the lock banner +
  // request button. Never blocks the page.
  String _voiceRequestStatus = '';
  bool _voiceRequestBusy = false;
  String _myName = 'Player';
  // FIX 23 item 12b: the online-members count (_onlineCount /
  // _showOnline) is GONE — its only consumers were the removed
  // top-bar sub-line and the removed host-card members button,
  // and the word "Members" must not appear in the room. The
  // presence read that fed it is removed too (no wasted query).
  // FIX 22 item 15: the ORGANIZER's profile followers count
  // (community follow = join, so no community-followers count
  // exists — the sidebar Followers icon shows the organizer's
  // followers). Null until the best-effort read lands (or when
  // it fails) — the icon shows '—', never a fake number.
  // FIX 23 item 12a: that count was the WRONG source for the
  // sidebar (3 profile followers vs the real 4 community
  // members) — it now feeds ONLY the item-19 blue-tick 1000
  // rule. The sidebar shows [_memberCountFresh] below.
  int? _organizerFollowers;
  // FIX 23 item 12a: the COMMUNITY's real member count — a fresh
  // COUNT from community_members (the same source the members
  // list uses), captured in _loadMemberCount. Null until the
  // read lands — the sidebar falls back to the cached count,
  // then to '—', never a fake number.
  int? _memberCountFresh;
  // FIX 23 items 14+21: this page's background id, loaded from the
  // same SharedPreferences key the room's Backgrounds setting
  // writes ('room_bg_id'). Default 'neon' (Neon Nights) — the
  // same default the room uses. [_chatBgUserPicked] is true once
  // a choice was actually stored: while false, the page shows the
  // app-wide background image (AppBackgroundLayer — item 21's
  // bundled artwork, item 22's remote URL when set) instead of
  // the neon gradient. The room notifies this page of a new pick
  // via onBackgroundChanged (_reloadChatBackground), so the chat
  // area updates live, not just on re-entry.
  String _chatBgId = 'neon';
  bool _chatBgUserPicked = false;

  @override
  void initState() {
    super.initState();
    _community = Map<String, dynamic>.from(widget.community);
    _init();
  }

  Future<void> _init() async {
    final me = await SupaDb.getProfile(widget.uid);
    final fresh = await CommunityGroups.getCommunity(widget.communityId,
        myUid: widget.uid);
    if (!mounted) return;
    setState(() {
      final n = SupaDb.strOf(me['display_name']);
      if (n.isNotEmpty) _myName = n;
      if (fresh.isNotEmpty) {
        _community = fresh;
        unawaited(CommunityGroups.cacheCommunity(fresh));
      }
    });
    // FIX 14 — when voice is locked, fetch this community's
    // request status so the lock banner / request button show the
    // right state (none / pending / rejected). Unlocked
    // communities never need it.
    final status = _voiceEnabled
        ? ''
        : await CommunityGroups.voiceRequestStatus(_id);
    if (!mounted) return;
    setState(() => _voiceRequestStatus = status);
    // FIX 23 items 14+21: load the chat background choice (same key
    // the room's Backgrounds setting writes). A failed read
    // keeps the default (app-wide image) — never a blank
    // background.
    await _reloadChatBackground();
    await _loadMemberCount();
    await _loadOrganizerFollowers();
  }

  /// FIX 23 items 14+21: re-read the stored background choice
  /// ('room_bg_id') and apply it. Called at init and whenever the
  /// room reports a new pick (onBackgroundChanged).
  Future<void> _reloadChatBackground() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final id = prefs.getString('room_bg_id');
      if (mounted) {
        setState(() {
          if (id != null && id.isNotEmpty) {
            _chatBgId = id;
            _chatBgUserPicked = true;
          }
        });
      }
    } catch (_) {}
  }

  /// ITEM 4 — header online count (same sources as Match Chat's
  /// team mode): presence rows for this community's member uids,
  /// online = last_seen within 2 minutes (SupaDb.presenceIsOnline).
  /// BOUNDED for scale (guide §4.1): the count comes from COUNT,
  /// and the presence lookup only runs when the community has at
  /// most 1000 members (UIDs fetched one cheap column query, the
  /// presence read chunked 100 at a time so no request carries a
  /// giant UID list). Above 1000 members the online segment is
  /// hidden rather than guessed — never a fake number.
  /// Best-effort, never blocks the page; a failed read leaves 0.
  Future<void> _loadMemberCount() async {
    try {
      final total = await CommunityGroups.memberCount(_id);
      // FIX 23 item 12a: the fresh total IS the sidebar Followers
      // count, from the same source the members list uses.
      if (mounted) setState(() => _memberCountFresh = total);
    } catch (_) {}
  }

  /// FIX 22 item 15: the organizer's profile followers count
  /// for the sidebar Followers icon (same count feeds the
  /// item-19 blue-tick 1000 rule). Best-effort, never blocks
  /// the page; a failed read leaves null (icon shows '—').
  Future<void> _loadOrganizerFollowers() async {
    try {
      final organizerUid = SupaDb.strOf(_community['created_by_uid']);
      if (organizerUid.isEmpty) return;
      final followers = await CommunityService.followers(organizerUid);
      if (mounted) setState(() => _organizerFollowers = followers.length);
    } catch (_) {}
  }

  /// FIX 23 item 4 — Copy community name (was the More menu's
  /// 'copy' case; the menu is gone with the top bar — the action
  /// now lives in the sidebar Settings sheet).
  Future<void> _copyCommunityName() async {
    await Clipboard.setData(ClipboardData(
        text: SupaDb.strOf(_community['name'], 'Community')));
    if (mounted) toast(context, 'Community name copy ho gaya!');
  }

  /// FIX 12 G4 — More ⋮ menu → About: resolves the creator's
  /// display name (role 'creator' → profiles, via
  /// [CommunityGroups.creatorDisplayName]) + a fresh member COUNT
  /// (never the cached row — the cached count goes stale as
  /// members join), then opens the About sheet. A 0 fresh count
  /// reads as the cached count (a failed COUNT must not show
  /// "0 members" for a community that has members).
  Future<void> _showAbout() async {
    final creatorName = await CommunityGroups.creatorDisplayName(_id,
        createdByUid: SupaDb.strOf(_community['created_by_uid']));
    final freshCount = await CommunityGroups.memberCount(_id);
    if (!mounted) return;
    final count = freshCount > 0
        ? freshCount
        : SupaDb.intOf(_community['memberCount']);
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: kCardPurpleMid,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22)), side: const BorderSide(color: kCardPurpleBorder, width: 1.5)),
      builder: (_) => CommunityAboutSheet(
        name: SupaDb.strOf(_community['name'], 'Community'),
        description: SupaDb.strOf(_community['description']),
        creatorName: creatorName,
        createdAtMs: SupaDb.parseTs(
            _community['createdAt'] ?? _community['created_at']),
        memberCount: count,
      ),
    );
  }

  /// FIX 15 — organizer/app-admin clear of this community's chat
  /// history (confirm dialog mirrors the room's _clearChat).
  Future<void> _clearCommunityChat() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kCardPurpleMid,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22), side: const BorderSide(color: kCardPurpleBorder, width: 1.5)),
        title: Text('Clear chat history?',
            style: TextStyle(color: kGold, fontWeight: FontWeight.bold)),
        content: Text(
            'Is community ki poori chat history sab ke liye delete ho jayegi. Ye wapas nahi aayegi.',
            style: TextStyle(color: kText)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text('Cancel', style: TextStyle(color: kMuted))),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Clear Chat',
                  style: TextStyle(
                      color: Colors.redAccent, fontWeight: FontWeight.bold))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final res = await CommunityGroups.clearCommunityChat(
      communityId: _id,
      requesterUid: widget.uid,
      requesterName: _myName,
    );
    if (!mounted) return;
    if (res['ok'] == true) {
      toast(context, 'Chat history clear ho gayi.');
    } else {
      toast(context, 'Clear failed: ${res['error'] ?? 'pata nahi'}');
    }
  }

  @override
  void dispose() {
    // Leaving the page unmounts the voice panel, which leaves
    // voice — a community voice session never outlives the
    // detail page.
    _voiceController.dispose();
    super.dispose();
  }

  bool get _isMember => _community['isMember'] == true;
  bool get _isCreator => SupaDb.strOf(_community['myRole']) == 'creator';
  // FIX 15: voice approved for this community (§1 flag — missing
  // reads as false, fail-closed).
  bool get _voiceApproved =>
      _community['voice_enabled'] == true ||
      _community['voiceEnabled'] == true;
  // FIX 15: organizer powers = creator AND voice approved.
  bool get _canOrganizerModerate => _isCreator && _voiceApproved;
  // FIX 14 — voice unlocked? (communities.voice_enabled, admin
  // approval sets it true forever.) Missing key reads locked.
  bool get _voiceEnabled => CommunityGroups.isVoiceEnabled(_community);
  // FIX 14 — may THIS user file a voice request? The creator is
  // communities.created_by_uid; myRole is only the fallback for a
  // stale cached row that has no created_by_uid yet.
  bool get _isVoiceRequester {
    final creatorUid = SupaDb.strOf(_community['created_by_uid']);
    if (creatorUid.isNotEmpty) return creatorUid == widget.uid;
    return _isCreator;
  }
  bool get _canRequestVoice => CommunityGroups.canRequestVoiceAccess(
      isCreator: _isVoiceRequester,
      voiceEnabled: _voiceEnabled,
      requestStatus: _voiceRequestStatus);
  String get _id => SupaDb.strOf(_community['id'], widget.communityId);

  Future<void> _toggleFollow() async {
    if (_followBusy) return;
    setState(() => _followBusy = true);
    final res = _isMember
        ? await CommunityGroups.unfollowCommunity(widget.uid, _id)
        : await CommunityGroups.followCommunity(widget.uid, _id);
    if (!mounted) return;
    setState(() => _followBusy = false);
    if (res['ok'] == true) {
      await _init();
    } else {
      toast(
          context,
          res['offline'] == true
              ? 'Communities backend abhi online nahi hua (migration 073 pending).'
              : 'Failed: ${res['error']}');
    }
  }

  /// PHASE E (E30): INVITE from a community — NO team gate
  /// anymore. The old flow resolved the caller's team first and
  /// refused without one ("Pehle team banayen...") — a SQUAD rule
  /// wrongly applied to communities — and then sent a TEAM
  /// invite (sendTeamInvite), which invited people to the team,
  /// not the community. Both are gone: this opens the friends
  /// picker (friends list + username search) and each Invite
  /// sends a real community_invite notification via
  /// SupaDb.sendCommunityInvite. No team needed, no toast.
  /// FIX 20: MOVED here from _CommunityChatTabState — the Invite
  /// button lives in the More menu / My Community page, and the
  /// menu lives on this page.
  Future<void> _inviteFromChat() async {
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: kCardPurpleMid,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
          side: BorderSide(color: kCardPurpleBorder, width: 1.5)),
      builder: (ctx) => _CommunityInvitePicker(
        uid: widget.uid,
        communityId: _id,
        communityName: SupaDb.strOf(_community['name'], 'Community'),
      ),
    );
  }

  Future<void> _delete() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kCardPurpleMid,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22), side: const BorderSide(color: kCardPurpleBorder, width: 1.5)),
        title: Text('Community delete karen?',
            style: TextStyle(color: kText)),
        content: Text(
            'Ye community, uski posts, comments aur chat hamesha ke liye delete ho jayenge.',
            style: TextStyle(color: kMuted)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text('Cancel', style: TextStyle(color: kMuted))),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('DELETE',
                  style: TextStyle(
                      color: Colors.red, fontWeight: FontWeight.w900))),
        ],
      ),
    );
    if (confirm != true || _deleteBusy) return;
    setState(() => _deleteBusy = true);
    final res = await CommunityGroups.deleteCommunity(
        communityId: _id, requesterUid: widget.uid);
    if (!mounted) return;
    setState(() => _deleteBusy = false);
    if (res['ok'] == true) {
      toast(context, 'Community delete ho gayi.');
      Navigator.pop(context, true);
    } else {
      toast(context, 'Failed: ${res['error']}');
    }
  }

  /// FIX 14 — locked Voice button tap. Non-creators only ever see
  /// the lock message (no button anywhere). The creator with a
  /// pending request gets the honest wait message; otherwise the
  /// request sheet opens (fresh request, or re-request after a
  /// reject).
  void _onLockedVoiceTap() {
    if (!_isVoiceRequester) {
      toast(context, 'Voice abhi lock hai — admin approval ke baad milegi.');
      return;
    }
    if (_voiceRequestStatus == 'pending') {
      toast(context,
          'Voice request pending hai — admin approval ka intezar karen.');
      return;
    }
    _showVoiceRequestSheet();
  }

  /// FIX 14 — creator-only sheet: why voice is locked + the
  /// request button. The button label differs from the banner's
  /// ('SEND VOICE REQUEST' vs 'REQUEST VOICE ACCESS') so both can
  /// coexist on screen without ambiguity.
  void _showVoiceRequestSheet() {
    final rejected = _voiceRequestStatus == 'rejected';
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: kCardPurpleMid,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22)), side: const BorderSide(color: kCardPurpleBorder, width: 1.5)),
      builder: (sheetCtx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.lock, color: kGold, size: 22),
                  const SizedBox(width: 8),
                  Text('Voice Locked hai',
                      style: TextStyle(
                          color: kText,
                          fontSize: 17,
                          fontWeight: FontWeight.w900)),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                  rejected
                      ? 'Pichli voice request reject ho gayi thi — dobara request kar sakte hain. Admin approve karega to voice is community mein hamesha ke liye unlock ho jayegi.'
                      : 'Is community mein voice sirf admin approval ke baad milegi. Request bhejen — admin approve karega to voice hamesha ke liye unlock ho jayegi.',
                  style: TextStyle(color: kMuted, fontSize: 13)),
              const SizedBox(height: 16),
              GoldButton(
                label: 'SEND VOICE REQUEST',
                busy: _voiceRequestBusy,
                onPressed: _voiceRequestBusy
                    ? null
                    : () async {
                        final ok = await _requestVoiceAccess();
                        if (ok && sheetCtx.mounted) {
                          Navigator.pop(sheetCtx);
                        }
                      },
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// FIX 14 — file the voice request (creator only; the service
  /// re-checks the creator rule). Returns true when the request
  /// landed (or was already pending) — the caller pops the sheet.
  /// Refreshes the page afterwards so a meanwhile-approval flips
  /// the lock open without a manual reload.
  Future<bool> _requestVoiceAccess() async {
    if (_voiceRequestBusy) return false;
    setState(() => _voiceRequestBusy = true);
    final res = await CommunityGroups.requestVoiceAccess(
        communityId: _id, requesterUid: widget.uid);
    if (!mounted) return false;
    setState(() => _voiceRequestBusy = false);
    if (res['ok'] == true) {
      setState(() => _voiceRequestStatus =
          SupaDb.strOf(res['status'], 'pending'));
      toast(
          context,
          res['already'] == true
              ? 'Voice request pehle se pending hai.'
              : 'Voice request bhej di gayi — admin approval ka intezar karen.');
      await _init();
      return true;
    }
    toast(
        context,
        res['offline'] == true
            ? 'Voice requests abhi online nahi hain.'
            : 'Failed: ${res['error']}');
    return false;
  }

  /// FIX 14 — lock banner under the description strip, shown ONLY
  /// while voice is locked. Everyone sees the lock message; ONLY
  /// the creator sees the request button (pending -> a PENDING
  /// label instead of the button). FIX 23 item 1: the banner is
  /// tappable — it carries the old Locked-button tap (lock
  /// message for non-creators, the request sheet for the
  /// creator), since the top bar that held the button is gone.
  Widget _voiceLockBanner() {
    final pending = _voiceRequestStatus == 'pending';
    return InkWell(
      onTap: _onLockedVoiceTap,
      child: Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: _cCard,
        border: Border(bottom: BorderSide(color: _cBorder)),
      ),
      child: Row(
        children: [
          Icon(Icons.lock, color: kGold, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
                pending
                    ? 'Voice request pending hai — admin approval ka intezar karen.'
                    : 'Voice locked hai — admin approval ke baad milegi.',
                style: TextStyle(color: kMuted, fontSize: 13)),
          ),
          if (_isVoiceRequester) ...[
            const SizedBox(width: 8),
            if (pending)
              Text('PENDING',
                  style: TextStyle(
                      color: kGold,
                      fontSize: 12,
                      fontWeight: FontWeight.w900))
            else
              GoldButton(
                label: 'REQUEST VOICE ACCESS',
                busy: _voiceRequestBusy,
                fullWidth: false,
                onPressed:
                    _canRequestVoice ? () => _requestVoiceAccess() : null,
              ),
          ],
        ],
      ),
      ),
    );
  }

  /// FIX 23 item 15 — open the My Community page (creator
  /// only; the entry lives in the sidebar Settings sheet).
  /// Refreshes the detail page when something changed there
  /// (name / description / photo).
  Future<void> _openMyCommunity() async {
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => MyCommunityPage(
          community: _community,
          uid: widget.uid,
          onInvite: () => unawaited(_inviteFromChat()),
          onChanged: () async {
            final fresh = await CommunityGroups.getCommunity(_id,
                myUid: widget.uid);
            if (mounted && fresh.isNotEmpty) {
              setState(() => _community = fresh);
            }
          },
        ),
      ),
    );
    if (changed == true) await _init();
  }

  /// FIX 12 G6 — the panel: the community room page in embedded
  /// mode (same room identity `community_<id>`, same community
  /// scope, 6 mic seats — the SAME full voice room the old clan
  /// room had).
  /// FIX 23 item 16a: the panel is mounted ALWAYS for members
  /// (the host card is STICKY) — no onCloseVoice, so Leave Room
  /// leaves voice but never unmounts the panel. voiceLocked
  /// carries the Fix-14 lock into the room (seats become the
  /// "Voice locked" line; join is refused there).
  Widget _buildVoicePanel() {
    final cachedCount = SupaDb.intOf(_community['memberCount']);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        UnifiedRoomPage(
          scope: 'community',
          communityId: _id,
          communityName: SupaDb.strOf(_community['name'], 'Community'),
          organizerUid: SupaDb.strOf(_community['created_by_uid']),
          // FIX 22 item 14: host-card tagline fallback (the
          // community description; the organizer bio wins when
          // one exists) + dimmed cover behind the card.
          hostCardDescription: SupaDb.strOf(_community['description']),
          hostCardCoverUrl: SupaDb.strOf(_community['photo_url']),
          // FIX 20 (fix 7): the panel binds its Music / Room
          // Settings / RJ / Close actions into this controller
          // (room's _bindVoiceController, item-16 wiring).
          voiceController: _voiceController,
          micCount: 6,
          embedded: true,
          // FIX 72 (2026-11-24): the panel's sidebar reserve —
          // the 236 default leaves the chat tab ~1px (72px bottom
          // overflow at 800x600, 71px at 360x800: the panel took
          // the whole screen). 480 reserves the voice-lock banner
          // (76–154px, measured pre-fix) + host card + header
          // strip (~158px, measured pre-fix) + the chat tab's
          // ~143px minimum — the capped sidebar takes the rest
          // and scrolls. TeamChatPage keeps its own 316 reserve
          // (FIX 31b Defect A, untouched).
          sidebarReserve: 480.0,
          // FIX 23 item 16a — the Fix-14 lock, carried into the
          // room (no onCloseVoice: the card is sticky).
          voiceLocked: !_voiceEnabled,
          onBackgroundChanged: _reloadChatBackground,
          // FIX 23 items 6/9/11/12a: the embedded sidebar's SIX
          // neon round-icon entries — Followers (real community
          // count), Music, RJ Panel, Settings, Power, Leave Room.
          // The organizer's profile-followers count feeds ONLY
          // the item-19 blue-tick 1000 rule now.
          sidebarFollowersCount: _organizerFollowers,
          sidebarCommunityCount:
              _memberCountFresh ?? (cachedCount > 0 ? cachedCount : null),
          sidebarFollowing: _isCreator ? null : _isMember,
          sidebarFollowBusy: _followBusy,
          onSidebarFollowToggle: () => unawaited(_toggleFollow()),
          onSidebarFollowers: _openMembers,
          onSidebarSettings: () => showCommunitySettingsSheet(
            context,
            _voiceController,
            isMember: _isMember,
            isCreator: _isCreator,
            onAbout: () => unawaited(_showAbout()),
            onInvite: () => unawaited(_inviteFromChat()),
            onCopyName: () => unawaited(_copyCommunityName()),
            onMyCommunity: _isCreator ? _openMyCommunity : null,
            onClearChat: (_canOrganizerModerate || widget.isAdmin)
                ? () => unawaited(_clearCommunityChat())
                : null,
            onDeleteCommunity:
                _isCreator ? () => unawaited(_delete()) : null,
          ),
          onSidebarLeaveRoom: () => _voiceController.leaveVoice(),
          onSidebarRjPanel: () => _voiceController.openRjConsole(),
          onSidebarMusic: () => _voiceController.openMusic(),
          // FIX 22 item 19: the verified flag from the community
          // row when the key exists (absent = false — no flag
          // exists in the data today).
          hostCardVerified: profileVerifiedFlag(_community),
        ),
        Divider(color: _cBorder, height: 1),
      ],
    );
  }

  /// FIX 22 — members list as a pushed page (the CHAT/MEMBERS tab
  /// bar is gone; the header Members button calls this). Same
  /// [_MembersTab] widget + same arguments as the old members tab.
  void _openMembers() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _CommunityMembersPage(
          communityId: _id,
          uid: widget.uid,
          isCreator: _isCreator,
          voiceApproved: _voiceApproved,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final count = SupaDb.intOf(_community['memberCount']);
    // FIX 23 item 1: NO AppBar — the whole top bar (back arrow,
    // trophy, title + member count, Members, Voice On, More)
    // is REMOVED. Exit is Leave Room (sidebar) + Android
    // system back. Item 14: the page sits on the code-drawn
    // background (Neon Nights default; the Backgrounds setting
    // overrides it on re-entry).
    return Scaffold(
      body: Container(
        // FIX 23 items 14+21: by DEFAULT (no stored background
        // pick) the page shows the app-wide background image
        // (AppBackgroundLayer) instead of the neon gradient —
        // the image supersedes item 14's code-drawn default. An
        // explicit pick shows its gradient instead; the neon
        // blobs only render for an explicit 'neon' pick.
        decoration: _chatBgUserPicked
            ? BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: roomBackgroundColorsFor(_chatBgId),
                ),
              )
            : null,
        child: Stack(
          children: [
            if (!_chatBgUserPicked)
              const AppBackgroundLayer(respectLightMode: false),
            if (_chatBgId == 'neon' && _chatBgUserPicked) ...[
              Positioned(
                top: -70,
                right: -50,
                child: Container(
                  width: 220,
                  height: 220,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(colors: [
                      _cNeonPurple.withValues(alpha: 0.12),
                      _cNeonPurple.withValues(alpha: 0.0),
                    ]),
                  ),
                ),
              ),
              Positioned(
                bottom: -90,
                left: -60,
                child: Container(
                  width: 240,
                  height: 240,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(colors: [
                      _cNeonPink.withValues(alpha: 0.10),
                      _cNeonPink.withValues(alpha: 0.0),
                    ]),
                  ),
                ),
              ),
            ],
            // PHASE E (E11): the host card sat at y=0 under the status
            // bar — SafeArea pushes CONTENT below it; the
            // background layer stays edge-to-edge (Stack sibling).
            SafeArea(
              top: true,
              bottom: false,
              child: Column(
              children: [
                // FIX 14 — voice lock banner (locked only).
                if (!_voiceEnabled) _voiceLockBanner(),
                // FIX 23 item 16a — the full voice room, mounted
                // ALWAYS for members (the host card is sticky).
                // Non-members see no panel — the chat below
                // shows the Follow-to-join strip instead.
                if (_isMember) _buildVoicePanel(),
                // FIX 22 — no tabs: the chat renders directly.
                Expanded(
                  child: _CommunityChatTab(
                      uid: widget.uid,
                      communityId: _id,
                      isMember: _isMember,
                      memberCount: count,
                      myName: _myName),
                ),
              ],
              ),
            ),
          ],
        ),
      ),
    );
  }

}

class _FollowToInteractBanner extends StatelessWidget {
  final String text;
  const _FollowToInteractBanner({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.all(12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: kGold.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kGold.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          Icon(Icons.lock_outline, color: kGold, size: 18),
          const SizedBox(width: 8),
          Expanded(
              child: Text(text,
                  style: TextStyle(color: kText, fontSize: 13))),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------
// CHAT TAB (realtime, existing chat_messages table)
// ------------------------------------------------------------------

// FIX 22 item 23: legacy CHAT_CLEARED markers (written by the
// room's clear before this fix — no new ones are ever written)
// never render in community chat. The room's own list already
// filtered them; this list did not, so a marker sat STICKY as
// a persistent organizer message in an otherwise-empty chat.
const _chatClearedPrefix = 'CHAT_CLEARED::';

// PHASE E (E14): also match the PLAIN-TEXT legacy notice
// ("— Chat history clear kar di gayi —", written by an old
// version with no CHAT_CLEARED:: prefix) — the prefix filter
// alone let it sit STICKY as an organizer bubble.
bool _isChatClearedRow(Map<String, dynamic> m) {
  final msg = SupaDb.strOf(m['message']);
  return msg.startsWith(_chatClearedPrefix) ||
      msg.contains('Chat history clear kar di gayi');
}

class _CommunityChatTab extends StatefulWidget {
  final String uid;
  final String communityId;
  final bool isMember;
  // Real member count (COUNT-based, from the detail page) — the
  // invite row shows this, never the number of loaded profiles.
  final int memberCount;
  final String myName;
  const _CommunityChatTab(
      {required this.uid,
      required this.communityId,
      required this.isMember,
      required this.memberCount,
      required this.myName});

  @override
  State<_CommunityChatTab> createState() => _CommunityChatTabState();
}

class _CommunityChatTabState extends State<_CommunityChatTab> {
  final _ctrl = TextEditingController();
  final _scroll = ScrollController();
  bool _sending = false;
  bool _uploading = false;
  bool _showEmoji = false;
  // BATCH 3B #27 ADMIN PIN: designated admin only (fail-closed —
  // unreadable admin UID = not admin, same rule as TeamChatPage).
  bool _isAdmin = false;
  // FIX 15 — KICK POLL (mirrors watch_live's 30s poll): a member
  // the organizer community-blocks sees a blocked banner + a
  // disabled composer instead of silently failing sends.
  Timer? _kickTimer;
  bool _chatBlocked = false;
  bool _kickDialogShown = false;
  // _loadAdmin must land first — the designated admin is never
  // kicked, and the poll must not run on a not-yet-known admin.
  bool _adminLoaded = false;
  // Member roles + photos for the #27 rows (avatar, ORGANIZER pill).
  // LAZY (guide §4.1): only the senders actually on screen, never
  // the whole member list.
  final Map<String, Map<String, dynamic>> _memberByUid = {};
  // ITEM 3 — TEAM pill (2026-11-22; FIX 11 2026-11-23 renamed
  // from SQUAD — the Squad team type is gone): sender
  // firebase_uid -> team number. Derived lazily for visible
  // senders only (see _ensureSenderProfiles); numbers are the
  // first-seen order of distinct team_ids among visible senders,
  // stable in this tab.
  Map<String, int> _teamOf = {};
  final Map<String, int> _teamNum = {};
  // FIX 20 (fix 6): the FIX 12 G10 live-members strip is deleted —
  // its presence timer, uid list, live list, profile cache and
  // disabled flag fields, the two loader methods and the 30s
  // timer are gone with it. FIX 23 item 12b: the detail page's
  // own online count is gone too — only the fresh member count
  // (_loadMemberCount) lives on the detail page now.

  // FIX 23 item 7 — LIVE-ONLY chat: only messages created
  // AFTER this entry show. The entry timestamp is captured at
  // init (with a 30s grace for device/server clock skew, so a
  // just-sent live message is never hidden by a fast device
  // clock). Every entry is a fresh session — re-entering the
  // community captures a new entry time and hides everything
  // older. Server history is NOT deleted, just not shown.
  // _messages is newest-first; the ListView is reversed so the
  // newest sits at the bottom. No history is ever loaded.
  late final DateTime _entryTime;
  List<Map<String, dynamic>> _messages = [];
  final Set<String> _knownIds = {};
  // FIX 23 item 7: no history load happens on entry, so there
  // is no loading state — the field stays (read by the build
  // spinner + the message-sound gate) but starts false.
  bool _loading = false;
  StreamSubscription<List<Map<String, dynamic>>>? _streamSub;

  @override
  void initState() {
    super.initState();
    _entryTime = DateTime.now().subtract(const Duration(seconds: 30));
    _loadAdmin();
    _checkKicked();
    _kickTimer =
        Timer.periodic(const Duration(seconds: 30), (_) => _checkKicked());
    _streamSub = CommunityGroups.streamCommunityChat(widget.communityId)
        .listen(_mergeLive);
  }

  @override
  void dispose() {
    _kickTimer?.cancel();
    _streamSub?.cancel();
    _ctrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// FIX 23 item 7 — is this message live (created after this
  /// entry)? Own messages are always live (I can only send
  /// while inside the chat — this also covers clock skew on my
  /// own sends). Missing/unparseable timestamps FAIL OPEN
  /// (show) — a live message must never vanish because its
  /// timestamp is odd.
  bool _isLiveMessage(Map<String, dynamic> m) {
    if (SupaDb.strOf(m['firebase_uid']) == widget.uid) return true;
    final ms = SupaDb.intOf(m['timestamp']);
    if (ms > 0) {
      return DateTime.fromMillisecondsSinceEpoch(ms).isAfter(_entryTime);
    }
    final raw = SupaDb.strOf(m['created_at']);
    if (raw.isEmpty) return true;
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) return true;
    return parsed.isAfter(_entryTime);
  }

  // FIX 20 (fix 6): the two live-members loader methods are
  // deleted with the strip — nothing in this tab reads presence
  // any more (the detail header keeps its own count).

  /// Designated admin (admin_config.admin_firebase_uid) — the only
  /// UID that may pin/unpin in community chat. Fail-closed.
  Future<void> _loadAdmin() async {
    final adminUid = await SupaDb.designatedAdminUid();
    if (!mounted) return;
    setState(() {
      _isAdmin = adminUid.isNotEmpty && adminUid == widget.uid;
      _adminLoaded = true;
    });
    unawaited(_checkKicked());
  }

  /// FIX 23 item 8 — how long the kick/blocked notice stays up
  /// before auto-dismissing (2–3s per the user's order).
  /// Pinned by fix23_community_chat_test.
  static const Duration kKickNoticeDuration =
      Duration(milliseconds: 2500);

  /// FIX 15 — kick enforcement (mirrors watch_live): when the
  /// organizer restricts (blocks/kicks) this member, the next
  /// poll sees it and the composer turns into a blocked banner —
  /// no silent disappearance. Lifting the block un-blocks live.
  Future<void> _checkKicked() async {
    if (!_adminLoaded || _isAdmin) return;
    final restricted = await SupaDb.isChatRestrictedInCommunity(
        widget.uid, widget.communityId);
    if (!mounted) return;
    final shouldKick = shouldKickFromCommunityChat(
      loggedIn: widget.uid.isNotEmpty,
      isAdmin: _isAdmin,
      isRestricted: restricted,
    );
    if (shouldKick == _chatBlocked) return;
    setState(() => _chatBlocked = shouldKick);
    if (!shouldKick) {
      _kickDialogShown = false;
      return;
    }
    if (_kickDialogShown) return;
    _kickDialogShown = true;
    // FIX 23 item 8 — the notice auto-dismisses after ~2.5s
    // (it must never stick around). Tapping OK dismisses it
    // sooner; the timer is cancelled then, so no double-pop.
    var dialogOpen = true;
    final dismissTimer = Timer(kKickNoticeDuration, () {
      if (dialogOpen && mounted) Navigator.of(context).pop();
    });
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kCardPurpleMid,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22), side: const BorderSide(color: kCardPurpleBorder, width: 1.5)),
        title: Text('Chat se hata diya gaya',
            style: TextStyle(color: kGold, fontWeight: FontWeight.bold)),
        content: Text(
            'Organizer ne aapko is community ki chat se hata diya hai. Aap members dekh sakte hain, chat nahi kar sakte.',
            style: TextStyle(color: kText)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('OK', style: TextStyle(color: kGold))),
        ],
      ),
    );
    dialogOpen = false;
    dismissTimer.cancel();
  }

  /// Live arrivals from the realtime stream (newest 50): anything
  /// not seen yet is a new message — prepend it, newest first.
  /// FIX 23 item 7 — the stream's first emission includes
  /// HISTORY, so the live filter here is load-bearing: only
  /// post-entry messages ever enter the list.
  void _mergeLive(List<Map<String, dynamic>> live) {
    if (!mounted) return;
    final fresh = live
        .where((m) => !_isChatClearedRow(m))
        .where(_isLiveMessage)
        .where((m) => _knownIds.add(SupaDb.strOf(m['id'])))
        .toList();
    if (fresh.isEmpty) return;
    // MESSAGE SOUNDS: fresh message from someone else while inside
    // this chat -> the short in-chat pop (chat_08). FIX 23 item 7:
    // only post-entry messages reach here, so the beep is always
    // for a live message; own sends never beep.
    if (!_loading &&
        fresh.any((m) => SupaDb.strOf(m['firebase_uid']) != widget.uid)) {
      MessageSounds.play(MessageSound.chat);
    }
    fresh.sort((a, b) => SupaDb.intOf(b['timestamp'])
        .compareTo(SupaDb.intOf(a['timestamp'])));
    setState(() => _messages = [...fresh, ..._messages]);
    _ensureSenderProfiles();
  }

  /// Sender profiles + roles + squad numbers for the senders
  /// actually in the loaded messages — one profiles query + one
  /// roles query per batch of NEW senders, never the member list.
  Future<void> _ensureSenderProfiles() async {
    final wanted = _messages
        .map((m) => SupaDb.strOf(m['firebase_uid']))
        .where((u) => u.isNotEmpty && !_memberByUid.containsKey(u))
        .toSet()
        .toList();
    if (wanted.isEmpty) return;
    final profiles = await CommunityService.publicProfiles(wanted);
    final roles =
        await CommunityGroups.memberRoles(widget.communityId, wanted);
    if (!mounted) return;
    setState(() {
      for (final p in profiles) {
        final uid = SupaDb.strOf(p['firebase_uid']);
        if (uid.isEmpty) continue;
        final m = Map<String, dynamic>.from(p);
        m['role'] = roles[uid] ?? 'member';
        _memberByUid[uid] = m;
      }
      // Senders with no public profile still get their role, so
      // the ORGANIZER pill never depends on the profile read.
      for (final uid in wanted) {
        if (_memberByUid.containsKey(uid)) continue;
        _memberByUid[uid] = {
          'firebase_uid': uid,
          'display_name': 'Player',
          'displayName': 'Player',
          'role': roles[uid] ?? 'member',
        };
      }
    });
    // ITEM 3 — TEAM pill derivation (2026-11-22): per sender,
    // their OWN first team via SupaDb.getMyFirstTeam. Bounded by
    // the visible senders only (was: one lookup per member).
    // A member with no team gets NO number and NO pill — never an
    // invented name. Best-effort, one lookup per new sender.
    final teamOf = Map<String, int>.from(_teamOf);
    for (final uid in wanted) {
      if (teamOf.containsKey(uid)) continue;
      final team = await SupaDb.getMyFirstTeam(uid);
      final teamId = SupaDb.strOf(team['id']);
      if (teamId.isEmpty) continue;
      final n = _teamNum.putIfAbsent(teamId, () => _teamNum.length + 1);
      teamOf[uid] = n;
      if (!mounted) return;
    }
    if (mounted) setState(() => _teamOf = teamOf);
  }

  Future<void> _send() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty || _sending) return;
    if (_showEmoji) setState(() => _showEmoji = false);
    setState(() => _sending = true);
    final res = await CommunityGroups.sendCommunityChatMessage(
      communityId: widget.communityId,
      fromUid: widget.uid,
      displayName: widget.myName,
      message: text,
    );
    if (!mounted) return;
    setState(() => _sending = false);
    if (res['ok'] == true) {
      _ctrl.clear();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          // Reversed list: the newest message sits at offset 0.
          _scroll.animateTo(0,
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOut);
        }
      });
    } else {
      toast(
          context,
          res['offline'] == true
              ? 'Community chat backend abhi online nahi hua (migration 073 pending).'
              : 'Failed: ${res['error']}');
    }
  }

  /// P1-7 PHOTO SHARE — same proven path as the DM picture flow:
  /// pick (ImagePicker, compressed at pick time, file_picker fallback)
  /// -> probe the image_url column FIRST -> ImgBB upload -> send with
  /// the image URL. Renders via ArenaChatMessage(imageUrl:).
  Future<void> _sendImage() async {
    if (!widget.isMember || _sending || _uploading) return;
    File? file;
    try {
      try {
        final picked = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 85, maxWidth: 1024);
        if (picked == null) return;
        file = File(picked.path);
      } on MissingPluginException {
        final res = await FilePicker.platform.pickFiles(type: FileType.image, allowMultiple: false);
        if (res == null || res.files.isEmpty || res.files.single.path == null) return;
        file = File(res.files.single.path!);
      }
    } catch (_) {
      if (mounted) toast(context, 'Photo nahi khul saki — dobara koshish karein.');
      return;
    }
    final lower = file.path.toLowerCase();
    if (!lower.endsWith('.jpg') && !lower.endsWith('.jpeg') && !lower.endsWith('.png')) {
      if (mounted) toast(context, 'Sirf JPG ya PNG photo allowed hai.');
      return;
    }
    try {
      if (await file.length() > 5 * 1024 * 1024) {
        if (mounted) toast(context, 'Photo 5MB se bari hai — chhoti photo chunen.');
        return;
      }
    } catch (_) {}
    if (!mounted) return;
    setState(() => _uploading = true);
    final ready = await CommunityService.dmImageColumnReady();
    if (!mounted) return;
    if (!ready) {
      setState(() => _uploading = false);
      toast(context, 'Photo messages abhi available nahi — backend update pending hai.');
      return;
    }
    String url;
    try {
      url = await ImgbbService.uploadImage(file);
    } catch (e) {
      if (!mounted) return;
      setState(() => _uploading = false);
      toast(context, 'Photo upload failed: $e');
      return;
    }
    final res = await CommunityGroups.sendCommunityChatImageMessage(
      communityId: widget.communityId,
      fromUid: widget.uid,
      displayName: widget.myName,
      imageUrl: url,
    );
    if (!mounted) return;
    setState(() => _uploading = false);
    if (res['ok'] != true) {
      toast(
          context,
          res['needs_column'] == true
              ? 'Photo messages abhi available nahi — backend update pending hai.'
              : 'Failed: ${res['error']}');
    }
  }

  // FIX 23 item 10c — the like/dislike (👍👎) reactions row is
  // REMOVED from community chat (the old _reactionRow +
  // _toggleReaction lived here). Team chat keeps its own
  // reactions (pro_features.dart) — untouched.
  /// Mockup #27 flag icon: report a message to the admin (real
  /// `disputes` row via SupaDb.reportChatMessage). Community chat had
  /// no report path at all before this.
  Future<void> _reportMessage(Map<String, dynamic> m) async {
    final senderUid = SupaDb.strOf(m['firebase_uid']);
    if (senderUid.isEmpty || senderUid == widget.uid) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: kCardPurpleMid,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22), side: const BorderSide(color: kCardPurpleBorder, width: 1.5)),
        title: Text('Report message?', style: TextStyle(color: kText)),
        content: Text('Ye message admin ko report hoga.', style: TextStyle(color: kMuted)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text('Cancel', style: TextStyle(color: kMuted))),
          TextButton(onPressed: () => Navigator.pop(context, true), child: Text('Report', style: TextStyle(color: kGold))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      final raw = SupaDb.strOf(m['message']);
      final excerpt = raw.isEmpty ? 'Photo message' : raw;
      await SupaDb.reportChatMessage(
        raisedBy: widget.uid,
        raisedByName: widget.myName,
        againstUid: senderUid,
        reason: 'Chat report [message ${SupaDb.strOf(m['id'])}] Inappropriate: "${excerpt.length > 120 ? excerpt.substring(0, 120) : excerpt}"',
      );
      if (mounted) toast(context, 'Report admin ko bhej diya.');
    } catch (e) {
      if (mounted) toast(context, 'Report failed: $e');
    }
  }

  /// BATCH 3B #27 ADMIN PIN/UNPIN (community chat): designated admin
  /// long-press only (fail-closed — non-admins never get the sheet).
  /// pinned_messages cannot represent a community (008:
  /// tournament_id is NOT NULL and there is no community column),
  /// so the pin lives on the message itself via chat_messages.pinned
  /// (019 §6, live; normChat passes the flag through). Pinning a new
  /// message unpins any older pinned one first, so the banner below
  /// always shows exactly one message. The banner reads the flag off
  /// the same realtime stream, so every member sees pin/unpin live
  /// with no extra fetch. Photo messages pin fine here (the banner
  /// shows "Photo message" for them — unlike the text-only
  /// pinned_messages rows the tournament/room chats use).
  Future<void> _showMessageActions(Map<String, dynamic> m) async {
    if (!_isAdmin) return;
    final id = SupaDb.strOf(m['id']);
    if (id.isEmpty) return;
    final isPinned = m['pinned'] == true;
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: kCardPurpleMid,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22)), side: const BorderSide(color: kCardPurpleBorder, width: 1.5)),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            ListTile(
              leading: Icon(Icons.push_pin, color: kGold),
              title: Text(isPinned ? 'Unpin message' : 'Pin message',
                  style: TextStyle(color: kText, fontWeight: FontWeight.bold)),
              subtitle: Text(
                  isPinned
                      ? 'Ye pinned banner se hat jayega.'
                      : 'Ye message sab ke liye upar pin ho jayega.',
                  style: TextStyle(color: kMuted, fontSize: 12)),
              onTap: () => Navigator.pop(ctx, isPinned ? 'unpin' : 'pin'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    try {
      if (action == 'pin') {
        await SupaDb.client
            .from('chat_messages')
            .update({'pinned': false})
            .eq('scope', 'community')
            .eq('community_id', widget.communityId)
            .eq('pinned', true);
        await SupaDb.client
            .from('chat_messages')
            .update({'pinned': true})
            .eq('id', id);
        if (mounted) toast(context, 'Message pin ho gaya.');
      } else {
        await SupaDb.client
            .from('chat_messages')
            .update({'pinned': false})
            .eq('id', id);
        if (mounted) toast(context, 'Message unpin ho gaya.');
      }
    } catch (e) {
      if (mounted) toast(context, 'Pin failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    // BATCH 3B #27 PINNED BANNER: the latest message with
    // chat_messages.pinned == true, read off the loaded messages
    // (no extra fetch; unpin hides it).
    Map<String, dynamic>? pinnedMsg;
    for (final pm in _messages) {
      if (pm['pinned'] == true) pinnedMsg = pm;
    }
    final pinnedText = pinnedMsg == null
        ? ''
        : (SupaDb.strOf(pinnedMsg['message']).isEmpty
            ? 'Photo message'
            : SupaDb.strOf(pinnedMsg['message']));
    return Column(
      children: [
        // FIX 20 (user order 2026-11-23, v2019 screenshots): the
        // "N members + Invite" row is GONE from below the mic
        // seats — Invite moved into the More menu, the member
        // count moved under the voice-room "Not connected" pill.
        // The LIVE-members strip below it is gone too (fix 6):
        // LiveMembersStrip + its presence refresh are deleted.
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _messages.isEmpty
                  // FIX 72: the empty state scrolls instead of
                  // overflowing — at the chat tab's ~143–205px
                  // heights the message area is shorter than the
                  // empty state's ~170px content, and a bare
                  // Column reports a bottom overflow (93px at
                  // 360x800, measured pre-fix). At full height
                  // this renders identically; at partial height
                  // the top shows and the rest scrolls.
                  ? const SingleChildScrollView(
                      child: EmptyState(
                        icon: Icons.chat_bubble_outline,
                        title: 'Abhi koi chat nahi',
                        body: 'Pehla message aap bhejen — members yahan baat karenge.',
                      ),
                    )
                  : Column(
                      children: [
                        if (pinnedMsg != null)
                          ArenaPinnedBanner(
                            message: pinnedText,
                            onView: () => showDialog<void>(
                              context: context,
                              builder: (context) => AlertDialog(
                                backgroundColor: kCardPurpleMid,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22), side: const BorderSide(color: kCardPurpleBorder, width: 1.5)),
                                title: Text('Pinned Message',
                                    style: TextStyle(color: kGold)),
                                content: Text(pinnedText,
                                    style: TextStyle(color: kText)),
                                actions: [
                                  TextButton(
                                      onPressed: () => Navigator.pop(context),
                                      child: Text('Close',
                                          style: TextStyle(color: kGold)))
                                ],
                              ),
                            ),
                          ),
                        Expanded(
                          child: ListView.builder(
                            controller: _scroll,
                            reverse: true,
                            padding: const EdgeInsets.all(14),
                            itemCount: _messages.length,
                            itemBuilder: (ctx, i) {
                              final m = _messages[i];
                              final mine =
                                  SupaDb.strOf(m['firebase_uid']) == widget.uid;
                              final senderUid = SupaDb.strOf(m['firebase_uid']);
                              final sender = _memberByUid[senderUid];
                              final senderName = SupaDb.strOf(
                                  m['display_name'],
                                  SupaDb.strOf(sender?['display_name'], 'Player'));
                              final role = SupaDb.strOf(sender?['role']);
                              final isOrganizer =
                                  role == 'creator' || role == 'admin';
                              final imageUrl = SupaDb.strOf(m['image_url']);
                              // Mockup #27 own header "Player (You) Lv.5 07:48 PM":
                              // the level is already in the loaded member map
                              // (members() merges public profiles, which carry
                              // 'level'); no new data call. Peers get no Lv. pill,
                              // same as TeamChatPage.
                              final myLevel = SupaDb.intOf(
                                  _memberByUid[widget.uid]?['level'], 0);
                              // Mockup #27 row (shared [ArenaChatMessage]).
                              // FIX 23 item 10 — NEON bubbles, ALL
                              // left-aligned (alignEnd: false —
                              // messages never sit on the right),
                              // tighter between-message gap, and
                              // NO like/dislike buttons (the
                              // reactions row is gone from
                              // community chat; team chat keeps
                              // its own). Creator/admin get the
                              // gold role pill straddling a
                              // gold-border bubble.
                              return ArenaChatMessage(
                                isMine: mine,
                                alignEnd: false,
                                neon: true,
                                // FIX 12 G10 — polished bubbles in
                                // community chat (rounder, deeper
                                // shadow, richer gold on own).
                                polished: true,
                                text: SupaDb.strOf(m['message']),
                                imageUrl: imageUrl,
                                onImageTap: imageUrl.isEmpty
                                    ? null
                                    : () => showChatImageDialog(context, imageUrl),
                                timeLabel: _chatClock(SupaDb.intOf(m['timestamp'])),
                                senderName: senderName,
                                showYouSuffix: mine,
                                level: mine && myLevel > 0 ? myLevel : null,
                                avatar: mine
                                    ? null
                                    : _initialAvatar(senderName,
                                        SupaDb.strOf(sender?['photo_url']),
                                        radius: 20),
                                isOrganizer: isOrganizer,
                                // ITEM 5 (2026-11-22): the pill label is ORGANIZER
                                // for BOTH creator and admin messages — only the
                                // label changed; who gets the pill is unchanged.
                                roleLabel: 'ORGANIZER',
                                // ITEM 3 — TEAM pill: 'TEAM N' next to the
                                // sender name (FIX 11 renamed from 'SQUAD N'),
                                // only when this sender has a real team (see
                                // _teamOf); '' = no pill. NOTE: the shared
                                // ArenaChatMessage renders the pill only on
                                // other-member rows — organizer rows and own
                                // messages never show it (shared component).
                                squadLabel: _teamOf.containsKey(senderUid)
                                    ? 'TEAM ${_teamOf[senderUid]}'
                                    : '',
                                onReport:
                                    mine || isOrganizer ? null : () => _reportMessage(m),
                                // BATCH 3B #27: designated-admin long-press ->
                                // Pin/Unpin sheet (see _showMessageActions).
                                onLongPress:
                                    _isAdmin ? () => _showMessageActions(m) : null,
                              );
                
                            },
                          ),
                        ),
                      ],
                    ),
        ),
        // FIX 15: a community-blocked member sees the blocked
        // banner instead of the composer (kick).
        if (_chatBlocked)
          const _FollowToInteractBanner(
              text:
                  'Aapko is community ki chat se hata diya gaya hai — organizer se rabta karein.')
        else if (widget.isMember) ...[
          // Mockup #27 composer (shared [ArenaChatInputBar]): pill
          // field "Type a message..." + emoji + photo inside, gold
          // round send button. Emoji opens the shared built-in
          // picker above the bar.
          if (_showEmoji)
            ArenaEmojiPicker(
              onSelected: (e) => insertEmojiAtCursor(_ctrl, e),
            ),
          // FIX 12 G10 — polished composer: a thin gold divider
          // above the input bar, separating it from the messages.
          Container(
            decoration: BoxDecoration(
              border: Border(
                  top: BorderSide(color: kGold.withValues(alpha: 0.25))),
            ),
            child: ArenaChatInputBar(
              controller: _ctrl,
              onSend: _send,
              onEmoji: () => setState(() => _showEmoji = !_showEmoji),
              onAttach: _sendImage,
              attachIcon: Icons.image,
              attachTooltip: 'Send a photo',
              busy: _uploading,
            ),
          ),
        ] else
          const _FollowToInteractBanner(
              text: 'Chat karne ke liye pehle Follow karen.'),
      ],
    );
  }
}

/// FIX 22 — the followers list as its own page (the CHAT/MEMBERS
/// tab bar is gone; the sidebar Followers entry pushes this via
/// [_CommunityDetailPageState._openMembers]). Same [_MembersTab]
/// widget + same arguments as the old members tab.
/// FIX 23 item 12b: titled 'Followers' — the word "Members"
/// must not appear in the room.
class _CommunityMembersPage extends StatelessWidget {
  final String communityId;
  final String uid;
  final bool isCreator;
  final bool voiceApproved;
  const _CommunityMembersPage(
      {required this.communityId,
      required this.uid,
      required this.isCreator,
      required this.voiceApproved});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent, // PHASE E (E4): transparent header — poster shows through
        title: Text('Followers',
            style: TextStyle(
                color: kGold,
                fontSize: 20,
                fontWeight: FontWeight.w900,
                fontStyle: FontStyle.italic)),
      ),
      body: _MembersTab(
          communityId: communityId,
          uid: uid,
          isCreator: isCreator,
          voiceApproved: voiceApproved),
    );
  }
}

// ------------------------------------------------------------------
// MEMBERS TAB
// ------------------------------------------------------------------

class _MembersTab extends StatefulWidget {
  final String communityId;
  final String uid;
  final bool isCreator;
  // FIX 15: organizer block/unblock needs voice approval.
  final bool voiceApproved;
  const _MembersTab(
      {required this.communityId,
      required this.uid,
      required this.isCreator,
      required this.voiceApproved});

  @override
  State<_MembersTab> createState() => _MembersTabState();
}

class _MembersTabState extends State<_MembersTab> {
  final _scroll = ScrollController();
  final _searchCtrl = TextEditingController();
  Timer? _debounce;
  List<Map<String, dynamic>> _members = [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  // True while a search query is active — the list then shows the
  // search results (server-side, capped 50) with no load-more.
  bool _inSearch = false;
  // FIX 15: UIDs currently community-blocked (scoped rows) — one
  // query per tab load; the Block/Unblock menu reads this set.
  Set<String> _restrictedUids = {};
  // FIX 23 item 12d — presence for the loaded members (same
  // 2-minute rule as the detail header): green dot = online.
  Map<String, Map<String, dynamic>> _presence = {};

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _loadPage();
    _loadRestricted();
  }

  /// FIX 23 item 12d — load presence for the members currently
  /// in the list (chunked 100 at a time, same as the detail
  /// header). Best-effort; a failed read leaves no dots.
  Future<void> _loadPresence() async {
    final uids = _members
        .map((m) => SupaDb.strOf(m['firebase_uid']))
        .where((u) => u.isNotEmpty)
        .toSet()
        .toList();
    if (uids.isEmpty) return;
    try {
      final map = <String, Map<String, dynamic>>{};
      for (var i = 0; i < uids.length; i += 100) {
        final chunk = uids.sublist(
            i, i + 100 > uids.length ? uids.length : i + 100);
        map.addAll(await SupaDb.getPresenceMap(chunk));
      }
      if (mounted) setState(() => _presence = map);
    } catch (_) {}
  }

  Future<void> _loadRestricted() async {
    final uids =
        await CommunityGroups.restrictedMemberUids(widget.communityId);
    if (!mounted) return;
    setState(() => _restrictedUids = uids);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients ||
        _loadingMore ||
        !_hasMore ||
        _loading ||
        _inSearch) {
      return;
    }
    if (_scroll.position.pixels >=
        _scroll.position.maxScrollExtent - 200) {
      _loadPage();
    }
  }

  Future<void> _loadPage() async {
    if (_loadingMore) return;
    final first = _members.isEmpty && !_inSearch;
    if (!first) setState(() => _loadingMore = true);
    final got = await CommunityGroups.members(widget.communityId,
        offset: first ? 0 : _members.length);
    if (!mounted) return;
    setState(() {
      _members = first ? got : [..._members, ...got];
      _loading = false;
      _loadingMore = false;
      _hasMore = got.length >= CommunityGroups.pageSize;
    });
    unawaited(_loadPresence());
  }

  Future<void> _refresh() async {
    _debounce?.cancel();
    _searchCtrl.clear();
    setState(() {
      _inSearch = false;
      _members = [];
      _loading = true;
      _hasMore = true;
    });
    await _loadPage();
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () async {
      final q = value.trim();
      if (q.isEmpty) {
        await _refresh();
        return;
      }
      setState(() {
        _inSearch = true;
        _loading = true;
      });
      final results = await CommunityGroups.searchMembers(
          widget.communityId, q);
      if (!mounted) return;
      setState(() {
        _members = results;
        _loading = false;
        _hasMore = false;
      });
    });
  }

  Future<void> _promote(String targetUid, String toRole) async {
    final res = await CommunityGroups.promoteMember(
        communityId: widget.communityId,
        requesterUid: widget.uid,
        targetUid: targetUid,
        toRole: toRole);
    if (!mounted) return;
    if (res['ok'] == true) {
      setState(() {
        for (final m in _members) {
          if (SupaDb.strOf(m['firebase_uid']) == targetUid) {
            m['role'] = toRole;
          }
        }
      });
      toast(context,
          toRole == 'admin' ? 'Admin bana diya.' : 'Admin hata diya.');
    } else {
      toast(context, 'Failed: ${res['error']}');
    }
  }

  /// FIX 15 — organizer blocks a member INSIDE this community
  /// only (community-scoped chat_restrictions row).
  Future<void> _restrictMember(String targetUid, String name) async {
    final res = await CommunityGroups.restrictMemberInCommunity(
        communityId: widget.communityId,
        requesterUid: widget.uid,
        targetUid: targetUid);
    if (!mounted) return;
    if (res['ok'] == true) {
      setState(() => _restrictedUids.add(targetUid));
      toast(context, '$name ko is community ki chat se hata diya.');
    } else {
      toast(context, 'Block failed: ${res['error']}');
    }
  }

  /// FIX 15 — organizer lifts a community block.
  Future<void> _unrestrictMember(String targetUid, String name) async {
    final res = await CommunityGroups.unrestrictMemberInCommunity(
        communityId: widget.communityId,
        requesterUid: widget.uid,
        targetUid: targetUid);
    if (!mounted) return;
    if (res['ok'] == true) {
      setState(() => _restrictedUids.remove(targetUid));
      toast(context, '$name ka block khatam ho gaya.');
    } else {
      toast(context, 'Unblock failed: ${res['error']}');
    }
  }

  void _onMemberAction(
      String targetUid, String name, String role, String value) {
    if (value == 'admin' || value == 'member') {
      _promote(targetUid, value);
    } else if (value == 'block') {
      _restrictMember(targetUid, name);
    } else if (value == 'unblock') {
      _unrestrictMember(targetUid, name);
    }
  }

  /// FIX 23 item 12d — the member avatar with a green ONLINE
  /// dot (bottom-right) when this follower's presence says
  /// online (2-minute rule). No presence row = no dot, never a
  /// guessed online state.
  Widget _memberAvatarWithDot(String name, String photoUrl, String uid) {
    final online = uid.isNotEmpty &&
        _presence.containsKey(uid) &&
        SupaDb.presenceIsOnline(_presence[uid]!);
    final avatar = _initialAvatar(name, photoUrl);
    if (!online) return avatar;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        avatar,
        Positioned(
          right: 0,
          bottom: 0,
          child: Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.greenAccent,
              border: Border.all(color: _cCard, width: 2),
            ),
          ),
        ),
      ],
    );
  }

  Widget _rolePill(String role) {
    if (role == 'creator') {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
            color: kGold, borderRadius: BorderRadius.circular(6)),
        child: const Text('CREATOR',
            style: TextStyle(
                color: Colors.black,
                fontSize: 10,
                fontWeight: FontWeight.w900)),
      );
    }
    if (role == 'admin') {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
            color: kGold.withValues(alpha: 0.2),
            borderRadius: BorderRadius.circular(6)),
        child: Text('ADMIN',
            style: TextStyle(
                color: kGold, fontSize: 10, fontWeight: FontWeight.w900)),
      );
    }
    return const SizedBox.shrink();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
          // FIX 23 item 29: card look via CardFieldShell.
          child: CardFieldShell(
            child: TextField(
            controller: _searchCtrl,
            onChanged: _onSearchChanged,
            style: TextStyle(color: kText),
            decoration: InputDecoration(
              hintText: 'Follower dhoondhen...',
              hintStyle: TextStyle(color: kMuted),
              prefixIcon: Icon(Icons.search, color: kMuted),
              suffixIcon: _searchCtrl.text.isEmpty
                  ? null
                  : IconButton(
                      icon: Icon(Icons.clear, color: kMuted, size: 20),
                      onPressed: () => _onSearchChanged(''),
                    ),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              border: const OutlineInputBorder(borderSide: BorderSide.none),
              enabledBorder: const OutlineInputBorder(borderSide: BorderSide.none),
              focusedBorder: const OutlineInputBorder(borderSide: BorderSide.none),
            ),
          ),
          ),
        ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _members.isEmpty
                  ? EmptyState(
                      icon: Icons.people_outline,
                      title: _inSearch
                          ? 'Koi follower nahi mila'
                          : 'Koi follower nahi',
                      body: _inSearch
                          ? 'Is naam ka koi follower is community mein nahi hai.'
                          : 'Abhi is community mein koi follower nahi hai.',
                    )
                  : RefreshIndicator(
                      onRefresh: _refresh,
                      child: ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.all(12),
                        itemCount: _members.length +
                            (_loadingMore ? 1 : 0),
                        itemBuilder: (ctx, i) {
                          if (i >= _members.length) {
                            return const Padding(
                              padding: EdgeInsets.symmetric(vertical: 16),
                              child: Center(
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2)),
                            );
                          }
                          final m = _members[i];
                          final role = SupaDb.strOf(m['role'], 'member');
                          final name =
                              SupaDb.strOf(m['display_name'], 'Player');
                          final memberUid = SupaDb.strOf(m['firebase_uid']);
                          // Creator manages roles (guide §4.3): any
                          // member except the creator row and self.
                          final canManage = widget.isCreator &&
                              memberUid.isNotEmpty &&
                              memberUid != widget.uid &&
                              role != 'creator';
                          // GLOBAL CARD RULE (2026-11-22 polish):
                          // standard card, parked shines, no border.
                          return MockupCard(
                            padding: EdgeInsets.zero,
                            radius: 12,
                            animate: false,
                            child: ListTile(
                              onTap: memberUid.isEmpty
                                  ? null
                                  : () => Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                          builder: (_) => PublicProfilePage(
                                              uid: widget.uid,
                                              targetUid: memberUid))),
                              leading: _memberAvatarWithDot(
                                  name, SupaDb.strOf(m['photo_url']), memberUid),
                              title: Text(name,
                                  style: TextStyle(
                                      color: kText,
                                      fontWeight: FontWeight.w800)),
                              subtitle: Text(
                                  '@${SupaDb.strOf(m['username']).isEmpty ? 'player' : SupaDb.strOf(m['username'])}',
                                  style: TextStyle(
                                      color: kMuted, fontSize: 12)),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (memberUid == widget.uid)
                                    Container(
                                      margin: const EdgeInsets.only(right: 6),
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 8, vertical: 3),
                                      decoration: BoxDecoration(
                                          color: kGold.withValues(alpha: 0.2),
                                          borderRadius:
                                              BorderRadius.circular(6)),
                                      child: Text('YOU',
                                          style: TextStyle(
                                              color: kGold,
                                              fontSize: 10,
                                              fontWeight: FontWeight.w900)),
                                    ),
                                  _rolePill(role),
                                  if (canManage)
                                    PopupMenuButton<String>(
                                      icon: Icon(Icons.more_vert,
                                          color: kMuted, size: 20),
                                      color: _cCard,
                                      onSelected: (v) => _onMemberAction(
                                          memberUid, name, role, v),
                                      itemBuilder: (_) => [
                                        PopupMenuItem(
                                          value: role == 'admin'
                                              ? 'member'
                                              : 'admin',
                                          child: Text(
                                              role == 'admin'
                                                  ? 'Remove admin'
                                                  : 'Make admin',
                                              style:
                                                  TextStyle(color: kText)),
                                        ),
                                        // FIX 15: organizer block /
                                        // unblock (voice approved
                                        // only) — community-scoped.
                                        if (widget.voiceApproved)
                                          PopupMenuItem(
                                            value: _restrictedUids
                                                    .contains(memberUid)
                                                ? 'unblock'
                                                : 'block',
                                            child: Text(
                                                _restrictedUids
                                                        .contains(memberUid)
                                                    ? 'Unblock in community'
                                                    : 'Block in community',
                                                style: TextStyle(
                                                    color: Colors.redAccent)),
                                          ),
                                      ],
                                    ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
        ),
      ],
    );
  }
}

// ------------------------------------------------------------------
// MY COMMUNITY PAGE (FIX 23 item 15)
// ------------------------------------------------------------------
// Mirrors the My Team page layout (reference screenshot
// 1000050450_2_6l45.jpg), community-flavored: header card with
// avatar + camera (photo upload that WORKS), gold name, real
// Followers stats, EDIT COMMUNITY button, invite section,
// followers roster, big "Open Community Chat" button.
// TEAM HISTORY is deliberately OMITTED — no community
// activity/history view exists in code, and inventing one was
// explicitly forbidden. Creator-only entry (the Settings
// sheet shows it only to the creator).

class MyCommunityPage extends StatefulWidget {
  final Map<String, dynamic> community;
  final String uid;
  final VoidCallback onInvite;
  final VoidCallback? onChanged;
  const MyCommunityPage(
      {super.key,
      required this.community,
      required this.uid,
      required this.onInvite,
      this.onChanged});

  @override
  State<MyCommunityPage> createState() => _MyCommunityPageState();
}

class _MyCommunityPageState extends State<MyCommunityPage> {
  late Map<String, dynamic> _community;
  bool _uploadingPhoto = false;
  bool _changed = false;
  // Real stats: fresh follower count + online count (loaded in
  // _loadCounts; null until the read lands — never a fake 0).
  int? _followersCount;
  int? _onlineCount;
  bool _showOnline = false;

  String get _id => SupaDb.strOf(_community['id']);
  String get _name => SupaDb.strOf(_community['name'], 'Community');
  String get _photoUrl => SupaDb.strOf(_community['photo_url']);
  bool get _voiceApproved =>
      _community['voice_enabled'] == true ||
      _community['voiceEnabled'] == true;

  @override
  void initState() {
    super.initState();
    _community = Map<String, dynamic>.from(widget.community);
    _loadCounts();
  }

  Future<void> _loadCounts() async {
    try {
      final total = await CommunityGroups.memberCount(_id);
      if (!mounted) return;
      setState(() => _followersCount = total);
      if (total > 1000 || total <= 0) return;
      final uids = await CommunityGroups.memberUids(_id);
      if (uids.isEmpty || !mounted) return;
      var online = 0;
      for (var i = 0; i < uids.length; i += 100) {
        final chunk =
            uids.sublist(i, i + 100 > uids.length ? uids.length : i + 100);
        final presence = await SupaDb.getPresenceMap(chunk);
        online += presence.values.where(SupaDb.presenceIsOnline).length;
      }
      if (mounted) {
        setState(() {
          _onlineCount = online;
          _showOnline = true;
        });
      }
    } catch (_) {}
  }

  /// Photo upload — the WORKING pattern (Edit Profile /
  /// CreateCommunityPage): pick (ImagePicker, compressed at
  /// pick time, file_picker fallback) -> ImgBB upload -> save
  /// the URL to communities.photo_url via updateCommunity
  /// (read-back verified — never fake success). The local photo
  /// changes ONLY after the server save lands; failures keep
  /// the old photo + an honest toast. NO ImgBB bucket is
  /// involved — ImgBB hosts the image; the community column is
  /// `communities.photo_url`. (The broken team/clan photo
  /// pattern is NOT used here.)
  Future<void> _pickPhoto() async {
    if (_uploadingPhoto) return;
    File? file;
    try {
      try {
        final picked = await ImagePicker().pickImage(
            source: ImageSource.gallery, imageQuality: 85, maxWidth: 1024);
        if (picked == null) return;
        file = File(picked.path);
      } on MissingPluginException {
        final res = await FilePicker.platform
            .pickFiles(type: FileType.image, allowMultiple: false);
        if (res == null || res.files.isEmpty || res.files.single.path == null) {
          return;
        }
        file = File(res.files.single.path!);
      }
    } catch (_) {
      if (mounted) toast(context, 'Photo nahi khul saki — dobara koshish karein.');
      return;
    }
    setState(() => _uploadingPhoto = true);
    String url;
    try {
      url = await ImgbbService.uploadImage(file);
    } catch (e) {
      if (!mounted) return;
      setState(() => _uploadingPhoto = false);
      toast(context, 'Photo upload failed: $e');
      return;
    }
    if (url.isEmpty) {
      if (!mounted) return;
      setState(() => _uploadingPhoto = false);
      toast(context, 'Photo upload nahi hui — dobara try karen.');
      return;
    }
    final res =
        await CommunityGroups.updateCommunity(id: _id, photoUrl: url);
    if (!mounted) return;
    setState(() => _uploadingPhoto = false);
    if (res['ok'] == true) {
      setState(() {
        _community['photo_url'] = url;
        _changed = true;
      });
      widget.onChanged?.call();
      toast(context, 'Community photo badal gayi.');
    } else {
      toast(context, 'Photo save nahi hui: ${res['error']}');
    }
  }

  Future<void> _openEdit() async {
    final saved = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => EditCommunityPage(
          communityId: _id,
          name: _name,
          description: SupaDb.strOf(_community['description']),
        ),
      ),
    );
    if (saved != true || !mounted) return;
    final fresh =
        await CommunityGroups.getCommunity(_id, myUid: widget.uid);
    if (!mounted) return;
    if (fresh.isNotEmpty) {
      setState(() {
        _community = fresh;
        _changed = true;
      });
      widget.onChanged?.call();
    }
  }

  Widget _sectionHeader(String title) {
    return Row(
      children: [
        Container(
          width: 4,
          height: 22,
          decoration: BoxDecoration(
              color: kGold, borderRadius: BorderRadius.circular(2)),
        ),
        const SizedBox(width: 8),
        Text(title,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w900,
                fontStyle: FontStyle.italic)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final followersText = _followersCount == null
        ? '— Followers'
        : '$_followersCount Follower${_followersCount == 1 ? '' : 's'}';
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent, // PHASE E (E4): transparent header — poster shows through
        title: const Text('MY COMMUNITY',
            style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.w900)),
        centerTitle: true,
        actions: const [
          Padding(
            padding: EdgeInsets.only(right: 12),
            child: ArenaLogo(crownSize: 28, fontSize: 13),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: MockupCard(
              padding: const EdgeInsets.all(16),
              radius: 16,
              animate: false,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      GestureDetector(
                        onTap: _pickPhoto,
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            Container(
                              width: 88,
                              height: 88,
                              decoration: BoxDecoration(
                                color: _cCard,
                                borderRadius: BorderRadius.circular(16),
                                border:
                                    Border.all(color: kGold, width: 1.5),
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(15),
                                child: _photoUrl.isNotEmpty
                                    ? ArenaCachedImage(
                                        imageUrl: _photoUrl,
                                        width: 88,
                                        height: 88,
                                        fit: BoxFit.cover,
                                      )
                                    : Icon(Icons.emoji_events,
                                        color: kGold, size: 40),
                              ),
                            ),
                            Positioned(
                              right: -6,
                              bottom: -6,
                              child: Container(
                                width: 30,
                                height: 30,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: kGold,
                                  border: Border.all(
                                      color: _cBg, width: 2),
                                ),
                                child: const Icon(Icons.camera_alt,
                                    color: Colors.black, size: 16),
                              ),
                            ),
                            if (_uploadingPhoto)
                              const Positioned.fill(
                                  child: Center(
                                      child: CircularProgressIndicator())),
                          ],
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Text(_name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                color: kGold,
                                fontSize: 24,
                                fontWeight: FontWeight.w800,
                                fontStyle: FontStyle.italic,
                                height: 1.1)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.25),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.people, color: kGold, size: 18),
                        const SizedBox(width: 6),
                        Text(followersText,
                            style: TextStyle(
                                color: kText,
                                fontSize: 15,
                                fontWeight: FontWeight.w800)),
                        if (_showOnline) ...[
                          Container(
                            margin:
                                const EdgeInsets.symmetric(horizontal: 12),
                            width: 1,
                            height: 18,
                            color: _cBorder,
                          ),
                          Container(
                            width: 8,
                            height: 8,
                            decoration: const BoxDecoration(
                                shape: BoxShape.circle,
                                color: Colors.greenAccent),
                          ),
                          const SizedBox(width: 6),
                          Text('$_onlineCount Online',
                              style: TextStyle(
                                  color: kText,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w800)),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _openEdit,
                      icon: Icon(Icons.edit, color: kGold, size: 18),
                      label: const Text('EDIT COMMUNITY',
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w900)),
                      style: OutlinedButton.styleFrom(
                        side: BorderSide(color: kGold, width: 1.5),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 18),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: _sectionHeader('INVITE PLAYERS'),
          ),
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: MockupCard(
              padding: const EdgeInsets.all(14),
              radius: 16,
              animate: false,
              child: Row(
                children: [
                  Expanded(
                    child: Text('Invite players to this community',
                        style: TextStyle(color: kText, fontSize: 14)),
                  ),
                  const SizedBox(width: 10),
                  GoldButton(
                    label: 'INVITE',
                    fullWidth: false,
                    onPressed: widget.onInvite,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 18),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: _sectionHeader(
                'ROSTER (${_followersCount ?? '—'})'),
          ),
          const SizedBox(height: 6),
          Expanded(
            child: _MembersTab(
              communityId: _id,
              uid: widget.uid,
              isCreator: true,
              voiceApproved: _voiceApproved,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: GoldButton(
              label: 'Open Community Chat',
              onPressed: () => Navigator.pop(context, _changed),
            ),
          ),
        ],
      ),
    );
  }
}

/// FIX 23 item 15 — the Edit Community form (name + description,
/// pre-filled, same fields as CreateCommunityPage). Empty name
/// is rejected with a clear message; save goes through
/// [CommunityGroups.updateCommunity] (honest success/failure —
/// never fake success). Pops true on a successful save.
class EditCommunityPage extends StatefulWidget {
  final String communityId;
  final String name;
  final String description;
  const EditCommunityPage(
      {super.key,
      required this.communityId,
      required this.name,
      required this.description});

  @override
  State<EditCommunityPage> createState() => _EditCommunityPageState();
}

class _EditCommunityPageState extends State<EditCommunityPage> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _descCtrl;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.name);
    _descCtrl = TextEditingController(text: widget.description);
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      toast(context, 'Naam likhen.');
      return;
    }
    setState(() => _saving = true);
    final res = await CommunityGroups.updateCommunity(
      id: widget.communityId,
      name: name,
      description: _descCtrl.text,
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (res['ok'] == true) {
      toast(context, 'Community update ho gayi.');
      Navigator.pop(context, true);
    } else {
      toast(
          context,
          res['offline'] == true
              ? 'Communities backend abhi online nahi hua (migration 073 pending).'
              : 'Failed: ${res['error']}');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent, // PHASE E (E4): transparent header — poster shows through
        title: Text('EDIT COMMUNITY',
            style: TextStyle(
                color: kGold,
                fontSize: 20,
                fontWeight: FontWeight.w900,
                fontStyle: FontStyle.italic)),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ArenaFormField(
                key: const Key('g23_edit_name_field'),
                controller: _nameCtrl,
                label: 'Naam',
                hint: 'e.g. PUBG Pro Players'),
            ArenaFormField(
                key: const Key('g23_edit_desc_field'),
                controller: _descCtrl,
                label: 'Description',
                hint: 'Is mein kya hota hai?',
                maxLines: 3),
            const SizedBox(height: 16),
            GoldButton(
              label: 'SAVE',
              busy: _saving,
              onPressed: _save,
            ),
          ],
        ),
      ),
    );
  }
}

/// PHASE E (E30) — community invite picker (bottom sheet).
///
/// Two ways to find people, both username-based (NEVER by
/// Firebase UID — the UID never shows in the UI or acts as a
/// search key, same rule as PlayerLookupPage):
///  1. FRIENDS: the legacy `friends` table (PlayerLookupPage
///     pattern: getList('friends', user_uid)) + profiles for
///     names/avatars.
///  2. SEARCH: username lookup (SupaDb.findUserByUsername).
///
/// Each row has an Invite button -> SupaDb.sendCommunityInvite
/// (a real community_invite notification in the invitee's
/// inbox). Members show 'Member', already-invited show
/// 'Invited' — no dead buttons, no forced joins (nobody is
/// added without tapping Join themself).
class _CommunityInvitePicker extends StatefulWidget {
  final String uid;
  final String communityId;
  final String communityName;
  const _CommunityInvitePicker({
    required this.uid,
    required this.communityId,
    required this.communityName,
  });

  @override
  State<_CommunityInvitePicker> createState() =>
      _CommunityInvitePickerState();
}

class _CommunityInvitePickerState extends State<_CommunityInvitePicker> {
  final TextEditingController _searchCtrl = TextEditingController();
  List<Map<String, dynamic>> _friends = [];
  bool _loadingFriends = true;
  bool _searching = false;
  Map<String, dynamic>? _searchResult;
  String _inviterName = '';
  final Set<String> _invited = {};
  final Set<String> _memberUids = {};
  final Set<String> _busy = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      // Friends (legacy table) + their profiles.
      final friendRows = await SupaDb.getList('friends',
          eqCol: 'user_uid', eqVal: widget.uid);
      final friendUids = friendRows
          .map((r) => SupaDb.strOf(r['friend_uid']))
          .where((u) => u.isNotEmpty && u != widget.uid)
          .toSet()
          .toList();
      final profiles = await SupaDb.getProfilesMap(friendUids);
      // Members (hide their Invite button) + pending invitees
      // (show 'Invited').
      final members = await SupaDb.getList('community_members',
          eqCol: 'community_id', eqVal: widget.communityId);
      final pending = await SupaDb.getList('user_notifications',
          eqCol: 'type', eqVal: 'community_invite', limit: 200);
      final me = await SupaDb.getProfilesMap([widget.uid]);
      if (!mounted) return;
      setState(() {
        _friends = friendUids
            .map((u) => profiles[u])
            .whereType<Map<String, dynamic>>()
            .toList();
        _memberUids.addAll(members
            .map((r) => SupaDb.strOf(r['firebase_uid']))
            .where((u) => u.isNotEmpty));
        _invited.addAll(pending
            .where((r) =>
                SupaDb.strOf(r['community_id']) == widget.communityId)
            .map((r) => SupaDb.strOf(r['firebase_uid']))
            .where((u) => u.isNotEmpty));
        _inviterName = SupaDb.strOf(
            me[widget.uid]?['display_name'],
            SupaDb.strOf(me[widget.uid]?['username']));
        _loadingFriends = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingFriends = false);
    }
  }

  Future<void> _search() async {
    final target = _searchCtrl.text.trim();
    if (target.isEmpty) return;
    setState(() => _searching = true);
    final p = SupaDb.normProfile(await SupaDb.findUserByUsername(target));
    if (!mounted) return;
    setState(() {
      _searching = false;
      _searchResult = p.isEmpty ? null : p;
    });
    if (p.isEmpty) toast(context, 'Is username ka koi player nahi mila.');
  }

  Future<void> _invite(String targetUid) async {
    if (targetUid.isEmpty ||
        targetUid == widget.uid ||
        _busy.contains(targetUid) ||
        _invited.contains(targetUid) ||
        _memberUids.contains(targetUid)) {
      return;
    }
    setState(() => _busy.add(targetUid));
    final res = await SupaDb.sendCommunityInvite(
      communityId: widget.communityId,
      communityName: widget.communityName,
      invitedUid: targetUid,
      inviterUid: widget.uid,
      inviterName: _inviterName,
    );
    if (!mounted) return;
    setState(() => _busy.remove(targetUid));
    if (res['ok'] == true) {
      setState(() => _invited.add(targetUid));
      toast(context, 'Invitation bhej di!');
    } else {
      toast(context, 'Failed: ${SupaDb.strOf(res['error'])}');
    }
  }

  Widget _personRow(Map<String, dynamic> profile) {
    final uid = SupaDb.strOf(
        profile['firebase_uid'], SupaDb.strOf(profile['uid']));
    final name = SupaDb.strOf(
        profile['display_name'], SupaDb.strOf(profile['username'], 'Player'));
    final username = SupaDb.strOf(profile['username']);
    final isMember = _memberUids.contains(uid);
    final isInvited = _invited.contains(uid);
    final busy = _busy.contains(uid);
    final label = isMember ? 'Member' : isInvited ? 'Invited' : 'Invite';
    final enabled = !isMember && !isInvited && !busy;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          CircleAvatar(
            radius: 20,
            backgroundColor: kCardPurpleMid,
            child: Text(
              name.isNotEmpty ? name[0].toUpperCase() : '?',
              style: TextStyle(
                  color: kGold, fontWeight: FontWeight.bold, fontSize: 16),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name,
                    style: TextStyle(
                        color: kText,
                        fontWeight: FontWeight.bold,
                        fontSize: 15),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                if (username.isNotEmpty)
                  Text('@$username',
                      style: TextStyle(color: kMuted, fontSize: 12),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Opacity(
            opacity: enabled ? 1 : 0.55,
            child: InkWell(
              onTap: enabled ? () => _invite(uid) : null,
              borderRadius: BorderRadius.circular(20),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: enabled ? kGold : kField,
                  borderRadius: BorderRadius.circular(20),
                  border: enabled
                      ? null
                      : Border.all(color: kBorder, width: 1),
                ),
                child: Text(label,
                    style: TextStyle(
                        color: enabled ? Colors.black : kMuted,
                        fontWeight: FontWeight.bold,
                        fontSize: 13)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('communityInvitePicker'),
      height: MediaQuery.of(context).size.height * 0.72,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Text('Invite to ${widget.communityName}',
              style: TextStyle(
                  color: kText, fontWeight: FontWeight.w900, fontSize: 18)),
          const SizedBox(height: 4),
          Text('Friends ko invite karen ya username se dhoondhen.',
              style: TextStyle(color: kMuted, fontSize: 13)),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchCtrl,
                  style: TextStyle(color: kText),
                  decoration: InputDecoration(
                    hintText: 'Username se dhoondhen...',
                    hintStyle: TextStyle(color: kMuted),
                    filled: true,
                    fillColor: kField,
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: kBorder)),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 12),
                  ),
                  onSubmitted: (_) => _search(),
                ),
              ),
              const SizedBox(width: 8),
              InkWell(
                onTap: _searching ? null : _search,
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 13),
                  decoration: BoxDecoration(
                    color: kGold,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: _searching
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.black))
                      : const Text('Search',
                          style: TextStyle(
                              color: Colors.black,
                              fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
          if (_searchResult != null) ...[
            const SizedBox(height: 12),
            Text('Search result',
                style: TextStyle(
                    color: kSectionLabel,
                    fontWeight: FontWeight.bold,
                    fontSize: 13)),
            const SizedBox(height: 4),
            _personRow(_searchResult!),
            Divider(color: kBorder, height: 20),
          ],
          const SizedBox(height: 12),
          Text('Friends',
              style: TextStyle(
                  color: kSectionLabel,
                  fontWeight: FontWeight.bold,
                  fontSize: 13)),
          const SizedBox(height: 4),
          Expanded(
            child: _loadingFriends
                ? const Center(child: CircularProgressIndicator())
                : _friends.isEmpty
                    ? Center(
                        child: Text(
                          'Abhi koi friend nahi — username se dhoondh kar invite karen.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: kMuted, fontSize: 13),
                        ),
                      )
                    : ListView(
                        children: _friends.map(_personRow).toList(),
                      ),
          ),
        ],
      ),
    );
  }
}
