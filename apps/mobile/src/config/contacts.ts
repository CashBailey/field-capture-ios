/**
 * On-duty dispatcher contact + OS dialing helpers. Single source of truth so every "Call Dispatch"
 * button across the app actually rings the same number instead of being a dead handler.
 *
 * TODO(hub): these are placeholder numbers; the real on-duty dispatcher / supervisor numbers should
 * come from the Hub (per shift) once that slice lands.
 */
import { Linking } from 'react-native';

export const DISPATCH_PHONE = '4325550100';
export const SUPERVISOR_PHONE = '4325550123';

/** Place a phone call via the OS dialer. */
export function callNumber(phone: string): void {
  void Linking.openURL(`tel:${phone}`).catch(() => undefined);
}

/** Call the on-duty dispatcher. */
export function callDispatch(): void {
  callNumber(DISPATCH_PHONE);
}
