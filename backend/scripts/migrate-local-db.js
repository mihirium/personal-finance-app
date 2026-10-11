import "dotenv/config";

import { readdir, readFile } from "node:fs/promises";

import { closeDatabase, databasePool } from "../src/database.js";

export async function migrateLocalDatabase() {
  const migrationsURL = new URL("../migrations/", import.meta.url);
  const migrationFiles = (await readdir(migrationsURL))
    .filter((file) => file.endsWith(".sql"))
    .sort();

  for (const migrationFile of migrationFiles) {
    const migration = await readFile(new URL(migrationFile, migrationsURL), "utf8");
    await databasePool().query(migration);
  }
}

if (process.argv[1] === new URL(import.meta.url).pathname) {
  try {
    await migrateLocalDatabase();
    console.log("Local database schema is up to date.");
  } finally {
    await closeDatabase();
  }
}
