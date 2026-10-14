import type {
  IConnector,
  MessageHandler,
  ConnectHandler,
  DisconnectHandler,
  TypingHandler,
  SurveyPayload,
  ToolCallHandler,
  GenUIChunkHandler,
  GenUIComponentsHandler,
  GenUIComponentDefinition,
  GenUIEventOptions,
  CapabilitiesHandler,
  ConnectorCapabilities,
} from "@chativa/core";
import type { OutgoingMessage, MessageAction } from "@chativa/core";
// Value import — deliberately from the `frames` subpath, not the package root:
// the root would inline all of core into this connector's standalone bundle.
import { parseChatFrame, createGenUIEventFrame, createGenUIComponentCache } from "../core/frames.ts";
import type { GenUIComponentCache } from "../core/frames.ts";
import type {
  MekikAuthContext,
  MekikAuthDecision,
  MekikAuthError,
  MekikAuthProvider,
  MekikCredential,
} from "./auth.ts";
import { TokenAuth } from "./auth.ts";

export type {
  MekikAuthContext,
  MekikAuthDecision,
  MekikAuthError,
  MekikAuthProvider,
  MekikCredential,
  MekikTokenTransport,
  CookieAuthOptions,
  TokenAuthOptions,
} from "./auth.ts";
export { CookieAuth, TokenAuth } from "./auth.ts";

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

/** The prompt shown for an interrupt — the first human-readable field its payload offers. */
function interruptText(payload: Record<string, unknown>): string {
  for (const key of ["title", "message", "question", "text"]) {
    const v = payload[key];
    if (typeof v === "string" && v) return v;
  }
  return "Approval required";
}

/** What a client tool handler receives: the `params` the server-side caller passed. */
export type MekikClientToolHandler = (
  params: Record<string, unknown> | undefined,
) => unknown | Promise<unknown>;

/**
 * One tool this client declares to the mekik server (mekik PROTOCOL.md §11):
 * a UI capability — render a card, open a picker, read the device — described
 * well enough for a server-side model to call it. The definition (everything
 * but `handler`) travels in the `hello` handshake; the handler stays local and
 * runs when the server invokes the tool.
 *
 * Security note: the definition is deep-cloned and frozen at registration, and
 * both definitions and handlers live in true-private (`#`) fields — page-level
 * script cannot reach or rewire them through the connector instance. Servers
 * additionally opt in and allowlist declarations on their side.
 */
export interface MekikClientTool {
  /** Unique tool name; a redeclared name replaces the earlier one. */
  name: string;
  /** What the tool does — this is what the server-side model reads. */
  description?: string;
  /** JSON Schema for the tool's parameters (the model's input_schema). */
  parameters?: Record<string, unknown>;
  /**
   * Server-side filter labels (§11.2): the server exposes tagged tools only to
   * graph nodes that ask for an intersecting tag; untagged tools are
   * unrestricted.
   */
  tags?: string[];
  /**
   * `"call"` (default): the server parks its run until {@link handler} answers;
   * the result (or thrown error) is sent back in a `resume` frame.
   * `"notify"`: fire-and-forget — the invocation arrives as a stream event and
   * the handler's return value is discarded.
   */
  mode?: "call" | "notify";
  /** Runs when the server invokes the tool. */
  handler: MekikClientToolHandler;
}

/** The wire shape of a declaration — {@link MekikClientTool} minus the handler. */
type ClientToolDefinition = Omit<MekikClientTool, "handler">;

/**
 * One skill this client declares to the mekik server (mekik PROTOCOL.md §12.4):
 * a house style, the names its screens use — instructions a server-side model
 * should follow when the task matches. A client has no folder to serve, so the
 * whole skill travels inline in the declaration (`hello.skills` or a
 * `client_skills` frame). Ignored entirely by servers that did not opt in
 * (`MekikOptions.clientSkills`), and a name that collides with a server skill
 * is dropped server-side — the server's catalog is authoritative.
 */
export interface MekikClientSkill {
  /** 1–64 lowercase letters, digits and single hyphens — the Agent Skills name rule. */
  name: string;
  /** What the skill does and when to use it — the whole trigger surface. */
  description: string;
  /** The markdown instructions a model reads when it loads the skill. */
  instructions: string;
  /** Server-side filter labels (§11.2 tag rule). */
  tags?: string[];
}

/** Level-1 summary from the server's `skills` catalog frame (mekik PROTOCOL.md §12.2). */
export interface MekikSkillSummary {
  name: string;
  description: string;
  tags?: string[];
  /** Stamped by the server: where the skill came from. */
  source?: "server" | "client";
}

/** One skill use, as it travels on a persistent `skill` frame (mekik PROTOCOL.md §12.5). */
export interface MekikSkillUse {
  /** Replay-stable id — a resume re-emits the same id, so upsert rather than append. */
  id: string;
  name: string;
  status: "loaded" | "error";
  source?: "server" | "client";
  error?: string;
}

/** Receives the server's skill catalog (level-1 summaries) when it arrives or changes. */
export type MekikSkillsHandler = (skills: MekikSkillSummary[]) => void;
/** Receives each `skill` frame — which skill the agent is following, like a tool trace. */
export type MekikSkillUseHandler = (use: MekikSkillUse) => void;

/** The Agent Skills name rule (§12.1): 1–64 lowercase letters, digits, single hyphens. */
const SKILL_NAME = /^[a-z0-9]+(?:-[a-z0-9]+)*$/;

function deepFreeze<T>(value: T): T {
  if (typeof value === "object" && value !== null) {
    for (const v of Object.values(value)) deepFreeze(v);
    Object.freeze(value);
  }
  return value;
}

