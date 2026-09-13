import 'package:anx_reader/service/tts/text/chinese_number.dart';

/// How chemical formulas are read aloud.
enum FormulaReading {
  /// Letter by letter with counts and charge: H3O+ → H 三 O 正离子.
  symbols,

  /// By name where one can be given: H3O+ → 水合氢离子, otherwise as
  /// [symbols].
  names,
}

sealed class _Token {
  const _Token();
}

class _Element extends _Token {
  _Element(this.symbol, this.count, this.countDigits);
  final String symbol;
  int count;

  /// The count as written in ASCII digits, which may still hold a charge.
  String countDigits;
}

class _Group extends _Token {
  _Group(this.tokens, this.count);
  final List<_Token> tokens;
  final int count;
}

String _keyOf(List<_Token> tokens) => tokens
    .map((t) => switch (t) {
          _Element(:final symbol, :final count) =>
            count > 1 ? '$symbol$count' : symbol,
          _Group(:final tokens, :final count) =>
            '(${_keyOf(tokens)})${count > 1 ? count : ''}',
        })
    .join();

bool _anyCount(List<_Token> tokens) => tokens.any((t) => switch (t) {
      _Element(:final count) => count > 1,
      _Group(:final tokens, :final count) => count > 1 || _anyCount(tokens),
    });

class ChemicalFormula {
  ChemicalFormula._(
      this.coefficient, this._tokens, this.charge, this.asciiCharge,
      [this.hydrate]);

  final int coefficient;
  final List<_Token> _tokens;
  final int charge;

  /// The charge was written with a plain + or -, not superscripts.
  final bool asciiCharge;

  /// Water of crystallisation after a dot: the 5H2O of CuSO4·5H2O.
  final ChemicalFormula? hydrate;

  bool get hasParentheses => _tokens.any((t) => t is _Group);
  bool get isMonatomic => _tokens.length == 1 && _tokens.first is _Element;
  bool get hasCounts => coefficient > 0 || hydrate != null || _anyCount(_tokens);

  /// Body, water and charge in plain ASCII, without the coefficient:
  /// SO₄²⁻ → SO42-, CuSO₄·5H₂O → CuSO4·5H2O.
  String get key {
    final magnitude = charge.abs();
    final sign = charge == 0
        ? ''
        : '${magnitude > 1 ? magnitude : ''}${charge > 0 ? '+' : '-'}';
    final water = hydrate == null
        ? ''
        : '·${hydrate!.coefficient > 1 ? hydrate!.coefficient : ''}${_keyOf(hydrate!._tokens)}';
    return '${_keyOf(_tokens)}$water$sign';
  }
}

class _Reader {
  _Reader(this.text, this.i);

  static const _subscripts = '₀₁₂₃₄₅₆₇₈₉';
  static final _ascii = RegExp(r'[0-9]');
  static final _upper = RegExp(r'[A-Z]');
  static final _lower = RegExp(r'[a-z]');

  final String text;
  int i;

  bool get atEnd => i >= text.length;

  (int, String) count() {
    final start = i;
    final ascii = StringBuffer();
    final value = StringBuffer();
    while (!atEnd) {
      final c = text[i];
      if (_ascii.hasMatch(c)) {
        ascii.write(c);
        value.write(c);
      } else if (_subscripts.contains(c)) {
        value.write(_subscripts.indexOf(c));
      } else {
        break;
      }
      i++;
    }
    if (i == start) return (1, '');
    return (int.parse(value.toString()), ascii.toString());
  }

  List<_Token>? sequence() {
    final tokens = <_Token>[];
    while (!atEnd) {
      final c = text[i];
      if (c == '(') {
        i++;
        final inner = sequence();
        if (inner == null || inner.isEmpty || atEnd || text[i] != ')') {
          return null;
        }
        i++;
        tokens.add(_Group(inner, count().$1));
      } else if (c == ')') {
        break;
      } else if (_upper.hasMatch(c)) {
        var symbol = c;
        i++;
        if (!atEnd && _lower.hasMatch(text[i])) {
          symbol += text[i];
          i++;
        }
        if (!Chemistry.elementSymbols.contains(symbol)) return null;
        final (n, digits) = count();
        tokens.add(_Element(symbol, n, digits));
      } else {
        return null;
      }
    }
    return tokens;
  }
}

