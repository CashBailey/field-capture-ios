// Flat ESLint config for the Field Capture bare React Native app. Run: `npm run lint`.
const { defineConfig } = require('eslint/config');
const reactNativeConfig = require('@react-native/eslint-config/flat');

module.exports = defineConfig([
  ...reactNativeConfig,
  {
    files: ['**/*.js'],
    rules: {
      'ft-flow/define-flow-type': 'off',
      'ft-flow/use-flow-type': 'off',
    },
  },
  {
    files: ['jest.setup.js'],
    languageOptions: {
      globals: {
        jest: 'readonly',
      },
    },
  },
  {
    ignores: ['dist/*'],
  },
]);