export interface MekikConnectorOptions {
  /** mekik WebSocket endpoint, e.g. "ws://localhost:8790/chat". */
  url: string;
  protocols?: string | string[];
  reconnect?: boolean;
  reconnectDelay?: number;
  maxReconnectAttempts?: number;
  /**
   * Reconnect pacing. `"fixed"` (default) waits `reconnectDelay` every time —
   * unchanged legacy behaviour. `"exponential"` grows the wait geometrically up
   * to `reconnectMaxDelay` and applies full jitter, so a whole fleet reconnecting
   * after a node dies doesn't thunder back in lockstep (docs/SCALING.md).
   */
  reconnectBackoff?: "fixed" | "exponential";
  /** Ceiling for `"exponential"` backoff, in ms. Default 30000. */
  reconnectMaxDelay?: number;
  /**
   * Put `conversationId` (and `userId`) in the connect URL query string, so a
   * sticky-by-conversation load balancer can route the WebSocket upgrade to the
   * owning node — the `hello` frame carries them too, but only arrives after the
   * handshake, too late for L7 routing. Off by default (they stay out of URLs /
   * server logs); turn on only when running a mekik fleet with affinity routing.
   */
  routeInUrl?: boolean;
  /** Queue outgoing messages while the socket is down and flush on (re)connect. */
  queueOfflineMessages?: boolean;
  /** Stable user identity. Omit to let the server mint one (announced via `welcome`). */
  userId?: string;
  /** Conversation to resume. Omit to start a new one. */
  conversationId?: string;
  /** Persist identity + watermark in localStorage and resume across page reloads. */
  resumeConversation?: boolean;
  /**
   * How this client authenticates, for servers that authenticate (PROTOCOL.md
   * §2.1) — the client-side mirror of the server's `Authenticator` port. Pass an
   * adapter: {@link CookieAuth} for a cookie session, {@link TokenAuth} for an
   * API key or a short-lived JWT, or your own {@link MekikAuthProvider}.
   * Omit entirely for servers that don't authenticate.
   *
   * Takes precedence over {@link MekikConnectorOptions.token}.
   */
  auth?: MekikAuthProvider;
  /**
   * Shorthand for `auth: new TokenAuth({ token, maxRetries: 0 })` — a credential
   * sent in the `hello` handshake, with no retry after a rejection.
   *
   * @deprecated Prefer `auth`, which also covers cookie sessions, the `query`
   * transport, and refresh-and-retry. This shorthand stays for compatibility.
   */
  token?: string | ((ctx: MekikAuthContext) => string | Promise<string>);
  /**
   * Called when the server rejects the connection (an `error` frame + close,
   * WebSocket code 4401). Fires regardless of which `auth` adapter is used, and
   * before any provider-driven retry. Auto-reconnect stays suppressed unless the
   * provider asks to retry, so this is where an app redirects to login.
   */
  onAuthError?: (error: MekikAuthError) => void;
  /**
   * Tools this client can execute on the server's behalf (mekik PROTOCOL.md
   * §11). Declared in the `hello` handshake; when the server invokes one, the
   * matching {@link MekikClientTool.handler} runs and its result round-trips
   * back automatically. Ignored by servers that did not opt in.
   */
  tools?: MekikClientTool[];
  /**
   * Allow {@link MekikConnector.registerTool} / {@link MekikConnector.unregisterTool}
   * after construction. **Off by default on purpose**: with the default, the
   * tool set is fixed at construction and held in true-private fields, so
   * console access or an injected script cannot add or replace tools at
   * runtime. Enable only when the app legitimately changes its toolset while
   * running (e.g. route-scoped tools in a SPA).
   */
  allowDynamicTools?: boolean;
  /**
   * Skills this client declares to the server (mekik PROTOCOL.md §12.4) —
   * inline SKILL.md-style instructions a server-side model follows when the
   * task matches. Declared in the `hello` handshake and re-sent on every
   * (re)connect. Ignored by servers that did not opt in (`clientSkills`).
   */
  skills?: MekikClientSkill[];
  /**
   * Allow {@link MekikConnector.registerSkill} / {@link MekikConnector.unregisterSkill}
   * after construction. Off by default for the same reason as
   * {@link MekikConnectorOptions.allowDynamicTools}: a skill's description and
   * instructions are text a server-side model will follow, so with the default
   * the set is sealed at construction and held in true-private fields.
   */
  allowDynamicSkills?: boolean;
}

/** Identity assigned/confirmed by the server's `welcome` frame. */
export interface MekikIdentity {
  conversationId: string;
  userId: string;
  connectionId: string;
  watermark: number;
}

interface PersistedSession {
  userId?: string;
  conversationId?: string;
  watermark?: number;
}

/**
 * MekikConnector — the single Chativa client connector for mekik servers
 * (Mekik Wire Protocol v1; mekik is the server-side sibling of Chativa).
 *
 * The wire protocol is identical over every mekik transport:
 *
 * - `{ type: "hello", ... }`      ← sent by us on open: userId / conversationId /
 *   watermark handshake. All fields optional; the server generates missing ids.
 * - `{ type: "welcome", data }`   → identity + current watermark; captured (and
 *   optionally persisted), never surfaced as a chat message.
 * - `{ type: "text", ... }`       → chat bubble; frames carrying `actions`
 *   (human-in-the-loop questions) surface as "quick-reply" messages so the
 *   chips render natively. `from: "user"` frames are the transcript replay /
 *   other-tab fan-out of the user's own messages.
 * - `{ type: "tool_call", data }` → ToolCall lifecycle frame (same `id`
 *   upserted as running → completed/error) → `onToolCall`.
 * - `{ type: "run", data: { status } }` → run lifecycle; mapped to the typing
 *   indicator (`started` → typing on, `finished` → typing off).
 * - `{ type: "genui", streamId, chunk, done }` → Generative UI chunk; mounts a
 *   GenUIRegistry component inline via `onGenUIChunk`.
 * - `{ type: "genui_event", streamId, eventType, scope?, component?, payload }` ←
 *   sent by us when a mounted GenUI component fires an event (form submit, card
 *   action, …). `scope` says who it is addressed to (§10.4): `"component"` from a
 *   `component-event` attribute, `"graph"` from `mekik-event`, absent from a plain
 *   `data-event`.
 * - `{ type: "error", data: { code, message } }` → auth rejection (§2.1),
 *   followed by a close (code 4401); surfaced via `onAuthError`, reconnect off.
 *
 * Authenticated servers (PROTOCOL.md §2.1): pass an `auth` provider — the
 * client-side mirror of mekik's `Authenticator` port. `CookieAuth` for a cookie
 * session, `TokenAuth` for an API key or short-lived JWT, or your own adapter.
 * The provider is consulted before every socket, so it can mint a fresh
 * credential per attempt and decide whether a rejection is worth retrying.
 *
 * Persistent frames carry `seq`; we track the highest one as our watermark and
 * hand it back on reconnect, so the server replays only what we missed —
 * DirectLine-style resume, multi-tab and multi-device included.
 */
export class MekikConnector implements IConnector {
  readonly name = "mekik";
  readonly addSentToHistory = true;

  private ws: WebSocket | null = null;
  private options: Required<
    Omit<
      MekikConnectorOptions,
      | "userId"
      | "conversationId"
      | "auth"
      | "token"
      | "onAuthError"
      | "tools"
      | "allowDynamicTools"
      | "skills"
      | "allowDynamicSkills"
    >
  > &
    Pick<
      MekikConnectorOptions,
      "userId" | "conversationId" | "auth" | "token" | "onAuthError"
    >;

  // ── client tools (mekik PROTOCOL.md §11) ─────────────────────────────
  // True-private (#) on purpose: `private` is erased at runtime, so a console
  // user or injected script could otherwise read or replace tool handlers on
  // the instance. With #fields the registry is unreachable from outside the
  // class body, and the definitions are frozen clones — the declaration the
  // server saw cannot be mutated after the fact.
  /** Frozen definition clones, in declaration order — what `hello.tools` carries. */
  #toolDefs: readonly ClientToolDefinition[] = [];
  /** name → handler; never exposed. */
  readonly #toolHandlers = new Map<string, MekikClientToolHandler>();
  /** Locked unless `allowDynamicTools: true` was passed at construction. */
  readonly #allowDynamicTools: boolean = false;
  /** Interrupt ids whose tool handler already ran this session (idempotence guard). */
  readonly #executedToolCalls = new Set<string>();
  /** `streamId:chunkId` keys of notify invocations already fired this session. */
  readonly #firedNotifications = new Set<string>();
  /**
   * The server's seq at welcome. Replayed history frames carry seq ≤ this, so a
   * replayed (possibly long-resolved) tool interrupt is never re-executed —
   * still-open calls are re-announced via `welcome.pending` instead.
   */
  #sessionBaseSeq = 0;

