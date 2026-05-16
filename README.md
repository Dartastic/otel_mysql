# otel_mysql

OpenTelemetry instrumentation for package:mysql_client. Wraps MySQL query execution in CLIENT-kind spans following OTel stable semantic conventions (db.system.name=mysql, db.operation.name, db.collection.name, db.namespace, db.query.text).

Span names follow OTel stable semantic conventions:
`{operation.name} {target}` with no system prefix (the system is
already in `db.system.name` / `messaging.system`).

Part of the [Dartastic](https://dartastic.io) OpenTelemetry family.
