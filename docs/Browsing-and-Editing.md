# Browsing and Editing

Pick a table, view or collection in the sidebar to browse it. You can search, filter, sort and pick fields without
writing a query. Changes you make wait in a list until you review and save them.

## How items show

- **On the Mac and iPad**, a table shows as a grid with a column per field. Key fields carry a key glyph, numbers are
  right-aligned, and NULL shows quietly. Click or tap a column's header to sort by it.
- **On iPhone**, a table shows as a list, one row per item. Pull down to refresh, and choose **Load More** at the
  bottom. Tap an item to open it on its own page.

**Show As** in the toolbar switches how items show: **Table** or **JSON** for SQL tables, and **Table**, **Cards** or
**JSON** for MongoDB collections, which open in Cards. Cards show a title, a few fields and chips for arrays and
sub-documents. JSON shows each item as Extended JSON. On iPhone the list is used whatever you pick.

**Find** and **Aggregate** switch between browsing and the pipeline builder. See [Pipelines](Pipelines.md). Redis,
Cassandra and ScyllaDB don't have Aggregate.

When the toolbar is narrow, its tools move into the **…** menu: **Show As**, **Mode**, **Query Editor**, **Refresh**
and the rest.

## Search

Type in **Search** (it names the table) to find items. Results come after a short pause, and Return searches at once.
The search scope menu searches **Any column** (**Any field** for MongoDB) or one field you pick.

## Filters

1. Choose **Add Filter**. On iPhone it's an icon button.
2. Pick the **Field**, then the **Condition**. Conditions are in words that fit the field's type, such as dates "in
   the last" number of **Days**.
3. Enter the **Value**. Booleans offer true and false.

The filter shows as a token in the bar and the list reloads. Tap a token's × to remove it. When nothing matches,
**Clear Filters** removes the filters and the search.

On Cassandra and ScyllaDB, a filter on a field that isn't the partition key warns that it reads the whole table
unless the partition key is filtered too.

## Sort and fields

- **Sort** ▸ a field ▸ **A to Z** or **Z to A** (**Oldest First** and **Newest First** for dates, **Lowest First**
  and **Highest First** for numbers). **Don't Sort** removes it.
- **Fields** lets you turn fields off. A hidden field isn't fetched at all. **Show All Fields** brings them back.

Redis, Cassandra and ScyllaDB don't have Sort. Redis doesn't have Fields.

## Pages

The status bar shows which items you're looking at and how long the page took. **Previous Page** and **Next Page**
move through them. A page holds 50 items, or 100 keys in Redis.

The status bar also notes **Production**, **Read only**, or **View: read only** for a database view, which can't be
changed. **Refresh** loads the items again from the first page.

## The inspector

Select an item to see all its fields.

- On the Mac and iPad the inspector sits beside the grid. Where there isn't room, it floats over the grid. On the Mac,
  toggle it with **Data ▸ Show Inspector** (⌥⌘I). On iPad, use **Show Inspector** or **Hide Inspector** in the
  toolbar, or ⌥⌘I with a keyboard.
- On iPhone, the item's own page is its inspector.

The inspector shows each field with its value. Keys are marked **Key**, and Cassandra's **Partition key** and
**Clustering**. Touch and hold a value to copy it.

- A field that refers to another table, like an order's customer, shows a link. Tap it to open that table filtered to
  the item it points to.
- **Related** lists tables that refer to this item, with how many rows. Tap one to open it filtered to them.
- **Copy as JSON** and **Copy as INSERT** copy the item.

A MongoDB document shows as an outline of typed fields. Open sub-documents and arrays to see inside them.

## Select several items

On the Mac and iPad, select several rows (Shift-click or ⌘-click). The inspector offers **Copy as JSON** and Delete
for all of them. The row menu (right-click, or touch and hold on iPad) has **Copy as JSON**, **Copy as INSERT**,
**Filter by Value** and Delete.

## Edit an item

1. In the inspector, choose **Edit**.
2. Change the values. Each field gets an editor for its type: true and false for booleans, several lines for JSON and
   long text. **Empty** stores NULL. Key fields can't be changed.
3. Choose **Done**. The item is marked as edited and the change joins the list of changes.

On the Mac and iPad you can also edit a cell in the grid: double-click or double-tap it (or press Return with a
keyboard) and type. The cell turns orange while its change waits.

A table without a primary key can't be changed here, and the inspector says so.

### Edit a MongoDB document

**Edit** shows each field with a **Type** (String, Int32, Date, ObjectId, Null, Object, Array and others). Use
**Add Field** to add one and − to remove one. `_id` can't be changed. A new field needs a name.

## Add an item

Choose **Add Row** (**Add Document** for MongoDB) in the toolbar. Fill in the fields, or for MongoDB write the
document in MongoDB Shell syntax; Database adds an `_id` if it has none. Choose **Add to Changes**.

## Delete items

Choose Delete in the inspector, the row menu or the item's page. Database asks, then **Add to Changes** marks the
items as deleted. Nothing is deleted until you save.

## Review and save

Changes wait under the grid in a **Changes** card that says nothing is saved until you review. Each change shows old →
new, with **Undo** to drop it. **Discard All** drops them all.

1. Choose **Review and Save** on the card, **Review Changes** in the toolbar, or **Data ▸ Review Changes…** (⌘S).
2. The review lists every change and, under **SQL that will run**, the exact statements. The engine's language
   is named for MongoDB and Cassandra.
3. Choose **Save** with the number of changes, **Keep Editing**, or **Discard All**.

On SQL databases, several changes are saved together, or none are. On Cassandra and ScyllaDB they're saved as one
batch. MongoDB without a replica set saves documents one at a time: if one fails, the ones before it stay saved and
can be undone.

## Undo a save

After a save, a message says what was saved, with **Undo** for 8 seconds. **Edit ▸ Undo Last Save** (⇧⌥⌘Z) does the
same afterwards.

## Production and Read only

- On a **Production** connection, every change goes through the review, and the review names the connection as
  Production.
- On a **Read only** connection there's no Edit, Add or Delete, and the review can't save.

See [Connections](Connections.md#name-and-safety).

## The Query Editor strip

Choose **Show Query Editor** (the `</>` button, or ⇧⌘E). A strip shows the query the search, filters and sort make:
SQL, MongoDB Shell for MongoDB, or CQL for Cassandra.

- Edit it to go further. The strip says **Edited query** and its results replace the list below.
- **Run** (⌘↩) runs it. **Reset** goes back to the bar's query.

## Indexes

With the Query Editor strip shown, **Indexes** in the toolbar lists a table's indexes on PostgreSQL, MySQL, MariaDB,
SQLite and MongoDB: their fields and directions, and **Unique** and **Required** chips. A table with no indexes says
every search reads it whole.

- **Add Index**: pick a **Field** (and **Then by** fields), **Ascending** or **Descending**, a **Name**, and
  **Unique** if no two items may share the values. Choose **Add to Changes**.
- **Drop** marks an index **Will be dropped**; **Keep** takes that back. Required indexes, like a primary key or
  `_id`, can't be dropped.
- The statements show under **SQL that will run**. Choose **Apply Change** (or **Apply** with the number of changes).

After applying, **Undo** puts things back: a dropped index is made again as it was, and a new one is dropped.

On a Read only connection you can look at indexes but not change them.

## When something goes wrong

- An empty table says so. A search with no results shows **No Matches** with **Clear Filters**.
- If a page can't load, Database says why, with **Try Again**. An error over a page that loaded shows as a red
  banner you can close.
