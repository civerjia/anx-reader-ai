import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Books picked on the shelf, by id; null while the shelf is not selecting.
final bookshelfSelectionProvider = StateProvider<Set<int>?>((ref) => null);
