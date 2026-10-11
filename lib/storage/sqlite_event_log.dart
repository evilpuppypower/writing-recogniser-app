import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../core/event_log.dart';

/// [EventLog] stored in the app's SQLite database.
class SqliteEventLog implements EventLog {
  SqliteEventLog(this._db);

  final Database _db;

  @override
  Future<void> log(LoggedEvent e) => _db.insert('events', {
    'type': e.type,
    'at': e.at.millisecondsSinceEpoch,
    'engine': e.engine,
    'latency_ms': e.latencyMs,
    'data': jsonEncode(e.data),
  });

  @override
  Future<List<LoggedEvent>> ofType(String type) async {
    final rows = await _db.query(
      'events',
      where: 'type = ?',
      whereArgs: [type],
      orderBy: 'id',
    );
    return [
      for (final r in rows)
        LoggedEvent(
          type: r['type']! as String,
          at: DateTime.fromMillisecondsSinceEpoch(r['at']! as int),
          engine: r['engine'] as String?,
          latencyMs: r['latency_ms'] as int?,
          data: (jsonDecode(r['data']! as String) as Map)
              .cast<String, Object?>(),
        ),
    ];
  }
}