class _Anion {
  const _Anion(this.charge, this.stem, this.ion);
  final int charge;

  /// What the anion contributes to a compound's name: 硫酸 in 硫酸钠.
  final String stem;
  final String ion;
}

class Chemistry {
  static const _superscripts = '⁰¹²³⁴⁵⁶⁷⁸⁹';
  static final _ascii = RegExp(r'[0-9]');
  static final _dot = RegExp('[·•∙]');
  static const _formula = r'[0-9]*[A-Z(][A-Za-z0-9₀-₉()]*';

  /// A formula standing alone: letters, digits, sub- and superscripts,
  /// parentheses and water of crystallisation, with a charge. A plain + or -
  /// counts as a charge only when no formula or number follows it, so
  /// 2H2+O2 is not read as an ion.
  static final candidate = RegExp('(?<![A-Za-z0-9.])$_formula'
      '(?:[·•∙]$_formula)?'
      r'(?:[⁰¹²³⁴-⁹]*[⁺⁻]|[+\-](?![A-Za-z0-9(+\-]))?(?![A-Za-z0-9])');

  static final equation = RegExp(
      '(?<![A-Za-z0-9.])$_formula(?:\\s*[+=→⇌]\\s*$_formula)+(?![A-Za-z0-9])');
  static final _operator = RegExp(r'\s*([+=→⇌])\s*');

  /// Letter-and-digit words that fit the grammar but are not chemistry.
  static const _notFormulas = {'B2B', 'B2C', 'C2C', 'C2B', 'O2O', 'P2P'};

  /// Formulas in capitals only, without digits, that are not read as
  /// acronyms. NO, HF, KI, CO stay with the voice: in books they are far
  /// more often English or abbreviations.
  static const _capitalFormulas = {'KOH', 'HCN', 'KCN', 'KSCN', 'HCHO', 'HCOOH'};
  static final _lowerOrDigit = RegExp(r'[a-z0-9₀-₉]');

  static const _operators = {'+': '加', '=': '等于', '→': '生成', '⇌': '可逆生成'};

  /// Parses [text] as a formula, or returns null.
  static ChemicalFormula? parse(String text, {bool allowCharge = true}) {
    final dot = text.indexOf(_dot);
    if (dot >= 0) {
      final main = parse(text.substring(0, dot), allowCharge: false);
      final water = parse(text.substring(dot + 1), allowCharge: false);
      if (main == null ||
          water == null ||
          main.coefficient > 0 ||
          main.hydrate != null ||
          water.hydrate != null) {
        return null;
      }
      return ChemicalFormula._(0, main._tokens, 0, false, water);
    }

    var body = text;
    var charge = 0;
    var asciiCharge = false;
    final last = body.isEmpty ? '' : body[body.length - 1];
    if (allowCharge && (last == '⁺' || last == '⁻')) {
      var start = body.length - 1;
      while (start > 0 && _superscripts.contains(body[start - 1])) {
        start--;
      }
      final digits = body
          .substring(start, body.length - 1)
          .split('')
          .map((c) => _superscripts.indexOf(c))
          .join();
      charge =
          (digits.isEmpty ? 1 : int.parse(digits)) * (last == '⁺' ? 1 : -1);
      body = body.substring(0, start);
    } else if (allowCharge && (last == '+' || last == '-')) {
      asciiCharge = true;
      charge = last == '+' ? 1 : -1;
      body = body.substring(0, body.length - 1);
    }

    var i = 0;
    while (i < body.length && _ascii.hasMatch(body[i])) {
      i++;
    }
    final coefficient = i > 0 ? int.parse(body.substring(0, i)) : 0;

    final reader = _Reader(body, i);
    final tokens = reader.sequence();
    if (tokens == null || tokens.isEmpty || !reader.atEnd) return null;

    if (asciiCharge) {
      // Plain text runs the last count and the charge together: Fe3+ is
      // Fe³⁺, SO42- is SO₄²⁻, but NH4+ is NH₄⁺.
      final lastToken = tokens.last;
      if (lastToken is _Element && lastToken.countDigits.isNotEmpty) {
        final digits = lastToken.countDigits;
        if (tokens.length == 1) {
          charge *= int.parse(digits);
          lastToken
            ..count = 1
            ..countDigits = '';
        } else if (digits.length >= 2) {
          charge *= int.parse(digits[digits.length - 1]);
          final rest = digits.substring(0, digits.length - 1);
          lastToken
            ..count = int.parse(rest)
            ..countDigits = rest;
        }
      }
    }
    return ChemicalFormula._(coefficient, tokens, charge, asciiCharge);
  }

