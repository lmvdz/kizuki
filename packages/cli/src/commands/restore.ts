import { chmodSync, existsSync, readFileSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import type { Database } from "bun:sqlite";
import { listConnections, restoreVault, verifyBackup } from "@kizuki/core";
import { UsageError, parseArguments } from "../args";
import { connectionStateIsCredentialFree, decodeHostState } from "../connections";
import { openVaultDb } from "../context";
import { tryRefreshDerived } from "../derived";
import type { CliIo, Command } from "./index";

/**
 * The counterpart to `exportCredentialFreeConnectionState`: only a
 * connection export judged credential-free ever had its state copied into
 * the backup, so only those connections can come back usable. Anything
 * else keeps reporting `state=missing` exactly as it did before this fix —
 * re-enrollment, not a silently trusted credential, is what a sign-in
 * connection gets back.
 *
 * The decision is re-derived here from the just-restored `connections`
 * row and the raw bytes actually sitting in the backup directory —
 * decoded fresh with `decodeHostState`, never trusted from anything the
 * backup merely claims about itself. A row a tampered backup relabeled
 * `kizuki.ics` still only comes back if the bytes next to it decode to a
 * bare local path; the connector's own `sign_in` shape does not decode
 * that way, so a copied session credential is never restored no matter
 * what the surrounding rows say.
 */
function restoreCredentialFreeConnectionState(
  db: Database,
  backupDir: string,
  into: string,
): number {
  let restored = 0;
  for (const connection of listConnections(db, { includeDisconnected: true })) {
    const ref = connection.secret_refs[0];
    if (connection.secret_refs.length !== 1 || ref === undefined) continue;
    if (!ref.startsWith("file:connections/") || !ref.endsWith(".state")) continue;
    const relative = ref.slice("file:".length);
    const from = join(backupDir, relative);
    if (!existsSync(from)) continue;
    const bytes = readFileSync(from);
    let state;
    try {
      state = decodeHostState(bytes, connection.connector_id);
    } catch {
      continue;
    }
    if (!connectionStateIsCredentialFree(connection.connector_id, state)) continue;
    const to = join(into, ".kizuki", relative);
    writeFileSync(to, bytes, { mode: 0o600 });
    chmodSync(to, 0o600);
    restored += 1;
  }
  return restored;
}

export const restoreCommand: Command = {
  name: "restore",
  usage: "restore --from DIR [--into DIR] [--verify]",
  summary: "verify a backup and restore it into an empty directory",
  async run(io: CliIo, args: string[]): Promise<number> {
    const parsed = parseArguments(args, {
      options: ["--from", "--into"],
      flags: ["--verify"],
    });
    if (parsed.positionals.length !== 0) throw new UsageError(this.usage);
    const from = parsed.options.get("--from");
    if (from === undefined) throw new UsageError(this.usage);
    const backupDir = resolve(from);
    const into = parsed.options.get("--into");
    if (into === undefined) {
      const manifest = verifyBackup(backupDir);
      io.out(`verified=${backupDir}/manifest.json`);
      io.out(`schema=${manifest.schema} complete=${manifest.complete}`);
      if (manifest.schema_versions.serve < 8) {
        io.out("warning=backup predates durable extraction recovery; an interrupted model decision was not preserved");
      }
      return 0;
    }
    const target = resolve(into);
    const report = restoreVault(backupDir, target);
    io.out(`vault=${target}`);
    io.out(
      [
        `events=${report.events}`,
        `claims=${report.claims}`,
        `receipts=${report.receipts}`,
        `vault_files=${report.vault_files}`,
        `doctor_valid=${report.doctor.valid}`,
        `doctor_invalid=${report.doctor.invalid}`,
      ].join(" "),
    );
    for (const warning of report.recovery_warnings) io.out(`warning=${warning}`);
    const db = openVaultDb(target);
    try {
      const connectionState = restoreCredentialFreeConnectionState(db, backupDir, target);
      io.out(`connection_state=${connectionState}`);
      const derived = tryRefreshDerived(db, target);
      for (const warning of derived.degraded) io.err(`degraded: ${warning}`);
    } finally {
      db.close();
    }
    return 0;
  },
};
