import { printer } from '@fieldcapture/contracts';

describe('Field Capture foundation (Slice 0)', () => {
  it('runs the React Native test runner', () => {
    expect(1 + 1).toBe(2);
  });

  it('resolves the @fieldcapture/contracts workspace package at runtime (value import)', () => {
    // A real value import (not `import type`) — proves Metro/Jest can bundle the shared package,
    // which the .js-suffixed specifiers used to break. Regression guard for that landmine.
    expect(typeof printer.NotImplementedError).toBe('function');
  });
});
