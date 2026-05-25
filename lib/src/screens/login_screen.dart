import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_controller.dart';
import '../core/app_theme.dart';
import '../services/api_client.dart';

// ════════════════════════════════════════════════════════════════════
// LoginScreen — clean modern bottom-sheet style
// ════════════════════════════════════════════════════════════════════
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.controller});

  final AppController controller;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen>
    with SingleTickerProviderStateMixin {
  late final TextEditingController _baseUrlCtrl;
  final _userCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  bool _submitting = false;
  bool _obscurePassword = true;
  bool _rememberMe = true;

  late final AnimationController _entryCtrl;

  @override
  void initState() {
    super.initState();
    _baseUrlCtrl = TextEditingController(text: widget.controller.baseUrl);
    _entryCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    )..forward();
  }

  @override
  void dispose() {
    _entryCtrl.dispose();
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
              const Icon(
                Icons.error_outline_rounded,
                color: Colors.white,
                size: 18,
              ),
              const SizedBox(width: 8),
              Expanded(child: Text(msg)),
            ],
          ),
          backgroundColor: AppTheme.error,
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.all(16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
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

  // ────────────────────────────── build ──────────────────────────────
  @override
  Widget build(BuildContext context) {
    final viewInsets = MediaQuery.of(context).viewInsets.bottom;
    final keyboardOpen = viewInsets > 0;
    final size = MediaQuery.of(context).size;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: AppTheme.bgDark,
        resizeToAvoidBottomInset: true,
        body: Stack(
          children: [
            // Background gradient + decorative blobs
            const Positioned.fill(child: _Backdrop()),

            // Hero (logo + brand) — anchored to top, fades when keyboard opens
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: AnimatedSlide(
                duration: const Duration(milliseconds: 280),
                curve: Curves.easeOut,
                offset: keyboardOpen ? const Offset(0, -0.2) : Offset.zero,
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 220),
                  opacity: keyboardOpen ? 0.5 : 1,
                  child: SafeArea(
                    bottom: false,
                    child: SizedBox(
                      height: size.height * 0.42,
                      child: _buildHero(),
                    ),
                  ),
                ),
              ),
            ),

            // Form sheet — anchored to bottom
            Align(
              alignment: Alignment.bottomCenter,
              child: SingleChildScrollView(
                physics: const ClampingScrollPhysics(),
                padding: EdgeInsets.only(bottom: viewInsets),
                child: SlideTransition(
                  position:
                      Tween<Offset>(
                        begin: const Offset(0, 0.3),
                        end: Offset.zero,
                      ).animate(
                        CurvedAnimation(
                          parent: _entryCtrl,
                          curve: const Interval(
                            0.25,
                            1,
                            curve: Curves.easeOutCubic,
                          ),
                        ),
                      ),
                  child: FadeTransition(
                    opacity: CurvedAnimation(
                      parent: _entryCtrl,
                      curve: const Interval(0.25, 1, curve: Curves.easeOut),
                    ),
                    child: _buildFormSheet(),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ────────────────────────────── Hero ──────────────────────────────
  Widget _buildHero() {
    return FadeTransition(
      opacity: CurvedAnimation(
        parent: _entryCtrl,
        curve: const Interval(0, 0.6, curve: Curves.easeOut),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 36, 24, 0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Logo with halo
            Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppTheme.radiusXl),
                boxShadow: [
                  BoxShadow(
                    color: AppTheme.brandOrange.withValues(alpha: 0.5),
                    blurRadius: 38,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(AppTheme.radiusXl),
                child: Image.asset(
                  'assets/odg.png',
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Container(
                    color: AppTheme.brandNavyMid,
                    child: const Center(
                      child: Icon(
                        Icons.local_shipping_rounded,
                        color: AppTheme.brandOrange,
                        size: 44,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 22),
            ShaderMask(
              shaderCallback: (b) => const LinearGradient(
                colors: [AppTheme.brandOrange, AppTheme.brandOrangeLight],
              ).createShader(b),
              child: const Text(
                'ODG TMS',
                style: TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.w900,
                  color: Colors.white,
                  letterSpacing: 3,
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'ລະບົບຈັດສົ່ງສິນຄ້າ ສຳລັບຄົນຂັບ',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.72),
                fontSize: 13,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.4,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ────────────────────────────── Form sheet ──────────────────────────────
  Widget _buildFormSheet() {
    return Container(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [AppTheme.brandNavy, AppTheme.brandNavyDeep],
        ),
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(AppTheme.radiusXxl),
        ),
        border: Border(
          top: BorderSide(color: Colors.white.withValues(alpha: 0.12)),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.4),
            blurRadius: 32,
            offset: const Offset(0, -10),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 22),
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Drag handle
                Center(
                  child: Container(
                    width: 44,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'ເຂົ້າສູ່ລະບົບ',
                        style: TextStyle(
                          color: AppTheme.textBright,
                          fontSize: 22,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                    _ServerChip(onTap: _submitting ? null : _editServer),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  'ກະລຸນາໃສ່ຊື່ຜູ້ໃຊ້ ແລະ ລະຫັດຜ່ານ',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.65),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 20),

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
                  decoration: _inputDeco(
                    'driver001',
                    Icons.person_outline_rounded,
                  ),
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
                    letterSpacing: 0.5,
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
                const SizedBox(height: 14),

                _RememberMeRow(
                  remember: _rememberMe,
                  onChanged: _submitting
                      ? null
                      : (v) => setState(() => _rememberMe = v),
                ),
                const SizedBox(height: 18),

                SizedBox(
                  width: double.infinity,
                  height: 60,
                  child: FilledButton(
                    onPressed: _submitting ? null : _submit,
                    style: FilledButton.styleFrom(
                      backgroundColor: AppTheme.primary,
                      foregroundColor: Colors.white,
                      disabledBackgroundColor: AppTheme.primary.withValues(
                        alpha: 0.5,
                      ),
                      elevation: _submitting ? 0 : 6,
                      shadowColor: AppTheme.primary.withValues(alpha: 0.55),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(18),
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
                                'ເລີ່ມພາລະກິດ',
                                style: TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: 0.5,
                                ),
                              ),
                              SizedBox(width: 8),
                              Icon(Icons.arrow_forward_rounded, size: 22),
                            ],
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _label(String text) => Text(
    text,
    style: TextStyle(
      color: Colors.white.withValues(alpha: 0.85),
      fontSize: 12,
      fontWeight: FontWeight.w800,
      letterSpacing: 0.3,
    ),
  );

  InputDecoration _inputDeco(String hint, IconData icon) {
    return InputDecoration(
      hintText: hint,
      prefixIcon: Padding(
        padding: const EdgeInsets.only(left: 12, right: 8),
        child: Icon(icon, size: 20, color: AppTheme.brandOrange),
      ),
      prefixIconConstraints: const BoxConstraints(minWidth: 40),
      filled: true,
      fillColor: AppTheme.bgDark.withValues(alpha: 0.55),
      hintStyle: TextStyle(
        color: Colors.white.withValues(alpha: 0.3),
        fontWeight: FontWeight.w500,
      ),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: AppTheme.brandOrange, width: 2),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: AppTheme.error, width: 1.5),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: AppTheme.error, width: 2),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
    );
  }
}

InputDecoration _bottomSheetInputDeco(String hint, IconData icon) {
  return InputDecoration(
    hintText: hint,
    prefixIcon: Padding(
      padding: const EdgeInsets.only(left: 12, right: 8),
      child: Icon(icon, size: 20, color: AppTheme.brandOrange),
    ),
    prefixIconConstraints: const BoxConstraints(minWidth: 40),
    filled: true,
    fillColor: AppTheme.bgDark.withValues(alpha: 0.55),
    hintStyle: TextStyle(
      color: Colors.white.withValues(alpha: 0.3),
      fontWeight: FontWeight.w500,
    ),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: const BorderSide(color: AppTheme.brandOrange, width: 2),
    ),
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
  );
}

class _RememberMeRow extends StatelessWidget {
  const _RememberMeRow({required this.remember, required this.onChanged});

  final bool remember;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onChanged == null ? null : () => onChanged!(!remember),
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                gradient: remember
                    ? const LinearGradient(
                        colors: [
                          AppTheme.brandOrange,
                          AppTheme.brandOrangeDeep,
                        ],
                      )
                    : null,
                color: remember ? null : Colors.transparent,
                borderRadius: BorderRadius.circular(7),
                border: Border.all(
                  color: remember
                      ? AppTheme.brandOrange
                      : Colors.white.withValues(alpha: 0.3),
                  width: 1.5,
                ),
              ),
              child: remember
                  ? const Icon(
                      Icons.check_rounded,
                      color: Colors.white,
                      size: 14,
                    )
                  : null,
            ),
            const SizedBox(width: 10),
            Text(
              'ຈື່ຂ້ອຍໄວ້',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.85),
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ServerChip extends StatelessWidget {
  const _ServerChip({required this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppTheme.bgDark.withValues(alpha: 0.5),
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.dns_rounded,
                size: 14,
                color: Colors.white.withValues(alpha: 0.7),
              ),
              const SizedBox(width: 6),
              Text(
                'Server',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.85),
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
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: const BoxDecoration(
          color: AppTheme.bgCard,
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(AppTheme.radiusXl),
          ),
        ),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(999),
              ),
            ),
            const SizedBox(height: 18),
            const Row(
              children: [
                Icon(Icons.dns_rounded, color: AppTheme.brandOrange, size: 20),
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
              decoration: _bottomSheetInputDeco(
                'http://10.0.2.2:4000',
                Icons.link_rounded,
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              height: 52,
              child: FilledButton(
                onPressed: () =>
                    Navigator.pop(context, _controller.text.trim()),
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

// ════════════════════════════════════════════════════════════════════
// Backdrop - quiet operational canvas
// ════════════════════════════════════════════════════════════════════
class _Backdrop extends StatelessWidget {
  const _Backdrop();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            AppTheme.brandNavyDeep,
            AppTheme.brandNavy,
            AppTheme.brandNavyDeep,
          ],
        ),
      ),
    );
  }
}
