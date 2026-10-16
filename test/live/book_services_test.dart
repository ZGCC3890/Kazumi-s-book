import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/request/apis/bangumi_api.dart';
import 'package:kazumi/request/core/dio_factory.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'live production Bangumi search and subject/episode comments use public upstream endpoints',
    () async {
      final originalPaths = PathProviderPlatform.instance;
      final originalHttp = HttpOverrides.current;
      final root = await Directory.systemTemp.createTemp('book-live-services-');
      PathProviderPlatform.instance = _Paths(root.path);
      HttpOverrides.global = null;
      Hive.init(root.path);
      await GStorage.init();
      try {
        expect(GStorage.getSetting(SettingsKeys.bangumiAcceleration), 'direct');
        for (final query in ['无职转生', '葬送的芙莉莲']) {
          final page = await BangumiApi.bangumiSearch(query);
          expect(page, isNotNull);
          expect(page!.items, isNotEmpty, reason: 'live search: $query');
          print(
            'LIVE search "$query": ${page.items.length} parsed anime results',
          );
        }
        final comments = await BangumiApi.getBangumiCommentsByID(55770);
        expect(comments.commentList, isNotEmpty);
        expect(comments.total, greaterThan(0));
        final episode = await BangumiApi.getBangumiEpisodeByID(55770, 1);
        expect(episode.id, greaterThan(0));
        final episodeComments = await BangumiApi.getBangumiCommentsByEpisodeID(
          episode.id,
        );
        expect(episodeComments.commentList, isNotEmpty);
        print(
          'LIVE subject comments=${comments.commentList.length} total=${comments.total}; '
          'episode ${episode.id} comments=${episodeComments.commentList.length}',
        );
      } finally {
        DioFactory.reset();
        await Hive.close();
        PathProviderPlatform.instance = originalPaths;
        HttpOverrides.global = originalHttp;
        expect(root.parent.absolute.path, Directory.systemTemp.absolute.path);
        await root.delete(recursive: true);
      }
    },
    skip: !const bool.fromEnvironment('BOOK_LIVE'),
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
