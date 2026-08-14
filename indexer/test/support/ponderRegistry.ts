/**
 * Test stand-in for the `ponder:registry` virtual module (aliased in
 * vitest.config.ts). `ponder.on` records handlers into a map instead of
 * registering them with the ponder runtime; tests replay decoded events
 * through the recorded handlers via `getHandler`.
 */

export type RecordedHandler = (args: { event: unknown; context: unknown }) => Promise<void>;

const handlers = new Map<string, RecordedHandler>();

export const ponder = {
  on(name: string, fn: RecordedHandler): void {
    handlers.set(name, fn);
  },
};

export function getHandler(name: string): RecordedHandler {
  const handler = handlers.get(name);
  if (!handler) {
    throw new Error(`no handler recorded for "${name}" — did the src module get imported?`);
  }
  return handler;
}

export function recordedHandlerNames(): string[] {
  return [...handlers.keys()];
}
