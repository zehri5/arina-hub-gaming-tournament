// FIX 16 — VOICE SETTINGS SHEET (user order 2026-11-23, voice call):
// the team chat's top-bar More button becomes Settings while the
// voice panel is open, and tapping it opens THIS sheet with ALL
// voice functions inside — Music, Voice Settings (room settings),
// RJ Studio (room host only: admin / team captain / community
// organizer — FIX 20 fix 7b) and Close voice. Music /
// Settings / RJ left the host card for this sheet; Close voice
// (the old bottom row's Close, removed by Fix 1) is reachable
// here again. No voice function is removed — only relocated.
//
// The sheet cannot call the room page directly (it opens from the
// chat header, one widget above the embedded panel), so the room
// state binds its real actions into a [VoicePanelController]
// (TeamChatPage owns one and passes it to UnifiedRoomPage). The
// sheet reads the controller at build time; the RJ row evaluates
// its visibility getter then, so a late admin load still shows.
import 'package:flutter/material.dart';

import '../theme.dart';

/// FIX 16: the bridge between the chat header's Settings sheet and
/// the embedded voice panel. The room state binds its real actions
/// ([bind] in initState, [unbind] in dispose); the sheet calls the
/// open/close methods. All callbacks are nullable — an unbound
/// controller is a safe no-op (full-page mode has no controller).
class VoicePanelController extends ChangeNotifier {
  VoidCallback? _onMusic;
  VoidCallback? _onRoomSettings;
  VoidCallback? _onRjConsole;
  VoidCallback? _onCloseVoice;
  // FIX 22 item 5: the embedded sidebar's Leave menu reaches
  // the room through this controller too (the parent pages hold
  // no room reference of their own). (Item 15 removed the
  // sidebar's Participants menu, so openParticipants is gone.)
  VoidCallback? _onLeaveVoice;
  ValueGetter<bool>? _rjVisible;
  // FIX 23 item 4: the FLATTENED room-settings rows, so the
  // community Settings sheet can reach each one directly
  // (Backgrounds / Frames / Participants / diagnostics / voice
  // test / Cheer) instead of opening _showRoomSettings as a
  // nested sheet. Same nullable no-op contract as the rest.
  VoidCallback? _onBackgrounds;
  VoidCallback? _onFrames;
  VoidCallback? _onParticipantsStatus;
  VoidCallback? _onVoiceDiagnostics;
  VoidCallback? _onVoiceTest;
  VoidCallback? _onCheer;

  /// Bind the panel's real actions. [rjVisible] is evaluated every
  /// time [showRj] is read (admin state loads async — never a
  /// snapshot taken at bind time).
  void bind({
    VoidCallback? onMusic,
    VoidCallback? onRoomSettings,
    VoidCallback? onRjConsole,
    VoidCallback? onCloseVoice,
    VoidCallback? onLeaveVoice,
    ValueGetter<bool>? rjVisible,
    VoidCallback? onBackgrounds,
    VoidCallback? onFrames,
    VoidCallback? onParticipantsStatus,
    VoidCallback? onVoiceDiagnostics,
    VoidCallback? onVoiceTest,
    VoidCallback? onCheer,
  }) {
    _onMusic = onMusic;
    _onRoomSettings = onRoomSettings;
    _onRjConsole = onRjConsole;
    _onCloseVoice = onCloseVoice;
    _onLeaveVoice = onLeaveVoice;
    _rjVisible = rjVisible;
    _onBackgrounds = onBackgrounds;
    _onFrames = onFrames;
    _onParticipantsStatus = onParticipantsStatus;
    _onVoiceDiagnostics = onVoiceDiagnostics;
    _onVoiceTest = onVoiceTest;
    _onCheer = onCheer;
    notifyListeners();
  }

