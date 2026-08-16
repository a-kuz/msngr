/// Dev-only measurement of what one object invocation costs: storage
/// operations and the records they touch, D1 statements, subrequests to other
/// objects. Off unless PERF_LOG is set; the wrappers are never installed then.
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
  d1: number;
  d1Ms: number;
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
    storageMs: 0, d1: 0, d1Ms: 0, sub: 0, subMs: 0, outFrames: 0, outBytes: 0,
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

export function wrapState(state: DurableObjectState, c: PerfCounters): DurableObjectState {
  const storage = wrapStorage(state.storage, c);
  return new Proxy(state, {
    get(target, prop) {
      if (prop === "storage") return storage;
      const value = Reflect.get(target, prop, target);
      return typeof value === "function" ? value.bind(target) : value;
    },
  });
}

/// Counts every fetch made through a stub of another object.
export function wrapStub<T extends { fetch: (...a: never[]) => Promise<Response> }>(
  stub: T,
  c: PerfCounters
): T {
  return new Proxy(stub, {
    get(target, prop) {
      const value = Reflect.get(target, prop, target);
      if (prop !== "fetch" || typeof value !== "function") {
        return typeof value === "function" ? value.bind(target) : value;
      }
      return async (...args: never[]) => {
        const t0 = Date.now();
        c.sub++;
        const res = await (value as (...a: never[]) => Promise<Response>).apply(target, args);
        c.subMs += Date.now() - t0;
        return res;
      };
    },
  }) as T;
}

/// Counts D1 statements: one per run/first/all of a prepared statement.
export function wrapDB(db: D1Database, c: PerfCounters): D1Database {
  const wrapStatement = (stmt: D1PreparedStatement): D1PreparedStatement =>
    new Proxy(stmt, {
      get(target, prop) {
        const value = Reflect.get(target, prop, target);
        if (typeof value !== "function") return value;
        const name = String(prop);
        return (...args: unknown[]) => {
          if (name === "bind") {
            return wrapStatement(
              (value as (...a: unknown[]) => D1PreparedStatement).apply(target, args)
            );
          }
          if (name === "run" || name === "first" || name === "all" || name === "raw") {
            const t0 = Date.now();
            c.d1++;
            return (value as (...a: unknown[]) => Promise<unknown>)
              .apply(target, args)
              .then((r) => {
                c.d1Ms += Date.now() - t0;
                return r;
              });
          }
          return (value as (...a: unknown[]) => unknown).apply(target, args);
        };
      },
    });
  return new Proxy(db, {
    get(target, prop) {
      const value = Reflect.get(target, prop, target);
      if (typeof value !== "function") return value;
      if (prop === "prepare") {
        return (sql: string) =>
          wrapStatement((value as (s: string) => D1PreparedStatement).apply(target, [sql]));
      }
      if (prop === "batch") {
        return (stmts: unknown[]) => {
          c.d1 += stmts.length;
          return (value as (...a: unknown[]) => unknown).apply(target, [stmts]);
        };
      }
      return (value as (...a: unknown[]) => unknown).bind(target);
    },
  });
}

/// `d` is what this invocation saw, `total` what the object has spent since it
/// woke. Invocations of one object interleave across awaits, so a burst is read
/// off the totals; the per-invocation numbers hold for a serial scenario.
export function logPerf(tag: string, op: string, ms: number, d: PerfCounters,
                        total: PerfCounters, extra?: object) {
  console.log(`PERF ${JSON.stringify({ tag, op, ms, ...d, total, ...(extra ?? {}) })}`);
}
