import 'package:flutter/material.dart';
import 'package:kazumi/novel/novel_entry.dart';
import 'package:kazumi/novel/novel_service.dart';

class NovelSearchPane extends StatelessWidget {
  const NovelSearchPane({
    super.key,
    required this.service,
    required this.query,
    required this.revision,
    required this.onSelected,
    required this.header,
    required this.discovery,
  });
  final Widget header;
  final Widget discovery;
  final NovelService service;
  final String? query;
  final int revision;
  final Future<void> Function(String editionId) onSelected;

  @override
  Widget build(BuildContext context) => query == null
      ? ListView(
          children: [
            header,
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('输入书名搜索小说，进入详情后选择书源阅读。'),
            ),
            discovery,
          ],
        )
      : NovelSearchPage.results(
          key: ValueKey((query, revision)),
          service: service,
          initialQuery: query!,
          onSelected: onSelected,
          header: header,
        );
}
