/**
 * access-map-guard.ts — fail when two plugins, or a plugin and Kanboard core, share a
 * controller short name.
 *
 * Usage: node testing/access-map-guard.ts [plugins-root] [kanboard-src]
 *
 * Kanboard's AccessMap keys its rules by the lowercased short class name, with no namespace
 * (app/Core/Security/AccessMap.php addRule()). A rule one plugin registers for
 * `SettingsController` therefore also governs every other plugin's `SettingsController`, and
 * core's own rules (AuthenticationProvider) govern any plugin controller named like a core one.
 *
 * A clash is one of:
 *   shared        a routable class of the same short name in two plugins' Controller/
 *   core          a plugin controller named like a core controller
 *   foreign-rule  a plugin's *AccessMap->add('X', …) where X is not its own controller but
 *                 another plugin's or core's
 *
 * Traits, interfaces and abstract classes are not routable and are skipped. A clash listed in
 * WAIVERS, with every party named, passes; a new party joining it fails again. ACCESS_MAP_WAIVERS
 * may name a JSON file of more waivers, same shape; a malformed file exits 2.
 * Exits 1 and lists each clash when any is unwaived.
 */
import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { basename, dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export type Waiver = { name: string; parties: string[]; reason: string };
export type Clash = { kind: 'shared' | 'core' | 'foreign-rule'; name: string; parties: string[] };
export type Scan = {
  /** plugin => lowercased routable controller short names */
  controllers: Map<string, Set<string>>;
  /** plugin => lowercased controller names its Plugin.php registers access rules for */
  rules: Map<string, Set<string>>;
  core: Set<string>;
};

const CORE = 'core';

export const WAIVERS: Waiver[] = [
  {
    name: 'ThemeController',
    parties: ['Harbor', 'ShadcnTheme'],
    reason: 'Harbor replaces ShadcnTheme and the two are never installed together; neither registers a rule for it.',
  },
  {
    name: 'BoardAjaxController',
    parties: ['Bigboard', 'core'],
    reason: "Bigboard's board mirrors core's; core's PROJECT_MEMBER rule on save is the rule Bigboard wants.",
  },
  {
    name: 'ExportController',
    parties: ['Vault', 'core'],
    reason: "Core's PROJECT_MANAGER rule is a project rule; Vault's export routes carry no project_id or task_id, so it never applies.",
  },
  {
    name: 'FeedController',
    parties: ['BattleLobby', 'core'],
    reason: "Core makes FeedController APP_PUBLIC; BattleLobby's recent/thanks check project access and CSRF themselves.",
  },
  {
    name: 'SubtaskStatusController',
    parties: ['Harbor', 'core'],
    reason: "Core's PROJECT_MEMBER rule only narrows Harbor's set(), which checks canSet() itself.",
  },
];

/** WAIVERS plus the ones a JSON file (ACCESS_MAP_WAIVERS) lists, for plugins this repo does not name. */
export function loadWaivers(path: string | undefined): Waiver[] {
  if (!path) return WAIVERS;
  let text: string;
  try {
    text = readFileSync(path, 'utf8');
  } catch (e) {
    throw new Error(`access-map-guard: cannot read waivers from ${path} (${(e as NodeJS.ErrnoException).code ?? 'read error'})`);
  }
  let extra: unknown;
  try {
    extra = JSON.parse(text);
  } catch {
    // Never pass the parser's message on: it can quote the file's contents.
    throw new Error(`access-map-guard: ${path} is not valid JSON`);
  }
  const ok = (w: any) =>
    w && typeof w.name === 'string' && typeof w.reason === 'string' &&
    Array.isArray(w.parties) && w.parties.every((p: unknown) => typeof p === 'string');
  if (!Array.isArray(extra) || !extra.every(ok)) {
    throw new Error(`access-map-guard: ${path} must be a JSON array of {name, parties: string[], reason}`);
  }
  return [...WAIVERS, ...(extra as Waiver[])];
}

const CLASS_RE = /^[ \t]*(?:final[ \t]+|readonly[ \t]+)*class[ \t]+(\w+)/m;
const RULE_RE = /(?:application|project)AccessMap->add\(\s*['"]([^'"]+)['"]/g;

const lower = (s: string) => s.toLowerCase();
const phpFiles = (dir: string) => (existsSync(dir) ? readdirSync(dir).filter((f) => f.endsWith('.php')) : []);

export function scan(pluginsRoot: string, kbSrc: string): Scan {
  const controllers = new Map<string, Set<string>>();
  const rules = new Map<string, Set<string>>();
  for (const name of readdirSync(pluginsRoot).sort()) {
    const dir = join(pluginsRoot, name);
    if (!existsSync(join(dir, 'plugin.json'))) continue;
    const own = new Set<string>();
    for (const f of phpFiles(join(dir, 'Controller'))) {
      const m = CLASS_RE.exec(readFileSync(join(dir, 'Controller', f), 'utf8'));
      if (m) own.add(lower(m[1]));
    }
    controllers.set(name, own);
    const php = existsSync(join(dir, 'Plugin.php')) ? readFileSync(join(dir, 'Plugin.php'), 'utf8') : '';
    rules.set(name, new Set([...php.matchAll(RULE_RE)].map((m) => lower(m[1]))));
  }
  const core = new Set(phpFiles(join(kbSrc, 'app', 'Controller')).map((f) => lower(basename(f, '.php'))));
  return { controllers, rules, core };
}

export function findClashes(s: Scan, waivers: Waiver[] = WAIVERS): Clash[] {
  const owners = new Map<string, string[]>();
  for (const [plugin, names] of s.controllers) {
    for (const n of names) owners.set(n, [...(owners.get(n) ?? []), plugin]);
  }
  const clashes: Clash[] = [];
  for (const [name, plugins] of [...owners].sort(([a], [b]) => a.localeCompare(b))) {
    if (plugins.length > 1) clashes.push({ kind: 'shared', name, parties: plugins });
    if (s.core.has(name)) clashes.push({ kind: 'core', name, parties: [...plugins, CORE] });
  }
  for (const [plugin, names] of s.rules) {
    for (const name of [...names].sort()) {
      if (s.controllers.get(plugin)?.has(name)) continue;
      const others = [...(owners.get(name) ?? []), ...(s.core.has(name) ? [CORE] : [])];
      if (others.length > 0) clashes.push({ kind: 'foreign-rule', name, parties: [plugin, ...others] });
    }
  }
  return clashes.filter(
    (c) => !waivers.some((w) => lower(w.name) === c.name && c.parties.every((p) => w.parties.includes(p))),
  );
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const repo = resolve(dirname(fileURLToPath(import.meta.url)), '..');
  const root = resolve(process.argv[2] ?? process.env.PLUGINS_ROOT ?? repo);
  const kb = resolve(process.argv[3] ?? process.env.KB_SRC ?? join(repo, 'testing', 'kanboard-src'));
  if (!existsSync(join(kb, 'app', 'Controller'))) {
    console.error(`access-map-guard: no Kanboard source at ${kb}`);
    process.exit(2);
  }
  let waivers: Waiver[];
  try {
    waivers = loadWaivers(process.env.ACCESS_MAP_WAIVERS || undefined);
  } catch (e) {
    console.error((e as Error).message);
    process.exit(2);
  }
  const s = scan(root, kb);
  const clashes = findClashes(s, waivers);
  for (const c of clashes) console.error(`CLASH ${c.kind}: ${c.name} — ${c.parties.join(', ')}`);
  if (clashes.length > 0) {
    console.error(`access-map-guard: ${clashes.length} clash(es). Rename the controller to <Plugin>…Controller, or add a waiver with a reason.`);
    process.exit(1);
  }
  console.log(`access-map-guard: ${s.controllers.size} plugins, no controller-name clashes.`);
}
