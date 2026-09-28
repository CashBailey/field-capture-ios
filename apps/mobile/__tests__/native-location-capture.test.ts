import { captureValidationGps } from '../src/adapters/device/NativeLocationCapture';

function geolocation(input: {
  permission?: 'granted' | 'denied';
  fix?: {
    latitude: number;
    longitude: number;
    accuracy: number | null;
    timestamp: number;
  };
  failFix?: boolean;
}) {
  return {
    requestAuthorization: jest.fn((success?: () => void, error?: () => void) => {
      if (input.permission === 'denied') error?.();
      else success?.();
    }),
    getCurrentPosition: jest.fn((success, error) => {
      if (input.failFix) {
        error?.({ code: 2, message: 'location unavailable' });
        return;
      }
      const fix = input.fix ?? {
        latitude: 31.5,
        longitude: -102.1,
        accuracy: 8,
        timestamp: 1_782_223_600_000,
      };
      success({
        coords: {
          latitude: fix.latitude,
          longitude: fix.longitude,
          accuracy: fix.accuracy,
          altitude: null,
          heading: null,
          speed: null,
          altitudeAccuracy: null,
        },
        timestamp: fix.timestamp,
      });
    }),
  };
}

describe('captureValidationGps', () => {
  it('captures one foreground GPS fix for validation evidence', async () => {
    const geo = geolocation({
      fix: {
        latitude: 31.5,
        longitude: -102.1,
        accuracy: 8,
        timestamp: 1_782_223_600_000,
      },
    });

    await expect(captureValidationGps(geo)).resolves.toEqual({
      lat: 31.5,
      lon: -102.1,
      accuracyM: 8,
      timestampMs: 1_782_223_600_000,
    });
    expect(geo.getCurrentPosition).toHaveBeenCalledWith(
      expect.any(Function),
      expect.any(Function),
      expect.objectContaining({ enableHighAccuracy: false, maximumAge: 0 }),
    );
  });

  it('returns null when foreground permission is denied', async () => {
    const geo = geolocation({ permission: 'denied' });

    await expect(captureValidationGps(geo)).resolves.toBeNull();
    expect(geo.getCurrentPosition).not.toHaveBeenCalled();
  });

  it('returns null instead of fabricating GPS when the native fix fails', async () => {
    const geo = geolocation({ failFix: true });

    await expect(captureValidationGps(geo)).resolves.toBeNull();
  });
});
