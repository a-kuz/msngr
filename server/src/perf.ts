/// Dev-only measurement of what one object invocation costs: storage
/// operations and the records they touch, subrequests to other objects. Off
/// unless PERF_LOG is set; the wrappers are never installed then.
///
/// One line per invocation goes to the worker log as `PERF {json}`, so a run
/// can be read back from the wrangler dev output without a side channel.

export interface PerfCounters {
  /// storage.list calls and the records they returned
  lists: number;
  listed: number;
  gets: number;
  got: number;
  puts: number;
  putKeys: number;
  deletes: number;
  /// storage time, ms
  storageMs: number;
  /// fetches to other durable objects
  sub: number;
  subMs: number;
  /// frames written to client sockets, and their size
  outFrames: number;
  outBytes: number;
}

export function newCounters(): PerfCounters {
  return {
    lists: 0, listed: 0, gets: 0, got: 0, puts: 0, putKeys: 0, deletes: 0,
    storageMs: 0, sub: 0, subMs: 0, outFrames: 0, outBytes: 0,
  };
}

export function diff(a: PerfCounters, b: PerfCounters): PerfCounters {
  const out = newCounters();
  for (const k of Object.keys(out) as Array<keyof PerfCounters>) out[k] = a[k] - b[k];
  return out;
}

export function snapshot(c: PerfCounters): PerfCounters {
  return { ...c };
}

/// Counts the storage traffic of one object. `list` is counted by the records it
/// returned, which is what a page of the journal actually costs.
function wrapStorage(storage: DurableObjectStorage, c: PerfCounters): DurableObjectStorage {
  return new Proxy(storage, {
    get(target, prop, receiver) {
      const value = Reflect.get(target, prop, target);
      if (typeof value !== "function") return value;
      const name = String(prop);
      return async (...args: unknown[]) => {
        const t0 = Date.now();
        const result = await (value as (...a: unknown[]) => Promise<unknown>).apply(target, args);
        c.storageMs += Date.now() - t0;
        if (name === "list") {
          c.lists++;
          c.listed += (result as Map<string, unknown>)?.size ?? 0;
        } else if (name === "get") {
          c.gets++;
          c.got += result instanceof Map ? result.size : result === undefined ? 0 : 1;
        } else if (name === "put") {
          c.puts++;
          c.putKeys += typeof args[0] === "object" && args[0] !== null
            ? Object.keys(args[0] as object).length
            : 1;
        } else if (name === "delete") {
          c.deletes++;
        }
        return result;
      };
    },
  });
}

export function wrapState<Props>(state: DurableObjectState<Props>, c: PerfCounters): DurableObjectState<Props> {
  const storage = wrapStorage(state.storage, c);
  return new Proxy(state, {
    get(target, prop) {
      if (prop === "storage") return storage;
      const value = Reflect.get(target, prop, target);
      return typeof value === "function" ? value.bind(target) : value;
    },
  });
}

/// A call the platform tunnels back as retryable (a transient failure, worth
/// repeating for an idempotent call) or overloaded (never worth repeating —
/// retrying an overloaded object only adds to the overload). See
/// https://developers.cloudflare.com/durable-objects/best-practices/error-handling.
interface RetryableError {
  retryable?: boolean;
  overloaded?: boolean;
}

/// Pause before each retry of a retryable call, by the attempts already made.
const RPC_RETRY_DELAYS_MS = [100, 300];

/// Wraps every RPC method call made through a stub of another object: an
/// `overloaded` error is never retried, a `retryable` one is retried a bounded
/// number of times (every call here is idempotent — a claim, a fetch, an
/// upsert — so a repeat changes nothing a first success would not have),
/// and, when `c` is given (dev measurement, PERF_LOG), every call is counted
/// and timed. Every stub in this codebase is created through a `*Stub` helper
/// that passes through here, so a call anywhere gets the same treatment.
export function wrapStub<T extends object>(stub: T, c?: PerfCounters | null): T {
  return new Proxy(stub, {
    get(target, prop) {
      const value = Reflect.get(target, prop, target);
      if (typeof value !== "function") return value;
      // an RPC method value is already bound to the stub's own internal
      // capability, not a plain function: calling it through .apply/.call
      // with an explicit thisArg re-targets that binding and corrupts the
      // RPC serialization ("Could not serialize object of type
      // DurableObject"), so it is invoked directly, unbound.
      const call = value as (...a: unknown[]) => Promise<unknown>;
      return async (...args: unknown[]) => {
        for (let attempt = 0; ; attempt++) {
          const t0 = Date.now();
          if (c) c.sub++;
          try {
            const res = await call(...args);
            if (c) c.subMs += Date.now() - t0;
            return res;
          } catch (e) {
            if (c) c.subMs += Date.now() - t0;
            const re = e as RetryableError;
            if (!re?.overloaded && re?.retryable && attempt < RPC_RETRY_DELAYS_MS.length) {
              await new Promise((r) => setTimeout(r, RPC_RETRY_DELAYS_MS[attempt]));
              continue;
            }
            throw e;
          }
        }
      };
    },
  }) as T;
}

/// `d` is what this invocation saw, `total` what the object has spent since it
/// woke. Invocations of one object interleave across awaits, so a burst is read
/// off the totals; the per-invocation numbers hold for a serial scenario.
export function logPerf(tag: string, op: string, ms: number, d: PerfCounters,
                        total: PerfCounters, extra?: object) {
  console.log(`PERF ${JSON.stringify({ tag, op, ms, ...d, total, ...(extra ?? {}) })}`);
}
