import 'dart:io';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../components/arena_components.dart';
import '../services/imgbb_service.dart';
import '../components/cached_image.dart';
import '../services/supabase_db.dart';
import '../utils.dart';
import 'frames_widgets.dart';

/// MISC (2026-11-20): section heading in the global style — small
/// caps, muted olive-gold kSectionLabel (same as MORE worker's
/// ACCOUNT EMAIL pattern).
Widget _sectionLabel(String text) => Text(
      text,
      style: const TextStyle(color: kSectionLabel, fontSize: 13, fontWeight: FontWeight.bold, letterSpacing: 1),
    );

/// FRAMES SHOP — professional layout, ORIGINAL design only (no copied
/// art, colours, or branding from any reference screenshot).
///   * Top: LARGE live preview of the SELECTED frame on the user's own
///     avatar, with a green "Active" pill when equipped. Permanent
///     frames show "Permanent" (there is no time-limited purchase in
///     this app — see below — so no remaining-time countdown exists).
///   * Two tabs: "Profile Frame" (this shop, fully implemented) and
///     "Profile Photo" (the user's photo via the existing gallery +
///     ImgBB upload flow, saved to the profile — not a new system).
///   * Horizontally scrollable CATEGORY chips: Obtained, Golds,
///     Diamonds, Activity Rewards, Game Rewards, Room Rewards.
///     Obtained is a FILTER (frames the user already owns), not a
///     stored category. Each category gets a section banner with its
///     name, then a 4-column grid of circular frames: padlock overlay
///     on locked (unowned) frames, green checkmark on the equipped one.
///   * Tapping a tile selects it (preview updates); Buy/Equip live
///     under the preview.
///
/// DURATION: not implemented as time-limited purchase. No 7-day price
/// was specified by the user or admin — inventing one would be a
/// business decision. Purchase is permanent ("Permanent" tag), the
/// migration has no expires_at column, and expired auto-unequip does
/// not apply. If a 7-day price is set later, add expires_at +
/// auto-unequip then.
///
/// Degrade gracefully: getFrames() returns [] if the list cannot be
/// loaded (query error) or the table is empty, and this page shows a
/// "No frames available yet" empty state. (Migration 004 IS applied
/// live — 13 frames rows verified 2026-11-19 — so an empty list here
/// no longer means "the update has not been applied".)
class FramesShopPage extends StatefulWidget {
  const FramesShopPage({super.key});
  @override
  State<FramesShopPage> createState() => _FramesShopPageState();
}

class _FramesShopPageState extends State<FramesShopPage> {
  int _nonce = 0;
  String? _selectedId;
  int _mainTab = 0; // 0 = Profile Frame, 1 = Profile Photo
  String _category = 'obtained';
  bool _photoBusy = false;
  void _refresh() => setState(() => _nonce++);

  static const List<Map<String, String>> _categories = [
    {'key': 'obtained', 'label': 'Obtained'},
    {'key': 'golds', 'label': 'Golds'},
    {'key': 'diamonds', 'label': 'Diamonds'},
    {'key': 'activity', 'label': 'Activity Rewards'},
    {'key': 'game', 'label': 'Game Rewards'},
    {'key': 'room', 'label': 'Room Rewards'},
  ];

  String _categoryLabel(String key) => _categories.firstWhere((c) => c['key'] == key, orElse: () => {'label': key})['label']!;

