import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

Future<void> showNovelImage(BuildContext context, Uint8List bytes) =>
    showDialog<void>(context: context, builder: (ctx) => Dialog.fullscreen(
      backgroundColor: Colors.black,
      child: Stack(children: [
        Positioned.fill(child: InteractiveViewer(
          minScale: .5, maxScale: 5,
          child: Image.memory(bytes, fit: BoxFit.contain),
        )),
        SafeArea(child: Align(alignment: Alignment.topRight, child: IconButton(
          tooltip: '关闭插图', color: Colors.white,
          onPressed: () => Navigator.pop(ctx), icon: const Icon(Icons.close),
        ))),
      ]),
    ));
