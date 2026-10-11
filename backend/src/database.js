import pg from "pg";

const { Pool } = pg;
let pool;

export function databasePool() {
  if (!pool) {
    const connectionString = process.env.DATABASE_URL;
    if (!connectionString) {
      throw new Error("DATABASE_URL must be set.");
    }

    pool = new Pool({ connectionString });
  }

  return pool;
}

export function query(text, values = []) {
  return databasePool().query(text, values);
}

export async function closeDatabase() {
  if (pool) {
    await pool.end();
    pool = undefined;
  }
}
