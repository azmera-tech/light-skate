import { startWorker } from './worker/index.js';
import { closePool } from './db.js';

// Standalone worker process (optional: the API can also embed the worker via EMBEDDED_WORKER=true).
const stop = startWorker();
const shutdown = async () => { stop(); await closePool(); process.exit(0); };
process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);
