import 'package:flutter/material.dart';
import 'novel_conflicts.dart';
import 'novel_service.dart';

Future<void> addNovelToShelf(NovelService service, String editionId, {int animeId = 0}) {
  final associations = service.animeIdsForEdition(editionId);
  final targetAnimeId = animeId > 0 ? animeId : associations.length == 1 ? associations.single : 0;
  return service.addToShelf(editionId, animeId: targetAnimeId);
}

class NovelShelfAction extends StatefulWidget {
  const NovelShelfAction({super.key, required this.service, required this.editionId, this.animeId = 0});
  final NovelService service;
  final String editionId;
  final int animeId;

  @override
  State<NovelShelfAction> createState() => _NovelShelfActionState();
}

class _NovelShelfActionState extends State<NovelShelfAction> {
  bool _busy = false;

  Future<void> _add() async {
    setState(() => _busy = true);
    try {
      if (!await NovelConflicts.ensure(context, widget.service,
          () => ['shelf/${widget.editionId}']) || !mounted) return;
      await addNovelToShelf(widget.service, widget.editionId, animeId: widget.animeId);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.toString())));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.service,
    builder: (_, _) {
      final shelved = widget.service.isShelved(widget.editionId);
      return IconButton(
        tooltip: shelved ? '已在书架' : '加入书架',
        onPressed: _busy || shelved ? null : _add,
        icon: Icon(shelved ? Icons.library_add_check_outlined : Icons.library_add_outlined),
      );
    },
  );
}
