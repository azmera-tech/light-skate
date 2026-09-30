import pg from 'pg';

export default async function setup() {
  process.env.DATABASE_URL = 'postgres://lightskate:lightskate@localhost:5432/lightskate_test';
  const c = new pg.Client({ connectionString: process.env.DATABASE_URL });
  await c.connect();
  await c.query('DROP SCHEMA public CASCADE; CREATE SCHEMA public;');
  await c.end();
  const { migrate } = await import('../src/migrate.js');
  const { closePool } = await import('../src/db.js');
  await migrate(() => {});
  await closePool();
}
