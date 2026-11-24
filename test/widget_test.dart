import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/services/supabase_db.dart';

void main() {
  test('referral code is 8 uppercase alphanumerics', () {
    final code = SupaDb.generateReferralCode();
    expect(code.length, 8);
    expect(RegExp(r'^[A-Z0-9]{8}$').hasMatch(code), isTrue);
  });
}
