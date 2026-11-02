import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';

import '../services/log_buffer.dart';

/// Fallbacks that actually resolve to a fixed-width face per platform.
/// Flutter's bare 'monospace' family only resolves on Android.
const List<String> _monoFallback = <String>[
  'Menlo',
  'SF Mono',
  'Monaco',
  'Consolas',
  'DejaVu Sans Mono',
  'Roboto Mono',
  'Courier New',
  'monospace',
];

const TextStyle _monoStyle = TextStyle(
  fontFamily: 'Menlo',
  fontFamilyFallback: _monoFallback,
  fontSize: 11.5,
  height: 1.45,
  fontFeatures: [FontFeature.tabularFigures()],
);

/// A live log tail that can sit under the main content while debugging.
///
/// Reader problems here are usually only legible from the APDU trace, and by
/// the time a separate log page is opened the interesting lines have often
/// scrolled out of the buffer. Keeping the tail beside the UI that triggered it
/// keeps cause and effect together.
class LogConsole extends StatefulWidget {
  const LogConsole({
    super.key,
    required this.onClose,
    this.onResize,
    this.maxLines = 1000,
  });

  final VoidCallback onClose;

  /// Reports vertical drag on the top handle, in logical pixels.
  final ValueChanged<double>? onResize;
  final int maxLines;

  @override
  State<LogConsole> createState() => _LogConsoleState();
}

class _LogConsoleState extends State<LogConsole> {
  final List<LogRecord> _records = [];
  final ScrollController _scrollController = ScrollController();
  StreamSubscription<LogRecord>? _subscription;
  Timer? _flushTimer;
  bool _follow = true;
  String _filter = '';
  Level _minLevel = Level.ALL;

  /// How long new records are collected before the console repaints.
  ///
  /// Short enough to still read as a live tail, long enough that a burst of
  /// APDU trace lines costs one rebuild instead of one per line.
  static const Duration _flushInterval = Duration(milliseconds: 100);

