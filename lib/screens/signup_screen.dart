import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../components/arena_components.dart';
import '../theme/arena_theme.dart';
import '../widgets/arena_gaming_widgets.dart';

class SignupScreen extends StatefulWidget {
  // FIX 30: the AI Studio signature had no referral code — today's
  // signup has one (optional, passed to ensureUserProfile), so the
  // callback carries it. Do NOT drop functionality.
  final Future<void> Function(
      String fullName, String email, String password, String referralCode)? onSignupSubmit;
  final Future<void> Function()? onGoogleSignup;

  const SignupScreen({
    super.key,
    this.onSignupSubmit,
    this.onGoogleSignup,
  });

  @override
  State<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends State<SignupScreen> with SingleTickerProviderStateMixin {
  final _nameCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  // FIX 30: referral code (optional) — today's signup has this field;
  // the AI Studio signup lacked it, so it is ADDED in the same HUD style.
  final _referralCtrl = TextEditingController();

  String? _nameError;
  String? _emailError;
  String? _passwordError;
  String? _confirmError;
  bool _loading = false;

  late final AnimationController _animCtrl;
  late final Animation<double> _fadeAnim;

  @override
  void initState() {
    super.initState();
    _animCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    )..forward();
    _fadeAnim = CurvedAnimation(parent: _animCtrl, curve: Curves.easeOutCubic);
  }

  @override
  void dispose() {
    _animCtrl.dispose();
    _nameCtrl.dispose();
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    _confirmCtrl.dispose();
    _referralCtrl.dispose();
    super.dispose();
  }

  Future<void> _handleSignup() async {
    final name = _nameCtrl.text.trim();
    final email = _emailCtrl.text.trim();
    final pass = _passwordCtrl.text;
    final confirm = _confirmCtrl.text;
    final emailRegex = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]{2,}$');

    String? nErr;
    String? eErr;
    String? pErr;
    String? cErr;

    if (name.length < 2) nErr = 'Enter your full name.';
    if (email.isEmpty || !emailRegex.hasMatch(email)) eErr = 'Enter a valid email address.';
    if (pass.length < 6) pErr = 'Password must be at least 6 characters.';
    if (confirm != pass || confirm.isEmpty) cErr = 'Passwords do not match.';

    setState(() {
      _nameError = nErr;
      _emailError = eErr;
      _passwordError = pErr;
      _confirmError = cErr;
    });

    if (nErr != null || eErr != null || pErr != null || cErr != null) return;

