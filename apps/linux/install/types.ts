import type { InstallPaths } from "./paths.ts";

export interface CommandResult { status: number; stdout: string; stderr: string }
export type Runner = (command: string, args: string[], timeout?: number) => CommandResult;
export interface Receipt { schema: 1; release: string; files: Record<string, string>; backup: string; gestures: boolean; wheel: boolean; appReleases?: string[] }
export interface PlannedFile { path: string; content: string; mode: number; shared?: boolean }
export interface InstallContext { source?: string; paths?: InstallPaths; run?: Runner; which?: (command: string) => string | null; bun?: string; log?: (message: string) => void; omarchy?: string }
export type CheckedRunner = Runner;
export type AddFile = (path: string, content: string, mode?: number, shared?: boolean) => void;
