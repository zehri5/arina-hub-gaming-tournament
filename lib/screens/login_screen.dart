import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../components/arena_components.dart';
import '../theme/arena_theme.dart';
import '../widgets/arena_gaming_widgets.dart';
import 'forgot_password_sheet.dart';
import 'signup_screen.dart';

class LoginScreen extends StatefulWidget {
  final Future<void> Function(String email, String password)? onLoginSubmit;
  final Future<void> Function()? onGoogleLogin;
  // FIX 30 wiring (not in the AI Studio code): passed through to
  // SignupScreen / the forgot-password sheet so both reach the real
  // auth logic (AuthService). Null = the AI Studio demo fallback.
  final Future<void> Function(
      String fullName, String email, String password, String referralCode)? onSignupSubmit;
  final Future<void> Function(String email)? onForgotPassword;

  const LoginScreen({
    super.key,
    this.onLoginSubmit,
    this.onGoogleLogin,
    this.onSignupSubmit,
    this.onForgotPassword,
  });

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> with SingleTickerProviderStateMixin {
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();

  String? _emailError;
  String? _passwordError;
  bool _loading = false;

  late final AnimationController _animCtrl;
  late final Animation<double> _fadeAnim;
  late final Animation<Offset> _slideAnim;

  @override
  void initState() {
    super.initState();
    _animCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 650),
    )..forward();

