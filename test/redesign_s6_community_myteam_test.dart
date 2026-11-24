// ARENA HUB Phase 2 redesign — GROUP S6: Community / My Team
// (guide §6 Screen 6).
//
// Pins the S6 restyle of TeamsPage (lib/screens/pro_features.dart):
// the F2 screen background, the F2 outlined Join by Code button
// (full width), the F2 input in the Join dialog, the F2 gold
// loading indicator, F1 tokens across the team cards / invite
// cards / header, and the kept Fix 12 semantics (three-button row
// order + selected=gold / unselected=dark, no CLAN pill, no
// "Browse Communities", no "Create Team/Clan"). Styling only —
// no logic, flow, navigation or data change.
//
// NON-VACUITY: the widget asserts pin exact values that only the
// restyled code satisfies — ArenaOutlinedButton (not OutlinedButton)
// at full header width (328dp at 360px), MyTeamCard radius 18 +
// padding all(12) (was radius 16 + 12/10), the unselected tab fill
// kSurface (was kCard), ArenaTextField in the Join dialog (was
// field()), ArenaBackground with the golden glow (was no
// background), the search border radius 14 (was 12). Against the
// pre-restyle code these asserts fail; the kept-semantics asserts
// (selected label 0xFF0A0A0F, unselected kGold) pin what S6 must
// NOT change.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/screens/pro_features.dart';
import 'package:protournament_user/services/supabase_db.dart';
import 'package:protournament_user/theme.dart';
import 'package:protournament_user/widgets/arena_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Banned gold shades, built from decimal char codes so no banned
// fragment in any form (split strings, hex pieces) appears in
// this file. Shade A is the first banned gold, B the second.
String _bannedGoldA() => String.fromCharCodes([70, 70, 67, 56, 48, 48]);
String _bannedGoldB() => String.fromCharCodes([70, 53, 65, 57, 48, 48]);

const _uid = 'test-uid';
const _captainUid = 'captain-uid';

