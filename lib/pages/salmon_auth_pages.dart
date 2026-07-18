import 'dart:async';

import 'package:fl_clash/services/salmon_service.dart';
import 'package:flutter/material.dart';

class SalmonAuthResult {
  final String email;
  final String? password;
  final SalmonSession? session;
  const SalmonAuthResult(this.email, [this.password, this.session]);
}

class SalmonRegisterPage extends StatefulWidget {
  const SalmonRegisterPage({super.key});

  @override
  State<SalmonRegisterPage> createState() => _SalmonRegisterPageState();
}

class _SalmonRegisterPageState extends State<SalmonRegisterPage> {
  final email = TextEditingController();
  final code = TextEditingController();
  final password = TextEditingController();
  final confirm = TextEditingController();
  final invite = TextEditingController();
  final formKey = GlobalKey<FormState>();
  bool busy = false;

  @override
  void dispose() {
    email.dispose();
    code.dispose();
    password.dispose();
    confirm.dispose();
    invite.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    if (busy || formKey.currentState?.validate() != true) return;
    setState(() => busy = true);
    try {
      final session = await salmonService.register(
        email: email.text,
        password: password.text,
        emailCode: code.text,
        inviteCode: invite.text,
      );
      if (!mounted) return;
      Navigator.pop(
        context,
        SalmonAuthResult(email.text.trim(), password.text, session),
      );
    } catch (error) {
      if (mounted) _showError(error);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void _showError(Object error) => ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(salmonFriendlyError(error, fallback: '注册失败，请检查填写内容')),
    ),
  );

  @override
  Widget build(BuildContext context) => _AuthScaffold(
    title: '创建账号',
    subtitle: '注册后即可同步套餐与线路',
    child: Form(
      key: formKey,
      child: Column(
        children: [
          _emailField(email),
          const SizedBox(height: 14),
          _CodeField(email: email, controller: code),
          const SizedBox(height: 14),
          _passwordField(password, '设置密码'),
          const SizedBox(height: 14),
          TextFormField(
            controller: confirm,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: '确认密码',
              prefixIcon: Icon(Icons.verified_user_rounded),
            ),
            validator: (value) => value != password.text ? '两次输入的密码不一致' : null,
          ),
          const SizedBox(height: 14),
          TextFormField(
            controller: invite,
            decoration: const InputDecoration(
              labelText: '邀请码（选填）',
              prefixIcon: Icon(Icons.card_giftcard_rounded),
            ),
          ),
          const SizedBox(height: 24),
          _SubmitButton(label: '立即注册', busy: busy, onPressed: submit),
        ],
      ),
    ),
  );
}

class SalmonForgotPasswordPage extends StatefulWidget {
  const SalmonForgotPasswordPage({super.key});

  @override
  State<SalmonForgotPasswordPage> createState() =>
      _SalmonForgotPasswordPageState();
}

class _SalmonForgotPasswordPageState extends State<SalmonForgotPasswordPage> {
  final email = TextEditingController();
  final code = TextEditingController();
  final password = TextEditingController();
  final confirm = TextEditingController();
  final formKey = GlobalKey<FormState>();
  bool busy = false;

  @override
  void dispose() {
    email.dispose();
    code.dispose();
    password.dispose();
    confirm.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    if (busy || formKey.currentState?.validate() != true) return;
    setState(() => busy = true);
    try {
      await salmonService.resetPassword(
        email: email.text,
        password: password.text,
        emailCode: code.text,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('密码已重置，请重新登录')));
      Navigator.pop(context, SalmonAuthResult(email.text.trim()));
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(salmonFriendlyError(error, fallback: '重置失败，请检查验证码')),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => _AuthScaffold(
    title: '找回密码',
    subtitle: '通过注册邮箱验证身份',
    child: Form(
      key: formKey,
      child: Column(
        children: [
          _emailField(email),
          const SizedBox(height: 14),
          _CodeField(email: email, controller: code),
          const SizedBox(height: 14),
          _passwordField(password, '新密码'),
          const SizedBox(height: 14),
          TextFormField(
            controller: confirm,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: '确认新密码',
              prefixIcon: Icon(Icons.verified_user_rounded),
            ),
            validator: (value) => value != password.text ? '两次输入的密码不一致' : null,
          ),
          const SizedBox(height: 24),
          _SubmitButton(label: '确认重置', busy: busy, onPressed: submit),
        ],
      ),
    ),
  );
}

