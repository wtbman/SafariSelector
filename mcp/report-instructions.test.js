import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';

test('external clients receive the report workflow on connection without accessing Safari', { timeout: 15000 }, async () => {
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [fileURLToPath(new URL('./server.js', import.meta.url))],
    cwd: tmpdir(),
    stderr: 'pipe',
  });
  const client = new Client({ name: 'report-instructions-test', version: '1.0.0' });
  try {
    await client.connect(transport);
    const canonical = await readFile(new URL('./TAB_REPORTS.md', import.meta.url), 'utf8');
    assert.equal(client.getInstructions(), canonical);
    const { tools } = await client.listTools();
    const listing = tools.find(tool => tool.name === 'safari_list_tabs');
    assert.ok(listing);
    assert.match(listing.description, /tab-report instructions/);
    assert.ok(tools.some(tool => tool.name === 'safari_close_tabs'));
  } finally {
    await client.close();
  }
});
