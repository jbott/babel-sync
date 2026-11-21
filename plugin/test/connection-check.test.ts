import assert from "node:assert/strict";
import test from "node:test";
import { ConnectionCheck } from "../src/connection-check.ts";

const settled = () => new Promise<void>((resolve) => setImmediate(resolve));

test("sign-in changes debounce and coalesce while the server verifies one session at a time", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout", "Date"] });
  const results: ((connected: boolean) => void)[] = [];
  const events: string[] = [];
  const check = new ConnectionCheck({
    active: () => true,
    verify: () => new Promise<boolean>((resolve) => results.push(resolve)),
    checking: () => events.push("checking"),
    waiting: () => events.push("waiting"),
    connected: () => {
      events.push("connected");
    },
    failed: () => assert.fail("Unexpected verification failure"),
  });
  t.after(() => check.stop());
  check.schedule();
  t.mock.timers.tick(500);
  check.schedule();
  t.mock.timers.tick(500);
  assert.equal(results.length, 0);
  t.mock.timers.tick(250);
  assert.equal(results.length, 1);
  check.schedule();
  check.schedule();
  t.mock.timers.tick(1000);
  assert.equal(results.length, 1);
  results[0](false);
  await settled();
  assert.deepEqual(events, ["checking", "waiting"]);
  t.mock.timers.tick(3999);
  assert.equal(results.length, 1);
  t.mock.timers.tick(1);
  assert.equal(results.length, 2);
  results[1](true);
  await settled();
  assert.deepEqual(events, ["checking", "waiting", "checking", "connected"]);
  check.schedule(true);
  t.mock.timers.tick(10000);
  assert.equal(results.length, 2);
});

test("closing an attempt suppresses a late verification and any queued check", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout", "Date"] });
  let finish!: (connected: boolean) => void;
  let attempts = 0;
  const check = new ConnectionCheck({
    active: () => true,
    verify: () => {
      attempts++;
      return new Promise<boolean>((resolve) => {
        finish = resolve;
      });
    },
    checking: () => {},
    waiting: assert.fail,
    connected: assert.fail,
    failed: () => assert.fail("Unexpected verification failure"),
  });
  check.schedule(true);
  t.mock.timers.tick(0);
  check.schedule();
  check.stop();
  finish(true);
  await settled();
  t.mock.timers.tick(10000);
  assert.equal(attempts, 1);
});

test("actionable failures pause automatic attempts until an explicit retry", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout", "Date"] });
  const failure = new Error("The server rejected this session.");
  let attempts = 0;
  let errors = 0;
  let complete = false;
  const check = new ConnectionCheck({
    active: () => true,
    verify: async () => {
      if (++attempts === 1) throw failure;
      return true;
    },
    checking: () => {},
    waiting: assert.fail,
    connected: () => {
      complete = true;
    },
    failed: (error) => {
      assert.equal(error, failure);
      errors++;
    },
  });
  t.after(() => check.stop());
  check.schedule(true);
  t.mock.timers.tick(0);
  await settled();
  check.schedule();
  t.mock.timers.tick(10000);
  assert.equal(attempts, 1);
  assert.equal(errors, 1);
  check.schedule(true);
  t.mock.timers.tick(0);
  await settled();
  assert.equal(attempts, 2);
  assert.equal(complete, true);
});

test("a changed connection or destination prevents a scheduled check", (t) => {
  t.mock.timers.enable({ apis: ["setTimeout", "Date"] });
  let active = true;
  const check = new ConnectionCheck({
    active: () => active,
    verify: assert.fail,
    checking: assert.fail,
    waiting: assert.fail,
    connected: assert.fail,
    failed: () => assert.fail("Unexpected verification failure"),
  });
  check.schedule();
  active = false;
  t.mock.timers.tick(750);
  assert.equal(check.stopped, true);
});
