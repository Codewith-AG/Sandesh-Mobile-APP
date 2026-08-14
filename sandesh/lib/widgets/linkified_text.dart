import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Renders a message body as rich text where any detected URL is highlighted
/// (accent color + underline). Long-pressing a link for ~1.1s copies it to the
/// clipboard (WhatsApp-style), showing a confirmation SnackBar.
///
/// Plain (non-link) text is rendered with [style]; links use [linkColor] and
/// an underline decoration so they stand out on both light and dark bubbles.
class LinkifiedText extends StatefulWidget {
  final String text;
  final TextStyle style;
  final Color linkColor;

  const LinkifiedText({
    super.key,
    required this.text,
    required this.style,
    required this.linkColor,
  });

  @override
  State<LinkifiedText> createState() => _LinkifiedTextState();
}

class _LinkifiedTextState extends State<LinkifiedText> {
  // Matches http/https URLs and bare www.* links.
  static final RegExp _urlRegExp = RegExp(
    r'((https?:\/\/)|(www\.))[^\s]+',
    caseSensitive: false,
  );

  final List<GestureRecognizer> _recognizers = [];

  @override
  void dispose() {
    for (final r in _recognizers) {
      r.dispose();
    }
    super.dispose();
  }

  void _copyLink(String rawUrl) {
    // Trim trailing punctuation that often clings to URLs in prose.
    var url = rawUrl;
    while (url.isNotEmpty && '.,;:!?)]}"\''.contains(url.characters.last)) {
      url = url.substring(0, url.length - 1);
    }
    Clipboard.setData(ClipboardData(text: url));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Link copied', style: widget.style.copyWith(color: Colors.white)),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Clean up recognizers from a previous build before re-creating them.
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();

    final text = widget.text;
    final spans = <InlineSpan>[];
    int start = 0;

    for (final match in _urlRegExp.allMatches(text)) {
      if (match.start > start) {
        spans.add(TextSpan(text: text.substring(start, match.start), style: widget.style));
      }
      final linkText = text.substring(match.start, match.end);

      // Long-press (~1.1s) copies the link. A tap does nothing so normal
      // scrolling/selection is unaffected.
      final recognizer = LongPressGestureRecognizer(
        duration: const Duration(milliseconds: 1100),
      )..onLongPress = () => _copyLink(linkText);
      _recognizers.add(recognizer);

      spans.add(TextSpan(
        text: linkText,
        style: widget.style.copyWith(
          color: widget.linkColor,
          decoration: TextDecoration.underline,
          decorationColor: widget.linkColor,
          fontWeight: FontWeight.w600,
        ),
        recognizer: recognizer,
      ));
      start = match.end;
    }

    if (start < text.length) {
      spans.add(TextSpan(text: text.substring(start), style: widget.style));
    }

    return Text.rich(TextSpan(children: spans));
  }
}