    _fadeAnim = CurvedAnimation(parent: _animCtrl, curve: Curves.easeOutCubic);
    _slideAnim = Tween<Offset>(
      begin: const Offset(0, 0.05),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _animCtrl, curve: Curves.easeOutCubic));
  }

  @override
  void dispose() {
    _animCtrl.dispose();
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  Future<void> _handleLogin() async {
    final email = _emailCtrl.text.trim();
    final pass = _passwordCtrl.text;
    final emailRegex = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]{2,}$');

    String? eErr;
    String? pErr;

    if (email.isEmpty) {
      eErr = 'Email address is required.';
    } else if (!emailRegex.hasMatch(email)) {
      eErr = 'Enter a valid email address.';
    }

    if (pass.isEmpty) {
      pErr = 'Password is required.';
    } else if (pass.length < 6) {
      pErr = 'Password must be at least 6 characters.';
    }

    setState(() {
      _emailError = eErr;
      _passwordError = pErr;
    });

    if (eErr != null || pErr != null) return;

    setState(() => _loading = true);
    try {
      if (widget.onLoginSubmit != null) {
        await widget.onLoginSubmit!(email, pass);
      } else {
        await Future.delayed(const Duration(milliseconds: 700));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _goToSignup() {
    Navigator.of(context).push(
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => SignupScreen(
          onSignupSubmit: widget.onSignupSubmit,
          onGoogleSignup: widget.onGoogleLogin,
        ),
        transitionsBuilder: (_, anim, __, child) {
          return FadeTransition(
            opacity: anim,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0.08, 0),
                end: Offset.zero,
              ).animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
              child: child,
            ),
          );
        },
      ),
    );
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
            // Bottom Layer: Supplied Cinematic Background Image
            Image.asset(
              ArenaTheme.backgroundAsset,
              fit: BoxFit.cover,
              alignment: Alignment.center,
            ),

            // Controlled scrim behind top-left logo & middle form
            Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color(0x55040618),
                    Color(0x66050616),
                    Color(0x22050616),
                  ],
                  stops: [0.0, 0.55, 1.0],
                ),
              ),
            ),

            // Foreground Responsive Scrollable Content
            SafeArea(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  return SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(minHeight: constraints.maxHeight - 32),
                      child: FadeTransition(
                        opacity: _fadeAnim,
                        child: SlideTransition(
                          position: _slideAnim,
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              // Header + Hero Section
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  // FIX 30 logo rule (Sameer, pakka):
                                  // the AI Studio code's own logo is
                                  // REMOVED — our logo, CENTERED.
                                  const Center(
                                    child: ArenaHubLogoImage(
                                        size: 120, ringWidth: 3),
                                  ),
                                  const SizedBox(height: 14),
                                  Padding(
                                    padding: const EdgeInsets.only(left: 4),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          'Welcome Back,',
                                          style: ArenaTheme.bodyStyle(
                                            fontSize: 21,
                                            fontWeight: FontWeight.w700,
                                            fontStyle: FontStyle.italic,
                                          ),
                                        ),
                                        // PHASE E (E19): the Y's descender
                                        // escaped the tight 0.94 line box
                                        // and painted in the base WHITE —
                                        // the white sliver under "Player".
                                        // height 1.1 keeps the descender
                                        // inside the shader bounds, and the
                                        // base color is gold now, so any
                                        // overflow paints gold, never white.
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
                                            'Player',
                                            style: ArenaTheme.displayStyle(
                                              fontSize: 48,
                                              color: ArenaTheme.goldPrimary,
                                              height: 1.1,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(height: 6),
                                        Container(
                                          width: 144,
                                          height: 2,
                                          decoration: const BoxDecoration(
                                            gradient: LinearGradient(
                                              colors: [
                                                Color(0xFFFCD34D),
                                                Color(0xCCFBBF24),
                                                Colors.transparent,
                                              ],
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(height: 14),
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
                                          'Your next victory starts here.',
                                          style: ArenaTheme.bodyStyle(
                                            fontSize: 13.5,
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

                              // Form Section
                              Padding(
                                padding: const EdgeInsets.symmetric(vertical: 16),
                                child: Column(
                                  children: [
                                    ArenaGamingTextField(
                                      controller: _emailCtrl,
                                      hintText: 'Email Address',
                                      icon: Icons.mail_outline_rounded,
                                      variant: ArenaFrameVariant.blue,
                                      showDividerBar: true,
                                      keyboardType: TextInputType.emailAddress,
                                      errorText: _emailError,
                                      onChanged: (_) {
                                        if (_emailError != null) {
                                          setState(() => _emailError = null);
                                        }
                                      },
                                    ),
                                    const SizedBox(height: 12),
                                    ArenaGamingTextField(
                                      controller: _passwordCtrl,
                                      hintText: 'Password',
                                      icon: Icons.lock_outline_rounded,
                                      variant: ArenaFrameVariant.purple,
                                      isPassword: true,
                                      textInputAction: TextInputAction.done,
                                      errorText: _passwordError,
                                      onChanged: (_) {
                                        if (_passwordError != null) {
                                          setState(() => _passwordError = null);
                                        }
                                      },
                                    ),
                                    Align(
                                      alignment: Alignment.centerRight,
                                      child: TextButton(
                                        onPressed: () => showArenaForgotPasswordSheet(
                                          context,
                                          initialEmail: _emailCtrl.text.trim(),
                                          onSubmit: widget.onForgotPassword,
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Text(
                                              'Forgot Password?',
                                              style: ArenaTheme.bodyStyle(
                                                fontSize: 13.5,
                                                color: const Color(0xFFFFD646),
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                            const SizedBox(width: 6),
                                            Container(
                                              width: 20,
                                              height: 20,
                                              decoration: BoxDecoration(
                                                shape: BoxShape.circle,
                                                border: Border.all(color: const Color(0xFFFFD646)),
                                              ),
                                              child: const Icon(
                                                Icons.chevron_right,
                                                size: 14,
                                                color: Color(0xFFFFD646),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    ArenaGoldenButton(
                                      label: 'LOGIN',
                                      loading: _loading,
                                      onPressed: _handleLogin,
                                    ),
                                    const SizedBox(height: 14),
                                    const ArenaOrDivider(),
                                    const SizedBox(height: 14),
                                    ArenaGoogleButton(onPressed: widget.onGoogleLogin),
                                  ],
                                ),
                              ),

                              // Bottom Create Account Outlined Container
                              Column(
                                children: [
                                  GestureDetector(
                                    onTap: _goToSignup,
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 22,
                                        vertical: 12,
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
                                          const Icon(
                                            Icons.person_add_alt_1_outlined,
                                            color: Colors.white,
                                            size: 18,
                                          ),
                                          const SizedBox(width: 8),
                                          RichText(
                                            text: TextSpan(
                                              style: ArenaTheme.bodyStyle(fontSize: 14),
                                              children: const [
                                                TextSpan(text: 'New player? '),
                                                TextSpan(
                                                  text: 'Create Account',
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
                                  const SizedBox(height: 5),
                                  Container(
                                    width: 150,
                                    height: 2,
                                    decoration: const BoxDecoration(
                                      gradient: LinearGradient(
                                        colors: [
                                          Colors.transparent,
                                          Color(0xD9F59E0B),
                                          Colors.transparent,
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
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