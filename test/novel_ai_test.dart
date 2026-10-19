import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/novel/novel_ai.dart';
import 'package:kazumi/novel/novel_service.dart';
import 'package:kazumi/services/sync/webdav.dart';

void main() {
  const settings = NovelAiSettings(enabled: true, webSearch: false, endpoint: 'https://api.test/v1/',
    model: 'test-model', token: 'test-only-token');
  test('service uses the explicit unsaved configuration and closes its isolated client', () async {
    final dio = Dio();
    dio.interceptors.add(InterceptorsWrapper(onRequest: (request, handler) {
      expect(request.data['messages'][0]['content'], contains('同一本小说'));
      handler.resolve(Response(requestOptions: request, data: {'choices': [{'finish_reason': 'stop',
        'message': {'content': '{"titles":["候选"]}'}}]}));
    }));
    final service = NovelService(WebDav(), aiClient: () => dio);
    addTearDown(service.dispose);
    expect(await service.suggestTitles('作品', toAnime: false, sameNovel: true, settings: settings), ['候选']);
    expect(service.aiSettings.enabled, false);
    await expectLater(dio.get('https://api.test'), throwsA(isA<DioException>()));
    await expectLater(service.suggestTitles('作品', toAnime: false), throwsFormatException);
  });
  for (final webSearch in [false, true]) {
    test('source switching requests the same novel main title and alternate translations (web: $webSearch)', () async {
      final dio = Dio();
      addTearDown(dio.close);
      final requests = <String>[];
      dio.interceptors.add(InterceptorsWrapper(onRequest: (request, handler) {
        requests.add(request.path);
        if (request.path.endsWith('/tools/search')) {
          expect(request.data['query'], '輝夜姬想讓人告白 小說版 ～单卷副标题～ 小说 主标题 不同中文译名');
          handler.resolve(Response(requestOptions: request, data: {'results': [
            {'title': '小说出版资料', 'url': 'https://publisher.test/book', 'summary': '同作品的不同译名', 'content': '出版资料'},
          ]}));
        } else {
          final prompt = request.data['messages'][0]['content'] as String;
          expect(prompt, contains('仅列出同一本小说的主标题和不同中文译名'));
          expect(prompt, contains('不要列出改编动画、漫画、续作或衍生作品'));
          expect(prompt, contains('使用简体中文'));
          expect(prompt, contains('去掉“小说版”、卷号和单卷副标题'));
          expect(prompt, isNot(contains('列出对应原作或正式衍生轻小说')));
          handler.resolve(Response(requestOptions: request, data: {'choices': [{'finish_reason': 'stop',
            'message': {'content': '{"titles":["辉夜姬想让人告白 小说版 ～单卷副标题～","辉夜大小姐想让我告白"]}'}}]}));
        }
      }));
      final config = NovelAiSettings(enabled: true, webSearch: webSearch,
        endpoint: settings.endpoint, token: settings.token, model: settings.model);
      expect(await NovelAiClient(dio).titles(config, '輝夜姬想讓人告白 小說版 ～单卷副标题～',
        toAnime: false, sameNovel: true), ['辉夜姬想让人告白', '辉夜大小姐想让我告白']);
      expect(requests.length, webSearch ? 2 : 1);
    });
  }
  test('settings round trip and invalid endpoint or credentials are explicit errors', () {
    expect(NovelAiSettings.fromJson(settings.toJson()).toJson(), settings.toJson());
    for (final endpoint in ['http://api.test', 'https:', 'https://user@api.test',
      'https://api.test/?key=value', 'https://api.test/#part']) {
      expect(() => NovelAiSettings(endpoint: endpoint, model: 'm', token: 't').validate(), throwsFormatException);
    }
    expect(() => const NovelAiSettings(model: '', token: 't').validate(), throwsFormatException);
    expect(() => const NovelAiSettings().validate(), throwsFormatException);
  });
  test('web evidence is fetched from the configured provider before title inference', () async {
    final dio = Dio();
    addTearDown(dio.close);
    final requests = <String>[];
    var empty = false;
    dio.interceptors.add(InterceptorsWrapper(onRequest: (request, handler) {
      requests.add(request.path);
      if (request.path.endsWith('/tools/search')) {
        expect(request.uri.host, 'api.test');
        expect(request.data['query'], contains('官方衍生小说'));
        handler.resolve(Response(requestOptions: request, data: {'results': empty ? [] : [
          {'title': '出版书目', 'url': 'https://publisher.test/book', 'summary': '正式小说出版资料',
            'content': List.filled(2000, '字').join()}]}));
      } else {
        final data = jsonDecode(request.data['messages'][1]['content']);
        expect(data['sources'][0]['content'].length, 1800);
        expect(data['sources'][0]['url'], 'https://publisher.test/book');
        handler.resolve(Response(requestOptions: request, data: {'choices': [{'finish_reason': 'stop',
          'message': {'content': '{"titles":["关联小说"]}'}}]}));
      }
    }));
    const config = NovelAiSettings(enabled: true, endpoint: 'https://api.test/v1', token: 'fixture');
    expect(await NovelAiClient(dio).titles(config, '动画标题', toAnime: false), ['关联小说']);
    expect(requests.length, 2);
    empty = true;
    expect(await NovelAiClient(dio).titles(config, '动画标题', toAnime: false), isEmpty);
    expect(requests.length, 3);
    await expectLater(NovelAiClient(dio).titles(config, List.filled(129, '字').join(),
      toAnime: true), throwsFormatException);
  });
  for (final toAnime in [false, true]) {
    test('title request uses configured endpoint and returns unique names ($toAnime)', () async {
      final dio = Dio();
      addTearDown(dio.close);
      dio.interceptors.add(InterceptorsWrapper(onRequest: (request, handler) {
        expect(request.uri.toString(), 'https://api.test/v1/chat/completions');
        expect(request.headers['Authorization'], 'Bearer test-only-token');
        expect(request.data['model'], 'test-model');
        expect(request.data['messages'][0]['content'], contains(toAnime ? '动画' : '轻小说'));
        expect(jsonDecode(request.data['messages'][1]['content']), {'title': '输入名称'});
        handler.resolve(Response(requestOptions: request, data: {'choices': [{
          'finish_reason': 'stop', 'message': {'content': '{"titles":["候选一", "候选一 小说版 ～单卷副标题～", " 候选二 "]}'},
        }]}));
      }));
      expect(await NovelAiClient(dio).titles(settings, '输入名称', toAnime: toAnime), ['候选一', '候选二']);
    });
  }
  for (final body in ['{"titles":[]}', '{"titles":42}', '{"titles":[null]}',
    '{"titles":[" "]}', '{"titles":["1","2","3","4","5","6"]}', 'not json']) {
    test('response validation $body', () async {
      final dio = Dio();
      addTearDown(dio.close);
      dio.interceptors.add(InterceptorsWrapper(onRequest: (request, handler) => handler.resolve(
        Response(requestOptions: request, data: {'choices': [{
          'finish_reason': 'stop', 'message': {'content': body}}]}))));
      final result = NovelAiClient(dio).titles(settings, '标题', toAnime: false);
      if (body == '{"titles":[]}') {
        expect(await result, isEmpty);
      } else {
        await expectLater(result, throwsFormatException);
      }
    });
  }
  test('truncated responses, HTTP errors and cancellation do not substitute a title', () async {
    final dio = Dio();
    addTearDown(dio.close);
    await expectLater(NovelAiClient(dio).titles(settings, ' ', toAnime: false), throwsFormatException);
    dio.interceptors.add(InterceptorsWrapper(onRequest: (request, handler) => handler.resolve(
      Response(requestOptions: request, data: {'choices': [{'finish_reason': 'length'}]}))));
    await expectLater(NovelAiClient(dio).titles(settings, '标题', toAnime: false), throwsStateError);
    dio.interceptors.clear();
    dio.interceptors.add(InterceptorsWrapper(onRequest: (request, handler) => handler.reject(
      DioException(requestOptions: request, type: DioExceptionType.badResponse,
        response: Response(requestOptions: request, statusCode: 401)))));
    await expectLater(NovelAiClient(dio).titles(settings, '标题', toAnime: false), throwsA(isA<DioException>()));
    final cancel = CancelToken()..cancel();
    await expectLater(NovelAiClient(dio).titles(settings, '标题', toAnime: false,
      cancelToken: cancel), throwsA(isA<DioException>().having((e) => e.type, 'type', DioExceptionType.cancel)));
  });
}
