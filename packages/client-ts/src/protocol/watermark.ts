/**
 * Watermarks (spec section 6.5).
 *
 * In Protocol v1 a watermark is the integer `seq` of the last persistent frame
 * a client has durably seen; REST `activitySet.watermark` is that integer too
 * since server v3.0 (#63). The legacy Phoenix binding still emits the opaque
 * form, base64url of `seq:N`, for one release, and older servers emit it on
 * REST. Every server input accepts all forms. These helpers convert between them.
 *
 * @module
 */

function base64UrlEncode(text: string): string {
  return btoa(text).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function base64UrlDecode(value: string): string | null {
  try {
    const padded = value.replace(/-/g, "+").replace(/_/g, "/");
    return atob(padded + "=".repeat((4 - (padded.length % 4)) % 4));
  } catch {
    return null;
  }
}

/** The opaque pre-v1 form of a seq watermark (`base64url("seq:N")`). */
export function encodeOpaqueWatermark(seq: number): string {
  return base64UrlEncode(`seq:${seq}`);
}

/**
 * Parse any watermark the server emits into a seq: a number, a decimal string,
 * or the opaque `seq:N` form. Returns `null` for absent or unparseable values
 * (including legacy activity-id watermarks, which carry no seq).
 */
export function parseWatermark(value: unknown): number | null {
  if (typeof value === "number") {
    return Number.isInteger(value) && value >= 0 ? value : null;
  }
  if (typeof value !== "string" || value === "") return null;
  if (/^(0|[1-9][0-9]{0,15})$/.test(value)) return Number(value);
  const decoded = base64UrlDecode(value);
  const match = decoded === null ? null : /^seq:(0|[1-9][0-9]{0,15})$/.exec(decoded);
  return match ? Number(match[1]) : null;
}