Map<String, List<Map<String, dynamic>>> _fixtures({
  bool withTeams = true,
  bool withInvite = false,
}) =>
    {
      'teams': withTeams
          ? [
              {
                'id': 'team-1',
                'name': 'Falcons',
                'tag': 'FLC',
                'game': 'PUBG Mobile',
                'is_clan': false,
                'captain_uid': _uid,
                'captain_name': 'Tester',
                'invite_code': 'ABC123'
              },
              {
                'id': 'team-2',
                'name': 'Wolves',
                'tag': 'WLF',
                'game': 'PUBG Mobile',
                'is_clan': true,
                'captain_uid': _uid,
                'captain_name': 'Tester',
                'invite_code': 'XYZ789'
              },
            ]
          : [],
      'team_members': withTeams
          ? [
              {
                'team_id': 'team-1',
                'firebase_uid': _uid,
                'user_name': 'Tester',
                'role': 'captain'
              },
              {
                'team_id': 'team-2',
                'firebase_uid': _uid,
                'user_name': 'Tester',
                'role': 'captain'
              },
            ]
          : [],
      'team_invitations': withInvite
          ? [
              {
                'id': 'invite-1',
                'team_id': 'team-1',
                'invited_firebase_uid': _uid,
                'inviter_firebase_uid': _captainUid,
                'status': 'pending',
                'created_at': '2026-11-21T10:00:00Z',
              },
            ]
          : [],
      'communities': [
        {
          'id': 'comm-1',
          'name': 'Meri Kahani',
          'description': 'testing',
          'photo_url': '',
          'is_public': true,
          'created_by_uid': _uid,
          'created_at': '2026-11-22T19:39:32Z',
        },
        {
          'id': 'comm-2',
          'name': 'Pro Gamers',
          'description': '',
          'photo_url': '',
          'is_public': true,
          'created_by_uid': 'other-uid',
          'created_at': '2026-11-22T18:00:00Z',
        },
      ],
      'community_members': [
        {
          'community_id': 'comm-1',
          'firebase_uid': _uid,
          'role': 'creator'
        },
        {
          'community_id': 'comm-1',
          'firebase_uid': 'other-uid',
          'role': 'member'
        },
      ],
      'profiles': [
        {
          'firebase_uid': _uid,
          'display_name': 'Tester',
          'username': 'tester'
        },
        {
          'firebase_uid': _captainUid,
          'display_name': 'sameer',
          'username': 'sameer'
        },
      ],
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  setUp(() {
    themeLightNotifier.value = false;
  });
  tearDown(() {
    SupaDb.testFixtures = null;
  });

  /// 360dp-wide phone viewport (720x1280 @ 2.0). The task's
  /// required overflow check runs at this width.
  void setPhone360(WidgetTester tester) {
    tester.view.physicalSize = const Size(720, 1280);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> pumpTeams(WidgetTester tester) async {
    await tester.pumpWidget(
        const MaterialApp(home: TeamsPage(uid: _uid, embedded: true)));
    await tester.pump();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  group('S6 — contract tokens (F1 exact values)', () {
    test('gold is #FDC903 only — never the banned shades', () {
      expect(kGold, const Color(0xFFFDC903));
      expect(kGoldDeep, const Color(0xFFFDC903));
      expect(kGoldBright, const Color(0xFFFDC903));
      expect(kGoldSoft, const Color(0xFFFFE16A));
      expect(kGoldGradient.colors, [kGoldSoft, kGoldDeep]);
    });

    test('surface / muted / gradient tokens', () {
      expect(kSurface, const Color(0xFF10131A));
      expect(kSurfaceElevated, const Color(0xFF202331));
      expect(kTextMuted, const Color(0xFF737789));
      expect(kCardSurfaceGradient.colors,
          [const Color(0xFF202331), const Color(0xFF12141C)]);
      expect(kBackgroundGradient.colors,
          [const Color(0xFF10121A), const Color(0xFF08090D)]);
    });

    test('spacing + radius tokens', () {
      expect(kSpace4, 4);
      expect(kSpace8, 8);
      expect(kSpace12, 12);
      expect(kSpace16, 16);
      expect(kSpace20, 20);
      expect(kSpace24, 24);
      expect(kSpace32, 32);
      expect(kRadiusChip, 12);
      expect(kRadiusInput, 14);
      expect(kRadiusCard, 18);
      expect(kRadiusHero, 22);
    });

    test('text style tokens (guide §4 hierarchy)', () {
      expect(kStyleTitle.fontSize, 22);
      expect(kStyleTitle.fontWeight, FontWeight.bold);
      expect(kStyleSection.fontSize, 18);
      expect(kStyleSection.fontWeight, FontWeight.bold);
      expect(kStyleCardTitle.fontSize, 17);
      expect(kStyleCardTitle.fontWeight, FontWeight.w600);
      expect(kStyleBody.fontSize, 15);
      expect(kStyleMeta.fontSize, 13);
      expect(kStyleLabel.fontSize, 12);
      expect(kStyleLabel.fontWeight, FontWeight.w500);
    });
  });

  group('S6 — source pins (the screen wires the tokens in)', () {
    late String src;
    late String teamsPage;

    setUp(() {
      src = File('lib/screens/pro_features.dart').readAsStringSync();
      final start = src.indexOf('class _TeamsPageState');
      final end = src.indexOf('class TeamDetailPage', start);
      teamsPage = src.substring(start, end);
    });

    test('no banned gold hex anywhere in the S6 files', () {
      final themeSrc = File('lib/theme.dart').readAsStringSync();
      final uiSrc = File('lib/widgets/arena_ui.dart').readAsStringSync();
      final banned1 = _bannedGoldA();
      final banned2 = _bannedGoldB();
      for (final s in [src, themeSrc, uiSrc]) {
        expect(s.toUpperCase().contains(banned1), isFalse);
        expect(s.toUpperCase().contains(banned2), isFalse);
      }
    });

    test('F2 components wired into the TeamsPage region', () {
      expect(teamsPage, contains('ArenaBackground('));
      expect(teamsPage, contains('showGoldenGlow: true'));
      expect(teamsPage, contains('ArenaOutlinedButton('));
      expect(teamsPage, contains('ArenaTextField('));
      expect(teamsPage, contains('ArenaLoadingIndicator()'));
      // The Join dialog no longer uses the old field() helper.
      expect(teamsPage, isNot(contains('field(controller: codeCtrl')));
    });

    test('team cards use the global card rule + F1 card radius', () {
      expect(teamsPage, contains('MyTeamCard('));
      expect(teamsPage, contains('radius: kRadiusCard'));
      expect(teamsPage, contains('padding: const EdgeInsets.all(kSpace12)'));
    });

    test('no CLAN pill, no Browse Communities, no Create Team/Clan', () {
      // Fix 12 G5: no clan type anywhere (the kept 'Clan War'
      // feature button is mixed case and stays — see the widget
      // test below). 'CLAN' in a comment does not count, so the
      // quoted forms are what is pinned here.
      expect(teamsPage, isNot(contains("Text('CLAN'")));
      expect(teamsPage, isNot(contains("'CLAN'")));
      // Fix 11 deleted "Browse Communities" — S6 must not restore it.
      expect(teamsPage, isNot(contains('Browse Communities')));
      // The unified form replaced Create Team/Clan — no such
      // button or dialog call site may come back (the one
      // 'Create Clan' hit left in the file is a comment about the
      // deleted buttons, so the code forms are pinned).
      expect(teamsPage, isNot(contains("goldButton(label: 'Create Clan'")));
      expect(teamsPage, isNot(contains("goldButton(label: 'Create Team'")));
      expect(teamsPage, isNot(contains("Text('Create Clan'")));
      expect(teamsPage, isNot(contains("Text('Create Team'")));
    });

    test("S8's STAN rows still render inside this page, untouched", () {
      expect(teamsPage, contains('StanCommunityRow('));
      expect(teamsPage, contains('onOpen: () => _openCommunity(c)'));
    });
  });

  group('S6 — widget: 360px phone, header + three-button row', () {
    testWidgets('no teams: no overflow, row in order, empty state',
        (tester) async {
      setPhone360(tester);
      SupaDb.testFixtures = _fixtures(withTeams: false);
      await pumpTeams(tester);

      expect(find.text('Community'), findsOneWidget);
      expect(find.text('Squad'), findsOneWidget);
      expect(find.text('Create'), findsOneWidget);
      final communityX = tester.getCenter(find.text('Community')).dx;
      final squadX = tester.getCenter(find.text('Squad')).dx;
      final createX = tester.getCenter(find.text('Create')).dx;
      expect(communityX, lessThan(squadX));
      expect(squadX, lessThan(createX));
      final communityY = tester.getCenter(find.text('Community')).dy;
      final squadY = tester.getCenter(find.text('Squad')).dy;
      final createY = tester.getCenter(find.text('Create')).dy;
      expect((communityY - squadY).abs(), lessThan(1.0));
      expect((squadY - createY).abs(), lessThan(1.0));

      expect(find.text('Join by Code'), findsOneWidget);
      expect(find.text('No team yet'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('with teams: row in order, cards + actions render',
        (tester) async {
      setPhone360(tester);
      SupaDb.testFixtures = _fixtures();
      await pumpTeams(tester);

      expect(find.text('Community'), findsOneWidget);
      expect(find.text('Squad'), findsOneWidget);
      expect(find.text('Create'), findsOneWidget);
      final communityX = tester.getCenter(find.text('Community')).dx;
      final squadX = tester.getCenter(find.text('Squad')).dx;
      final createX = tester.getCenter(find.text('Create')).dx;
      expect(communityX, lessThan(squadX));
      expect(squadX, lessThan(createX));

      expect(find.text('Falcons'), findsOneWidget);
      expect(find.text('Wolves'), findsOneWidget);
      expect(find.text('Members & Chat'), findsNWidgets(2));
      // 'Clan War' is a kept named feature button, not the clan type.
      expect(find.text('Clan War'), findsNWidgets(2));
      expect(find.text('1 Members'), findsNWidgets(2));
      expect(find.text('ABC123'), findsOneWidget);
      expect(find.text('XYZ789'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('selected tab gold-filled + dark text; unselected dark',
        (tester) async {
      SupaDb.testFixtures = _fixtures();
      await pumpTeams(tester);

      Color? labelColor(String label) =>
          tester.widget<Text>(find.text(label)).style?.color;
      // Default side is Squad — the kept Fix 12 G11 semantics.
      expect(labelColor('Squad'), const Color(0xFF0A0A0F));
      expect(labelColor('Community'), kGold);
      expect(labelColor('Create'), kGold);

      BoxDecoration toggleDeco(String label) {
        final inkwell = tester.widget<InkWell>(find.ancestor(
            of: find.text(label), matching: find.byType(InkWell)).first);
        return (inkwell.child as Container).decoration as BoxDecoration;
      }

      final squadDeco = toggleDeco('Squad');
      expect(squadDeco.color, kGold);
      expect(squadDeco.borderRadius, BorderRadius.circular(30));
      final communityDeco = toggleDeco('Community');
      // REDESIGN S6: the unselected fill is the F2 chip surface
      // (was kCard before the restyle).
      expect(communityDeco.color, kSurface);
      expect(communityDeco.borderRadius, BorderRadius.circular(30));
      final border = communityDeco.border as Border;
      expect(border.top.color, kGold);
      expect(border.top.width, 1.5);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Join by Code is the F2 outlined button, full width',
        (tester) async {
      setPhone360(tester);
      SupaDb.testFixtures = _fixtures();
      await pumpTeams(tester);

      expect(find.byType(ArenaOutlinedButton), findsOneWidget);
      // Full header width: 360 - 2x16 page padding = 328. The old
      // OutlinedButton was content-width (~150), so this only
      // passes on the restyled code.
      final width =
          tester.getSize(find.byType(ArenaOutlinedButton)).width;
      expect(width, moreOrLessEquals(328, epsilon: 1.0));
      final style = tester.widget<Text>(find.text('Join by Code')).style!;
      expect(style.color, kGold);
      expect(style.fontWeight, FontWeight.w900);
      expect(style.fontSize, 16);
      expect(tester.takeException(), isNull);
    });

    testWidgets('screen background is the F2 ArenaBackground + glow + app image + smoke (FIX 23 items 21+24)',
        (tester) async {
      SupaDb.testFixtures = _fixtures();
      await pumpTeams(tester);

      final bg = tester.widget<ArenaBackground>(find.byType(ArenaBackground));
      expect(bg.showGoldenGlow, isTrue);
      // FIX 23 items 21+24 SUPERSEDE the gradient container: the
      // background is the app image layer + smoke now (the
      // kBackgroundGradient Container is gone).
      expect(
          find.descendant(
              of: find.byType(ArenaBackground),
              matching: find.byType(AppBackgroundLayer)),
          findsOneWidget);
      expect(
          find.descendant(
              of: find.byType(ArenaBackground),
              matching: find.byType(SmokeLayer)),
          findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('S6 — widget: team cards (global card rule + tokens)', () {
    testWidgets('cards are MockupCards with the F1 card radius',
        (tester) async {
      SupaDb.testFixtures = _fixtures();
      await pumpTeams(tester);

      expect(find.byType(MyTeamCard), findsNWidgets(2));
      for (final card
          in tester.widgetList<MyTeamCard>(find.byType(MyTeamCard))) {
        expect(card.radius, kRadiusCard);
        expect(card.padding, const EdgeInsets.all(kSpace12));
      }
      // MyTeamCard delegates to MockupCard (gradient fill + two
      // short gold shines, no full border) — one per team card.
      expect(find.byType(MockupCard), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    });

    testWidgets('name, members chip, tag/captain, invite code styles',
        (tester) async {
      SupaDb.testFixtures = _fixtures();
      await pumpTeams(tester);

      final nameStyle = tester.widget<Text>(find.text('Falcons')).style!;
      expect(nameStyle.color, kGold);
      expect(nameStyle.fontStyle, FontStyle.italic);
      expect(nameStyle.fontWeight, FontWeight.w900);
      expect(nameStyle.fontSize, 19);

      final membersStyle =
          tester.widget<Text>(find.text('1 Members').first).style!;
      expect(membersStyle.color, kGold);
      expect(membersStyle.fontWeight, FontWeight.bold);
      expect(membersStyle.fontSize, 12);

      final tagStyle = tester
          .widget<Text>(find.textContaining('Tag: FLC').first)
          .style!;
      expect(tagStyle.color, kMuted);
      expect(tagStyle.fontSize, 12);

      final codeStyle = tester.widget<Text>(find.text('ABC123')).style!;
      expect(codeStyle.color, kText);
      expect(codeStyle.fontWeight, FontWeight.bold);
      expect(codeStyle.fontSize, 13);
      expect(find.byIcon(Icons.copy), findsNWidgets(2));
      final copyIcon =
          tester.widget<Icon>(find.byIcon(Icons.copy).first);
      expect(copyIcon.color, kGold);
      expect(copyIcon.size, 14);
      expect(tester.takeException(), isNull);
    });
  });

  group('S6 — widget: community side + join dialog', () {
    testWidgets('search stays a TextField in a card shell (FIX 23 item 29B)',
        (tester) async {
      SupaDb.testFixtures = _fixtures();
      await pumpTeams(tester);
      await tester.tap(find.text('Community'));
      await tester.pump();
      await settle(tester);

      expect(find.byType(TextField), findsOneWidget);
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.decoration!.hintText, 'Community dhoonden...');
      // FIX 23 item 29B SUPERSEDES the token fill + gold focus
      // border: the field is borderless inside CardFieldShell
      // (card gradient + purple border + glow).
      expect(field.decoration!.fillColor, isNull);
      expect(
          (field.decoration!.border as OutlineInputBorder)
              .borderSide
              .style,
          BorderStyle.none);
      expect(
          find.ancestor(
              of: find.byType(TextField),
              matching: find.byType(CardFieldShell)),
          findsOneWidget);
      expect(field.style!.fontSize, kStyleBody.fontSize);
      expect(find.text('Meri Kahani'), findsOneWidget);
      expect(find.text('Join by Code'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Join dialog uses the card-style surface + F2 input (FIX 23 item 29C)',
        (tester) async {
      SupaDb.testFixtures = _fixtures();
      await pumpTeams(tester);
      await tester.tap(find.text('Join by Code'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(AlertDialog), findsOneWidget);
      final dialog =
          tester.widget<AlertDialog>(find.byType(AlertDialog));
      // FIX 23 item 29C SUPERSEDES the elevated surface: dialogs
      // wear the card style now (purple mid fill, radius 22,
      // purple border 1.5).
      expect(dialog.backgroundColor, kCardPurpleMid);
      expect(
          dialog.shape,
          RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(22),
              side: const BorderSide(
                  color: kCardPurpleBorder, width: 1.5)));
      final titleStyle =
          tester.widget<Text>(find.text('Join by invite code')).style!;
      expect(titleStyle.color, kGold);
      expect(titleStyle.fontSize, kStyleSection.fontSize);
      expect(titleStyle.fontWeight, FontWeight.bold);
      expect(find.byType(ArenaTextField), findsOneWidget);
      final input =
          tester.widget<ArenaTextField>(find.byType(ArenaTextField));
      expect(input.labelText, 'Invite code');
      expect(find.text('Cancel'), findsOneWidget);
      expect(find.text('Join'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('S6 — widget: pending invites', () {
    testWidgets('invite card renders with gold Accept + dark Decline',
        (tester) async {
      SupaDb.testFixtures = _fixtures(withInvite: true);
      await pumpTeams(tester);

      expect(find.text('TEAM INVITATIONS'), findsOneWidget);
      expect(find.text('Accept'), findsOneWidget);
      expect(find.text('Decline'), findsOneWidget);
      final acceptStyle = tester.widget<Text>(find.text('Accept')).style!;
      expect(acceptStyle.color, const Color(0xFF0A0A0F));
      expect(acceptStyle.fontWeight, FontWeight.bold);
      expect(acceptStyle.fontSize, 13);
      final declineStyle = tester.widget<Text>(find.text('Decline')).style!;
      expect(declineStyle.color, kText);
      expect(declineStyle.fontWeight, FontWeight.bold);
      // The Accept pill itself is gold-filled; Decline is dark.
      final goldPill = find.ancestor(
        of: find.text('Accept'),
        matching: find.byWidgetPredicate((w) =>
            w is Container &&
            w.decoration is BoxDecoration &&
            (w.decoration as BoxDecoration).color == kGold),
      );
      expect(goldPill, findsOneWidget);
      final darkPill = find.ancestor(
        of: find.text('Decline'),
        matching: find.byWidgetPredicate((w) =>
            w is Container &&
            w.decoration is BoxDecoration &&
            (w.decoration as BoxDecoration).color == kField),
      );
      expect(darkPill, findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