  // ── client skills (mekik PROTOCOL.md §12) ────────────────────────────
  // Same posture as the tool registry above: frozen clones in true-private
  // fields, sealed unless `allowDynamicSkills: true` was passed — a skill's
  // text reaches a server-side model, so page-level script must not be able
  // to rewrite what this client declared.
  /** Frozen declaration clones, in declaration order — what `hello.skills` carries. */
  #skillDefs: readonly MekikClientSkill[] = [];
  /** Locked unless `allowDynamicSkills: true` was passed at construction. */
  readonly #allowDynamicSkills: boolean = false;
  /**
   * The server's skill catalog (level-1 summaries) for this connection —
   * replayed to a handler that registers after the frame arrived, like
   * {@link onGenUIComponents}. Never contains client declarations (§12.2).
   */
  private _serverSkills: MekikSkillSummary[] = [];
  private skillsHandler: MekikSkillsHandler | null = null;
  /**
   * Message actions the server allows, from `welcome.data.capabilities`.
   * Both off until a welcome says otherwise: a server that never advertises
   * them would answer a `regenerate` / `edit` frame with `bad_request`.
   */
  private _messageActions: ConnectorCapabilities = { regenerate: false, editMessage: false };
  private capabilitiesHandler: CapabilitiesHandler | null = null;
  private skillUseHandler: MekikSkillUseHandler | null = null;

  /** The `auth` adapter, or one desugared from the legacy `token` option. */
  private readonly authProvider: MekikAuthProvider | undefined;

  private messageHandler: MessageHandler | null = null;
  private connectHandler: ConnectHandler | null = null;
  private disconnectHandler: DisconnectHandler | null = null;
  private typingHandler: TypingHandler | null = null;
  private toolCallHandler: ToolCallHandler | null = null;
  private genUIChunkHandler: GenUIChunkHandler | null = null;
  private genUIComponentsHandler: GenUIComponentsHandler | null = null;
  /**
   * Components the server announced on this connection. Replayed to a handler
   * that registers after the frame arrived, and re-sent by the server on every
   * reconnect (the client de-duplicates by name+version).
   */
  private serverComponents: GenUIComponentDefinition[] = [];
  /**
   * Catalog cache, keyed by server URL. Lets the handshake carry the stored
   * hash so an unchanged catalog is never re-sent (PROTOCOL.md §10). Built on
   * first use — `options` is only assigned in the constructor.
   */
  private _componentCache: GenUIComponentCache | null = null;

  private get componentCache(): GenUIComponentCache {
    this._componentCache ??= createGenUIComponentCache({ namespace: this.options.url });
    return this._componentCache;
  }

  private reconnectAttempts = 0;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  /** Set by disconnect(); suppresses auto-reconnect without mutating options. */
  private closedByUser = false;
  private queue: Array<{ payload: string; resolve: () => void }> = [];
  private watermark = 0;
  /** The app-configured userId (not a server-minted one) — scopes the storage key. */
  private readonly configuredUserId?: string;
  /**
   * Interrupts the server is parked on (mekik/2 §4). Keyed by the thread-scoped
   * interrupt `id`, which is how the answer must be routed back in a `resume`
   * frame. Filled by `interrupt` frames (and `welcome.pending` on reconnect),
   * drained by `interrupt_resolved` or by sending the answer.
   */
  private readonly openInterrupts = new Map<string, { ui?: unknown; actions?: MessageAction[] }>();
  private _identity: MekikIdentity | null = null;
  /** Set when the server rejects auth; suppresses reconnect and is cleared on the next connect(). */
  private _authError: MekikAuthError | null = null;
  /** Auth attempts for the current connection; reset once the server welcomes us. */
  private authAttempt = 0;
  /** The context handed to the provider for the in-flight attempt (replayed to onReject). */
  private authContext: MekikAuthContext | null = null;
  /**
   * Bumped by every connect()/disconnect(). An `authenticate()` call that
   * resolves after its generation is stale belongs to a superseded attempt and
   * must not open a socket.
   */
  private generation = 0;

  constructor(options: MekikConnectorOptions) {
    // Tools and skills never land on `this.options` (a soft-private field):
    // the defs and handlers go straight into the # registries below.
    const { tools, allowDynamicTools, skills, allowDynamicSkills, ...rest } = options;
    this.options = {
      protocols: [],
      reconnect: true,
      reconnectDelay: 2000,
      maxReconnectAttempts: 5,
      reconnectBackoff: "fixed",
      reconnectMaxDelay: 30000,
      routeInUrl: false,
      queueOfflineMessages: true,
      resumeConversation: false,
      ...rest,
    };
    this.#allowDynamicTools = allowDynamicTools === true;
    for (const tool of tools ?? []) this.#storeTool(tool);
    this.#allowDynamicSkills = allowDynamicSkills === true;
    for (const skill of skills ?? []) this.#storeSkill(skill);
    // Captured before `welcome` can adopt a server-minted id: only an
    // app-configured userId scopes the storage key (see storageKey()).
    this.configuredUserId = options.userId;
    // `token` is the legacy spelling of the same idea: hello-frame transport,
    // and no retry — re-sending a rejected credential the app never refreshed
    // would just be refused again, which is what it did before `auth` existed.
    this.authProvider =
      options.auth ??
      (options.token !== undefined
        ? new TokenAuth({ token: options.token, maxRetries: 0 })
        : undefined);
    if (this.options.resumeConversation) {
      const saved = this.loadSession();
      this.options.userId ??= saved?.userId;
      this.options.conversationId ??= saved?.conversationId;
      this.watermark = saved?.watermark ?? 0;
    }
  }

  /** Identity from the last `welcome` frame (null before the first connect). */
  get identity(): MekikIdentity | null {
    return this._identity;
  }

  /** The last auth rejection (null unless the server refused this connection). */
  get authError(): MekikAuthError | null {
    return this._authError;
  }

  // ── client tools API (mekik PROTOCOL.md §11) ─────────────────────────

  /** The declared tool definitions (frozen; handlers are not exposed). */
  get clientTools(): readonly Omit<MekikClientTool, "handler">[] {
    return this.#toolDefs;
  }

  /**
   * Declare (or replace) one tool at runtime and re-announce the full set to
   * the server with a `client_tools` frame. Requires
   * {@link MekikConnectorOptions.allowDynamicTools} — with the default, the
   * toolset is sealed at construction so page-level script cannot rewire what
   * the server-side model may trigger.
   */
  registerTool(tool: MekikClientTool): void {
    this.#assertDynamicToolsAllowed();
    this.#storeTool(tool);
    this.#announceTools();
  }

