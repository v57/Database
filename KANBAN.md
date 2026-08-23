# KANBAN — MongoDB client for Database app

Plan: .hermes/plans/2026-08-16_175045-mongodb-client.md

## To Do
- [ ] T13: xcodebuild + run app + manual verification (MongoDB flow)

## In Progress
- [ ] T11: NavigationSplitView shell + connections sidebar + form
- [ ] T12: collections + search + documents + query actions

## Done
- [x] T1: Package.swift MongoDB target + MongoSwift dep (+ explicit NIO, preconcurrency import)
- [x] T2: ConnectionConfig (4 unit tests pass)
- [x] T3: MongoDBError + BSONSupport + Exports (@_exported + @preconcurrency) + DriverSendable conformances
- [x] T4: MongoConnection connect/ping/databases/collections + search (2 tests pass)
- [x] T5: find (test pass)
- [x] T6: updateMany (test pass)
- [x] T7: deleteMany (test pass)
- [x] T8: full swift test — 9/9 pass (4 unit + 5 integration vs localhost)
- [x] T9: pbxproj MongoDB product link (plutil OK)
- [x] T10: ConnectionRecord + DatabaseModel + ContentView shell

Committed: a1b533c "Added MongoDB client support"

Multi-engine wave (2026-08-23):
- [x] E1: docker-compose.yml — mongo:8 + postgres:18 + redis:8 on 127.0.0.1, healthy
- [x] E2: Sources/PostgreSQL wrapper (postgres-nio 1.33.1) + 10 tests pass
- [x] E3: Sources/Redis wrapper (RediStack 1.6.3) + 11 tests pass
- [x] E4: App multi-engine: DatabaseEngine/EngineSettings, record.engine column,
      engine picker in form, sidebar rows + session dispatch, row/key->Document
- [x] E5: pbxproj product links repaired (hex-ID corruption) + SWIFT_ENABLE_EXPLICIT_MODULES=NO; xcodebuild SUCCEEDED

Committed: a681973 "Added PostgreSQL and Redis client support"
           0923671 "App: engine picker, multi-engine sessions, row/key to document conversion"

Follow-ups (not started):
- SQL editor / Redis key CRUD flows (update/delete currently MongoDB-only)
- Keychain for stored passwords
- Driver-API deviations discovered during implementation (plan correction):
- MongoSwift 1.3.1: MongoClient needs explicit NIO EventLoopGroup (using:), find/deleteMany take unlabeled non-optional filters, updateMany/deleteMany return Optionals, FindOptions.limit is Int
- swift-bson 3.x renamed Document -> BSONDocument (typealias shim added); extendedJSON -> description
- Swift 6 region isolation: @preconcurrency import alone not enough; retroactive @unchecked Sendable conformances for MongoClient/MongoDatabase/MongoCollection/MongoCursor/BSONDocument in DriverSendable.swift