  /// Whether [formula], written as [text], should be read as chemistry
  /// rather than left to the voice.
  static bool looksLikeChemistry(ChemicalFormula formula, String text) {
    if (_notFormulas.contains(text)) return false;
    if (formula.charge == 0 &&
        !_lowerOrDigit.hasMatch(text) &&
        !_capitalFormulas.contains(text)) {
      return false;
    }
    // Without a name or a charge there is nothing the voice would miss, and
    // letter-digit names (PS5, H1N1) are more often not chemistry at all.
    if (formula.charge == 0 && nameOf(formula) == null) return false;
    // B+, C- are grades far more often than ions.
    if (formula.isMonatomic &&
        formula.asciiCharge &&
        const {'B', 'C'}
            .contains((formula._tokens.first as _Element).symbol)) {
      return false;
    }
    return true;
  }

  /// Reads [formula] from [sentence]. By name, unless the sentence already
  /// says the name (H₃O⁺就是水合氢离子, 醋酸CH3COOH): then the formula is
  /// what the sentence is about, and it is spelled.
  static String read(ChemicalFormula formula, FormulaReading reading,
      {String sentence = ''}) {
    if (reading == FormulaReading.names) {
      final name = nameOf(formula);
      if (name != null && !sentence.contains(name)) return name;
    }
    return spell(formula);
  }

  /// The Chinese name of [formula], or null when none can be given.
  static String? nameOf(ChemicalFormula formula) {
    if (formula.coefficient > 0) return null;
    final known = _names[formula.key];
    if (known != null) return known;
    final water = formula.hydrate;
    if (water != null) {
      if (_keyOf(water._tokens) != 'H2O') return null;
      final main = _neutral(formula._tokens);
      if (main == null) return null;
      return '${chineseNumber(water.coefficient == 0 ? 1 : water.coefficient)}水$main';
    }
    if (formula.charge != 0) return _ion(formula);
    return _neutral(formula._tokens);
  }

  static String? _neutral(List<_Token> tokens) =>
      _names[_keyOf(tokens)] ?? _salt(tokens) ?? _binary(tokens);

  static String? _ion(ChemicalFormula formula) {
    if (formula.isMonatomic) {
      final symbol = (formula._tokens.first as _Element).symbol;
      final name = elementNames[symbol];
      if (name == null) return null;
      if (formula.charge > 0) {
        return _lowerState[symbol] == formula.charge ? '亚$name离子' : '$name离子';
      }
      for (final anion in _anions[symbol] ?? const <_Anion>[]) {
        if (anion.charge == -formula.charge) return anion.ion;
      }
      return '$name离子';
    }
    if (formula.charge > 0) return null;
    for (final anion in _anions[_keyOf(formula._tokens)] ?? const <_Anion>[]) {
      if (anion.charge == -formula.charge) return anion.ion;
    }
    return null;
  }