  /** Withdraw one tool at runtime and re-announce. Same lock as {@link registerTool}. */
  unregisterTool(name: string): void {
    this.#assertDynamicToolsAllowed();
    if (!this.#toolHandlers.delete(name)) return;
    this.#toolDefs = this.#toolDefs.filter((d) => d.name !== name);
    this.#announceTools();
  }

  #assertDynamicToolsAllowed(): void {
    if (!this.#allowDynamicTools) {
      throw new Error(
        "MekikConnector: the toolset is sealed. Pass `allowDynamicTools: true` at construction to change tools at runtime.",
      );
    }
  }

  /** Validate, deep-clone, freeze, and store one tool (last declaration of a name wins). */
  #storeTool(tool: MekikClientTool): void {
    if (typeof tool?.name !== "string" || tool.name.length === 0) {
      throw new Error("MekikConnector: a client tool needs a non-empty name.");
    }
    if (typeof tool.handler !== "function") {
      throw new Error(`MekikConnector: client tool "${tool.name}" needs a handler function.`);
    }
    // Clone via JSON so later mutation of the caller's object cannot silently
    // change what was (or will be) declared to the server.
    const def = deepFreeze(
      JSON.parse(
        JSON.stringify({
          name: tool.name,
          ...(tool.description !== undefined ? { description: tool.description } : {}),
          ...(tool.parameters !== undefined ? { parameters: tool.parameters } : {}),
          ...(tool.tags !== undefined ? { tags: tool.tags } : {}),
          ...(tool.mode !== undefined ? { mode: tool.mode } : {}),
        }),
      ) as ClientToolDefinition,
    );
    const existing = this.#toolDefs.findIndex((d) => d.name === def.name);
    this.#toolDefs =
      existing >= 0
        ? this.#toolDefs.map((d, i) => (i === existing ? def : d))
        : [...this.#toolDefs, def];
    this.#toolHandlers.set(def.name, tool.handler);
  }

