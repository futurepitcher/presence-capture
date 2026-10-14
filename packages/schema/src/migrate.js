import { readFileSync, readdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const MIGRATIONS_DIR = join(dirname(fileURLToPath(import.meta.url)), '..', 'migrations');

/**
 * Apply every unapplied migration, in filename order, inside one transaction
 * each. The lineage starts at 001 and is this package's own — an adopter never
 * inherits another project's migration history.
 *
 * @param {import('node:sqlite').DatabaseSync} db
 * @returns {string[]} names of migrations applied by this call
 */
export function migrate(db) {
  db.exec(`
    CREATE TABLE IF NOT EXISTS schema_migration (
      name       TEXT PRIMARY KEY,
      applied_at TEXT NOT NULL
    );
  `);

  const applied = () => new Set(
    db.prepare('SELECT name FROM schema_migration').all().map((r) => r.name),
  );

  const pending = readdirSync(MIGRATIONS_DIR)
    .filter((f) => f.endsWith('.sql'))
    .sort()
    .filter((f) => !applied().has(f));

  // Each under the write lock, and checked again inside it: two writers
  // opening an older store at once can't both apply the same migration.
  const ran = [];
  for (const name of pending) {
    db.exec('BEGIN IMMEDIATE');
    try {
      if (!applied().has(name)) {
        db.exec(readFileSync(join(MIGRATIONS_DIR, name), 'utf8'));
        db.prepare('INSERT INTO schema_migration (name, applied_at) VALUES (?, ?)')
          .run(name, new Date().toISOString());
        ran.push(name);
      }
      db.exec('COMMIT');
    } catch (err) {
      db.exec('ROLLBACK');
      throw new Error(`migration ${name} failed: ${err.message}`, { cause: err });
    }
  }

  return ran;
}
