import Foundation
import SQLite3
import Darwin

// MARK: - SQLite OCR Store

final class OcrStore {
    static let shared = OcrStore()

    private var db: OpaquePointer?
    private let queue: DispatchQueue
    private let retentionDays: () -> Int
    private let now: () -> Date
    private let shouldScheduleMaintenance: Bool

    // Cached prepared statements
    private var insertStmt: OpaquePointer?
    private var cleanupStmt: OpaquePointer?
    private var cleanupTimer: DispatchSourceTimer?
    private var dbPath: String
    private let maxEntriesPerWindow = 3
    private let maintenanceInterval: TimeInterval = 6 * 3600

    private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(dbPath: String = NSHomeDirectory() + "/.lattices/ocr.db",
         retentionDays: @escaping () -> Int = {
             let saved = UserDefaults.standard.integer(forKey: "ocr.retentionDays")
             return saved > 0 ? saved : 7
         },
         now: @escaping () -> Date = Date.init,
         scheduleMaintenance: Bool = true,
         queue: DispatchQueue = DispatchQueue(label: "dev.lattices.app.ocrstore", qos: .background)) {
        self.dbPath = dbPath
        self.retentionDays = retentionDays
        self.now = now
        self.shouldScheduleMaintenance = scheduleMaintenance
        self.queue = queue
    }

    deinit { closeDatabase() }

    /// Drains pending writes before closing; useful for isolated store lifecycles.
    func close() {
        queue.sync { closeDatabase() }
    }

    private func closeDatabase() {
        cleanupTimer?.cancel()
        cleanupTimer = nil
        sqlite3_finalize(insertStmt)
        sqlite3_finalize(cleanupStmt)
        insertStmt = nil
        cleanupStmt = nil
        if let db { sqlite3_close(db) }
        db = nil
    }

    // MARK: - Open / Schema

    func open() {
        queue.sync {
            guard db == nil else { return }

            let dir = (dbPath as NSString).deletingLastPathComponent
            do {
                // Apply private permissions only when creating a directory;
                // this store does not change permissions of an existing parent.
                if !FileManager.default.fileExists(atPath: dir) {
                    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                            attributes: [.posixPermissions: 0o700])
                }
                // SQLITE_OPEN_NOFOLLOW rejects symbolic links in ancestors too
                // (including macOS /var -> /private/var). Resolve the parent
                // only; the database filename must still pass nofollow checks.
                // Foundation's URL resolver preserves the special /var alias;
                // SQLite needs the filesystem path returned by realpath.
                guard let parent = Darwin.realpath(dir, nil) else {
                    throw CocoaError(.fileNoSuchFile)
                }
                defer { free(parent) }
                dbPath = String(cString: parent) + "/" + (dbPath as NSString).lastPathComponent
                try secureFile(dbPath, create: true)
                try secureDatabaseFiles()
            } catch {
                DiagnosticLog.shared.error("OcrStore: could not secure database files")
                return
            }
            guard sqlite3_open_v2(self.dbPath, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK else {
                DiagnosticLog.shared.error("OcrStore: failed to open \(self.dbPath)")
                closeDatabase()
                return
            }

            // SQLite inherits the already-private database mode for new WAL
            // and SHM files. Existing sidecars were secured before opening.
            guard exec("PRAGMA journal_mode=WAL"),
                  exec("PRAGMA synchronous=NORMAL"),
                  exec("PRAGMA secure_delete=ON") else {
                closeDatabase()
                return
            }

            // Main table
            exec("""
                CREATE TABLE IF NOT EXISTS ocr_entry (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    wid INTEGER NOT NULL,
                    app TEXT NOT NULL,
                    title TEXT NOT NULL,
                    frame_x REAL,
                    frame_y REAL,
                    frame_w REAL,
                    frame_h REAL,
                    full_text TEXT NOT NULL,
                    timestamp REAL NOT NULL
                )
            """)
            exec("CREATE INDEX IF NOT EXISTS idx_ocr_entry_timestamp ON ocr_entry(timestamp)")
            exec("CREATE INDEX IF NOT EXISTS idx_ocr_entry_wid ON ocr_entry(wid)")

            // FTS5 content-sync table
            exec("""
                CREATE VIRTUAL TABLE IF NOT EXISTS ocr_fts USING fts5(
                    full_text, app, title,
                    content='ocr_entry', content_rowid='id'
                )
            """)

            // Triggers to keep FTS in sync
            exec("""
                CREATE TRIGGER IF NOT EXISTS ocr_fts_ai AFTER INSERT ON ocr_entry BEGIN
                    INSERT INTO ocr_fts(rowid, full_text, app, title)
                    VALUES (new.id, new.full_text, new.app, new.title);
                END
            """)
            exec("""
                CREATE TRIGGER IF NOT EXISTS ocr_fts_ad AFTER DELETE ON ocr_entry BEGIN
                    INSERT INTO ocr_fts(ocr_fts, rowid, full_text, app, title)
                    VALUES ('delete', old.id, old.full_text, old.app, old.title);
                END
            """)
            exec("""
                CREATE TRIGGER IF NOT EXISTS ocr_fts_au AFTER UPDATE ON ocr_entry BEGIN
                    INSERT INTO ocr_fts(ocr_fts, rowid, full_text, app, title)
                    VALUES ('delete', old.id, old.full_text, old.app, old.title);
                    INSERT INTO ocr_fts(rowid, full_text, app, title)
                    VALUES (new.id, new.full_text, new.app, new.title);
                END
            """)

            // Migration: add source column if not present
            migrateAddSourceColumn()

            // Prepare cached statements
            prepareInsert()
            prepareCleanup()

            runMaintenanceSync(reason: "open")

            DiagnosticLog.shared.info("OcrStore: opened \(self.dbPath)")
            if shouldScheduleMaintenance { schedulePeriodicMaintenance() }
        }
    }

