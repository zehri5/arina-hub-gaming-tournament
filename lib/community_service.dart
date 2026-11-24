import 'dart:async';
import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'services/supabase_db.dart';
import 'utils.dart';

/// COMMUNITY DATA LAYER (2026-11-20, worker round — Community System).
///
/// All community DB calls live here. supabase_db.dart is NOT edited.
///
/// Tables (migration 035, DRAFT — NOT applied yet):
///   * friend_requests — from_uid / to_uid / status
///     (pending | accepted | declined). FRIENDSHIPS ARE DERIVED from
///     accepted requests — there is NO separate friendships table, so
///     a friendship can never drift out of sync with its request.
///   * follows — follower_uid / following_uid (unique pair). May
///     already exist from migration 008 (PlayerLookupPage reads it);
///     035 creates it only if missing and adds any missing column.
///   * chat_messages scope 'dm' + dm_key — 1:1 DMs reuse the existing
///     chat_messages table; dm_key is the two Firebase UIDs sorted
///     and joined with '|' (see [dmKey]).
///
/// GRACEFUL DEGRADATION: every function that touches a 035 table
/// catches the PostgREST "table does not exist" error and reports
/// {'ok': false, 'offline': true} (or an empty/0 result for reads)
/// instead of throwing — the UI shows a "coming online" state.
/// Username search + public profile read the EXISTING profiles
/// table, so they work BEFORE 035 is applied.
///
/// PRIVACY: Firebase UID is NEVER a search key and NEVER appears in
/// any user-facing string. [publicProfile]/[searchByUsername] strip
/// every private field (email, phone, wallet balances, earnings,
/// referral code) before the map reaches the UI.
class CommunityService {
  CommunityService._();

  // ------------------------------------------------------------------
  // Helpers
  // ------------------------------------------------------------------

  /// Same missing-table detection as pro_features' proTableMissing:
  /// PGRST205 (table not found in schema cache), 42P01 (undefined
  /// table), or the plain "does not exist" text.
  static bool tableMissing(Object e) {
    final s = e.toString();
    return s.contains('PGRST205') ||
        s.contains('42P01') ||
        s.contains('does not exist') ||
        s.contains('Could not find the table');
  }

  static SupabaseClient get _client => SupaDb.client;

  /// DM addressing: the two UIDs sorted lexicographically, joined
  /// with '|'. Both participants compute the SAME key, so either side
  /// can open the thread. UIDs contain no '|', so the key splits
  /// cleanly back into the pair.
  static String dmKey(String a, String b) =>
      a.compareTo(b) <= 0 ? '$a|$b' : '$b|$a';

  /// The other participant of a dm_key, given my UID.
  static String dmPeer(String key, String me) {
    final parts = key.split('|');
    if (parts.length != 2) return '';
    return parts[0] == me ? parts[1] : parts[0];
  }

  /// Keep ONLY the fields a public profile view may show. Everything
  /// private (email, phone, wallet, earnings, referral data,
  /// onesignal id) is dropped here — the UI can never leak it by
  /// accident. firebase_uid is kept INTERNALLY (follow / friend /
  /// DM actions need it) but must never be rendered.
  static Map<String, dynamic> _publicMap(Map<String, dynamic> p) {
    if (p.isEmpty) return {};
    return {
      'firebase_uid': SupaDb.strOf(p['firebase_uid']),
      'username': SupaDb.strOf(p['username']),
      'display_name': SupaDb.strOf(p['display_name']),
      'displayName': SupaDb.strOf(p['display_name']),
      'photo_url': SupaDb.strOf(p['photo_url']),
      'photoURL': SupaDb.strOf(p['photo_url']),
      'level': SupaDb.intOf(p['level'], 1),
      'rank_tier': SupaDb.strOf(p['rank_tier']),
      'total_matches': SupaDb.intOf(p['total_matches']),
      'totalMatches': SupaDb.intOf(p['total_matches']),
      'won_matches': SupaDb.intOf(p['won_matches']),
      'wonMatches': SupaDb.intOf(p['won_matches']),
      'leaderboard_rank': SupaDb.intOf(p['leaderboard_rank'], 0),
    };
  }

