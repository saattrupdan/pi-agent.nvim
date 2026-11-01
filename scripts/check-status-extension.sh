#!/bin/sh
set -eu

node --input-type=module <<'JS'
import assert from 'node:assert/strict';
import { readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import statusExtension from './lua/pi-agent/status.ts';

const path = join(tmpdir(), `pi-agent-status-test-${process.pid}`);
process.env.PI_AGENT_STATUS_FILE = path;
const handlers = new Map();
statusExtension({ on: (name, handler) => handlers.set(name, handler) });

function expectStatus(value) {
  assert.equal(readFileSync(path, 'utf8'), value);
}

function emit(name) {
  handlers.get(name)?.();
}

try {
  assert.ok(handlers.has('agent_settled'), 'completion uses final settlement');
  expectStatus('idle');
  emit('session_start');
  expectStatus('idle');
  emit('before_agent_start');
  expectStatus('working');
  emit('agent_start');
  emit('agent_end');
  expectStatus('working');
  emit('agent_start');
  emit('agent_end');
  emit('agent_before_settle');
  expectStatus('working');
  emit('agent_settled');
  expectStatus('finished:1');

  emit('agent_start');
  expectStatus('working');
  emit('ui_prompt_start');
  expectStatus('need_input');
  emit('ui_prompt_end');
  expectStatus('working');
  emit('agent_end');
  expectStatus('working');
  emit('agent_settled');
  expectStatus('finished:2');
  emit('session_start');
  expectStatus('idle');
  console.log('Pi status lifecycle remains working until settlement.');
} finally {
  rmSync(path, { force: true });
  delete process.env.PI_AGENT_STATUS_FILE;
}
JS
