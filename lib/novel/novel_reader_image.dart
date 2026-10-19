import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'novel_image_viewer.dart';

class NovelReaderImage extends StatelessWidget {
  const NovelReaderImage({super.key, required this.bytes, required this.retry});
  final Future<Uint8List> bytes;
  final VoidCallback retry;

  Widget _error(Object error) => Center(
    child: Tooltip(
      message: error.toString(),
      child: TextButton.icon(
        onPressed: retry,
        icon: const Icon(Icons.broken_image_outlined),
        label: const Text('插图加载失败，重试'),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List>(
    future: bytes,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return Semantics(label: '插图加载中', child: const SizedBox.expand());
      }
      if (snapshot.hasError) return _error(snapshot.error!);
      return Semantics(
        label: '小说插图，点击放大',
        button: true,
        child: InkWell(
          onTap: () => showNovelImage(context, snapshot.data!),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Image.memory(
              snapshot.data!,
              fit: BoxFit.contain,
              frameBuilder: (_, child, frame, _) =>
                  frame == null ? const SizedBox.expand() : child,
              errorBuilder: (_, error, _) => _error(error),
            ),
          ),
        ),
      );
    },
  );
}