  /// Salts, bases, metal oxides and acids, named from a cation and an anion
  /// whose charges balance: FeCl2 is 氯化亚铁, FeCl3 is 氯化铁.
  static String? _salt(List<_Token> tokens) {
    // Acetates are written anion first.
    final key = _keyOf(tokens);
    if (key.startsWith('CH3COO') && key.length > 6) {
      final rest = parse(key.substring(6), allowCharge: false);
      final cation = rest == null ? null : _cationOf(rest._tokens);
      if (cation != null && cation.count == 1 && cation.charges.contains(1)) {
        return '醋酸${_cationName(cation.symbol, 1)}';
      }
    }
    for (var split = 1; split < tokens.length; split++) {
      final cation = _cationOf(tokens.sublist(0, split));
      if (cation == null) continue;
      for (final (anionKey, multiplicity) in _anionKeys(tokens.sublist(split))) {
        for (final anion in _anions[anionKey] ?? const <_Anion>[]) {
          if (anion.stem == '过氧化' && !_peroxideCations.contains(cation.symbol)) {
            continue;
          }
          for (final charge in cation.charges) {
            if (charge * cation.count != anion.charge * multiplicity) continue;
            if (cation.symbol == 'H') {
              return anion.stem.endsWith('化') ? '${anion.stem}氢' : anion.stem;
            }
            // Two cations on a hydrogen phosphate are named: 磷酸氢二钠.
            final count = anion.stem == '磷酸氢' && cation.count == 2 ? '二' : '';
            return '${anion.stem}$count${_cationName(cation.symbol, charge)}';
          }
        }
      }
    }
    return null;
  }

  static ({String symbol, int count, List<int> charges})? _cationOf(
      List<_Token> units) {
    if (units.length == 1) {
      final unit = units.first;
      if (unit is _Element) {
        final charges = _cationCharges[unit.symbol];
        if (charges != null) {
          return (symbol: unit.symbol, count: unit.count, charges: charges);
        }
      }
      if (unit is _Group && _keyOf(unit.tokens) == 'NH4') {
        return (symbol: 'NH4', count: unit.count, charges: const [1]);
      }
    }
    if (_keyOf(units) == 'NH4') {
      return (symbol: 'NH4', count: 1, charges: const [1]);
    }
    return null;
  }

  static List<(String, int)> _anionKeys(List<_Token> units) {
    if (units.length == 1) {
      final unit = units.first;
      return switch (unit) {
        _Group(:final tokens, :final count) => [(_keyOf(tokens), count)],
        // O2 in Na2O2 is one peroxide ion, not two oxide ions.
        _Element(:final symbol, :final count) => [
            (symbol, count),
            if (count > 1) ('$symbol$count', 1),
          ],
      };
    }
    if (units.every((u) => u is _Element)) return [(_keyOf(units), 1)];
    return const [];
  }

  static String _cationName(String symbol, int charge) {
    if (symbol == 'NH4') return '铵';
    final name = elementNames[symbol]!;
    return _lowerState[symbol] == charge ? '亚$name' : name;
  }

  /// Two non-metals, or a metal in a high oxidation state, named with
  /// counts: 五氧化二磷, 二氧化锰, 四氯化碳.
  static String? _binary(List<_Token> tokens) {
    if (tokens.length != 2 || tokens.any((t) => t is! _Element)) return null;
    final a = tokens[0] as _Element;
    final b = tokens[1] as _Element;
    final stem = _binaryStems[b.symbol];
    final name = elementNames[a.symbol];
    final valences = _covalentValences[a.symbol];
    if (stem == null || name == null || valences == null) return null;
    final (stemName, charge) = stem;
    if (!valences.any((v) => v * a.count == charge * b.count)) return null;
    final count = b.count > 1 || stemName == '氧化' ? chineseNumber(b.count) : '';
    return '$count$stemName${a.count > 1 ? chineseNumber(a.count) : ''}$name';
  }

