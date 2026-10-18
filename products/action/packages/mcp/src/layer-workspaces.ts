import { AsyncLocalStorage } from "node:async_hooks";

export class LayerWorkspaces<Context> {
  private readonly contexts = new Map<string, Context>();
  private readonly pending = new Map<string, Promise<unknown>>();
  private readonly scope = new AsyncLocalStorage<Context>();

  constructor(private readonly create: (workspace: string) => Context) {}

  get(workspace: string): Context {
    let context = this.contexts.get(workspace);
    if (!context) {
      context = this.create(workspace);
      this.contexts.set(workspace, context);
    }
    return context;
  }

  current(): Context {
    return this.scope.getStore() ?? this.get("default");
  }

  async run<Result>(workspace: string, operation: () => Promise<Result>): Promise<Result> {
    const previous = this.pending.get(workspace) ?? Promise.resolve();
    const result = previous.catch(() => undefined).then(() => this.scope.run(this.get(workspace), operation));
    this.pending.set(workspace, result);
    try {
      return await result;
    } finally {
      if (this.pending.get(workspace) === result) this.pending.delete(workspace);
    }
  }
}
