import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/enums/lang_list.dart';
import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/service/dictionary/dictionary_service.dart';
import 'package:anx_reader/service/dictionary/stardict.dart';
import 'package:anx_reader/service/dictionary/system_dictionary.dart';
import 'package:anx_reader/service/translate/index.dart';
import 'package:anx_reader/widgets/common/axis_flex.dart';
import 'package:flutter/material.dart';
import 'package:pointer_interceptor/pointer_interceptor.dart';
import 'dart:async';

class TranslationMenu extends StatefulWidget {
  const TranslationMenu({
    super.key,
    required this.content,
    required this.decoration,
    required this.axis,
    this.contextText,
  });
  final String content;
  final BoxDecoration decoration;
  final Axis axis;
  final String? contextText;

  @override
  State<TranslationMenu> createState() => _TranslationMenuState();
}

class _TranslationMenuState extends State<TranslationMenu> {
  Widget? _translationWidget;
  // Local dictionary entries for a word or short term; null until looked up.
  List<DictionaryEntry>? _entries;
  // Whether iOS's own dictionaries have the term, for a button to open them.
  bool _systemHasDefinition = false;
  Timer? _debounceTimer;
  bool _translationInitialized = false;

  @override
  void initState() {
    super.initState();
    _initializeTranslation();
  }

  void _initializeTranslation() {
    // Use addPostFrameCallback to ensure the UI is rendered first
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _translationInitialized) return;

      // Debounce: Delay the translation call to ensure context has stopped updating
      _debounceTimer?.cancel();
      _debounceTimer = Timer(const Duration(milliseconds: 300), () {
        if (!mounted || _translationInitialized) return;

        _translationInitialized = true;
        _lookUpThenTranslate();
      });
    });
  }

  /// A word or short term is looked up in the local dictionaries first, which
  /// works offline; online translation runs only when they have nothing, or
  /// when asked for. Passages go straight to translation.
  Future<void> _lookUpThenTranslate() async {
    var entries = const <DictionaryEntry>[];
    if (isDictionaryTerm(widget.content)) {
      try {
        entries = await dictionaryLibrary.lookup(widget.content);
      } catch (_) {
        entries = const [];
      }
      SystemDictionary.hasDefinition(widget.content).then((has) {
        if (mounted && has) setState(() => _systemHasDefinition = true);
      });
    }
    if (!mounted) return;
    setState(() {
      _entries = entries;
      if (entries.isEmpty) _translateOnline();
    });
  }

  void _translateOnline() {
    final effectiveContextText =
        (widget.contextText?.trim().isEmpty ?? true) ? null : widget.contextText;
    _translationWidget = translateText(
      widget.content,
      contextText: effectiveContextText,
    );
  }

  Widget _dictionaryEntries(List<DictionaryEntry> entries) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final entry in entries) ...[
          Text(
            '${entry.headword} · ${entry.dictionary}',
            style: theme.textTheme.labelSmall
                ?.copyWith(color: theme.colorScheme.primary),
          ),
          const SizedBox(height: 2),
          Text(entry.definition, style: const TextStyle(fontSize: 14)),
          const SizedBox(height: 8),
        ],
        Wrap(
          spacing: 12,
          children: [
            if (_translationWidget == null)
              PointerInterceptor(
                child: TextButton.icon(
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: () => setState(_translateOnline),
                  icon: const Icon(Icons.translate, size: 16),
                  label: Text(L10n.of(context).dictionaryOnlineTranslate),
                ),
              ),
            if (_systemHasDefinition) _systemDictionaryButton(),
          ],
        ),
      ],
    );
  }

  Widget _systemDictionaryButton() => PointerInterceptor(
        child: TextButton.icon(
          style: TextButton.styleFrom(
            padding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
          ),
          onPressed: () => SystemDictionary.show(widget.content),
          icon: const Icon(Icons.menu_book_outlined, size: 16),
          label: Text(L10n.of(context).dictionarySystemLookUp),
        ),
      );

  @override
  void dispose() {
    _debounceTimer?.cancel();
    super.dispose();
  }

  Widget _langPicker(bool isFrom) {
    final MenuController menuController = MenuController();

    return PointerInterceptor(
      child: MenuAnchor(
        style: MenuStyle(
          backgroundColor: WidgetStateProperty.all(
            Theme.of(context).colorScheme.secondaryContainer,
          ),
          maximumSize: WidgetStateProperty.all(const Size(300, 300)),
        ),
        controller: menuController,
        menuChildren: [
          for (var lang in LangListEnum.values)
            PointerInterceptor(
              child: MenuItemButton(
                onPressed: () {
                  if (isFrom) {
                    Prefs().translateFrom = lang;
                  } else {
                    Prefs().translateTo = lang;
                  }
                },
                child: Text(lang.getNative(context)),
              ),
            ),
        ],
        builder: (context, controller, child) {
          return GestureDetector(
            onTap: () {
              if (controller.isOpen) {
                controller.close();
              } else {
                controller.open();
              }
            },
            child: Text(
              isFrom
                  ? Prefs().translateFrom.getNative(context)
                  : Prefs().translateTo.getNative(context),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // print('Building TranslationMenu');
    return Expanded(
      child: AnimatedSize(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
        child: Container(
          height: widget.axis == Axis.vertical ? double.infinity : 150,
          width: widget.axis == Axis.vertical ? 100 : double.infinity,
          decoration: widget.decoration,
          padding: const EdgeInsets.all(8),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.content,
                  style: const TextStyle(
                    fontSize: 16,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(height: 8),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Show translation widget if initialized, otherwise show loading placeholder
                    if (_entries?.isNotEmpty ?? false)
                      _dictionaryEntries(_entries!),
                    // With no local entry the system dictionary still belongs
                    // above the online translation.
                    if ((_entries?.isEmpty ?? false) && _systemHasDefinition)
                      _systemDictionaryButton(),
                    if (_translationWidget != null)
                      _translationWidget!
                    else if (_entries == null)
                      const SizedBox(
                        height: 20,
                        child: Center(child: Text('...')),
                      ),
                    const Divider(),
                    AxisFlex(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      axis: widget.axis,
                      children: [
                        _langPicker(true),
                        Transform.rotate(
                            angle: widget.axis == Axis.horizontal ? 0 : 1.57,
                            child: Icon(Icons.arrow_forward_ios, size: 16)),
                        _langPicker(false),
                        if (widget.axis == Axis.horizontal) const Spacer(),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
