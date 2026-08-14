import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:google_fonts/google_fonts.dart';

class UserAvatar extends StatelessWidget {
  final String? imageUrl;
  final String name;
  final double radius;
  final VoidCallback? onTap;

  const UserAvatar({
    super.key,
    this.imageUrl,
    required this.name,
    this.radius = 28,
    this.onTap,
  });

  double _getFontSize(double radius) {
    if (radius <= 20) return 18;
    if (radius <= 28) return 24;
    if (radius <= 56) return 40;
    return 48;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final fallbackLetter = name.isNotEmpty ? name[0].toUpperCase() : '?';

    final fallbackWidget = CircleAvatar(
      radius: radius,
      backgroundColor: cs.outlineVariant,
      child: Text(
        fallbackLetter,
        style: GoogleFonts.inter(
          color: cs.primary,
          fontWeight: FontWeight.w700,
          fontSize: _getFontSize(radius),
        ),
      ),
    );

    Widget avatar;

    if (imageUrl != null && imageUrl!.isNotEmpty && imageUrl!.startsWith('http')) {
      avatar = CircleAvatar(
        radius: radius,
        backgroundColor: cs.outlineVariant,
        child: ClipOval(
          child: CachedNetworkImage(
            imageUrl: imageUrl!,
            width: radius * 2,
            height: radius * 2,
            fit: BoxFit.cover,
            placeholder: (context, url) => fallbackWidget,
            errorWidget: (context, url, error) => fallbackWidget,
          ),
        ),
      );
    } else {
      avatar = fallbackWidget;
    }

    if (onTap != null) {
      return GestureDetector(
        onTap: onTap,
        child: avatar,
      );
    }

    return avatar;
  }
}