  /// Drop all bindings (panel disposed). The sheet can no longer
  /// reach the panel — every action becomes a no-op.
  void unbind() {
    _onMusic = null;
    _onRoomSettings = null;
    _onRjConsole = null;
    _onCloseVoice = null;
    _onLeaveVoice = null;
    _rjVisible = null;
    _onBackgrounds = null;
    _onFrames = null;
    _onParticipantsStatus = null;
    _onVoiceDiagnostics = null;
    _onVoiceTest = null;
    _onCheer = null;
    notifyListeners();
  }

  /// True while the RJ Studio row may show (room host only:
  /// admin / team captain / community organizer — FIX 20 fix 7b).
  bool get showRj => _rjVisible?.call() ?? false;

  /// True once the panel has bound at least one action.
  bool get isBound => _onMusic != null || _onRoomSettings != null || _onCloseVoice != null;

  void openMusic() => _onMusic?.call();
  void openRoomSettings() => _onRoomSettings?.call();
  void openRjConsole() => _onRjConsole?.call();
  void closeVoice() => _onCloseVoice?.call();
  void leaveVoice() => _onLeaveVoice?.call();
  // FIX 23 item 4: the flattened room-settings actions.
  void openBackgrounds() => _onBackgrounds?.call();
  void openFrames() => _onFrames?.call();
  void openParticipantsStatus() => _onParticipantsStatus?.call();
  void showVoiceDiagnostics() => _onVoiceDiagnostics?.call();
  void showVoiceTest() => _onVoiceTest?.call();
  void sendCheer() => _onCheer?.call();
}

/// FIX 16: the voice settings sheet — every voice function in one
/// place. Each row pops the sheet first, then runs its action (the
/// music / settings / RJ actions open their own sheets, and Close
/// voice unmounts the panel — none of them may stack on top of
/// this sheet).
class VoiceSettingsSheet extends StatelessWidget {
  final VoicePanelController controller;

  const VoiceSettingsSheet({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    // REDESIGN S7 (2026-11-23): the sheet's controls on the shared
    // F1 tokens — same rows, same bindings, same pop-then-run
    // behaviour; only spacing, radii and text styles tokenized.
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(kSpace20, kSpace12, kSpace20, kSpace20),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: kBorder,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: kSpace12),
              Row(
                children: [
                  Icon(Icons.settings, color: kGold, size: 22),
                  const SizedBox(width: kSpace8),
                  Text(
                    'Voice Settings',
                    style: kStyleCardTitle.copyWith(fontWeight: FontWeight.w900),
                  ),
                ],
              ),
              const SizedBox(height: kSpace12),
              _VoiceSettingsRow(
                icon: Icons.music_note,
                title: 'Music',
                subtitle: 'Play music in this room',
                onTap: () {
                  Navigator.pop(context);
                  controller.openMusic();
                },
              ),
              _VoiceSettingsRow(
                icon: Icons.settings,
                title: 'Room Settings',
                subtitle: 'Background, voice options and room controls',
                onTap: () {
                  Navigator.pop(context);
                  controller.openRoomSettings();
                },
              ),
              if (controller.showRj)
                _VoiceSettingsRow(
                  icon: Icons.graphic_eq,
                  title: 'RJ Studio',
                  subtitle: 'Live voice console (host only)',
                  onTap: () {
                    Navigator.pop(context);
                    controller.openRjConsole();
                  },
                ),
              Divider(color: kBorder, height: kSpace24),
              _VoiceSettingsRow(
                icon: Icons.close,
                title: 'Close voice',
                subtitle: 'Hide the voice panel and leave voice',
                destructive: true,
                onTap: () {
                  Navigator.pop(context);
                  controller.closeVoice();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _VoiceSettingsRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool destructive;
  final VoidCallback onTap;

  const _VoiceSettingsRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.destructive = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = destructive ? kLiveRed : kGold;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(kRadiusChip),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color.withValues(alpha: 0.12),
                border: Border.all(color: color.withValues(alpha: 0.4)),
              ),
              child: Icon(icon, color: color, size: 20),
            ),
            const SizedBox(width: kSpace12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: kStyleBody.copyWith(fontWeight: FontWeight.w800)),
                  const SizedBox(height: 2),
                  Text(subtitle, style: kStyleLabel),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: kMuted, size: 20),
          ],
        ),
      ),
    );
  }
}

