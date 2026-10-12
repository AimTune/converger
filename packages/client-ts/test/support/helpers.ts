export async function waitFor<T>(
  check: () => T | undefined | null | false,
  { timeout = 5_000, interval = 10, message = "condition" }: { timeout?: number; interval?: number; message?: string } = {},
): Promise<T> {
  const started = Date.now();
  for (;;) {
    const value = check();
    if (value) return value;
    if (Date.now() - started > timeout) throw new Error(`timed out waiting for ${message}`);
    await new Promise((resolve) => setTimeout(resolve, interval));
  }
}

export function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
