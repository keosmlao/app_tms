import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_controller.dart';
import '../core/app_theme.dart';
import '../services/api_client.dart';

// ════════════════════════════════════════════════════════════════════
// LoginScreen — clean, light, modern. Centered logo + brand over a white
// form card. Matches the app's light/premium theme.
// ════════════════════════════════════════════════════════════════════
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.controller});

  final AppController controller;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  late final TextEditingController _baseUrlCtrl;
  final _userCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  bool _submitting = false;
  bool _obscurePassword = true;
  bool _rememberMe = true;

  @override
  void initState() {
    super.initState();
    _baseUrlCtrl = TextEditingController(text: widget.controller.baseUrl);
  }

  @override
  void dispose() {
    _baseUrlCtrl.dispose();
    _userCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) {
      HapticFeedback.lightImpact();
      return;
    }
    HapticFeedback.mediumImpact();
    FocusScope.of(context).unfocus();
    setState(() => _submitting = true);
    try {
      await widget.controller.login(
        baseUrl: _baseUrlCtrl.text,
        username: _userCtrl.text,
        password: _passCtrl.text,
        rememberMe: _rememberMe,
      );
    } catch (e) {
      if (!mounted) return;
      final msg = e is ApiException ? e.message : e.toString();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.error_outline_rounded, color: Colors.white, size: 18),
              const SizedBox(width: 8),
              Expanded(child: Text(msg)),
            ],
          ),
          backgroundColor: AppTheme.error,
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.all(16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      );
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _editServer() async {
    final result = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _ServerUrlSheet(initialUrl: _baseUrlCtrl.text),
    );
    if (result != null && result.isNotEmpty) {
      setState(() => _baseUrlCtrl.text = result);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.dark,
      child: Scaffold(
        backgroundColor: AppTheme.bgDark,
        resizeToAvoidBottomInset: true,
        body: Stack(
          children: [
            // Soft warm wash at the top.
            Container(
              height: 320,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    AppTheme.primary.withValues(alpha: 0.10),
                    AppTheme.bgDark,
                  ],
                ),
              ),
            ),
            SafeArea(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _logo(),
                      const SizedBox(height: 20),
                      ShaderMask(
                        shaderCallback: (b) => const LinearGradient(
                          colors: [
                            AppTheme.brandOrange,
                            AppTheme.brandOrangeLight,
                          ],
                        ).createShader(b),
                        child: const Text(
                          'ODG TMS',
                          style: TextStyle(
                            fontSize: 30,
                            fontWeight: FontWeight.w900,
                            color: Colors.white,
                            letterSpacing: 2.5,
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        'ລະບົບບໍລິຫານ ແລະ ປະຕິບັດການຂົນສົ່ງ',
                        style: TextStyle(
                          color: AppTheme.textMuted,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 26),
                      _formCard(),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _logo() {
    return Container(
      width: 90,
      height: 90,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: AppTheme.primary.withValues(alpha: 0.28),
            blurRadius: 26,
            spreadRadius: 1,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: Image.asset(
          'assets/odg.png',
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => Container(
            color: AppTheme.primary.withValues(alpha: 0.12),
            child: const Center(
              child: Icon(
                Icons.local_shipping_rounded,
                color: AppTheme.primary,
                size: 42,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _formCard() {
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxWidth: 440),
      padding: const EdgeInsets.fromLTRB(22, 22, 22, 22),
      decoration: BoxDecoration(
        color: AppTheme.bgCard,
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: AppTheme.surfaceBorder),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 28,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'ເຂົ້າສູ່ລະບົບ',
                    style: TextStyle(
                      color: AppTheme.textBright,
                      fontSize: 21,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                _serverChip(),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              'ກະລຸນາໃສ່ຊື່ຜູ້ໃຊ້ ແລະ ລະຫັດຜ່ານ',
              style: TextStyle(color: AppTheme.textMuted, fontSize: 12),
            ),
            const SizedBox(height: 22),

            _label('ຊື່ຜູ້ໃຊ້'),
            const SizedBox(height: 6),
            TextFormField(
              controller: _userCtrl,
              enabled: !_submitting,
              textInputAction: TextInputAction.next,
              style: const TextStyle(
                color: AppTheme.textBright,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
              decoration: _inputDeco('ຊື່ຜູ້ໃຊ້', Icons.person_outline_rounded),
              validator: (v) =>
                  (v ?? '').trim().isEmpty ? 'ກະລຸນາໃສ່ username' : null,
            ),
            const SizedBox(height: 14),

            _label('ລະຫັດຜ່ານ'),
            const SizedBox(height: 6),
            TextFormField(
              controller: _passCtrl,
              enabled: !_submitting,
              obscureText: _obscurePassword,
              textInputAction: TextInputAction.done,
              onFieldSubmitted: (_) => _submit(),
              style: const TextStyle(
                color: AppTheme.textBright,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
              decoration: _inputDeco('••••••••', Icons.lock_outline_rounded)
                  .copyWith(
                    suffixIcon: IconButton(
                      onPressed: () => setState(
                        () => _obscurePassword = !_obscurePassword,
                      ),
                      icon: Icon(
                        _obscurePassword
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined,
                        size: 20,
                        color: AppTheme.textMuted,
                      ),
                    ),
                  ),
              validator: (v) =>
                  (v ?? '').trim().isEmpty ? 'ກະລຸນາໃສ່ password' : null,
            ),
            const SizedBox(height: 12),

            _rememberRow(),
            const SizedBox(height: 20),

            SizedBox(
              width: double.infinity,
              height: 56,
              child: FilledButton(
                onPressed: _submitting ? null : _submit,
                style: FilledButton.styleFrom(
                  backgroundColor: AppTheme.primary,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: AppTheme.primary.withValues(alpha: 0.5),
                  elevation: _submitting ? 0 : 4,
                  shadowColor: AppTheme.primary.withValues(alpha: 0.5),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                child: _submitting
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.4,
                          color: Colors.white,
                        ),
                      )
                    : const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            'ເຂົ້າສູ່ລະບົບ',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 0.5,
                            ),
                          ),
                          SizedBox(width: 8),
                          Icon(Icons.arrow_forward_rounded, size: 21),
                        ],
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _serverChip() {
    return Material(
      color: AppTheme.bgSurface,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        onTap: _submitting ? null : _editServer,
        borderRadius: BorderRadius.circular(999),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: const [
              Icon(Icons.dns_rounded, size: 14, color: AppTheme.textMuted),
              SizedBox(width: 6),
              Text(
                'Server',
                style: TextStyle(
                  color: AppTheme.textSecondary,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _rememberRow() {
    return InkWell(
      onTap: _submitting ? null : () => setState(() => _rememberMe = !_rememberMe),
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                color: _rememberMe ? AppTheme.primary : Colors.transparent,
                borderRadius: BorderRadius.circular(7),
                border: Border.all(
                  color: _rememberMe ? AppTheme.primary : AppTheme.surfaceBorder,
                  width: 1.6,
                ),
              ),
              child: _rememberMe
                  ? const Icon(Icons.check_rounded, color: Colors.white, size: 14)
                  : null,
            ),
            const SizedBox(width: 10),
            const Text(
              'ຈົດຈຳການເຂົ້າສູ່ລະບົບ',
              style: TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _label(String text) => Text(
    text,
    style: const TextStyle(
      color: AppTheme.textSecondary,
      fontSize: 12,
      fontWeight: FontWeight.w800,
      letterSpacing: 0.2,
    ),
  );

  InputDecoration _inputDeco(String hint, IconData icon) {
    OutlineInputBorder border(Color c, [double w = 1]) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: BorderSide(color: c, width: w),
    );
    return InputDecoration(
      hintText: hint,
      prefixIcon: Padding(
        padding: const EdgeInsets.only(left: 12, right: 8),
        child: Icon(icon, size: 20, color: AppTheme.primary),
      ),
      prefixIconConstraints: const BoxConstraints(minWidth: 40),
      filled: true,
      fillColor: AppTheme.bgSurface,
      hintStyle: const TextStyle(
        color: AppTheme.textDim,
        fontWeight: FontWeight.w500,
      ),
      border: border(AppTheme.surfaceBorder),
      enabledBorder: border(AppTheme.surfaceBorder),
      focusedBorder: border(AppTheme.primary, 2),
      errorBorder: border(AppTheme.error, 1.5),
      focusedErrorBorder: border(AppTheme.error, 2),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
    );
  }
}

class _ServerUrlSheet extends StatefulWidget {
  const _ServerUrlSheet({required this.initialUrl});

  final String initialUrl;

  @override
  State<_ServerUrlSheet> createState() => _ServerUrlSheetState();
}

class _ServerUrlSheetState extends State<_ServerUrlSheet> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialUrl);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    OutlineInputBorder border(Color c, [double w = 1]) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: BorderSide(color: c, width: w),
    );
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: const BoxDecoration(
          color: AppTheme.bgCard,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppTheme.surfaceBorder,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
            const SizedBox(height: 18),
            const Row(
              children: [
                Icon(Icons.dns_rounded, color: AppTheme.primary, size: 20),
                SizedBox(width: 8),
                Text(
                  'Server URL',
                  style: TextStyle(
                    color: AppTheme.textBright,
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _controller,
              autofocus: true,
              style: const TextStyle(color: AppTheme.textBright),
              decoration: InputDecoration(
                hintText: 'https://tms.odienmall.com',
                hintStyle: const TextStyle(color: AppTheme.textDim),
                prefixIcon: const Icon(Icons.link_rounded, color: AppTheme.primary),
                filled: true,
                fillColor: AppTheme.bgSurface,
                border: border(AppTheme.surfaceBorder),
                enabledBorder: border(AppTheme.surfaceBorder),
                focusedBorder: border(AppTheme.primary, 2),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 16,
                ),
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              height: 52,
              child: FilledButton(
                onPressed: () => Navigator.pop(context, _controller.text.trim()),
                style: FilledButton.styleFrom(
                  backgroundColor: AppTheme.primary,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                child: const Text(
                  'ບັນທຶກ',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w900),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
