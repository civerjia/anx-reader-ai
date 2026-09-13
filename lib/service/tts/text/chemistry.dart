import 'package:anx_reader/service/tts/text/chinese_number.dart';

/// How chemical formulas are read aloud.
enum FormulaReading {
  /// Letter by letter with counts and charge: H3O+ → H 三 O 正离子.
  symbols,

  /// By name where one is known: H3O+ → 水合氢离子, otherwise as [symbols].
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

class _Open extends _Token {
  const _Open();
}

class _Close extends _Token {
  const _Close(this.count);
  final int count;
}

class ChemicalFormula {
  ChemicalFormula._(this.coefficient, this._tokens, this.charge, this.asciiCharge);

  final int coefficient;
  final List<_Token> _tokens;
  final int charge;

  /// The charge was written with a plain + or -, not superscripts.
  final bool asciiCharge;

  Iterable<_Element> get _elements => _tokens.whereType<_Element>();
  bool get hasParentheses => _tokens.any((t) => t is _Open);
  bool get isMonatomic => _elements.length == 1 && !hasParentheses;
  bool get hasCounts =>
      coefficient > 0 ||
      _elements.any((e) => e.count > 1) ||
      _tokens.any((t) => t is _Close && t.count > 1);

  /// Body and charge in plain ASCII, without the coefficient: SO₄²⁻ → SO42-.
  String get key {
    final body = _tokens.map((t) => switch (t) {
          _Element(:final symbol, :final count) =>
            count > 1 ? '$symbol$count' : symbol,
          _Open() => '(',
          _Close(:final count) => count > 1 ? ')$count' : ')',
        });
    final magnitude = charge.abs();
    final sign = charge == 0 ? '' : '${magnitude > 1 ? magnitude : ''}${charge > 0 ? '+' : '-'}';
    return '${body.join()}$sign';
  }
}

class Chemistry {
  static const _subscripts = '₀₁₂₃₄₅₆₇₈₉';
  static const _superscripts = '⁰¹²³⁴⁵⁶⁷⁸⁹';

  static final _upper = RegExp(r'[A-Z]');
  static final _lower = RegExp(r'[a-z]');
  static final _ascii = RegExp(r'[0-9]');

  /// A formula standing alone: letters, digits, sub- and superscripts and
  /// parentheses, with a charge. A plain + or - counts as a charge only when
  /// no formula or number follows it, so 2H2+O2 is not read as an ion.
  static final candidate = RegExp(
      r'(?<![A-Za-z0-9.])[0-9]*[A-Z(][A-Za-z0-9₀-₉()]*(?:[⁰¹²³⁴-⁹]*[⁺⁻]|[+\-](?![A-Za-z0-9(+\-]))?(?![A-Za-z0-9])');

  static final equation = RegExp(
      r'(?<![A-Za-z0-9.])[0-9]*[A-Z(][A-Za-z0-9₀-₉()]*(?:\s*[+=→⇌]\s*[0-9]*[A-Z(][A-Za-z0-9₀-₉()]*)+(?![A-Za-z0-9])');
  static final _operator = RegExp(r'\s*([+=→⇌])\s*');

  /// Letter-and-digit words that fit the grammar but are not chemistry.
  static const _notFormulas = {'B2B', 'B2C', 'C2C', 'C2B', 'O2O', 'P2P'};

  static const _operators = {'+': '加', '=': '等于', '→': '生成', '⇌': '可逆生成'};

  /// Parses [text] as a formula, or returns null.
  static ChemicalFormula? parse(String text, {bool allowCharge = true}) {
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
      charge = (digits.isEmpty ? 1 : int.parse(digits)) * (last == '⁺' ? 1 : -1);
      body = body.substring(0, start);
    } else if (allowCharge && (last == '+' || last == '-')) {
      asciiCharge = true;
      charge = last == '+' ? 1 : -1;
      body = body.substring(0, body.length - 1);
    }

    var i = 0;
    var coefficient = 0;
    final coefficientStart = i;
    while (i < body.length && _ascii.hasMatch(body[i])) {
      i++;
    }
    if (i > coefficientStart) {
      coefficient = int.parse(body.substring(coefficientStart, i));
    }

