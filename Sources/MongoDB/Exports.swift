// @preconcurrency: MongoSwift 1.3.1 predates Swift 6 strict concurrency (its
// MongoClient/MongoCollection types are not Sendable-clean). This downgrades
// region-isolation diagnostics for its types everywhere MongoDB is imported —
// the documented migration path for consuming pre-concurrency dependencies.
@preconcurrency @_exported import MongoSwift
