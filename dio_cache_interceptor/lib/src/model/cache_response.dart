import 'dart:convert' show jsonDecode, jsonEncode, utf8;
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';

import 'package:dio_cache_interceptor/src/model/cache_cipher.dart';
import 'package:dio_cache_interceptor/src/model/cache_control.dart';
import 'package:dio_cache_interceptor/src/model/cache_options.dart';
import 'package:dio_cache_interceptor/src/util/contants.dart';
import 'package:dio_cache_interceptor/src/util/http_date.dart';

import '../util/content_serialization.dart';
import 'cache_priority.dart';

/// Response representation from cache store.
class CacheResponse {
  /// Cache key available in [Response]
  static const String cacheKey = '@cache_key@';

  /// Available in [Response] if coming from network.
  static const String fromNetwork = '@fromNetwork@';

  /// Available in [RequestOptions] to know when request has been sent.
  static const String requestSentDate = '@requestSentDate@';

  /// Response Cache-control header
  final CacheControl cacheControl;

  /// Response body
  List<int>? content;

  /// Response Date header
  final DateTime? date;

  /// ETag header
  final String? eTag;

  /// Expires header
  final DateTime? expires;

  /// Response headers
  List<int>? headers;

  /// Key used by store
  final String key;

  /// Last-modified header
  final String? lastModified;

  /// Max stale expiry
  final DateTime? maxStale;

  /// Cache priority
  final CachePriority priority;

  /// Absolute date representing date/time when request has been sent
  final DateTime requestDate;

  /// Absolute date representing date/time when response has been received
  final DateTime responseDate;

  /// Initial request URL
  final String url;

  CacheResponse({
    required this.cacheControl,
    required this.content,
    required this.date,
    required this.eTag,
    required this.expires,
    required this.headers,
    required this.key,
    required this.lastModified,
    required this.maxStale,
    required this.priority,
    required this.requestDate,
    required this.responseDate,
    required this.url,
  });

  Response toResponse(RequestOptions options, {bool fromNetwork = false}) {
    return Response(
      data: deserializeContent(options.responseType, content),
      extra: {cacheKey: key, CacheResponse.fromNetwork: fromNetwork},
      headers: getHeaders(),
      statusCode: 304,
      requestOptions: options,
    );
  }

  Headers getHeaders() {
    final checkedHeaders = headers;
    final decHeaders = (checkedHeaders != null)
        ? jsonDecode(utf8.decode(checkedHeaders)) as Map<String, dynamic>
        : null;

    final h = Headers();
    decHeaders?.forEach((key, value) => h.set(key, value));

    return h;
  }

  /// Checks if response is staled from [maxStale] option.
  bool isStaled() {
    return maxStale?.isBefore(DateTime.now()) ?? false;
  }

  /// Checks if response is expired.
  bool isExpired({required CacheControl requestCaching}) {
    final responseCaching = cacheControl;

    if (!responseCaching.noCache) {
      final ageMillis = _cacheResponseAge();

      var freshMillis = _computeFreshnessLifetime();
      final maxAge = requestCaching.maxAge;
      if (maxAge != -1) {
        freshMillis = min(freshMillis, maxAge * 1000);
      }

      var maxStaleMillis = 0;
      final maxStale = requestCaching.maxStale;
      if (!responseCaching.mustRevalidate && maxStale != -1) {
        maxStaleMillis = maxStale * 1000;
      }

      var minFreshMillis = 0;
      final minFresh = requestCaching.minFresh;
      if (minFresh != -1) {
        minFreshMillis = minFresh * 1000;
      }

      if (ageMillis + minFreshMillis < freshMillis + maxStaleMillis) {
        return false;
      }
    }

    return true;
  }

