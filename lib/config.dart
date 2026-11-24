/// App-wide configuration placeholders.
///
/// NEVER put a real OneSignal App ID, EasyPaisa/JazzCash merchant credential
/// or ImgBB key in this file. Real values come at runtime from Supabase
/// `app_settings` - see the README. Firebase is used ONLY for login.
class AppConfig {
  /// OneSignal App ID placeholder. Leave empty until the user provides
  /// their OneSignal App ID. When empty, push initialisation is skipped
  /// gracefully and in-app Supabase notifications keep working.
  /// Admins may also set app_settings onesignal.appId; that value wins
  /// over this constant when present (see PushService).
  static const String oneSignalAppId = '';

  /// ImgBB API key placeholder. The source HTML app embedded its key in
  /// a `const IMGBB_API_KEY` - deliberately NOT copied here. Set it in
  /// app_settings imgbb_api_key (admin only). Uploads refuse with a
  /// clear message while it is empty.
  static const String imgbbApiKey = '';

  /// Google Sign-In Web (server) OAuth client ID, e.g.
  /// `32847154184-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx.apps.googleusercontent.com`.
  /// This is a PUBLIC OAuth client identifier, not a secret — but its
  /// real value is NOT known in this codebase (there is no
  /// google-services.json in the app), so it is left EMPTY on purpose.
  /// Fill it from Firebase Console → Authentication → Sign-in method →
  /// Google → Web client ID. While empty, GoogleSignIn() uses its
  /// default configuration and sign-in will fail with error 10 until
  /// the app's SHA-1 is registered for com.protournament.app in
  /// Firebase + Cloud Console (see auth_screen.dart). Do NOT invent
  /// a value here.
  static const String googleServerClientId = '32847154184-3q2f7k4ib1oj89mp1trsbmk08lnohuuf.apps.googleusercontent.com';

  /// Supabase table names (match the shared Supabase contract).
  static const String tableProfiles = 'profiles';
  static const String tableGames = 'games';
  static const String tablePromotions = 'promotions';
  static const String tableTournaments = 'tournaments';
  static const String tableRegistrations = 'tournament_registrations';
  static const String tableTransactions = 'transactions';
  static const String tableWithdrawals = 'withdrawals';
  static const String tableDeposits = 'deposits';
  static const String tablePendingReferrals = 'pending_referrals';
  static const String tableSettings = 'app_settings';
  static const String tableNotifications = 'notifications';
  static const String tableChats = 'chat_messages';
  static const String tableSupportTickets = 'support_tickets';
  static const String tableAds = 'ads';
}
