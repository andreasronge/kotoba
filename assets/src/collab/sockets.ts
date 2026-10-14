import { Socket } from "phoenix";

/**
 * The editors of a page share one Phoenix socket per URL, each with its own
 * channel on it. A socket holds one channel per topic, so a second editor of
 * the same document on the page gets a socket of its own.
 */
export interface Lease { readonly socket: Socket; release(): void }

interface Shared { socket: Socket; topics: Set<string>; cleanup: () => void }
const shared = new Map<string, Shared>();

function open(url: string): { socket: Socket; cleanup: () => void } {
  const socket = new Socket(url);
  const offline = (): void => socket.disconnect();
  const online = (): void => socket.connect();
  window.addEventListener("offline", offline);
  window.addEventListener("online", online);
  if (navigator.onLine) socket.connect();
  return { socket, cleanup: () => { window.removeEventListener("offline", offline); window.removeEventListener("online", online); socket.disconnect(); } };
}

export function lease(url: string, topic: string): Lease {
  let entry = shared.get(url);
  if (entry?.topics.has(topic)) {
    const own = open(url);
    return { socket: own.socket, release: own.cleanup };
  }
  if (!entry) {
    entry = { ...open(url), topics: new Set() };
    shared.set(url, entry);
  }
  const current = entry;
  current.topics.add(topic);
  let released = false;
  return {
    socket: current.socket,
    release: () => {
      if (released) return;
      released = true;
      current.topics.delete(topic);
      if (current.topics.size === 0 && shared.get(url) === current) { shared.delete(url); current.cleanup(); }
    },
  };
}
