#!/usr/bin/env python3
"""Fills the docker-compose.yml servers with demo data and writes demo files.

Usage:
  docker compose up -d --wait
  Scripts/seed-demo.py --files ~/Documents/Database-Demo [--data-dir <dev data folder>]

--files     where the SQLite, DuckDB, Parquet and CSV demo files go
--data-dir  also write connections for every engine there (for a DEBUG run with --data-dir)
"""

import argparse
import datetime
import json
import os
import random
import subprocess
import sys
import uuid

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
random.seed(57)

FIRST = ["Maya", "Liam", "Sofia", "Noah", "Aiko", "Omar", "Elena", "Lucas", "Grace", "Jonas", "Priya", "Mateo",
         "Ines", "Tomasz", "Akosua", "Rafael", "Hana", "Diego", "Noor", "Lin"]
LAST = ["Okafor", "Chen", "Marino", "Fischer", "Tanaka", "Haddad", "Petrova", "Silva", "Mensah", "Berg", "Nair",
        "Ruiz", "Costa", "Novak", "Boateng", "Moreau", "Kim", "Reyes", "Haddad", "Wei"]
CITIES = ["Lisbon", "Oslo", "Milan", "Berlin", "Osaka", "Beirut", "Sofia", "Porto", "Accra", "Bergen"]
PRODUCTS = [("Aurora Wireless Headphones", "Audio", 249.0), ("Lumen Desk Speaker", "Audio", 129.0),
            ("Drift Earbuds", "Audio", 89.0), ("Tidal Soundbar", "Audio", 399.0), ("Ember Turntable", "Audio", 319.0),
            ("Pocket Radio", "Audio", 59.0), ("Arc Desk Lamp", "Home", 79.0), ("Cove Kettle", "Home", 49.0),
            ("Slate Notebook", "Office", 19.0), ("Glide Pen", "Office", 9.5), ("Fern Planter", "Home", 29.0),
            ("Orbit Clock", "Home", 39.0)]
STATUSES = ["shipped"] * 6 + ["pending"] * 2 + ["refunded", "cancelled"]
NOW = datetime.datetime(2026, 10, 12, 10, 0, 0)


def run(service, *command, stdin=None):
    result = subprocess.run(["docker", "compose", "exec", "-T", service, *command], cwd=ROOT, input=stdin,
                            capture_output=True, text=True)
    if result.returncode != 0:
        sys.stderr.write(f"{service}: {(result.stderr + result.stdout).strip()[:2000]}\n")
        raise SystemExit(1)
    return result.stdout


def q(text):
    return "'" + str(text).replace("'", "''") + "'"


def name(i):
    return f"{FIRST[i % len(FIRST)]} {LAST[(i * 7) % len(LAST)]}"


def shop_rows():
    customers = [(i + 1, name(i), f"{FIRST[i % len(FIRST)].lower()}{i}@example.com", CITIES[i % len(CITIES)])
                 for i in range(40)]
    orders, items = [], []
    for n in range(250):
        oid = 10233 + n
        created = NOW - datetime.timedelta(minutes=37 * (249 - n))
        lines = random.randint(1, 4)
        total = 0.0
        for _ in range(lines):
            pid = random.randint(1, len(PRODUCTS))
            qty = random.randint(1, 3)
            price = PRODUCTS[pid - 1][2]
            total += price * qty
            items.append((len(items) + 1, oid, pid, qty, price))
        orders.append((oid, random.randint(1, 40), random.choice(STATUSES), lines, round(total, 2), created))
    return customers, orders, items


