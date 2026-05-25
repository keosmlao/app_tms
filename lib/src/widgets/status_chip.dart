import 'package:flutter/material.dart';

class StatusChip extends StatelessWidget {
  const StatusChip({
    super.key,
    required this.label,
    required this.backgroundColor,
    required this.foregroundColor,
  });

  final String label;
  final Color backgroundColor;
  final Color foregroundColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: backgroundColor.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: foregroundColor.withValues(alpha: 0.3)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: foregroundColor,
          fontWeight: FontWeight.w700,
          fontSize: 11,
        ),
      ),
    );
  }
}