  /// True when the friend_requests table exists (one cheap probe).
  /// This gates FRIENDS / friend requests / DMs only — see
  /// [followsBackendReady] for the separate follows gate. The hub
  /// calls this on load to decide between the live UI and the
  /// "coming online" state. Any error (missing table, offline, RLS)
  /// reads as not-ready — never a throw.
  static Future<bool> communityBackendReady() async {
    try {
      await _client.from('friend_requests').select('id').limit(1);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// True when the follows table exists (one cheap probe). Follow /
  /// unfollow + follower/following counts do NOT wait for migration
  /// 035: follows was created by migration 008 and is live today
  /// (verified 2026-11-20 against the live database), so the Follow
  /// button and the Following tab work while friend requests / DMs
  /// still wait for 035. Any error reads as not-ready — never a
  /// throw.
  static Future<bool> followsBackendReady() async {
    try {
      await _client.from('follows').select('follower_uid').limit(1);
      return true;
    } catch (_) {
      return false;
    }
  }

  // ------------------------------------------------------------------
  // Username search + public profile (EXISTING profiles table —
  // works BEFORE migration 035).
  // ------------------------------------------------------------------

  /// Search by USERNAME (exact match, leading '@' stripped) via the
  /// existing SupaDb.findUserByUsername. Returns the public profile
  /// map, or {} when no such username exists. Never throws.
  static Future<Map<String, dynamic>> searchByUsername(
      String username) async {
    try {
      final p = await SupaDb.findUserByUsername(username);
      return _publicMap(p);
    } catch (_) {
      return {};
    }
  }

  /// Case-insensitive username availability check, for the Edit
  /// Profile flow: true when NO other profile holds this username
  /// (case-insensitive). LIKE wildcards in the name are escaped so
  /// '_' / '%' match literally. The caller's own UID is excluded
  /// via [excludeUid] (keeping your own username is always fine).
  /// On any error returns true (fail-open: the DB unique index in
  /// 035 is the real enforcer, and the save path surfaces its error).
  static Future<bool> isUsernameAvailable(String username,
      {String? excludeUid}) async {
    final name = username.trim().replaceFirst(RegExp(r'^@'), '');
    if (name.isEmpty) return false;
    try {
      final escaped = name.replaceAll('\\', '\\\\').replaceAll('%', '\\%').replaceAll('_', '\\_');
      final rows = await _client
          .from('profiles')
          .select('firebase_uid')
          .ilike('username', escaped);
      for (final r in (rows as List)) {
        final uid = SupaDb.strOf((r as Map)['firebase_uid']);
        if (uid.isEmpty || uid != excludeUid) return false;
      }
      return true;
    } catch (_) {
      return true;
    }
  }

  /// Public profile of any player by UID (read-only, private fields
  /// stripped). {} when the profile does not exist. Never throws.
  static Future<Map<String, dynamic>> publicProfile(String uid) async {
    if (uid.isEmpty) return {};
    try {
      return _publicMap(await SupaDb.getProfile(uid));
    } catch (_) {
      return {};
    }
  }

  /// Public profiles for a set of UIDs (friends / followers lists).
  /// One query, then normalised + stripped per row.
  static Future<List<Map<String, dynamic>>> publicProfiles(
      List<String> uids) async {
    final ids = uids.where((u) => u.isNotEmpty).toSet().toList();
    if (ids.isEmpty) return [];
    try {
      final rows = await _client
          .from('profiles')
          .select()
          .inFilter('firebase_uid', ids);
      return (rows as List)
          .map((r) => _publicMap(SupaDb.normProfile(
              Map<String, dynamic>.from(r as Map))))
          .where((m) => m.isNotEmpty)
          .toList();
    } catch (_) {
      return [];
    }
  }

  // ------------------------------------------------------------------
  // Friend requests + friendships (035 — derived from accepted
  // requests; no separate friendships table).
  // ------------------------------------------------------------------

  /// Pending-request count for the CURRENT user, as a live stream.
  /// NEVER throws: emits 0 when logged out, when the table does not
  /// exist yet, when realtime is unavailable, or on any error.
  /// Backed by SupaDb.streamList (initial fetch + postgres_changes
  /// refetch); screens that do not hold the stream refetch on resume.
  static Stream<int> get pendingRequestCountStream async* {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    if (uid.isEmpty) {
      yield 0;
      return;
    }
    try {
      await for (final rows in SupaDb.streamList('friend_requests',
          eqCol: 'to_uid', eqVal: uid, eqCol2: 'status', eqVal2: 'pending')) {
        yield rows.length;
      }
    } catch (_) {
      yield 0;
    }
  }

  /// One-shot pending count (for screens that prefer a Future).
  /// 0 when logged out / table missing / any error — never throws.
  static Future<int> pendingRequestCount(String uid) async {
    if (uid.isEmpty) return 0;
    try {
      final rows = await _client
          .from('friend_requests')
          .select('id')
          .eq('to_uid', uid)
          .eq('status', 'pending');
      return (rows as List).length;
    } catch (_) {
      return 0;
    }
  }

  /// Incoming pending requests for [uid] (newest first), each row
  /// carrying its sender's public profile under 'sender'.
  static Future<List<Map<String, dynamic>>> pendingRequests(
      String uid) async {
    if (uid.isEmpty) return [];
    try {
      final rows = await _client
          .from('friend_requests')
          .select()
          .eq('to_uid', uid)
          .eq('status', 'pending')
          .order('created_at', ascending: false);
      final list = (rows as List)
          .map((r) => Map<String, dynamic>.from(r as Map))
          .toList();
      final senders = await publicProfiles(
          list.map((r) => SupaDb.strOf(r['from_uid'])).toList());
      final byUid = {for (final s in senders) SupaDb.strOf(s['firebase_uid']): s};
      for (final r in list) {
        r['sender'] = byUid[SupaDb.strOf(r['from_uid'])] ?? {};
      }
      return list;
    } catch (_) {
      return [];
    }
  }

  /// Relationship between [me] and [other]: 'none', 'pending_out'
  /// (I sent it), 'pending_in' (they sent it — request id returned
  /// so the UI can Accept/Decline), or 'friends'. Also returns
  /// {'offline': true} when the 035 tables do not exist yet.
  static Future<Map<String, dynamic>> friendshipStatus(
      String me, String other) async {
    if (me.isEmpty || other.isEmpty || me == other) {
      return {'status': 'none'};
    }
    try {
      final rows = await _client
          .from('friend_requests')
          .select()
          .or('and(from_uid.eq.$me,to_uid.eq.$other),and(from_uid.eq.$other,to_uid.eq.$me)');
      for (final r in (rows as List)) {
        final m = Map<String, dynamic>.from(r as Map);
        final status = SupaDb.strOf(m['status']);
        if (status == 'accepted') return {'status': 'friends'};
        if (status == 'pending') {
          if (SupaDb.strOf(m['from_uid']) == me) {
            return {'status': 'pending_out'};
          }
          return {
            'status': 'pending_in',
            'request_id': SupaDb.strOf(m['id']),
          };
        }
      }
      return {'status': 'none'};
    } catch (e) {
      if (tableMissing(e)) return {'status': 'none', 'offline': true};
      return {'status': 'none'};
    }
  }

  /// Send a friend request. Rejects self-requests and duplicate
  /// pending requests (either direction) with a friendly message;
  /// a declined request may be sent again (old row is re-opened).
  static Future<Map<String, dynamic>> sendFriendRequest(
      String fromUid, String toUid) async {
    if (fromUid.isEmpty || toUid.isEmpty) {
      return {'ok': false, 'error': 'Login zaroori hai.'};
    }
    if (fromUid == toUid) {
      return {'ok': false, 'error': 'Apne aap ko friend request nahi bhej sakte.'};
    }
    if (await isBlockedEitherWay(fromUid, toUid)) {
      return {'ok': false, 'error': 'Is player ko friend request nahi bheji ja sakti.'};
    }
    try {
      final existing = await friendshipStatus(fromUid, toUid);
      if (existing['offline'] == true) {
        return {'ok': false, 'offline': true};
      }
      final st = SupaDb.strOf(existing['status']);
      if (st == 'friends') {
        return {'ok': false, 'error': 'Ye player pehle se friend hai.'};
      }
      if (st == 'pending_out') {
        return {'ok': false, 'error': 'Friend request pehle se pending hai.'};
      }
      if (st == 'pending_in') {
        return {
          'ok': false,
          'error': 'Is player ki request pehle se pending hai — Requests mein accept karen.'
        };
      }
      // A declined request may be re-sent: re-open the old row.
      final declined = await _client
          .from('friend_requests')
          .select('id')
          .eq('from_uid', fromUid)
          .eq('to_uid', toUid)
          .eq('status', 'declined')
          .limit(1);
      final dList = declined as List;
      if (dList.isNotEmpty) {
        final id = SupaDb.strOf((dList.first as Map)['id']);
        await _client
            .from('friend_requests')
            .update({'status': 'pending'}).eq('id', id);
        await _notifyFriendRequest(fromUid, toUid);
        return {'ok': true};
      }
      await _client.from('friend_requests').insert({
        'from_uid': fromUid,
        'to_uid': toUid,
        'status': 'pending',
      });
      await _notifyFriendRequest(fromUid, toUid);
      return {'ok': true};
    } catch (e) {
      if (tableMissing(e)) return {'ok': false, 'offline': true};
      final msg = e.toString();
      if (msg.contains('duplicate key') || msg.contains('uq_friend_requests')) {
        return {'ok': false, 'error': 'Friend request pehle se pending hai.'};
      }
      return {'ok': false, 'error': msg};
    }
  }

  /// Notify the recipient of a friend request (best-effort — a
  /// failed notification never fails the request itself).
  static Future<void> _notifyFriendRequest(String fromUid, String toUid) async {
    try {
      final p = await SupaDb.getProfile(fromUid);
      final name = SupaDb.strOf(p['displayName'], 'Aik player');
      await SupaDb.notifyUser(
          toUid, 'Friend Request', '$name ne aapko friend request bheji hai.');
    } catch (_) {}
  }

  /// Accept or decline an incoming request. Only the recipient may
  /// respond (enforced by RLS in 035). Accepting turns the request
  /// into the friendship — no second row is written.
  static Future<Map<String, dynamic>> respondFriendRequest(
      String requestId, bool accept) async {
    if (requestId.isEmpty) return {'ok': false, 'error': 'Request nahi mili.'};
    try {
      await _client
          .from('friend_requests')
          .update({'status': accept ? 'accepted' : 'declined'})
          .eq('id', requestId);
      return {'ok': true};
    } catch (e) {
      if (tableMissing(e)) return {'ok': false, 'offline': true};
      return {'ok': false, 'error': e.toString()};
    }
  }

  /// Friends of [uid]: the OTHER side of every accepted request
  /// (either direction), with public profiles. [] when the table
  /// does not exist yet — never throws.
  static Future<List<Map<String, dynamic>>> friends(String uid) async {
    if (uid.isEmpty) return [];
    try {
      final rows = await _client
          .from('friend_requests')
          .select()
          .eq('status', 'accepted')
          .or('from_uid.eq.$uid,to_uid.eq.$uid')
          .order('created_at', ascending: false);
      final otherUids = <String>{};
      for (final r in (rows as List)) {
        final m = Map<String, dynamic>.from(r as Map);
        final from = SupaDb.strOf(m['from_uid']);
        final to = SupaDb.strOf(m['to_uid']);
        otherUids.add(from == uid ? to : from);
      }
      return await publicProfiles(otherUids.toList());
    } catch (_) {
      return [];
    }
  }

  /// True when [a] and [b] are friends (accepted request either way).
  /// Used to gate DMs (friends-only). False on any error.
  static Future<bool> areFriends(String a, String b) async {
    if (a.isEmpty || b.isEmpty || a == b) return false;
    final st = await friendshipStatus(a, b);
    if (SupaDb.strOf(st['status']) == 'friends') return true;
    // LEGACY friends table (PlayerLookupPage one-way adds): a row in
    // either direction also counts as a friend for DM gating, so a
    // lookup-added friend can DM (audit fix 2026-11-21 — the two
    // friendship systems are otherwise unsynced; unifying them needs
    // the backend decision recorded in the audit guide).
    try {
      final rows = await _client
          .from('friends')
          .select('user_uid')
          .or('and(user_uid.eq.$a,friend_uid.eq.$b),and(user_uid.eq.$b,friend_uid.eq.$a)')
          .limit(1);
      return (rows as List).isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// True when either player has blocked the other (blocked_users,
  /// either direction). Fail-open on error (no block proven).
  static Future<bool> isBlockedEitherWay(String a, String b) async {
    if (a.isEmpty || b.isEmpty) return false;
    try {
      final rows = await _client
          .from('blocked_users')
          .select('blocker_uid')
          .or('and(blocker_uid.eq.$a,blocked_uid.eq.$b),and(blocker_uid.eq.$b,blocked_uid.eq.$a)')
          .limit(1);
      return (rows as List).isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Unfriend: deletes the accepted request row(s) between the pair
  /// (both directions — the unique pair index means at most one).
  static Future<Map<String, dynamic>> unfriend(
      String me, String friendUid) async {
    if (me.isEmpty || friendUid.isEmpty) {
      return {'ok': false, 'error': 'Login zaroori hai.'};
    }
    try {
      await _client
          .from('friend_requests')
          .delete()
          .eq('status', 'accepted')
          .or('and(from_uid.eq.$me,to_uid.eq.$friendUid),and(from_uid.eq.$friendUid,to_uid.eq.$me)');
      return {'ok': true};
    } catch (e) {
      if (tableMissing(e)) return {'ok': false, 'offline': true};
      return {'ok': false, 'error': e.toString()};
    }
  }

  // ------------------------------------------------------------------
  // Follows (035 — no approval needed).
  // ------------------------------------------------------------------

  static Future<bool> isFollowing(String me, String other) async {
    if (me.isEmpty || other.isEmpty || me == other) return false;
    try {
      final rows = await _client
          .from('follows')
          .select('follower_uid')
          .eq('follower_uid', me)
          .eq('following_uid', other)
          .limit(1);
      return (rows as List).isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  static Future<Map<String, dynamic>> follow(
      String me, String other) async {
    if (me.isEmpty || other.isEmpty) {
      return {'ok': false, 'error': 'Login zaroori hai.'};
    }
    if (me == other) {
      return {'ok': false, 'error': 'Apne aap ko follow nahi kar sakte.'};
    }
    try {
      await _client
          .from('follows')
          .insert({'follower_uid': me, 'following_uid': other});
      return {'ok': true};
    } catch (e) {
      if (tableMissing(e)) return {'ok': false, 'offline': true};
      if (e.toString().contains('duplicate key')) return {'ok': true};
      return {'ok': false, 'error': e.toString()};
    }
  }

  static Future<Map<String, dynamic>> unfollow(
      String me, String other) async {
    if (me.isEmpty || other.isEmpty) {
      return {'ok': false, 'error': 'Login zaroori hai.'};
    }
    try {
      await _client
          .from('follows')
          .delete()
          .eq('follower_uid', me)
          .eq('following_uid', other);
      return {'ok': true};
    } catch (e) {
      if (tableMissing(e)) return {'ok': false, 'offline': true};
      return {'ok': false, 'error': e.toString()};
    }
  }

  /// {'followers': n, 'following': n} for [uid]. 0/0 when the table
  /// does not exist yet — never throws.
  static Future<Map<String, int>> followCounts(String uid) async {
    if (uid.isEmpty) return {'followers': 0, 'following': 0};
    try {
      final followers = await _client
          .from('follows')
          .select('follower_uid')
          .eq('following_uid', uid);
      final following = await _client
          .from('follows')
          .select('following_uid')
          .eq('follower_uid', uid);
      return {
        'followers': (followers as List).length,
        'following': (following as List).length,
      };
    } catch (_) {
      return {'followers': 0, 'following': 0};
    }
  }

  /// Followers of [uid] (public profiles), newest first.
  static Future<List<Map<String, dynamic>>> followers(String uid) async {
    if (uid.isEmpty) return [];
    try {
      final rows = await _client
          .from('follows')
          .select('follower_uid')
          .eq('following_uid', uid)
          .order('created_at', ascending: false);
      return await publicProfiles((rows as List)
          .map((r) => SupaDb.strOf((r as Map)['follower_uid']))
          .toList());
    } catch (_) {
      return [];
    }
  }

  /// Players [uid] follows (public profiles), newest first.
  static Future<List<Map<String, dynamic>>> following(String uid) async {
    if (uid.isEmpty) return [];
    try {
      final rows = await _client
          .from('follows')
          .select('following_uid')
          .eq('follower_uid', uid)
          .order('created_at', ascending: false);
      return await publicProfiles((rows as List)
          .map((r) => SupaDb.strOf((r as Map)['following_uid']))
          .toList());
    } catch (_) {
      return [];
    }
  }

  // ------------------------------------------------------------------
  // 1:1 DMs (friends-only; chat_messages scope 'dm' + dm_key).
  // ------------------------------------------------------------------

  /// DM conversation list for [uid]: one entry per thread, newest
  /// message first. Each entry: {dm_key, peer (public profile),
  /// last_message, last_at}. [] when chat_messages has no dm_key
  /// column yet (035 not applied) — never throws.
  static Future<List<Map<String, dynamic>>> dmConversations(
      String uid) async {
    if (uid.isEmpty) return [];
    try {
      final rows = await _client
          .from('chat_messages')
          .select()
          .eq('scope', 'dm')
          .or('dm_key.like.$uid|%,dm_key.like.%|$uid')
          .order('created_at', ascending: false)
          .limit(200);
      final byKey = <String, Map<String, dynamic>>{};
      for (final r in (rows as List)) {
        final m = SupaDb.normChat(Map<String, dynamic>.from(r as Map));
        final key = SupaDb.strOf(m['dm_key']);
        if (key.isEmpty) continue;
        byKey.putIfAbsent(key, () => m);
      }
      final peers = await publicProfiles(
          byKey.keys.map((k) => dmPeer(k, uid)).toList());
      final byUid = {for (final p in peers) SupaDb.strOf(p['firebase_uid']): p};
      final out = <Map<String, dynamic>>[];
      for (final e in byKey.entries) {
        final peerUid = dmPeer(e.key, uid);
        // FIX 4 follow-up (2026-11-21): image-only DM rows carry
        // message='' — show 'Photo' instead of a blank preview.
        final lastText = SupaDb.strOf(e.value['message']);
        final lastImage = SupaDb.strOf(e.value['image_url']);
        out.add({
          'dm_key': e.key,
          'peer_uid': peerUid,
          'peer': byUid[peerUid] ?? {},
          'last_message': lastText.isNotEmpty ? lastText : (lastImage.isNotEmpty ? tr('Photo', 'Tasveer') : ''),
          'last_at': SupaDb.intOf(e.value['timestamp']),
        });
      }
      out.sort((a, b) =>
          SupaDb.intOf(b['last_at']).compareTo(SupaDb.intOf(a['last_at'])));
      return out;
    } catch (_) {
      return [];
    }
  }

  /// One-shot DM history for a thread (oldest first, latest 200).
  static Future<List<Map<String, dynamic>>> getDmMessages(
      String key) async {
    if (key.isEmpty) return [];
    try {
      final rows = await SupaDb.getList('chat_messages',
          eqCol: 'scope',
          eqVal: 'dm',
          eqCol2: 'dm_key',
          eqVal2: key,
          orderBy: 'created_at',
          ascending: true,
          limit: 200);
      return rows.map(SupaDb.normChat).where((m) => m['deleted_at'] == null).toList();
    } catch (_) {
      return [];
    }
  }

  /// Live DM thread (initial fetch + postgres_changes refetch, same
  /// pattern as SupaDb.streamChat). Never throws — emits [] when the
  /// dm_key column does not exist yet.
  static Stream<List<Map<String, dynamic>>> streamDmMessages(String key) {
    if (key.isEmpty) return Stream.value(const []);
    try {
      return SupaDb.streamList('chat_messages',
              eqCol: 'scope',
              eqVal: 'dm',
              eqCol2: 'dm_key',
              eqVal2: key,
              orderBy: 'created_at',
              ascending: true,
              limit: 200)
          .map((rows) => rows.map(SupaDb.normChat).where((m) => m['deleted_at'] == null).toList());
    } catch (_) {
      return Stream.value(const []);
    }
  }

  /// Send a DM. FRIENDS-ONLY: refused (friendly message, no write)
  /// when the two players are not friends. The insert reuses the
  /// chat_messages shape (scope / firebase_uid / display_name /
  /// sender / message) + dm_key; tournament_id stays NULL for DMs
  /// (035 drops the NOT NULL if it was ever set).
  static Future<Map<String, dynamic>> sendDmMessage({
    required String fromUid,
    required String toUid,
    required String displayName,
    required String message,
  }) async {
    final text = message.trim();
    if (text.isEmpty) return {'ok': false, 'error': 'Message khaali hai.'};
    if (fromUid.isEmpty || toUid.isEmpty || fromUid == toUid) {
      return {'ok': false, 'error': 'DM nahi bheji ja sakti.'};
    }
    try {
      if (!await areFriends(fromUid, toUid)) {
        return {
          'ok': false,
          'error': 'DM sirf friends ko bheji ja sakti hai — pehle friend request accept karen.'
        };
      }
      if (await SupaDb.isChatRestricted(fromUid)) {
        return {
          'ok': false,
          'error': 'Aapka chat admin ne band kiya hua hai — admin se rabta karein.'
        };
      }
      if (await isBlockedEitherWay(fromUid, toUid)) {
        return {
          'ok': false,
          'error': 'Is player ko DM nahi bheji ja sakti.'
        };
      }
      await _client.from('chat_messages').insert({
        'scope': 'dm',
        'dm_key': dmKey(fromUid, toUid),
        'firebase_uid': fromUid,
        'display_name': displayName,
        'sender': displayName,
        'message': text,
      });
      return {'ok': true};
    } catch (e) {
      if (tableMissing(e)) {
        return {
          'ok': false,
          'offline': true,
          'error': 'DM backend abhi online nahi hua (migration 035 pending).'
        };
      }
      // A missing dm_key column reads as "column does not exist" —
      // same offline state, not a crash.
      if (e.toString().contains('dm_key')) {
        return {
          'ok': false,
          'offline': true,
          'error': 'DM backend abhi online nahi hua (migration 035 pending).'
        };
      }
      return {'ok': false, 'error': e.toString()};
    }
  }

  /// FIX 4 (2026-11-21): does the live chat_messages table have the
  /// image_url column yet? A fast one-row probe — the DM composer
  /// checks BEFORE uploading, so a missing column fails fast instead
  /// of after a 30 s upload on a slow connection. False on any error
  /// (a missing column reads as Postgrest 42703); never throws.
  static Future<bool> dmImageColumnReady() async {
    try {
      await _client.from('chat_messages').select('image_url').limit(1);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// FIX 4 (2026-11-21): send a PICTURE in a DM. Same friends-only
  /// rule and row shape as [sendDmMessage], plus the ImgBB URL in
  /// chat_messages.image_url (backend addendum — the column does not
  /// exist on live yet; see [dmImageColumnReady]). The message body
  /// stays empty: the URL is NEVER stuffed into the text. A missing
  /// column returns {'ok': false, 'needs_column': true} instead of
  /// crashing, so the UI can say the backend update is pending.
  static Future<Map<String, dynamic>> sendDmImageMessage({
    required String fromUid,
    required String toUid,
    required String displayName,
    required String imageUrl,
  }) async {
    final url = imageUrl.trim();
    if (url.isEmpty) return {'ok': false, 'error': 'Photo ka link khaali hai.'};
    if (fromUid.isEmpty || toUid.isEmpty || fromUid == toUid) {
      return {'ok': false, 'error': 'DM nahi bheji ja sakti.'};
    }
    try {
      if (!await areFriends(fromUid, toUid)) {
        return {
          'ok': false,
          'error': 'DM sirf friends ko bheji ja sakti hai — pehle friend request accept karen.'
        };
      }
      if (await SupaDb.isChatRestricted(fromUid)) {
        return {
          'ok': false,
          'error': 'Aapka chat admin ne band kiya hua hai — admin se rabta karein.'
        };
      }
      if (await isBlockedEitherWay(fromUid, toUid)) {
        return {
          'ok': false,
          'error': 'Is player ko DM nahi bheji ja sakti.'
        };
      }
      await _client.from('chat_messages').insert({
        'scope': 'dm',
        'dm_key': dmKey(fromUid, toUid),
        'firebase_uid': fromUid,
        'display_name': displayName,
        'sender': displayName,
        'message': '',
        'image_url': url,
      });
      return {'ok': true};
    } catch (e) {
      if (tableMissing(e)) {
        return {
          'ok': false,
          'offline': true,
          'error': 'DM backend abhi online nahi hua (migration 035 pending).'
        };
      }
      if (e.toString().contains('image_url')) {
        return {
          'ok': false,
          'needs_column': true,
          'error': 'Photo messages ke liye backend update pending hai.'
        };
      }
      return {'ok': false, 'error': e.toString()};
    }
  }

  // ------------------------------------------------------------------
  // Notification delete (user_notifications — own rows only).
  // ------------------------------------------------------------------

  /// Delete ONE of the user's own user_notifications rows.
  /// Direct DELETE first; the row is re-read to confirm it is gone
  /// (RLS can silently drop a delete — a success response alone does
  /// not prove the row went away). If the row survives (RLS blocks
  /// DELETE until draft 036 is applied), falls back to the existing
  /// dismiss_notification RPC (027) so the row still disappears from
  /// the user's list. Global `notifications` rows are never passed
  /// here — the UI only offers delete on rows whose firebase_uid is
  /// the current user.
  static Future<Map<String, dynamic>> deleteNotification({
    required String id,
    required String uid,
  }) async {
    if (id.isEmpty || uid.isEmpty) {
      return {'ok': false, 'error': 'Notification nahi mili.'};
    }
    try {
      await _client
          .from('user_notifications')
          .delete()
          .eq('id', id)
          .eq('firebase_uid', uid);
      final stillThere =
          await SupaDb.getRow('user_notifications', 'id', id);
      if (stillThere.isEmpty) return {'ok': true};
      // Row survived: RLS blocked the DELETE (036 pending) — fall
      // back to the proven dismiss RPC so the row still leaves the
      // user's list.
      final res = await SupaDb.dismissNotification(id);
      if (res['ok'] == true) return {'ok': true, 'via_rpc': true};
      return {
        'ok': false,
        'error': 'Delete blocked — notification delete policy (036) abhi pending hai.'
      };
    } catch (e) {
      // Direct delete threw (e.g. RLS violation surfaces as an
      // error): try the dismiss RPC before giving up.
      try {
        final res = await SupaDb.dismissNotification(id);
        if (res['ok'] == true) return {'ok': true, 'via_rpc': true};
      } catch (_) {}
      return {'ok': false, 'error': e.toString()};
    }
  }
}

/// COMMUNITIES — user-created groups (2026-11-21, user design, voice
/// call: "WhatsApp channels jaisi communities — user community banaye,
/// doosre follow karen, andar chat/post karen").
///
/// DATA MODEL (draft migration 073 — DRAFT ONLY, NOT applied yet):
///   * communities — id / created_by_uid / name / description /
///     photo_url / is_public / created_at / updated_at.
///   * community_members — community_id / firebase_uid / role
///     (creator | admin | member) / joined_at. FOLLOWING a community
///     IS the member row; unfollow deletes it. The creator is
///     auto-added as role 'creator' at creation time.
///   * community_posts — community_id / author_uid / body / image_url.
///   * community_comments — post_id / author_uid / body.
///   * chat_messages.community_id — community CHAT reuses the EXISTING
///     live chat_messages table (scope = 'community', tournament_id =
///     NULL, squad_id = NULL), same pattern as squad chat (squad_id)
///     and DMs (dm_key).
///
/// REUSED AS-IS (already live — no migration needed):
///   * profiles — creator / author / member names + photos, via
///     [CommunityService.publicProfiles] (private fields stripped).
///   * user_notifications — via [SupaDb.notifyUser] (best-effort).
///   * ImgBB — community photos upload with ImgbbService; the UI
///     passes the URL in, this layer never uploads.
///
/// GRACEFUL DEGRADATION: every method that touches a 073 table
/// catches the PostgREST "table does not exist" error and reports
/// {'ok': false, 'offline': true} (or an empty result for reads)
/// instead of throwing — the UI shows a "coming online" state.
/// Nothing here ever throws.
class CommunityGroups {
  CommunityGroups._();

  /// Scale page size (guide §4.1): members / posts / chat / list
  /// all page at 50. One constant so no file invents its own cap.
  static const int pageSize = 50;

  static SupabaseClient get _client => SupaDb.client;

  static bool _missingColumn(Object e) =>
      e.toString().contains('community_id') ||
      e.toString().contains('PGRST204') ||
      e.toString().contains('column does not exist');

  // ------------------------------------------------------------------
  // Cached-first (guide §4.1 "instant load"): the last good
  // communities list + detail rows are saved locally so the list
  // and detail pages render IMMEDIATELY on open; fresh data
  // replaces them in the background. Cache is best-effort only —
  // every read/write is wrapped, a broken cache never crashes
  // anything and never shows stale data as fresh (the UI always
  // refreshes behind it).
  // ------------------------------------------------------------------

  static const String _cacheListKey = 'cached_communities_v1';
  static const String _cacheDetailPrefix = 'cached_community_v1:';

  /// Last saved communities list (already normalised rows), [] when
  /// nothing was saved yet or the cache is unreadable.
  static Future<List<Map<String, dynamic>>> loadCachedCommunities() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_cacheListKey);
      if (raw == null || raw.isEmpty) return [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return decoded
          .whereType<Map>()
          .map((m) => Map<String, dynamic>.from(m))
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// Save the first page of the communities list for instant load.
  /// Only the first page is cached (page 0 = what the user sees
  /// first); deeper pages always come from the network.
  static Future<void> cacheCommunities(
      List<Map<String, dynamic>> rows) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_cacheListKey, jsonEncode(rows));
    } catch (_) {}
  }

  /// Last saved detail row for one community, {} when none.
  static Future<Map<String, dynamic>> loadCachedCommunity(
      String id) async {
    if (id.isEmpty) return {};
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('$_cacheDetailPrefix$id');
      if (raw == null || raw.isEmpty) return {};
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      return Map<String, dynamic>.from(decoded);
    } catch (_) {
      return {};
    }
  }

  /// Save one community detail row for instant load.
  static Future<void> cacheCommunity(Map<String, dynamic> row) async {
    final id = SupaDb.strOf(row['id']);
    if (id.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('$_cacheDetailPrefix$id', jsonEncode(row));
    } catch (_) {}
  }

  /// Normalise one communities row: both snake_case and camelCase
  /// keys, member count + my-membership filled in by the list
  /// methods below (0 / false when unknown). Pure — unit-testable.
  static Map<String, dynamic> normCommunity(Map<String, dynamic> r) {
    if (r.isEmpty) return {};
    final m = Map<String, dynamic>.from(r);
    m['id'] = SupaDb.strOf(r['id']);
    m['name'] = SupaDb.strOf(r['name'], 'Community');
    m['description'] = SupaDb.strOf(r['description']);
    m['photo_url'] = SupaDb.strOf(r['photo_url'], SupaDb.strOf(r['photoUrl']));
    m['photoUrl'] = m['photo_url'];
    m['created_by_uid'] = SupaDb.strOf(r['created_by_uid'], SupaDb.strOf(r['createdByUid']));
    m['createdByUid'] = m['created_by_uid'];
    m['is_public'] = r['is_public'] ?? r['isPublic'] ?? true;
    // FIX 14 + FIX 15 (v2016, backend guide §1): voice-approval
    // flag — the admin approves voice for a community once, then
    // the flag stays true. Missing (pre-§1 row) reads as false
    // (fail-closed: voice locked AND organizer powers stay off
    // until approval lands). Strict == true so the stored value
    // is always a bool.
    m['voice_enabled'] =
        r['voice_enabled'] == true || r['voiceEnabled'] == true;
    m['voiceEnabled'] = m['voice_enabled'];
    m['createdAt'] = SupaDb.parseTs(r['created_at'] ?? r['createdAt']);
    m['memberCount'] = SupaDb.intOf(r['member_count'], SupaDb.intOf(r['memberCount']));
    m['member_count'] = m['memberCount'];
    m['isMember'] = r['is_member'] ?? r['isMember'] ?? false;
    m['is_member'] = m['isMember'];
    m['myRole'] = SupaDb.strOf(r['my_role'], SupaDb.strOf(r['myRole']));
    m['my_role'] = m['myRole'];
    return m;
  }

  /// Normalise one community_posts row (author profile attached
  /// under 'author' by the list methods). Pure — unit-testable.
  static Map<String, dynamic> normPost(Map<String, dynamic> r) {
    if (r.isEmpty) return {};
    final m = Map<String, dynamic>.from(r);
    m['id'] = SupaDb.strOf(r['id']);
    m['community_id'] = SupaDb.strOf(r['community_id']);
    m['author_uid'] = SupaDb.strOf(r['author_uid']);
    m['body'] = SupaDb.strOf(r['body']);
    m['image_url'] = SupaDb.strOf(r['image_url'], SupaDb.strOf(r['imageUrl']));
    m['imageUrl'] = m['image_url'];
    m['createdAt'] = SupaDb.parseTs(r['created_at'] ?? r['createdAt']);
    m['commentCount'] = SupaDb.intOf(r['comment_count'], SupaDb.intOf(r['commentCount']));
    m['comment_count'] = m['commentCount'];
    return m;
  }

  /// Normalise one community_comments row. Pure — unit-testable.
  static Map<String, dynamic> normComment(Map<String, dynamic> r) {
    if (r.isEmpty) return {};
    final m = Map<String, dynamic>.from(r);
    m['id'] = SupaDb.strOf(r['id']);
    m['post_id'] = SupaDb.strOf(r['post_id']);
    m['author_uid'] = SupaDb.strOf(r['author_uid']);
    m['body'] = SupaDb.strOf(r['body']);
    m['createdAt'] = SupaDb.parseTs(r['created_at'] ?? r['createdAt']);
    return m;
  }

  /// True when the 073 tables exist (one cheap probe). Gates the
  /// whole Communities UI. Any error reads as not-ready — never a
  /// throw.
  static Future<bool> communitiesBackendReady() async {
    try {
      await _client.from('communities').select('id').limit(1);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Member counts for a set of community ids — from COUNT, never
  /// from loading rows (guide §4.1: thousands of members must not
  /// mean thousands of rows). One exact-count query per id, run in
  /// parallel; a failed count reads as 0 for that id. {} when the
  /// table does not exist yet — never throws.
  static Future<Map<String, int>> _memberCounts(List<String> ids) async {
    final out = <String, int>{};
    if (ids.isEmpty) return out;
    final results = await Future.wait(
        ids.map((id) => SupaDb.countRows('community_members',
            eqCol: 'community_id', eqVal: id)));
    for (var i = 0; i < ids.length; i++) {
      out[ids[i]] = results[i];
    }
    return out;
  }

  /// My membership rows for a set of community ids, in ONE read:
  /// {communityId: role}. {} when logged out / table missing.
  static Future<Map<String, String>> _myMemberships(
      String uid, List<String> ids) async {
    final out = <String, String>{};
    if (uid.isEmpty || ids.isEmpty) return out;
    try {
      final List<Map<String, dynamic>> rows;
      if (SupaDb.hasTestFixtures) {
        // Fixture seam (tests only — testFixtures is null in
        // production): the direct client has no Supabase
        // connection under flutter test, so read memberships
        // through the fixture-aware path instead. Without this,
        // _enrich always reports isMember=false in widget tests.
        rows = await SupaDb.getList('community_members',
            eqCol: 'firebase_uid', eqVal: uid);
      } else {
        rows = (await _client
            .from('community_members')
            .select('community_id, role')
            .eq('firebase_uid', uid)
            .inFilter('community_id', ids) as List)
            .map((r) => Map<String, dynamic>.from(r as Map))
            .toList();
      }
      for (final m in rows) {
        final id = SupaDb.strOf(m['community_id']);
        if (id.isNotEmpty && ids.contains(id)) {
          out[id] = SupaDb.strOf(m['role'], 'member');
        }
      }
    } catch (_) {}
    return out;
  }

  /// Attach member counts + my membership to raw community rows.
  static Future<List<Map<String, dynamic>>> _enrich(
      List<Map<String, dynamic>> rows, String myUid) async {
    final ids = rows.map((r) => SupaDb.strOf(r['id'])).where((i) => i.isNotEmpty).toList();
    final counts = await _memberCounts(ids);
    final mine = await _myMemberships(myUid, ids);
    return rows.map((r) {
      final m = normCommunity(r);
      final id = SupaDb.strOf(m['id']);
      m['memberCount'] = counts[id] ?? 0;
      m['member_count'] = m['memberCount'];
      m['isMember'] = mine.containsKey(id);
      m['is_member'] = m['isMember'];
      m['myRole'] = mine[id] ?? '';
      m['my_role'] = m['myRole'];
      return m;
    }).toList();
  }

  // ------------------------------------------------------------------
  // Communities: list / get / create
  // ------------------------------------------------------------------

  /// Communities, newest first, with member counts + my
  /// membership — PAGINATED (guide §4.1): [offset]/[limit] page
  /// through the list (default 50/page); [search] filters by name
  /// SERVER-side (case-insensitive ilike — never a client filter
  /// over a fetched page, so search works with thousands of
  /// communities). [] when 073 is not applied yet — never throws.
  static Future<List<Map<String, dynamic>>> listCommunities(
      {String myUid = '',
      String search = '',
      int offset = 0,
      int limit = pageSize}) async {
    try {
      final q = search.trim();
      final rows = await SupaDb.getList('communities',
          orderBy: 'created_at',
          ascending: false,
          limit: limit,
          offset: offset,
          ilikeCol: q.isEmpty ? null : 'name',
          ilikeVal: q.isEmpty ? null : q);
      return await _enrich(rows, myUid);
    } catch (_) {
      return [];
    }
  }

  /// Live community list (initial fetch + postgres_changes refetch,
  /// same pattern as SupaDb.streamList). Emits [] when 073 is not
  /// applied yet — never throws. Member counts are attached on each
  /// emission; my-membership needs [myUid].
  static Stream<List<Map<String, dynamic>>> streamCommunities(
      {String myUid = ''}) {
    late final Stream<List<Map<String, dynamic>>> stream;
    try {
      stream = SupaDb.streamList('communities',
              orderBy: 'created_at', ascending: false, limit: 100)
          .asyncMap((rows) => _enrich(rows, myUid));
    } catch (_) {
      return Stream.value(const []);
    }
    return stream;
  }

  /// Communities I created or joined, newest first. [] when logged
  /// out / 073 missing — never throws.
  static Future<List<Map<String, dynamic>>> myCommunities(
      String uid) async {
    if (uid.isEmpty) return [];
    try {
      final memberRows = await _client
          .from('community_members')
          .select('community_id')
          .eq('firebase_uid', uid)
          .order('joined_at', ascending: false);
      final ids = (memberRows as List)
          .map((r) => SupaDb.strOf((r as Map)['community_id']))
          .where((i) => i.isNotEmpty)
          .toList();
      if (ids.isEmpty) return [];
      final rows = await _client
          .from('communities')
          .select()
          .inFilter('id', ids)
          .order('created_at', ascending: false);
      final list = (rows as List)
          .map((r) => Map<String, dynamic>.from(r as Map))
          .toList();
      // Keep joined order (newest join first) — the DB order above
      // is by creation date, so re-sort by the membership order.
      final order = {for (var i = 0; i < ids.length; i++) ids[i]: i};
      list.sort((a, b) => (order[SupaDb.strOf(a['id'])] ?? 0)
          .compareTo(order[SupaDb.strOf(b['id'])] ?? 0));
      return await _enrich(list, uid);
    } catch (e) {
      if (CommunityService.tableMissing(e)) return [];
      return [];
    }
  }

  /// One community by id, with member count + my membership.
  /// {} when not found / 073 missing — never throws.
  static Future<Map<String, dynamic>> getCommunity(String id,
      {String myUid = ''}) async {
    if (id.isEmpty) return {};
    try {
      final row = await SupaDb.getRow('communities', 'id', id);
      if (row.isEmpty) return {};
      return (await _enrich([row], myUid)).first;
    } catch (_) {
      return {};
    }
  }

  /// Create a community. The creator is auto-added as role
  /// 'creator' (second write — if it fails, the community still
  /// exists and the creator can follow it from the detail page;
  /// the result reports 'member_row_failed' so the UI can say so).
  /// Name is validated client-side (1–80 chars, matching the 073
  /// CHECK); photoUrl comes from the ImgBB upload in the UI.
  /// [isPublic] defaults to true (guide §4.2) and is written
  /// explicitly — the 073 column default is also true.
  static Future<Map<String, dynamic>> createCommunity({
    required String creatorUid,
    required String name,
    String description = '',
    String photoUrl = '',
    bool isPublic = true,
  }) async {
    final cleanName = name.trim();
    if (creatorUid.isEmpty) {
      return {'ok': false, 'error': 'Login zaroori hai.'};
    }
    if (cleanName.isEmpty) {
      return {'ok': false, 'error': 'Community ka naam likhen.'};
    }
    if (cleanName.length > 80) {
      return {'ok': false, 'error': 'Naam 80 characters se zyada nahi ho sakta.'};
    }
    if (SupaDb.hasTestFixtures) {
      // Fixture seam (tests only): mirror the live writes in the
      // in-memory fixture lists so widget tests can prove a tap
      // really created the community (same precedent as
      // SupaDb.toggleWatchLiveLike — production path untouched).
      // ignore: invalid_use_of_visible_for_testing_member
      final communities = SupaDb.testFixtures!.putIfAbsent(
          'communities', () => <Map<String, dynamic>>[]);
      final id = 'test-comm-${communities.length + 1}';
      communities.add({
        'id': id,
        'created_by_uid': creatorUid,
        'name': cleanName,
        'description': description.trim(),
        'photo_url': photoUrl.trim(),
        'is_public': isPublic,
      });
      // ignore: invalid_use_of_visible_for_testing_member
      SupaDb.testFixtures!
          .putIfAbsent('community_members', () => <Map<String, dynamic>>[])
          .add({
        'community_id': id,
        'firebase_uid': creatorUid,
        'role': 'creator',
      });
      return {'ok': true, 'id': id};
    }
    try {
      final inserted = await _client.from('communities').insert({
        'created_by_uid': creatorUid,
        'name': cleanName,
        'description': description.trim(),
        'photo_url': photoUrl.trim(),
        'is_public': isPublic,
      }).select('id').limit(1);
      final list = inserted as List;
      if (list.isEmpty) {
        return {'ok': false, 'error': 'Community nahi ban saki — dobara try karen.'};
      }
      final id = SupaDb.strOf((list.first as Map)['id']);
      var memberRowOk = true;
      try {
        await _client.from('community_members').insert({
          'community_id': id,
          'firebase_uid': creatorUid,
          'role': 'creator',
        });
      } catch (_) {
        memberRowOk = false;
      }
      return {
        'ok': true,
        'id': id,
        if (!memberRowOk) 'member_row_failed': true,
      };
    } catch (e) {
      if (CommunityService.tableMissing(e)) {
        return {
          'ok': false,
          'offline': true,
          'error': 'Communities backend abhi online nahi hua (migration 073 pending).'
        };
      }
      return {'ok': false, 'error': e.toString()};
    }
  }

  /// FIX 23 item 15 — update a community's name / description /
  /// photo (the My Community page's Edit form + photo upload).
  /// Only the provided fields are written. The save is verified
  /// by READ-BACK ([getCommunity]): the returned row must match
  /// every written value, else ok:false (the Edit Profile
  /// saveProfilePhotoNow pattern — never fake success). Empty
  /// name is rejected here too (the UI also rejects it first).
  /// Anon UPDATE on `communities` is allowed server-side
  /// (verified by curl probe 2026-11-23: HTTP 204) — no backend
  /// item needed.
  static Future<Map<String, dynamic>> updateCommunity({
    required String id,
    String? name,
    String? description,
    String? photoUrl,
  }) async {
    if (id.isEmpty) {
      return {'ok': false, 'error': 'Community nahi mili.'};
    }
    final patch = <String, dynamic>{};
    if (name != null) {
      final cleanName = name.trim();
      if (cleanName.isEmpty) {
        return {'ok': false, 'error': 'Community ka naam likhen.'};
      }
      if (cleanName.length > 80) {
        return {'ok': false, 'error': 'Naam 80 characters se zyada nahi ho sakta.'};
      }
      patch['name'] = cleanName;
    }
    if (description != null) patch['description'] = description.trim();
    if (photoUrl != null) patch['photo_url'] = photoUrl.trim();
    if (patch.isEmpty) {
      return {'ok': false, 'error': 'Kuch badla nahi.'};
    }
    if (SupaDb.hasTestFixtures) {
      // Fixture seam (tests only): mirror the live update in the
      // in-memory fixture list (same precedent as createCommunity
      // above). Production path untouched.
      // ignore: invalid_use_of_visible_for_testing_member
      final communities = SupaDb.testFixtures!.putIfAbsent(
          'communities', () => <Map<String, dynamic>>[]);
      final idx = communities.indexWhere((c) => c['id'] == id);
      if (idx < 0) {
        return {'ok': false, 'error': 'Community nahi mili.'};
      }
      communities[idx] = {...communities[idx], ...patch};
      return {'ok': true};
    }
    try {
      await _client.from('communities').update(patch).eq('id', id);
      // Read-back verification: the saved row must match every
      // written value, else the save did not really land.
      final saved = await getCommunity(id);
      if (saved.isEmpty) {
        return {'ok': false, 'error': 'Save verify nahi ho saki — dobara try karen.'};
      }
      for (final entry in patch.entries) {
        if (SupaDb.strOf(saved[entry.key]) != entry.value) {
          return {'ok': false, 'error': 'Save poori nahi hui — dobara try karen.'};
        }
      }
      return {'ok': true};
    } catch (e) {
      if (CommunityService.tableMissing(e)) {
        return {
          'ok': false,
          'offline': true,
          'error': 'Communities backend abhi online nahi hua (migration 073 pending).'
        };
      }
      return {'ok': false, 'error': e.toString()};
    }
  }

  /// FIX 12 G13 (2026-11-23, user order: ONE create form) — create
  /// a squad: a plain `teams` row + the creator as captain in
  /// `team_members`. Extracted from the old TeamsPage `_createTeam`
  /// dialog (deleted by the same fix — the unified form replaces
  /// it). `is_clan` is deliberately NEVER written here: the spec
  /// says it is ignored, and no Squad/Clan choice exists anywhere.
  /// The invite-code uniqueness loop is carried over verbatim
  /// (Batch 3B F23). Description/photo have no `teams` columns —
  /// the form keeps a picked photo device-local via
  /// saveTeamPhotoLocal after a successful create.
  static Future<Map<String, dynamic>> createSquad({
    required String creatorUid,
    required String name,
  }) async {
    final cleanName = name.trim();
    if (creatorUid.isEmpty) {
      return {'ok': false, 'error': 'Login zaroori hai.'};
    }
    if (cleanName.isEmpty) {
      return {'ok': false, 'error': 'Squad ka naam likhen.'};
    }
    try {
      final profile = await SupaDb.getProfile(creatorUid);
      final captainName = SupaDb.strOf(profile['displayName'], 'User');
      var code = '';
      for (var attempt = 0; attempt < 8; attempt++) {
        final candidate = SupaDb.generateReferralCode(6);
        final clash = await SupaDb.getList('teams',
            eqCol: 'invite_code', eqVal: candidate, limit: 1);
        if (clash.isEmpty) {
          code = candidate;
          break;
        }
      }
      if (code.isEmpty) {
        return {
          'ok': false,
          'error': 'Invite code ban nahi saka — dobara koshish karein.'
        };
      }
      if (SupaDb.hasTestFixtures) {
        // Fixture seam (tests only) — see createCommunity above.
        // ignore: invalid_use_of_visible_for_testing_member
        final teams = SupaDb.testFixtures!
            .putIfAbsent('teams', () => <Map<String, dynamic>>[]);
        final id = 'test-team-${teams.length + 1}';
        teams.add({
          'id': id,
          'name': cleanName,
          'tag': '',
          'game': '',
          'captain_uid': creatorUid,
          'captain_name': captainName,
          'invite_code': code,
        });
        // ignore: invalid_use_of_visible_for_testing_member
        SupaDb.testFixtures!
            .putIfAbsent('team_members', () => <Map<String, dynamic>>[])
            .add({
          'team_id': id,
          'firebase_uid': creatorUid,
          'user_name': captainName,
          'role': 'captain',
        });
        return {'ok': true, 'id': id, 'inviteCode': code};
      }
      final team = await _client.from('teams').insert({
        'name': cleanName,
        'tag': '',
        'game': '',
        'captain_uid': creatorUid,
        'captain_name': captainName,
        'invite_code': code,
      }).select('id').single();
      final id = SupaDb.strOf((team as Map)['id']);
      await _client.from('team_members').insert({
        'team_id': id,
        'firebase_uid': creatorUid,
        'user_name': captainName,
        'role': 'captain',
      });
      return {'ok': true, 'id': id, 'inviteCode': code};
    } catch (e) {
      if (CommunityService.tableMissing(e)) {
        return {
          'ok': false,
          'offline': true,
          'error': 'Teams backend abhi online nahi hua.'
        };
      }
      final msg = e.toString();
      if (msg.contains('duplicate') ||
          msg.contains('23505') ||
          msg.contains('invite_code')) {
        // F23 race guard (carried over from _createTeam): two
        // creators picked the same code at the same instant.
        return {
          'ok': false,
          'error': 'Invite code takra gaya — dobara koshish karein.'
        };
      }
      return {'ok': false, 'error': msg};
    }
  }

  /// Delete a community. Only the creator may do it (client-side
  /// check — the creator UID is compared here; members/posts/
  /// comments cascade-delete server-side via 073 FKs).
  static Future<Map<String, dynamic>> deleteCommunity({
    required String communityId,
    required String requesterUid,
  }) async {
    if (communityId.isEmpty || requesterUid.isEmpty) {
      return {'ok': false, 'error': 'Community nahi mili.'};
    }
    try {
      final row = await SupaDb.getRow('communities', 'id', communityId);
      if (row.isEmpty) return {'ok': false, 'error': 'Community nahi mili.'};
      if (SupaDb.strOf(row['created_by_uid']) != requesterUid) {
        return {'ok': false, 'error': 'Sirf community banane wala delete kar sakta hai.'};
      }
      await _client.from('communities').delete().eq('id', communityId);
      return {'ok': true};
    } catch (e) {
      if (CommunityService.tableMissing(e)) {
        return {'ok': false, 'offline': true};
      }
      return {'ok': false, 'error': e.toString()};
    }
  }

  /// Delete a community AS ADMIN (guide §4.7): no creator check —
  /// the caller MUST be the designated admin, enforced by the
  /// admin UI via verifyDesignatedAdmin() BEFORE calling this.
  /// Members/posts/comments cascade-delete server-side via 073 FKs.
  /// Same table, same service — no second data path.
  static Future<Map<String, dynamic>> deleteCommunityAsAdmin({
    required String communityId,
  }) async {
    if (communityId.isEmpty) {
      return {'ok': false, 'error': 'Community nahi mili.'};
    }
    try {
      await _client.from('communities').delete().eq('id', communityId);
      return {'ok': true};
    } catch (e) {
      if (CommunityService.tableMissing(e)) {
        return {'ok': false, 'offline': true};
      }
      return {'ok': false, 'error': e.toString()};
    }
  }

  // ------------------------------------------------------------------
  // Voice-access approval — FIX 14 (backend handoff §1, LIVE
  // 2026-11-22). TEAMS have voice by default — no
  // approval, no gating (untouched here). Only PUBLIC communities
  // are gated: voice_enabled=false -> voice UI locked + the
  // creator may file ONE request -> admin approves once ->
  // voice_enabled=true forever. Reject -> creator may re-request.
  //
  //   community_voice_requests: id / community_id / requested_by /
  //   status ('pending' | 'approved' | 'rejected') / created_at /
  //   decided_by / decided_at. Unique partial index: one OPEN
  //   (pending/approved) request per community.
  //
  // Nothing here ever throws; every method reports {'ok': false}
  // (or '' / [] for reads) on failure. Writes have a fixture seam
  // (SupaDb.hasTestFixtures) so tests exercise the real state
  // transitions without a Supabase connection — same pattern as
  // SupaDb.toggleWatchLiveLike.
  // ------------------------------------------------------------------

  /// Is voice unlocked for this (normalised OR raw) community row?
  /// Missing key reads as locked — fail-closed. Pure.
  static bool isVoiceEnabled(Map<String, dynamic> community) =>
      community['voice_enabled'] == true ||
      community['voiceEnabled'] == true;

  /// Is this request status OPEN (blocks a new request)? Only
  /// 'pending' and 'approved' are open — 'rejected' (or anything
  /// else) leaves re-request possible. Pure.
  static bool isOpenVoiceRequestStatus(String status) =>
      status == 'pending' || status == 'approved';

  /// May THIS user file a voice request right now? Only the
  /// community creator, only while voice is still locked, and only
  /// when no open request exists (rejected / none -> allowed).
  /// Pure — the UI gates the button on this; the service method
  /// below re-checks the creator rule server-side. Pure.
  static bool canRequestVoiceAccess({
    required bool isCreator,
    required bool voiceEnabled,
    required String requestStatus,
  }) =>
      isCreator &&
      !voiceEnabled &&
      !isOpenVoiceRequestStatus(requestStatus);

  /// Normalise one community_voice_requests row: both snake_case
  /// and camelCase keys, ms timestamps. Pure — unit-testable.
  static Map<String, dynamic> normVoiceRequest(Map<String, dynamic> r) {
    if (r.isEmpty) return {};
    final m = Map<String, dynamic>.from(r);
    m['id'] = SupaDb.strOf(r['id']);
    m['community_id'] = SupaDb.strOf(r['community_id']);
    m['requested_by'] = SupaDb.strOf(r['requested_by']);
    m['requestedBy'] = m['requested_by'];
    m['status'] = SupaDb.strOf(r['status'], 'pending');
    m['createdAt'] = SupaDb.parseTs(r['created_at'] ?? r['createdAt']);
    m['decided_by'] = SupaDb.strOf(r['decided_by']);
    m['decidedBy'] = m['decided_by'];
    m['decidedAt'] = SupaDb.parseTs(r['decided_at'] ?? r['decidedAt']);
    m['community_name'] =
        SupaDb.strOf(r['community_name'], SupaDb.strOf(r['communityName']));
    m['communityName'] = m['community_name'];
    return m;
  }

  /// The community's OPEN voice request (pending/approved), {} when
  /// none. The unique partial index guarantees at most one.
  static Future<Map<String, dynamic>> _openVoiceRequest(
      String communityId) async {
    try {
      final rows = await SupaDb.getList('community_voice_requests',
          eqCol: 'community_id', eqVal: communityId);
      for (final r in rows) {
        if (isOpenVoiceRequestStatus(SupaDb.strOf(r['status']))) {
          return normVoiceRequest(r);
        }
      }
    } catch (_) {}
    return {};
  }

  /// File a voice-access request for a community. ONLY the creator
  /// may file (checked here against communities.created_by_uid —
  /// the UI also hides the button for non-creators). Idempotent:
  /// when a pending/approved request already exists, the existing
  /// state is returned ({'ok': true, 'already': true, 'status': …})
  /// instead of crashing on the unique index — including the race
  /// where a second request lands between the check and the
  /// insert (23505 / duplicate key -> re-read, return that state).
  /// A rejected request does NOT block a new one.
  static Future<Map<String, dynamic>> requestVoiceAccess({
    required String communityId,
    required String requesterUid,
  }) async {
    if (communityId.isEmpty || requesterUid.isEmpty) {
      return {'ok': false, 'error': 'Login zaroori hai.'};
    }
    try {
      final community =
          await SupaDb.getRow('communities', 'id', communityId);
      if (community.isEmpty) {
        return {'ok': false, 'error': 'Community nahi mili.'};
      }
      if (SupaDb.strOf(community['created_by_uid']) != requesterUid) {
        return {
          'ok': false,
          'error': 'Sirf community banane wala voice request kar sakta hai.'
        };
      }
      if (isVoiceEnabled(community)) {
        return {'ok': true, 'already': true, 'status': 'approved'};
      }
      final existing = await _openVoiceRequest(communityId);
      if (existing.isNotEmpty) {
        return {
          'ok': true,
          'already': true,
          'status': SupaDb.strOf(existing['status']),
          'id': SupaDb.strOf(existing['id']),
        };
      }
      if (SupaDb.hasTestFixtures) {
        // Fixture seam (tests only): same idempotency, in-memory.
        final list = SupaDb.fixtureTable('community_voice_requests')!;
        for (final r in list) {
          if (r['community_id'] == communityId &&
              isOpenVoiceRequestStatus(SupaDb.strOf(r['status']))) {
            return {
              'ok': true,
              'already': true,
              'status': SupaDb.strOf(r['status']),
              'id': SupaDb.strOf(r['id']),
            };
          }
        }
        final id = 'vr-${list.length + 1}';
        list.add({
          'id': id,
          'community_id': communityId,
          'requested_by': requesterUid,
          'status': 'pending',
          'created_at': DateTime.now().toUtc().toIso8601String(),
        });
        return {'ok': true, 'id': id, 'status': 'pending'};
      }
      try {
        final inserted = await _client
            .from('community_voice_requests')
            .insert({
              'community_id': communityId,
              'requested_by': requesterUid,
              'status': 'pending',
            })
            .select('id')
            .limit(1);
        final list = inserted as List;
        if (list.isEmpty) {
          return {
            'ok': false,
            'error': 'Request nahi bheji ja saki — dobara try karen.'
          };
        }
        return {
          'ok': true,
          'id': SupaDb.strOf((list.first as Map)['id']),
          'status': 'pending',
        };
      } catch (e) {
        // Unique-index race: an open request landed after our
        // check — return THAT state, never a crash.
        if (e.toString().contains('duplicate key') ||
            e.toString().contains('23505')) {
          final again = await _openVoiceRequest(communityId);
          if (again.isNotEmpty) {
            return {
              'ok': true,
              'already': true,
              'status': SupaDb.strOf(again['status']),
              'id': SupaDb.strOf(again['id']),
            };
          }
        }
        rethrow;
      }
    } catch (e) {
      if (CommunityService.tableMissing(e)) {
        return {
          'ok': false,
          'offline': true,
          'error': 'Voice requests abhi online nahi hain.'
        };
      }
      return {'ok': false, 'error': e.toString()};
    }
  }

  /// This community's voice-request status: 'pending' | 'approved'
  /// | 'rejected' | '' (no request ever filed). An open request
  /// wins over an older rejected one. '' on any error — never
  /// throws.
  static Future<String> voiceRequestStatus(String communityId) async {
    if (communityId.isEmpty) return '';
    try {
      final rows = await SupaDb.getList('community_voice_requests',
          eqCol: 'community_id',
          eqVal: communityId,
          orderBy: 'created_at',
          ascending: false);
      if (rows.isEmpty) return '';
      for (final r in rows) {
        final s = SupaDb.strOf(r['status']);
        if (isOpenVoiceRequestStatus(s)) return s;
      }
      // No open request — the latest row is the last decision
      // (rejected).
      return SupaDb.strOf(rows.first['status']);
    } catch (_) {
      return '';
    }
  }

  /// Pending voice requests, oldest first, each with its community
  /// name attached ('community_name' / 'communityName'). [] when
  /// none / table missing — never throws. Admin queue only.
  static Future<List<Map<String, dynamic>>> listPendingVoiceRequests(
      {int limit = pageSize}) async {
    try {
      final rows = await SupaDb.getList('community_voice_requests',
          eqCol: 'status',
          eqVal: 'pending',
          orderBy: 'created_at',
          ascending: true,
          limit: limit);
      // One cheap read per request for the name — the queue is
      // small, and names are cached per call for repeat ids.
      final names = <String, String>{};
      final out = <Map<String, dynamic>>[];
      for (final r in rows) {
        final m = normVoiceRequest(r);
        final cid = SupaDb.strOf(m['community_id']);
        if (!names.containsKey(cid)) {
          final c = await SupaDb.getRow('communities', 'id', cid);
          names[cid] = SupaDb.strOf(c['name'], 'Community');
        }
        m['community_name'] = names[cid];
        m['communityName'] = names[cid];
        out.add(m);
      }
      return out;
    } catch (_) {
      return [];
    }
  }

  /// Approve a voice request (ADMIN ONLY — the caller MUST be the
  /// designated admin, enforced by the admin UI via
  /// verifyDesignatedAdmin() BEFORE calling this). TWO writes, per
  /// contract §1: request status='approved' (+ decided_by /
  /// decided_at) AND communities.voice_enabled=true. Idempotent:
  /// approving an already-approved request still sets the flag
  /// (repairs a flag write that failed the first time). A
  /// rejected request cannot be approved — the creator must
  /// re-request (a fresh pending row).
  static Future<Map<String, dynamic>> approveVoiceRequest({
    required String requestId,
    required String adminUid,
  }) async {
    if (requestId.isEmpty || adminUid.isEmpty) {
      return {'ok': false, 'error': 'Request nahi mili.'};
    }
    try {
      final row =
          await SupaDb.getRow('community_voice_requests', 'id', requestId);
      if (row.isEmpty) {
        return {'ok': false, 'error': 'Request nahi mili.'};
      }
      if (SupaDb.strOf(row['status']) == 'rejected') {
        return {
          'ok': false,
          'error':
              'Ye request pehle reject ho chuki hai — creator dobara request kare to nayi request aayegi.'
        };
      }
      final communityId = SupaDb.strOf(row['community_id']);
      final now = DateTime.now().toUtc().toIso8601String();
      if (SupaDb.hasTestFixtures) {
        // Fixture seam (tests only): mutate both fixture lists
        // exactly like the live writes would.
        final list =
            SupaDb.fixtureTable('community_voice_requests') ?? [];
        for (final r in list) {
          if (r['id'] == requestId) {
            r['status'] = 'approved';
            r['decided_by'] = adminUid;
            r['decided_at'] = now;
          }
        }
        final communities = SupaDb.fixtureTable('communities') ?? [];
        for (final c in communities) {
          if (c['id'] == communityId) c['voice_enabled'] = true;
        }
        return {'ok': true, 'community_id': communityId};
      }
      await _client.from('community_voice_requests').update({
        'status': 'approved',
        'decided_by': adminUid,
        'decided_at': now,
      }).eq('id', requestId);
      // Second write — the actual unlock. Without it the request
      // would read approved while voice stays locked.
      if (communityId.isNotEmpty) {
        await _client
            .from('communities')
            .update({'voice_enabled': true})
            .eq('id', communityId);
      }
      return {'ok': true, 'community_id': communityId};
    } catch (e) {
      if (CommunityService.tableMissing(e)) {
        return {'ok': false, 'offline': true};
      }
      return {'ok': false, 'error': e.toString()};
    }
  }

  /// Reject a voice request (ADMIN ONLY — same gating as
  /// [approveVoiceRequest]). Sets status='rejected' (+ decided_by
  /// / decided_at); communities.voice_enabled is NOT touched (it
  /// stays false) and the creator may re-request. Rejecting an
  /// already-approved request is refused — voice is already
  /// unlocked for that community.
  static Future<Map<String, dynamic>> rejectVoiceRequest({
    required String requestId,
    required String adminUid,
  }) async {
    if (requestId.isEmpty || adminUid.isEmpty) {
      return {'ok': false, 'error': 'Request nahi mili.'};
    }
    try {
      final row =
          await SupaDb.getRow('community_voice_requests', 'id', requestId);
      if (row.isEmpty) {
        return {'ok': false, 'error': 'Request nahi mili.'};
      }
      if (SupaDb.strOf(row['status']) == 'approved') {
        return {
          'ok': false,
          'error': 'Ye request pehle approve ho chuki hai — voice unlock hai.'
        };
      }
      if (SupaDb.strOf(row['status']) == 'rejected') {
        return {'ok': true, 'already': true, 'status': 'rejected'};
      }
      final now = DateTime.now().toUtc().toIso8601String();
      if (SupaDb.hasTestFixtures) {
        // Fixture seam (tests only).
        final list =
            SupaDb.fixtureTable('community_voice_requests') ?? [];
        for (final r in list) {
          if (r['id'] == requestId) {
            r['status'] = 'rejected';
            r['decided_by'] = adminUid;
            r['decided_at'] = now;
          }
        }
        return {'ok': true, 'status': 'rejected'};
      }
      await _client.from('community_voice_requests').update({
        'status': 'rejected',
        'decided_by': adminUid,
        'decided_at': now,
      }).eq('id', requestId);
      return {'ok': true, 'status': 'rejected'};
    } catch (e) {
      if (CommunityService.tableMissing(e)) {
        return {'ok': false, 'offline': true};
      }
      return {'ok': false, 'error': e.toString()};
    }
  }

  // ------------------------------------------------------------------
  // Follow / unfollow (= join / leave) + members
  // ------------------------------------------------------------------

  /// Am I a member of [communityId]? False on any error.
  static Future<bool> isMember(String uid, String communityId) async {
    if (uid.isEmpty || communityId.isEmpty) return false;
    try {
      // FIX 15: via SupaDb.getList (same query as before) so the
      // test-fixture seam applies — live behaviour unchanged.
      final rows = await SupaDb.getList('community_members',
          eqCol: 'community_id',
          eqVal: communityId,
          eqCol2: 'firebase_uid',
          eqVal2: uid,
          limit: 1);
      return rows.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// My role in a community: 'creator' | 'admin' | 'member' | ''.
  static Future<String> myRole(String uid, String communityId) async {
    if (uid.isEmpty || communityId.isEmpty) return '';
    try {
      // FIX 15: via SupaDb.getList (same query as before) so the
      // test-fixture seam applies — live behaviour unchanged.
      final rows = await SupaDb.getList('community_members',
          eqCol: 'community_id',
          eqVal: communityId,
          eqCol2: 'firebase_uid',
          eqVal2: uid,
          limit: 1);
      if (rows.isEmpty) return '';
      return SupaDb.strOf(rows.first['role']);
    } catch (_) {
      return '';
    }
  }

  /// Follow (join) a community. A duplicate follow is a success
  /// (idempotent — the unique pair index rejects the second insert).
  static Future<Map<String, dynamic>> followCommunity(
      String uid, String communityId) async {
    if (uid.isEmpty || communityId.isEmpty) {
      return {'ok': false, 'error': 'Login zaroori hai.'};
    }
    try {
      await _client.from('community_members').insert({
        'community_id': communityId,
        'firebase_uid': uid,
        'role': 'member',
      });
      return {'ok': true};
    } catch (e) {
      if (CommunityService.tableMissing(e)) {
        return {'ok': false, 'offline': true};
      }
      if (e.toString().contains('duplicate key')) return {'ok': true};
      return {'ok': false, 'error': e.toString()};
    }
  }

  /// Respond to a COMMUNITY invitation (PHASE E E30, 2026-11-24).
  ///
  /// The invite IS the user_notifications row (type=
  /// 'community_invite' — there is no community_invitations
  /// table). Join ('accepted') follows the community via
  /// [followCommunity] (a real membership row — never a forced
  /// add: the recipient tapped Join themself) and then deletes
  /// the notification row; Decline ('declined') just deletes
  /// the row. Returns {'ok': true} on success.
  static Future<Map<String, dynamic>> respondCommunityInvite({
    required String notificationId,
    required String communityId,
    required String response,
    required String uid,
  }) async {
    if (notificationId.isEmpty || communityId.isEmpty || uid.isEmpty) {
      return {'ok': false, 'error': 'Invitation ki maloomat missing hai.'};
    }
    // TEST SEAM (FIX 6 pattern): with fixtures, write the same
    // membership row + remove the notification from the fixture
    // lists so tests can run the full send -> inbox -> Join
    // chain with no network.
    // ignore: invalid_use_of_visible_for_testing_member
    if (SupaDb.testFixtures != null) {
      if (response == 'accepted') {
        // ignore: invalid_use_of_visible_for_testing_member
        final members = SupaDb.testFixtures!['community_members'] ?? [];
        final already = members.any((r) =>
            SupaDb.strOf(r['community_id']) == communityId &&
            SupaDb.strOf(r['firebase_uid']) == uid);
        if (!already) {
          // ignore: invalid_use_of_visible_for_testing_member
          (SupaDb.testFixtures!['community_members'] ??= []).add({
            'community_id': communityId,
            'firebase_uid': uid,
            'role': 'member',
          });
        }
      }
      // ignore: invalid_use_of_visible_for_testing_member
      SupaDb.testFixtures!['user_notifications']?.removeWhere(
          (r) => SupaDb.strOf(r['id']) == notificationId);
      return {'ok': true};
    }
    try {
      if (response == 'accepted') {
        final res = await followCommunity(uid, communityId);
        if (res['ok'] != true) return res;
      }
      // Best-effort delete: the card leaves the list on the next
      // load either way (the row is gone from the inbox query
      // once deleted; a failed delete keeps it visible, honestly).
      try {
        await CommunityService.deleteNotification(id: notificationId, uid: uid);
      } catch (_) {}
      return {'ok': true};
    } catch (e) {
      return {'ok': false, 'error': e.toString()};
    }
  }

  /// Unfollow (leave) a community. The creator cannot leave their
  /// own community (they must delete it instead) — enforced here
  /// so the community never ends up creator-less.
  static Future<Map<String, dynamic>> unfollowCommunity(
      String uid, String communityId) async {
    if (uid.isEmpty || communityId.isEmpty) {
      return {'ok': false, 'error': 'Login zaroori hai.'};
    }
    try {
      final role = await myRole(uid, communityId);
      if (role == 'creator') {
        return {
          'ok': false,
          'error': 'Creator community leave nahi kar sakta — delete karen ya pehle kisi aur ko creator banayen.'
        };
      }
      await _client
          .from('community_members')
          .delete()
          .eq('community_id', communityId)
          .eq('firebase_uid', uid);
      return {'ok': true};
    } catch (e) {
      if (CommunityService.tableMissing(e)) {
        return {'ok': false, 'offline': true};
      }
      return {'ok': false, 'error': e.toString()};
    }
  }

  /// Member count for one community — from COUNT, never from
  /// loading rows (guide §4.1). 0 when the table is missing.
  static Future<int> memberCount(String communityId) async {
    if (communityId.isEmpty) return 0;
    return SupaDb.countRows('community_members',
        eqCol: 'community_id', eqVal: communityId);
  }

  /// Display name of a community's creator (FIX 12 G4 — the About
  /// sheet). Spec route: community_members role 'creator' identifies
  /// WHO the creator is; the name comes from profiles (one
  /// [SupaDb.getProfile] row — NOT the whole member list). Falls
  /// back to [createdByUid] (communities.created_by_uid, the source
  /// of truth) when the role row is missing (repaired membership).
  /// '' when nothing resolves — the sheet shows 'Unknown' instead
  /// of a fake name. Never throws.
  static Future<String> creatorDisplayName(String communityId,
      {String createdByUid = ''}) async {
    if (communityId.isEmpty && createdByUid.isEmpty) return '';
    var creatorUid = '';
    try {
      final ms = await members(communityId, limit: pageSize);
      for (final m in ms) {
        if (SupaDb.strOf(m['role']) == 'creator') {
          creatorUid = SupaDb.strOf(m['firebase_uid']);
          break;
        }
      }
    } catch (_) {}
    if (creatorUid.isEmpty) creatorUid = createdByUid;
    if (creatorUid.isEmpty) return '';
    try {
      final p = await SupaDb.getProfile(creatorUid);
      return SupaDb.strOf(p['display_name']);
    } catch (_) {
      return '';
    }
  }

  /// Promote / demote a member (guide §4.3): ONLY the community
  /// creator may do it (checked here — the UI also hides the
  /// action for non-creators). [toRole] must be 'admin' or
  /// 'member'; the creator can never be demoted and nobody can be
  /// promoted TO creator (there is exactly one creator, set at
  /// creation). The target must already be a member.
  static Future<Map<String, dynamic>> promoteMember({
    required String communityId,
    required String requesterUid,
    required String targetUid,
    required String toRole,
  }) async {
    if (communityId.isEmpty || requesterUid.isEmpty || targetUid.isEmpty) {
      return {'ok': false, 'error': 'Member nahi mila.'};
    }
    if (toRole != 'admin' && toRole != 'member') {
      return {'ok': false, 'error': 'Ghalat role.'};
    }
    if (requesterUid == targetUid) {
      return {'ok': false, 'error': 'Apna role khud nahi badal sakte.'};
    }
    try {
      if (await myRole(requesterUid, communityId) != 'creator') {
        return {
          'ok': false,
          'error': 'Sirf community creator admin bana sakta hai.'
        };
      }
      final targetRole = await myRole(targetUid, communityId);
      if (targetRole.isEmpty) {
        return {'ok': false, 'error': 'Ye player community ka member nahi hai.'};
      }
      if (targetRole == 'creator') {
        return {'ok': false, 'error': 'Creator ka role nahi badal sakta.'};
      }
      if (targetRole == toRole) return {'ok': true};
      await _client
          .from('community_members')
          .update({'role': toRole})
          .eq('community_id', communityId)
          .eq('firebase_uid', targetUid);
      return {'ok': true};
    } catch (e) {
      if (CommunityService.tableMissing(e)) {
        return {'ok': false, 'offline': true};
      }
      return {'ok': false, 'error': e.toString()};
    }
  }

  // ----------------------------------------------------------------
  // FIX 15 (v2016) — COMMUNITY ORGANIZER MODERATION (backend
  // guide §9). Once the app admin approves voice for a public
  // community (§1: communities.voice_enabled), the community
  // ORGANIZER (creator) gets admin-like powers INSIDE THAT
  // COMMUNITY ONLY: mute (LiveKit data packet — see
  // LiveKitVoiceService), ban/block/kick (community-scoped
  // chat_restrictions row) and chat-history delete. Global/device
  // bans stay app-admin only. Every action below re-checks the
  // scope against live data (creator + voice flag) — the UI only
  // hides buttons; it never grants the power.
  // ----------------------------------------------------------------

  /// Pure: is [uid] the organizer of a community whose creator is
  /// [createdByUid] and in which [uid]'s member role is [role]?
  /// Either signal counts (created_by_uid is the source of truth;
  /// the 'creator' role row is the same fact from membership).
  static bool isOrganizerOf({
    required String uid,
    required String createdByUid,
    required String role,
  }) {
    if (uid.isEmpty) return false;
    return uid == createdByUid || role == 'creator';
  }

  /// Pure: may this user moderate this community? Organizer AND
  /// voice-approved — both are required. An organizer of community
  /// A is never the organizer of community B, so this can never
  /// grant cross-community power.
  static bool canOrganizerModerate({
    required bool isOrganizer,
    required bool voiceApproved,
  }) =>
      isOrganizer && voiceApproved;

  /// Is voice approved for this community (§1 flag)? Fail-closed:
  /// a missing row/column reads as false, so organizer powers stay
  /// off until the approval lands.
  static Future<bool> isCommunityVoiceApproved(String communityId) async {
    if (communityId.isEmpty) return false;
    try {
      final row = await SupaDb.getRow('communities', 'id', communityId);
      return row['voice_enabled'] == true || row['voiceEnabled'] == true;
    } catch (_) {
      return false;
    }
  }

  /// Is [uid] the organizer of [communityId]? Checks the community
  /// row's created_by_uid first, then the member role.
  static Future<bool> isOrganizer(String uid, String communityId) async {
    if (uid.isEmpty || communityId.isEmpty) return false;
    try {
      final row = await SupaDb.getRow('communities', 'id', communityId);
      final createdBy = SupaDb.strOf(row['created_by_uid']);
      if (createdBy.isNotEmpty && createdBy == uid) return true;
      return await myRole(uid, communityId) == 'creator';
    } catch (_) {
      return false;
    }
  }

  /// UIDs currently restricted inside this community (scoped rows
  /// only — global rows are the app admin's, not the organizer's).
  /// One cheap query; the members tab uses it for Block/Unblock.
  static Future<Set<String>> restrictedMemberUids(
      String communityId) async {
    if (communityId.isEmpty) return <String>{};
    try {
      final rows = await SupaDb.getList('chat_restrictions',
          eqCol: 'community_id', eqVal: communityId, limit: 200);
      return rows
          .map((r) => SupaDb.strOf(r['firebase_uid']))
          .where((u) => u.isNotEmpty)
          .toSet();
    } catch (_) {
      return <String>{};
    }
  }

  /// Shared gate for organizer moderation actions: the requester
  /// must be the community's organizer AND voice must be approved
  /// for it — OR the requester must be the designated app admin
  /// (who can do anything an organizer can, in any community).
  /// Returns an error string when the gate fails, '' when it passes.
  static Future<String> organizerGate(
      String communityId, String requesterUid) async {
    if (communityId.isEmpty || requesterUid.isEmpty) {
      return 'Community nahi mili.';
    }
    try {
      final adminUid = await SupaDb.designatedAdminUid();
      if (adminUid.isNotEmpty && adminUid == requesterUid) return '';
    } catch (_) {}
    if (!await isOrganizer(requesterUid, communityId)) {
      return 'Sirf community organizer ye kar sakta hai.';
    }
    if (!await isCommunityVoiceApproved(communityId)) {
      return 'Voice abhi is community mein approve nahi hui — organizer powers tab khulenge jab admin voice approve karega.';
    }
    return '';
  }

  /// Ban/block/kick a member INSIDE this community only (fix 15):
  /// inserts a community-scoped chat_restrictions row
  /// (community_id set — guide §9.1). The target cannot chat in
  /// THIS community; other communities are unaffected. The
  /// organizer can never restrict the creator or themselves.
  /// Idempotent: an already restricted member returns ok.
  static Future<Map<String, dynamic>> restrictMemberInCommunity({
    required String communityId,
    required String requesterUid,
    required String targetUid,
    String reason = 'organizer_block',
  }) async {
    if (communityId.isEmpty || requesterUid.isEmpty || targetUid.isEmpty) {
      return {'ok': false, 'error': 'Member nahi mila.'};
    }
    if (requesterUid == targetUid) {
      return {'ok': false, 'error': 'Apne aap ko block nahi kar sakte.'};
    }
    final gate = await organizerGate(communityId, requesterUid);
    if (gate.isNotEmpty) return {'ok': false, 'error': gate};
    try {
      final targetRole = await myRole(targetUid, communityId);
      if (targetRole.isEmpty) {
        return {
          'ok': false,
          'error': 'Ye player community ka member nahi hai.'
        };
      }
      if (targetRole == 'creator') {
        return {'ok': false, 'error': 'Creator ko block nahi kar sakte.'};
      }
      if (await SupaDb.isChatRestrictedInCommunity(targetUid, communityId)) {
        return {'ok': true, 'already': true};
      }
      final cleanReason =
          reason.trim().isEmpty ? 'organizer_block' : reason.trim();
      await SupaDb.insertChatRestriction(
          uid: targetUid, reason: cleanReason, communityId: communityId);
      // Verify the row really landed (an RLS-denied insert returns
      // no error — same F23 lesson as unrestrictChatUser).
      if (!await SupaDb.isChatRestrictedInCommunity(targetUid, communityId)) {
        return {
          'ok': false,
          'error':
              'Block nahi hua — restriction save nahi ho saki (shayad permission issue hai).'
        };
      }
      return {'ok': true};
    } catch (e) {
      if (_missingColumn(e)) {
        return {
          'ok': false,
          'error':
              'Community block abhi available nahi — backend update pending hai (chat_restrictions.community_id).'
        };
      }
      if (CommunityService.tableMissing(e)) {
        return {'ok': false, 'offline': true};
      }
      return {'ok': false, 'error': e.toString()};
    }
  }

  /// Undo a community-scoped block: deletes ONLY the scoped row
  /// for this community. A global admin row for the same user is
  /// untouched — the organizer cannot lift an admin's block.
  static Future<Map<String, dynamic>> unrestrictMemberInCommunity({
    required String communityId,
    required String requesterUid,
    required String targetUid,
  }) async {
    if (communityId.isEmpty || requesterUid.isEmpty || targetUid.isEmpty) {
      return {'ok': false, 'error': 'Member nahi mila.'};
    }
    final gate = await organizerGate(communityId, requesterUid);
    if (gate.isNotEmpty) return {'ok': false, 'error': gate};
    try {
      await SupaDb.deleteScopedChatRestriction(
          uid: targetUid, communityId: communityId);
      // Verify (F23): a denied delete returns no error.
      final remaining = await SupaDb.getList('chat_restrictions',
          eqCol: 'firebase_uid',
          eqVal: targetUid,
          eqCol2: 'community_id',
          eqVal2: communityId,
          limit: 1);
      if (remaining.isNotEmpty) {
        return {
          'ok': false,
          'error':
              'Unblock nahi hua — restriction abhi bhi maujood hai (shayad permission issue hai).'
        };
      }
      return {'ok': true};
    } catch (e) {
      if (CommunityService.tableMissing(e)) {
        return {'ok': false, 'offline': true};
      }
      return {'ok': false, 'error': e.toString()};
    }
  }

  /// Delete this community's whole chat history (fix 15): the same
  /// delete-by-ids path as the room's _clearChat, scoped to
  /// scope='community' + this community_id. Organizer (voice
  /// approved) or app admin only. Fetches in 500-row pages (offset
  /// 0 each time — the next page is whatever remains) so a huge
  /// history never loads at once; capped at 20 pages (10,000
  /// messages) so a silently failing delete cannot loop forever.
  /// FIX 20: after clear the chat is EMPTY — no marker message
  /// is posted (the old clear-marker stuck in the chat like a
  /// real message, so it is gone entirely).
  static Future<Map<String, dynamic>> clearCommunityChat({
    required String communityId,
    required String requesterUid,
    required String requesterName,
  }) async {
    if (communityId.isEmpty || requesterUid.isEmpty) {
      return {'ok': false, 'error': 'Community nahi mili.'};
    }
    final gate = await organizerGate(communityId, requesterUid);
    if (gate.isNotEmpty) return {'ok': false, 'error': gate};
    try {
      var deleted = 0;
      for (var page = 0; page < 20; page++) {
        final rows = await SupaDb.getList('chat_messages',
            eqCol: 'scope',
            eqVal: 'community',
            eqCol2: 'community_id',
            eqVal2: communityId,
            limit: 500);
        final ids = rows
            .map((r) => SupaDb.strOf(r['id']))
            .where((id) => id.isNotEmpty)
            .toList();
        if (ids.isEmpty) break;
        await SupaDb.deleteChatMessagesByIds(ids);
        deleted += ids.length;
        if (rows.length < 500) break;
      }
      // FIX 20: NO marker message after clear — the chat stays
      // empty (the UI toast already confirms the clear).
      return {'ok': true, 'deleted': deleted};
    } catch (e) {
      if (CommunityService.tableMissing(e)) {
        return {'ok': false, 'offline': true};
      }
      return {'ok': false, 'error': e.toString()};
    }
  }

  /// Member UIDs only (one cheap column query, bounded by [limit])
  /// — for the detail header's online count, which needs UIDs for
  /// the presence lookup but must never load full member rows.
  /// Newest joins first. [] when 073 is missing — never throws.
  static Future<List<String>> memberUids(String communityId,
      {int limit = 1000}) async {
    if (communityId.isEmpty) return [];
    try {
      final rows = await SupaDb.getList('community_members',
          eqCol: 'community_id',
          eqVal: communityId,
          orderBy: 'joined_at',
          ascending: false,
          limit: limit);
      return rows
          .map((r) => SupaDb.strOf(r['firebase_uid']))
          .where((u) => u.isNotEmpty)
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// Members of a community (public profiles, creator first).
  /// PAGINATED (guide §4.1/§4.6): [offset]/[limit] page through
  /// the roster (default 50/page) — the whole member list is never
  /// fetched at once. Ordered by join time, OLDEST first, so the
  /// creator (who joined first) is always the first row of page 0
  /// and page boundaries stay stable as new members join.
  /// Each entry carries 'role' + 'joined_at' next to the public
  /// profile fields. [] when 073 is missing — never throws.
  static Future<List<Map<String, dynamic>>> members(
      String communityId, {int offset = 0, int limit = pageSize}) async {
    if (communityId.isEmpty) return [];
    try {
      final rows = await SupaDb.getList('community_members',
          eqCol: 'community_id',
          eqVal: communityId,
          orderBy: 'joined_at',
          ascending: true,
          limit: limit,
          offset: offset);
      final list = rows.map((r) => Map<String, dynamic>.from(r)).toList();
      final profiles = await CommunityService.publicProfiles(
          list.map((r) => SupaDb.strOf(r['firebase_uid'])).toList());
      final byUid = {
        for (final p in profiles) SupaDb.strOf(p['firebase_uid']): p
      };
      final out = <Map<String, dynamic>>[];
      for (final r in list) {
        final uid = SupaDb.strOf(r['firebase_uid']);
        final p = Map<String, dynamic>.from(byUid[uid] ?? {});
        if (p.isEmpty) {
          p['firebase_uid'] = uid;
          p['display_name'] = 'Player';
          p['displayName'] = 'Player';
        }
        p['role'] = SupaDb.strOf(r['role'], 'member');
        p['joined_at'] = SupaDb.parseTs(r['joined_at']);
        out.add(p);
      }
      // Creator first (defensive — join order already puts the
      // creator first, but a repaired membership row could reorder).
      out.sort((a, b) {
        final ra = SupaDb.strOf(a['role']) == 'creator' ? 0 : 1;
        final rb = SupaDb.strOf(b['role']) == 'creator' ? 0 : 1;
        if (ra != rb) return ra.compareTo(rb);
        return SupaDb.intOf(a['joined_at']).compareTo(SupaDb.intOf(b['joined_at']));
      });
      return out;
    } catch (_) {
      return [];
    }
  }

  /// Roles for a set of UIDs in one community — ONE query
  /// (community_members inFilter). The chat tab uses this to show
  /// ORGANIZER pills for the senders actually on screen, instead
  /// of loading the whole member list. {} on any error.
  static Future<Map<String, String>> memberRoles(
      String communityId, List<String> uids) async {
    final out = <String, String>{};
    final ids = uids.where((u) => u.isNotEmpty).toSet().toList();
    if (communityId.isEmpty || ids.isEmpty) return out;
    try {
      final rows = await _client
          .from('community_members')
          .select('firebase_uid, role')
          .eq('community_id', communityId)
          .inFilter('firebase_uid', ids);
      for (final r in (rows as List)) {
        final m = Map<String, dynamic>.from(r as Map);
        final uid = SupaDb.strOf(m['firebase_uid']);
        if (uid.isNotEmpty) out[uid] = SupaDb.strOf(m['role'], 'member');
      }
    } catch (_) {}
    return out;
  }

  /// Search WITHIN a community's members (guide §4.6): matches
  /// username or display name, SERVER-side (case-insensitive
  /// ilike on profiles), then keeps only the UIDs that are members
  /// of this community. [] when nothing matches / 073 missing.
  static Future<List<Map<String, dynamic>>> searchMembers(
      String communityId, String query, {int limit = pageSize}) async {
    final q = query.trim();
    if (communityId.isEmpty || q.isEmpty) return [];
    try {
      final byUsername = await SupaDb.getList('profiles',
          ilikeCol: 'username', ilikeVal: q, limit: limit);
      final byName = await SupaDb.getList('profiles',
          ilikeCol: 'display_name', ilikeVal: q, limit: limit);
      final uids = <String>{};
      for (final r in [...byUsername, ...byName]) {
        final u = SupaDb.strOf(r['firebase_uid']);
        if (u.isNotEmpty) uids.add(u);
      }
      if (uids.isEmpty) return [];
      final memberRows = await _client
          .from('community_members')
          .select('firebase_uid, role, joined_at')
          .eq('community_id', communityId)
          .inFilter('firebase_uid', uids.toList());
      final roles = <String, Map<String, dynamic>>{};
      for (final r in (memberRows as List)) {
        final m = Map<String, dynamic>.from(r as Map);
        roles[SupaDb.strOf(m['firebase_uid'])] = m;
      }
      final profiles = await CommunityService.publicProfiles(
          roles.keys.toList());
      final out = <Map<String, dynamic>>[];
      for (final p in profiles) {
        final uid = SupaDb.strOf(p['firebase_uid']);
        final m = Map<String, dynamic>.from(p);
        m['role'] = SupaDb.strOf(roles[uid]?['role'], 'member');
        m['joined_at'] = SupaDb.parseTs(roles[uid]?['joined_at']);
        out.add(m);
      }
      out.sort((a, b) {
        final ra = SupaDb.strOf(a['role']) == 'creator' ? 0 : 1;
        final rb = SupaDb.strOf(b['role']) == 'creator' ? 0 : 1;
        return ra.compareTo(rb);
      });
      return out;
    } catch (_) {
      return [];
    }
  }

  // ------------------------------------------------------------------
  // Posts + comments (inside a community)
  // ------------------------------------------------------------------

  /// Posts of a community, newest first, each with its author's
  /// public profile under 'author' and a comment count.
  /// PAGINATED (guide §4.1): [offset]/[limit] page through posts
  /// (default 50/page). Comment counts come from COUNT, never from
  /// loading comment rows. [] when 073 is missing — never throws.
  static Future<List<Map<String, dynamic>>> listPosts(
      String communityId, {int offset = 0, int limit = pageSize}) async {
    if (communityId.isEmpty) return [];
    try {
      final rows = await SupaDb.getList('community_posts',
          eqCol: 'community_id',
          eqVal: communityId,
          orderBy: 'created_at',
          ascending: false,
          limit: limit,
          offset: offset);
      final posts = rows.map(normPost).toList();
      if (posts.isEmpty) return posts;
      final authors = await CommunityService.publicProfiles(
          posts.map((p) => SupaDb.strOf(p['author_uid'])).toList());
      final byUid = {
        for (final a in authors) SupaDb.strOf(a['firebase_uid']): a
      };
      final ids = posts.map((p) => SupaDb.strOf(p['id'])).toList();
      final countsList = await Future.wait(ids.map((id) =>
          SupaDb.countRows('community_comments',
              eqCol: 'post_id', eqVal: id)));
      final counts = <String, int>{
        for (var i = 0; i < ids.length; i++) ids[i]: countsList[i]
      };
      for (final p in posts) {
        final uid = SupaDb.strOf(p['author_uid']);
        p['author'] = byUid[uid] ?? {'firebase_uid': uid, 'display_name': 'Player', 'displayName': 'Player'};
        p['commentCount'] = counts[SupaDb.strOf(p['id'])] ?? 0;
        p['comment_count'] = p['commentCount'];
      }
      return posts;
    } catch (_) {
      return [];
    }
  }

  /// Live posts stream for a community (initial fetch +
  /// postgres_changes refetch). Emits [] when 073 is missing.
  static Stream<List<Map<String, dynamic>>> streamPosts(
      String communityId) {
    if (communityId.isEmpty) return Stream.value(const []);
    late final Stream<List<Map<String, dynamic>>> stream;
    try {
      stream = SupaDb.streamList('community_posts',
              eqCol: 'community_id',
              eqVal: communityId,
              orderBy: 'created_at',
              ascending: false,
              limit: 100)
          .asyncMap((rows) async {
        final posts = rows.map(normPost).toList();
        if (posts.isEmpty) return posts;
        final authors = await CommunityService.publicProfiles(
            posts.map((p) => SupaDb.strOf(p['author_uid'])).toList());
        final byUid = {
          for (final a in authors) SupaDb.strOf(a['firebase_uid']): a
        };
        for (final p in posts) {
          final uid = SupaDb.strOf(p['author_uid']);
          p['author'] = byUid[uid] ?? {'firebase_uid': uid, 'display_name': 'Player', 'displayName': 'Player'};
        }
        return posts;
      });
    } catch (_) {
      return Stream.value(const []);
    }
    return stream;
  }

  /// Create a post. Only MEMBERS may post (follow first) — the
  /// check is client-side; the UI hides the composer for
  /// non-members too. imageUrl comes from the ImgBB upload in the
  /// UI. On success, members are notified best-effort (a failed
  /// notification never fails the post).
  static Future<Map<String, dynamic>> createPost({
    required String communityId,
    required String authorUid,
    required String body,
    String imageUrl = '',
  }) async {
    final text = body.trim();
    if (communityId.isEmpty || authorUid.isEmpty) {
      return {'ok': false, 'error': 'Login zaroori hai.'};
    }
    if (text.isEmpty) {
      return {'ok': false, 'error': 'Post khaali hai — kuch likhen.'};
    }
    if (text.length > 2000) {
      return {'ok': false, 'error': 'Post 2000 characters se zyada nahi ho sakti.'};
    }
    try {
      if (!await isMember(authorUid, communityId)) {
        return {
          'ok': false,
          'error': 'Post karne ke liye pehle community follow karen.'
        };
      }
      final inserted = await _client.from('community_posts').insert({
        'community_id': communityId,
        'author_uid': authorUid,
        'body': text,
        'image_url': imageUrl.trim(),
      }).select('id').limit(1);
      final id = (inserted as List).isEmpty
          ? ''
          : SupaDb.strOf(((inserted as List).first as Map)['id']);
      // Best-effort: tell the creator a member posted.
      try {
        final c = await SupaDb.getRow('communities', 'id', communityId);
        final creator = SupaDb.strOf(c['created_by_uid']);
        if (creator.isNotEmpty && creator != authorUid) {
          await SupaDb.notifyUser(creator, 'Community Post',
              '"${SupaDb.strOf(c['name'], 'Aapki community')}" mein aik nayi post aayi hai.');
        }
      } catch (_) {}
      return {'ok': true, 'id': id};
    } catch (e) {
      if (CommunityService.tableMissing(e)) {
        return {'ok': false, 'offline': true};
      }
      return {'ok': false, 'error': e.toString()};
    }
  }

  /// Delete a post. Only the author or the community creator may
  /// do it (client-side check). Comments cascade-delete via 073.
  static Future<Map<String, dynamic>> deletePost({
    required String postId,
    required String requesterUid,
  }) async {
    if (postId.isEmpty || requesterUid.isEmpty) {
      return {'ok': false, 'error': 'Post nahi mili.'};
    }
    try {
      final row = await SupaDb.getRow('community_posts', 'id', postId);
      if (row.isEmpty) return {'ok': false, 'error': 'Post nahi mili.'};
      final isAuthor = SupaDb.strOf(row['author_uid']) == requesterUid;
      var isCreator = false;
      if (!isAuthor) {
        final c = await SupaDb.getRow(
            'communities', 'id', SupaDb.strOf(row['community_id']));
        isCreator = SupaDb.strOf(c['created_by_uid']) == requesterUid;
      }
      if (!isAuthor && !isCreator) {
        return {'ok': false, 'error': 'Sirf post karne wala ya community creator delete kar sakta hai.'};
      }
      await _client.from('community_posts').delete().eq('id', postId);
      return {'ok': true};
    } catch (e) {
      if (CommunityService.tableMissing(e)) {
        return {'ok': false, 'offline': true};
      }
      return {'ok': false, 'error': e.toString()};
    }
  }

  /// Delete a post AS ADMIN (guide §4.7): no author/creator
  /// check — the caller MUST be the designated admin, enforced by
  /// the admin UI via verifyDesignatedAdmin() BEFORE calling this.
  /// Same table, same service — no second data path.
  static Future<Map<String, dynamic>> deletePostAsAdmin({
    required String postId,
  }) async {
    if (postId.isEmpty) {
      return {'ok': false, 'error': 'Post nahi mili.'};
    }
    try {
      await _client.from('community_posts').delete().eq('id', postId);
      return {'ok': true};
    } catch (e) {
      if (CommunityService.tableMissing(e)) {
        return {'ok': false, 'offline': true};
      }
      return {'ok': false, 'error': e.toString()};
    }
  }

  /// Comments of one post, oldest first, each with its author's
  /// public profile under 'author'. PAGINATED ([offset]/[limit],
  /// default 50/page) so a long thread never loads whole.
  /// [] when 073 is missing — never throws.
  static Future<List<Map<String, dynamic>>> listComments(
      String postId, {int offset = 0, int limit = pageSize}) async {
    if (postId.isEmpty) return [];
    try {
      final rows = await SupaDb.getList('community_comments',
          eqCol: 'post_id',
          eqVal: postId,
          orderBy: 'created_at',
          ascending: true,
          limit: limit,
          offset: offset);
      final comments = rows.map(normComment).toList();
      if (comments.isEmpty) return comments;
      final authors = await CommunityService.publicProfiles(
          comments.map((c) => SupaDb.strOf(c['author_uid'])).toList());
      final byUid = {
        for (final a in authors) SupaDb.strOf(a['firebase_uid']): a
      };
      for (final c in comments) {
        final uid = SupaDb.strOf(c['author_uid']);
        c['author'] = byUid[uid] ?? {'firebase_uid': uid, 'display_name': 'Player', 'displayName': 'Player'};
      }
      return comments;
    } catch (_) {
      return [];
    }
  }

  /// Add a comment. Only MEMBERS may comment (follow first).
  static Future<Map<String, dynamic>> addComment({
    required String postId,
    required String communityId,
    required String authorUid,
    required String body,
  }) async {
    final text = body.trim();
    if (postId.isEmpty || authorUid.isEmpty) {
      return {'ok': false, 'error': 'Login zaroori hai.'};
    }
    if (text.isEmpty) {
      return {'ok': false, 'error': 'Comment khaali hai.'};
    }
    if (text.length > 1000) {
      return {'ok': false, 'error': 'Comment 1000 characters se zyada nahi ho sakta.'};
    }
    try {
      if (communityId.isNotEmpty &&
          !await isMember(authorUid, communityId)) {
        return {
          'ok': false,
          'error': 'Comment karne ke liye pehle community follow karen.'
        };
      }
      await _client.from('community_comments').insert({
        'post_id': postId,
        'author_uid': authorUid,
        'body': text,
      });
      return {'ok': true};
    } catch (e) {
      if (CommunityService.tableMissing(e)) {
        return {'ok': false, 'offline': true};
      }
      return {'ok': false, 'error': e.toString()};
    }
  }

  // ------------------------------------------------------------------
  // Community chat (EXISTING chat_messages table, scope 'community'
  // + community_id — the 073 column). Same shape as squad chat.
  // ------------------------------------------------------------------

  /// One-shot community chat history, NEWEST FIRST (guide §4.5).
  /// PAGINATED: [limit] messages per page (default 50); pass
  /// [before] (a created_at ISO string) to fetch the next OLDER
  /// page — a cursor, so new arrivals never shift page
  /// boundaries. [] when the community_id column does not exist
  /// yet — never throws.
  static Future<List<Map<String, dynamic>>> getCommunityChat(
      String communityId, {String? before, int limit = pageSize}) async {
    if (communityId.isEmpty) return [];
    try {
      final rows = await SupaDb.getList('chat_messages',
          eqCol: 'scope',
          eqVal: 'community',
          eqCol2: 'community_id',
          eqVal2: communityId,
          ltCol: (before == null || before.isEmpty) ? null : 'created_at',
          ltVal: (before == null || before.isEmpty) ? null : before,
          orderBy: 'created_at',
          ascending: false,
          limit: limit);
      return rows
          .map(SupaDb.normChat)
          .where((m) => m['deleted_at'] == null)
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// Live community chat (initial fetch + 3 s poll refetch — A1
  /// has no Realtime relay, so polling is the only live-update
  /// path) — the NEWEST 50 messages, newest first, so the UI
  /// can merge live arrivals into its paginated history. (The old
  /// oldest-first limit-200 stream could never show a message
  /// past the first 200.) Emits [] when the community_id column
  /// does not exist yet — never throws.
  static Stream<List<Map<String, dynamic>>> streamCommunityChat(
      String communityId) {
    if (communityId.isEmpty) return Stream.value(const []);
    try {
      return SupaDb.streamList('chat_messages',
              eqCol: 'scope',
              eqVal: 'community',
              eqCol2: 'community_id',
              eqVal2: communityId,
              orderBy: 'created_at',
              ascending: false,
              limit: pageSize,
              // FIX 12 G2 (2026-11-23): 3 s poll — A1 has NO Realtime
              // (404), so without this the stream never refetches and
              // the sender never sees their own message. Same O-2
              // pattern streamChat uses for all 4 of its branches.
              pollInterval: const Duration(seconds: 3))
          .map((rows) => rows
              .map(SupaDb.normChat)
              .where((m) => m['deleted_at'] == null)
              .toList());
    } catch (_) {
      return Stream.value(const []);
    }
  }

  /// Send a community chat message. Only MEMBERS may chat (follow
  /// first). A missing community_id column returns
  /// {'ok': false, 'offline': true} instead of crashing.
  static Future<Map<String, dynamic>> sendCommunityChatMessage({
    required String communityId,
    required String fromUid,
    required String displayName,
    required String message,
  }) async {
    final text = message.trim();
    if (text.isEmpty) return {'ok': false, 'error': 'Message khaali hai.'};
    if (communityId.isEmpty || fromUid.isEmpty) {
      return {'ok': false, 'error': 'Message nahi bheja ja sakta.'};
    }
    try {
      if (!await isMember(fromUid, communityId)) {
        return {
          'ok': false,
          'error': 'Chat karne ke liye pehle community follow karen.'
        };
      }
      if (await SupaDb.isChatRestricted(fromUid)) {
        return {
          'ok': false,
          'error': 'Aapka chat admin ne band kiya hua hai — admin se rabta karein.'
        };
      }
      // FIX 15: community-scoped block (organizer action) — this
      // community only; other communities are unaffected.
      if (await SupaDb.isChatRestrictedInCommunity(fromUid, communityId)) {
        return {
          'ok': false,
          'error':
              'Aapko is community ki chat se hata diya gaya hai — organizer se rabta karein.'
        };
      }
      await _client.from('chat_messages').insert({
        'scope': 'community',
        'community_id': communityId,
        'tournament_id': null,
        'squad_id': null,
        'firebase_uid': fromUid,
        'display_name': displayName,
        'sender': displayName,
        'message': text,
      });
      return {'ok': true};
    } catch (e) {
      if (CommunityService.tableMissing(e) || _missingColumn(e)) {
        return {
          'ok': false,
          'offline': true,
          'error': 'Community chat backend abhi online nahi hua (migration 073 pending).'
        };
      }
      return {'ok': false, 'error': e.toString()};
    }
  }

  /// Send a PICTURE in community chat (P1-7 — same pattern as the DM
  /// picture path: member-only + chat-restriction checks, ImgBB URL in
  /// chat_messages.image_url, empty message body). A missing column
  /// returns {'ok': false, 'needs_column': true} instead of crashing.
  static Future<Map<String, dynamic>> sendCommunityChatImageMessage({
    required String communityId,
    required String fromUid,
    required String displayName,
    required String imageUrl,
  }) async {
    if (imageUrl.isEmpty) return {'ok': false, 'error': 'Photo nahi mili.'};
    if (communityId.isEmpty || fromUid.isEmpty) {
      return {'ok': false, 'error': 'Photo nahi bheji ja sakti.'};
    }
    try {
      if (!await isMember(fromUid, communityId)) {
        return {
          'ok': false,
          'error': 'Chat karne ke liye pehle community follow karen.'
        };
      }
      if (await SupaDb.isChatRestricted(fromUid)) {
        return {
          'ok': false,
          'error': 'Aapka chat admin ne band kiya hua hai — admin se rabta karein.'
        };
      }
      // FIX 15: community-scoped block (organizer action) — this
      // community only; other communities are unaffected.
      if (await SupaDb.isChatRestrictedInCommunity(fromUid, communityId)) {
        return {
          'ok': false,
          'error':
              'Aapko is community ki chat se hata diya gaya hai — organizer se rabta karein.'
        };
      }
      await _client.from('chat_messages').insert({
        'scope': 'community',
        'community_id': communityId,
        'tournament_id': null,
        'squad_id': null,
        'firebase_uid': fromUid,
        'display_name': displayName,
        'sender': displayName,
        'message': '',
        'image_url': imageUrl,
      });
      return {'ok': true};
    } catch (e) {
      if (CommunityService.tableMissing(e) || _missingColumn(e)) {
        return {'ok': false, 'needs_column': true, 'error': 'Photo messages abhi available nahi — backend update pending hai.'};
      }
      return {'ok': false, 'error': e.toString()};
    }
  }
}