def seed_sql(engine):
    customers, orders, items = shop_rows()
    # SQL Server reads only the ISO 8601 "T" form reliably in multi-row VALUES.
    date_format = "%Y-%m-%dT%H:%M:%S" if engine == "sqlserver" else "%Y-%m-%d %H:%M:%S"
    if engine == "postgres":
        ts, text, dec, auto = "timestamptz", "text", "numeric(10,2)", ""
    elif engine == "sqlserver":
        ts, text, dec, auto = "datetime2", "nvarchar(200)", "decimal(10,2)", ""
    else:
        ts, text, dec, auto = "datetime", "varchar(200)", "decimal(10,2)", ""
    statements = [
        f"CREATE TABLE customers (id INT PRIMARY KEY, name {text} NOT NULL, email {text}, city {text})",
        f"CREATE TABLE products (id INT PRIMARY KEY, name {text} NOT NULL, category {text}, price {dec})",
        f"CREATE TABLE orders (id INT PRIMARY KEY, customer_id INT, status {text}, items INT, total {dec}, created_at {ts}, note {text}, "
        f"FOREIGN KEY (customer_id) REFERENCES customers(id))",
        f"CREATE TABLE order_items (id INT PRIMARY KEY, order_id INT, product_id INT, quantity INT, price {dec}, "
        f"FOREIGN KEY (order_id) REFERENCES orders(id), FOREIGN KEY (product_id) REFERENCES products(id))",
        f"CREATE TABLE refunds (id INT PRIMARY KEY, order_id INT, amount {dec}, reason {text}, FOREIGN KEY (order_id) REFERENCES orders(id))",
    ]
    for chunk in [customers[i:i + 50] for i in range(0, len(customers), 50)]:
        statements.append("INSERT INTO customers VALUES " + ", ".join(f"({c[0]}, {q(c[1])}, {q(c[2])}, {q(c[3])})" for c in chunk))
    statements.append("INSERT INTO products VALUES " + ", ".join(
        f"({i + 1}, {q(p[0])}, {q(p[1])}, {p[2]})" for i, p in enumerate(PRODUCTS)))
    for chunk in [orders[i:i + 100] for i in range(0, len(orders), 100)]:
        statements.append("INSERT INTO orders VALUES " + ", ".join(
            f"({o[0]}, {o[1]}, {q(o[2])}, {o[3]}, {o[4]}, {q(o[5].strftime(date_format))}, NULL)" for o in chunk))
    for chunk in [items[i:i + 200] for i in range(0, len(items), 200)]:
        statements.append("INSERT INTO order_items VALUES " + ", ".join(f"({i[0]}, {i[1]}, {i[2]}, {i[3]}, {i[4]})" for i in chunk))
    refunds = [o for o in orders if o[2] == "refunded"]
    statements.append("INSERT INTO refunds VALUES " + ", ".join(
        f"({n + 1}, {o[0]}, {o[4]}, {q('Arrived damaged' if n % 2 else 'Changed mind')})" for n, o in enumerate(refunds)))
    return statements


def seed_postgres():
    run("postgres", "psql", "-U", "postgres", "-c", "DROP DATABASE IF EXISTS shop")
    run("postgres", "psql", "-U", "postgres", "-c", "CREATE DATABASE shop")
    sql = ";\n".join(seed_sql("postgres")) + ";\n"
    sql += ("CREATE VIEW monthly_revenue AS SELECT date_trunc('month', created_at) AS month, count(*) AS orders, "
            "sum(total) AS revenue FROM orders GROUP BY 1;\n")
    run("postgres", "psql", "-v", "ON_ERROR_STOP=1", "-q", "-U", "postgres", "-d", "shop", stdin=sql)
    print("PostgreSQL: shop")


def seed_mysql(service, database):
    sql = f"DROP DATABASE IF EXISTS {database}; CREATE DATABASE {database}; USE {database};\n"
    sql += ";\n".join(seed_sql("mysql")) + ";\n"
    client = "mysql" if service == "mysql" else "mariadb"
    run(service, client, "-uroot", "-pdatabasepro", stdin=sql)
    print(f"{service}: {database}")


def split_rows(values):
    rows, depth, quote, current = [], 0, False, ""
    for ch in values:
        if ch == "'":
            quote = not quote
        if not quote and ch == "(":
            depth += 1
        if not quote and ch == ")":
            depth -= 1
        if not quote and depth == 0 and ch == ",":
            rows.append(current)
            current = ""
            continue
        current += ch
    rows.append(current)
    return rows