  /// H3O+ → H 三 O 正离子; SO₄²⁻ → S O 四 二价负离子.
  static String spell(ChemicalFormula formula) {
    final parts = <String>[];
    if (formula.coefficient > 0) parts.add(chineseNumber(formula.coefficient));
    void add(List<_Token> tokens) {
      for (final token in tokens) {
        switch (token) {
          case _Element(:final symbol, :final count):
            parts.add(symbol.toUpperCase().split('').join(' '));
            if (count > 1) parts.add(chineseNumber(count));
          case _Group(:final tokens, :final count):
            add(tokens);
            if (count > 1) parts.add(chineseNumber(count));
        }
      }
    }

    add(formula._tokens);
    if (formula.hydrate != null) parts.add(spell(formula.hydrate!));
    final magnitude = formula.charge.abs();
    if (magnitude > 0) {
      parts.add('${magnitude > 1 ? '${chineseNumber(magnitude)}价' : ''}'
          '${formula.charge > 0 ? '正离子' : '负离子'}');
    }
    return parts.join(' ');
  }

  /// Rewrites equations and formulas in [text].
  static String rewrite(String text, FormulaReading reading) {
    var result = text.replaceAllMapped(equation, (match) {
      final source = match[0]!;
      final pieces = source.split(_operator);
      final operators = _operator.allMatches(source).map((m) => m[1]!).toList();
      final formulas = [
        for (final piece in pieces) parse(piece, allowCharge: false),
      ];
      if (formulas.any((f) => f == null)) return source;
      if (!formulas.any((f) => f!.hasCounts || !f.isMonatomic)) return source;
      final out = StringBuffer(spell(formulas.first!));
      for (var k = 0; k < operators.length; k++) {
        out.write(' ${_operators[operators[k]]} ${spell(formulas[k + 1]!)}');
      }
      return out.toString();
    });
    result = result.replaceAllMapped(candidate, (match) {
      final source = match[0]!;
      final formula = parse(source);
      if (formula == null || !looksLikeChemistry(formula, source)) return source;
      return read(formula, reading, sentence: text);
    });
    return result;
  }

  static const Map<String, List<int>> _cationCharges = {
    'H': [1], 'Li': [1], 'Na': [1], 'K': [1], 'Rb': [1], 'Cs': [1], 'Ag': [1],
    'Be': [2], 'Mg': [2], 'Ca': [2], 'Sr': [2], 'Ba': [2], 'Zn': [2], 'Cd': [2],
    'Ni': [2], 'Co': [2], 'Mn': [2], 'Pb': [2], 'Sn': [2],
    'Al': [3], 'Cr': [3],
    'Fe': [2, 3], 'Cu': [1, 2], 'Hg': [1, 2],
  };

  /// Metals whose lower charge is named with 亚: 亚铁, 亚铜, 亚汞, 亚锡.
  static const _lowerState = {'Fe': 2, 'Cu': 1, 'Hg': 1, 'Sn': 2};

  static const _peroxideCations = {
    'H', 'Li', 'Na', 'K', 'Rb', 'Cs', 'Mg', 'Ca', 'Sr', 'Ba', 'Zn',
  };

