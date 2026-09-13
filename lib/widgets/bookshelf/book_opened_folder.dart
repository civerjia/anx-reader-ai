import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/providers/book_list.dart';
import 'package:anx_reader/providers/tb_groups.dart';
import 'package:anx_reader/widgets/bookshelf/book_item.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class BookOpenedFolder extends ConsumerStatefulWidget {
  const BookOpenedFolder({
    super.key,
    required this.books,
    required this.groupName,
  });

  final List<Book> books;
  final String groupName;

  @override
  ConsumerState<BookOpenedFolder> createState() => _BookOpenedFolderState();
}

class _BookOpenedFolderState extends ConsumerState<BookOpenedFolder> {
  bool isEditing = false;
  bool isEditingName = false;
  List<Book> books = [];
  late TextEditingController _nameController;
  String currentGroupName = "";

  @override
  void initState() {
    super.initState();
    books = widget.books;
    currentGroupName = widget.groupName;
    _nameController = TextEditingController(text: currentGroupName);
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _updateGroupName() async {
    if (books.isEmpty) return;

    final groupId = books.first.groupId;
    if (groupId <= 0) return;

    try {
      final group = await ref.read(groupDaoProvider.notifier).getGroup(groupId);
      if (group == null) return;
      final updatedGroup = group.copyWith(name: _nameController.text);
      await ref.read(groupDaoProvider.notifier).updateGroup(updatedGroup);

      setState(() {
        currentGroupName = _nameController.text;
        isEditingName = false;
      });
    } catch (e) {
      // Handle error
      setState(() {
        isEditingName = false;
      });
    }
  }

  Future<void> _confirmDissolve(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(L10n.of(dialogContext).bookshelfDissolveConfirmTitle),
        content: Text(L10n.of(dialogContext).bookshelfDissolveConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(L10n.of(dialogContext).commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: TextButton.styleFrom(
                foregroundColor: Theme.of(dialogContext).colorScheme.error),
            child: Text(L10n.of(dialogContext).commonDissolve),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    ref.read(bookListProvider.notifier).dissolveGroup(books);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: isEditingName
          ? Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _nameController,
                    decoration: InputDecoration(
                      border: OutlineInputBorder(),
                    ),
                    autofocus: true,
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.check),
                  onPressed: _updateGroupName,
                ),
                IconButton(
                  icon: Icon(Icons.close),
                  onPressed: () {
                    setState(() {
                      _nameController.text = currentGroupName;
                      isEditingName = false;
                    });
                  },
                ),
              ],
            )
          : InkWell(
              onTap: () {
                setState(() {
                  isEditingName = true;
                });
              },
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      currentGroupName,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    Icons.edit_outlined,
                    size: 18,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ],
              ),
            ),
      content: SizedBox(
        width: MediaQuery.of(context).size.width * 0.7,
        child: GridView.builder(
            shrinkWrap: true,
            gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: Prefs().bookCoverWidth,
              childAspectRatio: 1 / 2.2,
              crossAxisSpacing: 10,
              mainAxisSpacing: 10,
            ),
            itemCount: books.length,
            itemBuilder: (context, index) => Stack(
                  children: [
                    BookItem(book: books[index]),
                    isEditing
                        ? Positioned(
                            right: 0,
                            top: 0,
                            child: IconButton(
                              onPressed: () {
                                ref
                                    .read(bookListProvider.notifier)
                                    .removeFromGroup(books[index]);
                                books.removeAt(index);
                                if (books.isEmpty) {
                                  Navigator.pop(context);
                                }
                                setState(() {});
                              },
                              icon: const Icon(
                                Icons.remove_circle,
                                size: 30,
                                color: Colors.red,
                              ),
                            ),
                          )
                        : Container(),
                  ],
                )),
      ),
      // Dissolving sat next to Edit and acted on one tap. It now shows only
      // while editing, at the far side from Cancel, and asks first.
      actionsAlignment:
          isEditing ? MainAxisAlignment.spaceBetween : MainAxisAlignment.end,
      actions: [
        if (isEditing)
          TextButton(
              style: TextButton.styleFrom(
                  foregroundColor: Theme.of(context).colorScheme.error),
              onPressed: () => _confirmDissolve(context),
              child: Text(L10n.of(context).commonDissolve)),
        TextButton(
            onPressed: () {
              isEditing = !isEditing;
              setState(() {});
            },
            child: Text(isEditing
                ? L10n.of(context).commonCancel
                : L10n.of(context).commonEdit)),
      ],
    );
  }
}