  Future<void> _buy(BuildContext context, Map<String, dynamic> frame) async {
    final uid = FirebaseAuth.instance.currentUser!.uid;
    final price = SupaDb.numOf(frame['price']);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kCardPurpleMid,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22), side: const BorderSide(color: kCardPurpleBorder, width: 1.5)),
        title: Text('Buy ${SupaDb.strOf(frame['name'], 'Frame')}?', style: TextStyle(color: kText)),
        content: Text(price <= 0 ? 'This frame is free and permanent.' : 'Price: Rs ${price.toStringAsFixed(2)} — permanent, not time-limited.\nDeducted from your spendable balance (deposit first, then winnings). Frames are cosmetic only.', style: TextStyle(color: kMuted)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('Cancel', style: TextStyle(color: kMuted))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text('Buy', style: TextStyle(color: kGold))),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    try {
      await SupaDb.buyFrame(uid, frame);
      FrameCache.invalidate(uid);
      if (context.mounted) toast(context, 'Frame purchased. Tap Equip to wear it.');
      _refresh();
    } catch (e) {
      if (context.mounted) toast(context, 'Buy failed: $e');
    }
  }

  Future<void> _equip(BuildContext context, String frameId) async {
    final uid = FirebaseAuth.instance.currentUser!.uid;
    try {
      await SupaDb.equipFrame(uid, frameId);
      FrameCache.invalidate(uid);
      if (context.mounted) toast(context, 'Frame equipped.');
      _refresh();
    } catch (e) {
      if (context.mounted) toast(context, 'Equip failed: $e');
    }
  }

  Future<void> _unequip(BuildContext context) async {
    final uid = FirebaseAuth.instance.currentUser!.uid;
    try {
      await SupaDb.unequipFrame(uid);
      FrameCache.invalidate(uid);
      if (context.mounted) toast(context, 'Frame removed.');
      _refresh();
    } catch (e) {
      if (context.mounted) toast(context, 'Failed: $e');
    }
  }

  Future<void> _changePhoto() async {
    final uid = FirebaseAuth.instance.currentUser!.uid;
    try {
      final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
      if (picked == null) return;
      setState(() => _photoBusy = true);
      final url = await ImgbbService.uploadImage(File(picked.path));
      await SupaDb.updateProfile(uid, {'photo_url': url});
      // ROUND 11: drop the cached photo so seats/strip/chat pick up
      // the new photo on their next build instead of the old one.
      PhotoCache.invalidate(uid);
      if (mounted) toast(context, 'Profile photo updated.');
      _refresh();
    } catch (e) {
      if (mounted) toast(context, 'Photo update failed: $e');
    } finally {
      if (mounted) setState(() => _photoBusy = false);
    }
  }

  Widget _tabButton(String label, int index) {
    final active = _mainTab == index;
    return Expanded(
      child: InkWell(
        onTap: () => setState(() => _mainTab = index),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          // PHASE E (E24, CORRECTED 2026-11-24): active tab is
          // gold-filled (Sameer: "click pe yellow hona
          // chahiye"); the rest are the card fill — never black.
          decoration: active
              ? BoxDecoration(
                  color: kGold,
                  borderRadius: BorderRadius.circular(10),
                )
              : cardFillDecoration(radius: 10).copyWith(
                  border: Border.all(color: kBorder, width: 1),
                ),
          alignment: Alignment.center,
          child: Text(label, style: TextStyle(color: active ? Colors.black : kText, fontWeight: FontWeight.bold, fontSize: 13)),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser!.uid;
    return Scaffold(
      appBar: AppBar(title: Text('Frames', style: TextStyle(color: kGold))),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        key: ValueKey(_nonce),
        future: SupaDb.getFrames(),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) return Center(child: CircularProgressIndicator(color: kGold));
          return FutureBuilder<List<Map<String, dynamic>>>(
            future: SupaDb.getUserFrames(uid),
            builder: (context, ownedSnap) {
              return FutureBuilder<Map<String, dynamic>>(
                future: SupaDb.getProfile(uid),
                builder: (context, profSnap) {
                  final all = snap.data ?? [];
                  final active = all.where((f) => f['active'] != false).toList();
                  final owned = ownedSnap.data ?? [];
                  final ownedIds = owned.map((r) => SupaDb.strOf(r['frame_id'])).toSet();
                  final equippedIds = owned.where((r) => r['is_equipped'] == true).map((r) => SupaDb.strOf(r['frame_id'])).toSet();
                  final profile = profSnap.data ?? {};
                  final userName = SupaDb.strOf(profile['displayName'], 'User');
                  final photo = SupaDb.strOf(profile['photoURL']);
                  final spendable = SupaDb.numOf(profile['depositBalance']) + SupaDb.numOf(profile['winningCash']);
                  if (all.isEmpty) {
                    return Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text('No frames available yet.\nCheck back after the next update.', textAlign: TextAlign.center, style: TextStyle(color: kMuted)),
                      ),
                    );
                  }
                  // ROUND 7 QA: the old body was a fixed Column with
                  // an Expanded grid inside it — on a short phone the
                  // preview + info + tabs ate the height, the grid was
                  // squeezed to almost nothing, and its labels clipped
                  // / collided (the "Obtained" frames in the video).
                  // Now the whole page scrolls and the grid sizes to
                  // its content, so nothing is ever squeezed.
                  return SingleChildScrollView(
                    child: Column(
                      children: [
                        // ---- BASIC INFO panel (video-shop layout, own
                      // wording): who you are, what you wear, what you
                      // own, what you can spend — above the tabs.
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                        // MISC (2026-11-20): MockupCard — global
                        // 2-shine card style instead of the full
                        // gold-tinted border.
                        child: MockupCard(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _sectionLabel('BASIC INFO'),
                              const SizedBox(height: 4),
                              Text(userName, style: TextStyle(color: kText, fontWeight: FontWeight.bold), maxLines: 1, overflow: TextOverflow.ellipsis),
                              Text('Equipped: ${equippedIds.isEmpty ? 'No frame' : active.firstWhere((f) => equippedIds.contains(SupaDb.strOf(f['id'])), orElse: () => {'name': 'Frame'})['name']} • Owned: ${ownedIds.length} • Frames in shop: ${active.length}', style: TextStyle(color: kMuted, fontSize: 12)),
                              Text('Spendable balance: Rs ${spendable.toStringAsFixed(2)}', style: TextStyle(color: kMuted, fontSize: 12)),
                            ],
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                        child: Row(
                          children: [
                            _tabButton('Profile Frame', 0),
                            const SizedBox(width: 8),
                            _tabButton('Profile Photo', 1),
                          ],
                        ),
                      ),
                      if (_mainTab == 1) ...[
                        const SizedBox(height: 24),
                        ArenaCachedAvatar(photoUrl: photo, radius: 64, backgroundColor: kGold, fallback: Icon(Icons.person, size: 64, color: Colors.black)),
                        const SizedBox(height: 12),
                        Text(userName, style: TextStyle(color: kText, fontWeight: FontWeight.bold, fontSize: 17)),
                        Text('Your profile photo (from gallery via ImgBB).', style: TextStyle(color: kMuted, fontSize: 12)),
                        const SizedBox(height: 16),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          // MISC (2026-11-20): shared primary button
                          // (mockup pill + spinner while busy).
                          child: goldButton(label: 'Change Photo', onPressed: _photoBusy ? null : _changePhoto, busy: _photoBusy),
                        ),
                      ] else ...[
                        // ---- LARGE PREVIEW (top) ----
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                          // MISC (2026-11-20): preview in a MockupCard
                          // — global 2-shine card style.
                          child: MockupCard(
                            child: _PreviewArea(
                            userName: userName,
                            photo: photo,
                            spendable: spendable,
                            active: active,
                            ownedIds: ownedIds,
                            equippedIds: equippedIds,
                            selectedId: _selectedId,
                            onSelect: (id) => setState(() => _selectedId = id),
                            onBuy: (f) => _buy(context, f),
                            onEquip: (id) => _equip(context, id),
                            onUnequip: () => _unequip(context),
                            ),
                          ),
                        ),
                        // ---- CATEGORY CHIPS (horizontal scroll) ----
                        SizedBox(
                          height: 38,
                          child: ListView.separated(
                            scrollDirection: Axis.horizontal,
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            separatorBuilder: (_, __) => const SizedBox(width: 8),
                            itemCount: _categories.length,
                            itemBuilder: (_, i) {
                              final c = _categories[i];
                              final sel = _category == c['key'];
                              return InkWell(
                                onTap: () => setState(() => _category = c['key']!),
                                borderRadius: BorderRadius.circular(16),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                                  // PHASE E (E24, CORRECTED
                                  // 2026-11-24): selected chip is
                                  // gold-filled; the rest are the
                                  // card fill — never black.
                                  decoration: sel
                                      ? BoxDecoration(
                                          color: kGold,
                                          borderRadius:
                                              BorderRadius.circular(16),
                                        )
                                      : cardFillDecoration(radius: 16)
                                          .copyWith(
                                          border: Border.all(
                                              color: kBorder, width: 1),
                                        ),
                                  alignment: Alignment.center,
                                  child: Text(c['label']!, style: TextStyle(color: sel ? Colors.black : kText, fontWeight: FontWeight.bold, fontSize: 12)),
                                ),
                              );
                            },
                          ),
                        ),
                        const SizedBox(height: 8),
                        // ---- SECTION BANNER + 4-COLUMN GRID ----
                        _CategoryGrid(
                          categoryKey: _category,
                          categoryLabel: _categoryLabel(_category),
                          allFrames: all,
                          active: active,
                          owned: owned,
                          ownedIds: ownedIds,
                          equippedIds: equippedIds,
                          userName: userName,
                          photo: photo,
                          selectedId: _selectedId,
                          onSelect: (id) => setState(() => _selectedId = id),
                        ),
                      ],
                      Padding(
                        padding: EdgeInsets.only(top: 8, bottom: 12),
                        child: Text('Frames are cosmetic only — they never affect tournaments, joins, or winnings.', style: TextStyle(color: kMuted, fontSize: 12)),
                      ),
                      ],
                    ),
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}

class _PreviewArea extends StatelessWidget {
  final String userName;
  final String photo;
  final double spendable;
  final List<Map<String, dynamic>> active;
  final Set<String> ownedIds;
  final Set<String> equippedIds;
  final String? selectedId;
  final void Function(String) onSelect;
  final void Function(Map<String, dynamic>) onBuy;
  final void Function(String) onEquip;
  final VoidCallback onUnequip;
  const _PreviewArea({required this.userName, required this.photo, required this.spendable, required this.active, required this.ownedIds, required this.equippedIds, required this.selectedId, required this.onSelect, required this.onBuy, required this.onEquip, required this.onUnequip});

  @override
  Widget build(BuildContext context) {
    // D3: `active` can be empty while `all` is not (every frame
    // deactivated) — the old code called active.first below and
    // threw. Show the honest empty state instead of crashing.
    if (active.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 16),
        child: Text(
          'No active frames right now.\nCheck back after the next update.',
          textAlign: TextAlign.center,
          style: TextStyle(color: kMuted),
        ),
      );
    }
    final Map<String, dynamic> selected = active.firstWhere(
      (f) => SupaDb.strOf(f['id']) == selectedId,
      orElse: () => active.firstWhere((f) => equippedIds.contains(SupaDb.strOf(f['id'])), orElse: () => active.first),
    );
    final selId = SupaDb.strOf(selected['id']);
    final selectedOwned = ownedIds.contains(selId);
    final selectedEquipped = equippedIds.contains(selId);
    final selectedPrice = SupaDb.numOf(selected['price']);
    return Column(
      children: [
        Stack(
          clipBehavior: Clip.none,
          children: [
            FramedAvatar(name: userName, frame: selected, radius: 56, photoUrl: photo),
            if (selectedEquipped)
              Positioned(
                bottom: -6,
                left: 0,
                right: 0,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                    decoration: BoxDecoration(color: Colors.greenAccent, borderRadius: BorderRadius.circular(12)),
                    child: const Text('Active', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 11)),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 18),
        Text(userName, style: TextStyle(color: kText, fontWeight: FontWeight.bold, fontSize: 17), maxLines: 1, overflow: TextOverflow.ellipsis),
        Text('${SupaDb.strOf(selected['name'], 'Frame')} • ${frameStyleOf(SupaDb.strOf(selected['style_preset'], 'gold_royal')).label} • Permanent', style: TextStyle(color: kMuted, fontSize: 12)),
        Text('Spendable balance: Rs ${spendable.toStringAsFixed(2)}', style: TextStyle(color: kMuted, fontSize: 12)),
        const SizedBox(height: 10),
        if (selectedEquipped)
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text('Equipped', style: TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold)),
              const SizedBox(width: 12),
              TextButton(onPressed: onUnequip, child: Text('Remove', style: TextStyle(color: kGold))),
            ],
          )
        else if (selectedOwned)
          // MISC (2026-11-20): shared primary button (mockup pill).
          GoldButton(label: 'Equip', onPressed: () => onEquip(selId), fullWidth: false)
        else
          GoldButton(
            label: selectedPrice <= 0 ? 'Get Free' : 'Buy • Rs ${selectedPrice.toStringAsFixed(2)}',
            onPressed: () => onBuy(selected),
            fullWidth: false,
          ),
      ],
    );
  }
}

