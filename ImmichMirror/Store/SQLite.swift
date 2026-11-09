import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum SQLValue {
  case text(String)
  case int(Int64)
  case real(Double)
  case null
}

/// Tiny SQLite wrapper. Not thread-safe; owned by MirrorStore which is used from one actor.
final class SQLite {
  private var db: OpaquePointer?

  init(path: String) throws {
    guard
      sqlite3_open_v2(
        path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        == SQLITE_OK
    else {
      throw err("open")
    }
    // The app and a sync can open the store at the same time: wait for the other connection's lock
    // instead of failing at once with "database is locked".
    sqlite3_busy_timeout(db, 5000)
    try exec("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;")
  }

  deinit { sqlite3_close(db) }

  private func err(_ ctx: String) -> NSError {
    NSError(
      domain: "SQLite", code: Int(sqlite3_errcode(db)),
      userInfo: [NSLocalizedDescriptionKey: "\(ctx): \(String(cString: sqlite3_errmsg(db)))"])
  }

  func exec(_ sql: String) throws {
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw err(sql) }
  }

  func run(_ sql: String, _ args: [SQLValue] = []) throws {
    let st = try prepare(sql, args)
    defer { sqlite3_finalize(st) }
    let rc = sqlite3_step(st)
    guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw err(sql) }
  }

  func query(_ sql: String, _ args: [SQLValue] = [], _ row: (Row) throws -> Void) throws {
    let st = try prepare(sql, args)
    defer { sqlite3_finalize(st) }
    while true {
      let rc = sqlite3_step(st)
      if rc == SQLITE_DONE { break }
      guard rc == SQLITE_ROW else { throw err(sql) }
      try row(Row(st: st))
    }
  }

  func scalarInt(_ sql: String, _ args: [SQLValue] = []) throws -> Int {
    var v = 0
    try query(sql, args) { v = $0.int(0) }
    return v
  }

  func transaction(_ body: () throws -> Void) throws {
    try exec("BEGIN IMMEDIATE")
    do {
      try body()
      try exec("COMMIT")
    } catch {
      try? exec("ROLLBACK")
      throw error
    }
  }

  private func prepare(_ sql: String, _ args: [SQLValue]) throws -> OpaquePointer? {
    var st: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { throw err(sql) }
    for (i, a) in args.enumerated() {
      let idx = Int32(i + 1)
      switch a {
      case .text(let s): sqlite3_bind_text(st, idx, s, -1, sqliteTransient)
      case .int(let n): sqlite3_bind_int64(st, idx, n)
      case .real(let d): sqlite3_bind_double(st, idx, d)
      case .null: sqlite3_bind_null(st, idx)
      }
    }
    return st
  }

  struct Row {
    let st: OpaquePointer?
    func text(_ i: Int32) -> String? {
      guard let c = sqlite3_column_text(st, i) else { return nil }
      return String(cString: c)
    }
    func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(st, i)) }
    func real(_ i: Int32) -> Double { sqlite3_column_double(st, i) }
    func isNull(_ i: Int32) -> Bool { sqlite3_column_type(st, i) == SQLITE_NULL }
  }
}

extension Optional where Wrapped == String {
  var sql: SQLValue { map { .text($0) } ?? .null }
}
