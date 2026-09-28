/**
 * Truth-in-UI: controls do what they say. Contact Dispatch actually dials the on-duty dispatcher via
 * the OS (and there is no fictional "Midland office"); the Jobs filters are large tap targets; and
 * Job Overview does not claim background GPS tracking.
 */
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

import { Linking } from 'react-native';

import { ContactDispatchScreen, PrinterSettingsScreen } from '../src/screens/MoreScreens';
import { JobOverviewScreen, JobsListScreen } from '../src/screens/JobScreens';
import { SyncHomeScreen } from '../src/screens/SyncScreens';

const TestRenderer = require('react-test-renderer') as typeof import('react-test-renderer');
const { act } = TestRenderer;

function render(node: React.ReactElement) {
  let r: import('react-test-renderer').ReactTestRenderer;
  act(() => {
    r = TestRenderer.create(node);
  });
  return r!;
}
function tap(r: import('react-test-renderer').ReactTestRenderer, testID: string) {
  const nodes = r.root.findAllByProps({ testID });
  const node = nodes.find((n) => typeof n.props.onPress === 'function') ?? nodes[0];
  act(() => node.props.onPress());
}
function has(r: import('react-test-renderer').ReactTestRenderer, testID: string): boolean {
  return r.root.findAllByProps({ testID }).length > 0;
}
function flatText(json: unknown): string {
  if (json === null || json === undefined) return '';
  if (typeof json === 'string' || typeof json === 'number') return String(json);
  if (Array.isArray(json)) return json.map(flatText).join('');
  return flatText((json as { children?: unknown }).children);
}
function mergedStyle(style: unknown): Record<string, unknown> {
  const parts = (Array.isArray(style) ? style : [style]).filter(Boolean) as object[];
  return Object.assign({}, ...parts);
}

describe('ContactDispatchScreen', () => {
  it('has no Midland office and dials Field Dispatch via the OS', () => {
    const spy = jest.spyOn(Linking, 'openURL').mockResolvedValue(true);
    const r = render(<ContactDispatchScreen />);
    const text = flatText(r.toJSON());
    expect(text).not.toContain('Midland');
    expect(text).toContain('Field Dispatch');
    tap(r, 'contact-call-dispatch');
    expect(spy).toHaveBeenCalledWith('tel:4325550100');
    spy.mockRestore();
  });
});

describe('Jobs filters', () => {
  it('are at least 48px tall tap targets', () => {
    const r = render(
      <JobsListScreen jobs={[]} onOpenJob={() => undefined} onRefresh={() => undefined} />,
    );
    const chip = r.root.findAllByProps({ testID: 'jobs-filter-all' }).find((n) => n.props.style);
    expect(mergedStyle(chip!.props.style).minHeight).toBe(48);
  });
});

describe('Job Overview', () => {
  it('has no manual Capture GPS button and points GPS validation to the Location panel', () => {
    const r = render(<JobOverviewScreen />);
    expect(has(r, 'job-capture-gps')).toBe(false);
    expect(has(r, 'job-gps-auto')).toBe(true);
    expect(has(r, 'job-add-evidence')).toBe(true);
    expect(flatText(r.toJSON())).toContain('GPS validation is captured from the Location panel');
  });

  it('records work-start from the job overview action', () => {
    const onStartWork = jest.fn();
    const r = render(
      <JobOverviewScreen
        onStartWork={onStartWork}
        workStartStatus={{ label: 'Work start saved', tone: 'success' }}
      />,
    );
    tap(r, 'job-start-work');
    expect(onStartWork).toHaveBeenCalledTimes(1);
    expect(has(r, 'job-work-start-status')).toBe(true);
  });
});

describe('Sync Home', () => {
  it('uses a truthful Sync Now action now that the runtime kicks sync/upload runners', () => {
    const onSyncNow = jest.fn();
    const r = render(
      <SyncHomeScreen
        overallState="Pending Sync"
        pendingCount={2}
        failedCount={0}
        syncedCount={3}
        lastSyncedAt="Never"
        onSyncNow={onSyncNow}
        onViewPending={() => undefined}
        onViewFailed={() => undefined}
      />,
    );
    const text = flatText(r.toJSON());

    expect(text).toContain('Tap Sync Now to push waiting work');
    tap(r, 'sync-home-sync-now');
    expect(onSyncNow).toHaveBeenCalledTimes(1);
  });
});

describe('Printer settings', () => {
  it('lets the test page action attempt reconnect when the printer is offline', () => {
    const onReconnect = jest.fn();
    const onPrintTestPage = jest.fn();
    const r = render(
      <PrinterSettingsScreen
        connected={false}
        actionMessage="Looking for your printer…"
        onReconnect={onReconnect}
        onPrintTestPage={onPrintTestPage}
      />,
    );

    expect(flatText(r.toJSON())).toContain('Offline Mode');
    expect(flatText(r.toJSON())).toContain('Looking for your printer');
    expect(flatText(r.toJSON())).toContain('Test page will reconnect first if needed');
    expect(r.root.findByProps({ testID: 'printer-test-page' }).props.disabled).toBe(false);
    tap(r, 'printer-reconnect');
    expect(onReconnect).toHaveBeenCalledTimes(1);
    tap(r, 'printer-test-page');
    expect(onPrintTestPage).toHaveBeenCalledTimes(1);
  });

  it('enables the test page and calls the host print action when connected', () => {
    const onPrintTestPage = jest.fn();
    const r = render(
      <PrinterSettingsScreen
        printerName="PT-210_261D"
        connected
        connectionMessage="PT-210_261D is connected and ready for field tickets."
        onPrintTestPage={onPrintTestPage}
      />,
    );

    expect(flatText(r.toJSON())).toContain('Synced');
    expect(flatText(r.toJSON())).toContain('PT-210_261D is connected');
    expect(r.root.findByProps({ testID: 'printer-test-page' }).props.disabled).toBe(false);
    tap(r, 'printer-test-page');
    expect(onPrintTestPage).toHaveBeenCalledTimes(1);
  });
});

describe('Field ticket route', () => {
  it('does not send JHA Complete into the old presentational ticket wizard', () => {
    const appSource = readFileSync(join(__dirname, '..', 'App.tsx'), 'utf8');

    expect(appSource).toContain("onStartFieldTicket={() => setWorkPanel('ticket')}");
    expect(appSource).not.toContain("'fieldticket'");
    expect(appSource).not.toContain('function FieldTicketFlow');
    expect(appSource).not.toContain('ticket-flow-back');
  });

  it('sends the big Add Evidence job action to the real capture panel', () => {
    const appSource = readFileSync(join(__dirname, '..', 'App.tsx'), 'utf8');

    expect(appSource).toContain("onAddEvidence={() => setWorkPanel('capture')}");
    expect(appSource).toContain("else if (key === 'evidence') setWorkPanel('capture')");
    expect(appSource).not.toContain("onAddEvidence={() => setWorkPanel('evidence')}");
  });
});