class _CategoryGrid extends StatelessWidget {
  final String categoryKey;
  final String categoryLabel;
  final List<Map<String, dynamic>> allFrames;
  final List<Map<String, dynamic>> active;
  final List<Map<String, dynamic>> owned;
  final Set<String> ownedIds;
  final Set<String> equippedIds;
  final String userName;
  final String photo;
  final String? selectedId;
  final void Function(String) onSelect;
  const _CategoryGrid({required this.categoryKey, required this.categoryLabel, required this.allFrames, required this.active, required this.owned, required this.ownedIds, required this.equippedIds, required this.userName, required this.photo, required this.selectedId, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    // Obtained = owned frames only (including deactivated ones the user
    // keeps); other categories = active frames in that category.
    List<Map<String, dynamic>> items;
    if (categoryKey == 'obtained') {
      // Owned frames only, INCLUDING deactivated ones the user keeps
      // (getFrames returns all frames, not just active ones, so the
      // lookup below covers them; other categories filter to active).
      final byId = {for (final f in allFrames) SupaDb.strOf(f['id']): f};
      items = [];
      for (final r in owned) {
        final f = byId[SupaDb.strOf(r['frame_id'])];
        if (f != null) items.add(f);
      }
    } else {
      items = active.where((f) => SupaDb.strOf(f['category'], 'golds') == categoryKey).toList();
    }
    // ROUND 7 QA: no Expanded anywhere here — the grid sizes to its
    // content inside the page scroll. Cells are taller (0.62, not
    // 0.78): a 4-col cell on a 360px phone is ~76px wide, and avatar
    // 52 + name + price + 'Permanent' + padding needs ~115px tall,
    // so 0.78 (~98px) clipped the labels — the video's truncated /
    // overlapping grid labels. Empty state gets a real 140px box
    // instead of a squeezed Center that collided with the banner.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // MISC (2026-11-20): plain kSectionLabel heading — the
        // filled strip is gone (global heading style).
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: _sectionLabel(categoryLabel.toUpperCase()),
        ),
        items.isEmpty
            ? SizedBox(height: 140, child: Center(child: Text('No frames in $categoryLabel yet.', style: TextStyle(color: kMuted))))
            : GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                padding: const EdgeInsets.all(12),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 4, childAspectRatio: 0.62, mainAxisSpacing: 10, crossAxisSpacing: 10),
                    itemCount: items.length,
                    itemBuilder: (_, i) {
                      final f = items[i];
                      final fid = SupaDb.strOf(f['id']);
                      final isOwned = ownedIds.contains(fid);
                      final isEquipped = equippedIds.contains(fid);
                      final isSelected = fid == selectedId;
                      final price = SupaDb.numOf(f['price']);
                      return InkWell(
                        onTap: () => onSelect(fid),
                        borderRadius: BorderRadius.circular(12),
                        // MISC (2026-11-20): tiles keep their own
                        // border ON PURPOSE — the gold border is the
                        // SELECTED state (like the mockups' selected
                        // radio rows), not card decoration; the
                        // unselected border (kField) is effectively
                        // invisible. No MockupCard here: a grid of
                        // animated cards would be noise + a ticker
                        // per tile.
                        child: Container(
                          padding: const EdgeInsets.all(6),
                          // PHASE E (E24/update 11): the tile
                          // is a card surface — shared card fill,
                          // not the opaque kCard.
                          decoration: cardFillDecoration(radius: 12).copyWith(
                            border: Border.all(color: isSelected ? kGold : kField, width: isSelected ? 2 : 1),
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Stack(
                                clipBehavior: Clip.none,
                                children: [
                                  FramedAvatar(name: userName, frame: f, radius: 26, photoUrl: photo),
                                  if (!isOwned)
                                    Positioned.fill(
                                      child: Container(
                                        decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.black.withValues(alpha: 0.45)),
                                        child: const Icon(Icons.lock, color: Colors.white, size: 20),
                                      ),
                                    ),
                                  if (isEquipped)
                                    const Positioned(
                                      top: -2,
                                      right: -2,
                                      child: CircleAvatar(radius: 9, backgroundColor: Colors.greenAccent, child: Icon(Icons.check, color: Colors.black, size: 12)),
                                    ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Text(SupaDb.strOf(f['name'], 'Frame'), style: TextStyle(color: kText, fontSize: 11, fontWeight: FontWeight.bold), maxLines: 1, overflow: TextOverflow.ellipsis),
                              Text(price <= 0 ? 'Free' : 'Rs ${price.toStringAsFixed(0)}', style: TextStyle(color: kGold, fontSize: 11, fontWeight: FontWeight.bold)),
                              Text('Permanent', style: TextStyle(color: kMuted, fontSize: 10)),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
        ],
    );
  }
}