/// FIX 16: opens the voice settings sheet (team chat header's
/// Settings button while the voice panel is open).
Future<void> showVoiceSettingsSheet(BuildContext context, VoicePanelController controller) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: kCardPurpleMid,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22)), side: const BorderSide(color: kCardPurpleBorder, width: 1.5)),
    builder: (_) => VoiceSettingsSheet(controller: controller),
  );
}

/// FIX 23 item 4 (user order 2026-11-23): the COMMUNITY room's
/// merged Settings sheet — the old top-bar More menu's entries
/// (About, Invite, Copy community name, Clear chat history,
/// Delete community, JOINED status) PLUS the flattened voice
/// rows (Music, Backgrounds, Frames, Participants / Status,
/// Voice diagnostics, Voice test (LiveKit), Cheer) PLUS My
/// Community (creator only, item 15) and RJ Studio (host only).
/// Follow/Unfollow is NOT here — it lives in the sidebar
/// Followers spot (item 9). No Close voice row (the host card
/// is sticky, item 16a — Leave Room in the sidebar leaves
/// voice). No Speaker row (speaker is permanently ON since
/// fix22 item 7). Each row pops the sheet first, then runs its
/// action (same pattern as [VoiceSettingsSheet]).
class CommunitySettingsSheet extends StatelessWidget {
  final VoicePanelController controller;
  final bool isMember;
  final bool isCreator;
  final VoidCallback onAbout;
  final VoidCallback onInvite;
  final VoidCallback onCopyName;
  final VoidCallback? onMyCommunity;
  final VoidCallback? onClearChat;
  final VoidCallback? onDeleteCommunity;

