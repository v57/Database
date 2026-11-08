# Privacy and Security

## What Database sends over the network

Database contacts no server on its own. It has no analytics or tracking. It sends something only in these cases:

- **Your databases.** When you open, test, refresh or query a connection, Database connects to that database server,
  or to the SSH server it goes through. Nothing connects at launch.
- **iCloud.** With iCloud on, your vault (connections, SSH configurations, server keys) syncs through iCloud, and
  saved passwords through iCloud Keychain. This goes to Apple, not to v57.
- **Hub.** A location marked **Via Hub** reaches your device through your own Hub.
- **DuckDB (Mac).** Database downloads DuckDB from GitHub only when you choose **Download** or **Update**, and checks
  the file before installing it.
- **Updates (Mac and Linux).** Database asks GitHub for a new version only when you choose **Check for Updates…**, or
  once a day after you turn on **Check for Updates Automatically**. On iPhone and iPad, the App Store handles
  updates.

On iPhone and iPad, the first connection to a device on your local network shows the system's Local Network
question.

## Passwords

- A password is kept only when **Save password in the Keychain** is on. It's kept in your keychain, and synced
  through iCloud Keychain when iCloud is on.
- **Copy Link** copies a connection without its password.
- Deleting a connection deletes its saved password. Deleting an SSH configuration deletes its saved password too.
- On Linux and Windows, secrets are kept in the system's password store, where your other programs can read them, as
  with other password stores there.

## Insecure logins

Some PostgreSQL, MySQL and MariaDB servers ask for the password in a form anyone on the network could read: in plain
text, or with MD5. By default Database refuses to send it that way unless the connection goes through SSH or is
encrypted with TLS. The connection fails and says why.

If you trust the network between you and the server, turn on **Allow insecure login** for that connection in the
connection sheet. It's only offered for connections that don't go through SSH. A better fix is to connect through
SSH, or turn on TLS where the engine has it.

## Encryption

- **Encrypted connection (TLS)** encrypts PostgreSQL, MongoDB, Redis, Cassandra and ScyllaDB connections.
  **Accept self-signed certificates** skips checking who signed the server's certificate; use it only for a server
  you know.
- MySQL, MariaDB and SQL Server aren't encrypted by Database on their own. Connect through SSH to encrypt them end to
  end.
- An SSH connection opens no port on your device. Only Database uses the tunnel.

## SSH server keys

- The first time you connect to an SSH server, Database asks **Trust this server's key?** with its fingerprint,
  before it sends anything. **Trust and Connect** saves the key for every v57 app; **Cancel** stops.
- If a saved server's key changes, Database refuses to log in and sends no password or key. Only clear the old key
  once you know why it changed: **Forget Host Key** on the SSH tile in the connection sheet, or **Forget Key** on the
  host in Vault. The next connection asks you about the new key.
- A fallback address needs its own trusted key; it isn't trusted because the main address is.

See [SSH](SSH.md#the-servers-key).

## This device's key

**This device’s key** lives in the device's Secure Enclave and can't be copied off it. A key made since
November 4, 2026 asks you to confirm with Face ID, Touch ID or your password before it signs in. An older key signs
in without asking.

## Production and Read only

**Production** makes every change in the browser go through a review, and Redis shows the exact commands before it
runs them. **Read only** removes editing from the browser, the inspector, indexes and the Redis tools. In a query tab
on PostgreSQL, MySQL, MariaDB or SQL Server, a statement you write still runs; use a database user that can only read
when you need a guarantee. See [Connections](Connections.md#read-only-and-query-tabs).