    // MARK: - Insert (batch, async)

    func insert(results: [OcrWindowResult], gate: ScreenTextScanGate, permit: UInt64) {
        guard !results.isEmpty else { return }
        queue.async { [weak self] in
            guard let self else { return }
            // The permit must be checked at the actual write, not when queued.
            // Disabling OCR or editing exclusions invalidates outstanding scans.
            gate.commit(permit) {
                guard let stmt = self.insertStmt, self.beginTransaction() else { return }
                var succeeded = true
                for r in results {
                    sqlite3_bind_int64(stmt, 1, Int64(r.wid))
                    self.bindText(stmt, 2, r.app)
                    self.bindText(stmt, 3, r.title)
                    sqlite3_bind_double(stmt, 4, r.frame.x)
                    sqlite3_bind_double(stmt, 5, r.frame.y)
                    sqlite3_bind_double(stmt, 6, r.frame.w)
                    sqlite3_bind_double(stmt, 7, r.frame.h)
                    self.bindText(stmt, 8, r.fullText)
                    sqlite3_bind_double(stmt, 9, r.timestamp.timeIntervalSince1970)
                    self.bindText(stmt, 10, r.source.rawValue)
                    if sqlite3_step(stmt) != SQLITE_DONE { succeeded = false }
                    sqlite3_reset(stmt)
                    sqlite3_clear_bindings(stmt)
                    if !succeeded { break }
                }
                if !succeeded || !self.exec("COMMIT") { self.exec("ROLLBACK") }
            }
        }
    }

    /// Explicit user action only. Turning OCR off stops collection; it does
    /// not silently delete existing history. This is not forensic erasure.
    func clear() {
        queue.sync {
            guard beginTransaction() else { return }
            guard exec("DELETE FROM ocr_entry"),
                  exec("INSERT INTO ocr_fts(ocr_fts) VALUES ('rebuild')"),
                  exec("COMMIT") else {
                exec("ROLLBACK")
                return
            }
            // Retire WAL pages promptly when no other reader holds them.
            exec("PRAGMA wal_checkpoint(TRUNCATE)")
        }
    }

    // MARK: - Search (FTS5, synchronous)