  static const Map<String, List<_Anion>> _anions = {
    'F': [_Anion(1, '氟化', '氟离子')],
    'Cl': [_Anion(1, '氯化', '氯离子')],
    'Br': [_Anion(1, '溴化', '溴离子')],
    'I': [_Anion(1, '碘化', '碘离子')],
    'S': [_Anion(2, '硫化', '硫离子')],
    'O': [_Anion(2, '氧化', '氧离子')],
    'N': [_Anion(3, '氮化', '氮离子')],
    'H': [_Anion(1, '氢化', '氢负离子')],
    'O2': [_Anion(2, '过氧化', '过氧根离子')],
    'OH': [_Anion(1, '氢氧化', '氢氧根离子')],
    'CN': [_Anion(1, '氰化', '氰根离子')],
    'SCN': [_Anion(1, '硫氰酸', '硫氰酸根离子')],
    'HS': [_Anion(1, '硫氢化', '硫氢根离子')],
    'SO4': [_Anion(2, '硫酸', '硫酸根离子')],
    'HSO4': [_Anion(1, '硫酸氢', '硫酸氢根离子')],
    'SO3': [_Anion(2, '亚硫酸', '亚硫酸根离子')],
    'HSO3': [_Anion(1, '亚硫酸氢', '亚硫酸氢根离子')],
    'S2O3': [_Anion(2, '硫代硫酸', '硫代硫酸根离子')],
    'NO3': [_Anion(1, '硝酸', '硝酸根离子')],
    'NO2': [_Anion(1, '亚硝酸', '亚硝酸根离子')],
    'CO3': [_Anion(2, '碳酸', '碳酸根离子')],
    'HCO3': [_Anion(1, '碳酸氢', '碳酸氢根离子')],
    'C2O4': [_Anion(2, '草酸', '草酸根离子')],
    'PO4': [_Anion(3, '磷酸', '磷酸根离子')],
    'HPO4': [_Anion(2, '磷酸氢', '磷酸氢根离子')],
    'H2PO4': [_Anion(1, '磷酸二氢', '磷酸二氢根离子')],
    'ClO': [_Anion(1, '次氯酸', '次氯酸根离子')],
    'ClO2': [_Anion(1, '亚氯酸', '亚氯酸根离子')],
    'ClO3': [_Anion(1, '氯酸', '氯酸根离子')],
    'ClO4': [_Anion(1, '高氯酸', '高氯酸根离子')],
    'IO3': [_Anion(1, '碘酸', '碘酸根离子')],
    'MnO4': [_Anion(1, '高锰酸', '高锰酸根离子'), _Anion(2, '锰酸', '锰酸根离子')],
    'CrO4': [_Anion(2, '铬酸', '铬酸根离子')],
    'Cr2O7': [_Anion(2, '重铬酸', '重铬酸根离子')],
    'SiO3': [_Anion(2, '硅酸', '硅酸根离子')],
    'AlO2': [_Anion(1, '偏铝酸', '偏铝酸根离子')],
    'CH3COO': [_Anion(1, '醋酸', '醋酸根离子')],
  };

  static const Map<String, (String, int)> _binaryStems = {
    'O': ('氧化', 2), 'S': ('硫化', 2), 'N': ('氮化', 3), 'P': ('磷化', 3),
    'C': ('碳化', 4), 'F': ('氟化', 1), 'Cl': ('氯化', 1), 'Br': ('溴化', 1),
    'I': ('碘化', 1),
  };

  /// Oxidation states in which an element forms the compounds [_binary]
  /// names; a count pair no state explains (PS5) is not a compound.
  static const Map<String, List<int>> _covalentValences = {
    'B': [3], 'C': [2, 4], 'N': [1, 2, 3, 4, 5], 'Si': [4], 'P': [3, 5],
    'S': [2, 4, 6], 'Se': [4, 6], 'As': [3, 5], 'Cl': [1, 3, 4, 5, 7],
    'Br': [1, 3, 5], 'I': [1, 3, 5, 7], 'Xe': [2, 4, 6],
    'Mn': [4, 7], 'Pb': [4], 'Ti': [4], 'Cr': [6], 'Sn': [4],
  };

