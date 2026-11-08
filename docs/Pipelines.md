# Pipelines

A pipeline answers a question in steps: keep the documents that match, group them, count them, sort the result.
Each step works on what the step above passes down, and you see the output after every step as you build it.

Pipelines are MongoDB's aggregation pipelines. On a SQL table, the same builder makes one SELECT statement.

## Start a pipeline

1. Open a collection or table.
2. Switch the toolbar from **Find** to **Aggregate**.

The **Pipeline** starts with a **Filter** step. The output panel shows what reaches the selected step, for example
"After step 1 · Filter", with the number of documents and the first ones.

## Add and edit steps

Choose **Add Step**. It lists the common steps, each with a line on what it does:

| Step | What it does |
|---|---|
| **Filter** | Keep only matching documents |
| **Group** | Combine and count, sum, average |
| **Sort** | Put documents in order |
| **Limit** | Keep the first few |
| **Pick Fields** | Show, hide or rename fields |
| **Add Fields** | Compute new fields |
| **Join** | Bring in documents from another collection |
| **Unwind** | One document per array item |

**More Steps** has the rest, such as **Skip**, **Count**, **Buckets**, **Auto Buckets**, **Count by Value**,
**Random Sample**, **Follow Links**, **Append Collection**, **Branches**, **Window Fields**, **Fill Gaps**,
**Fill Missing**, **Nearest First**, **Remove Fields**, **Replace Document**, **Save to Collection** and
**Merge Into**.

Each step has a form for its settings: conditions for Filter (**Add Condition**), the fields to group by and what to
compute for Group, and formulas for Add Fields. The output updates as you edit.

## Step actions

Each step's **…** menu has **Run Through This Step** (shows the results up to that step; later steps don't run),
**Move Up**, **Move Down**, **Duplicate** and **Delete Step**. A step's switch turns it off without deleting it; an
off step is drawn dashed.

## All Steps

On MongoDB, turn on **All Steps** for the full builder:

- a library of every step, in groups you can search; tap one to add it after the selected step, or drag it in;
- a step inspector that shows the fields reaching the step and how often they're filled, and its output;
- **Pipeline settings**: **Big sorts use disk**, **Time limit**, **Text comparison language**, **Ignore case** and
  **Tag in server logs**.

## Run the pipeline

Choose **Run** (⌘↩) to run the whole pipeline. The results show as **Pipeline results** with the number of
documents, up to 1,000. **Back to Step Output** returns to the step view.

The output panel's **Code** view shows the pipeline as JavaScript for MongoDB, or as SQL for a table.

## Import and export

- **Import…** opens **Import Pipeline**. Paste `db.collection.aggregate([…])`, a JSON array of stages, or stages
  separated by commas. Database builds the steps from it.
- **Export ▸ Copy as JavaScript** or **Copy as JSON** copies a MongoDB pipeline. **Export ▸ Copy SQL** copies a SQL
  table's query.

## Write the results

**Save to Collection** replaces a collection with the results. **Merge Into** merges the results into a collection.
Both start off: "Off while you try
things out. Turn it on to write the results." Turn the step on and choose **Run** to write.

## Pipelines on SQL tables

On a SQL table, Aggregate offers the steps a SELECT can do: **Filter**, **Group**, **Sort**, **Limit**, **Skip**,
**Pick Fields** and **Count**. The pipeline becomes one SELECT, shown under **Code**, and the output is a table.
