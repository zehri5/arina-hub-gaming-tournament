import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../community_service.dart';
import '../components/arena_components.dart';
import '../components/cached_image.dart';
import '../components/arena_chat.dart';
import '../components/chat_bubble.dart'; // showChatImageDialog (DM photo tap-to-view)
import '../components/premium_badge.dart';
import '../services/imgbb_service.dart';
import '../services/message_sounds.dart';
import '../services/presence_service.dart';
import '../services/supabase_db.dart';
import '../utils.dart';
import 'pro_features.dart';

/// COMMUNITY — FRIENDS / FOLLOWING (2026-11-20 Community System,
/// restructured 2026-11-22 on the user's order).
///
/// The old single Community hub (Friends + Requests + Following +
/// Messages tabs + a Squad card, on the nav Community tab) is
/// GONE — with many friends the chat was pushed off the bottom.
/// The pieces now live where the user asked for them:
///
/// * Nav Community tab → the teams list ([TeamsPage] in
///   pro_features.dart), with a "Browse Communities" entry to the
///   communities feature (`CommunitiesListPage`).
/// * Profile → Friends & Requests → [FriendsRequestsPage]:
///   Friends, Requests and Followers tabs, one scrollable list.
/// * Profile → Messages → [MessagesPage]: the 1:1 DM list.
/// * Profile → Following → [FollowingPage]: players I follow.
///
/// Squad/group chat is NOT lost: My Team → "Open Team Chat".
///
/// PRIVACY: Firebase UID is NEVER shown and NEVER a search key —
/// players are found by USERNAME only (see [FindPlayerPage]).
/// Public profiles show stats / rank / badges only — no email, no
/// phone, no UID, no wallet, no earnings.
///
/// BEFORE migration 035 is applied: username search + public
/// profiles work (existing profiles table), and follows work too
/// (the follows table is live since migration 008) — only friends
/// / friend requests / DMs show the "coming online" state instead
/// of crashing. The moment 035 is applied, those light up with no
/// new build: every screen re-probes on load.
/// FRIENDS & REQUESTS (2026-11-22, user order — Community tab
/// restructure, refined 2026-11-22 05:07).
///
/// Profile → Friends & Requests opens this page: three tabs —
/// Friends, Requests and Followers — each a scrollable list. The
/// SAME tab widgets the old Community hub had, minus Messages
/// (now its own Profile option, [MessagesPage]) and minus the
/// Squad & Group Chat card (team chat lives on My Team → "Open
/// Team Chat", and the teams list itself is now the nav Community
/// tab).
///
/// Why Requests + Followers live HERE instead of getting their own
/// Profile tiles: they belong to the friends flow (a request
/// becomes a friend; a follower is a player relationship), and one
/// page with three tabs keeps Profile's tile list short. The
/// pending-request badge still shows on the Requests pill AND on
/// the bottom-nav Profile tab (main.dart).
///
/// Scroll: the whole page is one ListView — a long friends list
/// scrolls up/down, which is the complaint that started this
/// restructure (friends pushed the chat off the bottom of the hub).
class FriendsRequestsPage extends StatefulWidget {
  final String uid;
  const FriendsRequestsPage({super.key, required this.uid});

  @override
  State<FriendsRequestsPage> createState() => _FriendsRequestsPageState();
}

class _FriendsRequestsPageState extends State<FriendsRequestsPage> {
  int _tab = 0; // 0 Friends, 1 Requests, 2 Followers
  // Split readiness (as the old hub had it): friends/requests wait
  // for migration 035 (friend_requests table), but follows live on
  // the 008 table — the two are probed separately so a missing
  // friend_requests table never hides the working Followers tab.
  // ($1 = friends backend, $2 = follows backend.)
  late Future<(bool, bool)> _readinessFuture;
  int _refreshTick = 0;

  @override
  void initState() {
    super.initState();
    _readinessFuture = _probeReadiness();
  }

  static Future<(bool, bool)> _probeReadiness() async {
    final friends = await CommunityService.communityBackendReady();
    final follows = await CommunityService.followsBackendReady();
    return (friends, follows);
  }

