export const PROVIDER_PRESETS = {
  custom: {
    provider: "custom",
    providerName: "Custom OpenAI Compatible Provider",
    wireApi: "responses",
  },
};

export function listProviderPresets() {
  return Object.keys(PROVIDER_PRESETS);
}

export function resolveProviderPreset(name) {
  if (!name) return {};
  const preset = PROVIDER_PRESETS[String(name).trim().toLowerCase()];
  if (!preset) {
    throw new Error(`Unknown preset: ${name}. Available presets: ${listProviderPresets().join(", ")}`);
  }
  return preset;
}
