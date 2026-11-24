// SQUAD REGISTRATION (#23) — regression tests for Sameer's live v2005
// report (voice call 2026-11-21 ~01:18, screenshot
// 1000049113_42_4g3e.jpg) + mockup same-to-same checks against his
// design screenshot 1000048256_43_mwt3.jpg (mockup #23).
//
// What v2005 showed (all four were live on his phone):
//   (a) only SQUAD MATE #2 visible — mates #3/#4 (and the slot
//       picker, rules checkbox and CONFIRM SQUAD button below them)
//       never appear; the page ends in black space.
//   (b) mate #2's card has NO dashed gold border and NO INVITE
//       TEAMMATE button — just a heading + two dark fields.
//   (c) a dark box with a white square outline (an unchecked
//       Material checkbox inside a card) overlaps the top-left of
//       the tournament banner.
//   (d) counter reads (0/4) while the leader's IGN "admin" is
//       filled — his game UID never auto-fills from the profile.
//
// The tests pump the REAL JoinTournamentPage at a real phone size
// (360x800) and prove all four slots render, are reachable by
// scrolling, and match the mockup element by element. No
// pumpAndSettle anywhere — MockupCard's shine controllers repeat
// forever (teams_fixes_test precedent); a few pump()s settle the
// frame. _load's Firebase/Supabase calls throw with no backend and
// are swallowed by its own try/catch, so the page renders with
// empty fields — exactly the state Sameer screenshotted.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/components/arena_components.dart';
import 'package:protournament_user/screens/home_screens.dart';
import 'package:protournament_user/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The "Pro Tour" squad tournament from Sameer's screenshot: 4-man
/// squad, Rs 1.00 per player -> Rs 4.00 team fee, 100 max players
/// (25 team slots), empty banner (fallback asset, no network).
Map<String, dynamic> _paidSquad() => {
      'id': 't-pro-tour',
      'name': 'Pro Tour',
      'mode': 'Squad',
      'gameName': 'PUBG Mobile',
      'status': 'upcoming',
      'startTime': DateTime(2026, 10, 28, 2, 59).millisecondsSinceEpoch,
      'entryFee': 1.0,
      'maxPlayers': 100,
      'banner': '',
    };

/// Same tournament, free entry — the mockup's FREE ENTRY case.
Map<String, dynamic> _freeSquad() => {..._paidSquad(), 'entryFee': 0.0};

/// 360x800 logical phone surface (home_vs_compact_fix_test pattern).
void _phoneSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _pumpSquad(WidgetTester tester, Map<String, dynamic> t) async {
  await tester.pumpWidget(MaterialApp(home: JoinTournamentPage(tournament: t)));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 100));
}

/// Scrolls the page until [finder] is visible. (scrollUntilVisible
/// cannot be used here: every TextField owns its own Scrollable, so
/// its default finder matches many; ensureVisible works from the
/// target's own Scrollable ancestor instead.)
Future<void> _scrollTo(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
}

/// The page's 9 TextFields in build order:
/// [0] Team Name (v2011: label-above, labelText null), [1] leader IGN,
/// [2] leader UID,
/// [3] mate#2 UID, [4] mate#2 Name, [5] mate#3 UID, [6] mate#3 Name,
/// [7] mate#4 UID, [8] mate#4 Name. The label-order test below pins
/// this map, so an index drift fails loudly instead of silently
/// typing into the wrong field.
List<TextField> _fields(WidgetTester tester) =>
    tester.widgetList<TextField>(find.byType(TextField)).toList();

Future<void> _enterAt(WidgetTester tester, int index, String value) async {
  await tester.enterText(find.byType(TextField).at(index), value);
  await tester.pump();
}

/// First bordered Container ancestor of [finder]'s widget (the card
/// wrapper), or null when the widget sits in a borderless card.
BoxDecoration? _cardDecoration(WidgetTester tester, Finder finder) {
  final containers = tester.widgetList<Container>(
    find.ancestor(of: finder, matching: find.byType(Container)),
  );
  for (final c in containers) {
    final d = c.decoration;
    if (d is BoxDecoration && d.border is Border) return d;
  }
  return null;
}

