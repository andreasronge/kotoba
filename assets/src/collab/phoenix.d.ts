declare module "phoenix" {
  export interface Push { receive(status: "ok" | "error" | "timeout", callback: (payload: unknown) => void): Push }
  export interface Channel {
    join(): Push;
    leave(): Push;
    push(event: string, payload: unknown, timeout?: number): Push;
    on(event: string, callback: (payload: unknown) => void): number;
    onError(callback: () => void): void;
    onClose(callback: () => void): void;
  }
  export class Socket {
    constructor(url: string, options?: Record<string, unknown>);
    connect(): void;
    disconnect(): void;
    channel(topic: string, params: Record<string, unknown> | (() => Record<string, unknown>)): Channel;
    onOpen(callback: () => void): string;
    onClose(callback: () => void): string;
    isConnected(): boolean;
    off(refs: string[]): void;
  }
}