def seed_sqlserver():
    sqlcmd = ["/opt/mssql-tools18/bin/sqlcmd", "-C", "-b", "-S", "localhost", "-U", "sa", "-P", "DatabasePro#2026"]
    run("sqlserver", *sqlcmd, "-Q",
        "IF DB_ID('LegacyERP') IS NOT NULL BEGIN ALTER DATABASE LegacyERP SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE LegacyERP; END; CREATE DATABASE LegacyERP")
    # One row per INSERT: SQL Server's multi-row VALUES trips over the date column here.
    statements = []
    for statement in seed_sql("sqlserver"):
        if statement.startswith("INSERT INTO ") and " VALUES (" in statement:
            head, rows = statement.split(" VALUES ", 1)
            statements.append("\n".join(f"{head} VALUES {row.strip()}" for row in split_rows(rows)))
        else:
            statements.append(statement)
    sql = "\nGO\n".join(statements) + "\nGO\nCREATE SCHEMA sales\nGO\nCREATE TABLE sales.targets (region nvarchar(50) PRIMARY KEY, quarter_target decimal(12,2))\nGO\n"
    sql += "INSERT INTO sales.targets VALUES (N'Europe', 2500000), (N'North America', 2400000), (N'Asia Pacific', 1500000)\nGO\n"
    run("sqlserver", *sqlcmd, "-d", "LegacyERP", stdin=sql)
    print("SQL Server: LegacyERP")


def seed_mongo():
    reviews, inventory, products = [], [], []
    titles = ["Fills the whole room", "Comfy for long calls", "Battery lasts all week", "Great value", "Stopped working",
              "Exactly as described", "Would buy again", "A bit loud"]
    for i, (pname, category, price) in enumerate(PRODUCTS):
        products.append({
            "_id": {"$oid": f"6703f1c2e4b0a91c{i:08x}"}, "name": pname, "category": category, "price": price,
            "stock": random.randint(0, 200), "rating": round(random.uniform(3.8, 4.9), 1),
            "tags": random.sample(["wireless", "desk", "bluetooth", "gift", "eco", "portable"], 3),
            "variants": [{"color": c, "sku": f"{pname[:3].upper()}-{c[:2].upper()}"} for c in random.sample(["Graphite", "Sand", "Sky", "Olive"], 2)],
            "specs": {"weightGrams": random.randint(80, 2400), "warrantyYears": random.choice([1, 2])},
            "onSale": i % 3 == 0, "updatedAt": {"$date": (NOW - datetime.timedelta(hours=i * 5)).isoformat() + "Z"},
        })
    for n in range(1500):
        p = random.randrange(len(PRODUCTS))
        reviews.append({
            "product_id": {"$oid": f"6703f1c2e4b0a91c{p:08x}"}, "rating": random.choice([3, 4, 4, 5, 5, 5, 2]),
            "title": random.choice(titles), "createdAt": {"$date": (NOW - datetime.timedelta(hours=n * 6)).isoformat() + "Z"},
        })
    script = f"""
      db = db.getSiblingDB('catalog'); db.dropDatabase();
      db.products.insertMany(EJSON.parse({json.dumps(json.dumps(products))}));
      db.reviews.insertMany(EJSON.parse({json.dumps(json.dumps(reviews))}));
      db.inventory.insertMany(db.products.find().toArray().map(p => ({{ product_id: p._id, warehouse: 'Lisbon', onHand: p.stock }})));
      db.carts.insertMany([{{ user: 'maya', items: [{{ sku: 'AUR-GR', qty: 1 }}], updatedAt: new Date() }}]);
      db.reviews.createIndex({{ createdAt: 1 }});
    """
    # Too long for an argument; mongosh reads it from stdin.
    run("mongodb", "sh", "-c", "cat > /tmp/seed.js && mongosh --quiet --file /tmp/seed.js", stdin=script)
    print("MongoDB: catalog")