/// Finder for the bordered card wrapping [finder]'s widget — the
/// one ancestor Container whose decoration carries a Border
/// (exactly one for the squad leader / filled mate cards).
Finder _borderedCardFinder(Finder finder) => find.ancestor(
      of: finder,
      matching: find.byWidgetPredicate((w) =>
          w is Container &&
          w.decoration is BoxDecoration &&
          (w.decoration as BoxDecoration).border is Border),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  group('(a) all 4 slots render and are reachable by scrolling', () {
    testWidgets('leader + mates #2/#3/#4 + CONFIRM all render at 360x800',
        (tester) async {
      _phoneSurface(tester);
      await _pumpSquad(tester, _paidSquad());

      // Field map pin: 9 fields, labels in build order.
      // v2011: [0] Team Name is now a LABEL-ABOVE field (P2 redesign
      // per mockup #6 — the label is a separate Text above the box,
      // not the field's labelText), so its labelText is null; the
      // label itself is asserted below.
      expect(
        _fields(tester).map((f) => f.decoration?.labelText).toList(),
        [null, 'IGN', 'UID', 'UID', 'Name', 'UID', 'Name', 'UID', 'Name'],
      );
      expect(find.text('Team Name'), findsOneWidget);

      // First viewport: leader + mate #2 (what v2005 showed).
      expect(find.text('TEAM LEADER (YOU)'), findsOneWidget);
      expect(find.text('SQUAD MATE #2'), findsOneWidget);

      // Mates #3/#4: scroll them into the viewport and prove they
      // are really on screen, not just in the tree.
      await _scrollTo(tester, find.text('SQUAD MATE #3'));
      await tester.pump();
      expect(find.text('SQUAD MATE #3'), findsOneWidget);
      final rect3 = tester.getRect(find.text('SQUAD MATE #3'));
      expect(rect3.top, greaterThanOrEqualTo(0));
      expect(rect3.top, lessThan(800));

      await _scrollTo(tester, find.text('SQUAD MATE #4'));
      await tester.pump();
      expect(find.text('SQUAD MATE #4'), findsOneWidget);
      final rect4 = tester.getRect(find.text('SQUAD MATE #4'));
      expect(rect4.top, greaterThanOrEqualTo(0));
      expect(rect4.top, lessThan(800));

      // Everything below the mates is reachable too: slot picker,
      // rules checkbox and the CONFIRM SQUAD button.
      await _scrollTo(tester, find.text('Select Slot'));
      await tester.pump();
      expect(find.text('Select Slot'), findsOneWidget);
      await _scrollTo(tester, find.text('CONFIRM SQUAD'));
      await tester.pump();
      expect(find.text('CONFIRM SQUAD'), findsOneWidget);
      final rectBtn = tester.getRect(find.text('CONFIRM SQUAD'));
      expect(rectBtn.top, greaterThanOrEqualTo(0));
      expect(rectBtn.top, lessThan(800));

      // The page really scrolled: the banner is now above the fold.
      // v2011: 'SQUAD' renders twice now (banner mode pill + the
      // date-row mode text, per the registration-unify design) —
      // either one proves the banner scrolled away.
      expect(tester.getRect(find.text('SQUAD').first).top, lessThan(0));
    });
  });

  group('(b) empty mate cards: dashed border + INVITE TEAMMATE', () {
    testWidgets('all 3 empty mates get the dashed gold border + invite button',
        (tester) async {
      _phoneSurface(tester);
      await _pumpSquad(tester, _paidSquad());

      expect(find.byType(ArenaDashedBorder), findsNWidgets(3));
      expect(find.text('INVITE\nTEAMMATE'), findsNWidgets(3));
      expect(find.widgetWithText(ElevatedButton, 'INVITE\nTEAMMATE'),
          findsNWidgets(3));

      // The gold dash painter is really attached (not a plain box).
      // (Each TextField/Material also owns a CustomPaint for its
      // own border/shape — filter on the foreground painter, which
      // only the dashed border sets.)
      final paints = tester
          .widgetList<CustomPaint>(find.descendant(
            of: find.byType(ArenaDashedBorder),
            matching: find.byType(CustomPaint),
          ))
          .where((p) => p.foregroundPainter is ArenaDashedBorderPainter)
          .toList();
      expect(paints.length, 3);
      for (final p in paints) {
        expect((p.foregroundPainter as ArenaDashedBorderPainter).color,
            kGold);
      }
    });
  });

  group('(c) no stray widget overlaps the banner', () {
    testWidgets('exactly one checkbox on the page, below the banner',
        (tester) async {
      _phoneSurface(tester);
      await _pumpSquad(tester, _paidSquad());

      // The v2005 glitch was a checkbox-in-a-card over the banner.
      // The only checkbox this page owns is the rules tile, which
      // lives at the bottom of the form — never near the banner.
      expect(find.byType(CheckboxListTile), findsOneWidget);
      expect(find.byType(Checkbox), findsOneWidget);
      // v2011: 'SQUAD' renders twice now (banner mode pill + the
      // date-row mode text) — .last is the lower date-row tag, the
      // closest proxy for the banner's bottom edge.
      final bannerBottom =
          tester.getBottomLeft(find.text('SQUAD').last).dy; // banner mode tag
      final checkboxTop = tester.getTopLeft(find.byType(Checkbox)).dy;
      expect(checkboxTop, greaterThan(bannerBottom));
    });
  });

  group('(d) counter + leader UID', () {
    testWidgets('counter counts complete slots and updates as the leader types',
        (tester) async {
      _phoneSurface(tester);
      await _pumpSquad(tester, _paidSquad());

      expect(find.text('BUILD YOUR SQUAD (0/4)'), findsOneWidget);
      expect(find.text('PENDING'), findsOneWidget);
      expect(find.text('VALIDATED'), findsNothing);
      expect(find.byIcon(Icons.check_circle), findsNothing);

      // IGN only: a half-filled slot does NOT count.
      await _enterAt(tester, 1, 'admin');
      expect(find.text('BUILD YOUR SQUAD (0/4)'), findsOneWidget);

      // IGN + UID: the leader counts, live, with green ticks and
      // the VALIDATED pill. (v2005 never updated this: the leader
      // fields had no change listeners.) 3 check_circle icons: one
      // tick per field + the pill's own icon.
      await _enterAt(tester, 2, '5123948573');
      expect(find.text('BUILD YOUR SQUAD (1/4)'), findsOneWidget);
      expect(find.text('VALIDATED'), findsOneWidget);
      expect(find.text('PENDING'), findsNothing);
      expect(find.byIcon(Icons.check_circle), findsNWidgets(3));

      // A filled mate counts too.
      await _scrollTo(tester, find.text('SQUAD MATE #2'));
      await tester.pump();
      await _enterAt(tester, 3, '384910248');
      await _enterAt(tester, 4, 'Ghost_Rider');
      expect(find.text('BUILD YOUR SQUAD (2/4)'), findsOneWidget);
    });

    test('squadFilledCount counts complete slots only', () {
      expect(
          squadFilledCount(leaderFilled: false, matesFilled: const []), 0);
      expect(
          squadFilledCount(
              leaderFilled: false,
              matesFilled: const [false, false, false]),
          0);
      expect(
          squadFilledCount(
              leaderFilled: true, matesFilled: const [false, false, false]),
          1);
      expect(
          squadFilledCount(
              leaderFilled: true, matesFilled: const [true, false, true]),
          3);
      expect(
          squadFilledCount(
              leaderFilled: false, matesFilled: const [true, true, true]),
          3);
    });

    test('squadLeaderUidPrefill prefers the profile UID', () {
      expect(
        squadLeaderUidPrefill(
          profile: const {'gameUid': '5123948573'},
          tournamentRegs: const [
            {'firebase_uid': 'u1', 'game_uid': '111'},
          ],
          myRegs: const [
            {'game_uid': '222'},
          ],
          uid: 'u1',
        ),
        '5123948573',
      );
      // snake_case profile key works too (raw row, un-normalized).
      expect(
        squadLeaderUidPrefill(
          profile: const {'game_uid': '999'},
          tournamentRegs: const [],
          myRegs: const [],
          uid: 'u1',
        ),
        '999',
      );
    });

    test('squadLeaderUidPrefill falls back to the user registration rows',
        () {
      // This tournament's own row (repair / re-join) beats older rows.
      expect(
        squadLeaderUidPrefill(
          profile: const {},
          tournamentRegs: const [
            {'firebase_uid': 'other', 'game_uid': '000'},
            {'firebase_uid': 'u1', 'game_uid': '384910248'},
          ],
          myRegs: const [
            {'game_uid': '222'},
          ],
          uid: 'u1',
        ),
        '384910248',
      );
      // Otherwise the latest UID from any of the user's registrations.
      expect(
        squadLeaderUidPrefill(
          profile: const {},
          tournamentRegs: const [],
          myRegs: const [
            {'game_uid': '111'},
            {'game_uid': ''},
            {'game_uid': '492019384'},
          ],
          uid: 'u1',
        ),
        '492019384',
      );
      // Nothing saved anywhere: honestly empty, never invented.
      expect(
        squadLeaderUidPrefill(
          profile: const {},
          tournamentRegs: const [],
          myRegs: const [],
          uid: 'u1',
        ),
        '',
      );
    });
  });

  group('mockup #23 conformance', () {
    testWidgets('banner: title + date + SQUAD tag', (tester) async {
      _phoneSurface(tester);
      await _pumpSquad(tester, _paidSquad());
      // Two-tone title is one RichText ("Pro" gold + " Tour" white).
      expect(find.text('Pro Tour', findRichText: true), findsOneWidget);
      expect(find.text('Wed, Oct 28 • 2:59 AM'), findsOneWidget);
      // v2011: 'SQUAD' renders twice now — the banner mode pill
      // (new in the registration unify) + the date-row mode text
      // (pre-existing). Duo/Solo already showed the mode twice in
      // live v2010, so this is the unify design, not a bug.
      expect(find.text('SQUAD'), findsNWidgets(2));
    });

    testWidgets('counter row: WHITE title + real price pill (paid)',
        (tester) async {
      _phoneSurface(tester);
      await _pumpSquad(tester, _paidSquad());
      final counter =
          tester.widget<Text>(find.text('BUILD YOUR SQUAD (0/4)'));
      expect(counter.style?.color, Colors.white);
      // v2011: the fee pill renders twice by unify design — once in
      // the banner, once in the heading/counter row.
      expect(find.text('Rs 4.00'), findsNWidgets(2));
      // Paid tournaments show neither the free line nor a second fee
      // line — the price lives in the pill only.
      expect(find.text('This is a free community event.'), findsNothing);
      expect(find.text('Entry fee: Rs 4.00'), findsNothing);
    });

    testWidgets('counter row: FREE ENTRY pill + free line (free tournament)',
        (tester) async {
      _phoneSurface(tester);
      await _pumpSquad(tester, _freeSquad());
      // v2011: the FREE ENTRY pill renders twice by unify design —
      // once in the banner, once in the heading/counter row.
      expect(find.text('FREE ENTRY'), findsNWidgets(2));
      await _scrollTo(tester, find.text('This is a free community event.'));
      await tester.pump();
      expect(find.text('This is a free community event.'), findsOneWidget);
    });

    testWidgets('leader card: full gold border, crown, mockup height',
        (tester) async {
      _phoneSurface(tester);
      await _pumpSquad(tester, _paidSquad());
      final deco =
          _cardDecoration(tester, find.text('TEAM LEADER (YOU)'));
      expect(deco, isNotNull);
      final border = deco!.border as Border;
      expect(border.top.color, kGold);
      expect(border.bottom.color, kGold);
      expect(border.left.color, kGold);
      expect(border.right.color, kGold);
      // Mockup card height ~100dp (avatar 56 + title + fields).
      final card = _borderedCardFinder(find.text('TEAM LEADER (YOU)'));
      expect(card, findsOneWidget);
      final size = tester.getSize(card);
      expect(size.height, greaterThan(80));
      expect(size.height, lessThan(120));
    });

    testWidgets('filled mate card: number circle + VALIDATED + grey border',
        (tester) async {
      _phoneSurface(tester);
      await _pumpSquad(tester, _paidSquad());
      await _enterAt(tester, 3, '384910248');
      await _enterAt(tester, 4, 'Ghost_Rider');
      await tester.pump();

      // Filled variant replaces the dashed empty card.
      expect(find.byType(ArenaDashedBorder), findsNWidgets(2));
      expect(find.text('2'), findsOneWidget); // number circle
      expect(find.text('VALIDATED'), findsOneWidget);
      final deco = _cardDecoration(tester, find.text('SQUAD MATE #2'));
      expect(deco, isNotNull);
      final border = deco!.border as Border;
      expect(border.top.color, hBorder);
      expect(border.bottom.color, hBorder);
      final card = _borderedCardFinder(find.text('SQUAD MATE #2'));
      expect(card, findsOneWidget);
      final size = tester.getSize(card);
      expect(size.height, greaterThan(80));
      expect(size.height, lessThan(120));
    });

    testWidgets('rules checkbox gates CONFIRM (existing join logic kept)',
        (tester) async {
      _phoneSurface(tester);
      await _pumpSquad(tester, _paidSquad());
      expect(
          find.text('I agree to the Tournament Rules & Regulations',
              findRichText: true),
          findsOneWidget);
      final btnFinder =
          find.widgetWithText(ElevatedButton, 'CONFIRM SQUAD');
      expect(
          tester.widget<ElevatedButton>(btnFinder).onPressed, isNull);

      await _scrollTo(tester, find.byType(Checkbox));
      await tester.pump();
      await tester.tap(find.byType(Checkbox));
      await tester.pump();
      expect(
          tester.widget<ElevatedButton>(btnFinder).onPressed, isNotNull);
    });
  });
}
