export const PTY_COMPATIBILITY_PROFILES = Object.freeze({
  claude: Object.freeze({
    id: 'claude-pty',
    displayName: 'Claude CLI',
    launchArgs: Object.freeze([]),
    startupTimeoutMs: 20_000,
    completionSettleMs: 650,
    readyPatterns: Object.freeze([
      /Claude Code/i,
      /(?:^|\n)\s*[>❯]\s*$/,
    ]),
    promptPatterns: Object.freeze([
      /(?:^|\n)\s*[>❯]\s*$/,
    ]),
    inputMode: 'bracketed-paste',
  }),
});

export function ptyCompatibilityProfile(adapterId, profiles = PTY_COMPATIBILITY_PROFILES) {
  return profiles[adapterId] || null;
}
