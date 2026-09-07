import { afterEach, expect, test } from "bun:test";
import { existsSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { createHelpers, fixtureConsent } from "./helpers";

const { cleanup, runCli, tempVault } = createHelpers();
afterEach(cleanup);
const mainPath = resolve(import.meta.dir, "../src/main.ts");

/**
 * Beeper's own fixture, kept alive on a loopback server: a synchronous
 * `Bun.spawnSync` (this suite's usual `runCli`) blocks the event loop the
 * server needs to answer, so the enrollment call that talks to it has to
 * run through an async child instead.
 */
async function asyncCli(env: Record<string, string | undefined>, ...args: string[]) {
  const child = Bun.spawn([process.execPath, mainPath, ...args], {
    env: { PATH: process.env.PATH, ...env }, stdout: "pipe", stderr: "pipe",
  });
  const [stdout, stderr, exitCode] = await Promise.all([
    new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited,
  ]);
  return { stdout, stderr, exitCode };
}

// Empty on purpose: `import`'s backfill loop re-sends a local-file
// calendar's whole snapshot on every pass (the ledger's dedupe is what
// makes a replay a no-op for a real, populated calendar), which needs a
// remote source's conditional-GET "unchanged" signal to ever look drained
// to `runToCompletion` — a local-file backfill's own completion semantics
// are not what this suite is about. An empty calendar is drained on its
// first and only batch, so it exercises exactly the connection-state
// export/restore path this suite targets.
const FIXTURE_CALENDAR = [
  "BEGIN:VCALENDAR",
  "VERSION:2.0",
  "X-WR-CALNAME:Acme team",
  "END:VCALENDAR",
  "",
].join("\r\n");

const BEEPER_TOKEN = "synthetic-local-message-token";

function onlyFileIn(directory: string): string {
  const entries = readdirSync(directory);
  expect(entries.length).toBe(1);
  return join(directory, entries[0]!);
}

// Closes the gap left by #555's restore fix: kizuki.ics declares
// auth_modes ["none", "sign_in"] (a local file or public URL versus a
// private calendar URL), so the connector-level gate excluded it wholesale
// even when the specific enrolled connection is the plain, never-a-
// credential `none` mode (a local .ics file). connectionStateIsCredentialFree
// now also accepts a connection whose decoded state literally is a bare
// {path} -- a shape decodeHostState refuses to produce from anything but a
// `none`-mode enrollment for this connector -- so this connection now
// survives export/restore exactly like markdown-folder already did.
test("a none-mode kizuki.ics connection restores with state=present health=ok", () => {
  const setup = tempVault();
  const calendarPath = join(setup.root, "acme-team.ics");
  writeFileSync(calendarPath, FIXTURE_CALENDAR, { mode: 0o600 });

  const imported = runCli(
    setup.env,
    "import",
    "ics",
    "--source",
    calendarPath,
    ...fixtureConsent(setup.root),
  );
  expect(imported.exitCode, imported.stderr).toBe(0);

  const doctorBefore = runCli(setup.env, "doctor", "--vault", setup.vault);
  expect(doctorBefore.exitCode, doctorBefore.stdout).toBe(0);
  expect(doctorBefore.stdout).toContain(`path=${calendarPath} state=present health=ok`);

  const outDir = join(setup.root, "export");
  const exported = runCli(setup.env, "export", "--out", outDir);
  expect(exported.exitCode, exported.stderr).toBe(0);
  // This is the finish line for the gap: before this fix, kizuki.ics's
  // state was never copied at all, no matter its actual enrollment mode.
  expect(exported.stdout).toContain("connection_state=1");
  expect(existsSync(join(outDir, "connections"))).toBe(true);

  const restored = join(setup.root, "restored");
  const restore = runCli(setup.env, "restore", "--from", outDir, "--into", restored);
  expect(restore.exitCode, restore.stderr).toBe(0);
  expect(restore.stdout).toContain("connection_state=1");

  const doctorAfter = runCli(setup.env, "doctor", "--vault", restored);
  expect(doctorAfter.stdout).not.toContain("state=missing");
  expect(doctorAfter.stdout).toContain(`path=${calendarPath} state=present health=ok`);
  expect(doctorAfter.stdout).toContain("status=ok");
  expect(doctorAfter.exitCode, doctorAfter.stdout).toBe(0);
});

// The security floor the loosened gate must not move: a connection whose
// state really could be a credential (Beeper mints a bearer token into the
// same opaque store) still never gets copied, still reports state=missing
// after restore, and still needs re-enrollment -- unchanged from before
// this fix, and unaffected by kizuki.ics also being in the same vault.
test("a sign-in-mode connection still needs re-enrollment after restore", async () => {
  const setup = tempVault();
  const calendarPath = join(setup.root, "acme-team.ics");
  writeFileSync(calendarPath, FIXTURE_CALENDAR, { mode: 0o600 });
  expect(
    runCli(setup.env, "import", "ics", "--source", calendarPath, ...fixtureConsent(setup.root)).exitCode,
  ).toBe(0);

  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    fetch() {
      return Response.json({ app: { name: "Beeper", version: "fixture" }, server: { status: "running" } });
    },
  });
  try {
    const env = { ...setup.env, BEEPER_TOKEN };
    const connected = await asyncCli(
      env,
      "connect",
      "beeper",
      "--token-ref",
      "env:BEEPER_TOKEN",
      "--endpoint",
      `http://127.0.0.1:${server.port}`,
    );
    expect(connected.exitCode, connected.stderr).toBe(0);

    const doctorBefore = runCli(env, "doctor", "--vault", setup.vault);
    // Health can be misconfigured before source consent is granted; what
    // this test needs is that the enrollment itself has state present.
    expect(doctorBefore.stdout).toMatch(/connection kizuki\.beeper source=\S+ path=http:\S+ state=present/);

    const outDir = join(setup.root, "export");
    const exported = runCli(env, "export", "--out", outDir);
    expect(exported.exitCode, exported.stderr).toBe(0);
    // Exactly one connection's state is credential-free (kizuki.ics);
    // Beeper's is not, no matter that both connectors sit in the same vault.
    expect(exported.stdout).toContain("connection_state=1");
    expect(onlyFileIn(join(outDir, "connections"))).toBeTruthy();

    const restored = join(setup.root, "restored");
    const restore = runCli(env, "restore", "--from", outDir, "--into", restored);
    expect(restore.exitCode, restore.stderr).toBe(0);
    expect(restore.stdout).toContain("connection_state=1");

    const doctorAfter = runCli(env, "doctor", "--vault", restored);
    // kizuki.ics is healthy; Beeper still needs a fresh `connect beeper`.
    expect(doctorAfter.stdout).toContain(`path=${calendarPath} state=present health=ok`);
    expect(doctorAfter.stdout).toMatch(/connection kizuki\.beeper source=\S+ path=- state=missing health=misconfigured/);
  } finally {
    await server.stop(true);
  }
});