  /// Substances whose names do not follow from their formula.
  static const Map<String, String> _names = {
    'H2O': '水', 'H2O2': '过氧化氢', 'O2': '氧气', 'O3': '臭氧', 'H2': '氢气',
    'N2': '氮气', 'Cl2': '氯气', 'F2': '氟气', 'Br2': '溴', 'I2': '碘', 'P4': '白磷',
    'NH3': '氨气', 'NH3·H2O': '一水合氨', 'CO2': '二氧化碳', 'SO2': '二氧化硫',
    'SO3': '三氧化硫', 'NO2': '二氧化氮', 'SiO2': '二氧化硅', 'SiH4': '硅烷',
    'PH3': '磷化氢', 'HCl': '氯化氢', 'H2SO4': '硫酸', 'HNO3': '硝酸',
    'H3PO4': '磷酸', 'H2CO3': '碳酸', 'H2SO3': '亚硫酸', 'Fe3O4': '四氧化三铁',
    'KAl(SO4)2': '硫酸铝钾', 'Cu2(OH)2CO3': '碱式碳酸铜', 'CO(NH2)2': '尿素',
    'CH4': '甲烷', 'C2H6': '乙烷', 'C3H8': '丙烷', 'C4H10': '丁烷', 'C2H4': '乙烯',
    'C3H6': '丙烯', 'C2H2': '乙炔', 'C6H6': '苯', 'C7H8': '甲苯', 'CH3OH': '甲醇',
    'C2H5OH': '乙醇', 'C3H5(OH)3': '丙三醇', 'HCHO': '甲醛', 'CH3CHO': '乙醛',
    'HCOOH': '甲酸', 'CH3COOH': '醋酸', 'CH3COOC2H5': '乙酸乙酯',
    'C6H5OH': '苯酚', 'C6H5NO2': '硝基苯', 'CH3Cl': '一氯甲烷',
    'CH2Cl2': '二氯甲烷', 'CHCl3': '三氯甲烷', 'C2H5Br': '溴乙烷',
    'C6H12O6': '葡萄糖', 'C12H22O11': '蔗糖',
    'H+': '氢离子', 'H3O+': '水合氢离子', 'NH4+': '铵根离子',
  };

  static const Map<String, String> elementNames = {
    'H': '氢', 'He': '氦', 'Li': '锂', 'Be': '铍', 'B': '硼', 'C': '碳', 'N': '氮',
    'O': '氧', 'F': '氟', 'Ne': '氖', 'Na': '钠', 'Mg': '镁', 'Al': '铝', 'Si': '硅',
    'P': '磷', 'S': '硫', 'Cl': '氯', 'Ar': '氩', 'K': '钾', 'Ca': '钙', 'Sc': '钪',
    'Ti': '钛', 'V': '钒', 'Cr': '铬', 'Mn': '锰', 'Fe': '铁', 'Co': '钴', 'Ni': '镍',
    'Cu': '铜', 'Zn': '锌', 'Ga': '镓', 'Ge': '锗', 'As': '砷', 'Se': '硒', 'Br': '溴',
    'Kr': '氪', 'Rb': '铷', 'Sr': '锶', 'Y': '钇', 'Zr': '锆', 'Nb': '铌', 'Mo': '钼',
    'Tc': '锝', 'Ru': '钌', 'Rh': '铑', 'Pd': '钯', 'Ag': '银', 'Cd': '镉', 'In': '铟',
    'Sn': '锡', 'Sb': '锑', 'Te': '碲', 'I': '碘', 'Xe': '氙', 'Cs': '铯', 'Ba': '钡',
    'La': '镧', 'Ce': '铈', 'Pr': '镨', 'Nd': '钕', 'Pm': '钷', 'Sm': '钐', 'Eu': '铕',
    'Gd': '钆', 'Tb': '铽', 'Dy': '镝', 'Ho': '钬', 'Er': '铒', 'Tm': '铥', 'Yb': '镱',
    'Lu': '镥', 'Hf': '铪', 'Ta': '钽', 'W': '钨', 'Re': '铼', 'Os': '锇', 'Ir': '铱',
    'Pt': '铂', 'Au': '金', 'Hg': '汞', 'Tl': '铊', 'Pb': '铅', 'Bi': '铋', 'Po': '钋',
    'At': '砹', 'Rn': '氡', 'Fr': '钫', 'Ra': '镭', 'Ac': '锕', 'Th': '钍', 'Pa': '镤',
    'U': '铀', 'Np': '镎', 'Pu': '钚', 'Am': '镅', 'Cm': '锔', 'Bk': '锫', 'Cf': '锎',
    'Es': '锿', 'Fm': '镄', 'Md': '钔', 'No': '锘', 'Lr': '铹',
  };

  static final Set<String> elementSymbols = {
    ...elementNames.keys,
    'Rf', 'Db', 'Sg', 'Bh', 'Hs', 'Mt', 'Ds', 'Rg', 'Cn', 'Nh', 'Fl', 'Mc', 'Lv', 'Ts', 'Og',
  };
}