    setState(() => _loading = true);
    try {
      if (widget.onSignupSubmit != null) {
        await widget.onSignupSubmit!(
            name, email, pass, _referralCtrl.text.trim());
      } else {
        await Future.delayed(const Duration(milliseconds: 750));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
      ),
      child: Scaffold(
        backgroundColor: ArenaTheme.midnightBg,
        resizeToAvoidBottomInset: true,
        body: Stack(
          fit: StackFit.expand,
          children: [
            Image.asset(
              ArenaTheme.backgroundAsset,
              fit: BoxFit.cover,
              alignment: Alignment.center,
            ),
            Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color(0x55040618),
                    Color(0x6B050616),
                    Color(0x22050616),
                  ],
                  stops: [0.0, 0.55, 1.0],
                ),
              ),
            ),
            SafeArea(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  return SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(minHeight: constraints.maxHeight - 28),
                      child: FadeTransition(
                        opacity: _fadeAnim,
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            // Header + Hero
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                // FIX 30 logo rule (Sameer, pakka):
                                // the AI Studio code's own logo is
                                // REMOVED — our logo, CENTERED.
                                const Center(
                                  child: ArenaHubLogoImage(
                                      size: 96, ringWidth: 3),
                                ),
                                const SizedBox(height: 10),
                                Padding(
                                  padding: const EdgeInsets.only(left: 4),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Create Your',
                                        style: ArenaTheme.bodyStyle(
                                          fontSize: 19,
                                          fontWeight: FontWeight.w700,
                                          fontStyle: FontStyle.italic,
                                        ),
                                      ),
                                      ShaderMask(
                                        shaderCallback: (bounds) => const LinearGradient(
                                          begin: Alignment.topCenter,
                                          end: Alignment.bottomCenter,
                                          colors: [
                                            ArenaTheme.goldBright,
                                            ArenaTheme.goldPrimary,
                                            ArenaTheme.goldOrange,
                                          ],
                                        ).createShader(bounds),
                                        child: Text(
                                          'Account',
                                          style: ArenaTheme.displayStyle(
                                            fontSize: 42,
                                            height: 0.94,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 10),
                                Row(
                                  children: [
                                    Expanded(
                                      child: Container(
                                        height: 1,
                                        decoration: const BoxDecoration(
                                          gradient: LinearGradient(
                                            colors: [Colors.transparent, Color(0xD9FCD34D)],
                                          ),
                                        ),
                                      ),
                                    ),
                                    Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 10),
                                      child: Text(
                                        'Join the Arena. Become a Champion.',
                                        style: ArenaTheme.bodyStyle(
                                          fontSize: 12.5,
                                          fontStyle: FontStyle.italic,
                                          color: const Color(0xFFF1F5F9),
                                        ),
                                      ),
                                    ),
                                    Expanded(
                                      child: Container(
                                        height: 1,
                                        decoration: const BoxDecoration(
                                          gradient: LinearGradient(
                                            colors: [Color(0xD9FCD34D), Colors.transparent],
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),

                            // 4 Fields + Buttons
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              child: Column(
                                children: [
                                  ArenaGamingTextField(
                                    controller: _nameCtrl,
                                    hintText: 'Full Name',
                                    icon: Icons.person_outline_rounded,
                                    variant: ArenaFrameVariant.blue,
                                    showDividerBar: true,
                                    errorText: _nameError,
                                    onChanged: (_) {
                                      if (_nameError != null) setState(() => _nameError = null);
                                    },
                                  ),
                                  const SizedBox(height: 10),
                                  ArenaGamingTextField(
                                    controller: _emailCtrl,
                                    hintText: 'Email Address',
                                    icon: Icons.mail_outline_rounded,
                                    variant: ArenaFrameVariant.blue,
                                    keyboardType: TextInputType.emailAddress,
                                    errorText: _emailError,
                                    onChanged: (_) {
                                      if (_emailError != null) setState(() => _emailError = null);
                                    },
                                  ),
                                  const SizedBox(height: 10),
                                  ArenaGamingTextField(
                                    controller: _passwordCtrl,
                                    hintText: 'Password (min. 6 characters)',
                                    icon: Icons.lock_outline_rounded,
                                    variant: ArenaFrameVariant.purple,
                                    isPassword: true,
                                    errorText: _passwordError,
                                    onChanged: (_) {
                                      if (_passwordError != null) {
                                        setState(() => _passwordError = null);
                                      }
                                    },
                                  ),
                                  const SizedBox(height: 10),
                                  ArenaGamingTextField(
                                    controller: _confirmCtrl,
                                    hintText: 'Confirm Password',
                                    icon: Icons.verified_user_outlined,
                                    variant: ArenaFrameVariant.purple,
                                    isPassword: true,
                                    textInputAction: TextInputAction.done,
                                    errorText: _confirmError,
                                    onChanged: (_) {
                                      if (_confirmError != null) {
                                        setState(() => _confirmError = null);
                                      }
                                    },
                                  ),
                                  // FIX 30: referral code (optional) —
                                  // same HUD field style as the rest.
                                  const SizedBox(height: 10),
                                  ArenaGamingTextField(
                                    controller: _referralCtrl,
                                    hintText: 'Referral Code (Optional)',
                                    icon: Icons.card_giftcard_outlined,
                                    variant: ArenaFrameVariant.blue,
                                    textInputAction: TextInputAction.done,
                                  ),
                                  const SizedBox(height: 14),
                                  ArenaGoldenButton(
                                    label: 'CREATE ACCOUNT',
                                    loading: _loading,
                                    onPressed: _handleSignup,
                                  ),
                                  const SizedBox(height: 12),
                                  const ArenaOrDivider(),
                                  const SizedBox(height: 12),
                                  ArenaGoogleButton(onPressed: widget.onGoogleSignup),
                                ],
                              ),
                            ),

                            // Bottom Login Link
                            Center(
                              child: GestureDetector(
                                onTap: () => Navigator.of(context).pop(),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 22,
                                    vertical: 11,
                                  ),
                                  decoration: BoxDecoration(
                                    color: const Color(0xC7090820),
                                    borderRadius: BorderRadius.circular(999),
                                    border: Border.all(
                                      color: const Color(0xBFA855F7),
                                      width: 1.4,
                                    ),
                                    boxShadow: const [
                                      BoxShadow(color: Color(0x61A855F7), blurRadius: 16),
                                    ],
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(Icons.login_rounded, color: Colors.white, size: 18),
                                      const SizedBox(width: 8),
                                      RichText(
                                        text: TextSpan(
                                          style: ArenaTheme.bodyStyle(fontSize: 13.5),
                                          children: const [
                                            TextSpan(text: 'Already have an account? '),
                                            TextSpan(
                                              text: 'Login',
                                              style: TextStyle(
                                                color: Color(0xFFFFD646),
                                                fontWeight: FontWeight.w700,
                                                decoration: TextDecoration.underline,
                                                decorationColor: Color(0xFFFFD646),
                                                decorationThickness: 1.8,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}