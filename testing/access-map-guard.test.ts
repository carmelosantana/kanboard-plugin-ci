// Tests for access-map-guard.ts against throwaway plugin trees.
// Run: node --test testing/access-map-guard.test.ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { findClashes, loadWaivers, scan, WAIVERS, type Waiver } from './access-map-guard.ts';

type Fixture = Record<string, { controllers?: Record<string, string>; plugin?: string }>;

function tree(plugins: Fixture, core: string[] = ['TaskStatusController']): { root: string; kb: string } {
  const root = mkdtempSync(join(tmpdir(), 'amg-'));
  for (const [name, p] of Object.entries(plugins)) {
    mkdirSync(join(root, name, 'Controller'), { recursive: true });
    writeFileSync(join(root, name, 'plugin.json'), '{}');
    writeFileSync(join(root, name, 'Plugin.php'), `<?php\nclass Plugin {\n  function initialize() {\n${p.plugin ?? ''}\n  }\n}\n`);
    for (const [cls, body] of Object.entries(p.controllers ?? {})) {
      writeFileSync(join(root, name, 'Controller', `${cls}.php`), body);
    }
  }
  const kb = join(root, '.kb');
  mkdirSync(join(kb, 'app', 'Controller'), { recursive: true });
  for (const c of core) writeFileSync(join(kb, 'app', 'Controller', `${c}.php`), `<?php class ${c} {}`);
  return { root, kb };
}

const cls = (name: string) => `<?php\nnamespace X;\n\nclass ${name} extends BaseController\n{\n}\n`;
const check = (plugins: Fixture, waivers: Waiver[] = [], core?: string[]) => {
  const { root, kb } = tree(plugins, core);
  return findClashes(scan(root, kb), waivers);
};

test('two plugins with a controller of the same short name clash', () => {
  const clashes = check({
    Deed: { controllers: { SettingsController: cls('SettingsController') } },
    Vault: { controllers: { SettingsController: cls('SettingsController') } },
  });
  assert.equal(clashes.length, 1);
  assert.equal(clashes[0].kind, 'shared');
  assert.equal(clashes[0].name, 'settingscontroller');
  assert.deepEqual(clashes[0].parties, ['Deed', 'Vault']);
});

test('short names compare case-insensitively, as AccessMap lowercases them', () => {
  const clashes = check({
    A: { controllers: { FooController: cls('FooController') } },
    B: { controllers: { fooController: cls('fooController') } },
  });
  assert.equal(clashes.length, 1);
});

test('a plugin controller named like a core controller clashes with core', () => {
  const clashes = check({ CoreClash: { controllers: { TaskStatusController: cls('TaskStatusController') } } });
  assert.deepEqual(clashes.map((c) => [c.kind, c.name, c.parties]), [['core', 'taskstatuscontroller', ['CoreClash', 'core']]]);
});

test('a rule for a controller only another plugin defines clashes', () => {
  const clashes = check({
    A: { plugin: "$this->applicationAccessMap->add('BarController', '*', Role::APP_ADMIN);" },
    B: { controllers: { BarController: cls('BarController') } },
  });
  assert.deepEqual(clashes.map((c) => [c.kind, c.name, c.parties]), [['foreign-rule', 'barcontroller', ['A', 'B']]]);
});

test('a rule for a core controller clashes too, with either access map and quote style', () => {
  const clashes = check({ A: { plugin: '$this->projectAccessMap->add("TaskStatusController", "x", Role::PROJECT_VIEWER);' } });
  assert.deepEqual(clashes.map((c) => [c.kind, c.parties]), [['foreign-rule', ['A', 'core']]]);
});

test("a rule for the plugin's own, unique controller is fine", () => {
  const clashes = check({
    A: {
      plugin: "$this->applicationAccessMap->add('ASettingsController', ['index'], Role::APP_ADMIN);",
      controllers: { ASettingsController: cls('ASettingsController') },
    },
  });
  assert.deepEqual(clashes, []);
});

test('traits, interfaces and abstract classes in Controller/ are not routable and do not count', () => {
  const clashes = check({
    A: { controllers: { JsonErrors: '<?php\ntrait JsonErrors {}\n', Base: '<?php\nabstract class Base {}\n' } },
    B: { controllers: { JsonErrors: '<?php\ntrait JsonErrors {}\n', Base: '<?php\ninterface Base {}\n' } },
  });
  assert.deepEqual(clashes, []);
});

test('a waiver naming the clash and all its parties suppresses it', () => {
  const plugins = {
    Harbor: { controllers: { ThemeController: cls('ThemeController') } },
    ShadcnTheme: { controllers: { ThemeController: cls('ThemeController') } },
  };
  assert.deepEqual(check(plugins, [{ name: 'ThemeController', parties: ['Harbor', 'ShadcnTheme'], reason: 'r' }]), []);
});

test('a waiver does not cover a new party joining the clash', () => {
  const clashes = check(
    {
      Harbor: { controllers: { ThemeController: cls('ThemeController') } },
      ShadcnTheme: { controllers: { ThemeController: cls('ThemeController') } },
      Third: { controllers: { ThemeController: cls('ThemeController') } },
    },
    [{ name: 'ThemeController', parties: ['Harbor', 'ShadcnTheme'], reason: 'r' }],
  );
  assert.equal(clashes.length, 1);
  assert.deepEqual(clashes[0].parties, ['Harbor', 'ShadcnTheme', 'Third']);
});

test('directories without plugin.json are not plugins', () => {
  const { root, kb } = tree({ A: { controllers: { FooController: cls('FooController') } } });
  mkdirSync(join(root, 'docs', 'Controller'), { recursive: true });
  writeFileSync(join(root, 'docs', 'Controller', 'FooController.php'), cls('FooController'));
  assert.deepEqual(findClashes(scan(root, kb), []), []);
});

test('every waiver in the script gives a reason', () => {
  for (const w of WAIVERS) assert.ok(w.reason.trim().length > 20, `${w.name} needs a reason`);
});

test('loadWaivers with no file is the built-in list', () => {
  assert.deepEqual(loadWaivers(undefined), WAIVERS);
});

test('loadWaivers adds the waivers a JSON file lists', () => {
  const file = join(mkdtempSync(join(tmpdir(), 'amg-w-')), 'waivers.json');
  writeFileSync(file, JSON.stringify([
    { name: 'TaskStatusController', parties: ['CoreClash', 'core'], reason: 'fixture waiver for a core name clash' },
  ]));
  const waivers = loadWaivers(file);
  assert.equal(waivers.length, WAIVERS.length + 1);
  assert.deepEqual(check({ CoreClash: { controllers: { TaskStatusController: cls('TaskStatusController') } } }, waivers), []);
});

test('loadWaivers rejects a file that is not a list of waivers, naming the file', () => {
  const dir = mkdtempSync(join(tmpdir(), 'amg-w-'));
  for (const [i, body] of ['{"x":1}', '[{"name":"A","parties":"core","reason":"r"}]', 'not json'].entries()) {
    const file = join(dir, `bad-${i}.json`);
    writeFileSync(file, body);
    assert.throws(() => loadWaivers(file), (e: Error) => e.message.includes(file));
  }
});

test('a malformed waivers file never echoes its contents in the error', () => {
  const file = join(mkdtempSync(join(tmpdir(), 'amg-w-')), 'oops.env');
  writeFileSync(file, 'API_TOKEN=sk-not-for-logs');
  assert.throws(() => loadWaivers(file), (e: Error) => !e.message.includes('sk-not-for-logs') && !e.message.includes('API_TOKEN'));
});
