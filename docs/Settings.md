# Settings

On the Mac, choose **Database ▸ Settings…** (⌘,). Linux has the same Settings window. iPhone and iPad have no Settings
screen: you make and import SSH keys in the SSH configuration sheet (see [SSH](SSH.md)), and the iCloud switch is in
another v57 app's Settings.

## General

- **Items per page**: how many rows, documents or keys a page of the browser loads (25, 50, 100, 200 or 500). An open
  browser reloads at the new size.
- **DuckDB**: download DuckDB, update it when a newer version is available, or **Remove** it. Database downloads it
  from GitHub only when you choose **Download**, and shows its size first. Removing it takes effect after Database
  restarts. See [Connections](Connections.md#duckdb-on-the-mac).
- The footer reminds you that Production connections always show their changes for review before saving.

## SSH Keys

The keys Database can sign in with, besides this device's own key.

- **Create New Key** makes a key.
- **Import Private Key…** imports an OpenSSH private key file. A key with a passphrase asks for it once.
- **Copy Public Key** copies the line to give the SSH server's administrator, or to add to `~/.ssh/authorized_keys`
  yourself.
- **Delete Key** removes a key. Connections that use it can't log in until you choose another.

Keys are stored in your keychain.

## Privacy

**Use iCloud** turns iCloud sync on or off for every v57 app on this Mac. See
[Accounts and Sync](Accounts-and-Sync.md#icloud).

## Accounts

Your vault's accounts: **New Account…**, and **Edit…** or **Delete…** for each one. Deleting an account deletes its
hosts, passwords and settings on every device; Personal is always there. See [Accounts and Sync](Accounts-and-Sync.md#accounts) and
[Vault](https://github.com/v57/Vault/blob/main/docs/README.md).

## Remote

Which of your devices may sign in to this Mac over SSH, for example to reach the databases on this Mac from your
iPhone. It needs Remote Login, which you turn on in System Settings ▸ General ▸ Sharing. Turn on each device under
**Let Your Devices In**. The pane is the same as in
[Vault](https://github.com/v57/Vault/blob/main/docs/README.md).

## Updates

Database for the Mac updates itself from GitHub Releases. Choose **Database ▸ Check for Updates…** to check now.
**Check for Updates Automatically** is off until you turn it on; then Database checks once a day. On iPhone and iPad,
updates come from the App Store.
