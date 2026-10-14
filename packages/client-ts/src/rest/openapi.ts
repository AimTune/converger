/**
 * REST schema types of the Converger client API (`/api/v1/converger`).
 *
 * HAND-WRITTEN placeholder in the shape `openapi-typescript` emits
 * (`components["schemas"][...]`). Once the server publishes its OpenAPI
 * document (`priv/static/openapi.json`, issue #45), `pnpm generate:types`
 * overwrites this file with the generated one; `./types.ts` re-exports the
 * schemas under stable names, so only that file needs adjusting if the
 * generated schema names differ.
 *
 * Shapes follow the controllers in `lib/converger_web/controllers/converger/`.
 */

export interface components {
  schemas: {
    /** `POST /tokens/generate` and `POST /tokens/refresh`. */
    TokenResponse: {
      conversationId: string | null;
      token: string;
      /** Lifetime in seconds. */
      expires_in: number;
      /** `read`, `write`, `typing` when the token is restricted (#52), else null. */
      permissions?: ("read" | "write" | "typing")[] | null;
    };
    /** `POST /conversations` and `GET /conversations/:id`. */
    ConversationResponse: {
      conversationId: string;
      /** A token restricted to this conversation. */
      token: string;
      expires_in: number;
      /** Phoenix binding URL (`/socket/converger/websocket?...`). */
      streamUrl: string;
    };
    /** `POST /conversations/:id/close` and `.../reopen`. */
    ConversationStatusResponse: {
      conversationId: string;
      status: "active" | "closed" | (string & {});
    };
    Attachment: {
      contentType?: string;
      contentUrl?: string;
      name?: string;
      size?: number;
      [key: string]: unknown;
    };
    /** An activity in the REST (Direct Line-like) shape. Carries no `seq`. */
    Activity: {
      id: string;
      type: string;
      from: { id: string | null };
      text: string | null;
      /** ISO 8601. */
      timestamp: string;
      attachments: components["schemas"]["Attachment"][] | null;
      conversationId: string;
      channelData: Record<string, unknown> | null;
      replyToId?: string | null;
      editedAt?: string | null;
      deletedAt?: string | null;
    };
    /** A page of activities (`GET /conversations/:id/activities`). */
    ActivitySet: {
      activities: components["schemas"]["Activity"][];
      /**
       * Watermark of the last activity; pass it back unchanged for the next page.
       * The integer seq since server v3.0 (#63); older servers send an opaque string.
       */
      watermark: number | string | null;
      has_more: boolean;
    };
    /** `POST /conversations/:id/activities`. */
    PostActivityRequest: {
      type?: string;
      text?: string;
      attachments?: components["schemas"]["Attachment"][];
      channelData?: Record<string, unknown>;
      from?: { id: string };
      replyToId?: string;
    };
    ResourceResponse: {
      id: string;
    };
    /** `POST /conversations/:id/upload`. */
    UploadResponse: {
      id: string;
      attachments: {
        id: string;
        contentType: string;
        contentUrl: string;
        size: number;
      }[];
    };
    /** The standard error envelope (#45). */
    ErrorEnvelope: {
      error: {
        code: string;
        message: string;
        details?: Record<string, unknown>;
        request_id?: string;
      };
    };
  };
}
