jest.mock('react-native-keychain', () => {
  const store = new Map();
  return {
    ACCESSIBLE: {
      AFTER_FIRST_UNLOCK_THIS_DEVICE_ONLY: 'AccessibleAfterFirstUnlockThisDeviceOnly',
    },
    getGenericPassword: jest.fn(async ({ service } = {}) => {
      const value = store.get(service ?? 'default');
      return value === undefined ? false : { username: 'fieldcapture', password: value };
    }),
    setGenericPassword: jest.fn(async (_username, password, { service } = {}) => {
      store.set(service ?? 'default', password);
      return { service: service ?? 'default', storage: 'mock' };
    }),
    resetGenericPassword: jest.fn(async ({ service } = {}) => {
      store.delete(service ?? 'default');
      return true;
    }),
  };
});

jest.mock('react-native-fs', () => ({
  DocumentDirectoryPath: '/tmp/fieldcapture-documents',
  mkdir: jest.fn(async () => undefined),
  writeFile: jest.fn(async () => undefined),
  readFile: jest.fn(async () => ''),
  unlink: jest.fn(async () => undefined),
  exists: jest.fn(async () => true),
}));

jest.mock('react-native-quick-sqlite', () => ({
  QuickSQLite: {
    open: jest.fn(),
    close: jest.fn(),
    delete: jest.fn(),
    execute: jest.fn(() => ({
      rowsAffected: 0,
      rows: { _array: [], length: 0, item: () => undefined },
    })),
  },
}));

jest.mock('@react-native-community/geolocation', () => ({
  __esModule: true,
  default: {
    requestAuthorization: jest.fn((success) => success?.()),
    getCurrentPosition: jest.fn(),
  },
}));

jest.mock('react-native-image-picker', () => ({
  launchCamera: jest.fn(),
  launchImageLibrary: jest.fn(),
}));
