# Settings

Settings holds how much the browser loads, the DuckDB download on the Mac, your SSH keys, iCloud, your vault accounts
and your devices. How you open it, and which panes it has, depends on the device.

## On the Mac

Choose **Database ▸ Settings…** (⌘,). The panes are **General**, **SSH Keys**, **Privacy**, **Accounts** and
**Remote**.

<!-- only: linux -->

On Linux, choose **Edit ▸ Preferences…**. The panes are **General**, **SSH Keys**, **Privacy**, **Accounts** and
**Devices**; Linux has no DuckDB card and no Remote pane.

<!-- /only -->

<!-- only: mac -->

### DuckDB

In **General**, the **DuckDB** card downloads DuckDB, updates it when a newer version is available, and removes it
with **Remove**. Database downloads it from GitHub only when you choose **Download**, and shows its size first. Removing it takes
effect after Database restarts. See [Connections](Connections.md#duckdb-on-the-mac).

### Remote

Which of your devices may sign in to this Mac over SSH, for example to reach the databases on this Mac from your
iPhone. It needs Remote Login, which you turn on in System Settings ▸ General ▸ Sharing. Turn on each device under
**Let Your Devices In**. The pane is the same as in [Vault](https://github.com/v57/Vault/blob/main/docs/README.md).

<!-- /only -->

### Updates

Database for the Mac and Linux updates itself from GitHub Releases. Choose **Database ▸ Check for Updates…** on the
Mac, or **Help ▸ Check for Updates…** on Linux, to check now. **Check for Updates Automatically** is off until you
turn it on; then Database checks once a day.

## On iPhone and iPad

Tap **Settings** at the foot of the sidebar. On iPad the panes take the place of the page; on iPhone they slide in
over the sidebar. **Done** closes them. The panes are **General**, **SSH Keys**, **Privacy**, **Accounts** and
**Devices**. There's no DuckDB card and no Remote pane.

Updates come from the App Store.

## On Windows

Database for Windows has no Settings window and no in-app updates. A browser page holds 50 items, or 100 Redis keys.
SSH keys can still be made and imported from the connection sheet (see [SSH](SSH.md#sign-in-with-a-key)), and
**Manage Accounts…** in the account picker shows your accounts.

## General

- **Items per page**: how many rows, documents or keys a page of the browser loads (25, 50, 100, 200 or 500). An open
  browser reloads at the new size.
- The footer reminds you that Production connections always show their changes for review before saving.

## SSH Keys

The keys Database can sign in with, besides this device's own key.

- **Create New Key** makes a key.
- **Import Private Key…** imports an OpenSSH private key file. A key with a passphrase asks for it once.
- **Copy Public Key** copies the line to give the SSH server's administrator, or to add to `~/.ssh/authorized_keys`
  yourself.
- **Delete** removes a key, after asking. Connections that use it can't log in until you choose another.

Keys are stored in your keychain.

## Privacy

**Use iCloud** turns iCloud sync on or off for every v57 app on this device. Turning it off asks first. On Linux the
pane says iCloud is only on Apple devices. See [Accounts and Sync](Accounts-and-Sync.md#icloud).

## Accounts

Your vault's accounts: **New Account…**, and **Edit…** or **Delete…** for each one. Deleting an account deletes its
projects, hosts, passwords and settings on every device; Personal keeps everything. See
[Accounts and Sync](Accounts-and-Sync.md#accounts) and [Vault](https://github.com/v57/Vault/blob/main/docs/README.md).

## Devices

On iPhone, iPad and Linux: your devices that run a v57 app. Touch and hold a device (right-click on Linux) to rename
or remove one you no longer use. It's the same pane as [Vault](https://github.com/v57/Vault/blob/main/docs/README.md)'s
**Settings ▸ Devices**.