  const CommunitySettingsSheet({
    super.key,
    required this.controller,
    required this.isMember,
    required this.isCreator,
    required this.onAbout,
    required this.onInvite,
    required this.onCopyName,
    this.onMyCommunity,
    this.onClearChat,
    this.onDeleteCommunity,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(kSpace20, kSpace12, kSpace20, kSpace20),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: kBorder,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: kSpace12),
              Row(
                children: [
                  Icon(Icons.settings, color: kGold, size: 22),
                  const SizedBox(width: kSpace8),
                  Text(
                    'Settings',
                    style: kStyleCardTitle.copyWith(fontWeight: FontWeight.w900),
                  ),
                ],
              ),
              const SizedBox(height: kSpace12),
              Text('Community',
                  style: kStyleLabel.copyWith(
                      color: kGold, fontWeight: FontWeight.w900)),
              const SizedBox(height: kSpace8),
              if (isMember)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Row(
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: kGold.withValues(alpha: 0.12),
                          border: Border.all(
                              color: kGold.withValues(alpha: 0.4)),
                        ),
                        child: Icon(Icons.check_circle,
                            color: kGold, size: 20),
                      ),
                      const SizedBox(width: kSpace12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('JOINED',
                                style: kStyleBody.copyWith(
                                    color: kGold,
                                    fontWeight: FontWeight.w900)),
                            const SizedBox(height: 2),
                            Text('You are a member of this community',
                                style: kStyleLabel),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              _VoiceSettingsRow(
                icon: Icons.info_outline,
                title: 'About',
                subtitle: 'About this community',
                onTap: () {
                  Navigator.pop(context);
                  onAbout();
                },
              ),
              _VoiceSettingsRow(
                icon: Icons.person_add,
                title: 'Invite',
                subtitle: 'Invite players to this community',
                onTap: () {
                  Navigator.pop(context);
                  onInvite();
                },
              ),
              _VoiceSettingsRow(
                icon: Icons.copy,
                title: 'Copy community name',
                subtitle: 'Copy the name to the clipboard',
                onTap: () {
                  Navigator.pop(context);
                  onCopyName();
                },
              ),
              if (isCreator && onMyCommunity != null)
                _VoiceSettingsRow(
                  icon: Icons.group,
                  title: 'My Community',
                  subtitle: 'Photo, name, stats and members',
                  onTap: () {
                    Navigator.pop(context);
                    onMyCommunity!();
                  },
                ),
              if (onClearChat != null)
                _VoiceSettingsRow(
                  icon: Icons.delete_sweep,
                  title: 'Clear chat history',
                  subtitle: 'Delete all chat messages',
                  destructive: true,
                  onTap: () {
                    Navigator.pop(context);
                    onClearChat!();
                  },
                ),
              if (isCreator && onDeleteCommunity != null)
                _VoiceSettingsRow(
                  icon: Icons.delete_forever,
                  title: 'Delete community',
                  subtitle: 'Permanently delete this community',
                  destructive: true,
                  onTap: () {
                    Navigator.pop(context);
                    onDeleteCommunity!();
                  },
                ),
              Divider(color: kBorder, height: kSpace24),
              Text('Voice',
                  style: kStyleLabel.copyWith(
                      color: kGold, fontWeight: FontWeight.w900)),
              const SizedBox(height: kSpace8),
              _VoiceSettingsRow(
                icon: Icons.music_note,
                title: 'Music',
                subtitle: 'Play music in this room',
                onTap: () {
                  Navigator.pop(context);
                  controller.openMusic();
                },
              ),
              _VoiceSettingsRow(
                icon: Icons.wallpaper,
                title: 'Backgrounds',
                subtitle: 'Change the room background',
                onTap: () {
                  Navigator.pop(context);
                  controller.openBackgrounds();
                },
              ),
              _VoiceSettingsRow(
                icon: Icons.emoji_events,
                title: 'Frames',
                subtitle: 'Profile frames',
                onTap: () {
                  Navigator.pop(context);
                  controller.openFrames();
                },
              ),
              _VoiceSettingsRow(
                icon: Icons.people,
                title: 'Participants / Status',
                subtitle: 'Who is in the room',
                onTap: () {
                  Navigator.pop(context);
                  controller.openParticipantsStatus();
                },
              ),
              _VoiceSettingsRow(
                icon: Icons.bug_report,
                title: 'Voice diagnostics',
                subtitle: 'Connection details',
                onTap: () {
                  Navigator.pop(context);
                  controller.showVoiceDiagnostics();
                },
              ),
              _VoiceSettingsRow(
                icon: Icons.science,
                title: 'Voice test (LiveKit)',
                subtitle: 'Test the LiveKit voice engine',
                onTap: () {
                  Navigator.pop(context);
                  controller.showVoiceTest();
                },
              ),
              _VoiceSettingsRow(
                icon: Icons.celebration,
                title: 'Cheer (Free Points)',
                subtitle: 'Send a cheer to the host',
                onTap: () {
                  Navigator.pop(context);
                  controller.sendCheer();
                },
              ),
              if (controller.showRj)
                _VoiceSettingsRow(
                  icon: Icons.graphic_eq,
                  title: 'RJ Studio',
                  subtitle: 'Live voice console (host only)',
                  onTap: () {
                    Navigator.pop(context);
                    controller.openRjConsole();
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// FIX 23 item 4: opens the community Settings sheet (the
/// sidebar Settings entry in the community room).
Future<void> showCommunitySettingsSheet(
  BuildContext context,
  VoicePanelController controller, {
  required bool isMember,
  required bool isCreator,
  required VoidCallback onAbout,
  required VoidCallback onInvite,
  required VoidCallback onCopyName,
  VoidCallback? onMyCommunity,
  VoidCallback? onClearChat,
  VoidCallback? onDeleteCommunity,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: kCardPurpleMid,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22)), side: const BorderSide(color: kCardPurpleBorder, width: 1.5)),
    builder: (_) => CommunitySettingsSheet(
      controller: controller,
      isMember: isMember,
      isCreator: isCreator,
      onAbout: onAbout,
      onInvite: onInvite,
      onCopyName: onCopyName,
      onMyCommunity: onMyCommunity,
      onClearChat: onClearChat,
      onDeleteCommunity: onDeleteCommunity,
    ),
  );
}
