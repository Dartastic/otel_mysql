// Licensed under the Apache License, Version 2.0
// Copyright 2025, Mindful Software LLC, All rights reserved.

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:mysql_client/mysql_client.dart' as my;

import 'otel_mysql_suppression.dart';

const _tracerName = 'otel_mysql';
const _dbSystem = 'mysql';

Tracer _tracer() => OTel.tracerProvider().getTracer(_tracerName);

/// Best-effort SQL operation extraction. Pulls the first SQL keyword
/// (SELECT, INSERT, UPDATE, DELETE, BEGIN, COMMIT, ROLLBACK, etc.)
/// and uppercases it. Skips leading `--` and `/* */` comments.
String? _extractOperation(String sql) {
  var s = sql.trimLeft();
  while (true) {
    if (s.startsWith('--')) {
      final nl = s.indexOf('\n');
      if (nl == -1) return null;
      s = s.substring(nl + 1).trimLeft();
    } else if (s.startsWith('/*')) {
      final end = s.indexOf('*/');
      if (end == -1) return null;
      s = s.substring(end + 2).trimLeft();
    } else {
      break;
    }
  }
  final m = RegExp(r'^([A-Za-z]+)').firstMatch(s);
  return m?.group(1)?.toUpperCase();
}

/// Best-effort table-name extraction from the SQL text. Handles the
/// common DML / DQL shapes:
/// - `SELECT ... FROM <table>`
/// - `INSERT INTO <table> ...`
/// - `UPDATE <table> SET ...`
/// - `DELETE FROM <table> ...`
String? _extractTable(String sql) {
  final patterns = <RegExp>[
    RegExp(r'\bFROM\s+`?([a-zA-Z_][\w.]*)`?', caseSensitive: false),
    RegExp(r'\bINTO\s+`?([a-zA-Z_][\w.]*)`?', caseSensitive: false),
    RegExp(r'\bUPDATE\s+`?([a-zA-Z_][\w.]*)`?', caseSensitive: false),
  ];
  for (final p in patterns) {
    final m = p.firstMatch(sql);
    if (m != null) return m.group(1);
  }
  return null;
}

Attributes _attrs({
  required String sqlText,
  String? namespace,
  String? operationOverride,
  String? tableOverride,
  String? serverAddress,
  int? serverPort,
}) {
  final operation = operationOverride ?? _extractOperation(sqlText);
  final table = tableOverride ?? _extractTable(sqlText);
  return OTel.attributesFromMap(<String, Object>{
    Database.dbSystem.key: _dbSystem,
    Database.dbSystemName.key: _dbSystem,
    if (operation != null) Database.dbOperation.key: operation,
    if (operation != null) Database.dbOperationName.key: operation,
    if (table != null) Database.dbCollectionName.key: table,
    if (namespace != null) Database.dbNamespace.key: namespace,
    Database.dbQueryText.key: sqlText,
    if (serverAddress != null) ServerResource.serverAddress.key: serverAddress,
    if (serverPort != null) ServerResource.serverPort.key: serverPort,
  });
}

/// Runs [invoke] inside a CLIENT-kind span named `<op> <table>` (or
/// just `<op>` when no table can be extracted), with
/// `db.system.name=mysql` and the standard OTel db attributes.
///
/// Pass [namespace] when you know the schema / database name (becomes
/// `db.namespace`). Pass [operationOverride] / [tableOverride] when
/// best-effort SQL parsing would mis-tag the span. Pass
/// [serverAddress] / [serverPort] when you know the endpoint.
///
/// Exceptions are recorded with `error.type` + `recordException`, span
/// status is set to `Error`, and the exception is rethrown.
Future<R> tracedMysqlCall<R>({
  required String sqlText,
  required Future<R> Function() invoke,
  String? namespace,
  String? operationOverride,
  String? tableOverride,
  String? serverAddress,
  int? serverPort,
}) async {
  if (mysqlInstrumentationSuppressed()) return invoke();
  final operation = operationOverride ?? _extractOperation(sqlText);
  final table = tableOverride ?? _extractTable(sqlText);
  // OTel stable semconv: span name is `{operation} {target}` with NO
  // system prefix. `db.system.name=mysql` already carries the system.
  final op = operation ?? 'query';
  final name = table != null ? '$op $table' : op;
  final span = _tracer().startSpan(
    name,
    kind: SpanKind.client,
    attributes: _attrs(
      sqlText: sqlText,
      namespace: namespace,
      operationOverride: operationOverride,
      tableOverride: tableOverride,
      serverAddress: serverAddress,
      serverPort: serverPort,
    ),
  );
  try {
    return await invoke();
  } catch (e, st) {
    span.addAttributes(
      OTel.attributes([
        OTel.attributeString(
          ErrorResource.errorType.key,
          e.runtimeType.toString(),
        ),
      ]),
    );
    span.recordException(e, stackTrace: st);
    span.setStatus(SpanStatusCode.Error, e.toString());
    rethrow;
  } finally {
    span.end();
  }
}

/// Traced `execute` on `MySQLConnection`. Drop-in replacement that
/// best-effort parses the SQL for operation + table.
extension OTelMySQLConnection on my.MySQLConnection {
  /// Traced `execute`. Pass [namespace] when you know the schema; pass
  /// [operationOverride] / [tableOverride] for non-trivial SQL.
  Future<my.IResultSet> executeTraced(
    String query, [
    Map<String, dynamic>? params,
    bool iterable = false,
    String? namespace,
    String? operationOverride,
    String? tableOverride,
  ]) {
    return tracedMysqlCall<my.IResultSet>(
      sqlText: query,
      namespace: namespace,
      operationOverride: operationOverride,
      tableOverride: tableOverride,
      invoke: () => execute(query, params, iterable),
    );
  }
}
