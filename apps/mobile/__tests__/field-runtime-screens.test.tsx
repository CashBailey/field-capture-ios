/**
 * UI screens over the field runtimes. These tests stay hardware-free: they render React
 * components against the real domain/runtime services and fake transports/stores.
 */
import React from 'react';
import { fieldwork, printer, sync } from '@fieldcapture/contracts';

import {
  VolatileAssignmentStore,
  VolatileBlobBytesSource,
  VolatileBlobUploadStore,
  VolatileFieldFormStore,
  VolatileLocationEvidenceStore,
  VolatileReceiptDraftStore,
  type FieldTicketDraft,
  type FieldTicketDraftStore,
  type FieldWorkGate,
  parseWorkflowRequirementsFromAssignments,
  type HubAssignment,
  type InboxFilter,
  type SrSyncState,
  signatureBytes,
} from '../src/domain';
import { serializeSignature } from '../src/design';
import {
  AssignmentDetailScreen,
  AssignmentInboxScreen,
  CaptureEvidenceScreen,
  FieldWorkflowScreen,
  MoreScreen,
  TodayScreen,
  LocationValidationScreen,
  Pt210DiagnosticScreen,
  PrintQueueScreen,
  ReceiptCaptureScreen,
  SyncCenterScreen,
  TicketCaptureScreen,
} from '../src/screens';
import { summarizeSyncCenter } from '../src/domain';
import type { Pt210NativeBinding, Pt210Status } from '../src/adapters/printer';
import {
  CaptureFlow,
  PrintRuntime,
  UploadEngine,
  VolatilePrintPayloadStore,
  printEventOutcomeFromOutbox,
  type CaptureSource,
} from '../src/runtime';

const TestRenderer = require('react-test-renderer') as typeof import('react-test-renderer');
const { act } = TestRenderer;

const UNLOCKED: FieldWorkGate = {
  state: 'unlocked',
  clockedInSince: '2026-06-10T06:00:00Z',
  source: 'timeclock',
};
const LOCKED: FieldWorkGate = { state: 'locked', reason: 'not-clocked-in' };
const ALL_REQUIRED: fieldwork.WorkflowRequirements = {
  clockInRequired: true,
  requiredSteps: ['pre_trip_dvir', 'jha', 'post_trip_dvir'],
};
const SIGNED = serializeSignature([
  [
    { x: 0, y: 0 },
    { x: 40, y: 10 },
    { x: 80, y: 0 },
  ],
]);

function textOf(renderer: import('react-test-renderer').ReactTestRenderer): string {
  return JSON.stringify(renderer.toJSON());
}

function press(renderer: import('react-test-renderer').ReactTestRenderer, testID: string): void {
  act(() => {
    renderer.root.findByProps({ testID }).props.onPress();
  });
}

