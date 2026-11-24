import 'dart:math';

import 'package:protournament_user/platform/core/tournament_enums.dart';

/// Team allocation into match slots (ChatGPT blueprint §5-3; backend
/// guide §5-3 `match_teams` table + `allocate_teams` RPC).
///
/// PURE + DETERMINISTIC: no I/O, no state, no clock. The same inputs
/// always produce the same slots (random allocation is seeded when
/// [randomSeed] is given, so tests and re-runs reproduce it).
///
/// Slots are 1-based. `seed` on a slot is the team's seed number
/// when one was supplied (seeded method); otherwise null.
///
/// INTERIM — LOCAL ONLY: allocations are computed here and held in
/// the allocation page's state (saved to the local store by the
/// page). The backend `match_teams` table + `allocate_teams` RPC
/// (with audit-logged manual override) are the eventual home.

class AllocatedSlot {
  final String teamId;
  final int slot;
  final int? seed;

  const AllocatedSlot({required this.teamId, required this.slot, this.seed});

  AllocatedSlot copyWith({String? teamId, int? slot, int? seed}) =>
      AllocatedSlot(
        teamId: teamId ?? this.teamId,
        slot: slot ?? this.slot,
        seed: seed ?? this.seed,
      );

  factory AllocatedSlot.fromMap(Map<String, dynamic> map) => AllocatedSlot(
        teamId: (map['team_id'] ?? map['teamId'] ?? '').toString(),
        slot: (map['slot'] as num?)?.toInt() ?? 0,
        seed: (map['seed'] as num?)?.toInt(),
      );

  Map<String, dynamic> toMap() => {
        'team_id': teamId,
        'slot': slot,
        'seed': seed,
      };
}

/// Allocates [teamIds] into slots 1..n by [method]:
/// * [TeamAllocationMode.random] — shuffled; deterministic when
///   [randomSeed] is given.
/// * [TeamAllocationMode.seeded] — by [seeds] ascending (seed 1 =
///   slot 1); teams without a seed go last, in input order.
/// * [TeamAllocationMode.countryBased] — grouped by [teamCountries]
///   and spread round-robin across slots, so teams from the same
///   country land as far apart as possible.
/// * [TeamAllocationMode.performanceBased] — by [teamRatings]
///   descending (highest rated = slot 1); missing rating counts as
///   0; ties keep input order.
/// * [TeamAllocationMode.manual] — input order = slot order.
List<AllocatedSlot> allocateTeams({
  required List<String> teamIds,
  required TeamAllocationMode method,
  Map<String, int>? seeds,
  Map<String, String>? teamCountries,
  Map<String, int>? teamRatings,
  int? randomSeed,
}) {
  final ordered = List<String>.of(teamIds);
  switch (method) {
    case TeamAllocationMode.random:
      ordered.shuffle(Random(randomSeed));
    case TeamAllocationMode.seeded:
      ordered.sort((a, b) {
        final sa = seeds?[a];
        final sb = seeds?[b];
        if (sa == null && sb == null) return 0;
        if (sa == null) return 1;
        if (sb == null) return -1;
        return sa.compareTo(sb);
      });
    case TeamAllocationMode.countryBased:
      ordered
        ..clear()
        ..addAll(_spreadByCountry(teamIds, teamCountries ?? const {}));
    case TeamAllocationMode.performanceBased:
      ordered.sort((a, b) {
        final ra = teamRatings?[a] ?? 0;
        final rb = teamRatings?[b] ?? 0;
        return rb.compareTo(ra); // Descending; stable sort keeps ties.
      });
    case TeamAllocationMode.manual:
      break; // Input order = slot order.
  }
  return [
    for (var i = 0; i < ordered.length; i++)
      AllocatedSlot(
        teamId: ordered[i],
        slot: i + 1,
        seed: seeds?[ordered[i]],
      ),
  ];
}

/// Round-robin spread: groups keep input order; groups are visited
/// in order of first appearance, one team per group per round, so
/// same-country teams are spread across the slot list.
List<String> _spreadByCountry(
    List<String> teamIds, Map<String, String> teamCountries) {
  final groups = <String, List<String>>{};
  final groupOrder = <String>[];
  for (final teamId in teamIds) {
    final country = (teamCountries[teamId] ?? '').trim().toUpperCase();
    final key = country.isEmpty ? '' : country;
    if (!groups.containsKey(key)) {
      groups[key] = [];
      groupOrder.add(key);
    }
    groups[key]!.add(teamId);
  }
  final out = <String>[];
  var index = 0;
  var placed = true;
  while (placed) {
    placed = false;
    for (final key in groupOrder) {
      final group = groups[key]!;
      if (index < group.length) {
        out.add(group[index]);
        placed = true;
      }
    }
    index++;
  }
  return out;
}

/// Manual override (admin re-seed): moves [teamId] to [newSlot] by
/// SWAPPING it with the team currently in that slot, so slot numbers
/// stay unique (1..n, no gaps, no duplicates). Out-of-range slots
/// are clamped to 1..n. Unknown team → returns the list unchanged
/// (new list instance, same contents).
List<AllocatedSlot> applyManualOverride(
    List<AllocatedSlot> slots, String teamId, int newSlot) {
  if (slots.isEmpty) return const [];
  final target = newSlot.clamp(1, slots.length);
  final current = slots.indexWhere((s) => s.teamId == teamId);
  if (current == -1) return List<AllocatedSlot>.of(slots);
  final occupant = slots.indexWhere((s) => s.slot == target);
  final out = List<AllocatedSlot>.of(slots);
  if (occupant == -1 || occupant == current) {
    out[current] = out[current].copyWith(slot: target);
    return out;
  }
  final currentSlot = out[current].slot;
  out[current] = out[current].copyWith(slot: target);
  out[occupant] = out[occupant].copyWith(slot: currentSlot);
  out.sort((a, b) => a.slot.compareTo(b.slot));
  return out;
}
