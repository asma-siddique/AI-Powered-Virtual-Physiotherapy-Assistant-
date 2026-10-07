/// Base URL of the PhysioAI API. Override at build time with
/// `--dart-define=API_BASE_URL=https://.../api/v1`.
const apiBaseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'http://localhost:8000/api/v1',
);
