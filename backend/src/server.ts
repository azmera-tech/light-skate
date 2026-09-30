import { buildApp } from './app.js';
import { config } from './config.js';
import { closePool } from './db.js';

const { app, close } = await buildApp({ runMigrations: true });
await app.listen({ port: config.port, host: config.host });

let shuttingDown = false;
async function shutdown(sig: string) {
  if (shuttingDown) return;
  shuttingDown = true;
  app.log.info(`${sig} received, shutting down`);
  await close();
  await closePool();
  process.exit(0);
}
process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
