import Foundation
import Testing
@testable import MongoDB

@Suite struct ConnectionConfigTests {
    @Test func plainUri() {
        let c = ConnectionConfig(name: "local", host: "127.0.0.1", port: 27017)
        #expect(c.connectionString == "mongodb://127.0.0.1:27017")
    }

    @Test func uriWithCredentialsPercentEncodes() {
        let c = ConnectionConfig(name: "a", host: "db.example.com", port: 27017,
                                 username: "u ser", password: "p@ss:word")
        #expect(c.connectionString == "mongodb://u%20ser:p%40ss%3Aword@db.example.com:27017")
    }

    @Test func uriWithAuthSource() {
        let c = ConnectionConfig(name: "a", host: "h", port: 27018, username: "u", password: "p", authSource: "admin")
        #expect(c.connectionString == "mongodb://u:p@h:27018/?authSource=admin")
    }

    @Test func uriWithDirectConnection() {
        let c = ConnectionConfig(name: "local", host: "127.0.0.1", port: 27017, directConnection: true)
        #expect(c.connectionString == "mongodb://127.0.0.1:27017/?directConnection=true")
    }

    @Test func uriWithAuthSourceAndDirectConnection() {
        let c = ConnectionConfig(name: "a", host: "h", port: 27017, username: "u", password: "p",
                                 authSource: "admin", directConnection: true)
        #expect(c.connectionString == "mongodb://u:p@h:27017/?authSource=admin&directConnection=true")
    }

    @Test func directConnectionOffByDefault() {
        let c = ConnectionConfig(name: "local", host: "127.0.0.1", port: 27017)
        #expect(c.directConnection == false)
        #expect(!c.connectionString.contains("directConnection"))
    }

    @Test func validation() {
        #expect(ConnectionConfig(name: "x", host: "", port: 27017).isValid == false)
        #expect(ConnectionConfig(name: "x", host: "h", port: 0).isValid == false)
        #expect(ConnectionConfig(name: "x", host: "h", port: 27017).isValid)
    }
}