Widget _emailField(TextEditingController controller) => TextFormField(
  controller: controller,
  keyboardType: TextInputType.emailAddress,
  autofillHints: const [AutofillHints.email],
  decoration: const InputDecoration(
    labelText: '邮箱',
    prefixIcon: Icon(Icons.mail_rounded),
  ),
  validator: (value) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) return '请输入邮箱';
    if (!text.contains('@')) return '邮箱格式不正确';
    return null;
  },
);

Widget _passwordField(TextEditingController controller, String label) =>
    TextFormField(
      controller: controller,
      obscureText: true,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: const Icon(Icons.lock_rounded),
      ),
      validator: (value) => (value?.length ?? 0) < 8 ? '密码至少需要 8 位' : null,
    );

class _CodeField extends StatefulWidget {
  final TextEditingController email;
  final TextEditingController controller;
  const _CodeField({required this.email, required this.controller});

  @override
  State<_CodeField> createState() => _CodeFieldState();
}

class _CodeFieldState extends State<_CodeField> {
  Timer? timer;
  int seconds = 0;
  bool sending = false;

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  Future<void> send() async {
    if (sending || seconds > 0 || !widget.email.text.contains('@')) {
      if (!widget.email.text.contains('@')) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('请先填写正确的邮箱')));
      }
      return;
    }
    setState(() => sending = true);
    try {
      await salmonService.sendEmailCode(widget.email.text);
      if (!mounted) return;
      setState(() => seconds = 60);
      timer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (!mounted || seconds <= 1) {
          timer.cancel();
          if (mounted) setState(() => seconds = 0);
        } else {
          setState(() => seconds--);
        }
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('验证码已发送')));
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(salmonFriendlyError(error, fallback: '验证码发送失败')),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  @override
  Widget build(BuildContext context) => TextFormField(
    controller: widget.controller,
    keyboardType: TextInputType.number,
    decoration: InputDecoration(
      labelText: '邮箱验证码',
      prefixIcon: const Icon(Icons.shield_rounded),
      suffixIcon: TextButton(
        onPressed: send,
        child: Text(seconds > 0 ? '${seconds}s' : (sending ? '发送中' : '获取验证码')),
      ),
    ),
    validator: (value) => (value?.trim().isEmpty ?? true) ? '请输入邮箱验证码' : null,
  );
}

class _AuthScaffold extends StatelessWidget {
  final String title;
  final String subtitle;
  final Widget child;
  const _AuthScaffold({
    required this.title,
    required this.subtitle,
    required this.child,
  });

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(title)),
    body: Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFF5F8FE), Color(0xFFF3F6FC)],
        ),
      ),
      child: SafeArea(
        top: false,
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(22),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 430),
              child: Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: .96),
                  borderRadius: BorderRadius.circular(28),
                  border: Border.all(color: const Color(0xFFD8E3F3)),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x182F6BFF),
                      blurRadius: 28,
                      offset: Offset(0, 12),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w900,
                        color: Color(0xFF10233F),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      subtitle,
                      style: const TextStyle(color: Color(0xFF7186A5)),
                    ),
                    const SizedBox(height: 24),
                    child,
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _SubmitButton extends StatelessWidget {
  final String label;
  final bool busy;
  final VoidCallback onPressed;
  const _SubmitButton({
    required this.label,
    required this.busy,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) => FilledButton.icon(
    onPressed: busy ? null : onPressed,
    icon: busy
        ? const SizedBox.square(
            dimension: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : const Icon(Icons.arrow_forward_rounded),
    label: Text(busy ? '请稍候…' : label),
    style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(54)),
  );
}
