import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/services/salmon_service.dart';
import 'package:flutter/material.dart';

class SalmonLoadError extends StatelessWidget {
  final Object error;
  final VoidCallback onRetry;

  const SalmonLoadError({
    super.key,
    required this.error,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(salmonFriendlyError(error), textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: onRetry,
              child: Text(context.appLocalizations.salmonRetry),
            ),
          ],
        ),
      ),
    );
  }
}
