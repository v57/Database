# Accounts and Sync

Database keeps its connections in your vault, the store every v57 app shares. That's how a connection you add on the
Mac shows on your iPhone, and how Shell lists the same connections.

## What's shared

- **Connections**: name, engine, server, color, Production and Read only, and their order.
- **SSH configurations**: every SSH server, whichever v57 app added it.
- **Passwords**: kept in your keychain when **Save password in the Keychain** is on.
- **Server keys**: once you trust an SSH server's key, every v57 app trusts it.
- **This device's key**: Database and the other v57 apps on one device sign in with the same key.

Saved queries and the DuckDB download stay on the device.

## iCloud

With iCloud on, your vault syncs through iCloud and your passwords through iCloud Keychain. A connection you add,
edit or delete on one device follows on your others.

The **Use iCloud** switch is one switch for every v57 app on the device:

- On the Mac, it's in Database's **Settings ▸ Privacy**.
- On iPhone and iPad, Database has no Settings screen. Use another v57 app's Settings, such as
  [Vault](https://github.com/v57/Vault/blob/main/docs/README.md)'s **Settings ▸ Privacy**.

Turning it off stops syncing for every v57 app on the device. What's already in iCloud stays, and your other devices
keep it.

## Accounts

Your vault can hold more than one account, for example one for work. You make accounts in
[Vault](https://github.com/v57/Vault/blob/main/docs/README.md), or with **New Account…** in the account picker.

With more than one account, the sidebar starts with the account picker. Pick an account to see its connections. Each
window keeps its own account, also after you quit and reopen Database.

On the Mac, the picker also has **Manage Accounts…** (opens **Settings ▸ Accounts**) and **Open in a New Window**.

## Other v57 apps

- [Shell](https://github.com/v57/Shell/blob/main/Docs/README.md) lists your database connections in its sidebar and
  opens them with the same browser, queries and tools as Database. An SSH host you add in Shell is a location in
  Database's connection sheet.
- [Vault](https://github.com/v57/Vault/blob/main/docs/README.md) shows the connections, SSH hosts and the server keys
  you've trusted. Its host inspector can forget a server's key.
- [Hub](https://github.com/v57/hub-app/blob/main/docs/README.md): your Hub devices are locations in the connection
  sheet, marked **Via Hub**.
- To reach the databases on your Mac from your iPhone or iPad, turn on Remote Login on the Mac and let your devices in
  under **Settings ▸ Remote** on the Mac. Then add the Mac as an SSH configuration on the iPhone or iPad, signing in
  with **This device’s key**, and use `127.0.0.1` as the database's host.
