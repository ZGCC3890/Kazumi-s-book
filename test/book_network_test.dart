import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/request/apis/bangumi_api.dart';
import 'package:kazumi/request/core/dio_factory.dart';
import 'package:kazumi/services/network/book_network_migration.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

class _BangumiAdapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  int status = 200;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final body = options.method == 'POST'
        ? {
            'data': [
              {
                'id': 55770,
                'name': '测试动画',
                'name_cn': '测试动画',
                'rating': {'rank': 10, 'total': 3, 'score': 8.0},
                'images': <String, String>{},
              },
            ],
          }
        : {'list': [], 'total': 0};
    return ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    '0.1.0 migration restores upstream public search and comments; HTTP errors stay errors',
    () async {
      final paths = PathProviderPlatform.instance;
      final dir = await Directory.systemTemp.createTemp('book-network-test-');
      PathProviderPlatform.instance = _Paths(dir.path);
      Hive.init(dir.path);
      final settings = await Hive.openBox<dynamic>('setting');
      await settings.putAll({
        'bangumiAcceleration': '',
        'enableBangumiProxy': true,
      });
      await GStorage.init();
      expect(GStorage.getSetting(SettingsKeys.bangumiAcceleration), 'direct');
      expect(GStorage.getSetting(SettingsKeys.bookNetworkNotice), true);
      final adapter = _BangumiAdapter();
      DioFactory.bangumiDio.httpClientAdapter = adapter;
      final page = await BangumiApi.bangumiSearch('测试');
      expect(page!.items.single.id, 55770);
      await BangumiApi.getBangumiCommentsByID(55770);
      expect(adapter.requests[0].uri.host, 'api.bgm.tv');
      expect(adapter.requests[0].uri.path, '/v0/search/subjects');
      expect(adapter.requests[1].uri.host, 'next.bgm.tv');
      expect(adapter.requests[1].uri.path, '/p1/subjects/55770/comments');
      expect(
        adapter.requests.every((r) => !r.headers.containsKey('X-Signature')),
        true,
      );
      adapter.status = 401;
      await expectLater(
        BangumiApi.bangumiSearch('测试'),
        throwsA(isA<Exception>()),
      );
      await settings.put('bangumiAcceleration', 'ech');
      await migrateBookNetwork(settings);
      expect(
        settings.get('bangumiAcceleration'),
        'ech',
        reason: 'migration must not overwrite subsequent choices',
      );
      DioFactory.reset();
      await Hive.close();
      PathProviderPlatform.instance = paths;
      await dir.delete(recursive: true);
    },
  );
}
