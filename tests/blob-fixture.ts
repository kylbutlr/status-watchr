const stores = new Map<string, Map<string, unknown>>();
export const blobFailure = { writes: false };
export function resetBlobs() { stores.clear(); blobFailure.writes = false; }
export function getStore({ name }: { name: string }) {
  let records = stores.get(name);
  if (!records) { records = new Map(); stores.set(name, records); }
  return {
    get: async (key: string) => records.get(key) ?? null,
    setJSON: async (key: string, value: unknown) => {
      if (blobFailure.writes) throw Error('Fixture storage unavailable');
      records.set(key, value);
    },
    delete: async (key: string) => { records.delete(key); },
    list: async function* ({ prefix = '' } = {}) {
      yield { blobs: [...records.keys()].filter(key => key.startsWith(prefix)).map(key => ({ key })) };
    },
  };
}