  /** Replace the server's view of this connection's toolset (a live socket only — `hello` covers reconnects). */
  #announceTools(): void {
    if (this.ws?.readyState === WebSocket.OPEN) {
      this.ws.send(JSON.stringify({ type: "client_tools", tools: this.#toolDefs }));
    }
  }

  // ── client skills API (mekik PROTOCOL.md §12) ────────────────────────

  /** The skills this client declared (frozen clones). */
  get clientSkills(): readonly MekikClientSkill[] {
    return this.#skillDefs;
  }

  /**
   * The server's skill catalog for this connection — level-1 summaries from the
   * `skills` frame (or the local cache while the hash is unchanged). Empty
   * before the first catalog arrives, and never includes client declarations.
   */
  get serverSkills(): readonly MekikSkillSummary[] {
    return this._serverSkills;
  }

  /**
   * Declare (or replace) one skill at runtime and re-announce the full set with
   * a `client_skills` frame (§12.4 — the list is the connection's whole new
   * set). Requires {@link MekikConnectorOptions.allowDynamicSkills}; with the
   * default the set is sealed at construction, same as tools.
   */
  registerSkill(skill: MekikClientSkill): void {
    this.#assertDynamicSkillsAllowed();
    this.#storeSkill(skill);
    this.#announceSkills();
  }

  /** Withdraw one skill at runtime and re-announce. Same lock as {@link registerSkill}. */
  unregisterSkill(name: string): void {
    this.#assertDynamicSkillsAllowed();
    if (!this.#skillDefs.some((d) => d.name === name)) return;
    this.#skillDefs = this.#skillDefs.filter((d) => d.name !== name);
    // `[]` is meaningful on the wire: it withdraws every declared skill.
    this.#announceSkills();
  }

  /**
   * The server's catalog, delivered when it arrives or changes. A catalog that
   * already arrived (or was restored from cache during the handshake) is
   * replayed immediately, like {@link onGenUIComponents}.
   */
  /**
   * Which message actions the server allows. Announced immediately (both off
   * before the first `welcome`) and again on every `welcome`, so the Regenerate
   * and Edit buttons appear only on servers that advertise
   * `capabilities: { regenerate: true, edit: true }`.
   */
  onCapabilities(callback: CapabilitiesHandler): void {
    this.capabilitiesHandler = callback;
    callback({ ...this._messageActions });
  }

  /**
   * Ask the server to re-run the latest turn and stream a new reply:
   * `{ type: "regenerate", messageId }`. Only offered when the server's
   * `welcome` advertised `capabilities.regenerate`.
   */
  async regenerate(messageId: string): Promise<void> {
    await this.sendOrQueue(JSON.stringify({ type: "regenerate", messageId }));
  }

  /**
   * Replace the latest user message and re-run the turn from it:
   * `{ type: "edit", messageId, data }`. Only offered when the server's
   * `welcome` advertised `capabilities.edit`.
   */
  async editMessage(messageId: string, message: OutgoingMessage): Promise<void> {
    await this.sendOrQueue(JSON.stringify({ type: "edit", messageId, data: message.data }));
  }

  onSkills(callback: MekikSkillsHandler): void {
    this.skillsHandler = callback;
    if (this._serverSkills.length > 0) callback([...this._serverSkills]);
  }

  /**
   * Each persistent `skill` frame (§12.5) — which skill the agent loaded while
   * answering, the way `onToolCall` traces tool use. The id is replay-stable:
   * a reconnect replays the same id, so treat deliveries as upserts.
   */
  onSkillUse(callback: MekikSkillUseHandler): void {
    this.skillUseHandler = callback;
  }

  #assertDynamicSkillsAllowed(): void {
    if (!this.#allowDynamicSkills) {
      throw new Error(
        "MekikConnector: the skill set is sealed. Pass `allowDynamicSkills: true` at construction to change skills at runtime.",
      );
    }
  }

  /** Validate (§12.4 sanitization rules), deep-clone, freeze, and store one skill. */
  #storeSkill(skill: MekikClientSkill): void {
    if (typeof skill?.name !== "string" || !SKILL_NAME.test(skill.name) || skill.name.length > 64) {
      throw new Error(
        "MekikConnector: a client skill name must be 1–64 lowercase letters, digits and single hyphens.",
      );
    }
    const description = typeof skill.description === "string" ? skill.description.trim() : "";
    if (description.length === 0 || description.length > 1024) {
      throw new Error(
        `MekikConnector: client skill "${skill.name}" needs a non-empty description of at most 1024 characters.`,
      );
    }
    if (typeof skill.instructions !== "string") {
      throw new Error(`MekikConnector: client skill "${skill.name}" needs string instructions.`);
    }
    const def = deepFreeze(
      JSON.parse(
        JSON.stringify({
          name: skill.name,
          description,
          instructions: skill.instructions,
          ...(skill.tags !== undefined ? { tags: skill.tags } : {}),
        }),
      ) as MekikClientSkill,
    );
    const existing = this.#skillDefs.findIndex((d) => d.name === def.name);
    this.#skillDefs =
      existing >= 0
        ? this.#skillDefs.map((d, i) => (i === existing ? def : d))
        : [...this.#skillDefs, def];
  }

  /** Replace the server's view of this connection's skill set (live socket only — `hello` covers reconnects). */
  #announceSkills(): void {
    if (this.ws?.readyState === WebSocket.OPEN) {
      this.ws.send(JSON.stringify({ type: "client_skills", skills: this.#skillDefs }));
    }
  }

  /**
   * Run the handler for a server-invoked tool call and answer the pause with
   * the §11.3 result envelope. Executed at most once per interrupt id per
   * session; an id nobody here handles is left standing (another tab may own
   * it — the pause is durable and re-announced on its reconnect).
   */
  async #executeToolCall(id: string, call: { name: string; params?: Record<string, unknown> }): Promise<void> {
    if (this.#executedToolCalls.has(id)) return;
    const handler = this.#toolHandlers.get(call.name);
    if (!handler) return;
    this.#executedToolCalls.add(id);

    let envelope: Record<string, unknown>;
    try {
      const result = await handler(call.params);
      envelope = { ok: true, ...(result !== undefined ? { result } : {}) };
    } catch (err) {
      envelope = { ok: false, error: err instanceof Error ? err.message : String(err) };
    }
    this.openInterrupts.delete(id);
    await this.sendOrQueue(JSON.stringify({ type: "resume", answers: { [id]: envelope } }));
  }

  /**
   * A `"notify"`-mode invocation arrives as a stream event chunk under the
   * reserved name `client_tool` (§11.3). It belongs to the tool registry, not
   * the mounted components — fire the handler (once per chunk key) and swallow
   * the chunk. Returns true when the chunk was claimed.
   */
  #maybeClientToolChunk(streamId: string, chunk: unknown): boolean {
    if (!isRecord(chunk) || chunk.type !== "event" || chunk.name !== "client_tool") return false;
    const payload = isRecord(chunk.payload) ? chunk.payload : {};
    const name = typeof payload.name === "string" ? payload.name : "";
    const key = `${streamId}:${String(chunk.id ?? "")}`;
    if (!name || this.#firedNotifications.has(key)) return true;
    this.#firedNotifications.add(key);
    const handler = this.#toolHandlers.get(name);
    if (handler) {
      // Fire-and-forget by contract: the result is discarded, a failure is the
      // client's own business — nothing round-trips.
      void Promise.resolve()
        .then(() => handler(isRecord(payload.params) ? payload.params : undefined))
        .catch(() => {});
    }
    return true;
  }

  async connect(): Promise<void> {
    this.authAttempt = 0;
    return this.connectWithAuth(0, null);
  }

  /**
   * One connection attempt at a given auth attempt number. Split from connect()
   * so a provider-driven retry can re-enter with an incremented `attempt` and
   * the rejection that caused it, which is what lets `authenticate()` mint a
   * different credential than the one that was just refused.
   */
  private async connectWithAuth(
    attempt: number,
    previousError: MekikAuthError | null,
  ): Promise<void> {
    // Re-entrant safe: ChatEngine's auto-reconnect and our own onclose timer
    // can both call connect() after the same drop — tear down whichever
    // socket exists (detached first so its close event can't re-schedule)
    // so only one live socket ever routes frames.
    if (this.reconnectTimer !== null) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
    this.detachSocket();
    this.closedByUser = false;
    this._authError = null;
    const generation = ++this.generation;

    // The credential is resolved before the socket exists because a `query`
    // transport has to be in the URL the handshake opens with — too late once
    // onopen fires. A provider that throws fails connect() with its error
    // rather than degrading to an anonymous attempt, which would surface a
    // credential outage as a misleading "unauthorized" from the server.
    let credential: MekikCredential = {};
    if (this.authProvider) {
      const ctx: MekikAuthContext = { url: this.options.url, attempt, previousError };
      this.authContext = ctx;
      credential = await this.authProvider.authenticate(ctx);
    }
    // disconnect() or a newer connect() landed while we were resolving — that
    // attempt owns the socket now, so this one must not open a second one.
    if (this.closedByUser || generation !== this.generation) return;

    return new Promise((resolve, reject) => {
      const ws = new WebSocket(this.buildUrl(credential.query), this.options.protocols);
      this.ws = ws;

      ws.onopen = () => {
        this.sendHello(ws, credential.token, resolve);
      };

      ws.onerror = (event) => {
        reject(new Error(`MekikConnector WebSocket error: ${JSON.stringify(event)}`));
      };

      ws.onmessage = (event: MessageEvent) => {
        this.routeFrame(event.data as string);
      };

      ws.onclose = (event) => {
        // The run may have died with the socket — don't leave typing stuck on.
        this.typingHandler?.(false);
        this.disconnectHandler?.(event.reason);
        // An auth rejection (error frame seen, or close code 4401) must not
        // auto-reconnect: the same credential would just be refused again. A
        // retry only happens if the auth provider asks for one, because only it
        // can produce a credential that would fare any better.
        const authRejected =
          this._authError !== null ||
          (event as { code?: number }).code === 4401;
        if (
          !this.closedByUser &&
          !authRejected &&
          this.options.reconnect &&
          this.reconnectAttempts < this.options.maxReconnectAttempts
        ) {
          this.reconnectAttempts++;
          this.reconnectTimer = setTimeout(() => {
            this.reconnectTimer = null;
            if (this.closedByUser) return;
            this.connect().catch(() => {});
          }, this.nextReconnectDelay());
        }
      };
    });
  }

  async disconnect(): Promise<void> {
    this.closedByUser = true;
    // Strands any in-flight authenticate(): its generation is now stale, so it
    // cannot open a socket after we've been told to shut down.
    this.generation++;
    if (this.reconnectTimer !== null) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
    this.detachSocket();
  }

  /** Detach all handlers and close the current socket (if any) without side effects. */
  private detachSocket(): void {
    const ws = this.ws;
    this.ws = null;
    if (!ws) return;
    ws.onopen = null;
    ws.onerror = null;
    ws.onmessage = null;
    ws.onclose = null;
    if (ws.readyState === WebSocket.OPEN || ws.readyState === WebSocket.CONNECTING) {
      ws.close();
    }
  }

  async sendMessage(message: OutgoingMessage): Promise<void> {
    // If the server is parked on an interrupt (mekik/2 §4), an answer must go
    // back as a `resume` frame keyed by the interrupt id — not as a new turn.
    const resume = this.asResume(message);
    if (resume) {
      this.openInterrupts.delete(resume.id);
      await this.sendOrQueue(JSON.stringify(resume.frame));
      return;
    }
    await this.sendOrQueue(JSON.stringify(message));
  }

  /**
   * Turn an outgoing message into a `resume` frame when the conversation is
   * parked. A quick-reply chip carries its action's `label`; we match it back to
   * the stored action to recover the structured answer. A free-text reply while
   * exactly one interrupt is open resumes that one with the text.
   */
  private asResume(message: OutgoingMessage): { id: string; frame: unknown } | null {
    // The text lives at `data.text` on an OutgoingMessage — the same field the
    // server reads for a normal turn.
    const raw = message?.data?.text;
    const text = typeof raw === "string" ? raw : undefined;
    if (text === undefined || this.openInterrupts.size === 0) return null;

    for (const [id, info] of this.openInterrupts) {
      const match = info.actions?.find((a) => a.label === text);
      if (match) {
        const answer = "value" in match ? match.value : match.label;
        return { id, frame: { type: "resume", answers: { [id]: answer } } };
      }
    }
    if (this.openInterrupts.size === 1) {
      const id = this.openInterrupts.keys().next().value as string;
      return { id, frame: { type: "resume", answers: { [id]: text } } };
    }
    return null;
  }

  /**
   * Render an `interrupt` frame (mekik/2 §4). Chips are the reliable answer path
   * (a tap sends a `resume`); a mounted `ui` form is streamed as a GenUI chunk,
   * handed the interrupt id so its submit can round-trip.
   */
  private handleInterrupt(frame: Record<string, unknown>): void {
    const id = typeof frame.id === "string" ? frame.id : "";
    if (!id) return;
    const d = (frame.data ?? {}) as Record<string, unknown>;
    const payload = (d.payload ?? {}) as Record<string, unknown>;
    const actions = Array.isArray(d.actions) ? (d.actions as MessageAction[]) : undefined;
    // `event` means the server is parked on `onEvent` (§10.4): a widget already on
    // screen answers this pause, so there is nothing for the chat to render.
    const awaitedEvent = typeof d.event === "string" ? d.event : undefined;
    this.openInterrupts.set(id, { ui: d.ui, actions });
    this.typingHandler?.(false);

    // A client tool call (§11.3): the pause is answered by our registered
    // handler, not by a human — render nothing. Execute only when the call is
    // actually open: a `welcome.pending` re-announcement (no seq) or a live
    // frame (seq beyond the welcome watermark); a replayed historic interrupt
    // is display-order bookkeeping, not an instruction to run the tool again.
    if (isRecord(d.tool) && typeof d.tool.name === "string") {
      const live = frame.seq === undefined || (typeof frame.seq === "number" && frame.seq > this.#sessionBaseSeq);
      if (live) {
        void this.#executeToolCall(id, d.tool as { name: string; params?: Record<string, unknown> });
      }
      return;
    }

    if (actions && actions.length > 0) {
      // Chips display and send the label; asResume maps it back to the answer.
      this.renderQuickReply(id, interruptText(payload), actions.map((a) => ({ label: a.label, value: a.label })));
      return;
    }
    if (isRecord(d.ui) && typeof d.ui.component === "string") {
      const props = { ...(isRecord(d.ui.props) ? d.ui.props : {}), interruptId: id };
      this.genUIChunkHandler?.(`interrupt-${id}`, { type: "ui", component: d.ui.component, props, id: 1 }, true);
      return;
    }
    // A pause waiting for a component interaction is answered by that component,
    // not by the chat. Default chips here would be a dead end — tapping "Approve"
    // sends a `resume` the node is not waiting for.
    if (awaitedEvent) return;
    // Nothing to answer with: default Approve/Cancel chips.
    this.renderQuickReply(id, interruptText(payload), [{ label: "Approve" }, { label: "Cancel" }]);
  }

  private renderQuickReply(id: string, text: string, chips: MessageAction[]): void {
    const frame = parseChatFrame(
      { type: "text", id: `interrupt-${id}`, from: "bot", data: { text }, actions: chips },
      { idPrefix: "mekik" },
    );
    if (frame.kind === "quick_reply") this.messageHandler?.(frame.message);
  }

  /** Send the survey as a JSON frame with discriminator `{ type: "survey", ... }`. */
  async sendSurvey(payload: SurveyPayload): Promise<void> {
    await this.sendOrQueue(JSON.stringify({ type: "survey", ...payload }));
  }

  onMessage(callback: MessageHandler): void {
    this.messageHandler = callback;
  }

  onConnect(callback: ConnectHandler): void {
    this.connectHandler = callback;
  }

  onDisconnect(callback: DisconnectHandler): void {
    this.disconnectHandler = callback;
  }

  onTyping(callback: TypingHandler): void {
    this.typingHandler = callback;
  }

  onToolCall(callback: ToolCallHandler): void {
    this.toolCallHandler = callback;
  }

  onGenUIChunk(callback: GenUIChunkHandler): void {
    this.genUIChunkHandler = callback;
  }

  /**
   * Components the server defines itself (PROTOCOL.md §10). The catalog arrives
   * right after `welcome`, which can be before the app registers this handler —
   * so whatever already arrived is replayed immediately.
   */
  onGenUIComponents(callback: GenUIComponentsHandler): void {
    this.genUIComponentsHandler = callback;
    if (this.serverComponents.length > 0) callback([...this.serverComponents]);
  }

  /**
   * Forward a GenUI component event (form submit, card action, …) to the server
   * as `{ type: "genui_event", streamId, eventType, scope?, component?, payload }`
   * — the outbound counterpart of the inbound `genui` frame.
   *
   * `scope` is what makes the interaction routable server-side (PROTOCOL.md
   * §10.4): `"component"` (from a `component-event` attribute) reaches only a node
   * parked waiting for that event name, `"graph"` (from `mekik-event`) reaches the
   * app's handler, and an absent scope lets the server try both. A `submit` naming
   * an open interrupt still answers it whatever the scope says.
   */
  receiveComponentEvent(
    streamId: string,
    eventType: string,
    payload: unknown,
    opts?: GenUIEventOptions,
  ): void {
    void this.sendOrQueue(
      JSON.stringify(createGenUIEventFrame(streamId, eventType, payload, opts)),
    );
  }

  // ── internals ────────────────────────────────────────────────────────

  private routeFrame(raw: string): void {
    let data: Record<string, unknown>;
    try {
      data = JSON.parse(raw) as Record<string, unknown>;
    } catch {
      this.messageHandler?.({
        id: `mekik-${Date.now()}`,
        type: "text",
        data: { text: raw },
        timestamp: Date.now(),
      });
      return;
    }

    // Watermark: every persistent frame carries `seq` — remember the highest
    // so reconnects replay only what we missed.
    if (typeof data.seq === "number" && data.seq > this.watermark) {
      this.watermark = data.seq;
      if (this.options.resumeConversation) this.saveSession();
    }

    // Error frame: { type: "error", data: { code, message } }. Only an auth
    // rejection (code "unauthorized", followed by a 4401 close) tears the
    // connection down and stops reconnecting. Ordinary protocol errors — `busy`,
    // `interrupted`, `incomplete_resume`, `bad_request` — must NOT be mistaken
    // for an auth failure: surface them and keep the socket open.
    if (data?.type === "error") {
      const d = (data.data ?? {}) as Record<string, unknown>;
      const code = typeof d.code === "string" ? d.code : "error";
      const message = typeof d.message === "string" ? d.message : "";
      this.typingHandler?.(false);
      if (code === "unauthorized") {
        const error: MekikAuthError = { code, message };
        this._authError = error;
        this.options.onAuthError?.(error);
        this.disconnectHandler?.(message);
        void this.handleAuthRejection(error);
      }
      return;
    }

    // Handshake response: identity + current watermark. Not a chat message.
    // (Like tool_call, the payload may also be flattened onto the frame.)
    if (data?.type === "welcome") {
      // A welcome means the server accepted this credential — the only real
      // proof auth succeeded, since a rejection arrives after the socket opens.
      this.authAttempt = 0;
      const d = (data.data ?? data) as Partial<MekikIdentity>;
      const prevConversationId = this.options.conversationId;
      this._identity = {
        conversationId: String(d.conversationId ?? this.options.conversationId ?? ""),
        userId: String(d.userId ?? this.options.userId ?? ""),
        connectionId: String(d.connectionId ?? ""),
        watermark: Number(d.watermark ?? this.watermark),
      };
      // Adopt server-minted ids so the next reconnect resumes this session —
      // but never clobber a configured id with an empty value from a partial
      // welcome payload.
      if (this._identity.userId) this.options.userId = this._identity.userId;
      if (this._identity.conversationId) {
        this.options.conversationId = this._identity.conversationId;
      }
      // A different conversation than the one we tried to resume (e.g. the old
      // one expired) means our watermark belongs to the old transcript —
      // restart the new conversation's replay window from zero.
      if (
        this._identity.conversationId &&
        this._identity.conversationId !== prevConversationId
      ) {
        this.watermark = 0;
      }
      if (this.options.resumeConversation) this.saveSession();

      // Message actions the server allows (regenerate / edit). Absent means
      // not supported — re-announce so a reconnect to a different server
      // version can switch the buttons on or off.
      const caps = (data.data as Record<string, unknown> | undefined)?.capabilities;
      this._messageActions = {
        regenerate: isRecord(caps) && caps.regenerate === true,
        editMessage: isRecord(caps) && caps.edit === true,
      };
      this.capabilitiesHandler?.({ ...this._messageActions });

      // Frames replayed after this welcome carry seq ≤ the server's current
      // watermark — that boundary is what keeps historic (already-resolved)
      // client tool calls from re-executing (§11.3).
      this.#sessionBaseSeq = this._identity.watermark;

      // mekik/2: the server re-announces any open interrupts so a reconnecting
      // tab re-renders the approval it was parked on (§3.2).
      const pending = (data.data as Record<string, unknown> | undefined)?.pending;
      if (Array.isArray(pending)) {
        for (const p of pending) {
          if (isRecord(p)) this.handleInterrupt({ type: "interrupt", ...p });
        }
      }
      return;
    }

    // Run lifecycle frame: { type: "run", data: { status } } → typing indicator.
    // mekik-specific: the shared vocabulary has no `run` frame. Only "started"
    // means work is in flight; "finished"/"interrupted"/"error"/"aborted" all
    // clear the indicator.
    if (data?.type === "run") {
      const status = (data.data as Record<string, unknown> | undefined)?.status;
      this.typingHandler?.(status === "started");
      return;
    }

    // mekik/2 human-in-the-loop (§4): a first-class `interrupt` frame the server
    // is parked on. Render it as quick-reply chips (or a mounted form) and
    // remember the id so the answer goes back as a `resume`.
    if (data?.type === "interrupt") {
      this.handleInterrupt(data);
      return;
    }

    // The pause was answered (by us or another tab): stop tracking it so a later
    // message is sent as a normal turn, not a stray resume.
    if (data?.type === "interrupt_resolved") {
      this.openInterrupts.delete(String(data.id ?? ""));
      return;
    }

    // Server skill catalog (§12.2): a transient frame right after `welcome`.
    // `unchanged` confirms the cached copy already restored during the
    // handshake; otherwise store, cache by hash, and notify — the same ETag
    // dance as `genui_components`.
    if (data?.type === "skills") {
      if (data.unchanged === true) return;
      const skills = Array.isArray(data.skills)
        ? (data.skills as MekikSkillSummary[])
        : [];
      this._serverSkills = skills;
      if (typeof data.hash === "string" && data.hash) this.saveSkillCatalog(data.hash, skills);
      this.skillsHandler?.([...skills]);
      return;
    }

    // Persistent `skill` trace (§12.5): which skill the agent loaded. The id is
    // replay-stable, so a reconnect replays the same id — upsert, not append.
    // Never surfaced as a chat bubble; apps subscribe via onSkillUse().
    if (data?.type === "skill") {
      const d = (data.data ?? {}) as Record<string, unknown>;
      if (
        typeof d.id === "string" &&
        typeof d.name === "string" &&
        (d.status === "loaded" || d.status === "error")
      ) {
        this.skillUseHandler?.(d as unknown as MekikSkillUse);
      }
      return;
    }

    // The frames mekik shares with every other Chativa connector — tool calls,
    // GenUI chunks and the HITL chips — are routed by the one parser in core so
    // the rules can't drift apart between transports.
    const frame = parseChatFrame(data, { idPrefix: "mekik" });
    switch (frame.kind) {
      case "tool_call":
        this.toolCallHandler?.(frame.toolCall);
        return;
      case "genui":
        // A reserved `client_tool` event chunk is a notify-mode invocation
        // (§11.3): it addresses the tool registry, never a mounted component.
        if (this.#maybeClientToolChunk(frame.streamId, frame.chunk)) return;
        this.genUIChunkHandler?.(frame.streamId, frame.chunk, frame.done);
        return;
      case "genui_components":
        // `unchanged` means our cached catalog is still current — it was
        // already published when the socket opened, so there is nothing to do.
        if (frame.unchanged) return;
        this.serverComponents = frame.definitions;
        if (frame.hash) this.componentCache.save(frame.hash, frame.definitions);
        this.genUIComponentsHandler?.(frame.definitions);
        return;
      case "typing":
        this.typingHandler?.(frame.isTyping);
        return;
      case "quick_reply":
        // The question itself ends the visible "working" state.
        this.typingHandler?.(false);
        this.messageHandler?.(frame.message);
        return;
      case "other":
        break;
    }

    // A malformed `tool_call`/`genui` frame is dropped rather than falling
    // through to the message handler: rendering half a trace as a chat bubble
    // would be worse than ignoring a frame the server got wrong.
    if (
      data?.type === "tool_call" ||
      data?.type === "genui" ||
      data?.type === "genui_components"
    ) return;

    // A bot message ends any visible "working" state.
    this.typingHandler?.(false);
    this.messageHandler?.(data as never);
  }

  /**
   * Send now, or queue until the next (re)connect. A queued payload's promise
   * resolves only when it is actually flushed onto the wire, so ChatEngine
   * keeps the bubble on "sending" instead of stamping "sent" for a message
   * the server never received.
   */
  private sendOrQueue(payload: string): Promise<void> {
    if (this.ws && this.ws.readyState === WebSocket.OPEN) {
      this.ws.send(payload);
      return Promise.resolve();
    }
    if (this.options.queueOfflineMessages) {
      return new Promise((resolve) => this.queue.push({ payload, resolve }));
    }
    return Promise.reject(new Error("MekikConnector: not connected."));
  }

  private flushQueue(): void {
    while (this.queue.length && this.ws?.readyState === WebSocket.OPEN) {
      const entry = this.queue.shift()!;
      this.ws.send(entry.payload);
      entry.resolve();
    }
  }

  /**
   * Build the socket URL, merging in any query credential. Kept separate from
   * `options.url`, which stays credential-free — it is the localStorage key and
   * the value handed to the provider.
   */
  private buildUrl(query?: Record<string, string>): string {
    // Routing keys for a sticky-by-conversation load balancer (opt-in), because
    // the hello frame that also carries them arrives only after the upgrade. A
    // query credential wins over these on any key clash.
    const routing: Record<string, string> = {};
    if (this.options.routeInUrl) {
      if (this.options.conversationId) routing.conversationId = this.options.conversationId;
      if (this.options.userId) routing.userId = this.options.userId;
    }
    const merged = { ...routing, ...query };
    if (Object.keys(merged).length === 0) return this.options.url;
    const url = new URL(this.options.url);
    for (const [key, value] of Object.entries(merged)) {
      url.searchParams.set(key, value);
    }
    return url.toString();
  }

  /** Next reconnect wait — fixed `reconnectDelay`, or jittered exponential when configured. */
  private nextReconnectDelay(): number {
    const base = this.options.reconnectDelay;
    if (this.options.reconnectBackoff !== "exponential") return base;
    // reconnectAttempts was already incremented for this scheduling, so the first
    // retry uses `base`. Full jitter over [raw/2, raw] de-correlates a fleet storm.
    const raw = Math.min(base * 2 ** (this.reconnectAttempts - 1), this.options.reconnectMaxDelay);
    return raw / 2 + Math.random() * (raw / 2);
  }

  /**
   * Ask the provider what to do about a rejection. Only a provider can know
   * whether a fresh credential is obtainable, so the retry decision is its call
   * — the connector just carries it out.
   */
  private async handleAuthRejection(error: MekikAuthError): Promise<void> {
    const provider = this.authProvider;
    if (!provider?.onReject) return;

    const ctx = this.authContext ?? {
      url: this.options.url,
      attempt: this.authAttempt,
      previousError: null,
    };

    let decision: MekikAuthDecision;
    try {
      decision = await provider.onReject(error, ctx);
    } catch {
      decision = "fail"; // a provider that can't decide doesn't get to retry
    }
    if (decision !== "retry" || this.closedByUser) return;

    this.authAttempt = ctx.attempt + 1;
    await this.connectWithAuth(this.authAttempt, error).catch(() => {
      /* the retry failed too — onAuthError already told the app */
    });
  }

  /** Send the mekik/1 hello handshake once the socket is open, then resolve connect(). */
  private sendHello(ws: WebSocket, token: string | undefined, resolve: () => void): void {
    this.reconnectAttempts = 0;
    // A returning user's widgets render from cache immediately; the server
    // only sends markup back when the hash moved on.
    const cached = this.componentCache.load();
    const componentsHash = cached?.hash;
    if (cached && cached.components.length > 0) {
      this.serverComponents = cached.components;
      this.genUIComponentsHandler?.([...cached.components]);
    }
    // Same ETag handshake for the server's skill catalog (§12.2): restore the
    // cached summaries now, hand the hash back, and the server answers
    // `unchanged` instead of re-sending an identical catalog.
    const cachedSkills = this.loadSkillCatalog();
    const skillsHash = cachedSkills?.hash;
    if (cachedSkills && cachedSkills.skills.length > 0) {
      this._serverSkills = cachedSkills.skills;
      this.skillsHandler?.([...cachedSkills.skills]);
    }
    // mekik/1 handshake — all fields optional, server fills the gaps.
    // `token` is only present when the server authenticates (§2.1).
    ws.send(
      JSON.stringify({
        type: "hello",
        userId: this.options.userId,
        conversationId: this.options.conversationId,
        watermark: this.watermark,
        // ETag for the server-defined component catalog: same hash → the
        // server answers `unchanged` instead of re-sending the markup.
        ...(componentsHash ? { componentsHash } : {}),
        ...(token ? { token } : {}),
        // Client tools (§11.1): the definitions only — handlers stay local.
        // Re-sent on every (re)connect, since declarations are per-connection.
        ...(this.#toolDefs.length > 0 ? { tools: this.#toolDefs } : {}),
        // Client skills (§12.4): the connection's whole set, re-declared on
        // every (re)connect. `skillsHash` is the catalog ETag (§12.2).
        ...(skillsHash ? { skillsHash } : {}),
        ...(this.#skillDefs.length > 0 ? { skills: this.#skillDefs } : {}),
      }),
    );
    this.flushQueue();
    this.connectHandler?.();
    resolve();
  }

  // ── skill catalog cache (§12.2's ETag handshake) ─────────────────────

  private skillCacheKey(): string {
    return `chativa:mekik:skills:${this.options.url}`;
  }

  private loadSkillCatalog(): { hash: string; skills: MekikSkillSummary[] } | null {
    try {
      if (typeof localStorage === "undefined") return null;
      const raw = localStorage.getItem(this.skillCacheKey());
      if (!raw) return null;
      const parsed = JSON.parse(raw) as { hash?: unknown; skills?: unknown };
      if (typeof parsed.hash !== "string" || !Array.isArray(parsed.skills)) return null;
      return { hash: parsed.hash, skills: parsed.skills as MekikSkillSummary[] };
    } catch {
      return null;
    }
  }

  private saveSkillCatalog(hash: string, skills: MekikSkillSummary[]): void {
    try {
      if (typeof localStorage === "undefined") return;
      localStorage.setItem(this.skillCacheKey(), JSON.stringify({ hash, skills }));
    } catch {
      /* storage unavailable — the server just re-sends the catalog */
    }
  }

  private storageKey(): string {
    // Scope by the app-configured userId so two known users sharing an origin
    // don't collide on one stored session. A server-minted (anonymous) id is not
    // used — it isn't known at load time and would strand the session across
    // reloads; anonymous means one user per browser anyway.
    const suffix = this.configuredUserId ? `:${this.configuredUserId}` : "";
    return `chativa:mekik:${this.options.url}${suffix}`;
  }

  private loadSession(): PersistedSession | null {
    try {
      if (typeof localStorage === "undefined") return null;
      const raw = localStorage.getItem(this.storageKey());
      return raw ? (JSON.parse(raw) as PersistedSession) : null;
    } catch {
      return null;
    }
  }

  private saveSession(): void {
    try {
      if (typeof localStorage === "undefined") return;
      localStorage.setItem(
        this.storageKey(),
        JSON.stringify({
          userId: this.options.userId,
          conversationId: this.options.conversationId,
          watermark: this.watermark,
        } satisfies PersistedSession),
      );
    } catch {
      /* storage unavailable — resume silently disabled */
    }
  }
}

/** @deprecated Renamed — use {@link MekikConnector}. */
export const LineConnector = MekikConnector;
/** @deprecated Renamed — use {@link MekikConnectorOptions}. */
export type LineConnectorOptions = MekikConnectorOptions;
