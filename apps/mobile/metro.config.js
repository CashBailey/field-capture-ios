// Metro config for the Field Capture monorepo.
// Lets the app resolve the shared `@fieldcapture/contracts` workspace package and the
// hoisted root node_modules under bare React Native.
const { getDefaultConfig, mergeConfig } = require('@react-native/metro-config');
const path = require('path');

const projectRoot = __dirname;
const monorepoRoot = path.resolve(projectRoot, '../..');

module.exports = mergeConfig(getDefaultConfig(projectRoot), {
  watchFolders: [monorepoRoot],
  resolver: {
    nodeModulesPaths: [
      path.resolve(projectRoot, 'node_modules'),
      path.resolve(monorepoRoot, 'node_modules'),
    ],
  },
});