  void _refresh() {
    setState(() {
      _refreshTick++;
      _readinessFuture = _probeReadiness();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('FRIENDS & REQUESTS', style: TextStyle(color: kGold, fontSize: 22, fontWeight: FontWeight.w900, fontStyle: FontStyle.italic)),
        actions: [
          IconButton(
            icon: Icon(Icons.search, color: kGold),
            tooltip: 'Find player by username',
            onPressed: () async {
              await Navigator.push(context, MaterialPageRoute(builder: (_) => FindPlayerPage(uid: widget.uid)));
              _refresh();
            },
          ),
          IconButton(icon: Icon(Icons.refresh, color: kGold), onPressed: _refresh),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: _CommunityFilterTabs(
              labels: const ['Friends', 'Requests', 'Followers'],
              selectedIndex: _tab,
              onSelected: (i) => setState(() => _tab = i),
            ),
          ),
          // Pending-request badge under the tabs (live, never throws).
          StreamBuilder<int>(
            stream: CommunityService.pendingRequestCountStream,
            builder: (context, snap) {
              final n = snap.data ?? 0;
              if (n <= 0) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                child: InkWell(
                  onTap: () => setState(() => _tab = 1),
                  borderRadius: BorderRadius.circular(12),
                  child: MockupCard(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    child: Row(
                      children: [
                        Icon(Icons.person_add_alt, color: kGold, size: 20),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            n == 1 ? '1 friend request pending' : '$n friend requests pending',
                            style: TextStyle(color: kText, fontWeight: FontWeight.bold),
                          ),
                        ),
                        Icon(Icons.chevron_right, color: kMuted),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
          Expanded(
            child: FutureBuilder<(bool, bool)>(
              future: _readinessFuture,
              builder: (context, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator(color: Color(0xFFFDC903)));
                }
                final ready = snap.data?.$1 ?? false;
                final followsReady = snap.data?.$2 ?? false;
                return RefreshIndicator(
                  color: kGold,
                  onRefresh: () async => _refresh(),
                  child: ListView(
                    key: ValueKey(_refreshTick),
                    padding: const EdgeInsets.all(16),
                    children: [
                      if (!ready) ...[
                        _comingOnlineCard(),
                        const SizedBox(height: 12),
                      ],
                      if (_tab == 0) _FriendsTab(uid: widget.uid, ready: ready, onChanged: _refresh),
                      if (_tab == 1) _RequestsTab(uid: widget.uid, ready: ready, onChanged: _refresh),
                      if (_tab == 2) _FollowersTab(uid: widget.uid, ready: followsReady, onChanged: _refresh),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _comingOnlineCard() {
    return MockupCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.cloud_sync, color: kGold),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Friends are coming online', style: TextStyle(color: kText, fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Text(
                  'Friend requests unlock once the community update is applied. Follows and username search work right now — tap the search icon above to find a player.',
                  style: TextStyle(color: kMuted, fontSize: 13),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// FOLLOWING (2026-11-22, user order — Community tab restructure).
///
/// Profile → Following opens this page: the players I follow, one
/// scrollable list with an Unfollow action per row (the old hub's
/// Following tab, lifted out whole — [_FollowingTab] is unchanged).
/// KEPT as its own Profile tile in the refined 05:07 workflow:
/// the refined structure names Friends & Requests + Messages, and
/// Following fits neither — dropping it would orphan a working
/// feature, so it keeps its tile. Followers live as a tab on
/// [FriendsRequestsPage]; [FollowListPage] still serves other
/// players' follow lists from their public profiles.
class FollowingPage extends StatefulWidget {
  final String uid;
  const FollowingPage({super.key, required this.uid});

  @override
  State<FollowingPage> createState() => _FollowingPageState();
}

class _FollowingPageState extends State<FollowingPage> {
  late Future<bool> _readinessFuture;
  int _refreshTick = 0;

  @override
  void initState() {
    super.initState();
    _readinessFuture = CommunityService.followsBackendReady();
  }

  void _refresh() {
    setState(() {
      _refreshTick++;
      _readinessFuture = CommunityService.followsBackendReady();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('FOLLOWING', style: TextStyle(color: kGold, fontSize: 22, fontWeight: FontWeight.w900, fontStyle: FontStyle.italic)),
        actions: [
          IconButton(icon: Icon(Icons.refresh, color: kGold), onPressed: _refresh),
        ],
      ),
      body: FutureBuilder<bool>(
        future: _readinessFuture,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator(color: Color(0xFFFDC903)));
          }
          final ready = snap.data ?? false;
          return RefreshIndicator(
            color: kGold,
            onRefresh: () async => _refresh(),
            child: ListView(
              key: ValueKey(_refreshTick),
              padding: const EdgeInsets.all(16),
              children: [
                _FollowingTab(uid: widget.uid, ready: ready, onChanged: _refresh),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// MESSAGES (2026-11-22, refined Profile workflow 05:07).
///
/// Profile → Messages opens this page: the 1:1 DM conversation
/// list, one scrollable list (the old hub's Messages tab, lifted
/// out whole — [_MessagesTab] is unchanged). DMs are friends-only;
/// new conversations start from a friend's profile or the Friends
/// tab on [FriendsRequestsPage].
class MessagesPage extends StatefulWidget {
  final String uid;
  const MessagesPage({super.key, required this.uid});

  @override
  State<MessagesPage> createState() => _MessagesPageState();
}

class _MessagesPageState extends State<MessagesPage> {
  late Future<bool> _readinessFuture;
  int _refreshTick = 0;

  @override
  void initState() {
    super.initState();
    _readinessFuture = CommunityService.communityBackendReady();
  }

  void _refresh() {
    setState(() {
      _refreshTick++;
      _readinessFuture = CommunityService.communityBackendReady();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('MESSAGES', style: TextStyle(color: kGold, fontSize: 22, fontWeight: FontWeight.w900, fontStyle: FontStyle.italic)),
        actions: [
          IconButton(icon: Icon(Icons.refresh, color: kGold), onPressed: _refresh),
        ],
      ),
      body: FutureBuilder<bool>(
        future: _readinessFuture,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator(color: Color(0xFFFDC903)));
          }
          final ready = snap.data ?? false;
          return RefreshIndicator(
            color: kGold,
            onRefresh: () async => _refresh(),
            child: ListView(
              key: ValueKey(_refreshTick),
              padding: const EdgeInsets.all(16),
              children: [
                _MessagesTab(uid: widget.uid, ready: ready, onChanged: _refresh),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// SAMEER FIX 2 (2026-11-21): pending friend-request count badge
/// for the Requests tab — mirrors the bottom-nav badge in main.dart
/// (same red pill, white bold 9pt text, '9+' cap). Renders nothing
/// when [count] is 0, same as the nav badge. Extracted so the
/// show/hide rule is widget-testable.
class RequestsTabBadge extends StatelessWidget {
  final int count;
  const RequestsTabBadge({super.key, required this.count});

  @override
  Widget build(BuildContext context) {
    if (count <= 0) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(color: Colors.red, borderRadius: BorderRadius.circular(8)),
      constraints: const BoxConstraints(minWidth: 14, minHeight: 14),
      child: Text(count > 9 ? '9+' : '$count', style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold), textAlign: TextAlign.center),
    );
  }
}

/// Community filter tabs (SAMEER FIX 2, 2026-11-21): the same pills
/// as the shared FilterTabs (same padding, radius, colours, font
/// sizes — visually identical), with one addition the shared widget
/// cannot carry: the Requests pill shows the LIVE pending
/// friend-request count badge, from the EXACT same stream as the
/// bottom-nav badge ([CommunityService.pendingRequestCountStream]).
/// The under-tabs "N friend requests pending" banner below is
/// untouched — this badge is ON the tab itself, which is the piece
/// that was missing. Local to this file on purpose: the shared
/// FilterTabs is used by many screens and takes no badges.
/// RESTRUCTURE (2026-11-22): the labels are passed in —
/// [FriendsRequestsPage] passes three (Friends, Requests,
/// Followers) — and 'Requests' MUST stay at index 1, because the
/// badge is pinned to that index.
class _CommunityFilterTabs extends StatelessWidget {
  final List<String> labels;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  const _CommunityFilterTabs({required this.labels, required this.selectedIndex, required this.onSelected});

  Widget _pill(int i, int pending) {
    final active = i == selectedIndex;
    // PHASE E (E24, CORRECTED 2026-11-24): the active pill is
    // gold-filled (Sameer: "click pe yellow hona chahiye"); the
    // rest are the card fill (shared token) — never black.
    // Same rule as FilterTabs.
    final pill = Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      alignment: Alignment.center,
      decoration: active
          ? BoxDecoration(
              color: kGold,
              borderRadius: BorderRadius.circular(20),
            )
          : cardFillDecoration(radius: 20).copyWith(
              border: Border.all(color: kBorder, width: 1),
            ),
      child: Text(labels[i],
          style: TextStyle(
              color: active ? const Color(0xFF0A0A0F) : kText,
              fontWeight: FontWeight.bold,
              fontSize: 13)),
    );
    final badged = i == 1 && pending > 0
        ? Stack(
            clipBehavior: Clip.none,
            children: [
              pill,
              Positioned(top: -6, right: -4, child: RequestsTabBadge(count: pending)),
            ],
          )
        : pill;
    return GestureDetector(onTap: () => onSelected(i), child: badged);
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<int>(
      stream: CommunityService.pendingRequestCountStream,
      builder: (context, snap) {
        final pending = snap.data ?? 0;
        // CLIP FIX (2026-11-21, user screenshot): the Requests badge
        // sits 6px above its pill (Positioned top: -6 in _pill), but
        // a SingleChildScrollView clips at its own edge by default —
        // and the 8px top Padding is OUTSIDE the scroll view, so it
        // never gave the badge room inside the viewport: the top
        // half of the red "1" was cut off. Clip.none lets the badge
        // paint into that 8px headroom above the scroll view
        // (badge needs 6px). The Stack's own Clip.none only defeats
        // clipping by the Stack itself, never by this ancestor.
        return Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 2),
          child: SingleChildScrollView(
            clipBehavior: Clip.none,
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (var i = 0; i < labels.length; i++) ...[
                  _pill(i, pending),
                  if (i < labels.length - 1) const SizedBox(width: 8),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

// ------------------------------------------------------------------
// Hub tabs
// ------------------------------------------------------------------

class _FriendsTab extends StatelessWidget {
  final String uid;
  final bool ready;
  final VoidCallback onChanged;
  const _FriendsTab({required this.uid, required this.ready, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    if (!ready) {
      return const EmptyState(icon: Icons.people, title: 'Friends coming online', body: 'Your friends list appears here once the community update is applied.');
    }
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: CommunityService.friends(uid),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.only(top: 32),
            child: Center(child: CircularProgressIndicator(color: Color(0xFFFDC903))),
          );
        }
        final list = snap.data ?? [];
        if (list.isEmpty) {
          return const EmptyState(
            icon: Icons.people_outline,
            title: 'No friends yet',
            body: 'Search a player by username and send a friend request.',
          );
        }
        return Column(
          children: [
            for (final f in list)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _PlayerRow(
                  profile: f,
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: Icon(Icons.message, color: kGold, size: 20),
                        tooltip: 'Message',
                        onPressed: () => _openDm(context, f),
                      ),
                      PopupMenuButton<String>(
                        icon: Icon(Icons.more_vert, color: kMuted, size: 20),
                        color: kCard,
                        onSelected: (v) async {
                          if (v == 'unfriend') {
                            final ok = await showDialog<bool>(
                              context: context,
                              builder: (ctx) => AlertDialog(
                                backgroundColor: kCardPurpleMid,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22), side: const BorderSide(color: kCardPurpleBorder, width: 1.5)),
                                title: Text('Unfriend?', style: TextStyle(color: kGold)),
                                content: Text(
                                  'Remove ${SupaDb.strOf(f['display_name'], SupaDb.strOf(f['username']))} from your friends? Your DM history stays, but you can no longer message each other until you are friends again.',
                                  style: TextStyle(color: kText),
                                ),
                                actions: [
                                  TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('Cancel', style: TextStyle(color: kMuted))),
                                  TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Unfriend', style: TextStyle(color: Color(0xFFFF3B30)))),
                                ],
                              ),
                            );
                            if (ok == true) {
                              final res = await CommunityService.unfriend(uid, SupaDb.strOf(f['firebase_uid']));
                              if (context.mounted) {
                                if (res['ok'] == true) {
                                  toast(context, 'Friend removed.');
                                  onChanged();
                                } else {
                                  toast(context, res['offline'] == true ? 'Community backend abhi online nahi hua.' : 'Failed: ${res['error']}');
                                }
                              }
                            }
                          }
                        },
                        itemBuilder: (_) => [
                          const PopupMenuItem(value: 'unfriend', child: Text('Unfriend', style: TextStyle(color: Color(0xFFFF3B30)))),
                        ],
                      ),
                    ],
                  ),
                  onTap: () => _openProfile(context, f),
                ),
              ),
          ],
        );
      },
    );
  }

  void _openProfile(BuildContext context, Map<String, dynamic> f) {
    Navigator.push(context, MaterialPageRoute(builder: (_) => PublicProfilePage(uid: uid, targetUid: SupaDb.strOf(f['firebase_uid'])))).then((_) => onChanged());
  }

  void _openDm(BuildContext context, Map<String, dynamic> f) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => DirectMessagePage(
          uid: uid,
          peerUid: SupaDb.strOf(f['firebase_uid']),
          peerName: SupaDb.strOf(f['display_name'], SupaDb.strOf(f['username'], 'Player')),
          peerPhotoUrl: SupaDb.strOf(f['photo_url']),
        ),
      ),
    );
  }
}

class _RequestsTab extends StatelessWidget {
  final String uid;
  final bool ready;
  final VoidCallback onChanged;
  const _RequestsTab({required this.uid, required this.ready, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    if (!ready) {
      return const EmptyState(icon: Icons.person_add_alt, title: 'Requests coming online', body: 'Friend requests appear here once the community update is applied.');
    }
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: CommunityService.pendingRequests(uid),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.only(top: 32),
            child: Center(child: CircularProgressIndicator(color: Color(0xFFFDC903))),
          );
        }
        final list = snap.data ?? [];
        if (list.isEmpty) {
          return const EmptyState(icon: Icons.person_add_alt_1, title: 'No pending requests', body: 'New friend requests show up here.');
        }
        return Column(
          children: [
            for (final r in list)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _RequestRow(
                  request: r,
                  onRespond: (accept) async {
                    final res = await CommunityService.respondFriendRequest(SupaDb.strOf(r['id']), accept);
                    if (context.mounted) {
                      if (res['ok'] == true) {
                        toast(context, accept ? 'Friend request accepted!' : 'Request declined.');
                        onChanged();
                      } else {
                        toast(context, res['offline'] == true ? 'Community backend abhi online nahi hua.' : 'Failed: ${res['error']}');
                      }
                    }
                  },
                ),
              ),
          ],
        );
      },
    );
  }
}

class _RequestRow extends StatelessWidget {
  final Map<String, dynamic> request;
  final Future<void> Function(bool accept) onRespond;
  const _RequestRow({required this.request, required this.onRespond});

  @override
  Widget build(BuildContext context) {
    final sender = (request['sender'] as Map<String, dynamic>?) ?? {};
    final name = SupaDb.strOf(sender['display_name'], SupaDb.strOf(sender['username'], 'Player'));
    return MockupCard(
      child: Row(
        children: [
          _PlayerAvatar(profile: sender, radius: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, style: TextStyle(color: kText, fontWeight: FontWeight.bold)),
                Text('wants to be your friend', style: TextStyle(color: kMuted, fontSize: 12)),
              ],
            ),
          ),
          TextButton(
            onPressed: () => onRespond(true),
            style: TextButton.styleFrom(backgroundColor: kGold, padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6)),
            child: const Text('Accept', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
          ),
          const SizedBox(width: 6),
          TextButton(
            onPressed: () => onRespond(false),
            style: TextButton.styleFrom(side: BorderSide(color: kBorder), padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6)),
            child: Text('Decline', style: TextStyle(color: kMuted, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }
}

class _FollowingTab extends StatelessWidget {
  final String uid;
  final bool ready;
  final VoidCallback onChanged;
  const _FollowingTab({required this.uid, required this.ready, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    if (!ready) {
      return const EmptyState(icon: Icons.visibility, title: 'Following coming online', body: 'Players you follow appear here once the follows backend is available.');
    }
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: CommunityService.following(uid),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.only(top: 32),
            child: Center(child: CircularProgressIndicator(color: Color(0xFFFDC903))),
          );
        }
        final list = snap.data ?? [];
        if (list.isEmpty) {
          return const EmptyState(
            icon: Icons.visibility_outlined,
            title: 'Not following anyone yet',
            body: 'Search a player by username and tap Follow — no approval needed.',
          );
        }
        return Column(
          children: [
            for (final f in list)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _PlayerRow(
                  profile: f,
                  trailing: TextButton(
                    onPressed: () async {
                      final res = await CommunityService.unfollow(uid, SupaDb.strOf(f['firebase_uid']));
                      if (context.mounted) {
                        if (res['ok'] == true) {
                          toast(context, 'Unfollowed.');
                          onChanged();
                        } else {
                          toast(context, res['offline'] == true ? 'Community backend abhi online nahi hua.' : 'Failed: ${res['error']}');
                        }
                      }
                    },
                    child: Text('Unfollow', style: TextStyle(color: kGold, fontWeight: FontWeight.bold)),
                  ),
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => PublicProfilePage(uid: uid, targetUid: SupaDb.strOf(f['firebase_uid'])))).then((_) => onChanged()),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Followers tab (2026-11-22, refined Profile workflow): the
/// players who follow ME, on the Friends & Requests page.
/// Mirrors [_FollowingTab] with [CommunityService.followers]
/// instead of [CommunityService.following]. No per-row action —
/// you cannot unfollow someone who follows you; tapping a row
/// opens their public profile (where Follow Back lives).
class _FollowersTab extends StatelessWidget {
  final String uid;
  final bool ready;
  final VoidCallback onChanged;
  const _FollowersTab({required this.uid, required this.ready, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    if (!ready) {
      return const EmptyState(icon: Icons.people, title: 'Followers coming online', body: 'Your followers appear here once the follows backend is available.');
    }
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: CommunityService.followers(uid),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.only(top: 32),
            child: Center(child: CircularProgressIndicator(color: Color(0xFFFDC903))),
          );
        }
        final list = snap.data ?? [];
        if (list.isEmpty) {
          return const EmptyState(
            icon: Icons.people_outline,
            title: 'No followers yet',
            body: 'Players who follow you show up here.',
          );
        }
        return Column(
          children: [
            for (final f in list)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _PlayerRow(
                  profile: f,
                  trailing: Icon(Icons.chevron_right, color: kMuted),
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => PublicProfilePage(uid: uid, targetUid: SupaDb.strOf(f['firebase_uid'])))).then((_) => onChanged()),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _MessagesTab extends StatelessWidget {
  final String uid;
  final bool ready;
  final VoidCallback onChanged;
  const _MessagesTab({required this.uid, required this.ready, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    if (!ready) {
      return const EmptyState(icon: Icons.message, title: 'DMs coming online', body: 'Direct messages unlock once the community update is applied.');
    }
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: CommunityService.dmConversations(uid),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.only(top: 32),
            child: Center(child: CircularProgressIndicator(color: Color(0xFFFDC903))),
          );
        }
        final list = snap.data ?? [];
        if (list.isEmpty) {
          return const EmptyState(
            icon: Icons.message_outlined,
            title: 'No conversations yet',
            body: 'DMs are friends-only — add a friend, then message from their profile or the Friends tab.',
          );
        }
        return Column(
          children: [
            for (final c in list)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Builder(
                  builder: (context) {
                    final peer = (c['peer'] as Map<String, dynamic>?) ?? {};
                    final name = SupaDb.strOf(peer['display_name'], SupaDb.strOf(peer['username'], 'Player'));
                    return MockupCard(
                      child: InkWell(
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => DirectMessagePage(
                                uid: uid,
                                peerUid: SupaDb.strOf(c['peer_uid']),
                                peerName: name,
                                peerPhotoUrl: SupaDb.strOf(peer['photo_url']),
                              ),
                            ),
                          ).then((_) => onChanged());
                        },
                        borderRadius: BorderRadius.circular(16),
                        child: Row(
                          children: [
                            _PlayerAvatar(profile: peer, radius: 22),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(name, style: TextStyle(color: kText, fontWeight: FontWeight.bold)),
                                  const SizedBox(height: 2),
                                  Text(
                                    SupaDb.strOf(c['last_message']),
                                    style: TextStyle(color: kMuted, fontSize: 13),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                            Text(timeAgo(SupaDb.intOf(c['last_at'])), style: TextStyle(color: kMuted, fontSize: 11)),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
          ],
        );
      },
    );
  }
}

// ------------------------------------------------------------------
// Shared row widgets
// ------------------------------------------------------------------

class _PlayerAvatar extends StatelessWidget {
  final Map<String, dynamic> profile;
  final double radius;
  const _PlayerAvatar({required this.profile, this.radius = 20});

  @override
  Widget build(BuildContext context) {
    final name = SupaDb.strOf(profile['display_name'], SupaDb.strOf(profile['username'], 'P'));
    final initial = name.isNotEmpty ? name[0].toUpperCase() : 'P';
    return ArenaCachedAvatar(
      photoUrl: SupaDb.strOf(profile['photo_url']),
      radius: radius,
      backgroundColor: const Color(0xFFFDC903),
      fallback: Text(initial, style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: radius * 0.8)),
    );
  }
}

class _PlayerRow extends StatelessWidget {
  final Map<String, dynamic> profile;
  final Widget? trailing;
  final VoidCallback? onTap;
  const _PlayerRow({required this.profile, this.trailing, this.onTap});

  @override
  Widget build(BuildContext context) {
    final username = SupaDb.strOf(profile['username']);
    final name = SupaDb.strOf(profile['display_name'], username.isNotEmpty ? username : 'Player');
    final level = SupaDb.intOf(profile['level'], 1);
    final rankTier = SupaDb.strOf(profile['rank_tier']);
    final sub = [
      if (username.isNotEmpty) '@$username',
      'Level $level',
      if (rankTier.isNotEmpty) rankTier,
    ].join(' • ');
    return MockupCard(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Row(
          children: [
            _PlayerAvatar(profile: profile, radius: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name, style: TextStyle(color: kText, fontWeight: FontWeight.bold)),
                  if (sub.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(sub, style: TextStyle(color: kMuted, fontSize: 12)),
                  ],
                  // PRESENCE (2026-11-22, user order): friends /
                  // followers / following / DM rows show the real
                  // online state + last seen (green "Online" when
                  // the heartbeat is fresh, grey "last seen X"
                  // when stale). Per Sameer's direct order for the
                  // friends list — the presence doc's
                  // same-tournament-only note does not apply here.
                  if (SupaDb.strOf(profile['firebase_uid']).isNotEmpty) ...[
                    const SizedBox(height: 2),
                    PresenceDot(uid: SupaDb.strOf(profile['firebase_uid']), showLastSeen: true, showLabel: true),
                  ],
                ],
              ),
            ),
            if (trailing != null) trailing!,
          ],
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------
// Find player by USERNAME (never UID)
// ------------------------------------------------------------------

/// Username search — the ONLY player lookup in the community system.
/// The search box takes a USERNAME (exact match, '@' optional).
/// Firebase UID is never a search key and never displayed anywhere.
class FindPlayerPage extends StatefulWidget {
  final String uid;
  const FindPlayerPage({super.key, required this.uid});

  @override
  State<FindPlayerPage> createState() => _FindPlayerPageState();
}

class _FindPlayerPageState extends State<FindPlayerPage> {
  final _ctrl = TextEditingController();
  bool _searching = false;
  bool _searched = false;
  Map<String, dynamic> _result = {};

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final q = _ctrl.text.trim();
    if (q.isEmpty) {
      toast(context, 'Username likhen — jaise @playername');
      return;
    }
    setState(() {
      _searching = true;
      _searched = false;
    });
    final p = await CommunityService.searchByUsername(q);
    if (!mounted) return;
    setState(() {
      _searching = false;
      _searched = true;
      _result = p;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('FIND PLAYER', style: TextStyle(color: kGold, fontSize: 22, fontWeight: FontWeight.w900, fontStyle: FontStyle.italic))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          MockupCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Search by username', style: TextStyle(color: kText, fontWeight: FontWeight.bold, fontSize: 16)),
                const SizedBox(height: 4),
                Text('Enter the player\'s username to find their public profile.', style: TextStyle(color: kMuted, fontSize: 13)),
                const SizedBox(height: 12),
                // FIX 23 item 29: card look via CardFieldShell.
                CardFieldShell(
                  child: TextField(
                  controller: _ctrl,
                  style: TextStyle(color: kText),
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _search(),
                  decoration: InputDecoration(
                    hintText: '@username',
                    hintStyle: TextStyle(color: kMuted),
                    prefixIcon: Icon(Icons.search, color: kMuted),
                    border: const OutlineInputBorder(borderSide: BorderSide.none),
                    enabledBorder: const OutlineInputBorder(borderSide: BorderSide.none),
                    focusedBorder: const OutlineInputBorder(borderSide: BorderSide.none),
                  ),
                ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _searching ? null : _search,
                    style: ElevatedButton.styleFrom(backgroundColor: kGold, padding: const EdgeInsets.symmetric(vertical: 13), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                    child: _searching
                        ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.black, strokeWidth: 2))
                        : const Text('Find Player', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 15)),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          if (_searched && _result.isEmpty)
            const EmptyState(
              icon: Icons.person_search,
              title: 'No player found',
              body: 'Check the username spelling — search is by exact username.',
            ),
          if (_result.isNotEmpty)
            _PlayerRow(
              profile: _result,
              trailing: Icon(Icons.chevron_right, color: kMuted),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => PublicProfilePage(uid: widget.uid, targetUid: SupaDb.strOf(_result['firebase_uid']))),
              ),
            ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------
// Public profile (read-only — stats / rank / badges only)
// ------------------------------------------------------------------

/// Another player's public profile. Shows ONLY public data: avatar,
/// username, display name, level, rank tier, matches/wins, badges
/// derived from real match counts, and followers/following counts.
/// NEVER shows email, phone, UID, wallet or earnings.
class PublicProfilePage extends StatefulWidget {
  final String uid; // viewer
  final String targetUid; // player being viewed (internal only)
  const PublicProfilePage({super.key, required this.uid, required this.targetUid});

  @override
  State<PublicProfilePage> createState() => _PublicProfilePageState();
}

class _PublicProfilePageState extends State<PublicProfilePage> {
  Map<String, dynamic> _profile = {};
  Map<String, dynamic> _relation = {'status': 'none'};
  bool _following = false;
  Map<String, int> _counts = {'followers': 0, 'following': 0};
  bool _loading = true;
  // Split gates (2026-11-20): follows live on the 008 table, so
  // Follow works before migration 035; only friend requests / DMs
  // wait for 035 (friend_requests table). The two gates are probed
  // separately — a missing friend_requests table must never disable
  // Follow.
  bool _friendsOffline = false;
  bool _followsOffline = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final p = await CommunityService.publicProfile(widget.targetUid);
    if (!mounted) return;
    if (p.isEmpty) {
      setState(() => _loading = false);
      return;
    }
    final rel = await CommunityService.friendshipStatus(widget.uid, widget.targetUid);
    final fol = await CommunityService.isFollowing(widget.uid, widget.targetUid);
    final counts = await CommunityService.followCounts(widget.targetUid);
    final followsReady = await CommunityService.followsBackendReady();
    if (!mounted) return;
    setState(() {
      _profile = p;
      _relation = rel;
      _following = fol;
      _counts = counts;
      _friendsOffline = rel['offline'] == true;
      _followsOffline = !followsReady;
      _loading = false;
    });
  }

  Future<void> _toggleFollow() async {
    final res = _following
        ? await CommunityService.unfollow(widget.uid, widget.targetUid)
        : await CommunityService.follow(widget.uid, widget.targetUid);
    if (!mounted) return;
    if (res['ok'] == true) {
      setState(() => _following = !_following);
      _load();
    } else {
      toast(context, res['offline'] == true ? 'Community backend abhi online nahi hua.' : 'Failed: ${res['error']}');
    }
  }

  Future<void> _friendAction() async {
    final status = SupaDb.strOf(_relation['status']);
    if (status == 'friends') {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: kCardPurpleMid,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22), side: const BorderSide(color: kCardPurpleBorder, width: 1.5)),
          title: Text('Unfriend?', style: TextStyle(color: kGold)),
          content: Text('Remove this player from your friends?', style: TextStyle(color: kText)),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('Cancel', style: TextStyle(color: kMuted))),
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Unfriend', style: TextStyle(color: Color(0xFFFF3B30)))),
          ],
        ),
      );
      if (ok != true) return;
      final res = await CommunityService.unfriend(widget.uid, widget.targetUid);
      if (!mounted) return;
      if (res['ok'] == true) {
        toast(context, 'Friend removed.');
        _load();
      } else {
        toast(context, res['offline'] == true ? 'Community backend abhi online nahi hua.' : 'Failed: ${res['error']}');
      }
      return;
    }
    if (status == 'pending_in') {
      final res = await CommunityService.respondFriendRequest(SupaDb.strOf(_relation['request_id']), true);
      if (!mounted) return;
      if (res['ok'] == true) {
        toast(context, 'Friend request accepted!');
        _load();
      } else {
        toast(context, res['offline'] == true ? 'Community backend abhi online nahi hua.' : 'Failed: ${res['error']}');
      }
      return;
    }
    if (status == 'pending_out') return; // nothing to do — waiting
    final res = await CommunityService.sendFriendRequest(widget.uid, widget.targetUid);
    if (!mounted) return;
    if (res['ok'] == true) {
      toast(context, 'Friend request sent!');
      _load();
    } else {
      toast(context, res['offline'] == true ? 'Community backend abhi online nahi hua.' : '${res['error']}');
    }
  }

  void _openDm() {
    if (_friendsOffline) {
      toast(context, 'Community backend abhi online nahi hua.');
      return;
    }
    if (SupaDb.strOf(_relation['status']) != 'friends') {
      toast(context, 'DM sirf friends ko bheji ja sakti hai — pehle friend request accept karen.');
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => DirectMessagePage(
          uid: widget.uid,
          peerUid: widget.targetUid,
          peerName: SupaDb.strOf(_profile['display_name'], SupaDb.strOf(_profile['username'], 'Player')),
          peerPhotoUrl: SupaDb.strOf(_profile['photo_url']),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isMe = widget.uid == widget.targetUid;
    final username = SupaDb.strOf(_profile['username']);
    final name = SupaDb.strOf(_profile['display_name'], username.isNotEmpty ? username : 'Player');
    final level = SupaDb.intOf(_profile['level'], 1);
    final rankTier = SupaDb.strOf(_profile['rank_tier'], 'Bronze');
    final matches = SupaDb.intOf(_profile['total_matches']);
    final wins = SupaDb.intOf(_profile['won_matches']);
    final status = SupaDb.strOf(_relation['status']);
    // Badges derive ONLY from real match counts — the SAME four
    // match-based badges as the own-Profile achievements (First
    // Blood / Survivalist / Squad Leader / Veteran). Top Earner is
    // deliberately NOT shown here: it is earnings-based, and
    // earnings are private.
    final badges = <({String name, String condition, bool unlocked, String progress})>[
      (name: 'First Blood', condition: 'Win your first match', unlocked: wins >= 1, progress: '$wins / 1 win'),
      (name: 'Survivalist', condition: 'Play 10 matches', unlocked: matches >= 10, progress: '$matches / 10 matches'),
      (name: 'Squad Leader', condition: 'Win 5 matches', unlocked: wins >= 5, progress: '$wins / 5 wins'),
      (name: 'Veteran', condition: 'Play at least 50 matches', unlocked: matches >= 50, progress: '$matches / 50 matches'),
    ];
    return Scaffold(
      appBar: AppBar(title: Text('PLAYER PROFILE', style: TextStyle(color: kGold, fontSize: 20, fontWeight: FontWeight.w900, fontStyle: FontStyle.italic))),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFFFDC903)))
          : _profile.isEmpty
              ? const Center(child: EmptyState(icon: Icons.person_off, title: 'Player not found', body: 'This player profile could not be loaded.'))
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    MockupCard(
                      child: Column(
                        children: [
                          _PlayerAvatar(profile: _profile, radius: 40),
                          const SizedBox(height: 12),
                          Text(name, style: TextStyle(color: kText, fontWeight: FontWeight.bold, fontSize: 20)),
                          if (username.isNotEmpty) ...[
                            const SizedBox(height: 2),
                            Text('@$username', style: TextStyle(color: kMuted, fontSize: 14)),
                          ],
                          // PRESENCE (2026-11-22, user order): other
                          // players' profiles show the real online
                          // state + last seen. Own profile (isMe)
                          // skips it — the viewer is online by
                          // definition while looking at it.
                          if (!isMe) ...[
                            const SizedBox(height: 6),
                            PresenceDot(uid: widget.targetUid, showLastSeen: true, showLabel: true),
                          ],
                          const SizedBox(height: 8),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              _chip('Level $level'),
                              const SizedBox(width: 8),
                              _chip(rankTier),
                            ],
                          ),
                          const SizedBox(height: 14),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            children: [
                              _stat('Matches', '$matches'),
                              _stat('Wins', '$wins'),
                              InkWell(
                                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => FollowListPage(uid: widget.uid, targetUid: widget.targetUid, showFollowers: true, title: 'Followers'))),
                                child: _stat('Followers', '${_counts['followers'] ?? 0}'),
                              ),
                              InkWell(
                                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => FollowListPage(uid: widget.uid, targetUid: widget.targetUid, showFollowers: false, title: 'Following'))),
                                child: _stat('Following', '${_counts['following'] ?? 0}'),
                              ),
                            ],
                          ),
                          if (!isMe) ...[
                            const SizedBox(height: 16),
                            Row(
                              children: [
                                Expanded(
                                  child: ElevatedButton(
                                    onPressed: _followsOffline ? null : _toggleFollow,
                                    style: ElevatedButton.styleFrom(backgroundColor: _following ? kField : kGold, side: _following ? BorderSide(color: kGold) : BorderSide.none, padding: const EdgeInsets.symmetric(vertical: 11), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                                    child: Text(_following ? 'Following' : 'Follow', style: TextStyle(color: _following ? kGold : Colors.black, fontWeight: FontWeight.bold)),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: OutlinedButton(
                                    onPressed: _friendsOffline ? null : _friendAction,
                                    style: OutlinedButton.styleFrom(side: BorderSide(color: kGold), padding: const EdgeInsets.symmetric(vertical: 11), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                                    child: Text(
                                      status == 'friends'
                                          ? 'Friends'
                                          : status == 'pending_out'
                                              ? 'Request Sent'
                                              : status == 'pending_in'
                                                  ? 'Accept Request'
                                                  : 'Add Friend',
                                      style: TextStyle(color: kGold, fontWeight: FontWeight.bold),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: OutlinedButton.icon(
                                    onPressed: _friendsOffline ? null : _openDm,
                                    icon: Icon(Icons.message, color: kGold, size: 18),
                                    label: Text('Message', style: TextStyle(color: kGold, fontWeight: FontWeight.bold)),
                                    style: OutlinedButton.styleFrom(side: BorderSide(color: kGold), padding: const EdgeInsets.symmetric(vertical: 11), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                                  ),
                                ),
                              ],
                            ),
                            if (_friendsOffline) ...[
                              const SizedBox(height: 10),
                              Text('Friend requests & DMs: community update pending.', textAlign: TextAlign.center, style: TextStyle(color: kMuted, fontSize: 12)),
                            ],
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text('BADGES', style: TextStyle(color: kSectionLabel, fontWeight: FontWeight.bold, fontSize: 13, letterSpacing: 0.5)),
                    const SizedBox(height: 8),
                    MockupCard(
                      child: Column(
                        children: [
                          for (final b in badges)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: Row(
                                children: [
                                  PremiumAchievementBadge(kind: premiumBadgeKindFor(b.name), size: 28, locked: !b.unlocked),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(b.name, style: TextStyle(color: kText, fontWeight: FontWeight.bold)),
                                        Text(b.condition, style: TextStyle(color: kMuted, fontSize: 12)),
                                      ],
                                    ),
                                  ),
                                  Column(
                                    crossAxisAlignment: CrossAxisAlignment.end,
                                    children: [
                                      Text(b.unlocked ? 'Unlocked' : 'Locked', style: TextStyle(color: b.unlocked ? kGold : kMuted, fontWeight: FontWeight.bold, fontSize: 12)),
                                      Text(b.progress, style: TextStyle(color: kMuted, fontSize: 11)),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
    );
  }

  Widget _chip(String text) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(color: kField, borderRadius: BorderRadius.circular(20), border: Border.all(color: kGold.withValues(alpha: 0.5))),
        child: Text(text, style: TextStyle(color: kGold, fontWeight: FontWeight.bold, fontSize: 13)),
      );

  Widget _stat(String label, String value) => Column(
        children: [
          Text(value, style: TextStyle(color: kGold, fontWeight: FontWeight.bold, fontSize: 18)),
          const SizedBox(height: 2),
          Text(label, style: TextStyle(color: kMuted, fontSize: 12)),
        ],
      );
}

// ------------------------------------------------------------------
// Followers / Following list (tap-through from profile counts)
// ------------------------------------------------------------------

class FollowListPage extends StatelessWidget {
  final String uid;
  final String targetUid;
  final bool showFollowers;
  final String title;
  const FollowListPage({super.key, required this.uid, required this.targetUid, required this.showFollowers, required this.title});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title.toUpperCase(), style: TextStyle(color: kGold, fontSize: 20, fontWeight: FontWeight.w900, fontStyle: FontStyle.italic))),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: showFollowers ? CommunityService.followers(targetUid) : CommunityService.following(targetUid),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator(color: Color(0xFFFDC903)));
          }
          final list = snap.data ?? [];
          if (list.isEmpty) {
            return Center(
              child: EmptyState(
                icon: Icons.people_outline,
                title: showFollowers ? 'No followers yet' : 'Not following anyone yet',
                body: showFollowers ? 'Nobody follows this player yet.' : 'This player does not follow anyone yet.',
              ),
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: list.length,
            itemBuilder: (context, i) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _PlayerRow(
                profile: list[i],
                trailing: Icon(Icons.chevron_right, color: kMuted),
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => PublicProfilePage(uid: uid, targetUid: SupaDb.strOf(list[i]['firebase_uid'])))),
              ),
            ),
          );
        },
      ),
    );
  }
}

// ------------------------------------------------------------------
// 1:1 DM (friends-only)
// ------------------------------------------------------------------

/// Direct-message thread with one friend. Friends-only: the composer
/// is disabled until the two players are friends (the service also
/// refuses the write — defence in depth).
///
/// PINNED MESSAGE (2026-11-22, user order): one pinned message per
/// DM thread, banner at the top of the message list (mockup #27
/// [ArenaPinnedBanner]), long-press a message -> Pin/Unpin, tapping
/// the banner (or View) jumps to + highlights the message. The pin
/// is stored LOCALLY in SharedPreferences (key `dm_pin_<dmKey>`,
/// {id, text, sender, ts}) — NOT synced to the other player. Why
/// local: DM rows live in chat_messages (scope='dm', dm_key) and that
/// table has NO pin/metadata column (reactions jsonb is real reactions
/// — never reused for a pin), and pinned_messages is
/// tournament-scoped text-only (tournament_id / message / pinned_by /
/// created_at — no message id, no DM/thread column, nullability + RLS
/// unverified in this copy), so no backend pin fits WITHOUT a
/// migration. BACKEND FOLLOW-UP (no migration written here): add a
/// DM-scoped pin (e.g. pinned_messages.dm_key + message_id, or a
/// chat_messages.is_pinned flag) + RLS, then switch [_loadPin] /
/// [_savePin] / [_clearPin] to it. The banner hides whenever the
/// pinned id is not in the loaded list (deleted / beyond the 200-row
/// stream window) — a stale pin is never shown.
class DirectMessagePage extends StatefulWidget {
  final String uid; // me
  final String peerUid; // friend (internal only — never displayed)
  final String peerName;
  final String peerPhotoUrl;
  const DirectMessagePage({super.key, required this.uid, required this.peerUid, required this.peerName, this.peerPhotoUrl = ''});

  @override
  State<DirectMessagePage> createState() => _DirectMessagePageState();
}

class _DirectMessagePageState extends State<DirectMessagePage> {
  final _ctrl = TextEditingController();
  final _scroll = ScrollController();
  bool _sending = false;
  bool _uploading = false; // FIX 4: a picture upload is in flight
  bool _areFriends = false;
  bool _checking = true;
  bool _showEmoji = false; // P1-7: shared built-in emoji picker
  String _myName = 'Player';
  int _myLevel = 1; // Mockup #27 "Lv.N" pill on my own messages (real profiles.level)
  String _adminUid = ''; // Designated admin — peer ORGANIZER pill (same rule as TeamChat/room)
  // DM pinned message (2026-11-22): local-only pin, see the class
  // doc. One pin per thread; pinning a new message replaces the old.
  Map<String, dynamic>? _pinned; // {id, text, sender, ts}
  String? _highlightId; // message id briefly gold-highlighted after a banner jump
  final Map<String, GlobalKey> _msgKeys = {}; // per-message keys for the banner jump
  // MESSAGE SOUNDS (Sameer's picks, 2026-11-22): the in-chat pop
  // plays only AFTER the first stream emission has primed the
  // count — opening the DM must not beep for its loaded history.
  int _lastDmCount = 0;
  bool _dmPrimed = false;

  String get _pinKey => 'dm_pin_${CommunityService.dmKey(widget.uid, widget.peerUid)}';

  Future<void> _loadPin() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_pinKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return;
      final id = decoded['id']?.toString() ?? '';
      final text = decoded['text']?.toString() ?? '';
      if (id.isEmpty || text.isEmpty) return;
      if (!mounted) return;
      setState(() => _pinned = {'id': id, 'text': text, 'sender': decoded['sender']?.toString() ?? '', 'ts': decoded['ts']});
    } catch (_) {}
  }

  Future<void> _savePin(Map<String, dynamic> m) async {
    final pin = {
      'id': SupaDb.strOf(m['id']),
      'text': SupaDb.strOf(m['message']),
      'sender': SupaDb.strOf(m['display_name']),
      'ts': DateTime.now().millisecondsSinceEpoch,
    };
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_pinKey, jsonEncode(pin));
    } catch (_) {}
    if (!mounted) return;
    setState(() => _pinned = pin);
  }

