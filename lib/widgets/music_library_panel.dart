import 'package:flutter/material.dart';

class LibrarySong {
  final String key;
  final String title;
  final String artist;
  final Duration? duration; // null = hide the duration badge
  final bool isTone; // built-in tone: NO edit button
  final bool isPlaying;
  final bool isPaused;
  final bool inPlaylist;
  final String? statusLine; // e.g. "Shared • ducked to 5% — RJ bed", null = hide

  const LibrarySong({
    required this.key,
    required this.title,
    required this.artist,
    this.duration,
    this.isTone = false,
    this.isPlaying = false,
    this.isPaused = false,
    this.inPlaylist = false,
    this.statusLine,
  });
}

class MusicLibraryPanel extends StatefulWidget {
  final List<LibrarySong> songs;
  final LibrarySong? nowPlaying;
  final bool nowPlayingPaused;
  final bool broadcastOn;
  final int selectedTab; // 0 = Local Music, 1 = My Playlist
  final String searchQuery;
  // FIX 22 item 21: NO onBroadcastChanged — hosting is GO LIVE
  // only; broadcastOn is display-only now (the card shows the
  // live state, the switch is gone).
  final ValueChanged<int> onTabChanged;
  final ValueChanged<String> onSearchChanged;
  final ValueChanged<String> onPlaySong;
  final VoidCallback onPauseResume;
  final VoidCallback onStop;
  final VoidCallback onOpenPlayer;
  final ValueChanged<String> onToggleBookmark;
  final ValueChanged<String> onEditSong;
  final VoidCallback onUpload;
  // FIX 22 item 22: NO onSettings — the library Settings button
  // opened the same hosting dialog as the player's (removed;
  // GO LIVE owns hosting now, item 21).
  final VoidCallback onClose;
  // FIX 20 (fix 15): RJ Studio entry from the Music header.
  // rjVisible is the room-host check (admin / team captain /
  // community organizer — same gate as fix 7b); non-hosts see
  // no button at all, never a dead one.
  final VoidCallback? onRjPanel;
  final bool rjVisible;

  const MusicLibraryPanel({
    super.key,
    required this.songs,
    required this.nowPlaying,
    required this.nowPlayingPaused,
    required this.broadcastOn,
    required this.selectedTab,
    required this.searchQuery,
    required this.onTabChanged,
    required this.onSearchChanged,
    required this.onPlaySong,
    required this.onPauseResume,
    required this.onStop,
    required this.onOpenPlayer,
    required this.onToggleBookmark,
    required this.onEditSong,
    required this.onUpload,
    required this.onClose,
    this.onRjPanel,
    this.rjVisible = false,
  });

  @override
  State<MusicLibraryPanel> createState() => _MusicLibraryPanelState();
}

class _MusicLibraryPanelState extends State<MusicLibraryPanel> {
  static const Color _gold = Color(0xFFFDC903);
  static const Color _red = Color(0xFFE51919);
  static const Color _white = Color(0xFFFFFFFF);
  static const Color _mutedGrey = Color(0xFF94A3B8);
  static const Color _cardFill = Color(0x59000000); // black ~35% opacity