def seed_redis():
    commands = ["FLUSHDB"]
    for i in range(60):
        commands.append(f"HSET session:{uuid.UUID(int=(i + 1) * 0x9E3779B97F4A7C15).hex[-8:]} user {FIRST[i % 20].lower()} cart {i % 5} ip 10.0.0.{i}")
        commands.append(f"EXPIRE session:{uuid.UUID(int=(i + 1) * 0x9E3779B97F4A7C15).hex[-8:]} {600 + i * 120}")
    for i in range(25):
        commands.append(f"SADD cart:{1000 + i} AUR-GR LUM-SA")
    for i in range(8):
        commands.append(f"SET rate-limit:10.0.0.{i} {i * 3} EX 42")
    for member, score in [("noor_k", 9840), ("tomasz", 9512), ("lin.wei", 9107), ("akosua", 8866), ("rafael_m", 8420),
                          ("hana", 8012), ("diego.r", 7775), ("ines", 7301)]:
        commands.append(f"ZADD leaderboard:weekly {score} {member}")
    commands.append("HSET feature-flags newCheckout on darkMode on betaSearch off")
    for i in range(30):
        commands.append(f"XADD queue:emails * to user{i}@example.com template welcome")
    commands.append("RPUSH recent:searches headphones lamp kettle speaker turntable")
    commands.append("EXPIRE recent:searches 604800")
    commands.append("SADD online:users maya liam sofia noah aiko")
    commands.append("SET stats:visits 48213")
    commands.append('JSON.SET config:site $ \'{"title": "Shop", "currency": "EUR", "maintenance": false}\'')
    run("redis", "redis-cli", stdin="\n".join(commands) + "\n")
    run("redis", "redis-cli", "-n", "1", "SET", "migrations:last", "2026_10_01")
    print("Redis: database 0 and 1")


def seed_cql(service, keyspace, user=None):
    cql = [f"DROP KEYSPACE IF EXISTS {keyspace};",
           f"CREATE KEYSPACE {keyspace} WITH replication = {{'class': 'SimpleStrategy', 'replication_factor': 1}};",
           f"CREATE TABLE {keyspace}.readings (sensor text, at timestamp, value double, unit text, tags set<text>, PRIMARY KEY (sensor, at)) WITH CLUSTERING ORDER BY (at DESC);",
           f"CREATE TABLE {keyspace}.devices (id uuid PRIMARY KEY, name text, site text, installed date, attrs map<text, text>);"]
    for s in range(6):
        for m in range(30):
            at = (NOW - datetime.timedelta(minutes=5 * m)).strftime("%Y-%m-%d %H:%M:%S+0000")
            cql.append(f"INSERT INTO {keyspace}.readings (sensor, at, value, unit, tags) VALUES ('sensor-{s}', '{at}', {round(18 + random.random() * 6, 2)}, 'C', {{'floor-{s % 3}'}});")
    for d in range(6):
        cql.append(f"INSERT INTO {keyspace}.devices (id, name, site, installed, attrs) VALUES ({uuid.UUID(int=d + 1)}, 'Sensor {d}', '{CITIES[d]}', '2026-0{d + 1}-15', {{'model': 'T{d}'}});")
    command = ["cqlsh"] + (["-u", user, "-p", user] if user else [])
    run(service, *command, stdin="\n".join(cql) + "\n")
    print(f"{service}: {keyspace}")