  @override
  void initState() {
    super.initState();
    // Seed from the shared buffer so opening the console shows what already
    // happened, not only what happens next.
    final existing = LogBuffer().logs;
    _records.addAll(
      existing.length > widget.maxLines
          ? existing.sublist(existing.length - widget.maxLines)
          : existing,
    );
    _subscription = Logger.root.onRecord.listen(_onRecord);
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToEnd());
  }

  void _onRecord(LogRecord record) {
    if (!mounted) return;
    // Logger.root.onRecord is a synchronous broadcast stream, so this runs on
    // whatever stack emitted the log line -- including a widget's build method.
    // Calling setState() here would then be a setState-during-build error, so
    // the record is only buffered and the repaint is deferred to a timer.
    _records.add(record);
    final excess = _records.length - widget.maxLines;
    if (excess > 0) _records.removeRange(0, excess);
    _flushTimer ??= Timer(_flushInterval, _flush);
  }

  void _flush() {
    _flushTimer = null;
    if (!mounted) return;
    setState(() {});
    if (_follow) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToEnd());
    }
  }

  void _scrollToEnd() {
    if (!_scrollController.hasClients) return;
    _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _flushTimer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  List<LogRecord> get _visible {
    final needle = _filter.toLowerCase();
    return _records.where((record) {
      if (record.level < _minLevel) return false;
      if (needle.isEmpty) return true;
      return record.message.toLowerCase().contains(needle) ||
          record.loggerName.toLowerCase().contains(needle);
    }).toList();
  }

  _LevelPalette _paletteFor(Level level, ColorScheme scheme) {
    if (level >= Level.SEVERE) {
      return _LevelPalette(scheme.error, 'ERR');
    }
    if (level >= Level.WARNING) {
      return const _LevelPalette(Color(0xFFE0A030), 'WRN');
    }
    if (level >= Level.INFO) {
      return _LevelPalette(scheme.onSurface.withValues(alpha: 0.92), 'INF');
    }
    return _LevelPalette(scheme.onSurface.withValues(alpha: 0.45), 'DBG');
  }

  Future<void> _copyAll() async {
    final text = _visible
        .map(
          (record) =>
              '${record.time.toIso8601String()} ${record.level.name} '
              '${record.loggerName}: ${record.message}',
        )
        .join('\n');
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Copied ${_visible.length} lines'),
        behavior: SnackBarBehavior.floating,
        width: 240,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final records = _visible;
    final isDark = theme.brightness == Brightness.dark;
    final surface = isDark ? const Color(0xFF0E1116) : const Color(0xFFF7F8FA);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: surface,
        border: Border(
          top: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.6)),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.onResize != null) _buildResizeHandle(scheme),
          _buildHeader(theme, scheme, records.length),
          Expanded(
            child: records.isEmpty
                ? Center(
                    child: Text(
                      _records.isEmpty
                          ? 'Waiting for log records...'
                          : 'Nothing matches this filter',
                      style: _monoStyle.copyWith(
                        color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                      ),
                    ),
                  )
                : Scrollbar(
                    controller: _scrollController,
                    thumbVisibility: true,
                    child: ListView.builder(
                      controller: _scrollController,
                      primary: false,
                      padding: const EdgeInsets.fromLTRB(4, 6, 12, 10),
                      itemCount: records.length,
                      itemBuilder: (context, index) =>
                          _buildRow(records[index], scheme, isDark),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(ThemeData theme, ColorScheme scheme, int shown) {
    return Container(
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
        border: Border(
          bottom: BorderSide(
            color: scheme.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.terminal_rounded, size: 15, color: scheme.primary),
          const SizedBox(width: 7),
          Text(
            'Console',
            style: theme.textTheme.labelMedium?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: 0.2,
            ),
          ),
          const SizedBox(width: 8),
          _Pill(
            text: '$shown',
            colour: scheme.primary.withValues(alpha: 0.14),
            textColour: scheme.primary,
          ),
          const SizedBox(width: 12),
          Expanded(child: _buildFilterField(scheme)),
          const SizedBox(width: 8),
          _buildLevelSelector(scheme),
          const SizedBox(width: 4),
          _IconAction(
            icon: _follow
                ? Icons.vertical_align_bottom_rounded
                : Icons.pause_rounded,
            tooltip: _follow ? 'Following new lines' : 'Paused',
            active: _follow,
            onPressed: () => setState(() {
              _follow = !_follow;
              if (_follow) _scrollToEnd();
            }),
          ),
          _IconAction(
            icon: Icons.copy_rounded,
            tooltip: 'Copy visible lines',
            onPressed: _copyAll,
          ),
          _IconAction(
            icon: Icons.playlist_remove_rounded,
            tooltip: 'Clear',
            onPressed: () => setState(_records.clear),
          ),
          _IconAction(
            icon: Icons.close_rounded,
            tooltip: 'Close console',
            onPressed: widget.onClose,
          ),
        ],
      ),
    );
  }

  Widget _buildFilterField(ColorScheme scheme) {
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(6),
      borderSide: BorderSide(
        color: scheme.outlineVariant.withValues(alpha: 0.6),
      ),
    );
    return SizedBox(
      height: 26,
      child: TextField(
        style: _monoStyle.copyWith(fontSize: 11, height: 1.0),
        cursorHeight: 12,
        // isCollapsed plus explicit vertical centring is what keeps the text,
        // the hint and the prefix icon on one line inside a fixed height.
        textAlignVertical: TextAlignVertical.center,
        decoration: InputDecoration(
          isCollapsed: true,
          hintText: 'Filter by message or logger',
          hintStyle: _monoStyle.copyWith(
            fontSize: 11,
            height: 1.0,
            color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
          ),
          prefixIcon: Icon(
            Icons.search_rounded,
            size: 13,
            color: scheme.onSurfaceVariant,
          ),
          prefixIconConstraints: const BoxConstraints(
            minWidth: 24,
            minHeight: 24,
          ),
          filled: true,
          fillColor: scheme.surface.withValues(alpha: 0.6),
          contentPadding: const EdgeInsets.fromLTRB(0, 7, 8, 7),
          border: border,
          enabledBorder: border,
          focusedBorder: border.copyWith(
            borderSide: BorderSide(
              color: scheme.primary.withValues(alpha: 0.5),
            ),
          ),
        ),
        onChanged: (value) => setState(() => _filter = value),
      ),
    );
  }

  Widget _buildResizeHandle(ColorScheme scheme) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeRow,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // Dragging up grows the console, so the delta is inverted.
        onVerticalDragUpdate: (details) =>
            widget.onResize?.call(details.delta.dy),
        child: SizedBox(
          height: 7,
          width: double.infinity,
          child: Center(
            child: Container(
              width: 46,
              height: 3,
              decoration: BoxDecoration(
                color: scheme.onSurfaceVariant.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLevelSelector(ColorScheme scheme) {
    const levels = <(String, Level)>[
      ('All', Level.ALL),
      ('Info', Level.INFO),
      ('Warn', Level.WARNING),
      ('Error', Level.SEVERE),
    ];
    return Tooltip(
      message: 'Minimum level',
      child: DropdownButtonHideUnderline(
        child: DropdownButton<Level>(
          value: _minLevel,
          isDense: true,
          borderRadius: BorderRadius.circular(8),
          style: _monoStyle.copyWith(fontSize: 11, color: scheme.onSurface),
          icon: Icon(
            Icons.arrow_drop_down_rounded,
            size: 16,
            color: scheme.onSurfaceVariant,
          ),
          items: [
            for (final (label, level) in levels)
              DropdownMenuItem(value: level, child: Text(label)),
          ],
          onChanged: (value) => setState(() => _minLevel = value ?? Level.ALL),
        ),
      ),
    );
  }

  Widget _buildRow(LogRecord record, ColorScheme scheme, bool isDark) {
    final palette = _paletteFor(record.level, scheme);
    final stamp = record.time.toIso8601String().substring(11, 23);
    final highlight = record.level >= Level.WARNING;

    return Container(
      margin: const EdgeInsets.only(bottom: 1),
      padding: const EdgeInsets.fromLTRB(8, 2, 6, 2),
      decoration: BoxDecoration(
        color: highlight
            ? palette.colour.withValues(alpha: isDark ? 0.09 : 0.07)
            : null,
        border: Border(
          left: BorderSide(
            color: highlight ? palette.colour : Colors.transparent,
            width: 2,
          ),
        ),
        borderRadius: const BorderRadius.horizontal(right: Radius.circular(4)),
      ),
      child: SelectableText.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '$stamp  ',
              style: TextStyle(
                color: scheme.onSurfaceVariant.withValues(alpha: 0.55),
              ),
            ),
            TextSpan(
              text: '${palette.tag}  ',
              style: TextStyle(
                color: palette.colour,
                fontWeight: FontWeight.w700,
              ),
            ),
            TextSpan(
              text: '${record.loggerName}  ',
              style: TextStyle(color: scheme.primary.withValues(alpha: 0.85)),
            ),
            TextSpan(
              text: record.message,
              style: TextStyle(color: palette.colour),
            ),
          ],
        ),
        style: _monoStyle,
      ),
    );
  }
}

class _LevelPalette {
  const _LevelPalette(this.colour, this.tag);

  final Color colour;
  final String tag;
}

class _Pill extends StatelessWidget {
  const _Pill({
    required this.text,
    required this.colour,
    required this.textColour,
  });

  final String text;
  final Color colour;
  final Color textColour;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: colour,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        text,
        style: _monoStyle.copyWith(
          fontSize: 10,
          height: 1.1,
          color: textColour,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _IconAction extends StatelessWidget {
  const _IconAction({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.active = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.all(5),
          child: Icon(
            icon,
            size: 15,
            color: active ? scheme.primary : scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
