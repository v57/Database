# KANBAN — MongoDB client for Database app

Plan: .hermes/plans/2026-08-16_175045-mongodb-client.md

## To Do
- [ ] T13: xcodebuild + run app + manual verification

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

Driver-API deviations discovered during implementation (plan correction):
- MongoSwift 1.3.1: MongoClient needs explicit NIO EventLoopGroup (using:), find/deleteMany take unlabeled non-optional filters, updateMany/deleteMany return Optionals, FindOptions.limit is Int
- swift-bson 3.x renamed Document -> BSONDocument (typealias shim added); extendedJSON -> description
- Swift 6 region isolation: @preconcurrency import alone not enough; retroactive @unchecked Sendable conformances for MongoClient/MongoDatabase/MongoCollection/MongoCursor/BSONDocument in DriverSendable.swift