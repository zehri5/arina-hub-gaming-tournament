// Supabase client config for ARENA HUB apps (publishable anon key only).
// NEVER add the service_role key here. This file is copied into each app's lib/
// as supabase_config.dart by the build workers.
// BACKEND MOVE (2026-11-22, user order): the app now talks to the
// project's own server (api.appfixguru.com) instead of Supabase
// cloud (kgursqimpiyeafwrcewr.supabase.co). The server speaks the
// Supabase REST/Realtime protocol, so the client code is unchanged
// — only the base URL moved. The anon key line below is untouched.
const String kSupabaseUrl = 'https://api.appfixguru.com';
const String kSupabaseAnonKey = 'sb_publishable_Udf0OJ30kDpHOLq2taGnyw_inw0EjSt';
