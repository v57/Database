# Redis

A Redis connection opens a key browser instead of a table. You find keys, see and change their values, set when they
expire, and run Redis commands.

## Open a Redis database

Open the connection. The sidebar lists the server's databases, Database 0 to 15, with their key groups. Pick a
database to open its keys.

## Browse keys

- **On the Mac and iPad**, keys show as an outline grouped by the ":" in their names. A group such as `session:` shows
  how many keys it holds; open it to see them. The columns are **Key**, **Type**, **Holds**, **Size** and **Expires**.
- **On iPhone**, keys show as a list. Each row has the key's name, what it holds, its size and expiry, and a type chip.
  Tap a key to open its value.

Narrow the list:

- The type control at the top: **All**, **String**, **Hash**, **List**, **Set**, **Sorted Set**, **Stream** or
  **JSON**.
- **Find keys, like cart:\*** matches key names with a pattern.

Keys load 100 at a time. Use the page buttons in the status bar, or **Load More** on iPhone.

## See a value

Select a key. On the Mac and iPad its value shows in the inspector beside the list, or over it where there isn't
room; **Show Inspector** and **Hide Inspector** toggle it on iPad. On iPhone the key opens on its own page.

The value page shows the key, its type, its size, when it expires, an editor for the value, and the Redis command
that reads it, such as `GET` or `HGETALL`.

## Change a value

| Type | What you can do |
|---|---|
| String and JSON | Edit the text, then **Save** or **Revert** |
| Hash | Touch and hold a field (right-click on the Mac): **Edit Value**, delete it, **Copy Value**. **Add** a field |
| List | Touch and hold an item: **Edit**, **Remove**. **Add to Start** or **Add to End** |
| Set | Remove a member with −. **Add Member** |
| Sorted set | Touch and hold a member: **Change Score**, **Remove**. **Add Member** with a score |
| Stream | **Delete Entry**. **Add Entry** with a field and value |

After a change, a message says what changed, with **Undo**.

## Expiry

A key that never expires shows **Never expires**. Choose **Set Expiry…**, enter an amount and a unit (seconds,
minutes, hours or days), and Redis removes the key then. A key with an expiry shows how long it has left. **Change…**
changes it, and **Never Expire** removes the expiry.

## Rename or delete a key

- **Rename Key…** asks for the new name.
- **Delete Key…** asks first, and you can undo right after.
- In the key list, touch and hold one or more keys (right-click on the Mac) for **Copy Key Name** and **Delete Key**.

## Add a key

Choose **Add Key**. Enter the **Key name**, pick the **Type** (String, Hash, List, Set, Sorted Set, Stream or JSON)
and fill in its first value. Choose **Add**. The new key is selected.

## Production connections

On a Production connection, Database shows **Run these commands?** with the exact Redis commands before it changes
anything. Choose **Run** to go ahead, or **Cancel**.

## The command line

Choose **Show Command Line** in the toolbar. Type a command, such as `ZREVRANGE leaderboard 0 9 WITHSCORES`, and run
it. The reply shows below with your earlier commands, and errors show as "(error) …". The key list reloads after a
command.

## Read only

On a Read only connection there's no Add Key, Rename, Delete or Set Expiry, and a write in the command line is
refused.