async function pressAsync(
  renderer: import('react-test-renderer').ReactTestRenderer,
  testID: string,
): Promise<void> {
  await act(async () => {
    await renderer.root.findByProps({ testID }).props.onPress();
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

function makeWorkflow(
  gate: FieldWorkGate = UNLOCKED,
  requirements: () => fieldwork.WorkflowRequirements = () => ALL_REQUIRED,
) {
  const forms = new VolatileFieldFormStore();
  const enqueued: sync.OperationEnvelope[] = [];
  const outcomes = new Map<
    string,
    { state: sync.OutboxItemState; rejectionCode?: string; lastError?: string }
  >();
  let seq = 0;
  let uuid = 0;
  const service = new (require('../src/runtime').FieldWorkflowService)({
    forms,
    gateState: () => gate,
    enqueueEvidence: (envelope: sync.OperationEnvelope) => enqueued.push(envelope),
    outboxItem: (opId: string) => outcomes.get(opId),
    requirements,
    identity: {
      deviceInstanceId: 'devA',
      allocateLocalSeq: () => seq++,
      generateUuid: () => `op-${uuid++}`,
    },
    now: () => new Date('2026-06-10T12:00:00Z'),
  });
  return { service, forms, enqueued, outcomes };
}

function makeCapture() {
  const blobs = new VolatileBlobUploadStore();
  const bytes = new VolatileBlobBytesSource();
  const enqueued: sync.OperationEnvelope<sync.AttachBlobCommand>[] = [];
  const linkStates = new Map<string, sync.OutboxItemState>();
  let seq = 0;
  let uuid = 0;
  const uploadEngine = new UploadEngine({
    blobs,
    bytes,
    transport: {
      openUploadSession: async () => {
        throw new Error('Hub upload route unavailable');
      },
    },
    tus: {
      probe: async () => ({ offset: 0 }),
      uploadChunk: async () => ({ offset: 0 }),
    },
    enqueueLink: (envelope) => enqueued.push(envelope),
    linkState: (opId) => linkStates.get(opId),
    identity: {
      deviceInstanceId: 'devA',
      allocateLocalSeq: () => seq++,
      generateUuid: () => `up-${uuid++}`,
    },
    now: () => new Date('2026-06-10T12:00:00Z'),
  });
  const flow = new CaptureFlow({
    uploads: uploadEngine,
    persistBytes: async (blobId, data) => {
      const uri = `file:///captures/${blobId}`;
      bytes.put(uri, data);
      return uri;
    },
    gateState: () => UNLOCKED,
    identity: { generateUuid: () => `blob-${uuid++}` },
  });
  return { flow, uploadEngine, blobs, bytes, enqueued, linkStates };
}

async function fakeCaptureDevice(input: {
  attachmentKind: sync.AttachBlobCommand['attachmentKind'];
  source: CaptureSource;
}) {
  const data: Record<sync.AttachBlobCommand['attachmentKind'], Uint8Array> = {
    'field-ticket-photo': new Uint8Array([1, 2, 3, 4]),
    'disposal-photo': new Uint8Array([5, 6, 7, 8]),
    'receipt-photo': new Uint8Array([9, 10, 11, 12]),
    signature: new Uint8Array([13, 14, 15, 16]),
  };
  return {
    bytes: data[input.attachmentKind],
    mimeType: input.attachmentKind === 'signature' ? 'image/png' : 'image/jpeg',
    source: input.source,
  };
}

function signRuntimeCapture(renderer: import('react-test-renderer').ReactTestRenderer): void {
  act(() => {
    renderer.root.findByProps({ testID: 'capture-signature-field' }).props.onChange(SIGNED);
  });
}

function makePrint() {
  const queue = new printer.PrintJobQueue(new printer.InMemoryPrintJobStore());
  const payloads = new VolatilePrintPayloadStore();
  const outbox: sync.OutboxItem[] = [];
  let seq = 0;
  let uuid = 0;
  const runtime = new PrintRuntime({
    queue,
    payloads,
    transport: {
      kind: 'ble-gatt',
      connect: async () => {
        throw new printer.NotImplementedError('PT-210 native module');
      },
      disconnect: async () => undefined,
      isConnected: () => false,
      writeBytes: async () => undefined,
    },
    enqueueEvent: (envelope) => outbox.push({ envelope, state: 'pending', retryCount: 0 }),
    eventOutcome: (printJobId, event) => printEventOutcomeFromOutbox(outbox, printJobId, event),
    identity: {
      deviceInstanceId: 'devA',
      allocateLocalSeq: () => seq++,
      generateUuid: () => `print-${uuid++}`,
    },
    now: () => new Date('2026-06-10T12:00:00Z'),
  });
  return { runtime, queue, outbox };
}

function makePt210Binding(overrides?: Partial<Pt210NativeBinding>): Pt210NativeBinding & {
  written: Uint8Array[];
} {
  const written: Uint8Array[] = [];
  let connected = false;
  let deviceId: string | undefined;
  const status = (): Pt210Status => ({
    state: connected ? 'connected' : 'disconnected',
    connected,
    ready: connected,
    ...(deviceId !== undefined ? { deviceId } : {}),
  });
  return Object.assign(
    {
      discover: async () => [{ deviceId: 'bt-1', name: 'PT-210', paired: true }],
      connect: async (id: string) => {
        deviceId = id;
        connected = true;
        return status();
      },
      disconnect: async () => {
        connected = false;
        return status();
      },
      isConnected: () => connected,
      status: async () => status(),
      reconnect: async () => {
        connected = true;
        return status();
      },
      writeBytes: async (bytes: Uint8Array) => {
        written.push(bytes);
        return status();
      },
      ...overrides,
    },
    { written },
  );
}

const RICH_ASSIGNMENT: HubAssignment = {
  serviceRequestId: 'sr-9',
  snapshotHash: 'hash-rich',
  latestServerVersion: 'hash-rich',
  snapshot: { srId: 'sr-9' },
  details: {
    customer: { id: 'cust-1', name: 'ACME Oil' },
    lease: { id: 'lease-1', name: 'North Lease' },
    wells: [{ id: 'well-12', leaseId: 'lease-1', name: 'Well 12H' }],
    material: 'Produced water',
    disposalSite: { id: 'disp-1', name: 'SWD 8' },
    vehicle: { id: 'truck-7', name: 'Truck 7' },
    jobType: { id: 'jt-1', name: 'water-haul' },
    workflowRequirements: {
      clockInRequired: true,
      requiredSteps: ['jha'],
    },
  },
};

describe('AssignmentDetailScreen', () => {
  it('renders rich assignment fields, workflow requirements, and snapshot drift markers', () => {
    let renderer: import('react-test-renderer').ReactTestRenderer;
    act(() => {
      renderer = TestRenderer.create(<AssignmentDetailScreen assignment={RICH_ASSIGNMENT} />);
    });

    const text = textOf(renderer!);
    expect(text).toContain('Customer ACME Oil');
    expect(text).toContain('Lease North Lease');
    expect(text).toContain('Wells Well 12H');
    expect(text).toContain('Material Produced water');
    expect(text).toContain('Disposal SWD 8');
    expect(text).toContain('Vehicle Truck 7');
    expect(text).toContain('Job type water-haul');
    expect(text).toContain('Workflow JHA/JSA per SR');
    expect(text).toContain('Snapshot hash-rich');
    expect(text).toContain('Server version hash-rich');
  });

  it('shows clean unknown states for minimal or missing assignments', () => {
    let renderer: import('react-test-renderer').ReactTestRenderer;
    act(() => {
      renderer = TestRenderer.create(<AssignmentDetailScreen assignment={undefined} />);
    });
    expect(textOf(renderer!)).toContain('No assignment selected');

    act(() => {
      renderer!.update(
        <AssignmentDetailScreen
          assignment={{ serviceRequestId: 'sr-min', snapshotHash: 'h-min', snapshot: null }}
        />,
      );
    });
    expect(textOf(renderer!)).toContain('Customer unknown');
    expect(textOf(renderer!)).toContain('Snapshot h-min');
  });

  it('shows the spec-7.6 header: SR request_no, status badge, trailer, and an optional sync state', () => {
    let renderer: import('react-test-renderer').ReactTestRenderer;
    act(() => {
      renderer = TestRenderer.create(
        <AssignmentDetailScreen
          assignment={{
            serviceRequestId: 'sr-7',
            snapshotHash: 'h7',
            snapshot: null,
            details: { requestNo: '2026-000007', status: 'in_progress', trailer: { name: 'T-3' } },
          }}
          syncState="needs-review"
        />,
      );
    });
    const text = textOf(renderer!);
    expect(text).toContain('SR 2026-000007'); // request_no, not the raw id
    expect(text).toContain('in_progress'); // status badge
    expect(text).toContain('Trailer T-3');
    expect(text).toContain('Sync: Needs review'); // display-only read-path surface
  });
});

describe('FieldWorkflowScreen', () => {
  it('keeps field actions locked when the Hub clock gate is locked', () => {
    const { service, forms } = makeWorkflow(LOCKED);
    let renderer: import('react-test-renderer').ReactTestRenderer;
    act(() => {
      renderer = TestRenderer.create(
        <FieldWorkflowScreen
          gate={LOCKED}
          workflow={service}
          forms={forms}
          serviceRequestId="sr-9"
          onSubmitTicket={jest.fn()}
        />,
      );
    });

    expect(textOf(renderer!)).toContain('Field work locked: not-clocked-in');
    press(renderer!, 'pretrip-save');
    expect(textOf(renderer!)).toContain('Locked: not-clocked-in');
    expect(forms.list()).toHaveLength(0);
  });

  it('saves, validates, completes, submits, and renders frozen DVIR evidence', () => {
    const { service, forms } = makeWorkflow();
    let renderer: import('react-test-renderer').ReactTestRenderer;
    act(() => {
      renderer = TestRenderer.create(
        <FieldWorkflowScreen
          gate={UNLOCKED}
          workflow={service}
          forms={forms}
          serviceRequestId="sr-9"
          onSubmitTicket={jest.fn()}
        />,
      );
    });

    press(renderer!, 'pretrip-save');
    expect(forms.get('pre-trip-dvir-sr-9')).toMatchObject({ status: 'draft' });
    press(renderer!, 'pretrip-complete');
    expect(textOf(renderer!)).toContain("DVIR needs the driver's signature");

    changeText(renderer!, 'pretrip-signature', 'sig-pre');
    press(renderer!, 'pretrip-save');
    press(renderer!, 'pretrip-complete');
    expect(forms.get('pre-trip-dvir-sr-9')).toMatchObject({ status: 'completed' });
    press(renderer!, 'pretrip-submit');
    expect(forms.get('pre-trip-dvir-sr-9')).toMatchObject({ status: 'enqueued' });
    press(renderer!, 'pretrip-save');
    expect(textOf(renderer!)).toContain('Frozen: enqueued');
  });

  it('blocks ticket submission until required workflow steps are complete', async () => {
    const submit = jest.fn().mockResolvedValue({ status: 'accepted' });
    const { service, forms } = makeWorkflow();
    let renderer: import('react-test-renderer').ReactTestRenderer;
    act(() => {
      renderer = TestRenderer.create(
        <FieldWorkflowScreen
          gate={UNLOCKED}
          workflow={service}
          forms={forms}
          serviceRequestId="sr-9"
          onSubmitTicket={submit}
        />,
      );
    });

    await pressAsync(renderer!, 'ticket-submit');
    expect(textOf(renderer!)).toContain('Ticket blocked: pre-trip-dvir, jha-jsa');
    expect(submit).not.toHaveBeenCalled();

    changeText(renderer!, 'pretrip-signature', 'sig-pre');
    press(renderer!, 'pretrip-save');
    press(renderer!, 'pretrip-complete');
    changeText(renderer!, 'jha-signature', 'sig-jha');
    press(renderer!, 'jha-save');
    press(renderer!, 'jha-complete');
    await pressAsync(renderer!, 'ticket-submit');
    expect(textOf(renderer!)).toContain('Ticket submitted');
    expect(submit).toHaveBeenCalledTimes(1);
  });

  it('uses assignment workflow requirements to gate ticket submission', async () => {
    const assignments = new VolatileAssignmentStore();
    assignments.putAssignments([RICH_ASSIGNMENT]);
    const submit = jest.fn().mockResolvedValue({ status: 'accepted' });
    const { service, forms } = makeWorkflow(UNLOCKED, () =>
      parseWorkflowRequirementsFromAssignments(assignments.listAssignments(), 'sr-9'),
    );
    let renderer: import('react-test-renderer').ReactTestRenderer;
    act(() => {
      renderer = TestRenderer.create(
        <FieldWorkflowScreen
          gate={UNLOCKED}
          workflow={service}
          forms={forms}
          serviceRequestId="sr-9"
          onSubmitTicket={submit}
        />,
      );
    });

    await pressAsync(renderer!, 'ticket-submit');
    expect(textOf(renderer!)).toContain('Ticket blocked: jha-jsa');
    expect(textOf(renderer!)).not.toContain('Ticket blocked: pre-trip-dvir');

    changeText(renderer!, 'jha-signature', 'sig-jha');
    press(renderer!, 'jha-save');
    press(renderer!, 'jha-complete');
    await pressAsync(renderer!, 'ticket-submit');
    expect(submit).toHaveBeenCalledTimes(1);
  });

  it('refreshes and renders accepted, rejected, and needs-review form outcomes', () => {
    const { service, forms, outcomes } = makeWorkflow();
    let renderer: import('react-test-renderer').ReactTestRenderer;
    act(() => {
      renderer = TestRenderer.create(
        <FieldWorkflowScreen
          gate={UNLOCKED}
          workflow={service}
          forms={forms}
          serviceRequestId="sr-9"
          onSubmitTicket={jest.fn()}
        />,
      );
    });

    changeText(renderer!, 'pretrip-signature', 'sig-pre');
    press(renderer!, 'pretrip-save');
    press(renderer!, 'pretrip-complete');
    press(renderer!, 'pretrip-submit');

    changeText(renderer!, 'jha-signature', 'sig-jha');
    press(renderer!, 'jha-save');
    press(renderer!, 'jha-complete');
    press(renderer!, 'jha-submit');

    changeText(renderer!, 'posttrip-signature', 'sig-post');
    press(renderer!, 'posttrip-save');
    press(renderer!, 'posttrip-complete');
    press(renderer!, 'posttrip-submit');

    outcomes.set(forms.get('pre-trip-dvir-sr-9')!.opId!, { state: 'accepted' });
    outcomes.set(forms.get('jha-jsa-sr-9')!.opId!, {
      state: 'needs-review',
      lastError: 'assignment_changed',
    });
    outcomes.set(forms.get('post-trip-dvir-sr-9')!.opId!, {
      state: 'rejected',
      rejectionCode: 'clock_gate_locked',
    });

    press(renderer!, 'workflow-refresh-outcomes');

    const text = textOf(renderer!);
    expect(text).toContain('status accepted');
    expect(text).toContain('status needs-review (assignment_changed)');
    expect(text).toContain('status rejected (clock_gate_locked)');
    expect(text).toContain('Outcomes accepted 1 review 1 rejected 1');
  });
});

describe('CaptureEvidenceScreen', () => {
  it('captures photos and signatures while showing local preservation and source', async () => {
    const { flow, uploadEngine, blobs, bytes } = makeCapture();
    let renderer: import('react-test-renderer').ReactTestRenderer;
    act(() => {
      renderer = TestRenderer.create(
        <CaptureEvidenceScreen
          capture={flow}
          uploads={uploadEngine}
          blobs={blobs}
          parentType="field-ticket"
          parentId="ft-1"
          captureDevice={fakeCaptureDevice}
        />,
      );
    });

    await pressAsync(renderer!, 'capture-field-ticket-photo');
    signRuntimeCapture(renderer!);
    await pressAsync(renderer!, 'capture-signature');

    expect(blobs.list()).toHaveLength(2);
    expect(blobs.list().every((b) => bytes.has(b.localUri))).toBe(true);
    expect(textOf(renderer!)).toContain('source camera');
    expect(textOf(renderer!)).toContain('source signature-pad');
    expect(textOf(renderer!)).toContain('local saved');
    expect(textOf(renderer!)).toContain('local preserved');
    expect(textOf(renderer!)).toContain('state local-only');
    await expect(bytes.read(blobs.list()[0]!.localUri, 0, 4)).resolves.toEqual(
      new Uint8Array([1, 2, 3, 4]),
    );
    await expect(bytes.read(blobs.list()[1]!.localUri, 0, 4)).resolves.toEqual(
      signatureBytes(SIGNED).slice(0, 4),
    );
    expect(blobs.list()[1]).toMatchObject({
      attachmentKind: 'signature',
      mimeType: 'application/octet-stream',
    });
  });

  it('does not fabricate evidence when the native capture is canceled or unavailable', async () => {
    const { flow, uploadEngine, blobs } = makeCapture();
    let renderer: import('react-test-renderer').ReactTestRenderer;
    act(() => {
      renderer = TestRenderer.create(
        <CaptureEvidenceScreen
          capture={flow}
          uploads={uploadEngine}
          blobs={blobs}
          parentType="field-ticket"
          parentId="ft-1"
          captureDevice={async () => null}
        />,
      );
    });

    await pressAsync(renderer!, 'capture-field-ticket-photo');

    expect(blobs.list()).toHaveLength(0);
    expect(textOf(renderer!)).toContain('Capture canceled or unavailable');
  });

  it('does not fabricate a signature attachment until the driver draws one', async () => {
    const { flow, uploadEngine, blobs } = makeCapture();
    let renderer: import('react-test-renderer').ReactTestRenderer;
    act(() => {
      renderer = TestRenderer.create(
        <CaptureEvidenceScreen
          capture={flow}
          uploads={uploadEngine}
          blobs={blobs}
          parentType="field-ticket"
          parentId="ft-1"
          captureDevice={fakeCaptureDevice}
        />,
      );
    });

    await pressAsync(renderer!, 'capture-signature');

    expect(blobs.list()).toHaveLength(0);
    expect(textOf(renderer!)).toContain('Draw a signature before saving it as evidence');
  });

  it('does not hide needs-review attachment evidence', async () => {
    const { flow, uploadEngine, blobs, linkStates } = makeCapture();
    let renderer: import('react-test-renderer').ReactTestRenderer;
    act(() => {
      renderer = TestRenderer.create(
        <CaptureEvidenceScreen
          capture={flow}
          uploads={uploadEngine}
          blobs={blobs}
          parentType="field-ticket"
          parentId="ft-1"
          linkOutcome={(opId) => linkStates.get(opId)}
          captureDevice={fakeCaptureDevice}
        />,
      );
    });
    await pressAsync(renderer!, 'capture-receipt-photo');
    const record = blobs.list()[0]!;
    blobs.save({ ...record, state: 'uploaded', uploadConfirmed: true, linkOpId: 'link-1' });
    linkStates.set('link-1', 'needs-review');
    press(renderer!, 'capture-refresh');

    expect(textOf(renderer!)).toContain('needs-review');
    expect(blobs.list()).toHaveLength(1);
  });

  it('renders upload, link, failure, and review states without purging local evidence', async () => {
    const { flow, uploadEngine, blobs } = makeCapture();
    let renderer: import('react-test-renderer').ReactTestRenderer;
    act(() => {
      renderer = TestRenderer.create(
        <CaptureEvidenceScreen
          capture={flow}
          uploads={uploadEngine}
          blobs={blobs}
          parentType="field-ticket"
          parentId="ft-1"
          linkOutcome={(opId) => (opId === 'link-review' ? 'needs-review' : undefined)}
          captureDevice={fakeCaptureDevice}
        />,
      );
    });
    await pressAsync(renderer!, 'capture-field-ticket-photo');
    const base = blobs.list()[0]!;
    blobs.save({
      ...base,
      blobId: 'blob-pending',
      attachmentId: 'att-pending',
      state: 'local-only',
    });
    blobs.save({
      ...base,
      blobId: 'blob-uploading',
      attachmentId: 'att-uploading',
      state: 'uploading',
      uploadSessionId: 'sess-1',
      uploadUrl: 'https://hub/uploads/sess-1',
    });
    blobs.save({
      ...base,
      blobId: 'blob-uploaded',
      attachmentId: 'att-uploaded',
      state: 'uploaded',
      uploadConfirmed: true,
    });
    blobs.save({
      ...base,
      blobId: 'blob-linked',
      attachmentId: 'att-linked',
      state: 'linked',
      uploadConfirmed: true,
      linkConfirmed: true,
    });
    blobs.save({
      ...base,
      blobId: 'blob-failed',
      attachmentId: 'att-failed',
      state: 'upload-expired',
    });
    blobs.save({
      ...base,
      blobId: 'blob-review',
      attachmentId: 'att-review',
      state: 'uploaded',
      uploadConfirmed: true,
      linkOpId: 'link-review',
    });

    press(renderer!, 'capture-refresh');

    const text = textOf(renderer!);
    expect(text).toContain('status upload pending');
    expect(text).toContain('status uploading');
    expect(text).toContain('status uploaded');
    expect(text).toContain('status linked');
    expect(text).toContain('status failed');
    expect(text).toContain('status needs-review');
    expect(blobs.list().every((blob) => blob.purgedAt === undefined)).toBe(true);
  });
});

describe('PrintQueueScreen', () => {
  it('shows hardware-not-available and refuses to purge unsynced jobs', async () => {
    const { runtime, queue } = makePrint();
    runtime.enqueueTicketPrint({
      srId: 'sr-9',
      fieldTicketId: 'ft-1',
      payload: new Uint8Array([1, 2, 3]),
    });
    let renderer: import('react-test-renderer').ReactTestRenderer;
    act(() => {
      renderer = TestRenderer.create(<PrintQueueScreen runtime={runtime} queue={queue} />);
    });

    expect(textOf(renderer!)).toContain('status queued');
    await pressAsync(renderer!, 'print-process');
    expect(textOf(renderer!)).toContain('hardware-not-available');
    press(renderer!, 'print-purge');
    expect(queue.list()).toHaveLength(1);
  });

  it('renders queued, printing, printed, failed, canceled, and synced jobs', () => {
    const { runtime, queue } = makePrint();
    const jobs = Array.from({ length: 6 }, (_, index) =>
      runtime.enqueueTicketPrint({
        srId: 'sr-9',
        fieldTicketId: `ft-${index}`,
        payload: new Uint8Array([index + 1, 2, 3]),
      }),
    );
    queue.markPrinting(jobs[1]!.printJobId);
    queue.markPrinted(jobs[2]!.printJobId, '2026-06-10T12:01:00Z');
    queue.markFailed(jobs[3]!.printJobId, 'printer-not-implemented', 'native missing');
    queue.cancel(jobs[4]!.printJobId);
    queue.markPrinted(jobs[5]!.printJobId, '2026-06-10T12:02:00Z');
    queue.markSynced(jobs[5]!.printJobId, '2026-06-10T12:03:00Z');

    let renderer: import('react-test-renderer').ReactTestRenderer;
    act(() => {
      renderer = TestRenderer.create(<PrintQueueScreen runtime={runtime} queue={queue} />);
    });

    const text = textOf(renderer!);
    expect(text).toContain('status queued');
    expect(text).toContain('status printing');
    expect(text).toContain('status printed');
    expect(text).toContain('status failed');
    expect(text).toContain('status canceled');
    expect(text).toContain('status synced');
    expect(text).toContain('hardware-not-available');
  });
});

describe('Pt210DiagnosticScreen', () => {
  it('records discover, connect, test receipt, status, reconnect, and disconnect results', async () => {
    const binding = makePt210Binding();
    let renderer: import('react-test-renderer').ReactTestRenderer;
    act(() => {
      renderer = TestRenderer.create(<Pt210DiagnosticScreen binding={binding} />);
    });

    await pressAsync(renderer!, 'pt210-discover');
    await pressAsync(renderer!, 'pt210-connect');
    await pressAsync(renderer!, 'pt210-test-receipt');
    await pressAsync(renderer!, 'pt210-status');
    await pressAsync(renderer!, 'pt210-reconnect');
    await pressAsync(renderer!, 'pt210-disconnect');

    const text = textOf(renderer!);
    expect(text).toContain('discover ok: PT-210');
    expect(text).toContain('connect ok: connected');
    expect(text).toContain('print test receipt ok');
    expect(text).toContain('status ok: connected');
    expect(text).toContain('reconnect ok: connected');
    expect(text).toContain('disconnect ok: disconnected');
    expect(binding.written).toHaveLength(1);
  });

  it('reports missing native module explicitly instead of faking hardware', async () => {
    let renderer: import('react-test-renderer').ReactTestRenderer;
    act(() => {
      renderer = TestRenderer.create(<Pt210DiagnosticScreen binding={undefined} />);
    });

    await pressAsync(renderer!, 'pt210-discover');

    expect(textOf(renderer!)).toContain('printer-not-implemented');
  });

  it('shows explicit native permission errors in the diagnostic log', async () => {
    const binding = makePt210Binding({
      discover: async () => {
        throw Object.assign(new Error('BLUETOOTH_SCAN permission is required'), {
          code: 'ERR_PT210_PERMISSION_DENIED',
        });
      },
    });
    let renderer: import('react-test-renderer').ReactTestRenderer;
    act(() => {
      renderer = TestRenderer.create(<Pt210DiagnosticScreen binding={binding} />);
    });

    await pressAsync(renderer!, 'pt210-discover');

    expect(textOf(renderer!)).toContain('permission-denied');
    expect(textOf(renderer!)).toContain('ERR_PT210_PERMISSION_DENIED');
  });
});

describe('AssignmentInboxScreen', () => {
  const INBOX_ASSIGNMENTS: HubAssignment[] = [
    {
      serviceRequestId: 'sr-1',
      snapshotHash: 'h1',
      snapshot: null,
      details: {
        requestNo: '2026-000001',
        status: 'assigned',
        customer: { name: 'Acme Energy' },
        trailer: { name: 'Trailer 3' },
      },
    },
    {
      serviceRequestId: 'sr-2',
      snapshotHash: 'h2',
      snapshot: null,
      details: { status: 'on_hold' },
    },
    {
      serviceRequestId: 'sr-3',
      snapshotHash: 'h3',
      snapshot: null,
      details: { status: 'in_progress' },
    },
  ];
  const SYNC = new Map<string, SrSyncState>([
    ['sr-1', 'needs-sync'],
    ['sr-3', 'needs-review'],
  ]);

  function renderInbox(filter: InboxFilter, onSelectFilter: (f: InboxFilter) => void = () => {}) {
    let renderer: import('react-test-renderer').ReactTestRenderer;
    act(() => {
      renderer = TestRenderer.create(
        <AssignmentInboxScreen
          assignments={INBOX_ASSIGNMENTS}
          syncStateById={SYNC}
          selectedFilter={filter}
          onSelectFilter={onSelectFilter}
        />,
      );
    });
    return renderer!;
  }

  it('all-cached shows every card with SR number, status, customer, trailer, and sync state', () => {
    const text = textOf(renderInbox('all-cached'));
    expect(text).toContain('SR 2026-000001');
    expect(text).toContain('Acme Energy');
    expect(text).toContain('Trailer 3');
    expect(text).toContain('Last sync: Needs sync'); // sr-1
    expect(text).toContain('Last sync: Needs review'); // sr-3
    expect(text).toContain('Last sync: Not started'); // sr-2 has no local work
  });

  it('chips carry per-filter counts', () => {
    const text = textOf(renderInbox('all-cached'));
    expect(text).toContain('All cached (3)');
    expect(text).toContain('Needs review (1)');
    expect(text).toContain('On hold (1)');
  });

  it('the needs-review filter shows only the rejected/needs-review SR', () => {
    const renderer = renderInbox('needs-review');
    expect(renderer.root.findByProps({ testID: 'assignment-card-sr-3' })).toBeTruthy();
    expect(renderer.root.findAllByProps({ testID: 'assignment-card-sr-1' })).toHaveLength(0);
  });

  it('on-hold filter isolates dispatcher-paused SRs', () => {
    const renderer = renderInbox('on-hold');
    expect(renderer.root.findByProps({ testID: 'assignment-card-sr-2' })).toBeTruthy();
    expect(renderer.root.findAllByProps({ testID: 'assignment-card-sr-3' })).toHaveLength(0);
  });

  it('shows an empty state when no assignment matches the filter', () => {
    // completed-locally needs a 'synced' SR; none here.
    expect(textOf(renderInbox('completed-locally'))).toContain('No assignments in this view');
  });

  it('pressing a filter chip reports the selection to the caller', () => {
    let picked: InboxFilter | undefined;
    const renderer = renderInbox('all-cached', (f: InboxFilter) => (picked = f));
    act(() => {
      renderer.root.findByProps({ testID: 'filter-needs-sync' }).props.onPress();
    });
    expect(picked).toBe('needs-sync');
  });
});

describe('TicketCaptureScreen (draft store goes write-live)', () => {
  function makeDraftStore(): FieldTicketDraftStore & { rows: Map<string, FieldTicketDraft> } {
    const rows = new Map<string, FieldTicketDraft>();
    return {
      durability: 'volatile-memory',
      rows,
      save: (draft) => rows.set(draft.id, draft),
      get: (id) => rows.get(id),
      list: () => [...rows.values()],
      delete: (id) => void rows.delete(id),
    };
  }
  const identity = { generateUuid: () => 'draft-uuid-1' };
  const now = () => new Date('2026-06-15T12:00:00.000Z');

  function render(
    store: FieldTicketDraftStore,
    opts?: { gate?: FieldWorkGate; requestNo?: string; driverName?: string },
  ) {
    let renderer: import('react-test-renderer').ReactTestRenderer;
    act(() => {
      renderer = TestRenderer.create(
        <TicketCaptureScreen
          draftStore={store}
          serviceRequestId="sr-1"
          // The SR's human request number IS the ticket number; the driver is never typed.
          requestNo={opts?.requestNo ?? '2026-000001'}
          {...(opts?.driverName ? { driverName: opts.driverName } : {})}
          identity={identity}
          now={now}
          {...(opts?.gate ? { gate: opts.gate } : {})}
        />,
      );
    });
    return renderer!;
  }

  it('derives the ticket number from the SR request number (no manual entry)', () => {
    const store = makeDraftStore();
    const renderer = render(store, { requestNo: '2026-000077' });
    // The SR number is shown as the ticket id; there is no ticket-no / driver input to type into.
    expect(textOf(renderer)).toContain('Field ticket · SR 2026-000077');
    expect(renderer.root.findAllByProps({ testID: 'ticket-no-input' })).toHaveLength(0);
    expect(renderer.root.findAllByProps({ testID: 'ticket-driver-input' })).toHaveLength(0);

    changeText(renderer, 'ticket-qty-input', '80');
    changeText(renderer, 'ticket-disposal-input', 'D-9');
    press(renderer, 'ticket-save');

    expect(store.list()).toEqual([
      {
        id: 'draft-uuid-1',
        serviceRequestId: 'sr-1',
        ticketNo: '2026-000077', // the SR number, not a typed value — submit/contract path unchanged
        quantityBbl: 80,
        disposalTicketNo: 'D-9',
        captureMethod: 'digital',
        createdAt: '2026-06-15T12:00:00.000Z',
        updatedAt: '2026-06-15T12:00:00.000Z',
      },
    ]);
    expect(textOf(renderer)).toContain('Ticket draft saved');
  });

  it('populates driver from the authenticated session, not a visible field', () => {
    const store = makeDraftStore();
    const renderer = render(store, { requestNo: '2026-000088', driverName: 'arivera' });
    changeText(renderer, 'ticket-qty-input', '120');
    changeText(renderer, 'ticket-truck-input', 'Truck 7');
    changeText(renderer, 'ticket-trailer-input', 'Trailer 3');
    changeText(renderer, 'ticket-notes-input', 'gate code 4821');
    press(renderer, 'ticket-capture-paper');
    press(renderer, 'ticket-save');

    expect(store.list()[0]).toMatchObject({
      ticketNo: '2026-000088',
      quantityBbl: 120,
      truck: 'Truck 7',
      trailer: 'Trailer 3',
      driver: 'arivera', // from the session identity, never typed
      notes: 'gate code 4821',
      captureMethod: 'paper',
    });
  });

  it('loads an existing draft for the SR on mount and upserts (no duplicate row)', () => {
    const store = makeDraftStore();
    store.save({
      id: 'existing-1',
      serviceRequestId: 'sr-1',
      ticketNo: 'T-1',
      quantityBbl: 10,
      disposalTicketNo: 'D-1',
      createdAt: '2026-06-14T00:00:00.000Z',
      updatedAt: '2026-06-14T00:00:00.000Z',
    });
    const renderer = render(store, { requestNo: '2026-000001' });
    changeText(renderer, 'ticket-qty-input', '25');
    press(renderer, 'ticket-save');

    expect(store.list()).toHaveLength(1);
    expect(store.get('existing-1')).toMatchObject({
      quantityBbl: 25,
      ticketNo: '2026-000001', // ticket id always tracks the SR number
      createdAt: '2026-06-14T00:00:00.000Z', // preserved
      updatedAt: '2026-06-15T12:00:00.000Z', // bumped
    });
  });

  it('rejects a negative quantity without writing', () => {
    const store = makeDraftStore();
    const renderer = render(store);
    changeText(renderer, 'ticket-qty-input', '-3');
    press(renderer, 'ticket-save');
    expect(textOf(renderer)).toContain('Quantity must be a non-negative number');
    expect(store.list()).toHaveLength(0);
  });

  it('a locked clock gate blocks authoring (no write)', () => {
    const store = makeDraftStore();
    const renderer = render(store, { gate: LOCKED });
    changeText(renderer, 'ticket-qty-input', '5');
    press(renderer, 'ticket-save');
    expect(textOf(renderer)).toContain('Field work is locked: not-clocked-in');
    expect(store.list()).toHaveLength(0);
  });

  it('deletes the draft and clears the form', () => {
    const store = makeDraftStore();
    const renderer = render(store);
    changeText(renderer, 'ticket-qty-input', '80');
    press(renderer, 'ticket-save');
    expect(store.list()).toHaveLength(1);
    press(renderer, 'ticket-delete');
    expect(store.list()).toHaveLength(0);
    expect(textOf(renderer)).toContain('Draft deleted');
  });
});

describe('SyncCenterScreen (spec 7.15 — plain-language visibility)', () => {
  it('renders every category with its plain-language label and count + last Hub contact', () => {
    const summary = summarizeSyncCenter({
      draftCount: 1,
      evidence: [{ state: 'pending' }, { state: 'needs-review' }, { state: 'accepted' }],
    });
    let renderer: import('react-test-renderer').ReactTestRenderer;
    act(() => {
      renderer = TestRenderer.create(
        <SyncCenterScreen summary={summary} lastHubContactLabel="2 minutes ago" />,
      );
    });
    const text = textOf(renderer!);
    expect(text).toContain('Saved on this phone: 1');
    expect(text).toContain('Waiting to sync: 1');
    expect(text).toContain('Needs office review: 1');
    expect(text).toContain('Accepted by Hub: 1');
    expect(text).toContain('Last Hub contact: 2 minutes ago');
  });

  it('offers Retry all only when work is outstanding, and reports the press', () => {
    let retried = false;
    const summary = summarizeSyncCenter({ draftCount: 0, evidence: [{ state: 'pending' }] });
    let renderer: import('react-test-renderer').ReactTestRenderer;
    act(() => {
      renderer = TestRenderer.create(
        <SyncCenterScreen summary={summary} onRetryAll={() => (retried = true)} />,
      );
    });
    press(renderer!, 'sync-retry-all');
    expect(retried).toBe(true);
  });

  it('shows an all-clear message (no Retry) when everything is Hub-accepted', () => {
    const summary = summarizeSyncCenter({ draftCount: 0, evidence: [{ state: 'accepted' }] });
    let renderer: import('react-test-renderer').ReactTestRenderer;
    act(() => {
      renderer = TestRenderer.create(<SyncCenterScreen summary={summary} onRetryAll={() => {}} />);
    });
    expect(textOf(renderer!)).toContain('All work is accepted by Hub');
    expect(renderer!.root.findAllByProps({ testID: 'sync-retry-all' })).toHaveLength(0);
  });
});

describe('ReceiptCaptureScreen (the receipt half of the 7.10 package)', () => {
  const identity = { generateUuid: () => 'rcpt-uuid-1' };
  const now = () => new Date('2026-06-15T12:00:00.000Z');

  function render(store: VolatileReceiptDraftStore, gate?: FieldWorkGate, ticketDraftId?: string) {
    let renderer: import('react-test-renderer').ReactTestRenderer;
    act(() => {
      renderer = TestRenderer.create(
        <ReceiptCaptureScreen
          receiptStore={store}
          serviceRequestId="sr-1"
          identity={identity}
          now={now}
          {...(gate ? { gate } : {})}
          {...(ticketDraftId ? { ticketDraftId } : {})}
        />,
      );
    });
    return renderer!;
  }

  it('saves a receipt with the chosen type and the linked ticket draft', () => {
    const store = new VolatileReceiptDraftStore();
    const renderer = render(store, undefined, 'draft-9');
    press(renderer, 'receipt-type-fuel');
    changeText(renderer, 'receipt-vendor-input', 'Pilot');
    changeText(renderer, 'receipt-amount-input', '120.5');
    changeText(renderer, 'receipt-no-input', 'R-7');
    press(renderer, 'receipt-save');

    expect(store.list()).toEqual([
      {
        id: 'rcpt-uuid-1',
        serviceRequestId: 'sr-1',
        receiptType: 'fuel',
        vendor: 'Pilot',
        receiptNo: 'R-7',
        amount: 120.5,
        notes: '',
        ticketDraftId: 'draft-9',
        createdAt: '2026-06-15T12:00:00.000Z',
        updatedAt: '2026-06-15T12:00:00.000Z',
      },
    ]);
    expect(textOf(renderer)).toContain('Receipt draft saved');
  });

  it('requires a vendor and a non-negative amount before writing', () => {
    const store = new VolatileReceiptDraftStore();
    const renderer = render(store);
    press(renderer, 'receipt-save');
    expect(textOf(renderer)).toContain('Vendor is required');
    changeText(renderer, 'receipt-vendor-input', 'SWD 8');
    changeText(renderer, 'receipt-amount-input', '-1');
    press(renderer, 'receipt-save');
    expect(textOf(renderer)).toContain('Amount must be a non-negative number');
    expect(store.list()).toHaveLength(0);
  });

  it('a locked clock gate blocks authoring (no write)', () => {
    const store = new VolatileReceiptDraftStore();
    const renderer = render(store, LOCKED);
    changeText(renderer, 'receipt-vendor-input', 'SWD 8');
    changeText(renderer, 'receipt-amount-input', '10');
    press(renderer, 'receipt-save');
    expect(textOf(renderer)).toContain('Field work is locked: not-clocked-in');
    expect(store.list()).toHaveLength(0);
  });
});

describe('MoreScreen (settings / about)', () => {
  it('shows Hub env + read-only URL + storage durability + the offline/sign-out copy', () => {
    let renderer: import('react-test-renderer').ReactTestRenderer;
    act(() => {
      renderer = TestRenderer.create(
        <MoreScreen
          appEnv="dev"
          hubUrl="http://192.168.1.149:8000"
          durability="durable-encrypted"
          appVersion="1.0.0"
          onSignOut={() => {}}
        />,
      );
    });
    const text = textOf(renderer!);
    expect(text).toContain('Hub environment: dev');
    expect(text).toContain('Hub URL: http://192.168.1.149:8000');
    expect(text).toContain('durable-encrypted');
    expect(text).toContain('Version: 1.0.0');
    expect(text).toContain('never lost or auto-deleted');
    expect(text).toContain('keeps your unsynced work safe');
  });

  it('reports a missing Hub URL plainly and fires sign-out', () => {
    let signedOut = false;
    let renderer: import('react-test-renderer').ReactTestRenderer;
    act(() => {
      renderer = TestRenderer.create(
        <MoreScreen
          appEnv="dev"
          hubUrl={null}
          durability="durable-plain"
          onSignOut={() => {
            signedOut = true;
          }}
        />,
      );
    });
    expect(textOf(renderer!)).toContain('Hub URL: not configured');
    press(renderer!, 'more-sign-out');
    expect(signedOut).toBe(true);
  });
});

describe('TodayScreen (priority ladder)', () => {
  const ASSIGNMENTS: HubAssignment[] = [
    {
      serviceRequestId: 'sr-hold',
      snapshotHash: 'h',
      snapshot: null,
      details: { status: 'on_hold' },
    },
    {
      serviceRequestId: 'sr-review',
      snapshotHash: 'h',
      snapshot: null,
      details: { requestNo: '2026-7', status: 'in_progress' },
    },
  ];
  const SYNC = new Map<string, SrSyncState>([['sr-review', 'needs-review']]);

  it('summarizes the day and lists the highest-priority SR first', () => {
    let renderer: import('react-test-renderer').ReactTestRenderer;
    act(() => {
      renderer = TestRenderer.create(
        <TodayScreen assignments={ASSIGNMENTS} syncStateById={SYNC} />,
      );
    });
    const text = textOf(renderer!);
    expect(text).toContain('2 assignments · 1 need review');
    // needs-review SR card appears before the on-hold one in the rendered output.
    expect(text.indexOf('SR 2026-7')).toBeLessThan(text.indexOf('SR sr-hold'));
  });

  it('shows an empty state with no assignments', () => {
    let renderer: import('react-test-renderer').ReactTestRenderer;
    act(() => {
      renderer = TestRenderer.create(<TodayScreen assignments={[]} syncStateById={new Map()} />);
    });
    expect(textOf(renderer!)).toContain('No assignments today');
  });
});

describe('LocationValidationScreen (validation-only GPS)', () => {
  const identity = { generateUuid: () => 'loc-uuid-1' };
  const now = () => new Date('2026-06-15T12:00:00.000Z');
  const expectedArea = { lat: 31.5, lon: -102.1, radiusM: 250 };
  const gpsAt = (lat: number, lon: number) => ({
    lat,
    lon,
    accuracyM: 5,
    timestampMs: 1_750_000_000_000,
  });

  function render(
    store: VolatileLocationEvidenceStore,
    captureGps: () => Promise<unknown>,
    gate?: FieldWorkGate,
  ) {
    let renderer: import('react-test-renderer').ReactTestRenderer;
    act(() => {
      renderer = TestRenderer.create(
        <LocationValidationScreen
          locationStore={store}
          serviceRequestId="sr-1"
          {...(gate !== undefined ? { gate } : {})}
          expectedArea={expectedArea}
          captureGps={captureGps as () => Promise<never>}
          identity={identity}
          now={now}
        />,
      );
    });
    return renderer!;
  }

  it('a GPS fix inside the geofence saves verified evidence', async () => {
    const store = new VolatileLocationEvidenceStore();
    const renderer = render(store, async () => gpsAt(31.5, -102.1));
    await pressAsync(renderer, 'location-capture');
    expect(store.list()).toHaveLength(1);
    expect(store.get('loc-uuid-1')).toMatchObject({ state: 'verified', placeKind: 'well-site' });
    expect(textOf(renderer)).toContain('Location evidence saved: verified');
  });

  it('a fix outside the geofence saves outside-expected-area (never faked verified)', async () => {
    const store = new VolatileLocationEvidenceStore();
    const renderer = render(store, async () => gpsAt(32.5, -102.1));
    await pressAsync(renderer, 'location-capture');
    expect(store.get('loc-uuid-1')?.state).toBe('outside-expected-area');
  });

  it('a failed GPS fix saves gps-unavailable, not a guess', async () => {
    const store = new VolatileLocationEvidenceStore();
    const renderer = render(store, async () => null);
    await pressAsync(renderer, 'location-capture');
    expect(store.get('loc-uuid-1')?.state).toBe('gps-unavailable');
  });

  it('manual save records unverified/manual-only evidence for an unknown place', () => {
    const store = new VolatileLocationEvidenceStore();
    const renderer = render(store, async () => null);
    press(renderer, 'location-place-other');
    press(renderer, 'location-manual');
    expect(store.get('loc-uuid-1')).toMatchObject({ state: 'manual-only', placeKind: 'other' });
  });

  it('keeps location capture non-actionable while the field gate is locked', async () => {
    const store = new VolatileLocationEvidenceStore();
    const captureGps = jest.fn().mockResolvedValue(gpsAt(31.5, -102.1));
    const renderer = render(store, captureGps, LOCKED);

    await pressAsync(renderer, 'location-capture');

    expect(captureGps).not.toHaveBeenCalled();
    expect(store.list()).toHaveLength(0);
    expect(textOf(renderer)).toContain('Field work is locked: not-clocked-in');
  });
});
