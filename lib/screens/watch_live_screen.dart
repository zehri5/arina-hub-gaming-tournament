// Watch Live — YouTube live stream embedded in-app + the app's OWN
// live comments below it (NOT YouTube's chat).
//
// User order (voice call 2026-11-21; FIX 6 2026-11-22 free
// spectating): a "Watch Live" screen for ANY viewer — spectating is
// free, no tournament join needed. Joined or not, logged in or not,
// anyone can watch the stream and read the live comments; sending a
// comment or tapping like needs login (honest toast, never a crash
// and never a fake success). The stream plays inside the app via the
// existing webview_flutter dependency (no new package, no new paid
// service);
// comments are the app's own Supabase realtime chat, scoped
// `watch_live` on chat_messages keyed by tournament id — the same
// table and the same SupaDb.getChat / streamChat / sendChat helpers
// the room/tournament chat already uses. No new production table.
//
// EMBED URL SCHEME (documented — slow-4G first):
//   https://www.youtube.com/embed/VIDEO_ID
//     ?autoplay=1        — starts without an extra tap
//     &vq=small          — start at 240p so playback begins fast on
//                          slow 4G; YouTube's adaptive player steps
//                          quality UP as bandwidth allows
//     &rel=0             — no unrelated videos at the end
//     &modestbranding=1  — minimal YouTube chrome
//     &playsinline=1     — plays inside the app, no fullscreen jump
//     &iv_load_policy=3  — no video annotations over the stream
// A channel live URL carries no video id
// (youtube.com/@handle/live, youtube.com/channel/ID/live,
// youtube.com/c/NAME/live):
// those load directly in the webview instead — YouTube resolves the
// channel's live stream itself. A plain watch/shorts/embed/live URL
// with a video id always goes through the embed above.
//
// FIX 9 (2026-11-23): a video id no longer loads the plain embed
// URL — it loads through a small IFrame API wrapper page
// (buildYouTubePlayerHtml) with a Chrome mobile user agent
// (kWatchLiveUserAgent): the default Android WebView UA contains
// "wv" and YouTube's player answered it with Error 153 ("Video
// player configuration error") on Sameer's phone, for a video whose
// oEmbed says embedding is allowed. The wrapper's onError posts to
// the 'PlayerError' JavaScriptChannel, so a player error shows the
// app's own fallback + Retry instead of YouTube's error screen
// (which carried a watch-on-YouTube exit button). There is
// NO YouTube exit left on this screen: the AppBar arrow and the
// fallback's open-in-YouTube button are both gone (user order
// 2026-11-23 00:12).
//
// VISIBILITY — watchLiveVisibleFor: the button shows only when a
// watch_live_url exists AND show_watch_live is true. BACKEND NOTE:
// `show_watch_live` is NOT yet a column on the server (only
// `watch_live_url` is — SupaDb.normTournament reads it). Until the
// column lands, a tournament map that carries NO show_watch_live key
// falls back to "URL present = visible" so the feature works today;
// the moment the key exists on a row it is enforced strictly
// (false / null hides the button). The column to add (separate
// backend step, NOT done here):
//   alter table tournaments add column show_watch_live boolean
//   not null default false;
// Chat RLS note: `watch_live` rows use the same chat_messages
// columns as the `tournament` scope; the chat_messages RLS policies
// must admit scope = 'watch_live' for anon select/insert exactly as
// they do for scope = 'tournament', or comments fail to load/send
// (the screen shows the failure honestly instead of fake comments).
//
// Theme: gold #FDC903 on black (kGold / kBg / kCard from theme.dart).
// No named route — callers push with MaterialPageRoute directly.
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:share_plus/share_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
// ignore: depend_on_referenced_packages
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../services/admin_db_care.dart';
import '../services/message_sounds.dart';
import '../services/supabase_db.dart';
import '../theme.dart';
import '../utils.dart';
import '../widgets/arena_ui.dart';

String _str(dynamic v, [String dflt = '']) => v == null ? dflt : v.toString();

/// Extract the YouTube video id from a watch / youtu.be / embed / v /
/// shorts / live URL. Returns null for channel live URLs
/// (`/@handle/live`, `/channel/ID/live`, `/c/NAME/live`) and for
/// non-YouTube URLs — those load directly in the webview instead.
String? extractYouTubeVideoId(String rawUrl) {
  final url = rawUrl.trim();
  if (url.isEmpty) return null;
  Uri? uri;
  try {
    uri = Uri.parse(url);
  } catch (_) {
    return null;
  }
  final host = uri.host.toLowerCase();
  final isYouTube = host == 'youtu.be' ||
      host.endsWith('.youtube.com') ||
      host == 'youtube.com' ||
      host.endsWith('.youtube-nocookie.com');
  if (!isYouTube) return null;
  // watch?v=<id> (also music.youtube.com, /watch with extra params).
  final v = uri.queryParameters['v'];
  if (v != null && v.isNotEmpty) return v;
  // Path forms: /embed/<id>, /v/<id>, /shorts/<id>, /live/<id>.
  // A path ending in /live with NO id segment (channel live) must
  // NOT match: /@handle/live, /channel/<id>/live, /c/<name>/live.
  final segs = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  if (segs.isEmpty) return null;
  if (host == 'youtu.be') return segs.first;
  const idPrefixes = {'embed', 'v', 'shorts', 'live'};
  if (segs.length >= 2 && idPrefixes.contains(segs[0])) return segs[1];
  if (segs.length == 1 && idPrefixes.contains(segs[0])) return null;
  return null;
}

/// The embed URL loaded for a video id — see the file header for the
/// exact parameter list and why each one is there.
String buildYouTubeEmbedUrl(String videoId) =>
    'https://www.youtube.com/embed/$videoId'
    '?autoplay=1&vq=small&rel=0&modestbranding=1&playsinline=1&iv_load_policy=3';

/// The direct-load URL for a stream: the low-quality embed when a
/// video id can be parsed, otherwise the original URL (channel
/// live). FIX 9: the screen routes video ids through the IFrame
/// wrapper (buildYouTubePlayerHtml) instead, so in practice only
/// the channel-live branch is loaded through this helper — the
/// embed branch stays as the documented URL builder, pinned by
/// tests.
String watchLiveLoadUrl(String rawUrl) {
  final id = extractYouTubeVideoId(rawUrl);
  if (id != null && id.isNotEmpty) return buildYouTubeEmbedUrl(id);
  return rawUrl.trim();
}

/// Chrome mobile user agent for the Watch Live webview (FIX 9,
/// 2026-11-23): the default Android WebView UA contains "wv" and
/// YouTube's embed player answers it with Error 153 ("Video player
/// configuration error") — seen live on Sameer's phone for a video
/// whose oEmbed says embedding is allowed. A plain Chrome mobile
/// UA makes the player treat the webview as a real browser tab.
/// Pinned by test (must contain "Chrome/" and must NOT contain
/// the "; wv" WebView marker).
const String kWatchLiveUserAgent =
    'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

/// JavaScriptChannel the IFrame wrapper posts player errors to
/// (FIX 9). The channel object is exposed to the page as
/// `window.PlayerError` by webview_flutter; the wrapper calls
/// `PlayerError.postMessage(code)` from the player's onError.
const String kWatchLiveErrorChannel = 'PlayerError';

/// The IFrame wrapper's origin (FIX 21 item 4) — Sameer's own real
/// domain, a legitimate third-party referrer. FIX 20 (fix 22) used
/// 'https://www.youtube.com/' as the loadHtmlString baseUrl and
/// YouTube answered Error 152: a page claiming to BE youtube.com
/// hosting a youtube.com iframe is rejected as an invalid embed
/// context (startdebugging.net + screentinker PR #65,
/// Android-verified). A third-party origin keeps the Referer fix
/// (153) without triggering 152. The IFrame `origin` playerVar
/// MUST match this base URL — both are this one constant so they
/// can never drift apart.
const String kWatchLiveEmbedOrigin = 'https://appfixguru.com';