def write_files(folder):
    os.makedirs(folder, exist_ok=True)
    path = os.path.join(folder, "notes.sqlite")
    if os.path.exists(path):
        os.remove(path)
    sql = ["CREATE TABLE notebooks (id INTEGER PRIMARY KEY, name TEXT NOT NULL);",
           "CREATE TABLE notes (id INTEGER PRIMARY KEY, notebook_id INTEGER REFERENCES notebooks(id), title TEXT NOT NULL, body TEXT, pinned INTEGER DEFAULT 0, updated TEXT);",
           "INSERT INTO notebooks (name) VALUES ('Home'), ('Work'), ('Ideas');"]
    for i in range(30):
        sql.append(f"INSERT INTO notes (notebook_id, title, body, pinned, updated) VALUES ({i % 3 + 1}, {q('Note ' + str(i + 1))}, {q('Something to remember #' + str(i))}, {1 if i % 7 == 0 else 0}, '2026-10-{i % 28 + 1:02d}');")
    subprocess.run(["sqlite3", path], input="\n".join(sql), text=True, check=True)
    with open(os.path.join(folder, "customers.csv"), "w") as f:
        f.write("id,name,city,signed_up\n")
        for i in range(40):
            f.write(f"{i + 1},{name(i)},{CITIES[i % len(CITIES)]},2026-0{i % 9 + 1}-1{i % 9}\n")
    with open(os.path.join(folder, "events.json"), "w") as f:
        json.dump([{"kind": random.choice(["click", "view", "buy"]), "n": random.randint(1, 9)} for _ in range(200)], f)
    # DuckDB writes its own file and the Parquet one (so the versions match the app's DuckDB).
    env = dict(os.environ, DATABASE_DEMO_DIR=folder)
    subprocess.run(["swift", "test", "--filter", "writesDemoFiles"], cwd=ROOT, env=env, check=True,
                   stdout=subprocess.DEVNULL)
    print(f"Files: {folder}")


def write_connections(data_dir, files):
    os.makedirs(data_dir, exist_ok=True)
    def profile(name, engine, port, user="", database="", path="", color="none", production=False, readonly=False, options=None):
        return {"id": str(uuid.uuid5(uuid.NAMESPACE_DNS, name)).upper(), "name": name, "engine": engine,
                "host": "127.0.0.1", "port": port, "user": user, "database": database, "filePath": path,
                "options": options or {}, "color": color, "isProduction": production, "isReadOnly": readonly,
                "useTLS": False, "allowUntrustedCertificate": False, "savePassword": True,
                "ssh": {"enabled": False, "host": "", "port": 22, "user": "", "auth": "key"}}
    profiles = [
        profile("Shop", "postgres", 5432, "postgres", "shop", color="red", production=True),
        profile("Analytics", "duckdb", 0, path=os.path.join(files, "analytics.duckdb"), color="yellow"),
        profile("Catalog", "mongodb", 27017, database="catalog", color="green"),
        profile("Sessions", "redis", 6379, color="orange"),
        profile("Events", "scylla", 9043, database="events", color="purple"),
        profile("Telemetry", "cassandra", 9042, "cassandra", "telemetry", color="blue"),
        profile("Legacy ERP", "sqlserver", 1433, "sa", "LegacyERP", readonly=True),
        profile("Storefront", "mysql", 3306, "root", "storefront", color="green"),
        profile("Billing", "mariadb", 3307, "root", "billing"),
        profile("Notes", "sqlite", 0, path=os.path.join(files, "notes.sqlite")),
    ]
    passwords = {"Shop": "postgres", "Telemetry": "cassandra", "Legacy ERP": "DatabasePro#2026",
                 "Storefront": "databasepro", "Billing": "databasepro"}
    import base64
    secrets = {f"db.{p['id']}": base64.b64encode(passwords[p['name']].encode()).decode() for p in profiles if p["name"] in passwords}
    with open(os.path.join(data_dir, "connections.json"), "w") as f:
        json.dump(profiles, f, indent=2)
    with open(os.path.join(data_dir, "secrets-dev.json"), "w") as f:
        json.dump(secrets, f)
    print(f"Connections: {data_dir}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--files", required=True)
    parser.add_argument("--data-dir")
    parser.add_argument("--skip-servers", action="store_true")
    args = parser.parse_args()
    files = os.path.abspath(os.path.expanduser(args.files))
    if not args.skip_servers:
        seed_postgres()
        seed_mysql("mysql", "storefront")
        seed_mysql("mariadb", "billing")
        seed_sqlserver()
        seed_mongo()
        seed_redis()
        seed_cql("cassandra", "telemetry", user="cassandra")
        seed_cql("scylla", "events")
    write_files(files)
    if args.data_dir:
        write_connections(os.path.abspath(os.path.expanduser(args.data_dir)), files)


if __name__ == "__main__":
    main()
