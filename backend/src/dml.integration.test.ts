//! Integration test for the generated DML builders: runs them against the
//! docker-compose Postgres (schema applied by `zig build create-database`).
//! Unlike dml.test.ts (pure, node-only), this one needs the live database -
//! here the database is the oracle. Run with `zig build ts-backend-db`.

import { test } from "node:test";
import assert from "node:assert/strict";
import pg from "pg";

import { insertPeriodos, selectPeriodosByPk, deletePeriodos } from "./dml.ts";

const connectionString =
  process.env.DATABASE_URL ?? "postgres://aida:aida@localhost:5432/aida";

test("periodos: insert then selectByPk round-trips through Postgres", async () => {
  const pool = new pg.Pool({ connectionString });
  const periodo = `it-${Date.now()}`;
  try {
    const ins = insertPeriodos({ periodo });
    await pool.query(ins.text, ins.values);

    const sel = selectPeriodosByPk({ periodo });
    const { rows } = await pool.query(sel.text, sel.values);

    assert.equal(rows.length, 1);
    assert.equal(rows[0].periodo, periodo);
  } finally {
    const del = deletePeriodos({ periodo });
    await pool.query(del.text, del.values);
    await pool.end();
  }
});