    (int, String) readCount() {
      final start = i;
      final ascii = StringBuffer();
      final value = StringBuffer();
      while (i < body.length) {
        final c = body[i];
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

    final tokens = <_Token>[];
    var depth = 0;
    while (i < body.length) {
      final c = body[i];
      if (c == '(') {
        depth++;
        tokens.add(const _Open());
        i++;
      } else if (c == ')') {
        if (depth == 0) return null;
        depth--;
        i++;
        tokens.add(_Close(readCount().$1));
      } else if (_upper.hasMatch(c)) {
        var symbol = c;
        i++;
        if (i < body.length && _lower.hasMatch(body[i])) {
          symbol += body[i];
          i++;
        }
        if (!elementSymbols.contains(symbol)) return null;
        final (count, digits) = readCount();
        tokens.add(_Element(symbol, count, digits));
      } else {
        return null;
      }
    }
    if (depth != 0 || tokens.whereType<_Element>().isEmpty) return null;

    if (asciiCharge) {
      // Plain text runs the last count and the charge together: Fe3+ is
      // Fe³⁺, SO42- is SO₄²⁻, but NH4+ is NH₄⁺.
      final lastToken = tokens.last;
      final monatomic = tokens.length == 1;
      if (lastToken is _Element && lastToken.countDigits.isNotEmpty) {
        final digits = lastToken.countDigits;
        if (monatomic) {
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
  /// rather than left to the voice: something only a formula would have
  /// (a count, a charge, parentheses) or a formula known by name.
  static bool looksLikeChemistry(ChemicalFormula formula, String text) {
    if (_notFormulas.contains(text)) return false;
    final known = _names.containsKey(formula.key);
    if (!known && !formula.hasCounts && formula.charge == 0 && !formula.hasParentheses) {
      return false;
    }
    if (formula.isMonatomic && formula.charge == 0 && !known) return false;
    // B+, C- are grades far more often than ions.
    if (formula.isMonatomic &&
        formula.asciiCharge &&
        const {'B', 'C'}.contains(formula._elements.first.symbol)) {
      return false;
    }
    return true;
  }

  static String read(ChemicalFormula formula, FormulaReading reading) {
    if (reading == FormulaReading.names && formula.coefficient == 0) {
      final name = _names[formula.key];
      if (name != null) return name;
      if (formula.isMonatomic && formula.charge != 0) {
        final element = formula._elements.first.symbol;
        final elementName = elementNames[element];
        if (elementName != null) {
          final magnitude = formula.charge.abs();
          return magnitude > 1 && _variableValence.contains(element)
              ? '${chineseNumber(magnitude)}价$elementName离子'
              : '$elementName离子';
        }
      }
    }
    return spell(formula);
  }

  /// H3O+ → H 三 O 正离子; SO₄²⁻ → S O 四 二价负离子.
  static String spell(ChemicalFormula formula) {
    final parts = <String>[];
    if (formula.coefficient > 0) parts.add(chineseNumber(formula.coefficient));
    for (final token in formula._tokens) {
      switch (token) {
        case _Element(:final symbol, :final count):
          parts.add(symbol.toUpperCase().split('').join(' '));
          if (count > 1) parts.add(chineseNumber(count));
        case _Open():
          break;
        case _Close(:final count):
          if (count > 1) parts.add(chineseNumber(count));
      }
    }
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
      return read(formula, reading);
    });
    return result;
  }

  static const _variableValence = {
    'Fe', 'Cu', 'Mn', 'Cr', 'Co', 'Ni', 'Sn', 'Pb', 'Hg', 'Ti', 'V', 'Au', 'Pt', 'Ce',
  };

  /// Common substances and ions by their key.
  static const Map<String, String> _names = {
    'H2O': '水',
    'H2O2': '过氧化氢',
    'CO2': '二氧化碳',
    'SO2': '二氧化硫',
    'SO3': '三氧化硫',
    'NO2': '二氧化氮',
    'SiO2': '二氧化硅',
    'O2': '氧气',
    'O3': '臭氧',
    'H2': '氢气',
    'N2': '氮气',
    'Cl2': '氯气',
    'NH3': '氨气',
    'CH4': '甲烷',
    'C2H5OH': '乙醇',
    'CH3COOH': '醋酸',
    'C6H12O6': '葡萄糖',
    'HCl': '氯化氢',
    'H2SO4': '硫酸',
    'HNO3': '硝酸',
    'H3PO4': '磷酸',
    'H2CO3': '碳酸',
    'NaCl': '氯化钠',
    'KCl': '氯化钾',
    'NaOH': '氢氧化钠',
    'KOH': '氢氧化钾',
    'Ca(OH)2': '氢氧化钙',
    'CaCO3': '碳酸钙',
    'CaO': '氧化钙',
    'MgO': '氧化镁',
    'Al2O3': '氧化铝',
    'Fe2O3': '氧化铁',
    'Fe3O4': '四氧化三铁',
    'CuO': '氧化铜',
    'CuSO4': '硫酸铜',
    'BaSO4': '硫酸钡',
    'AgNO3': '硝酸银',
    'AgCl': '氯化银',
    'Na2CO3': '碳酸钠',
    'NaHCO3': '碳酸氢钠',
    'KMnO4': '高锰酸钾',
    'H+': '氢离子',
    'H3O+': '水合氢离子',
    'NH4+': '铵根离子',
    'OH-': '氢氧根离子',
    'NO3-': '硝酸根离子',
    'NO2-': '亚硝酸根离子',
    'SO42-': '硫酸根离子',
    'SO32-': '亚硫酸根离子',
    'HSO4-': '硫酸氢根离子',
    'CO32-': '碳酸根离子',
    'HCO3-': '碳酸氢根离子',
    'PO43-': '磷酸根离子',
    'MnO4-': '高锰酸根离子',
    'ClO-': '次氯酸根离子',
    'CH3COO-': '醋酸根离子',
    'Fe2+': '亚铁离子',
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
