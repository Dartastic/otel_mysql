// Licensed under the Apache License, Version 2.0
// Copyright 2025, Mindful Software LLC, All rights reserved.
//
// Tests exercise the span/attribute machinery of `tracedMysqlCall`
// using a fake `invoke` callback — no real MySQL server is needed.

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:otel_mysql/otel_mysql.dart';
import 'package:test/test.dart';

class _MemorySpanExporter implements SpanExporter {
  final List<Span> spans = [];
  bool _shutdown = false;
  @override
  Future<void> export(List<Span> s) async {
    if (_shutdown) return;
    spans.addAll(s);
  }

  @override
  Future<void> forceFlush() async {}

  @override
  Future<void> shutdown() async {
    _shutdown = true;
  }
}

Map<String, Object> _attrMap(Span span) => {
      for (final a in span.attributes.toList()) a.key: a.value,
    };

void main() {
  group('tracedMysqlCall', () {
    late _MemorySpanExporter exporter;

    setUp(() async {
      await OTel.reset();
      exporter = _MemorySpanExporter();
      await OTel.initialize(
        serviceName: 'otel_mysql-test',
        detectPlatformResources: false,
        spanProcessor: SimpleSpanProcessor(exporter),
      );
    });

    tearDown(() async {
      await OTel.shutdown();
      await OTel.reset();
    });

    test('SELECT names span "SELECT <table>" per OTel stable semconv',
        () async {
      await tracedMysqlCall<int>(
        sqlText: 'SELECT id, name FROM users WHERE id = ?',
        invoke: () async => 1,
      );
      expect(exporter.spans, hasLength(1));
      final span = exporter.spans.single;
      // Stable semconv: span name is `{op} {target}` — no system prefix.
      expect(span.name, 'SELECT users');
      final attrs = _attrMap(span);
      expect(attrs['db.system.name'], 'mysql');
      expect(attrs['db.operation.name'], 'SELECT');
      expect(attrs['db.collection.name'], 'users');
      expect(attrs['db.query.text'], contains('FROM users'));
    });

    test('INSERT extracts table from INTO and strips backticks', () async {
      await tracedMysqlCall<int>(
        sqlText: 'INSERT INTO `orders` (sku, qty) VALUES (?, ?)',
        invoke: () async => 1,
      );
      final attrs = _attrMap(exporter.spans.single);
      expect(attrs['db.operation.name'], 'INSERT');
      expect(attrs['db.collection.name'], 'orders');
    });

    test('UPDATE extracts table', () async {
      await tracedMysqlCall<int>(
        sqlText: 'UPDATE users SET name = ? WHERE id = ?',
        invoke: () async => 1,
      );
      final attrs = _attrMap(exporter.spans.single);
      expect(attrs['db.operation.name'], 'UPDATE');
      expect(attrs['db.collection.name'], 'users');
    });

    test('span name drops target when no table can be extracted', () async {
      await tracedMysqlCall<int>(
        sqlText: 'SELECT 1',
        invoke: () async => 1,
      );
      // No target — span name is just the operation, with NO trailing
      // system or namespace.
      expect(exporter.spans.single.name, 'SELECT');
    });

    test('namespace + server attrs recorded', () async {
      await tracedMysqlCall<int>(
        sqlText: 'SELECT 1',
        namespace: 'shop',
        serverAddress: 'mysql.internal',
        serverPort: 3306,
        invoke: () async => 1,
      );
      final attrs = _attrMap(exporter.spans.single);
      expect(attrs['db.namespace'], 'shop');
      expect(attrs['server.address'], 'mysql.internal');
      expect(attrs['server.port'], 3306);
    });

    test('records exception and sets error status on throw', () async {
      await expectLater(
        tracedMysqlCall<int>(
          sqlText: 'SELECT 1',
          invoke: () async => throw StateError('boom'),
        ),
        throwsA(isA<StateError>()),
      );
      final span = exporter.spans.single;
      expect(span.status, SpanStatusCode.Error);
      expect(_attrMap(span)['error.type'], 'StateError');
    });

    test('zone-scoped suppression skips span creation', () async {
      await runWithoutMysqlInstrumentationAsync(() async {
        await tracedMysqlCall<int>(
          sqlText: 'SELECT 1',
          invoke: () async => 1,
        );
      });
      expect(exporter.spans, isEmpty);
    });

    test('SQL with leading comments still extracts operation', () async {
      await tracedMysqlCall<int>(
        sqlText: '-- migration step\nSELECT count(*) FROM widgets',
        invoke: () async => 1,
      );
      final attrs = _attrMap(exporter.spans.single);
      expect(attrs['db.operation.name'], 'SELECT');
      expect(attrs['db.collection.name'], 'widgets');
    });
  });
}
