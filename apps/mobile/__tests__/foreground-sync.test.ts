/**
 * Foreground sync trigger: fires a sync kick only on a real background/inactive -> active
 * transition, once per return, never on mount-while-active. RN-agnostic (fake AppState seam).
 */
import { subscribeForegroundSync, type AppStateLike } from '../src/runtime';

function fakeAppState() {
  let handler: ((s: string) => void) | undefined;
  let removed = false;
  const appState: AppStateLike = {
    addEventListener: (_type, h) => {
      handler = h;
      return {
        remove: () => {
          removed = true;
        },
      };
    },
  };
  return { appState, emit: (s: string) => handler?.(s), isRemoved: () => removed };
}

describe('subscribeForegroundSync', () => {
  it('fires when the app returns to the foreground (background -> active)', () => {
    const f = fakeAppState();
    const onForeground = jest.fn();
    subscribeForegroundSync(f.appState, onForeground, 'active');
    f.emit('inactive');
    f.emit('background');
    expect(onForeground).not.toHaveBeenCalled();
    f.emit('active');
    expect(onForeground).toHaveBeenCalledTimes(1);
  });

  it('does not fire on mount-while-active nor on a redundant active->active', () => {
    const f = fakeAppState();
    const onForeground = jest.fn();
    subscribeForegroundSync(f.appState, onForeground, 'active');
    f.emit('active');
    expect(onForeground).not.toHaveBeenCalled();
  });

  it('fires once per foreground return across multiple cycles', () => {
    const f = fakeAppState();
    const onForeground = jest.fn();
    subscribeForegroundSync(f.appState, onForeground, 'active');
    f.emit('background');
    f.emit('active'); // return 1
    f.emit('inactive');
    f.emit('active'); // return 2
    expect(onForeground).toHaveBeenCalledTimes(2);
  });

  it('a cold start in the background fires on the first activation', () => {
    const f = fakeAppState();
    const onForeground = jest.fn();
    subscribeForegroundSync(f.appState, onForeground, 'background');
    f.emit('active');
    expect(onForeground).toHaveBeenCalledTimes(1);
  });

  it('unsubscribe removes the native listener', () => {
    const f = fakeAppState();
    const unsubscribe = subscribeForegroundSync(f.appState, () => undefined, 'active');
    unsubscribe();
    expect(f.isRemoved()).toBe(true);
  });
});