    func search(query: String, app: String? = nil, limit: Int = 50) -> [OcrSearchResult] {
        queue.sync {
            guard let db else { return [] }

            var sql = """
                SELECT e.id, e.wid, e.app, e.title,
                       e.frame_x, e.frame_y, e.frame_w, e.frame_h,
                       e.full_text, e.timestamp,
                       snippet(ocr_fts, 0, '»', '«', '…', 32) AS snip,
                       COALESCE(e.source, 'ocr') AS source
                FROM ocr_fts f
                JOIN ocr_entry e ON e.id = f.rowid
                WHERE ocr_fts MATCH ?1 AND e.timestamp >= ?4
            """
            if app != nil { sql += " AND e.app = ?2" }
            sql += " ORDER BY rank LIMIT ?3"

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }

            bindText(stmt!, 1, query)
            if let app { bindText(stmt!, 2, app) }
            sqlite3_bind_int(stmt!, 3, Int32(clamping: max(0, limit)))
            sqlite3_bind_double(stmt!, 4, retentionCutoff())

            var results: [OcrSearchResult] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                results.append(rowToSearchResult(stmt!))
            }
            return results
        }
    }

    // MARK: - History (per-window, synchronous)

    func history(wid: UInt32, limit: Int = 50) -> [OcrSearchResult] {
        queue.sync {
            guard let db else { return [] }

            let sql = """
                SELECT id, wid, app, title,
                       frame_x, frame_y, frame_w, frame_h,
                       full_text, timestamp, '' AS snip,
                       COALESCE(source, 'ocr') AS source
                FROM ocr_entry
                WHERE wid = ?1 AND timestamp >= ?3
                ORDER BY timestamp DESC
                LIMIT ?2
            """

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_int64(stmt!, 1, Int64(wid))
            sqlite3_bind_int(stmt!, 2, Int32(clamping: max(0, limit)))
            sqlite3_bind_double(stmt!, 3, retentionCutoff())

            var results: [OcrSearchResult] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                results.append(rowToSearchResult(stmt!))
            }
            return results
        }
    }

    // MARK: - Recent (chronological, synchronous)

    func recent(limit: Int = 50) -> [OcrSearchResult] {
        queue.sync {
            guard let db else { return [] }

            let sql = """
                SELECT id, wid, app, title,
                       frame_x, frame_y, frame_w, frame_h,
                       full_text, timestamp, '' AS snip,
                       COALESCE(source, 'ocr') AS source
                FROM ocr_entry
                WHERE timestamp >= ?2
                ORDER BY timestamp DESC
                LIMIT ?1
            """

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_int(stmt!, 1, Int32(clamping: max(0, limit)))
            sqlite3_bind_double(stmt!, 2, retentionCutoff())

            var results: [OcrSearchResult] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                results.append(rowToSearchResult(stmt!))
            }
            return results
        }
    }

    // MARK: - Cleanup

    private func schedulePeriodicMaintenance() {
        cleanupTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + maintenanceInterval, repeating: maintenanceInterval)
        timer.setEventHandler { [weak self] in
            self?.runMaintenanceSync(reason: "timer")
        }
        cleanupTimer = timer
        timer.resume()
    }

    private func runMaintenanceSync(reason: String) {
        let days = max(1, retentionDays())
        guard beginTransaction() else { return }
        let ageDeleted = cleanupByAge(days: days)
        let widDeleted = pruneExcessPerWindow(maxPerWid: maxEntriesPerWindow)
        guard exec("COMMIT") else { exec("ROLLBACK"); return }
        let totalDeleted = ageDeleted + widDeleted
        if totalDeleted > 0 {
            exec("PRAGMA incremental_vacuum")
        }
        logMaintenance(reason: reason, retentionDays: days, ageDeleted: ageDeleted, widDeleted: widDeleted)
    }

    @discardableResult
    private func cleanupByAge(days: Int) -> Int {
        guard let db, let stmt = cleanupStmt else { return 0 }
        let cutoff = now().timeIntervalSince1970 - Double(days) * 86400
        sqlite3_bind_double(stmt, 1, cutoff)
        sqlite3_step(stmt)
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        return Int(sqlite3_changes(db))
    }

    @discardableResult
    private func pruneExcessPerWindow(maxPerWid: Int) -> Int {
        guard let db else { return 0 }
        let sql = """
            DELETE FROM ocr_entry WHERE id IN (
                SELECT id FROM (
                    SELECT id,
                           ROW_NUMBER() OVER (PARTITION BY wid ORDER BY timestamp DESC) AS rn
                    FROM ocr_entry
                ) ranked
                WHERE rn > ?1
            )
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt!, 1, Int32(maxPerWid))
        sqlite3_step(stmt!)
        return Int(sqlite3_changes(db))
    }

    private func logMaintenance(reason: String, retentionDays: Int, ageDeleted: Int, widDeleted: Int) {
        let rowCount = countRows()
        let sizeMB = fileSizeMB()
        DiagnosticLog.shared.info(
            "OcrStore: maintenance (\(reason)) retention=\(retentionDays)d ageDeleted=\(ageDeleted) widPruned=\(widDeleted) rows=\(rowCount) size=\(String(format: "%.1f", sizeMB))MB"
        )
    }

    private func countRows() -> Int {
        guard let db else { return 0 }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM ocr_entry", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt!) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt!, 0))
    }

    private func fileSizeMB() -> Double {
        let attrs = try? FileManager.default.attributesOfItem(atPath: dbPath)
        let bytes = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        return Double(bytes) / 1_048_576.0
    }

    // MARK: - Helpers

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        guard let db else { return false }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            DiagnosticLog.shared.error("OcrStore SQL error: \(msg)")
            sqlite3_free(err)
            return false
        }
        return true
    }

    private func retentionCutoff() -> TimeInterval {
        now().timeIntervalSince1970 - Double(max(1, retentionDays())) * 86400
    }

    private func beginTransaction() -> Bool {
        guard db != nil else { return false }
        do { try secureDatabaseFiles() } catch {
            DiagnosticLog.shared.error("OcrStore: refusing to write insecure database files")
            return false
        }
        return exec("BEGIN IMMEDIATE TRANSACTION")
    }

    private func secureDatabaseFiles() throws {
        for suffix in ["", "-wal", "-shm", "-journal"] {
            try secureFile(dbPath + suffix, create: false)
        }
    }

    private func secureFile(_ path: String, create: Bool) throws {
        let fd = Darwin.open(path, O_RDWR | O_NOFOLLOW | O_CLOEXEC | (create ? O_CREAT : 0), 0o600)
        if fd < 0 {
            if !create && errno == ENOENT { return }
            throw CocoaError(.fileWriteNoPermission)
        }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1, fchmod(fd, 0o600) == 0 else {
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    private func bindText(_ stmt: OpaquePointer, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, sqliteTransient)
    }

    private func prepareInsert() {
        let sql = """
            INSERT INTO ocr_entry (wid, app, title, frame_x, frame_y, frame_w, frame_h, full_text, timestamp, source)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
        """
        sqlite3_prepare_v2(db, sql, -1, &insertStmt, nil)
    }

    private func migrateAddSourceColumn() {
        // Check if source column exists
        var tableInfoStmt: OpaquePointer?
        let sql = "PRAGMA table_info(ocr_entry)"
        guard sqlite3_prepare_v2(db, sql, -1, &tableInfoStmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(tableInfoStmt) }

        var hasSource = false
        while sqlite3_step(tableInfoStmt) == SQLITE_ROW {
            if let name = sqlite3_column_text(tableInfoStmt, 1) {
                if String(cString: name) == "source" {
                    hasSource = true
                    break
                }
            }
        }

        if !hasSource {
            exec("ALTER TABLE ocr_entry ADD COLUMN source TEXT DEFAULT 'ocr'")
            DiagnosticLog.shared.info("OcrStore: migrated — added source column")
        }
    }

    private func prepareCleanup() {
        let sql = "DELETE FROM ocr_entry WHERE timestamp < ?1"
        sqlite3_prepare_v2(db, sql, -1, &cleanupStmt, nil)
    }

    private func columnText(_ stmt: OpaquePointer, _ index: Int32) -> String {
        if let cStr = sqlite3_column_text(stmt, index) {
            return String(cString: cStr)
        }
        return ""
    }

    private func rowToSearchResult(_ stmt: OpaquePointer) -> OcrSearchResult {
        let sourceStr = columnText(stmt, 11)
        let source = TextSource(rawValue: sourceStr) ?? .ocr
        return OcrSearchResult(
            id: sqlite3_column_int64(stmt, 0),
            wid: UInt32(clamping: sqlite3_column_int64(stmt, 1)),
            app: columnText(stmt, 2),
            title: columnText(stmt, 3),
            frame: WindowFrame(
                x: sqlite3_column_double(stmt, 4),
                y: sqlite3_column_double(stmt, 5),
                w: sqlite3_column_double(stmt, 6),
                h: sqlite3_column_double(stmt, 7)
            ),
            fullText: columnText(stmt, 8),
            snippet: columnText(stmt, 10),
            timestamp: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 9)),
            source: source
        )
    }
}
