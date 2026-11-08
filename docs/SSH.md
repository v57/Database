# SSH

Many databases only listen inside their own network. Database can log in to an SSH server there and reach the
database from it. The database connection travels inside the SSH connection: Database opens no port on your device,
so other apps and users can't use the tunnel.

An SSH server you set up is saved in your vault as an SSH configuration. Shell, Vault and the other v57 apps list it
too, and every connection that goes through it uses the same settings.

## Connect through an SSH server

1. In the New Connection sheet, under **Location**, pick the SSH server's tile. If it isn't there, choose **New SSH**
   to add it.
2. In **Server**, enter the database's address as the SSH server sees it. For a database on the SSH server itself,
   that's usually `127.0.0.1`.
3. **Test**, then **Connect**.

## Add an SSH configuration

Choose **New SSH** under **Location**. The **New SSH Configuration** sheet has:

- **Name**: optional; the server's address is used when it's empty.
- **Server**, **Port** and **User**.
- **Sign in with**: **Key** or **Password**.
- **Fallback Addresses**: other addresses of the same server, tried in order when the first doesn't answer. See
  [Fallback addresses](#fallback-addresses).

Choose **Add**. The new tile is selected in the connection sheet.

## Sign in with a key

With **Sign in with** set to **Key**, pick the key in **Key**:

- **This device’s key** lives in this device's Secure Enclave. It can't be copied off the device. Database, Shell and
  the other v57 apps on this device use the same key, so one line in the server's `authorized_keys` serves them all.
  If the key asks for you, a login with it asks for Face ID, Touch ID or your passcode first.
- **Add Key ▸ Create New Key** makes a new key named "Database on" and this device's name, and selects it.
- **Add Key ▸ Import Private Key…** imports an OpenSSH private key file. If the key has a passphrase, Database asks
  for it in **Enter the Key's Passphrase** and keeps the key without it.

**Public key** shows the line to add to `~/.ssh/authorized_keys` on the SSH server. Choose **Copy** and add it there.

To let your iPhone or iPad sign in to your Mac with this device's key, use the Mac's **Settings ▸ Remote** in
Database or [Vault](https://github.com/v57/Vault/blob/main/docs/README.md).

## Sign in with a password

With **Sign in with** set to **Password**, type the password. **Save password in the Keychain** keeps it, synced to
your other devices when iCloud is on.

## Edit, copy or delete an SSH configuration

In the connection sheet, use the SSH tile's **…** button, or touch and hold it (right-click on the Mac):

- **Edit…** opens **Edit SSH Configuration**. Every connection through it uses the change. Once you've trusted the
  server, the sheet shows its **Remembered host key**.
- **Copy Public Key** copies the public key line, for a configuration that signs in with a key.
- **Forget Host Key** drops the server's saved key for every app. The next connection asks you about its key again.
  It shows for the selected tile once a key is saved.
- **Delete…** removes the configuration, and its saved password. Shell and the other v57 apps won't list it anymore.
  It's disabled while another connection uses it.

A connection with SSH settings that match no saved configuration shows an **SSH server · Not saved** tile. Choose
it, or **Save as Configuration…** in its menu, to save it.

## Fallback addresses

Under **Fallback Addresses**, choose **Add Address** to add another address of the same server, for example its
address on your local network. Database tries the addresses in order when one doesn't answer. **Remove** takes one
away. An address can't have spaces, and the same one can't be listed twice.

For your own devices, **Automatic** rows list addresses Database knows on its own: the device's Bonjour name on the
same network, or its Hub Network address. You don't edit these.

## The server's key

The first time Database logs in to an SSH server, it asks **Trust this server's key?** and shows the key's
fingerprint. Nothing has been sent to the server yet.

- **Trust and Connect** saves the key in your vault and connects. Every v57 app trusts it from then on.
- **Cancel** ends the login.

Trust a key only if you know it's the server's. Anyone on the network could be answering in its place.

If a server's key later changes, Database refuses to log in and sends no password or key. Find out why the key
changed. If the change is expected, use **Forget Host Key** on the tile, or **Forget Key** on the host in Vault, then
connect again to be asked about the new key.

A fallback address isn't trusted on the main address's word: it needs its own saved key.

## Via Hub

If you use [Hub](https://github.com/v57/hub-app/blob/main/docs/README.md), your devices that it knows show under
**Location** as tiles marked **Via Hub** with their address. Pick one to reach a database on that device.

## When the tunnel drops

If the SSH connection closes, the connection's page says so, for example "The SSH tunnel closed.", with
**Try Again**.