/// IFrame API wrapper page (FIX 9): the plain embed URL cannot tell
/// the app when YouTube's player itself errors — Error 153 is an
/// in-page player error, onWebResourceError never fires for it, so
/// the app's fallback never showed and YouTube's own error screen
/// (with its watch-on-YouTube exit button) stayed on screen.
/// Loading the player through the IFrame API lets onError
/// post to the 'PlayerError' JavaScriptChannel, so the app hides
/// the webview behind its own fallback + Retry instead. playerVars
/// mirror the old embed URL params (autoplay 1, modestbranding 1,
/// playsinline 1, rel 0). The video id is sanitised to
/// [A-Za-z0-9_-] so a hostile id can never break out of the JS
/// string. FIX 20 (fix 19): onReady starts at 240p ('small') and
/// caps auto quality at 360p ('medium') — on slow mobile data an
/// HD-first start takes forever; low-first starts in seconds and
/// YouTube adapts upward only as far as the connection allows.
/// FIX 21 (item 4): the `origin` playerVar is
/// [kWatchLiveEmbedOrigin] — it MUST match the loadHtmlString
/// baseUrl (same constant), or YouTube rejects the embed context
/// (Error 152, seen on v2020 with the youtube.com baseUrl).
/// Pure function — pinned by unit tests.
String buildYouTubePlayerHtml(String videoId) {
  final safeId = videoId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '');
  return '''
<!DOCTYPE html>
<html><head><meta name="viewport" content="width=device-width, initial-scale=1">
<style>html,body{margin:0;padding:0;background:#000;height:100%;overflow:hidden}#player{width:100%;height:100%}</style></head>
<body><div id="player"></div>
<script src="https://www.youtube.com/iframe_api"></script>
<script>
var player;
function onYouTubeIframeAPIReady() {
  player = new YT.Player('player', {
    videoId: '$safeId',
    playerVars: {autoplay: 1, modestbranding: 1, playsinline: 1, rel: 0, origin: '$kWatchLiveEmbedOrigin'},
    events: {
      onReady: function(e) { e.target.setPlaybackQuality('small'); e.target.setPlaybackQualityRange('small', 'medium'); e.target.playVideo(); },
      onError: function(e) { PlayerError.postMessage('' + (e && e.data !== undefined ? e.data : 'unknown')); }
    }
  });
}
</script></body></html>
''';
}

/// Entry-button rule: visible only when a watch URL exists AND
/// show_watch_live is true — with the documented fallback while the
/// show_watch_live column does not exist on the server yet (a map
/// with no such key at all falls back to "URL present = visible").
bool watchLiveVisibleFor(Map<String, dynamic> t) {
  final url = _str(t['watchLiveUrl']).isNotEmpty
      ? _str(t['watchLiveUrl'])
      : _str(t['watch_live_url']).isNotEmpty
          ? _str(t['watch_live_url'])
          : _str(t['live_url']);
  if (url.isEmpty) return false;
  if (t.containsKey('showWatchLive') || t.containsKey('show_watch_live')) {
    final flag = t['showWatchLive'] ?? t['show_watch_live'];
    return flag == true;
  }
  return true;
}

/// The stream URL for a tournament map (watchLiveUrl, snake-case and
/// legacy live_url spellings all accepted).
String watchLiveUrlOf(Map<String, dynamic> t) {
  final url = _str(t['watchLiveUrl']);
  if (url.isNotEmpty) return url;
  final snake = _str(t['watch_live_url']);
  if (snake.isNotEmpty) return snake;
  return _str(t['live_url']);
}

/// Detail-page note rule (v2013; FIX 6 2026-11-22 free spectating):
/// ANY viewer on a live (ongoing) tournament with NO stream URL sees
/// "URL set nahi hai" instead of a mysteriously missing Watch Live
/// button. Only ongoing tournaments — an upcoming tournament is not
/// live yet, so no note there. NO joined requirement: spectating is
/// free, so non-joined viewers see the same honest note.
bool watchLiveUrlNoteVisibleFor(Map<String, dynamic> t) {
  if (_str(t['status']).toLowerCase() != 'ongoing') return false;
  return watchLiveUrlOf(t).isEmpty;
}

/// Kick rule (v2013, Watch Live moderation): a viewer is kicked
/// out of the live screen when they are chat-restricted AND logged
/// in AND not the admin. Admins are never kicked (they are the ones
/// doing the restricting); logged-out viewers have no restriction
/// row to check. The screen polls `isChatRestricted` every 30s and
/// exits with "aap ko live chat se hata diya gaya" when this turns
/// true.
/// FIX 5 (2026-11-22): moderators are never kicked either — they
/// moderate the chat like the admin. `isModerator` defaults to
/// false so existing callers behave exactly as before.
bool shouldKickFromWatchLive({
  required bool loggedIn,
  required bool isAdmin,
  required bool isRestricted,
  bool isModerator = false,
}) =>
    loggedIn && !isAdmin && !isModerator && isRestricted;

// ---------- viewer counts + likes (2026-11-22) ----------
//
// IN-APP VIEWERS (FIX 8, 2026-11-22): Supabase Realtime presence
// does NOT exist on A1 (404 — backend lane's §3.4 finding), so the
// count comes from a heartbeat table instead — `watch_live_viewers`
// (see SupaDb's watch-live section for the DDL + RLS), polled
// every 30 s. Every open Watch Live screen upserts one row
// (tournament_id + one random viewer key per screen open,
// logged-in or guest) and re-upserts every 30 s; the count is the
// rows with last_seen inside the last 90 s. The Realtime presence
// subscription is still opened (harmless on A1 — it just never
// subscribes) but the DISPLAYED count comes from the poll, never
// from presenceState. If the heartbeat or the count query fails
// the count reads "—", never 0 and never a guess.
// NOTE: the presence TABLE's current_tournament_id is NOT used
// here — it sticks to the last-viewed tournament while the user
// stays in-app, so it would over-count (detail-page viewers are
// not watching the stream).
//
// YOUTUBE VIEWERS: YouTube Data API v3 videos.list,
// part=liveStreamingDetails -> concurrentViewers, polled every
// 60s (1 quota unit per call). The API key comes from app_settings
// (`youtube_api_key`, admin-pasted in Admin > Settings; free key
// from Google Cloud Console with YouTube Data API v3 enabled).
// No key / no video id / fetch failure = the YouTube count is
// HIDDEN (never a fake number). Quota note: every open screen
// polls, so a big live audience spends quota fast (60 calls/hour
// per viewer against the 10,000/day free quota) — a server-side
// cache is a later backend step if that ever bites.
//
// LIKES: `watch_live_likes` table (BACKEND LANE — see SupaDb's
// watch-live section for the DDL + RLS). Until it exists the
// count reads "—" and tapping like toasts honestly.

/// Realtime presence channel for one tournament's Watch Live screen.
String watchLivePresenceChannel(String tournamentId) =>
    'watchlive_$tournamentId';

/// Parse the concurrent-viewer count out of a YouTube Data API v3
/// videos.list response. Null when the video is not live, the
/// field is absent, or the payload is not what was expected.
int? parseYouTubeLiveViewers(dynamic json) {
  try {
    final m = json as Map<String, dynamic>;
    final items = m['items'] as List?;
    if (items == null || items.isEmpty) return null;
    final details =
        (items.first as Map<String, dynamic>)['liveStreamingDetails']
            as Map<String, dynamic>?;
    final raw = details?['concurrentViewers'];
    if (raw == null) return null;
    if (raw is num) return raw.toInt();
    return int.tryParse(raw.toString());
  } catch (_) {
    return null;
  }
}

/// Fetch the live concurrent-viewer count for a YouTube video id.
/// Returns null on ANY failure (no key, not live, quota/network
/// error) — callers hide the count instead of faking one.
/// [client] is injectable for tests (MockClient).
Future<int?> fetchYouTubeLiveViewers({
  required String videoId,
  required String apiKey,
  http.Client? client,
}) async {
  if (videoId.isEmpty || apiKey.isEmpty) return null;
  final c = client ?? http.Client();
  final close = client == null;
  try {
    final uri = Uri.https('www.googleapis.com', '/youtube/v3/videos', {
      'part': 'liveStreamingDetails',
      'id': videoId,
      'key': apiKey,
    });
    final res = await c.get(uri).timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) return null;
    return parseYouTubeLiveViewers(jsonDecode(res.body));
  } catch (_) {
    return null;
  } finally {
    if (close) c.close();
  }
}

/// Compact viewer/like counts: 999 -> "999", 1200 -> "1.2K",
/// 1500000 -> "1.5M". Whole thousands drop the ".0" (2000 -> "2K").
String formatViewerCount(int n) {
  if (n < 1000) return '$n';
  if (n < 1000000) {
    final v = n / 1000;
    return '${v.truncateToDouble() == v ? v.toInt() : v.toStringAsFixed(1)}K';
  }
  final v = n / 1000000;
  return '${v.truncateToDouble() == v ? v.toInt() : v.toStringAsFixed(1)}M';
}

