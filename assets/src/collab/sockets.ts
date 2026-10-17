import { Socket } from "phoenix";

/**
 * The shared editors of a page lease a Phoenix socket per URL, each with its
 * own channel on it. A socket takes another editor while it has no channel for
 * that editor's document (Phoenix holds one channel per topic on a socket) and
 * fewer than Phoenix's default limit of channels; otherwise the editor gets a
 * new socket.
 *
 * A socket belongs to its leases: it connects with the first, goes down and up
 * with the browser's offline and online events, and closes with the last
 * release. An editor never disconnects it; to recover, it leaves its channel
 * and joins a new one.
 */
export interface Lease { readonly socket: Socket; release(): void }

// Phoenix.Socket's default :max_channels_per_transport.
const MAX_CHANNELS = 100;

interface Entry { socket: Socket; topics: Set<string>; close: () => void }
const entries = new Map<string, Entry[]>();

function open(url: string): Entry {
  const socket = new Socket(url);
  const offline = (): void => socket.disconnect();
  const online = (): void => socket.connect();
  window.addEventListener("offline", offline);
  window.addEventListener("online", online);
  if (navigator.onLine) socket.connect();
  return { socket, topics: new Set(), close: () => { window.removeEventListener("offline", offline); window.removeEventListener("online", online); socket.disconnect(); } };
}

export function lease(url: string, topic: string): Lease {
  const sockets = entries.get(url) ?? [];
  entries.set(url, sockets);
  let entry = sockets.find(candidate => !candidate.topics.has(topic) && candidate.topics.size < MAX_CHANNELS);
  if (!entry) { entry = open(url); sockets.push(entry); }
  const current = entry;
  current.topics.add(topic);
  let released = false;
  return {
    socket: current.socket,
    release: () => {
      if (released) return;
      released = true;
      current.topics.delete(topic);
      if (current.topics.size > 0) return;
      current.close();
      sockets.splice(sockets.indexOf(current), 1);
      if (sockets.length === 0) entries.delete(url);
    },
  };
}