  late final TextEditingController _searchController;

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController(text: widget.searchQuery);
  }

  @override
  void didUpdateWidget(covariant MusicLibraryPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.searchQuery != oldWidget.searchQuery &&
        widget.searchQuery != _searchController.text) {
      _searchController.value = TextEditingValue(
        text: widget.searchQuery,
        selection: TextSelection.collapsed(offset: widget.searchQuery.length),
      );
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  String _formatDuration(Duration duration) {
    final int totalSeconds = duration.inSeconds;
    final int hours = totalSeconds ~/ 3600;
    final int minutes = (totalSeconds % 3600) ~/ 60;
    final int seconds = totalSeconds % 60;
    final String minStr = minutes.toString().padLeft(2, '0');
    final String secStr = seconds.toString().padLeft(2, '0');
    if (hours > 0) {
      return '$hours:$minStr:$secStr';
    }
    return '$minStr:$secStr';
  }

  @override
  Widget build(BuildContext context) {
    final LibrarySong? nowPlaying = widget.nowPlaying;

    return Material(
      type: MaterialType.transparency,
      // FIX 2 (design): warm golden glow behind the whole panel, as
      // in the design image — gold only, low alpha over the sheet's
      // dark brown (#1E1408).
      child: Container(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: Alignment.topCenter,
            radius: 1.1,
            colors: [
              _gold.withAlpha(30),
              _gold.withAlpha(0),
            ],
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          // FIX 2 (design): the whole panel scrolls and the song
          // list shrink-wraps, so Local Upload sits right under the
          // last song — the old Expanded list left a big empty gap
          // under a short list (the design shows the button directly
          // under the content).
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildHeader(),
                const SizedBox(height: 8),
                _buildBroadcastCard(),
                if (nowPlaying != null) ...[
                  const SizedBox(height: 8),
                  _buildNowPlayingStrip(nowPlaying),
                ],
                const SizedBox(height: 8),
                _buildTabs(),
                const SizedBox(height: 8),
                _buildSearchField(),
                const SizedBox(height: 8),
                _buildCountRow(),
                const SizedBox(height: 8),
                widget.songs.isEmpty ? _buildEmptyState() : _buildSongList(),
                const SizedBox(height: 8),
                _buildLocalUploadButton(),
                const SizedBox(height: 8),
                _buildFooterText(),
                if (widget.broadcastOn) ...[
                  const SizedBox(height: 8),
                  _buildBottomBroadcastBanner(),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Music',
                style: TextStyle(
                  color: _gold,
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.3,
                  height: 1.05,
                ),
              ),
              const SizedBox(height: 4),
              // FIX 20 (fix 15): the underline caps at 150 but
              // shrinks with the column — the RJ Panel pill takes
              // header space, and a fixed 150 would overflow.
              Container(
                height: 1.5,
                width: double.infinity,
                constraints: const BoxConstraints(maxWidth: 150),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      _gold.withAlpha(220),
                      _gold.withAlpha(0),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        // FIX 20 (fix 15): gold RJ Panel pill next to the gear,
        // hosts only (rjVisible). Tapping closes the Music sheet
        // first, then opens the RJ Studio console (mount wiring).
        if (widget.rjVisible)
          InkWell(
            onTap: widget.onRjPanel,
            borderRadius: BorderRadius.circular(20),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                border: Border.all(color: _gold, width: 1.2),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: const [
                  Icon(Icons.graphic_eq, color: _gold, size: 15),
                  SizedBox(width: 4),
                  Text(
                    'RJ Panel',
                    style: TextStyle(
                      color: _gold,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
          ),
        if (widget.rjVisible) const SizedBox(width: 10),
        // FIX 22 item 22: the Settings button is gone (see
        // onSettings removal above).
        _CircleBorderButton(
          icon: Icons.close,
          onTap: widget.onClose,
          gold: _gold,
          fill: _cardFill,
        ),
      ],
    );
  }

  Widget _buildBroadcastCard() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: _cardFill,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: _gold.withAlpha(widget.broadcastOn ? 220 : 120),
          width: 1.2,
        ),
        // FIX 2 (design): stronger gold glow when ON, as in the design.
        boxShadow: widget.broadcastOn
            ? [
                BoxShadow(
                  color: _gold.withAlpha(70),
                  blurRadius: 12,
                  spreadRadius: 0,
                ),
              ]
            : null,
      ),
      child: Row(
        children: [
          const Icon(
            Icons.sensors,
            color: _gold,
            size: 32,
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Broadcast My Music',
                  style: TextStyle(
                    color: _white,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  // FIX 22 item 21: hosting starts with GO LIVE
                  // in the RJ Studio panel — no switch here.
                  'Starts with GO LIVE in the RJ Studio panel.',
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: _mutedGrey,
                    fontSize: 11.5,
                    height: 1.25,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          // FIX 22 item 21: display-only status pill (was the
          // interactive _BroadcastPillToggle) — ON when live
          // is broadcasting, OFF otherwise. No tap action.
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: widget.broadcastOn ? _gold : const Color(0xFF1E293B),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: widget.broadcastOn ? _gold : _gold.withAlpha(120),
              ),
            ),
            child: Text(
              widget.broadcastOn ? 'ON' : 'OFF',
              style: TextStyle(
                color: widget.broadcastOn ? Colors.black : _mutedGrey,
                fontSize: 11.5,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNowPlayingStrip(LibrarySong song) {
    final String? status = song.statusLine;
    final bool hasStatus = status != null && status.isNotEmpty;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      decoration: BoxDecoration(
        color: _cardFill,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _gold.withAlpha(185), width: 1.2),
        // FIX 2 (design): stronger gold glow on the now-playing strip.
        boxShadow: [
          BoxShadow(
            color: _gold.withAlpha(70),
            blurRadius: 12,
            spreadRadius: 0,
          ),
        ],
      ),
      child: Row(
        children: [
          const _VinylThumb(size: 46, gold: _gold, showGlow: true),
          const SizedBox(width: 10),
          // FIX 2: tapping the strip's title/artist area opens the
          // player (same as the Open player button) — the buttons
          // stay separate siblings, so no gesture conflict.
          Expanded(
            child: InkWell(
              onTap: widget.onOpenPlayer,
              borderRadius: BorderRadius.circular(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    song.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: _white,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    song.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: _gold,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (hasStatus) ...[
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        const Icon(
                          Icons.equalizer,
                          color: _gold,
                          size: 13,
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            status,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: _gold,
                              fontSize: 10.5,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(width: 6),
          Container(
            width: 1,
            height: 36,
            color: _gold.withAlpha(65),
          ),
          const SizedBox(width: 8),
          InkWell(
            onTap: widget.onOpenPlayer,
            borderRadius: BorderRadius.circular(10),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
              decoration: BoxDecoration(
                color: _cardFill,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: _gold, width: 1.2),
              ),
              child: const Text(
                'Open\nplayer',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: _gold,
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  height: 1.1,
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          InkWell(
            onTap: widget.onPauseResume,
            customBorder: const CircleBorder(),
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _cardFill,
                border: Border.all(color: _gold, width: 1.6),
                boxShadow: [
                  BoxShadow(
                    color: _gold.withAlpha(45),
                    blurRadius: 8,
                    spreadRadius: 0,
                  ),
                ],
              ),
              child: Icon(
                widget.nowPlayingPaused ? Icons.play_arrow : Icons.pause,
                color: _gold,
                size: 20,
              ),
            ),
          ),
          const SizedBox(width: 6),
          InkWell(
            onTap: widget.onStop,
            customBorder: const CircleBorder(),
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _red,
                boxShadow: [
                  BoxShadow(
                    color: _red.withAlpha(90),
                    blurRadius: 8,
                    spreadRadius: 0,
                  ),
                ],
              ),
              child: const Icon(
                Icons.stop,
                color: _white,
                size: 20,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTabs() {
    return Row(
      children: [
        Expanded(
          child: _TabButton(
            label: 'Local Music',
            icon: Icons.music_note,
            active: widget.selectedTab == 0,
            gold: _gold,
            onTap: () => widget.onTabChanged(0),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _TabButton(
            label: 'My Playlist',
            icon: Icons.star_border,
            activeIcon: Icons.star,
            active: widget.selectedTab == 1,
            gold: _gold,
            onTap: () => widget.onTabChanged(1),
          ),
        ),
      ],
    );
  }

  Widget _buildSearchField() {
    return TextField(
      controller: _searchController,
      onChanged: widget.onSearchChanged,
      style: const TextStyle(color: _white, fontSize: 13.5),
      cursorColor: _gold,
      decoration: InputDecoration(
        isDense: true,
        filled: true,
        fillColor: _cardFill,
        hintText: 'Search for songs or artists',
        hintStyle: const TextStyle(color: _mutedGrey, fontSize: 13.5),
        prefixIcon: const Icon(
          Icons.search,
          color: _white,
          size: 21,
        ),
        suffixIcon: widget.searchQuery.isNotEmpty
            ? IconButton(
                icon: const Icon(Icons.close, color: _mutedGrey, size: 17),
                onPressed: () {
                  _searchController.clear();
                  widget.onSearchChanged('');
                },
                splashRadius: 16,
              )
            : null,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(24),
          borderSide: BorderSide(color: _gold.withAlpha(80), width: 1),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(24),
          borderSide: BorderSide(color: _gold.withAlpha(80), width: 1),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(24),
          borderSide: const BorderSide(color: _gold, width: 1.3),
        ),
      ),
    );
  }

  Widget _buildCountRow() {
    return Row(
      children: [
        Text(
          'All: ${widget.songs.length}',
          style: const TextStyle(
            color: _white,
            fontSize: 13.5,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(width: 10),
        Container(
          width: 1,
          height: 12,
          color: _gold.withAlpha(90),
        ),
        const SizedBox(width: 10),
        const Expanded(
          child: Text(
            'Session library — your uploaded songs',
            textAlign: TextAlign.right,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: _mutedGrey,
              fontSize: 11.5,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildEmptyState() {
    final String message = widget.selectedTab == 0
        ? 'No songs yet — use Local Upload below.'
        : 'My Playlist is empty — tap the bookmark on any song.';

    // FIX 2: padded (no Expanded parent any more — the panel
    // scrolls, so the empty message sits under the count row).
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
      child: Text(
        message,
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: _mutedGrey,
          fontSize: 13,
          height: 1.4,
        ),
      ),
    );
  }

  Widget _buildSongList() {
    // FIX 2: shrink-wrapped inside the panel's scroll view (see
    // build) — the list takes only the height its songs need.
    return ListView.separated(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: widget.songs.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final LibrarySong song = widget.songs[index];
        return _buildSongCard(song);
      },
    );
  }

  Widget _buildSongCard(LibrarySong song) {
    final bool showStatus =
        song.isPlaying && song.statusLine != null && song.statusLine!.isNotEmpty;
    final bool showPauseIcon = song.isPlaying && !song.isPaused;

    return Container(
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 13),
      decoration: BoxDecoration(
        color: _cardFill,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: song.isPlaying ? _gold : _gold.withAlpha(95),
          width: song.isPlaying ? 1.8 : 1.0,
        ),
        // FIX 2 (design): the playing card glows bright gold, as in
        // the design — the strongest glow on the panel.
        boxShadow: song.isPlaying
            ? [
                BoxShadow(
                  color: _gold.withAlpha(140),
                  blurRadius: 16,
                  spreadRadius: 1,
                ),
              ]
            : null,
      ),
      child: Row(
        children: [
          Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.bottomCenter,
            children: [
              _VinylThumb(
                size: 46,
                gold: _gold,
                showGlow: song.isPlaying,
              ),
              if (song.duration != null)
                Positioned(
                  bottom: -6,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 1.5,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: _gold.withAlpha(185),
                        width: 0.9,
                      ),
                    ),
                    child: Text(
                      _formatDuration(song.duration!),
                      style: const TextStyle(
                        color: _gold,
                        fontSize: 9.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  song.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: _white,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                // FIX 2 (design): the song-card artist is white in
                // the design (gold is only the strip + status line).
                Text(
                  song.artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: _white,
                    fontSize: 12.5,
                  ),
                ),
                if (showStatus) ...[
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      const Icon(
                        Icons.equalizer,
                        color: _gold,
                        size: 13,
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          song.statusLine!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: _gold,
                            fontSize: 10.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 6),
          _ActionIconTap(
            icon: song.inPlaylist ? Icons.bookmark : Icons.bookmark_border,
            color: _gold,
            onTap: () => widget.onToggleBookmark(song.key),
          ),
          _VerticalDivider(color: _gold.withAlpha(70)),
          if (!song.isTone) ...[
            _ActionIconTap(
              icon: Icons.edit_outlined,
              color: _gold,
              onTap: () => widget.onEditSong(song.key),
            ),
            _VerticalDivider(color: _gold.withAlpha(70)),
          ],
          const SizedBox(width: 4),
          InkWell(
            onTap: song.isPlaying
                ? widget.onPauseResume
                : () => widget.onPlaySong(song.key),
            customBorder: const CircleBorder(),
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: _gold,
                shape: BoxShape.circle,
                boxShadow: song.isPlaying
                    ? [
                        BoxShadow(
                          color: _gold.withAlpha(80),
                          blurRadius: 8,
                        ),
                      ]
                    : null,
              ),
              child: Icon(
                showPauseIcon ? Icons.pause : Icons.play_arrow,
                color: Colors.black,
                size: 21,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLocalUploadButton() {
    // FIX 2 (design): the upload button glows gold like the design's
    // luminous button (gold only — no new color).
    return Container(
      width: double.infinity,
      height: 46,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: _gold.withAlpha(90),
            blurRadius: 14,
            spreadRadius: 0,
          ),
        ],
      ),
      child: ElevatedButton.icon(
        onPressed: widget.onUpload,
        style: ElevatedButton.styleFrom(
          backgroundColor: _gold,
          foregroundColor: Colors.black,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        icon: const Icon(
          Icons.file_upload_outlined,
          size: 22,
          color: Colors.black,
        ),
        label: const Text(
          'Local Upload',
          style: TextStyle(
            color: Colors.black,
            fontSize: 15.5,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }

  Widget _buildFooterText() {
    return const Text(
      'Your own audio files from this phone (MP3, WAV, M4A, AAC, OGG, FLAC). No downloads, nothing paid.',
      textAlign: TextAlign.center,
      style: TextStyle(
        color: _mutedGrey,
        fontSize: 11,
        height: 1.3,
      ),
    );
  }

  Widget _buildBottomBroadcastBanner() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: _cardFill,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: _gold.withAlpha(150), width: 1),
      ),
      child: const Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.sensors, color: _gold, size: 18),
          SizedBox(width: 8),
          Flexible(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: 'Broadcast ON:',
                    style: TextStyle(
                      color: _gold,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  TextSpan(
                    text: ' shares with the room even when mic is muted.',
                    style: TextStyle(
                      color: _white,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ],
              ),
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11.5, height: 1.25),
            ),
          ),
        ],
      ),
    );
  }
}

class _CircleBorderButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final Color gold;
  final Color fill;

  const _CircleBorderButton({
    required this.icon,
    required this.onTap,
    required this.gold,
    required this.fill,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: fill,
          shape: BoxShape.circle,
          border: Border.all(color: gold.withAlpha(180), width: 1.2),
        ),
        child: Icon(icon, color: gold, size: 20),
      ),
    );
  }
}


class _TabButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final IconData? activeIcon;
  final bool active;
  final Color gold;
  final VoidCallback onTap;

  const _TabButton({
    required this.label,
    required this.icon,
    this.activeIcon,
    required this.active,
    required this.gold,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final Color foreground = active ? Colors.black : gold;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        decoration: BoxDecoration(
          color: active ? gold : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: gold, width: 1.2),
          // FIX 2 (design): the active tab glows brighter gold.
          boxShadow: active
              ? [
                  BoxShadow(
                    color: gold.withAlpha(110),
                    blurRadius: 12,
                  ),
                ]
              : null,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              active ? (activeIcon ?? icon) : icon,
              size: 18,
              color: foreground,
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: foreground,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _VinylThumb extends StatelessWidget {
  final double size;
  final Color gold;
  final bool showGlow;

  const _VinylThumb({
    required this.size,
    required this.gold,
    this.showGlow = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const SweepGradient(
          colors: [
            Color(0xFF0A0A0A),
            Color(0xFF2B2B2B),
            Color(0xFF0A0A0A),
            Color(0xFF262626),
            Color(0xFF0A0A0A),
          ],
        ),
        border: Border.all(color: gold, width: 1.8),
        // FIX 2 (design): the playing vinyl's gold halo is brighter.
        boxShadow: showGlow
            ? [
                BoxShadow(
                  color: gold.withAlpha(130),
                  blurRadius: 10,
                ),
              ]
            : null,
      ),
      child: Center(
        child: Container(
          width: size * 0.66,
          height: size * 0.66,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: gold.withAlpha(60), width: 0.8),
          ),
          child: Center(
            child: Container(
              width: size * 0.34,
              height: size * 0.34,
              decoration: BoxDecoration(
                color: gold,
                shape: BoxShape.circle,
              ),
              child: Center(
                child: Container(
                  width: size * 0.11,
                  height: size * 0.11,
                  decoration: const BoxDecoration(
                    color: Colors.black,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _VerticalDivider extends StatelessWidget {
  final Color color;

  const _VerticalDivider({required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 22,
      margin: const EdgeInsets.symmetric(horizontal: 2),
      color: color,
    );
  }
}

class _ActionIconTap extends StatelessWidget {
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const _ActionIconTap({
    required this.icon,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: SizedBox(
        width: 30,
        height: 30,
        child: Icon(icon, color: color, size: 20),
      ),
    );
  }
}