  /// Returns the current age of the response, in milliseconds.
  /// Calculating Age.
  /// https://datatracker.ietf.org/doc/html/rfc7234#section-4.2.3
  int _cacheResponseAge() {
    final nowMillis = DateTime.now().millisecondsSinceEpoch;
    final servedDate = date;
    final sentRequestMillis = requestDate.millisecondsSinceEpoch;
    final receivedResponseMillis = responseDate.millisecondsSinceEpoch;

    final headers = getHeaders();
    final ageSeconds = int.parse(headers[HttpHeaders.ageHeader]?.first ?? '-1');

    final apparentReceivedAge = (servedDate != null)
        ? max(0, receivedResponseMillis - servedDate.millisecondsSinceEpoch)
        : 0;

    final receivedAge = (ageSeconds > -1)
        ? max(apparentReceivedAge, ageSeconds * 1000)
        : apparentReceivedAge;

    final responseDuration = receivedResponseMillis - sentRequestMillis;
    final residentDuration = nowMillis - receivedResponseMillis;

    return receivedAge + responseDuration + residentDuration;
  }

  /// Returns the number of milliseconds that the response was fresh for.
  /// Calculating Freshness Lifetime.
  /// https://datatracker.ietf.org/doc/html/rfc7234#section-4.2.1
  int _computeFreshnessLifetime() {
    final maxAge = cacheControl.maxAge;
    if (maxAge != -1) {
      return maxAge * 1000;
    }

    final checkedExpires = expires;
    if (checkedExpires != null) {
      final delta =
          checkedExpires.difference(date ?? responseDate).inMilliseconds;
      return (delta > 0) ? delta : 0;
    }

    if (lastModified != null && Uri.parse(url).query.isEmpty) {
      final sentRequestMillis = requestDate.millisecondsSinceEpoch;
      // As recommended by the HTTP RFC, the max age of a document
      // should be defaulted to 10% of the document's age
      // at the time it was served.
      // Default expiration dates aren't used for URIs containing a query.
      final servedMillis = date?.millisecondsSinceEpoch ?? sentRequestMillis;
      final delta =
          servedMillis - HttpDate.parse(lastModified!).millisecondsSinceEpoch;
      return ((delta > 0) ? delta / 10 : 0).round();
    }

    return 0;
  }

  static Future<CacheResponse> fromResponse({
    required String key,
    required CacheOptions options,
    required Response response,
  }) async {
    final content = await CacheCipher.encryptContent(
      options,
      await serializeContent(
        response.requestOptions.responseType,
        response.data,
      ),
    );

    final headers = await CacheCipher.encryptContent(
      options,
      utf8.encode(jsonEncode(response.headers.map)),
    );

    final dateStr = response.headers[dateHeader]?.first;
    DateTime? date;
    if (dateStr != null) {
      try {
        date = HttpDate.parse(dateStr);
      } catch (_) {
        // Invalid date format => ignored
      }
    }

    final expiresDateStr = response.headers[expiresHeader]?.first;
    DateTime? httpExpiresDate;
    if (expiresDateStr != null) {
      try {
        httpExpiresDate = HttpDate.parse(expiresDateStr);
      } catch (_) {
        // Invalid date format => meaning something already expired
        httpExpiresDate = DateTime.fromMicrosecondsSinceEpoch(0, isUtc: true);
      }
    }

    final checkedMaxStale = options.maxStale;

    return CacheResponse(
      cacheControl: CacheControl.fromHeader(
        response.headers[cacheControlHeader],
      ),
      content: content,
      date: date,
      eTag: response.headers[etagHeader]?.first,
      expires: httpExpiresDate,
      headers: headers,
      key: key,
      lastModified: response.headers[lastModifiedHeader]?.first,
      maxStale: checkedMaxStale != null
          ? DateTime.now().toUtc().add(checkedMaxStale)
          : null,
      priority: options.priority,
      requestDate: response.requestOptions.extra[CacheResponse.requestSentDate],
      responseDate: DateTime.now().toUtc(),
      url: response.requestOptions.uri.toString(),
    );
  }

  CacheResponse copyWith({required DateTime newMaxStale}) {
    return CacheResponse(
      cacheControl: cacheControl,
      content: content,
      date: date,
      eTag: eTag,
      expires: expires,
      headers: headers,
      key: key,
      lastModified: lastModified,
      maxStale: newMaxStale,
      priority: priority,
      requestDate: requestDate,
      responseDate: responseDate,
      url: url,
    );
  }
}
