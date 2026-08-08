// Licensed under the Apache License, Version 2.0
// Copyright 2025, Mindful Software LLC, All rights reserved.

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:otel_mysql/otel_mysql.dart';

Future<void> main() async {
  await OTel.initialize(serviceName: 'otel-mysql-example');

  // Drop-in traced `execute` on a `MySQLConnection`. In a real app:
  //
  //   final conn = await MySQLConnection.createConnection(
  //     host: 'mysql.internal',
  //     port: 3306,
  //     userName: 'shop',
  //     password: '...',
  //     databaseName: 'shop',
  //   );
  //   await conn.connect();
  //   final rows = await conn.executeTraced(
  //     'SELECT id, name FROM users WHERE id = :id',
  //     {'id': 42},
  //   );
  //
  // Each call runs inside a CLIENT-kind span named `SELECT users`
  // (OTel stable semconv: `{operation} {target}`, no system prefix)
  // with db.system.name=mysql, db.operation.name, db.collection.name
  // and db.query.text attributes.

  // Call-site helper for anything the extension does not cover.
  // Operation and table are best-effort parsed from the SQL; pass
  // operationOverride / tableOverride when parsing would mis-tag.
  final count = await tracedMysqlCall<int>(
    sqlText: 'SELECT count(*) FROM widgets',
    namespace: 'shop',
    serverAddress: 'mysql.internal',
    serverPort: 3306,
    // In a real app: () => conn.execute('SELECT count(*) FROM widgets')
    invoke: () async => 1,
  );
  assert(count == 1);

  // Suppress instrumentation for a scope (e.g. noisy polling).
  await runWithoutMysqlInstrumentationAsync(() async {
    // Queries in here emit no spans.
  });

  await OTel.shutdown();
}
