import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/pages/salmon_auth_pages.dart';
import 'package:fl_clash/services/salmon_profile_sync.dart';
import 'package:fl_clash/services/salmon_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

enum _SalmonGateStatus { loading, login, ready }

class SalmonGate extends ConsumerStatefulWidget {
  final Widget child;

  const SalmonGate({super.key, required this.child});

  @override
  ConsumerState<SalmonGate> createState() => _SalmonGateState();
}

class _SalmonGateState extends ConsumerState<SalmonGate> {
  final _accountController = TextEditingController();
  final _passwordController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  _SalmonGateStatus _status = _SalmonGateStatus.loading;
  String? _error;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    salmonService.sessionRevision.addListener(_onSessionChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _restore());
  }

  void _onSessionChanged() {
    if (mounted) _setStatus(_SalmonGateStatus.login);
  }

  @override
  void dispose() {
    salmonService.sessionRevision.removeListener(_onSessionChanged);
    _accountController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _restore() async {
    try {
      final session = await salmonService.restore();
      if (session == null) {
        _setStatus(_SalmonGateStatus.login);
        return;
      }
      // A valid authentication session is sufficient to enter the app.
      // Subscription/profile availability is a separate concern: new users
      // without a plan must still be able to visit the store and account pages.
      Profile? cachedProfile;
      for (final profile in ref.read(profilesProvider)) {
        if (profile.label == salmonProfileLabel) {
          cachedProfile = profile;
          break;
        }
      }
      var synced = false;
      if (session.subscribeUrl.isNotEmpty) {
        try {
          await _syncProfile(session.subscribeUrl);
          synced = true;
        } catch (error) {
          debugPrint('Subscription sync skipped: $error');
        }
      }
      // Never expose a managed profile left by another account. The cached
      // profile is only safe when it belongs to this exact subscription URL.
      if (!synced &&
          cachedProfile != null &&
          cachedProfile.url == session.subscribeUrl) {
        ref.read(currentProfileIdProvider.notifier).value = cachedProfile.id;
        ref
            .read(setupActionProvider.notifier)
            .applyProfileDebounce(force: false, silence: true);
      }
      _setStatus(_SalmonGateStatus.ready);
    } catch (error) {
      debugPrint('Session restore failed: $error');
      _setStatus(_SalmonGateStatus.login);
    }
  }

  Future<void> _login() async {
    if (_submitting || _formKey.currentState?.validate() != true) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final session = await salmonService.login(
        account: _accountController.text.trim(),
        password: _passwordController.text,
      );
      _passwordController.clear();
      if (session.subscribeUrl.isNotEmpty) {
        try {
          await _syncProfile(session.subscribeUrl);
        } catch (error) {
          debugPrint('Post-login subscription sync skipped: $error');
        }
      }
      _setStatus(_SalmonGateStatus.ready);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = _friendlyError(error);
      });
    }
  }

  Future<void> _openRegister() async {
    final result = await Navigator.of(context).push<SalmonAuthResult>(
      MaterialPageRoute(builder: (_) => const SalmonRegisterPage()),
    );
    if (result == null || !mounted) return;
    _accountController.text = result.email;
    if (result.session != null) {
      _passwordController.clear();
      _setStatus(_SalmonGateStatus.ready);
      return;
    }
    if (result.password != null) {
      _passwordController.text = result.password!;
      await _login();
    }
  }

  Future<void> _openForgotPassword() async {
    final result = await Navigator.of(context).push<SalmonAuthResult>(
      MaterialPageRoute(builder: (_) => const SalmonForgotPasswordPage()),
    );
    if (result != null && mounted) _accountController.text = result.email;
  }

  Future<void> _openLink(String value) async {
    final uri = Uri.parse(value);
    final opened = await launchUrl(uri, mode: LaunchMode.inAppBrowserView);
    if (!opened && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('页面暂时无法打开，请稍后重试')));
    }
  }

  Future<void> _syncProfile(String subscribeUrl) async {
    try {
      await _saveProfile(subscribeUrl);
    } catch (_) {
      final baseUrl = await salmonService.savedBaseUrl();
      final source = Uri.tryParse(subscribeUrl);
      final base = baseUrl == null ? null : Uri.tryParse(baseUrl);
      if (source == null || base == null || base.host.isEmpty) rethrow;
      final fallbackUrl = Uri(
        scheme: base.scheme,
        host: base.host,
        port: base.hasPort ? base.port : null,
        path: source.path,
        query: source.hasQuery ? source.query : null,
        fragment: source.hasFragment ? source.fragment : null,
      ).toString();
      if (fallbackUrl == subscribeUrl) rethrow;
      await _saveProfile(fallbackUrl);
    }
  }

  Future<void> _saveProfile(String subscribeUrl) async {
    await syncSalmonProfile(ref, subscribeUrl);
  }

  String _friendlyError(Object error) {
    final value = error.toString().replaceFirst('Bad state: ', '').trim();
    final lower = value.toLowerCase();
    if (lower.contains('401') ||
        lower.contains('403') ||
        lower.contains('422') ||
        lower.contains('invalid credential') ||
        lower.contains('incorrect password') ||
        lower.contains('email or password') ||
        lower.contains('账号或密码') ||
        lower.contains('邮箱或密码')) {
      return '账号或密码错误';
    }
    if (value.contains('Failed host lookup') ||
        value.contains('SocketException') ||
        value.contains('connection error') ||
        value.contains('connection timeout') ||
        value.contains('receive timeout')) {
      return '服务器暂时无法连接，请稍后重试';
    }
    return value.isEmpty ? context.appLocalizations.salmonLoginFailed : value;
  }

  void _setStatus(_SalmonGateStatus status) {
    if (!mounted) return;
    setState(() {
      _status = status;
      _submitting = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return switch (_status) {
      _SalmonGateStatus.loading => const _SalmonLoadingView(),
      _SalmonGateStatus.login => _buildLoginView(context),
      _SalmonGateStatus.ready => widget.child,
    };
  }

  Widget _buildLoginView(BuildContext context) {
    final appLocalizations = context.appLocalizations;
    return Scaffold(
      body: Stack(
        children: [
          const Positioned(
            left: -90,
            top: -70,
            child: _LoginBubble(size: 230, color: Color(0xFFD9E8FF)),
          ),
          const Positioned(
            right: -70,
            bottom: -50,
            child: _LoginBubble(size: 210, color: Color(0xFFE7EDFF)),
          ),
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(22),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 430),
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(24, 30, 24, 26),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: .94),
                      borderRadius: BorderRadius.circular(34),
                      border: Border.all(color: const Color(0xFFD8E3F3)),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF245CFF).withValues(alpha: .15),
                          blurRadius: 38,
                          offset: const Offset(0, 18),
                        ),
                      ],
                    ),
                    child: Form(
                      key: _formKey,
                      child: AutofillGroup(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            SizedBox(
                              height: 112,
                              child: Image.asset(
                                'assets/images/brand/salmon-coral-transparent.png',
                                fit: BoxFit.contain,
                              ),
                            ),
                            const SizedBox(height: 18),
                            Text(
                              appLocalizations.salmonWelcome,
                              textAlign: TextAlign.center,
                              style: context.textTheme.headlineMedium?.copyWith(
                                color: const Color(0xFF10233F),
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                            const SizedBox(height: 28),
                            TextFormField(
                              controller: _accountController,
                              enabled: !_submitting,
                              keyboardType: TextInputType.emailAddress,
                              textInputAction: TextInputAction.next,
                              autofillHints: const [AutofillHints.username],
                              decoration: InputDecoration(
                                labelText: appLocalizations.account,
                                hintText: '请输入邮箱或账号',
                                prefixIcon: const Icon(Icons.person_rounded),
                              ),
                              validator: (value) =>
                                  value == null || value.trim().isEmpty
                                  ? appLocalizations.salmonRequiredField
                                  : null,
                            ),
                            const SizedBox(height: 16),
                            TextFormField(
                              controller: _passwordController,
                              enabled: !_submitting,
                              obscureText: true,
                              textInputAction: TextInputAction.done,
                              autofillHints: const [AutofillHints.password],
                              decoration: InputDecoration(
                                labelText: appLocalizations.password,
                                hintText: '请输入登录密码',
                                prefixIcon: const Icon(Icons.lock_rounded),
                              ),
                              onFieldSubmitted: (_) => _login(),
                              validator: (value) =>
                                  value == null || value.isEmpty
                                  ? appLocalizations.salmonRequiredField
                                  : null,
                            ),
                            const SizedBox(height: 6),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                TextButton(
                                  onPressed: _submitting ? null : _openRegister,
                                  child: const Text('注册账号'),
                                ),
                                TextButton(
                                  onPressed: _submitting
                                      ? null
                                      : _openForgotPassword,
                                  child: const Text('忘记密码？'),
                                ),
                              ],
                            ),
                            if (_error != null) ...[
                              const SizedBox(height: 16),
                              Text(
                                _error!,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: context.colorScheme.error,
                                ),
                              ),
                            ],
                            const SizedBox(height: 24),
                            FilledButton.icon(
                              onPressed: _submitting ? null : _login,
                              icon: _submitting
                                  ? const SizedBox.square(
                                      dimension: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.login),
                              label: Text(
                                _submitting
                                    ? appLocalizations.salmonLoggingIn
                                    : appLocalizations.salmonLogin,
                              ),
                              style: FilledButton.styleFrom(
                                minimumSize: const Size.fromHeight(54),
                                backgroundColor: const Color(0xFF245CFF),
                                textStyle: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                            const SizedBox(height: 16),
                            Row(
                              children: [
                                Expanded(
                                  child: OutlinedButton.icon(
                                    onPressed: () =>
                                        _openLink(salmonSupportUrl),
                                    icon: const Icon(
                                      Icons.support_agent_rounded,
                                    ),
                                    label: const Text('在线客服'),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: OutlinedButton.icon(
                                    onPressed: () =>
                                        _openLink(salmonWebsiteUrl),
                                    icon: const Icon(Icons.language_rounded),
                                    label: const Text('官方网站'),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LoginBubble extends StatelessWidget {
  final double size;
  final Color color;
  const _LoginBubble({required this.size, required this.color});

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}

class _SalmonLoadingView extends StatelessWidget {
  const _SalmonLoadingView();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFFF3F6FC), Color(0xFFE9EEFF), Color(0xFFF0F3FC)],
          ),
        ),
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 42, vertical: 38),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: .88),
              borderRadius: BorderRadius.circular(34),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF245CFF).withValues(alpha: .13),
                  blurRadius: 30,
                  offset: const Offset(0, 14),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 132,
                  height: 106,
                  child: Image.asset(
                    'assets/images/brand/salmon-coral-transparent.png',
                    fit: BoxFit.contain,
                  ),
                ),
                const SizedBox(height: 22),
                const SizedBox(
                  width: 150,
                  child: LinearProgressIndicator(
                    minHeight: 6,
                    borderRadius: BorderRadius.all(Radius.circular(8)),
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  context.appLocalizations.salmonLoading,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF10233F),
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  '连接云端中',
                  style: TextStyle(fontSize: 12, color: Color(0xFF64789A)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
