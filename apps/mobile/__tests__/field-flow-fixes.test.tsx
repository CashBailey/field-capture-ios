/**
 * Field-flow fixes (items 5–9): the add-evidence menu is contextual (Ticket Photo only for hybrid
 * tickets, Customer Signature only for flowback jobs, no manual GPS step), optional self-titled
 * photos, and the JHA save-as-you-go / don't-re-ask-once-done behavior. Hardware-free renders over
 * the real domain/runtime services.
 */
import React from 'react';
import { fieldwork, sync } from '@fieldcapture/contracts';

import { isFlowbackJob, VolatileFieldFormStore, type FieldWorkGate } from '../src/domain';
import { FieldWorkflowScreen } from '../src/screens';
import {
  buildEvidenceMenu,
  evidenceRouteForMenuKey,
  JobEvidenceScreen,
} from '../src/screens/EvidenceScreens';

const TestRenderer = require('react-test-renderer') as typeof import('react-test-renderer');
const { act } = TestRenderer;

const UNLOCKED: FieldWorkGate = {
  state: 'unlocked',
  clockedInSince: '2026-06-10T06:00:00Z',
  source: 'timeclock',
};

function textOf(renderer: import('react-test-renderer').ReactTestRenderer): string {
  return JSON.stringify(renderer.toJSON());
}
function press(renderer: import('react-test-renderer').ReactTestRenderer, testID: string): void {
  act(() => {
    renderer.root.findByProps({ testID }).props.onPress();
  });
}
function changeText(
  renderer: import('react-test-renderer').ReactTestRenderer,
  testID: string,
  value: string,
): void {
  act(() => {
    renderer.root.findByProps({ testID }).props.onChangeText(value);
  });
}
function has(renderer: import('react-test-renderer').ReactTestRenderer, testID: string): boolean {
  return renderer.root.findAllByProps({ testID }).length > 0;
}

describe('isFlowbackJob (item 6 predicate)', () => {
  it('is true only when the job type contains "flowback" (case-insensitive)', () => {
    expect(isFlowbackJob('Flowback')).toBe(true);
    expect(isFlowbackJob('FLOWBACK services')).toBe(true);
    expect(isFlowbackJob('well flowback test')).toBe(true);
    expect(isFlowbackJob('water-haul')).toBe(false);
    expect(isFlowbackJob('disposal')).toBe(false);
    expect(isFlowbackJob(undefined)).toBe(false);
    expect(isFlowbackJob('')).toBe(false);
  });
});

describe('buildEvidenceMenu (items 5–7)', () => {
  const keys = (ctx?: { captureMethod?: 'digital' | 'paper' | 'hybrid'; jobType?: string }) =>
    buildEvidenceMenu(ctx).map((m) => m.key);

  it('never offers a manual GPS event (captured automatically)', () => {
    expect(keys()).not.toContain('gps-event');
    expect(keys({ captureMethod: 'hybrid', jobType: 'flowback' })).not.toContain('gps-event');
  });

  it('offers Ticket Photo ONLY when the ticket is hybrid (item 5)', () => {
    expect(keys({ captureMethod: 'digital' })).not.toContain('ticket-photo');
    expect(keys({ captureMethod: 'paper' })).not.toContain('ticket-photo');
    expect(keys()).not.toContain('ticket-photo');
    expect(keys({ captureMethod: 'hybrid' })).toContain('ticket-photo');
  });

  it('offers Customer Signature ONLY for flowback jobs; driver signature always (item 6)', () => {
    expect(keys({ jobType: 'water-haul' })).not.toContain('customer-signature');
    expect(keys({ jobType: 'water-haul' })).toContain('signature'); // driver signature still offered
    expect(keys({ jobType: 'flowback' })).toContain('customer-signature');
    expect(keys({ jobType: 'flowback' })).toContain('signature');
  });

  it('always offers an optional self-titled photo (item 8)', () => {
    expect(keys()).toContain('photo');
  });

  it('routes each menu item to the capture surface the live Evidence flow opens', () => {
    expect(evidenceRouteForMenuKey('field-photo')).toBe('camera');
    expect(evidenceRouteForMenuKey('disposal-photo')).toBe('camera');
    expect(evidenceRouteForMenuKey('ticket-photo')).toBe('camera');
    expect(evidenceRouteForMenuKey('photo')).toBe('camera');
    expect(evidenceRouteForMenuKey('other')).toBe('camera');
    expect(evidenceRouteForMenuKey('receipt-photo')).toBe('receipt');
    expect(evidenceRouteForMenuKey('signature')).toBe('signature');
    expect(evidenceRouteForMenuKey('customer-signature')).toBe('signature');
  });
});