  Future<void> _clearPin() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_pinKey);
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _pinned = null;
      if (_highlightId != null) _highlightId = null;
    });
  }

  /// Long-press Pin/Unpin (same bottom-sheet pattern as TeamChat's
  /// admin pin). Photo-only messages cannot pin — the banner carries
  /// text only, same rule as the tournament banner. Report stays on
  /// the flag icon; this sheet is pin-only.
  Future<void> _showDmMessageActions(Map<String, dynamic> m) async {
    final id = SupaDb.strOf(m['id']);
    if (id.isEmpty) return;
    final text = SupaDb.strOf(m['message']);
    final isPinned = _pinned != null && SupaDb.strOf(_pinned!['id']) == id;
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
              title: Text(isPinned ? 'Unpin message' : 'Pin message', style: TextStyle(color: kText, fontWeight: FontWeight.bold)),
              subtitle: Text(isPinned ? 'Ye pinned banner se hat jayega.' : 'Ye message upar pin ho jayega.', style: TextStyle(color: kMuted, fontSize: 12)),
              onTap: () => Navigator.pop(ctx, isPinned ? 'unpin' : 'pin'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    if (action == 'pin') {
      if (text.isEmpty) {
        toast(context, 'Photo message pin nahi ho sakta — sirf text pin hota hai.');
        return;
      }
      await _savePin(m);
      if (mounted) toast(context, 'Message pin ho gaya.');
    } else {
      await _clearPin();
      if (mounted) toast(context, 'Message unpin ho gaya.');
    }
  }

  /// Banner jump: scroll to the pinned message + gold-highlight it
  /// for ~2.5 s. The item may be off-screen (not built yet), so first
  /// scroll near its index, then [Scrollable.ensureVisible] on its
  /// key. No-op when the pinned id is not in the loaded list.
  Future<void> _jumpToPinned(List<Map<String, dynamic>> msgs) async {
    if (_pinned == null || !_scroll.hasClients) return;
    final id = SupaDb.strOf(_pinned!['id']);
    final idx = msgs.indexWhere((m) => SupaDb.strOf(m['id']) == id);
    if (idx < 0) return;
    setState(() => _highlightId = id);
    Future.delayed(const Duration(milliseconds: 2500), () {
      if (mounted && _highlightId == id) setState(() => _highlightId = null);
    });
    GlobalKey? key = _msgKeys[id];
    if (key?.currentContext == null && msgs.length > 1) {
      // Off-screen: jump near the message first so it gets built.
      final target = (idx / msgs.length) * _scroll.position.maxScrollExtent;
      await _scroll.animateTo(target.clamp(0.0, _scroll.position.maxScrollExtent), duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
      await Future.delayed(const Duration(milliseconds: 120));
      key = _msgKeys[id];
    }
    final ctx = key?.currentContext;
    if (ctx != null && mounted) {
      await Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 300), alignment: 0.1);
    }
  }

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final friends = await CommunityService.areFriends(widget.uid, widget.peerUid);
    final me = await SupaDb.getProfile(widget.uid);
    final adminUid = await SupaDb.designatedAdminUid(); // fail-closed: '' when unreadable
    await _loadPin(); // DM pinned banner (local pin — restores on reopen)
    if (!mounted) return;
    setState(() {
      _areFriends = friends;
      _checking = false;
      final n = SupaDb.strOf(me['display_name']);
      if (n.isNotEmpty) _myName = n;
      _myLevel = SupaDb.intOf(me['level'], 1);
      _adminUid = adminUid;
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty || _sending) return;
    if (_showEmoji) setState(() => _showEmoji = false);
    setState(() => _sending = true);
    final res = await CommunityService.sendDmMessage(
      fromUid: widget.uid,
      toUid: widget.peerUid,
      displayName: _myName,
      message: text,
    );
    if (!mounted) return;
    setState(() => _sending = false);
    if (res['ok'] == true) {
      _ctrl.clear();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) _scroll.animateTo(_scroll.position.maxScrollExtent, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
      });
    } else {
      toast(context, res['offline'] == true ? 'DM backend abhi online nahi hua (migration 035 pending).' : 'Failed: ${res['error']}');
    }
  }

  /// FIX 4: pick a photo for the DM — same pattern as the profile /
  /// evidence pickers (ImagePicker, compressed at pick time, with
  /// the file_picker fallback when the plugin is missing). Returns
  /// null on cancel; toasts + returns null on rejection/failure.
  Future<File?> _pickDmImage() async {
    try {
      String? path;
      try {
        final picked = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 85, maxWidth: 1024);
        if (picked == null) return null;
        path = picked.path;
      } on MissingPluginException {
        final res = await FilePicker.platform.pickFiles(type: FileType.image, allowMultiple: false);
        if (res == null || res.files.isEmpty || res.files.single.path == null) return null;
        path = res.files.single.path!;
      }
      final lower = path.toLowerCase();
      if (!lower.endsWith('.jpg') && !lower.endsWith('.jpeg') && !lower.endsWith('.png')) {
        if (mounted) toast(context, 'Sirf JPG ya PNG photo allowed hai.');
        return null;
      }
      final file = File(path);
      if (await file.length() > 5 * 1024 * 1024) {
        if (mounted) toast(context, 'Photo 5MB se bari hai — chhoti photo chunen.');
        return null;
      }
      return file;
    } catch (_) {
      if (mounted) toast(context, 'Photo nahi khul saki — dobara koshish karein.');
      return null;
    }
  }

  /// FIX 4: send a picture in the DM — pick -> probe the backend
  /// column FIRST (a 30 s upload that cannot be stored would be a
  /// dead wait on a slow connection) -> ImgBB upload (the same
  /// service as profile/banner uploads) -> send with the image URL.
  /// The text send path above is untouched by this flow.
  /// P1-7 REACTIONS (mockup #27 👍👎 under a message): real shared
  /// reactions in chat_messages.reactions (jsonb emoji -> [uids]).
  /// The DM had none before this; the stream re-emits the new counts.
  Widget _reactionRow(Map<String, dynamic> m, {bool alignEnd = false}) {
    return ArenaReactionRow(
      reactions: SupaDb.asMap(m['reactions']),
      myUid: widget.uid,
      alignEnd: alignEnd,
      onToggle: (emoji) => _toggleReaction(m, emoji, SupaDb.asMap(m['reactions'])),
    );
  }

  Future<void> _toggleReaction(Map<String, dynamic> m, String emoji, Map<String, dynamic> raw) async {
    final id = SupaDb.strOf(m['id']);
    if (id.isEmpty) return;
    final next = Map<String, dynamic>.from(raw);
    final list = (next[emoji] as List?)?.map((x) => x.toString()).toList() ?? <String>[];
    if (list.contains(widget.uid)) {
      list.remove(widget.uid);
    } else {
      list.add(widget.uid);
    }
    if (list.isEmpty) {
      next.remove(emoji);
    } else {
      next[emoji] = list;
    }
    try {
      await SupaDb.client.from('chat_messages').update({'reactions': next}).eq('id', id);
    } catch (e) {
      if (mounted) toast(context, 'Reaction failed: $e');
    }
  }

  /// Long-press report: a DM message can be reported to the admin
  /// (real `disputes` row in the Chat Reports queue — the reason
  /// format matches AdminDbCare.parseChatReportReason). DMs had no
  /// report path at all before this (audit fix 2026-11-21).
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
        raisedByName: _myName,
        againstUid: senderUid,
        reason: 'Chat report [message ${SupaDb.strOf(m['id'])}] Inappropriate: "${excerpt.length > 120 ? excerpt.substring(0, 120) : excerpt}"',
      );
      if (mounted) toast(context, 'Report admin ko bhej diya.');
    } catch (e) {
      if (mounted) toast(context, 'Report failed: $e');
    }
  }

  Future<void> _sendImage() async {
    if (!_areFriends || _sending || _uploading) return;
    final file = await _pickDmImage();
    if (file == null || !mounted) return;
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
    final res = await CommunityService.sendDmImageMessage(
      fromUid: widget.uid,
      toUid: widget.peerUid,
      displayName: _myName,
      imageUrl: url,
    );
    if (!mounted) return;
    setState(() => _uploading = false);
    if (res['ok'] == true) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) _scroll.animateTo(_scroll.position.maxScrollExtent, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
      });
    } else {
      toast(context, res['needs_column'] == true ? 'Photo messages abhi available nahi — backend update pending hai.' : 'Failed: ${res['error']}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final key = CommunityService.dmKey(widget.uid, widget.peerUid);
    // Chat-unify (2026-11-21): the SAME mockup-#27 design as every
    // other chat — shared [ArenaChatHeader] + [ArenaChatMessage] +
    // [ArenaChatInputBar] (via DmComposer below). Same bubble shell,
    // same header, same composer; only the data is DM data.
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            ArenaChatHeader(
              onBack: () => Navigator.maybePop(context),
              thumbnailUrl: widget.peerPhotoUrl,
              titleName: widget.peerName.toUpperCase(),
              subtitle: 'Direct Message',
              // Mockup #27 More circle button (Members is N/A in a
              // 1:1 DM — no member list exists). View Profile is the
              // existing profile page this file already navigates to.
              moreItems: const [ArenaChatMenuItem('profile', 'View Profile')],
              onMoreSelected: (v) {
                if (v == 'profile') {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => PublicProfilePage(uid: widget.uid, targetUid: widget.peerUid),
                    ),
                  );
                }
              },
            ),
            Divider(color: kBorder, height: 1),
          if (!_checking && !_areFriends)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              color: kField,
              child: Text(
                'DMs are friends-only — send a friend request first.',
                textAlign: TextAlign.center,
                style: TextStyle(color: kMuted, fontSize: 13),
              ),
            ),
          Expanded(
            child: StreamBuilder<List<Map<String, dynamic>>>(
              stream: CommunityService.streamDmMessages(key),
              builder: (context, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator(color: Color(0xFFFDC903)));
                }
                final msgs = snap.data ?? [];
                // MESSAGE SOUNDS: new message from the peer while
                // inside this DM -> the short in-chat pop (chat_08).
                // Own sends and the first load never beep (see
                // MessageSounds). Count-guarded so rebuilds with
                // the same data never replay.
                if (MessageSounds.shouldPlayChatSound(
                    primed: _dmPrimed,
                    grew: msgs.length > _lastDmCount,
                    lastIsMine: msgs.isNotEmpty &&
                        SupaDb.strOf(msgs.last['firebase_uid']) ==
                            widget.uid)) {
                  MessageSounds.play(MessageSound.chat);
                }
                _lastDmCount = msgs.length;
                _dmPrimed = true;
                if (msgs.isEmpty) {
                  return const Center(
                    child: EmptyState(
                      icon: Icons.chat_bubble_outline,
                      title: 'No messages yet',
                      body: 'Say hello — start the conversation.',
                    ),
                  );
                }
                // DM pinned banner (2026-11-22, mockup #27): shown
                // ONLY when the pinned id is in the loaded list
                // (deleted / out-of-window pins hide — never stale).
                // The banner shows the LIVE message text, not the
                // stored copy, so it can never drift from the thread.
                Map<String, dynamic>? pinnedMsg;
                if (_pinned != null) {
                  final pid = SupaDb.strOf(_pinned!['id']);
                  for (final m in msgs) {
                    if (SupaDb.strOf(m['id']) == pid && SupaDb.strOf(m['message']).isNotEmpty) {
                      pinnedMsg = m;
                      break;
                    }
                  }
                }
                return Column(
                  children: [
                    if (pinnedMsg != null)
                      GestureDetector(
                        onTap: () => _jumpToPinned(msgs),
                        child: ArenaPinnedBanner(
                          message: SupaDb.strOf(pinnedMsg['message']),
                          onView: () => _jumpToPinned(msgs),
                        ),
                      ),
                    Expanded(
                      child: ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.all(16),
                  itemCount: msgs.length,
                  itemBuilder: (context, i) {
                    final m = msgs[i];
                    final mine = SupaDb.strOf(m['firebase_uid']) == widget.uid;
                    // FIX 8: the shared WhatsApp-style bubble. FIX 4:
                    // image_url (once the backend column exists)
                    // renders as a photo inside the bubble; tap opens
                    // the full-size view. Text messages render
                    // exactly as before — same text, same timestamp.
                    final imageUrl = SupaDb.strOf(m['image_url']);
                    // Mockup #27 row (shared [ArenaChatMessage]):
                    // peer messages show avatar + name + time above
                    // the dark bubble + the flag icon (tap to report
                    // — the old long-press report moves to the flag,
                    // the mockup's pattern); own messages are
                    // right-aligned gold-tinted with "Name (You)".
                    // ORGANIZER = the row's real is_admin flag OR the
                    // sender being the designated admin (same rule as
                    // TeamChat/room — sendDmMessage never persists
                    // is_admin, so the flag alone would almost never
                    // fire). Peer-only: my own messages never take
                    // the organizer rendering, as in TeamChat.
                    final isPeerOrganizer = !mine &&
                        (m['is_admin'] == true ||
                            (_adminUid.isNotEmpty &&
                                SupaDb.strOf(m['firebase_uid']) == _adminUid));
                    // Per-message key for the pinned-banner jump
                    // (only the pinned message needs one).
                    final msgId = SupaDb.strOf(m['id']);
                    final isPinnedMsg = _pinned != null && SupaDb.strOf(_pinned!['id']) == msgId && msgId.isNotEmpty;
                    final itemKey = isPinnedMsg ? _msgKeys.putIfAbsent(msgId, () => GlobalKey()) : null;
                    return ArenaChatMessage(
                      key: itemKey,
                      isMine: mine,
                      highlight: isPinnedMsg && _highlightId == msgId,
                      onLongPress: () => _showDmMessageActions(m),
                      text: SupaDb.strOf(m['message']),
                      imageUrl: imageUrl,
                      onImageTap: imageUrl.isEmpty ? null : () => showChatImageDialog(context, imageUrl),
                      timeLabel: formatChatClock(m['timestamp']),
                      senderName: mine ? _myName : widget.peerName,
                      showYouSuffix: mine,
                      level: mine ? _myLevel : null,
                      avatar: mine
                          ? null
                          : _PlayerAvatar(profile: {'display_name': widget.peerName, 'photo_url': widget.peerPhotoUrl}, radius: 20),
                      isOrganizer: isPeerOrganizer,
                      reactions: _reactionRow(m, alignEnd: mine),
                      onReport: mine ? null : () => _reportMessage(m),
                    );
                  },
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          // P1-7: emoji opens the shared built-in picker above the
          // composer (the icon used to be disabled — DmComposer had
          // no onEmoji at all).
          if (_showEmoji)
            ArenaEmojiPicker(
              onSelected: (e) => insertEmojiAtCursor(_ctrl, e),
            ),
          DmComposer(
            controller: _ctrl,
            enabled: _areFriends,
            sending: _sending,
            uploading: _uploading,
            onSend: _send,
            onAttach: _sendImage,
            onEmoji: () => setState(() => _showEmoji = !_showEmoji),
          ),
        ],
      ),
      ),
    );
  }
}

