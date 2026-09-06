import { afterEach, describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { openLedger } from "../../src/ledger/db";
import { initVault } from "../../src/vault/init";
import { inspectServeDoctor } from "../../src/serve/doctor";
import { persistRunReceipt } from "../../src/serve/receipts";
import { writeServeIntent } from "../../src/serve/intent";
import { emptyRunTotals, type SupervisorStatus } from "../../src/serve/types";
import type { SupervisorHost } from "../../src/serve/supervisor";

const dirs: string[] = [];

function vault() {
  const directory = mkdtempSync(join(tmpdir(), "kizuki-serve-doctor-"));
  dirs.push(directory);
  const path = join(directory, "vault");
  initVault(path);
  const db = openLedger(join(path, ".kizuki", "kizuki.db"));
  return { path, db };
}

function host(status: SupervisorStatus): SupervisorHost {
  return {
    kind: status.kind,
    home: "/tmp",
    execStart: "kizuki serve",
    query: () => status,
    reload: () => ({ ok: true, detail: "ok" }),
    enable: () => ({ ok: true, detail: "ok" }),
    disable: () => ({ ok: true, detail: "ok" }),
  };
}

function receipt(day: string, overrides: Partial<ReturnType<typeof emptyRunTotals>> & { rail?: string; run_id: string }) {
  return {
    ...emptyRunTotals(),
    rail: overrides.rail ?? "sync",
    started_at: `${day}T00:00:00Z`,
    finished_at: `${day}T00:00:01Z`,
    status: "ok" as const,
    stopped: null,
    ...overrides,
  };
}

afterEach(() => {
  for (const directory of dirs.splice(0)) rmSync(directory, { recursive: true, force: true });
});

test("doctor names legacy identity authority as unavailable", () => {
  const { path, db } = vault();
  expect(inspectServeDoctor(db, path).stores.degraded).toContain(
    "identity-authority-unavailable",
  );
  db.close();
});

describe("serve doctor", () => {
  test("malformed service intent is unknown and cannot hide an active service", () => {
    const { path, db } = vault();
    try {
      writeFileSync(join(path, ".kizuki", "serve-intent"), "invalid-private-value\n", {mode: 0o600});
      const report = inspectServeDoctor(db, path, {supervisor: host({kind: "systemd", state: "active", enabled: true, unit: "synthetic", detail: "active"})});
      expect(report.ok).toBe(false);
      expect(report.intent).toBe("unknown");
      expect(report.failures).toContain("service intent unavailable or invalid");
      expect(JSON.stringify(report)).not.toContain("invalid-private-value");
    } finally { db.close(); }
  });
  test("an expected installed supervisor cannot be unknown, stopped, or unenabled", () => {
    const { path, db } = vault();
    try {
      writeServeIntent(path, "installed");
      for (const state of ["unknown", "disabled", "none", "active"] as const) {
        const report = inspectServeDoctor(db, path, { supervisor: host({ kind: "systemd", state, unit: "synthetic", enabled: false, detail: state }) });
        expect(report.ok).toBe(false);
      }
    } finally { db.close(); }
  });
  test("a masked or absent unit for an enabled vault is a failure", () => {
    const { path, db } = vault();
    writeServeIntent(path, "installed");
    const masked = inspectServeDoctor(db, path, {
      supervisor: host({
        kind: "systemd",
        state: "masked",
        unit: "kizuki@x.service",
        enabled: false,
        detail: "masked",
      }),
    });
    expect(masked.ok).toBe(false);
    expect(masked.failures.some((item) => item.includes("masked"))).toBe(true);

    const absent = inspectServeDoctor(db, path, {
      supervisor: host({
        kind: "systemd",
        state: "absent",
        unit: "kizuki@x.service",
        enabled: false,
        detail: "absent",
      }),
    });
    expect(absent.ok).toBe(false);
    expect(absent.failures.some((item) => item.includes("absent"))).toBe(true);
    db.close();
  });

  test("a deliberately disabled service is reported without failing", () => {
    const { path, db } = vault();
    writeServeIntent(path, "opted-out");
    const report = inspectServeDoctor(db, path, {
      supervisor: host({
        kind: "systemd",
        state: "disabled",
        unit: "kizuki@x.service",
        enabled: false,
        detail: "disabled by owner",
      }),
    });
    expect(report.supervisor.detail).toBe("disabled by owner");
    expect(report.failures.some((item) => item.includes("supervisor"))).toBe(false);
    expect(report.ok).toBe(true);
    db.close();
  });

  test("a rail with five empty runs in a row is reported down", () => {
    const { path, db } = vault();
    writeServeIntent(path, "installed");
    for (let index = 1; index <= 5; index += 1) {
      persistRunReceipt(
        db,
        path,
        receipt(`2026-09-0${index}`, {
          run_id: `01JBEMPTY0000000000000000${index}`,
          rail: "sync",
        }),
      );
    }
    const report = inspectServeDoctor(db, path, {
      now: "2026-09-03T00:10:00Z",
      supervisor: host({
        kind: "systemd",
        state: "active",
        unit: "kizuki@x.service",
        enabled: true,
        detail: "active",
      }),
    });
    const sync = report.rails.find((rail) => rail.rail === "sync");
    expect(sync?.status).toBe("down");
    expect(sync?.reason).toContain("empty streak");
    expect(report.ok).toBe(false);
    db.close();
  });

  test("doctor reports canon writing off with no model configured", () => {
    const { path, db } = vault();
    writeServeIntent(path, "opted-out");
    const report = inspectServeDoctor(db, path);
    expect(report.model.canon_writing).toBe("off");
    expect(report.model.detail).toContain("no model configured");
    expect(report.model.detail).toContain("connectors, ledger, search, timeline and undo still work");
    expect(report.stores.derived.search.rebuilt_at).toBeNull();
    expect(report.stores.derived.graph.doc_count).toBe(0);
    expect(report.stores.writers).toEqual({
      loop: 0,
      correction: 0,
      import: 0,
      revert: 0,
    });
    expect(report.stores.origin).toEqual({ machine: 0, human: 0 });
    expect(report.calibration.failures).toEqual([]);
    db.close();
  });

  test("seven days of receipts feed calibration", () => {
    const { path, db } = vault();
    writeServeIntent(path, "opted-out");
    for (let day = 1; day <= 7; day += 1) {
      persistRunReceipt(
        db,
        path,
        receipt(`2026-08-2${day}`, {
          run_id: `01JBCALIB0000000000000000${day}`,
          claims_extracted: 10,
          claims_written: 4,
          claims_deduped: 3,
        }),
      );
    }
    const report = inspectServeDoctor(db, path, { now: "2026-08-28T00:00:00Z" });
    expect(report.calibration.write_rate).toBeCloseTo(0.4);
    expect(report.calibration.dedup_rate).toBeCloseTo(0.3);
    expect(report.calibration.failures).toEqual([]);
    db.close();
  });

  // #473: a fresh vault has nothing to dedup against and every single-source
  // claim sits at SINGLE_SOURCE_CAP by construction. Both calibration checks
  // must recognize that as immaturity, not miscalibration, while still
  // catching a model that is actually broken once the vault has seen a
  // repeated fact.
  describe("#473 calibration maturity", () => {
    function insertClaim(
      db: ReturnType<typeof vault>["db"],
      opts: {
        claim_id: string;
        claim_key: string;
        confidence: number;
        corroboration: number;
        asserted_at: string;
      },
    ) {
      db.query(
        `INSERT INTO claims
           (claim_id, kind, target, body, frontmatter, provenance, subjects,
            producer, confidence, status, created_at, body_hash,
            subject, predicate, object, polarity, claim_key, authority,
            sensitivity, taint, model_ref, valid_from, valid_to, asserted_at,
            retracted_at, superseded_by, receipt_id, corroboration, last_confirmed_at)
         VALUES (?, 'fact', NULL, ?, '{}', '[]', '[]', 'model', ?, 'live', ?, ?,
                 ?, 'predicate', 'object', 'positive', ?, 'model_inference',
                 NULL, 'quoted', NULL, '', NULL, ?, NULL, NULL, NULL, ?, NULL)`,
      ).run(
        opts.claim_id,
        `body ${opts.claim_id}`,
        opts.confidence,
        opts.asserted_at,
        `bh-${opts.claim_id}`,
        opts.claim_key,
        opts.claim_key,
        opts.asserted_at,
        opts.corroboration,
      );
    }

    test("a healthy fresh vault — every claim single-source-capped, nothing to dedup against — reports ok", () => {
      const { path, db } = vault();
      writeServeIntent(path, "opted-out");
      // 12 events in, 12 claims extracted, all 12 written (write_rate 1.0,
      // dedup_rate 0): exactly the shape from the issue.
      persistRunReceipt(
        db,
        path,
        receipt("2026-09-01", {
          run_id: "01JBFRESH00000000000000001",
          claims_extracted: 12,
          claims_written: 12,
          claims_deduped: 0,
        }),
      );
      for (let index = 1; index <= 12; index += 1) {
        insertClaim(db, {
          claim_id: `01JBFRESHCLAIM${String(index).padStart(4, "0")}`,
          claim_key: `key-${index}`, // every claim about a distinct fact
          confidence: 0.5, // SINGLE_SOURCE_CAP: forced, not chosen
          corroboration: 1, // never re-observed: no dedup opportunity yet
          asserted_at: "2026-09-01T00:00:01Z",
        });
      }
      const report = inspectServeDoctor(db, path, { now: "2026-09-01T00:10:00Z" });
      expect(report.calibration.write_rate).toBe(1);
      expect(report.calibration.failures).toEqual([]);
      expect(report.ok).toBe(true);
      db.close();
    });

    test("write_rate still catches indiscriminate writing once dedup opportunity exists", () => {
      const { path, db } = vault();
      writeServeIntent(path, "opted-out");
      persistRunReceipt(
        db,
        path,
        receipt("2026-09-01", {
          run_id: "01JBGREEDY0000000000000001",
          claims_extracted: 20,
          claims_written: 20, // write_rate 1.0: nothing ever absorbed
          claims_deduped: 0,
        }),
      );
      // Two claims share a claim_key: the same fact was extracted twice and
      // the loop filed both instead of merging — a real dedup opportunity
      // the model missed.
      insertClaim(db, {
        claim_id: "01JBGREEDYCLAIM0001",
        claim_key: "repeated-key",
        confidence: 0.5,
        corroboration: 1,
        asserted_at: "2026-09-01T00:00:01Z",
      });
      insertClaim(db, {
        claim_id: "01JBGREEDYCLAIM0002",
        claim_key: "repeated-key",
        confidence: 0.5,
        corroboration: 1,
        asserted_at: "2026-09-01T00:00:02Z",
      });
      const report = inspectServeDoctor(db, path, { now: "2026-09-01T00:10:00Z" });
      expect(report.calibration.write_rate).toBe(1);
      expect(report.calibration.failures.some((item) => item.startsWith("write_rate"))).toBe(true);
      expect(report.ok).toBe(false);
      db.close();
    });

    test("confidence_not_produced still catches flat confidence among genuinely corroborated claims", () => {
      const { path, db } = vault();
      writeServeIntent(path, "opted-out");
      // extracted 0 keeps write_rate out of this test entirely (extracted >
      // 0 is required before that check runs at all).
      persistRunReceipt(
        db,
        path,
        receipt("2026-09-01", {
          run_id: "01JBFLAT000000000000000001",
          claims_extracted: 0,
          claims_written: 0,
          claims_deduped: 0,
        }),
      );
      // 8 claims, each corroborated (re-observed) at least once, so none of
      // them are sitting at the cap by construction — yet the model still
      // stamps the same confidence on every one.
      for (let index = 1; index <= 8; index += 1) {
        insertClaim(db, {
          claim_id: `01JBFLATCLAIM${String(index).padStart(4, "0")}`,
          claim_key: `flat-key-${index}`,
          confidence: 0.53,
          corroboration: 2,
          asserted_at: "2026-09-01T00:00:01Z",
        });
      }
      const report = inspectServeDoctor(db, path, { now: "2026-09-01T00:10:00Z" });
      expect(report.calibration.failures).toContain("confidence_not_produced");
      expect(report.ok).toBe(false);
      db.close();
    });
  });

  // #473 part 2: doctor's own connection-state recovery sweep discarded its
  // cause, so a genuine lock-contention race and real journal debris were
  // both reported as the same bare string.
  test("a connection-state recovery failure carries its cause instead of a bare string", () => {
    const { path, db } = vault();
    writeServeIntent(path, "opted-out");
    // A writer in another process holds the ledger's write lock across its
    // own swap, exactly as a concurrent doctor-sweep or a daemon still
    // finishing its startup enrollment would. Doctor's own recover() then
    // collides with it (SQLITE_BUSY) instead of finding real debris.
    const other = new Database(join(path, ".kizuki", "kizuki.db"));
    other.exec("BEGIN IMMEDIATE");
    let report: ReturnType<typeof inspectServeDoctor>;
    try {
      report = inspectServeDoctor(db, path);
    } finally {
      other.exec("ROLLBACK");
      other.close();
    }
    const failure = report.failures.find((item) => item.startsWith("connection state recovery failed"));
    expect(failure).toBeDefined();
    // Not just the bare string this used to be: the cause is now in it.
    expect(failure).not.toBe("connection state recovery failed");
    expect(failure).toContain("locked by another writer");
    db.close();
  });
});