describe('JobEvidenceScreen (contextual menu + optional photos)', () => {
  function render(props: Parameters<typeof JobEvidenceScreen>[0] = {}) {
    let renderer: import('react-test-renderer').ReactTestRenderer;
    act(() => {
      renderer = TestRenderer.create(<JobEvidenceScreen {...props} />);
    });
    return renderer!;
  }

  it('hides Ticket Photo for non-hybrid and shows it for hybrid', () => {
    const digital = render({ captureMethod: 'digital' });
    press(digital, 'evidence-add-open');
    expect(has(digital, 'evidence-add-ticket-photo')).toBe(false);

    const hybrid = render({ captureMethod: 'hybrid' });
    press(hybrid, 'evidence-add-open');
    expect(has(hybrid, 'evidence-add-ticket-photo')).toBe(true);
  });

  it('hides Customer Signature for non-flowback and shows it for flowback', () => {
    const haul = render({ jobType: 'water-haul' });
    press(haul, 'evidence-add-open');
    expect(has(haul, 'evidence-add-customer-signature')).toBe(false);
    expect(has(haul, 'evidence-add-signature')).toBe(true); // driver signature always present

    const flow = render({ jobType: 'Flowback' });
    press(flow, 'evidence-add-open');
    expect(has(flow, 'evidence-add-customer-signature')).toBe(true);
  });

  it('never shows a manual GPS event item', () => {
    const r = render({ captureMethod: 'hybrid', jobType: 'flowback' });
    press(r, 'evidence-add-open');
    expect(has(r, 'evidence-add-gps-event')).toBe(false);
  });

  it('reports the selected evidence key so the host can open the matching capture screen', () => {
    const picked: string[] = [];
    const r = render({
      captureMethod: 'hybrid',
      jobType: 'flowback',
      onAddEvidence: (key) => picked.push(key),
    });
    press(r, 'evidence-add-open');
    press(r, 'evidence-add-receipt-photo');
    expect(picked).toEqual(['receipt-photo']);
  });

  it('adds multiple optional, driver-titled photos and reports each (item 8)', () => {
    const added: { title: string }[] = [];
    const r = render({ onAddPhoto: (p) => added.push(p) });
    changeText(r, 'optional-photo-title-input', 'Tank gauge before load');
    press(r, 'optional-photo-add');
    changeText(r, 'optional-photo-title-input', 'Seal intact');
    press(r, 'optional-photo-add');

    expect(added).toEqual([{ title: 'Tank gauge before load' }, { title: 'Seal intact' }]);
    expect(has(r, 'optional-photo-0')).toBe(true);
    expect(has(r, 'optional-photo-1')).toBe(true);
    expect(textOf(r)).toContain('Tank gauge before load');
    expect(textOf(r)).toContain('Seal intact');
  });

  it('ignores an empty optional-photo title (never required)', () => {
    const added: { title: string }[] = [];
    const r = render({ onAddPhoto: (p) => added.push(p) });
    press(r, 'optional-photo-add');
    expect(added).toHaveLength(0);
    expect(has(r, 'optional-photo-0')).toBe(false);
  });
});

// A FieldWorkflowService wired over volatile stores — mirrors the runtime test seam.
const JHA_REQUIRED: fieldwork.WorkflowRequirements = {
  clockInRequired: true,
  requiredSteps: ['jha'],
};
function makeWorkflow(forms: VolatileFieldFormStore) {
  const enqueued: sync.OperationEnvelope[] = [];
  const outcomes = new Map<string, { state: sync.OutboxItemState }>();
  let seq = 0;
  let uuid = 0;
  const service = new (require('../src/runtime').FieldWorkflowService)({
    forms,
    gateState: () => UNLOCKED,
    enqueueEvidence: (envelope: sync.OperationEnvelope) => enqueued.push(envelope),
    outboxItem: (opId: string) => outcomes.get(opId),
    requirements: () => JHA_REQUIRED,
    identity: {
      deviceInstanceId: 'devA',
      allocateLocalSeq: () => seq++,
      generateUuid: () => `op-${uuid++}`,
    },
    now: () => new Date('2026-06-10T12:00:00Z'),
  });
  return { service, enqueued, outcomes };
}

describe("FieldWorkflowScreen JHA save-as-you-go + don't-re-ask (item 9)", () => {
  function render(forms: VolatileFieldFormStore, service: unknown) {
    let renderer: import('react-test-renderer').ReactTestRenderer;
    act(() => {
      renderer = TestRenderer.create(
        <FieldWorkflowScreen
          gate={UNLOCKED}
          workflow={service as never}
          forms={forms}
          serviceRequestId="sr-9"
          onSubmitTicket={jest.fn()}
        />,
      );
    });
    return renderer!;
  }

  it('persists JHA progress on every change, not only on explicit Save', () => {
    const forms = new VolatileFieldFormStore();
    const { service } = makeWorkflow(forms);
    const renderer = render(forms, service);

    // No explicit Save pressed — just typing persists the draft keyed jha-jsa-sr-9.
    changeText(renderer, 'jha-hazard', 'H2S near tank battery');
    const saved = forms.get('jha-jsa-sr-9');
    expect(saved).toMatchObject({ status: 'draft' });
    expect(saved?.form.kind).toBe('jha-jsa');
    if (saved?.form.kind === 'jha-jsa') {
      expect(saved.form.hazards[0]?.description).toBe('H2S near tank battery');
    }
  });

  it('re-seeds the in-progress draft on remount (progress remembered across navigation)', () => {
    const forms = new VolatileFieldFormStore();
    const { service } = makeWorkflow(forms);
    const first = render(forms, service);
    changeText(first, 'jha-mitigation', 'ventilate and monitor');

    // Remount (e.g. navigated away and back) — the field comes back pre-filled from the store.
    const second = render(forms, service);
    expect(second.root.findByProps({ testID: 'jha-mitigation' }).props.value).toBe(
      'ventilate and monitor',
    );
  });

  it('does not re-ask once the JHA is completed; shows a completed banner instead', () => {
    const forms = new VolatileFieldFormStore();
    const { service } = makeWorkflow(forms);
    const renderer = render(forms, service);

    changeText(renderer, 'jha-hazard', 'H2S');
    changeText(renderer, 'jha-mitigation', 'monitor');
    changeText(renderer, 'jha-signature', 'sig-jha'); // a signature is required to complete
    press(renderer, 'jha-complete');

    expect(forms.get('jha-jsa-sr-9')).toMatchObject({ status: 'completed' });

    // Re-render after completion: the editable fields are gone, the completed banner is shown.
    const reopened = render(forms, service);
    expect(has(reopened, 'jha-complete-banner')).toBe(true);
    expect(has(reopened, 'jha-hazard')).toBe(false);
    expect(textOf(reopened)).toContain('already complete');
  });
});