/// DM composer (FIX 4): text field + image-attach button + send
/// button. Extracted from DirectMessagePage so the attach button is
/// widget-testable without Firebase/Supabase. Chat-unify (2026-11-21):
/// the SAME mockup-#27 composer as every other chat (shared
/// [ArenaChatInputBar] — pill field, emoji + image icons inside,
/// gold round send). The attach button keeps its image icon +
/// 'Send a picture' tooltip; while an upload runs it becomes a small
/// spinner and sending is disabled. Text behaviour is unchanged.
class DmComposer extends StatelessWidget {
  final TextEditingController controller;
  final bool enabled;
  final bool sending;
  final bool uploading;
  final VoidCallback onSend;
  final VoidCallback onAttach;
  final VoidCallback? onEmoji;
  const DmComposer({super.key, required this.controller, required this.enabled, required this.sending, required this.uploading, required this.onSend, required this.onAttach, this.onEmoji});

  @override
  Widget build(BuildContext context) {
    final canSend = enabled && !sending && !uploading;
    return ArenaChatInputBar(
      controller: controller,
      hint: enabled ? 'Type a message...' : 'Friends-only chat',
      onSend: canSend ? onSend : null,
      onEmoji: enabled ? onEmoji : null,
      onAttach: enabled && !uploading ? onAttach : null,
      attachIcon: Icons.image,
      attachTooltip: 'Send a picture',
      enabled: enabled,
      busy: uploading,
    );
  }
}
