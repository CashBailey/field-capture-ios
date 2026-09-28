import Geolocation, {
  type GeolocationError,
  type GeolocationOptions,
  type GeolocationResponse,
} from '@react-native-community/geolocation';
import type { fieldwork } from '@fieldcapture/contracts';

interface GeolocationLike {
  requestAuthorization(success?: () => void, error?: (error: GeolocationError) => void): void;
  getCurrentPosition(
    success: (position: GeolocationResponse) => void,
    error?: (error: GeolocationError) => void,
    options?: GeolocationOptions,
  ): void;
}

function requestForegroundPermission(geo: GeolocationLike): Promise<boolean> {
  return new Promise((resolve) => {
    try {
      geo.requestAuthorization(
        () => resolve(true),
        () => resolve(false),
      );
    } catch {
      resolve(false);
    }
  });
}

function getCurrentPosition(geo: GeolocationLike): Promise<GeolocationResponse> {
  return new Promise((resolve, reject) => {
    geo.getCurrentPosition(resolve, reject, {
      enableHighAccuracy: false,
      maximumAge: 0,
      timeout: 15_000,
    });
  });
}

/**
 * Capture one foreground GPS fix for validation evidence. This is intentionally not a tracker:
 * no watchPosition, no background task, no geofencing, and no map dependency.
 */
export async function captureValidationGps(
  geolocation: GeolocationLike = Geolocation,
): Promise<fieldwork.LocationGpsPoint | null> {
  try {
    const granted = await requestForegroundPermission(geolocation);
    if (!granted) return null;

    const fix = await getCurrentPosition(geolocation);
    return {
      lat: fix.coords.latitude,
      lon: fix.coords.longitude,
      accuracyM: Math.max(0, fix.coords.accuracy ?? 0),
      timestampMs: fix.timestamp,
    };
  } catch {
    return null;
  }
}
