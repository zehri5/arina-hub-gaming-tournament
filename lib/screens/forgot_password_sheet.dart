import 'package:flutter/material.dart';
import '../theme/arena_theme.dart';
import '../widgets/arena_gaming_widgets.dart';

Future<void> showArenaForgotPasswordSheet(BuildContext context,
    {String initialEmail = '',
    // FIX 30 wiring: the real reset-email call (AuthService). Null =
    // the AI Studio demo delay.
    Future<void> Function(String email)? onSubmit}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) =>
        _ForgotPasswordSheet(initialEmail: initialEmail, onSubmit: onSubmit),
  );
}

class _ForgotPasswordSheet extends StatefulWidget {
  final String initialEmail;
  final Future<void> Function(String email)? onSubmit;
  const _ForgotPasswordSheet({required this.initialEmail, this.onSubmit});

  @override
  State<_ForgotPasswordSheet> createState() => _ForgotPasswordSheetState();
}

class _ForgotPasswordSheetState extends State<_ForgotPasswordSheet> {
  late final TextEditingController _emailCtrl;
  String? _error;
  bool _loading = false;
  bool _sent = false;

  @override
  void initState() {
    super.initState();
    _emailCtrl = TextEditingController(text: widget.initialEmail);
  }

  @override
  void dispose() {
    _emailCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final email = _emailCtrl.text.trim();
    final emailRegex = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]{2,}$');
    if (email.isEmpty || !emailRegex.hasMatch(email)) {
      setState(() => _error = 'Enter a valid email address.');
      return;
    }

    setState(() {
      _error = null;
      _loading = true;
    });

    // FIX 30: real reset email via the wired callback; on failure the
    // error shows inline (no fake "sent" state). Null = the AI Studio
    // demo delay.
    try {
      if (widget.onSubmit != null) {
        await widget.onSubmit!(email);
      } else {
        await Future.delayed(const Duration(milliseconds: 650));
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not send reset email: $e';
      });
      return;
    }
    if (!mounted) return;
    setState(() {
      _loading = false;
      _sent = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Container(
        margin: const EdgeInsets.all(14),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: const Color(0xF20A0E26),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: const Color(0x80A855F7)),
          boxShadow: const [BoxShadow(color: Color(0x737C3AED), blurRadius: 28)],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextButton.icon(
              onPressed: () => Navigator.pop(context),
              style: TextButton.styleFrom(padding: EdgeInsets.zero),
              icon: const Icon(Icons.arrow_back, size: 16, color: ArenaTheme.goldPrimary),
              label: Text(
                'Back to Login',
                style: ArenaTheme.bodyStyle(
                  fontSize: 13,
                  color: ArenaTheme.goldPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(height: 6),
            RichText(
              text: TextSpan(
                style: ArenaTheme.displayStyle(fontSize: 30),
                children: const [
                  TextSpan(text: 'RESET '),
                  TextSpan(
                    text: 'PASSWORD',
                    style: TextStyle(color: ArenaTheme.goldPrimary),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Enter your registered Arena Hub email to receive recovery instructions.',
              style: ArenaTheme.bodyStyle(fontSize: 13, color: const Color(0xFFCBD5E1)),
            ),
            const SizedBox(height: 18),
            if (_sent) ...[
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0x4D064E3B),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: const Color(0x6634D399)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.check_circle_outline, color: Color(0xFF34D399), size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Reset link sent to ${_emailCtrl.text.trim()}.',
                        style: ArenaTheme.bodyStyle(fontSize: 13, color: const Color(0xFFA7F3D0)),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              ArenaGoldenButton(
                label: 'RETURN TO LOGIN',
                onPressed: () => Navigator.pop(context),
              ),
            ] else ...[
              ArenaGamingTextField(
                controller: _emailCtrl,
                hintText: 'Email Address',
                icon: Icons.mail_outline_rounded,
                keyboardType: TextInputType.emailAddress,
                showDividerBar: true,
                errorText: _error,
                onChanged: (_) {
                  if (_error != null) setState(() => _error = null);
                },
              ),
              const SizedBox(height: 16),
              ArenaGoldenButton(
                label: 'SEND RESET LINK',
                loading: _loading,
                onPressed: _submit,
              ),
            ],
          ],
        ),
      ),
    );
  }
}