/// FIX 22 (item 4): the Facebook-style reacted line. [displayName]
/// is the newest liker's display name, [total] the real like count.
/// '' when there is nothing honest to show (0 likers, or no name).
String watchLiveReactedText(String displayName, int total) {
  if (total <= 0) return '';
  final first = displayName
      .trim()
      .split(RegExp(r'\s+'))
      .firstWhere((s) => s.isNotEmpty, orElse: () => '');
  if (first.isEmpty) return '';
  if (total == 1) return '$first reacted';
  return '$first and ${total - 1} others reacted';
}

/// Watch Live screen: YouTube live embed on top, the app's own live
/// comments below. Push with MaterialPageRoute — no named route.
class WatchLiveScreen extends StatefulWidget {
  final String tournamentId;
  final String tournamentName;
  final String watchUrl;

  const WatchLiveScreen({
    super.key,
    required this.tournamentId,
    required this.tournamentName,
    required this.watchUrl,
  });

  @override
  State<WatchLiveScreen> createState() => _WatchLiveScreenState();
}

class _WatchLiveScreenState extends State<WatchLiveScreen> {
  late final WebViewController _controller;
  final _composer = TextEditingController();
  final _scroll = ScrollController();
  final _chatKey = GlobalKey();
  String _myName = 'You';
  bool _loadingPlayer = true;
  bool _playerFailed = false;
  // FIX 20 (fix 21): the diagnostic reason for a player failure
  // (JS channel code or main-frame resource error), shown as a
  // small muted line under the fallback message so one screenshot
  // tells us the exact cause. Null = no code available -> no
  // line at all (never "null" / "unknown" text).
  String? _playerErrorCode;
  // FIX 21 (item 5): which KIND of failure this is. True when the
  // IFrame player's own onError fired (JS channel — e.g. 152):
  // the internet may be perfectly fine, so the fallback must NOT
  // blame it. False for a genuine main-frame resource error
  // (network), where the internet hint stays. Reset by Retry.
  bool _playerFailedIsPlayerError = false;
  bool _atBottom = true;
  bool _sending = false;
  List<Map<String, dynamic>> _lastMessages = const [];
  // MESSAGE SOUNDS (Sameer's picks, 2026-11-22): the in-chat pop
  // plays only AFTER the first stream emission has primed the
  // list — opening the live chat must not beep for its history.
  bool _chatPrimed = false;

  // FIX 20 (fix 18): the comments stream, created ONCE in
  // initState. streamChat returns a FRESH polling stream on every
  // call, so building it inside build() recreated + resubscribed
  // on EVERY rebuild (viewer/like/YT/kick timers all setState)
  // — the spinner flashed and comments reloaded forever. The
  // field keeps stream identity stable; the 3s poll inside
  // streamList still delivers new comments.
  late final Stream<List<Map<String, dynamic>>> _commentStream;

  // --- Viewer counts + likes (2026-11-22). Null = unknown /
  // unavailable — the UI shows "—" (likes) or hides the chip
  // entirely (YouTube). Never a fake number.
  // FIX 22 item 3: the IN APP count is gone (display + its
  // local field + the count query) — the heartbeat upsert
  // still runs in _heartbeatViewer.
  int? _ytViewers;
  String _ytApiKey = '';
  // FIX 20 (fix 20): cumulative total views (tournaments
  // .watch_views) — never decreases. Null = unknown (backend
  // migration pending / read failed) -> UI shows "—", never 0.
  int? _totalViews;
  // FIX 20 (fix 20): the +1 increment fires ONCE per Watch open.
  bool _viewCounted = false;
  int? _likeCount;
  bool _liked = false;
  bool _likesAvailable = false;
  bool _likeBusy = false;
  // FIX 22 (item 4): likers for the reacted row — resolved
  // profiles (firebase_uid, display_name, photo_url), newest
  // first, capped at 50 by the query. Empty = no likers (row
  // hidden) or likers unknown (table missing) — both hide the
  // row, never fake it.
  List<Map<String, dynamic>> _likers = const [];
  // FIX 22 (item 4): the comment button focuses the composer.
  final _composerFocus = FocusNode();
  Timer? _ytTimer;
  Timer? _likeTimer;
  RealtimeChannel? _presenceChannel;

  // FIX 8 (2026-11-22): viewer-count polling — Realtime is 404 on
  // A1, so the IN APP count comes from the watch_live_viewers
  // heartbeat table, polled every 30 s. _viewerKey is one random
  // key per screen open (logged-in or guest, same scheme).
  String? _viewerKey;
  Timer? _viewerTimer;

  // --- Moderation (v2013). _isAdmin gates the long-press mod menu
  // (delete / block / kick / ban); the kick timer polls the
  // restriction and exits a kicked viewer with an honest message.
  // FIX 5 (2026-11-22): _isModerator (admin_users role
  // 'moderator', appointed by the designated admin — no request
  // flow) gets the SAME menu via _canModerate, and is never kicked.
  bool _isAdmin = false;
  bool _isModerator = false;

  /// May this viewer moderate this live chat (long-press menu)?
  /// Designated admin OR appointed moderator.
  bool get _canModerate => _isAdmin || _isModerator;
  Timer? _kickTimer;
  bool _kickedOut = false;

