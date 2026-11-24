import 'package:flutter/material.dart';

enum VoiceConnectionStatus { connected, reconnecting, disconnected }

enum SeatAccent { gold, cyan, pink, purple }

class VoiceSeatMember {
  final int seatNumber;
  final String? memberId;
  final String? name;
  final String? avatarAssetOrUrl;
  final bool isHost;
  final bool isVerified;
  final bool isMuted;
  final bool isSpeaking;
  final bool requestToSpeak;
  final SeatAccent accent;
  final int level;

  const VoiceSeatMember({
    required this.seatNumber,
    this.memberId,
    this.name,
    this.avatarAssetOrUrl,
    this.isHost = false,
    this.isVerified = false,
    this.isMuted = true,
    this.isSpeaking = false,
    this.requestToSpeak = false,
    this.accent = SeatAccent.cyan,
    this.level = 1,
  });

  bool get isOccupied => memberId != null;

  VoiceSeatMember copyWith({
    String? memberId,
    String? name,
    String? avatarAssetOrUrl,
    bool? isMuted,
    bool? isSpeaking,
    bool? requestToSpeak,
  }) {
    return VoiceSeatMember(
      seatNumber: seatNumber,
      memberId: memberId ?? this.memberId,
      name: name ?? this.name,
      avatarAssetOrUrl: avatarAssetOrUrl ?? this.avatarAssetOrUrl,
      isHost: isHost,
      isVerified: isVerified,
      isMuted: isMuted ?? this.isMuted,
      isSpeaking: isSpeaking ?? this.isSpeaking,
      requestToSpeak: requestToSpeak ?? this.requestToSpeak,
      accent: accent,
      level: level,
    );
  }
}

class ChatReaction {
  final String emoji;
  final int count;
  final bool userReacted;

  const ChatReaction({
    required this.emoji,
    required this.count,
    this.userReacted = false,
  });
}

class ArenaChatMessage {
  final String id;
  final String senderName;
  final String? avatarAssetOrUrl;
  final String initials;
  final String timestamp;
  final String text;
  final bool isHost;
  final bool isOwn;
  final bool isAnnouncement;
  final int? level;
  final List<ChatReaction> reactions;

  const ArenaChatMessage({
    required this.id,
    required this.senderName,
    this.avatarAssetOrUrl,
    required this.initials,
    required this.timestamp,
    required this.text,
    this.isHost = false,
    this.isOwn = false,
    this.isAnnouncement = false,
    this.level,
    this.reactions = const [],
  });
}
// FIX 31 — one extra row in the room menu (MoreActionsSheet):
// Power, Voice, Invite, Follow Host, Leave Voice, ... The room
// (UnifiedRoomPage) builds these from its real functions; the
// screen only renders them in-style, after Settings, before
// Leave Room. [visible] lets the room hide a row per scope/gate.
class ArenaMenuEntry {
  final IconData icon;
  final String label;
  final String? subtitle;
  final Color color;
  final VoidCallback? onTap;
  final bool visible;

  const ArenaMenuEntry({
    required this.icon,
    required this.label,
    this.subtitle,
    required this.color,
    this.onTap,
    this.visible = true,
  });
}
