import type { FastChoice } from "./fast-actions.js";
export type ActionMethod =
  | "action.fast.observe"
  | "action.fast.act"
  | "action.tabs.query"
  | "action.tabs.ensure"
  | "action.observe"
  | "action.resolve"
  | "action.setValue"
  | "action.click"
  | "action.rect"
  | "midjourney.observe"
  | "midjourney.setPrompt"
  | "midjourney.submitPrompt"
  | "midjourney.readResults";

export type BrowserSurfaceTarget = {
  tabId?: number;
  url?: string;
  urlMatches?: string[];
  createUrl?: string;
  activate?: boolean;
};

export type TargetQuery = {
  selector?: string;
  text?: string;
  role?: string;
  testId?: string;
  index?: number;
};

export type RoutedParams = {
  surface?: BrowserSurfaceTarget;
};

export type ActionMessage =
  | { method: "action.fast.observe"; params: RoutedParams }
  | { method: "action.fast.act"; params: RoutedParams & FastChoice }
  | {
      method: "action.tabs.query";
      params?: BrowserSurfaceTarget;
    }
  | {
      method: "action.tabs.ensure";
      params: BrowserSurfaceTarget & { createUrl: string };
    }
  | {
      method: "action.observe";
      params?: TargetQuery & RoutedParams & { limit?: number };
    }
  | {
      method: "action.resolve";
      params?: TargetQuery & RoutedParams;
    }
  | {
      method: "action.setValue";
      params: TargetQuery & RoutedParams & { value: string };
    }
  | {
      method: "action.click";
      params?: TargetQuery & RoutedParams;
    }
  | {
      method: "action.rect";
      params?: TargetQuery & RoutedParams;
    }
  | {
      method: "midjourney.observe";
      params?: RoutedParams;
    }
  | {
      method: "midjourney.setPrompt";
      params: RoutedParams & { prompt: string };
    }
  | {
      method: "midjourney.submitPrompt";
      params: RoutedParams & { prompt?: string };
    }
  | {
      method: "midjourney.readResults";
      params?: RoutedParams;
    };

export type ElementDescriptor = {
  selector: string | null;
  tagName: string;
  text: string;
  role: string | null;
  testId: string | null;
  name: string | null;
  value: string | null;
  rect: {
    x: number;
    y: number;
    width: number;
    height: number;
  };
};

export type BrowserTabDescriptor = {
  id: number;
  windowId: number;
  active: boolean;
  url: string | null;
  title: string | null;
};

export type MidjourneyResult = {
  href: string | null;
  imageUrl: string | null;
  text: string;
  rect: ElementDescriptor["rect"];
};

export type MidjourneyState = {
  url: string;
  title: string;
  prompt: ElementDescriptor | null;
  statusTexts: string[];
  results: MidjourneyResult[];
};

export type ActionResponse<T = unknown> =
  | {
      ok: true;
      result: T;
    }
  | {
      ok: false;
      error: string;
    };