  @override
  void initState() {
    super.initState();
    _commentStream = SupaDb.streamChat('watch_live', widget.tournamentId);
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFF000000))
      // FIX 9: Chrome mobile UA — the default Android WebView UA
      // ("wv") makes YouTube's player answer Error 153.
      ..setUserAgent(kWatchLiveUserAgent)
      // FIX 9: the IFrame wrapper posts player errors here (the
      // plain embed could not report them — onWebResourceError
      // never fires for an in-page player error, so YouTube's own
      // error screen stayed up with its watch-on-YouTube button).
      // Any error hides the webview behind the app's fallback +
      // Retry instead.
      ..addJavaScriptChannel(
        kWatchLiveErrorChannel,
        onMessageReceived: (message) {
          if (mounted) {
            // FIX 20 (fix 21): keep the posted code — the IFrame
            // posts 'unknown' when the player gives no code, and
            // that is not a diagnosis, so it stays null.
            // FIX 21 (item 5): this is a PLAYER error, not a
            // network error — the fallback message says so.
            final code = message.message.trim();
            setState(() {
              _loadingPlayer = false;
              _playerFailed = true;
              _playerFailedIsPlayerError = true;
              _playerErrorCode =
                  code.isEmpty || code == 'unknown' ? null : 'Error code: $code';
            });
          }
        },
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) {
            if (mounted) setState(() => _loadingPlayer = false);
          },
          onWebResourceError: (err) {
            // FIX 20 (fix 17): onWebResourceError fires for EVERY
            // resource — including subresources (ads, trackers,
            // thumbnails) that YouTube loads by the dozen. On slow
            // mobile data any one of them failing used to kill the
            // whole player and show "stream load nahi ho saka"
            // even though the video itself was fine. ONLY a
            // main-frame error fails the player now; subresource
            // errors are logged and ignored.
            if (err.isForMainFrame != true) {
              debugPrint('[watch_live] subresource error ignored: ${err.description} (${err.url})');
              return;
            }
            if (mounted) {
              // FIX 20 (fix 21): keep the main-frame error code +
              // description for the diagnostic line.
              // FIX 21 (item 5): this IS a network error — the
              // fallback keeps the internet hint for it.
              final desc = err.description.trim();
              setState(() {
                _loadingPlayer = false;
                _playerFailed = true;
                _playerFailedIsPlayerError = false;
                _playerErrorCode = 'Network error ${err.errorCode}'
                    '${desc.isEmpty ? '' : ': $desc'}';
              });
            }
          },
          // Keep the player inside YouTube; anything else (a link
          // out of the stream page) opens externally instead of
          // hijacking the watch screen.
          onNavigationRequest: (req) {
            final host = Uri.tryParse(req.url)?.host.toLowerCase() ?? '';
            final isYouTube = host == 'youtu.be' ||
                host == 'youtube.com' ||
                host.endsWith('.youtube.com') ||
                host.endsWith('.googlevideo.com');
            if (isYouTube) return NavigationDecision.navigate;
            launchUrl(Uri.parse(req.url), mode: LaunchMode.externalApplication);
            return NavigationDecision.prevent;
          },
        ),
      );
    // FIX 9: autoplay needs media playback without a user gesture
    // on Android; on other platforms (and in tests) `platform` is
    // not the Android controller and this is a no-op.
    final platform = _controller.platform;
    if (platform is AndroidWebViewController) {
      platform.setMediaPlaybackRequiresUserGesture(false);
    }
    _loadPlayer();
    _scroll.addListener(_onScroll);
    _loadMyName();
    _loadAdminStatus();
    _setupWatchLiveExtras();
    // Kick poll (v2013): every 30s, a restricted non-admin viewer
    // is exited with "aap ko live chat se hata diya gaya". First
    // check at 30s, not on open — an already-restricted user gets
    // their 30 seconds of stream before the exit lands.
    _kickTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _checkKicked(),
    );
  }

  /// Load the stream (FIX 9): a video id goes through the IFrame
  /// wrapper page (Chrome UA + onError reporting), a channel-live
  /// URL has no video id and loads directly, as before.
  ///
  /// FIX 20 (fix 22): the wrapper is loaded WITH a base URL.
  /// Without one the page has a null origin (about:blank) —
  /// YouTube's player can refuse a null-origin page with a
  /// "Video player configuration error" (Error 153, still seen on
  /// v2019 despite the Chrome UA) and YouTube cookies become
  /// third-party (often blocked).
  /// FIX 21 (item 4): the base URL is [kWatchLiveEmbedOrigin]
  /// (appfixguru.com), NOT youtube.com — fix 22's youtube.com
  /// baseUrl itself caused Error 152 on v2020 (a page claiming
  /// to BE youtube.com hosting a youtube.com iframe is rejected
  /// as an invalid embed context). A legitimate third-party
  /// origin keeps the Referer fix (153) without triggering 152.
  /// The IFrame `origin` playerVar is the same constant.
  void _loadPlayer() {
    final videoId = extractYouTubeVideoId(widget.watchUrl);
    if (videoId != null && videoId.isNotEmpty) {
      _controller.loadHtmlString(
        buildYouTubePlayerHtml(videoId),
        baseUrl: kWatchLiveEmbedOrigin,
      );
    } else {
      _controller.loadRequest(Uri.parse(watchLiveLoadUrl(widget.watchUrl)));
    }
  }

  /// Retry after a player failure — reload the same player in-app.
  /// No YouTube exit (FIX 9): the old fallback button opened the
  /// stream in the YouTube app; this one just tries again here.
  void _retryPlayer() {
    setState(() {
      _playerFailed = false;
      _playerErrorCode = null;
      _playerFailedIsPlayerError = false;
      _loadingPlayer = true;
    });
    _loadPlayer();
  }

  /// Admin detection for the mod menu — fail closed: the
  /// server-verified designated admin UID (admin_config id=1) must
  /// match the signed-in UID.
  /// FIX 32 (2026-11-24, admin-panel removal): the old SECOND gate —
  /// the device-local admin_mode marker — is GONE. The marker was
  /// only ever set by Admin Login / "Switch to Admin", both deleted
  /// with the panel, so keeping the gate would have silently locked
  /// the admin out of his own Watch Live mod menu in the user app.
  /// The UID check alone is the same fail-closed check the boot
  /// gates, the runbook gate and the room host checks all use.
  Future<void> _loadAdminStatus() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null || user.uid.isEmpty) return;
      // Designated admin: fresh UID match, no marker needed.
      var isAdmin = false;
      final adminUid = await SupaDb.designatedAdminUid();
      isAdmin = adminUid.isNotEmpty && adminUid == user.uid;
      // FIX 5: moderators moderate too — role from admin_users via
      // SupaDb.myAdminRole (RPC first, own-row fallback).
      // Fail closed: any read error leaves isModerator false.
      var isModerator = false;
      if (!isAdmin) {
        final role = await SupaDb.myAdminRole();
        isModerator = role == 'moderator';
      }
      if (!mounted) return;
      setState(() {
        _isAdmin = isAdmin;
        _isModerator = isModerator;
      });
    } catch (_) {
      // Fail closed: neither admin nor moderator.
    }
  }

  /// Kick enforcement (v2013): when an admin restricts (blocks /
  /// kicks) this viewer, the next 30s poll sees it and exits the
  /// screen with an honest message — no silent disappearance.
  Future<void> _checkKicked() async {
    if (_kickedOut || _isAdmin || _isModerator) return;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || user.uid.isEmpty) return;
    final restricted = await SupaDb.isChatRestricted(user.uid);
    if (!restricted || !mounted || _kickedOut) return;
    if (!shouldKickFromWatchLive(
      loggedIn: true,
      isAdmin: _isAdmin,
      isRestricted: restricted,
      isModerator: _isModerator,
    )) {
      return;
    }
    _kickedOut = true;
    _kickTimer?.cancel();
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        backgroundColor: kCardPurpleMid,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22), side: const BorderSide(color: kCardPurpleBorder, width: 1.5)),
        title: Text(
          'Live chat se hata diya gaya',
          style: TextStyle(color: kText),
        ),
        content: Text(
          'Aap ko is live stream ki chat se hata diya gaya hai.',
          style: TextStyle(color: kMuted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(
              'OK',
              style: TextStyle(color: kGold),
            ),
          ),
        ],
      ),
    );
    if (mounted) Navigator.pop(context);
  }

  /// Viewer counts + likes, all best-effort: any failure leaves the
  /// count unknown ("—" / hidden) and NEVER blocks watching.
  Future<void> _setupWatchLiveExtras() async {
    // YouTube viewers: only when a video id parses AND an API key
    // is configured. Poll every 60s (1 quota unit per call).
    final videoId = extractYouTubeVideoId(widget.watchUrl);
    if (videoId != null && videoId.isNotEmpty) {
      final key = await SupaDb.getYouTubeApiKey();
      if (!mounted) return;
      _ytApiKey = key;
      if (key.isNotEmpty) {
        await _fetchYouTubeViewers(videoId);
        _ytTimer = Timer.periodic(
          const Duration(seconds: 60),
          (_) => _fetchYouTubeViewers(videoId),
        );
      }
    }
    // In-app viewers: Realtime presence on this tournament's
    // channel. Join failures leave the count unknown ("—").
    // (FIX 8: kept for the subscription only — the displayed
    // count comes from the poll below, never from presence.)
    unawaited(_joinPresence());
    // FIX 8: in-app viewers via polling (Realtime is 404 on A1).
    unawaited(_startViewerPolling());
    // FIX 20 (fix 20): count this Watch open (+1 total view,
    // once per open) and load the cumulative total.
    unawaited(_countWatchView());
    unawaited(_loadTotalViews());
    // Likes: count + my state now, count refresh every 30s.
    await _loadLikes();
    if (!mounted) return;
    // FIX 22 (item 4): likers for the reacted row (refreshes
    // with the 30s like poll).
    unawaited(_loadLikers());
    _likeTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) {
        unawaited(_refreshLikeCount());
        unawaited(_loadLikers());
      },
    );
  }

  Future<void> _fetchYouTubeViewers(String videoId) async {
    final n = await fetchYouTubeLiveViewers(
      videoId: videoId,
      apiKey: _ytApiKey,
    );
    // A failed fetch keeps the LAST good count (or stays hidden);
    // a null never overwrites a real number with a fake 0.
    if (mounted && n != null) setState(() => _ytViewers = n);
  }

  Future<void> _joinPresence() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      // Logged-out viewers still count — one random key per screen
      // open (a guest is one viewer, same as a logged-in user).
      final key = user != null && user.uid.isNotEmpty
          ? user.uid
          : 'guest_${Random().nextInt(1 << 30)}_${DateTime.now().millisecondsSinceEpoch}';
      final channel = SupaDb.client
          .channel(watchLivePresenceChannel(widget.tournamentId))
          .onPresenceSync((_) {
        // FIX 8: the presence subscription is kept (harmless on
        // A1 — it never subscribes) but the displayed count comes
        // from the poll, never from presenceState.
      });
      _presenceChannel = channel;
      // subscribe() is synchronous (returns the channel) — track
      // only once the join is confirmed; tracking earlier can be
      // dropped. channelError/closed/timedOut leave the count
      // unknown ("—"); watching is never blocked.
      channel.subscribe((status, error) {
        if (status == RealtimeSubscribeStatus.subscribed) {
          unawaited(channel.track({'user_id': key}).catchError((_) {
            // Track failed: this viewer just doesn't count.
            return ChannelResponse.timedOut;
          }));
        }
      });
    } catch (_) {
      // Presence unavailable (no Realtime / offline): the count
      // stays unknown ("—"). Watching is never blocked.
    }
  }

  /// FIX 8: viewer-count polling — heartbeat this screen's row and
  /// refresh the IN APP count now, then every 30 s. Any failure
  /// leaves the count unknown ("—"); watching is never blocked.
  Future<void> _startViewerPolling() async {
    _viewerKey ??=
        'v_${Random().nextInt(1 << 30)}_${DateTime.now().millisecondsSinceEpoch}';
    await _heartbeatViewer();
    if (!mounted) return;
    _viewerTimer = Timer.periodic(
      const Duration(seconds: SupaDb.watchLiveViewerHeartbeatSeconds),
      (_) => _heartbeatViewer(),
    );
  }

  Future<void> _heartbeatViewer() async {
    // FIX 20 (fix 20): the total refreshes with the 30s poll,
    // independent of the heartbeat result (a failed heartbeat
    // must not freeze the total).
    unawaited(_loadTotalViews());
    final key = _viewerKey;
    if (key == null) return;
    // FIX 22 item 3: the IN APP count display is gone, so the
    // count query is gone too — the heartbeat itself (the
    // upsert below) still runs: the server-side presence
    // other viewers rely on depends on it.
    try {
      await SupaDb.heartbeatWatchLiveViewer(
        tournamentId: widget.tournamentId,
        viewerKey: key,
      );
    } catch (_) {}
  }

  /// FIX 20 (fix 20): count this Watch open as one view. The flag
  /// is set BEFORE the await, so rebuilds and retries can never
  /// double-count. Best-effort + fire-and-forget: the helper never
  /// throws, and a failed increment shows no error anywhere (that
  /// view just isn't counted).
  Future<void> _countWatchView() async {
    if (_viewCounted) return;
    _viewCounted = true;
    await SupaDb.incrementWatchViews(widget.tournamentId);
  }

  /// FIX 20 (fix 20): read the cumulative total from the
  /// tournament row. Missing row / missing column / any failure
  /// -> null -> the UI shows "—", never 0 and never a fake number.
  Future<void> _loadTotalViews() async {
    try {
      final row = await SupaDb.getRow('tournaments', 'id', widget.tournamentId);
      final v = row['watch_views'];
      if (!mounted) return;
      setState(() => _totalViews = v is int ? v : (v is num ? v.toInt() : null));
    } catch (_) {
      if (mounted) setState(() => _totalViews = null);
    }
  }

  Future<void> _loadLikes() async {
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
      final count = await SupaDb.getWatchLiveLikeCount(widget.tournamentId);
      final liked = uid.isEmpty
          ? false
          : await SupaDb.hasWatchLiveLiked(widget.tournamentId, uid);
      if (!mounted) return;
      setState(() {
        _likeCount = count;
        _liked = liked;
        _likesAvailable = true;
      });
    } catch (_) {
      // Likes table not on the server yet (backend lane): count
      // stays "—" and the button toasts honestly on tap.
      if (mounted) setState(() => _likesAvailable = false);
    }
  }

  Future<void> _refreshLikeCount() async {
    if (!_likesAvailable) return;
    try {
      final count = await SupaDb.getWatchLiveLikeCount(widget.tournamentId);
      if (mounted) setState(() => _likeCount = count);
    } catch (_) {
      // A failed refresh keeps the last good count.
    }
  }

  Future<void> _toggleLike() async {
    if (!_likesAvailable) {
      toast(context, 'Likes abhi available nahi hain — jald aa raha hai.');
      return;
    }
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      toast(context, 'Like karne ke liye login zaroori hai.');
      return;
    }
    if (_likeBusy) return;
    setState(() => _likeBusy = true);
    final ok = await SupaDb.toggleWatchLiveLike(
      tournamentId: widget.tournamentId,
      uid: user.uid,
      liked: _liked,
    );
    if (!mounted) return;
    setState(() => _likeBusy = false);
    if (!ok) {
      toast(context, 'Like save nahi ho saka — dobara koshish karein.');
      return;
    }
    // Refresh both from the server (never assume the write's
    // effect — someone else may have liked in the meantime).
    await _loadLikes();
    // FIX 22 (item 4): the reacted row follows the like state.
    unawaited(_loadLikers());
  }

  /// FIX 22 (item 4): load the likers for the reacted row
  /// (newest first, cap 50) + resolve their names/photos from
  /// profiles. Any failure (table missing / offline) leaves the
  /// row hidden — never a fake liker.
  Future<void> _loadLikers() async {
    try {
      final rows = await SupaDb.getWatchLiveLikers(widget.tournamentId);
      final uids = rows
          .map((r) => SupaDb.strOf(r['firebase_uid']))
          .where((u) => u.isNotEmpty)
          .toList();
      final profiles = await SupaDb.getProfilesMap(uids);
      if (!mounted) return;
      setState(() {
        _likers = rows.map((r) {
          final uid = SupaDb.strOf(r['firebase_uid']);
          final p = profiles[uid] ?? const <String, dynamic>{};
          return <String, dynamic>{
            'firebase_uid': uid,
            'display_name': SupaDb.strOf(p['display_name'], 'Player'),
            'photo_url': SupaDb.strOf(p['photo_url']),
          };
        }).toList();
      });
    } catch (_) {
      if (mounted) setState(() => _likers = const []);
    }
  }

  /// FIX 22 (item 4): share the stream link via the system sheet.
  /// No share count exists (no backend counter) — never show one.
  Future<void> _shareStream() async {
    final text =
        '${widget.tournamentName} — live dekhiye: ${widget.watchUrl}';
    try {
      await Share.share(text);
    } catch (_) {
      if (mounted) {
        toast(context, 'Share nahi ho saka — dobara koshish karein.');
      }
    }
  }

  /// FIX 22 (item 4): comment button — jump to the latest
  /// comments + focus the composer so the user can type.
  void _onCommentTap() {
    _jumpToLatest();
    _composerFocus.requestFocus();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    // "At bottom" with a small tolerance: the user is considered to
    // be following the live flow unless they scrolled clearly up.
    final atBottom =
        _scroll.position.pixels >= _scroll.position.maxScrollExtent - 80;
    if (atBottom != _atBottom) setState(() => _atBottom = atBottom);
  }

  Future<void> _loadMyName() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;
      final profile = await SupaDb.getProfile(user.uid);
      final name =
          _str(profile['displayName'], user.email?.split('@').first ?? 'You');
      if (mounted && name.isNotEmpty) setState(() => _myName = name);
    } catch (_) {
      // Display name stays the email-prefix fallback — sending still
      // works; a failed profile read must never block watching.
    }
  }

  @override
  void dispose() {
    _ytTimer?.cancel();
    _likeTimer?.cancel();
    _kickTimer?.cancel();
    _viewerTimer?.cancel();
    // FIX 8: best-effort delete of this screen's viewer row (a
    // failed delete is harmless — the row ages out of the count
    // after the 90 s staleness window anyway).
    final viewerKey = _viewerKey;
    if (viewerKey != null) {
      unawaited(SupaDb.leaveWatchLiveViewer(
        tournamentId: widget.tournamentId,
        viewerKey: viewerKey,
      ));
    }
    // Leave the presence channel so this viewer stops counting
    // immediately (the channel also drops on disconnect, but an
    // explicit unsubscribe is instant, not staleness-based).
    final channel = _presenceChannel;
    if (channel != null) {
      unawaited(channel.unsubscribe().catchError((_) => 'error'));
    }
    _scroll.dispose();
    _composer.dispose();
    _composerFocus.dispose();
    super.dispose();
  }

  /// New messages auto-scroll ONLY while the user is already at the
  /// bottom — never yanks the view while they are reading older
  /// comments (the "jump to latest" pill covers catching up).
  void _maybeAutoScroll(List<Map<String, dynamic>> messages) {
    final grew = messages.length > _lastMessages.length;
    final countChanged = messages.length != _lastMessages.length;
    // MESSAGE SOUNDS: new comment from someone else while watching
    // live -> the short in-chat pop (chat_08). Own comments and
    // the first load never beep (see MessageSounds).
    final lastIsMine = messages.isNotEmpty &&
        SupaDb.strOf(messages.last['firebase_uid']) ==
            (FirebaseAuth.instance.currentUser?.uid ?? '');
    if (MessageSounds.shouldPlayChatSound(
        primed: _chatPrimed, grew: grew, lastIsMine: lastIsMine)) {
      MessageSounds.play(MessageSound.chat);
    }
    _chatPrimed = true;
    _lastMessages = messages;
    // FIX 22 (item 4): the engagement row's comment count reads
    // _lastMessages — rebuild when the count changes. Post-frame:
    // this runs during the StreamBuilder's build, so a direct
    // setState here would throw.
    if (countChanged) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    }
    if (!grew || !_atBottom) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients || !mounted) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  void _jumpToLatest() {
    if (!_scroll.hasClients) return;
    _scroll.animateTo(
      _scroll.position.maxScrollExtent,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  Future<void> _send() async {
    final text = _composer.text.trim();
    if (text.isEmpty || _sending) return;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      toast(context, 'Comment karne ke liye login zaroori hai.');
      return;
    }
    if (await SupaDb.isChatRestricted(user.uid)) {
      if (!mounted) return;
      toast(context, 'Aap ke comments admin ne band kiye hue hain.');
      return;
    }
    setState(() => _sending = true);
    try {
      await SupaDb.sendChat(
        scope: 'watch_live',
        scopeId: widget.tournamentId,
        uid: user.uid,
        displayName: _myName,
        message: text,
      );
      _composer.clear();
      // Sent message should be visible immediately even if the
      // realtime echo is slow on a weak connection.
      _jumpToLatest();
    } catch (e) {
      if (mounted) toast(context, friendlyDbError(e));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// Moderation menu (v2013, admin only — long-press a message).
  /// Delete removes the message live (soft-delete + the chat
  /// stream filters deleted rows); Block restricts the user's chat
  /// everywhere; Kick restricts AND exits their live screen on the
  /// next 30s poll; Ban blocks their next login (device + account).
  /// Own messages can only be deleted, never blocked/kicked/banned.
  Future<void> _showModMenu(Map<String, dynamic> m, String name) async {
    final messageId = _str(m['id']);
    final senderUid = _str(m['firebase_uid']);
    final myUid = FirebaseAuth.instance.currentUser?.uid ?? '';
    final isOwn = senderUid.isNotEmpty && senderUid == myUid;
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: kCardPurpleMid,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22)), side: const BorderSide(color: kCardPurpleBorder, width: 1.5)),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(Icons.person, color: kMuted),
              title: Text(
                name,
                style: TextStyle(
                  color: kText,
                  fontWeight: FontWeight.bold,
                ),
              ),
              subtitle: Text(
                _str(m['message']),
                style: TextStyle(color: kMuted),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Divider(color: kBorder, height: 1),
            ListTile(
              leading: Icon(Icons.delete_outline, color: kText),
              title: Text(
                'Delete message',
                style: TextStyle(color: kText),
              ),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
            if (!isOwn) ...[
              ListTile(
                leading: Icon(Icons.block, color: kText),
                title: Text(
                  'Block user (comments band)',
                  style: TextStyle(color: kText),
                ),
                onTap: () => Navigator.pop(ctx, 'block'),
              ),
              ListTile(
                leading: Icon(Icons.exit_to_app, color: kText),
                title: Text(
                  'Kick user (live se nikaalein)',
                  style: TextStyle(color: kText),
                ),
                onTap: () => Navigator.pop(ctx, 'kick'),
              ),
              ListTile(
                leading: const Icon(Icons.gavel, color: kError),
                title: const Text(
                  'Ban user (login band)',
                  style: TextStyle(color: kError),
                ),
                onTap: () => Navigator.pop(ctx, 'ban'),
              ),
            ],
            ListTile(
              leading: Icon(Icons.close, color: kMuted),
              title: Text('Cancel', style: TextStyle(color: kMuted)),
              onTap: () => Navigator.pop(ctx),
            ),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    switch (action) {
      case 'delete':
        await _modDelete(messageId);
        break;
      case 'block':
        await _modRestrict(senderUid, kick: false);
        break;
      case 'kick':
        await _modRestrict(senderUid, kick: true);
        break;
      case 'ban':
        await _modBan(senderUid, name);
        break;
    }
  }

  Future<void> _modDelete(String messageId) async {
    if (messageId.isEmpty) {
      toast(context, 'Message nahi mila.');
      return;
    }
    final res = await AdminDbCare.deleteChatMessage(
      messageId: messageId,
      reason: 'Watch Live moderation',
    );
    if (!mounted) return;
    toast(
      context,
      res['ok'] == true
          ? 'Message delete ho gaya.'
          : friendlyDbError(res['error'], 'Delete'),
    );
  }

  Future<void> _modRestrict(String targetUid, {required bool kick}) async {
    if (targetUid.isEmpty) {
      toast(context, 'User nahi mila.');
      return;
    }
    final res = await AdminDbCare.restrictChatUser(
      targetUid: targetUid,
      reason: kick ? 'Watch Live kick' : 'Watch Live block',
    );
    if (!mounted) return;
    if (res['ok'] == true) {
      toast(
        context,
        kick
            ? 'User ko live chat se hata diya gaya — wo jald bahar nikal jayega.'
            : 'User block ho gaya — uske comments band hain.',
      );
    } else {
      toast(context, friendlyDbError(res['error'], 'Block'));
    }
  }

  Future<void> _modBan(String targetUid, String name) async {
    if (targetUid.isEmpty) {
      toast(context, 'User nahi mila.');
      return;
    }
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: kCardPurpleMid,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22), side: const BorderSide(color: kCardPurpleBorder, width: 1.5)),
        title: Text('Ban user?', style: TextStyle(color: kText)),
        content: Text(
          '$name dobara login nahi kar sakega (device + account dono ban honge). Pehle Block ya Kick aazma lein — ban sakht action hai.',
          style: TextStyle(color: kMuted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Cancel', style: TextStyle(color: kMuted)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text(
              'Ban',
              style: TextStyle(color: kError),
            ),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    final res = await AdminDbCare.banDeviceUser(
      targetUid: targetUid,
      reason: 'Watch Live ban',
    );
    if (!mounted) return;
    toast(
      context,
      res['ok'] == true
          ? 'User ban ho gaya — wo dobara login nahi kar sakega.'
          : friendlyDbError(res['error'], 'Ban'),
    );
  }

  /// Viewer stats under the player (FIX 22 items 3+4): YOUTUBE =
  /// total concurrent viewers on YouTube (Data API — shown only
  /// when a key is configured and a count loaded); total views =
  /// the cumulative watch_views counter (FIX 20). The IN APP count
  /// is GONE from the display (user order 2026-11-23) — the
  /// heartbeat still runs (it drives the total refresh), it just
  /// isn't shown. The like button moved into [_engagementRow].
  /// Unknown counts read "—", never 0 and never a guess.
  Widget _statsRow() {
    Widget stat(IconData icon, String count, String label) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: kGold),
          const SizedBox(width: 4),
          Text(
            count,
            style: TextStyle(
              color: kText,
              fontWeight: FontWeight.bold,
              fontSize: 13,
            ),
          ),
          const SizedBox(width: 3),
          Text(
            label,
            style: TextStyle(color: kMuted, fontSize: 11),
          ),
        ],
      );
    }

    // The info area (plain Padding in build) supplies the
    // horizontal padding — this row only adds its top gap.
    return Padding(
      padding: const EdgeInsets.only(top: kSpace8),
      child: Row(
        children: [
          if (_ytViewers != null) ...[
            Flexible(
              child: stat(
                Icons.play_circle_fill,
                formatViewerCount(_ytViewers!),
                'YOUTUBE',
              ),
            ),
            const SizedBox(width: 14),
          ],
          Flexible(
            child: stat(
              Icons.trending_up,
              _totalViews == null ? '—' : formatViewerCount(_totalViews!),
              'total views',
            ),
          ),
        ],
      ),
    );
  }

  /// FIX 22 (item 4): one liker avatar — photo when the profile
  /// has one, initial letter otherwise. Dark ring so overlapping
  /// avatars stay distinct.
  Widget _likerAvatar(Map<String, dynamic> liker, double radius) {
    final photo = SupaDb.strOf(liker['photo_url']);
    final name = SupaDb.strOf(liker['display_name'], 'Player');
    final initial =
        name.isNotEmpty ? name.characters.first.toUpperCase() : '?';
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: kBg, width: 2),
      ),
      child: CircleAvatar(
        radius: radius,
        backgroundColor: kSurfaceElevated,
        backgroundImage: photo.isNotEmpty ? NetworkImage(photo) : null,
        child: photo.isEmpty
            ? Text(
                initial,
                style: TextStyle(
                  color: kText,
                  fontWeight: FontWeight.bold,
                  fontSize: radius,
                ),
              )
            : null,
      ),
    );
  }

  /// FIX 22 (item 4): Facebook-style reacted row — up to 3
  /// overlapping liker avatars + "Name and N others reacted".
  /// Hidden entirely when there are no likers. Tap opens the
  /// full likers sheet.
  Widget _reactedRow() {
    if (_likers.isEmpty || (_likeCount ?? 0) <= 0) {
      return const SizedBox.shrink();
    }
    final shown = _likers.take(3).toList();
    final first = SupaDb.strOf(_likers.first['display_name']);
    final text = watchLiveReactedText(first, _likeCount ?? _likers.length);
    if (text.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: kSpace8),
      child: GestureDetector(
        onTap: _showLikersSheet,
        behavior: HitTestBehavior.opaque,
        child: Row(
          children: [
            SizedBox(
              width: 18.0 + (shown.length - 1) * 14.0,
              height: 22,
              child: Stack(
                children: [
                  for (var i = 0; i < shown.length; i++)
                    Positioned(
                      left: i * 14.0,
                      child: _likerAvatar(shown[i], 11),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                text,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: kMuted, fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// FIX 22 (item 4): full likers list (avatar + name each,
  /// capped at 50 by the query). The header shows the REAL like
  /// count; a note says so when the list is capped.
  void _showLikersSheet() {
    if (_likers.isEmpty) return;
    final total = _likeCount ?? _likers.length;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: kCardPurpleMid,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22)), side: const BorderSide(color: kCardPurpleBorder, width: 1.5)),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
              child: Row(
                children: [
                  Icon(Icons.favorite, size: 18, color: kGold),
                  const SizedBox(width: 8),
                  Text(
                    'Liked by $total',
                    style: TextStyle(
                      color: kText,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: kBorder),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _likers.length,
                itemBuilder: (ctx, i) {
                  final liker = _likers[i];
                  return ListTile(
                    leading: _likerAvatar(liker, 16),
                    title: Text(
                      SupaDb.strOf(liker['display_name'], 'Player'),
                      style: TextStyle(color: kText, fontSize: 14),
                    ),
                  );
                },
              ),
            ),
            if (total > _likers.length)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: Text(
                  'Showing first ${_likers.length} of $total',
                  style: TextStyle(color: kMuted, fontSize: 12),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// FIX 22 (item 4) + FIX 23 item 28: Facebook-style engagement
  /// row — Like (real count), Comment (real count), Share (NO
  /// count — none exists). Dark + gold pills. Bookmark REMOVED
  /// (user order 2026-11-24 — its device-local code is deleted).
  /// Three natural-width pills (no Expanded, no ellipsis): the
  /// full labels + counts fit at 360px (was "Com..."/"Bookm...").
  Widget _engagementRow() {
    Widget action({
      required IconData icon,
      required String label,
      String? count,
      required VoidCallback onTap,
      bool active = false,
      Key? key,
    }) {
      return InkWell(
        key: key,
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding:
              const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
          decoration: BoxDecoration(
            // PHASE E (E24, CORRECTED 2026-11-24): active keeps
            // its gold tint (Sameer: "click pe yellow hona
            // chahiye"); the REST is the card fill now (was the
            // dark kSurface) — never black.
            color: active
                ? kGold.withValues(alpha: 0.12)
                : kCardFillColor,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: active
                  ? kGold.withValues(alpha: 0.7)
                  : kBorder.withValues(alpha: 0.6),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 20,
                color: active ? kGold : kText.withValues(alpha: 0.8),
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: active ? kGold : kText,
                  fontSize: 13,
                  fontWeight:
                      active ? FontWeight.bold : FontWeight.normal,
                ),
              ),
              if (count != null) ...[
                const SizedBox(width: 4),
                Text(
                  count,
                  style: TextStyle(
                    color: active ? kGold : kText,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
              ],
            ],
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(top: kSpace8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          action(
            key: const ValueKey('watchLiveLikeButton'),
            icon: _liked ? Icons.favorite : Icons.favorite_border,
            label: 'Like',
            count:
                _likeCount == null ? '—' : formatViewerCount(_likeCount!),
            // Dimmed + honest toast when likes are not available
            // yet (backend table pending) — _toggleLike toasts.
            onTap: _likeBusy ? () {} : _toggleLike,
            active: _liked,
          ),
          action(
            key: const ValueKey('watchLiveCommentButton'),
            icon: Icons.chat_bubble_outline,
            label: 'Comment',
            // "—" until the first comments emission primes the
            // list — 0 before load would be a guess.
            count: _chatPrimed
                ? formatViewerCount(_lastMessages.length)
                : '—',
            onTap: _onCommentTap,
          ),
          action(
            key: const ValueKey('watchLiveShareButton'),
            icon: Icons.share_outlined,
            label: 'Share',
            // NO count — no backend share counter exists.
            onTap: _shareStream,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent, // PHASE E (E4): transparent header — poster shows through
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        foregroundColor: kText,
        centerTitle: true,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 9,
              height: 9,
              decoration: const BoxDecoration(
                color: kLiveRed,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 7),
            Flexible(
              child: Text(
                'WATCH LIVE',
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: kText,
                  fontWeight: FontWeight.w900,
                  fontStyle: FontStyle.italic,
                  fontSize: 18,
                ),
              ),
            ),
          ],
        ),
      ),
      body: ArenaBackground(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // --- Player: 16:9 embed in a dark rounded container,
            // capped at 280dp so the comments + composer still fit
            // on short / wide screens (a full-width 16:9 player on
            // a wide window would crowd them out entirely). On a
            // phone the 16:9 size wins.
            Container(
              key: const ValueKey('watchLivePlayerContainer'),
              margin: const EdgeInsets.fromLTRB(kSpace12, kSpace8, kSpace12, 0),
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(kRadiusHero),
                border: Border.all(color: kBorder),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(kRadiusHero),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final w = constraints.maxWidth;
                    final h = (w * 9 / 16).clamp(0.0, 280.0);
                    return SizedBox(
                      width: w,
                      height: h,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          WebViewWidget(controller: _controller),
                          if (_loadingPlayer)
                            const Center(
                              child: ArenaLoadingIndicator(
                                // Keyed so tests can tell the player
                                // spinner from the comments-area
                                // spinner (FIX 9).
                                key: ValueKey('watchLivePlayerLoading'),
                              ),
                            ),
                          if (_playerFailed)
                            Container(
                              color: Colors.black,
                              alignment: Alignment.center,
                              child: Padding(
                                // FIX 20 (fix 21a): the player box is
                                // only ~189dp tall at 360dp, and the
                                // fallback must fit INSIDE it —
                                // icon + message + diagnostic code +
                                // button, nothing hidden behind the
                                // button and nothing needing a
                                // scroll to be seen. Budget: 12px
                                // padding + 28 icon + 6 + ~36 message
                                // (2 lines) + 6 + ~15 code line + 6 +
                                // ~46 button + 12 padding ≈ 173dp,
                                // ~16dp of slack. The scroll view
                                // stays only as a safety net for
                                // narrower screens (320dp box is
                                // 166dp — it scrolls, never
                                // overflows).
                                padding: const EdgeInsets.all(12),
                                child: SingleChildScrollView(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.live_tv,
                                          color: kTextMuted, size: 28),
                                      const SizedBox(height: 6),
                                      // FIX 21 (item 5): the message
                                      // matches the failure kind. A
                                      // player error (JS channel,
                                      // e.g. 152) is NOT an internet
                                      // problem — Sameer's v2020
                                      // screenshot proved the net was
                                      // fine (comments/likes/viewers
                                      // all working) — so it gets a
                                      // neutral message. A genuine
                                      // network error keeps the
                                      // internet hint.
                                      Text(
                                        _playerFailedIsPlayerError
                                            ? 'Stream app mein nahi chal saki — dobara koshish karein.'
                                            : 'Stream load nahi ho saka — internet check karein aur dobara koshish karein.',
                                        textAlign: TextAlign.center,
                                        style: TextStyle(
                                            color: kMuted, fontSize: 13),
                                      ),
                                      // FIX 20 (fix 21): small muted
                                      // diagnostic line — only when
                                      // a real code was captured.
                                      // ABOVE the button, never
                                      // behind or below it.
                                      if (_playerErrorCode != null) ...[
                                        const SizedBox(height: 4),
                                        Text(
                                          _playerErrorCode!,
                                          textAlign: TextAlign.center,
                                          style: TextStyle(
                                              color: kTextMuted,
                                              fontSize: 11),
                                        ),
                                      ],
                                      const SizedBox(height: 6),
                                      ArenaPrimaryButton(
                                        onPressed: _retryPlayer,
                                        child: const Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(Icons.refresh,
                                                size: 18, color: Colors.black),
                                            SizedBox(width: 6),
                                            // Flexible + ellipsis: the
                                            // button frame adds 20px
                                            // padding per side, so the
                                            // label must never force
                                            // the Row past the player
                                            // box (77px overflow on a
                                            // 360dp screen before).
                                            Flexible(
                                              child: Text(
                                                'Dobara koshish karein',
                                                overflow:
                                                    TextOverflow.ellipsis,
                                                style: TextStyle(
                                                    color: Colors.black,
                                                    fontSize: 14),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
            // --- Stream info area: tournament title + viewer
            // stats + reacted row + engagement row + the
            // live-comments note. No channel/creator data exists
            // for a tournament stream, so the area carries the
            // title + stats — never fake creator info.
            // FIX 22 (item 3): the thick MockupCard frame is GONE
            // (user order) — a plain Padding, same padding, same
            // children. MockupCard itself is untouched (it is the
            // shared global card every other screen keeps).
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  kSpace12, kSpace12, kSpace12, kSpace8),
              child: Padding(
                key: const ValueKey('watchLiveInfoCard'),
                padding: const EdgeInsets.all(kSpace12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      widget.tournamentName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: kStyleCardTitle,
                    ),
                    // Viewer stats (YOUTUBE + total views).
                    _statsRow(),
                    // FIX 22 (item 4): reacted row (likers only).
                    _reactedRow(),
                    Padding(
                      padding: const EdgeInsets.only(top: kSpace8),
                      child: Divider(height: 1, color: kBorder),
                    ),
                    // FIX 22 (item 4) + FIX 23 item 28: Like /
                    // Comment / Share engagement row (Bookmark
                    // removed).
                    _engagementRow(),
                    Padding(
                      padding: const EdgeInsets.only(top: kSpace8),
                      child: Row(
                        children: [
                          Icon(Icons.chat_bubble_outline,
                              size: 14, color: kTextMuted),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              // FIX 6 (free spectating): anyone can
                              // watch + read comments; sending needs
                              // login (the composer hint + send
                              // toast say so).
                              'Live comments — sab dekh sakte hain',
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: kMuted, fontSize: 12),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // --- Own live comments (Supabase realtime, scope
            // 'watch_live', tournament id). PHASE E (E10b): NO
            // opaque fill — the solid kSurface covered the whole
            // comment-list area; the ArenaBackground poster shows
            // through now. Bubbles themselves are unchanged. ---
            Expanded(
              child: Container(
                key: const ValueKey('watchLiveCommentsSurface'),
                child: StreamBuilder<List<Map<String, dynamic>>>(
                  key: _chatKey,
                  // FIX 20 (fix 18): the initState-created stream
                  // — never a fresh streamChat() call per build.
                  stream: _commentStream,
                  builder: (context, snap) {
                    if (snap.hasError) {
                      return Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.error_outline,
                                  color: kError, size: 36),
                              const SizedBox(height: 12),
                              Text(
                                'Comments load nahi ho sake: ${snap.error}',
                                textAlign: TextAlign.center,
                                style: TextStyle(color: kMuted),
                              ),
                            ],
                          ),
                        ),
                      );
                    }
                    if (snap.connectionState == ConnectionState.waiting) {
                      return const Center(
                        child: ArenaLoadingIndicator(),
                      );
                    }
                    final messages = snap.data ?? [];
                    _maybeAutoScroll(messages);
                    if (messages.isEmpty) {
                      return Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.forum_outlined,
                                  color: kTextMuted, size: 40),
                              const SizedBox(height: 12),
                              Text(
                                'Abhi koi comment nahi — pehla comment aap karein!',
                                textAlign: TextAlign.center,
                                style: TextStyle(color: kMuted),
                              ),
                            ],
                          ),
                        ),
                      );
                    }
                    return Stack(
                      children: [
                        ListView.builder(
                          controller: _scroll,
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                          itemCount: messages.length,
                          itemBuilder: (context, i) {
                            final m = messages[i];
                            final mine = _str(m['firebase_uid']).isNotEmpty &&
                                _str(m['firebase_uid']) == uid;
                            final name = _str(
                                m['display_name'], _str(m['sender'], 'Player'));
                            final text = _str(m['message']);
                            if (text.isEmpty) return const SizedBox.shrink();
                            final initial = name.isNotEmpty
                                ? name.characters.first.toUpperCase()
                                : '?';
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: GestureDetector(
                                // v2013: admin long-press opens the
                                // moderation menu (delete / block /
                                // kick / ban). FIX 5: moderators get
                                // it too. Others get no gesture.
                                onLongPress: _canModerate
                                    ? () => _showModMenu(m, name)
                                    : null,
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    CircleAvatar(
                                      radius: 15,
                                      backgroundColor:
                                          mine ? kGold : kSurfaceElevated,
                                      child: Text(
                                        initial,
                                        style: TextStyle(
                                          color: mine ? Colors.black : kText,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 13,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Flexible(
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 12, vertical: 8),
                                        decoration: BoxDecoration(
                                          // Own bubble: dark gold-brown tint
                                          // (a background tint, not a gold —
                                          // kept per the GOLD RULE note in
                                          // theme.dart).
                                          color: mine
                                              ? const Color(0xFF3A2F00)
                                              : kCard,
                                          borderRadius: BorderRadius.circular(
                                              kRadiusInput),
                                          border: Border.all(
                                            color: mine
                                                ? kGold.withValues(alpha: 0.45)
                                                : kBorder,
                                          ),
                                        ),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              mine ? '$name (aap)' : name,
                                              style: TextStyle(
                                                color: mine ? kGold : kText,
                                                fontWeight: FontWeight.bold,
                                                fontSize: 12,
                                              ),
                                            ),
                                            const SizedBox(height: 2),
                                            Text(
                                              text,
                                              style: TextStyle(
                                                color: kText,
                                                fontSize: 14,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                        // Jump-to-latest pill — only while scrolled up.
                        if (!_atBottom)
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: 10,
                            child: Center(
                              child: ElevatedButton.icon(
                                onPressed: _jumpToLatest,
                                icon:
                                    const Icon(Icons.arrow_downward, size: 16),
                                label: const Text('Latest comments'),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: kGold,
                                  foregroundColor: Colors.black,
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 14, vertical: 8),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ),
            ),
            // --- Composer. PHASE E (E10b): transparent fill (the
            // kSurface fill is gone) — the top border divider
            // stays, and the CardFieldShell composer field is
            // unchanged. ---
            Container(
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: kBorder)),
              ),
              padding: EdgeInsets.fromLTRB(
                12,
                8,
                12,
                8 + MediaQuery.of(context).viewInsets.bottom,
              ),
              child: SafeArea(
                top: false,
                child: Row(
                  children: [
                    Expanded(
                      // FIX 23 item 29: card look via CardFieldShell.
                      child: CardFieldShell(
                        child: TextField(
                        controller: _composer,
                        // FIX 22 (item 4): the comment button
                        // focuses the composer.
                        focusNode: _composerFocus,
                        style: TextStyle(color: kText),
                        decoration: InputDecoration(
                          // FIX 6: a logged-out spectator sees the
                          // honest login hint up front (the send tap
                          // toasts the same thing — never a crash,
                          // never a fake success).
                          hintText: uid.isEmpty
                              ? 'Comment ke liye login karein…'
                              : 'Live comment likhein…',
                          hintStyle: TextStyle(color: kMuted),
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 10),
                          border: const OutlineInputBorder(borderSide: BorderSide.none),
                          enabledBorder: const OutlineInputBorder(borderSide: BorderSide.none),
                          focusedBorder: const OutlineInputBorder(borderSide: BorderSide.none),
                        ),
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => _send(),
                      ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    // Yellow Send button (guide §6 Screen 2) — the
                    // submission logic (_send) is unchanged.
                    Container(
                      key: const ValueKey('watchLiveSendButton'),
                      decoration: BoxDecoration(
                        color: kGold,
                        shape: BoxShape.circle,
                      ),
                      child: IconButton(
                        onPressed: _sending ? null : _send,
                        icon: _sending
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  color: Colors.black,
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.send, color: Colors.black),
                        tooltip: 'Bhejein',
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