// Proves the new decode-based check, not just the connector's declared auth
// modes, is what restore trusts. A backup directory is local, unsigned
// storage: nothing stops an attacker who already has write access to it
// from dropping different bytes behind the same reference a genuine
// kizuki.ics connection's row still points at. If those bytes are the
// connector's own opaque sign-in state (a private calendar URL) instead of
// a bare path, decodeHostState refuses to parse them for kizuki.ics -- so
// restore must still refuse to write them back, and the connection must
// still come back needing re-enrollment, exactly as if its state were
// simply missing.
test("a tampered backup cannot smuggle opaque state back in under a none-mode connector id", () => {
  const setup = tempVault();
  const calendarPath = join(setup.root, "acme-team.ics");
  writeFileSync(calendarPath, FIXTURE_CALENDAR, { mode: 0o600 });
  expect(
    runCli(setup.env, "import", "ics", "--source", calendarPath, ...fixtureConsent(setup.root)).exitCode,
  ).toBe(0);

  const outDir = join(setup.root, "export");
  const exported = runCli(setup.env, "export", "--out", outDir);
  expect(exported.exitCode, exported.stderr).toBe(0);
  expect(exported.stdout).toContain("connection_state=1");

  // Simulate an attacker (or corruption) replacing the exported state bytes
  // with the connector's own opaque sign-in shape -- what a real signed-in
  // kizuki.ics connection's state would look like, carrying a private
  // calendar URL as its credential.
  const statePath = onlyFileIn(join(outDir, "connections"));
  const original = readFileSync(statePath, "utf8");
  expect(JSON.parse(original).config.path).toBe(calendarPath);
  writeFileSync(
    statePath,
    JSON.stringify({ schema: "kizuki.ics-state/v1", url: "https://private.example.com/secret-token-in-path.ics" }),
    { mode: 0o600 },
  );

  const restored = join(setup.root, "restored");
  const restore = runCli(setup.env, "restore", "--from", outDir, "--into", restored);
  expect(restore.exitCode, restore.stderr).toBe(0);
  // decodeHostState rejects the tampered bytes outright (wrong schema), so
  // restore must not write them into the restored vault at all.
  expect(restore.stdout).toContain("connection_state=0");
  const restoredConnections = join(restored, ".kizuki", "connections");
  expect(existsSync(restoredConnections) && readdirSync(restoredConnections).length > 0).toBe(false);

  const doctorAfter = runCli(setup.env, "doctor", "--vault", restored);
  expect(doctorAfter.stdout).toMatch(/connection kizuki\.ics source=\S+ path=- state=missing health=misconfigured/);
});
