import Foundation
import SQLite

/// A small SQLite database to explore without any setup: movies and their
/// directors. Created on first use in the app's support folder and kept
/// afterwards, so changes made while practising stay put.
enum SampleDatabase {
  static let name = "Sample Movies"

  /// The sample file, created (and filled) when it doesn't exist yet.
  static func url() async throws -> URL {
    let folder = URL.applicationSupportDirectory.appendingPathComponent(
      "dev.v57.db", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent("\(name).sqlite")
    guard !FileManager.default.fileExists(atPath: url.path) else { return url }
    // Built under a temporary name and moved into place, so a failed build
    // never leaves a half-filled sample behind.
    let partial = folder.appendingPathComponent("\(name).partial.sqlite")
    try? FileManager.default.removeItem(at: partial)
    FileManager.default.createFile(atPath: partial.path, contents: nil)
    let connection = SQLiteConnection(config: SQLiteConnectionConfig(name: name, filePath: partial.path))
    do {
      try await connection.connect()
      try await connection.execute(sql: script)
      await connection.disconnect()
      try FileManager.default.moveItem(at: partial, to: url)
    } catch {
      await connection.disconnect()
      try? FileManager.default.removeItem(at: partial)
      throw error
    }
    return url
  }

  private static let directors: [(name: String, born: Int, country: String)] = [
    ("Hayao Miyazaki", 1941, "Japan"),
    ("Steven Spielberg", 1946, "United States"),
    ("Christopher Nolan", 1970, "United Kingdom"),
    ("Greta Gerwig", 1983, "United States"),
    ("Bong Joon-ho", 1969, "South Korea"),
    ("Agnès Varda", 1928, "France"),
    ("Pete Docter", 1968, "United States"),
    ("Denis Villeneuve", 1967, "Canada"),
    ("Akira Kurosawa", 1910, "Japan"),
    ("Jane Campion", 1954, "New Zealand"),
    ("Céline Sciamma", 1978, "France"),
    ("George Miller", 1945, "Australia"),
  ]

  /// title, year, genre, minutes, director (1-based), my rating, watched on, notes
  private static let movies:
    [(String, Int, String, Int, Int, Int?, String?, String?)] = [
      ("Spirited Away", 2001, "Animation", 125, 1, 5, "2024-01-14", "Watch again with the kids"),
      ("My Neighbor Totoro", 1988, "Animation", 86, 1, 5, "2023-11-02", nil),
      ("Princess Mononoke", 1997, "Animation", 134, 1, 4, "2024-03-09", nil),
      ("Jaws", 1975, "Thriller", 124, 2, 4, "2023-07-21", "Summer movie night"),
      ("E.T. the Extra-Terrestrial", 1982, "Science Fiction", 115, 2, nil, nil, nil),
      ("Jurassic Park", 1993, "Adventure", 127, 2, 5, "2023-08-05", nil),
      ("Inception", 2010, "Science Fiction", 148, 3, 4, "2024-02-17", nil),
      ("Interstellar", 2014, "Science Fiction", 169, 3, 5, "2024-05-25", "Best on a big screen"),
      ("Lady Bird", 2017, "Comedy", 94, 4, 4, "2024-04-06", nil),
      ("Little Women", 2019, "Drama", 135, 4, nil, nil, "Recommended by Sam"),
      ("Parasite", 2019, "Thriller", 132, 5, 5, "2023-12-30", nil),
      ("The Host", 2006, "Horror", 120, 5, 3, "2024-06-14", nil),
      ("Cléo from 5 to 7", 1962, "Drama", 90, 6, nil, nil, nil),
      ("Up", 2009, "Animation", 96, 7, 5, "2023-09-16", "The first ten minutes!"),
      ("Inside Out", 2015, "Animation", 95, 7, 4, "2023-10-07", nil),
      ("Arrival", 2016, "Science Fiction", 116, 8, 5, "2024-07-20", nil),
      ("Dune", 2021, "Science Fiction", 155, 8, 4, "2024-08-03", nil),
      ("Seven Samurai", 1954, "Action", 207, 9, nil, nil, "Save for a long weekend"),
      ("Ran", 1985, "Drama", 162, 9, nil, nil, nil),
      ("The Piano", 1993, "Drama", 121, 10, 4, "2024-09-12", nil),
      ("Portrait of a Lady on Fire", 2019, "Drama", 122, 11, 5, "2024-02-29", nil),
      ("Mad Max: Fury Road", 2015, "Action", 120, 12, 4, "2023-06-10", nil),
      ("Happy Feet", 2006, "Animation", 108, 12, 3, "2023-12-24", nil),
    ]

  private static var script: String {
    func text(_ value: String?) -> String {
      value.map { "'" + $0.replacingOccurrences(of: "'", with: "''") + "'" } ?? "NULL"
    }
    var sql = """
      BEGIN;
      CREATE TABLE directors (
        id INTEGER PRIMARY KEY,
        name TEXT NOT NULL,
        born INTEGER,
        country TEXT
      );
      CREATE TABLE movies (
        id INTEGER PRIMARY KEY,
        title TEXT NOT NULL,
        year INTEGER,
        genre TEXT,
        runtime_minutes INTEGER,
        director_id INTEGER REFERENCES directors(id),
        my_rating INTEGER CHECK (my_rating BETWEEN 1 AND 5),
        watched_on TEXT,
        notes TEXT
      );

      """
    for (i, d) in directors.enumerated() {
      sql += "INSERT INTO directors VALUES (\(i + 1), \(text(d.name)), \(d.born), \(text(d.country)));\n"
    }
    for (i, m) in movies.enumerated() {
      let rating = m.5.map(String.init) ?? "NULL"
      sql +=
        "INSERT INTO movies VALUES (\(i + 1), \(text(m.0)), \(m.1), \(text(m.2)), \(m.3), \(m.4), \(rating), \(text(m.6)), \(text(m.7)));\n"
    }
    return sql + "COMMIT;"
  }
}
