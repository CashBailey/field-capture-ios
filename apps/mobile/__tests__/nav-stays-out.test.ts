/**
 * FieldNav-stays-out guard (Phase 0 / spec scope-lock). Field Capture is a FIELD CAPTURE app, not
 * navigation. The entire streaming location / map / routing / AutoPi / telemetry stack was removed
 * in commit b4e0b36, and the ADR-005 isolation invariant went with it — so this test is what keeps
 * it from silently creeping back. It fails CI if any map/tile/routing/AutoPi dependency or import
 * reappears under apps/mobile.
 *
 * Deliberately ALLOWED (these are in scope, not FieldNav):
 *   - @react-navigation/* — the spec's 5-tab UI shell (Section 4a). UI navigation.
 *   - native location — Phase-7 VALIDATION-ONLY GPS (single-shot getCurrentPosition). Proving
 *     where an action happened is not navigating to it.
 */
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';

const MOBILE_ROOT = join(__dirname, '..');

// Forbidden dependency name substrings: maps, tiles, routing engines, AutoPi, fleet telemetry.
// NOT @react-navigation (UI shell) and NOT native location (validation-only GPS).
const FORBIDDEN_DEPENDENCY_SUBSTRINGS = [
  'maplibre',
  'react-native-maps',
  'mapbox',
  '@rnmapbox',
  'leaflet',
  'osrm',
  'turn-by-turn',
  'autopi',
  'react-native-mapbox-navigation',
];

// Forbidden import specifiers: the dep substrings above PLUS the deleted internal nav/map/route/
// tile modules, so a reintroduced file can't import them even from a relative path.
const FORBIDDEN_IMPORT_SUBSTRINGS = [
  ...FORBIDDEN_DEPENDENCY_SUBSTRINGS,
  'navruntime',
  'maplibreroute',
  'autopilocation',
  'phonelocationprovider',
  'tilepackage',
  '/adapters/map/',
  '/adapters/location/',
  '@fieldcapture/contracts/location',
  '@fieldcapture/contracts/nav',
  '@fieldcapture/contracts/mappackage',
];

function collectSourceFiles(dir: string, acc: string[] = []): string[] {
  for (const entry of readdirSync(dir)) {
    if (entry === 'node_modules' || entry === 'dist') continue;
    const full = join(dir, entry);
    const st = statSync(full);
    if (st.isDirectory()) {
      collectSourceFiles(full, acc);
    } else if (/\.(ts|tsx)$/.test(entry) && !entry.endsWith('.d.ts')) {
      acc.push(full);
    }
  }
  return acc;
}

function importSpecifiers(source: string): string[] {
  const specs: string[] = [];
  const patterns = [/\bfrom\s+['"]([^'"]+)['"]/g, /\brequire\(\s*['"]([^'"]+)['"]\s*\)/g];
  for (const re of patterns) {
    let m: RegExpExecArray | null;
    while ((m = re.exec(source)) !== null) specs.push(m[1]!);
  }
  return specs;
}

describe('FieldNav stays out of apps/mobile (scope-lock guard)', () => {
  it('declares no map/tile/routing/AutoPi dependency', () => {
    const pkg = JSON.parse(readFileSync(join(MOBILE_ROOT, 'package.json'), 'utf8')) as {
      dependencies?: Record<string, string>;
      devDependencies?: Record<string, string>;
    };
    const allDeps = Object.keys({ ...pkg.dependencies, ...pkg.devDependencies });
    const offenders = allDeps.filter((name) =>
      FORBIDDEN_DEPENDENCY_SUBSTRINGS.some((bad) => name.toLowerCase().includes(bad)),
    );
    expect(offenders).toEqual([]);
  });

  it('imports no nav/map/tile/routing module anywhere under the app', () => {
    const files = [join(MOBILE_ROOT, 'App.tsx'), ...collectSourceFiles(join(MOBILE_ROOT, 'src'))];
    const violations: string[] = [];
    for (const file of files) {
      const specs = importSpecifiers(readFileSync(file, 'utf8'));
      for (const spec of specs) {
        if (FORBIDDEN_IMPORT_SUBSTRINGS.some((bad) => spec.toLowerCase().includes(bad))) {
          violations.push(`${file.replace(MOBILE_ROOT, 'apps/mobile')} imports "${spec}"`);
        }
      }
    }
    expect(violations).toEqual([]);
  });
});
