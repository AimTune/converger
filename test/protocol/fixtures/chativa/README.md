# Vendored chativa sources

chativa is Converger's reference WebSocket client (#65,
[ADR-0065](../../../../docs/adr/0065-chativa-as-reference-client-and-history-cursor.md)).
`test/protocol/chativa_compat_test.exs` and `test/protocol/chativa_live_bot_test.exs` (a live mekik bot behind
Converger) run chativa's real connector code in Node against a real Converger server, through
`Converger.ChativaHarness` (`test/support/chativa_harness.ex`), so a protocol change that breaks chativa fails the
build.

These files are copied from [AimTune/chativa](https://github.com/AimTune/chativa) at commit
`f919c92ded52276249538f15a1e16043564b1867`:

| file here | chativa source | changes |
| --- | --- | --- |
| `core/ChatFrame.ts` | `packages/core/src/domain/entities/ChatFrame.ts` | none |
| `core/GenUIComponentCache.ts` | `packages/core/src/domain/entities/GenUIComponentCache.ts` | none |
| `connector-mekik/index.ts` | `packages/connector-mekik/src/index.ts` | import specifiers only (below) |
| `connector-mekik/auth.ts` | `packages/connector-mekik/src/auth.ts` | none |

Node runs TypeScript by stripping types, which needs explicit relative file paths, so two import
specifiers in `connector-mekik/index.ts` are rewritten: `"@chativa/core/frames"` becomes
`"../core/frames.ts"` and `"./auth"` becomes `"./auth.ts"`. Line endings are LF. The type-only
imports (`@chativa/core`, `./Message`, `./GenUI`, ...) are erased by Node and need no files.

Not vendored, written for Converger:

- `core/frames.ts`: the stand-in for `@chativa/core/frames`, re-exporting the two vendored files.
- `harness.mjs`: drives a `MekikConnector` (or `parseChatFrame`) and prints what chativa's
  ChatEngine would receive as JSON lines; it can disconnect and reconnect the same connector and keep
  localStorage in a file (a page reload). See the comment at its top.
- `package.json`: marks the directory as ES modules.

Requirements: Node >= 22.18 (or >= 23.6), where TypeScript type stripping is on by default. CI
installs Node 24 and sets `CHATIVA_COMPAT=required`, so a missing Node fails instead of skipping.

To update, copy the four files again from a newer chativa commit, re-apply the two import rewrites
and LF line endings, update the SHA above, and run `mix test --only chativa`:

```sh
C=path/to/chativa
cp $C/packages/core/src/domain/entities/{ChatFrame,GenUIComponentCache}.ts core/
cp $C/packages/connector-mekik/src/{index,auth}.ts connector-mekik/
sed -i 's/\r$//; s#"@chativa/core/frames"#"../core/frames.ts"#; s#from "./auth"#from "./auth.ts"#' \
  connector-mekik/index.ts
sed -i 's/\r$//' core/*.ts connector-mekik/auth.ts
```

## License

chativa is published under the MIT License (declared in its `package.json` files; the repository
has no separate LICENSE file at that commit). MIT permits redistribution with this notice:

> Copyright (c) AimTune (Hamza Agar)
>
> Permission is hereby granted, free of charge, to any person obtaining a copy of this software
> and associated documentation files (the "Software"), to deal in the Software without
> restriction, including without limitation the rights to use, copy, modify, merge, publish,
> distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the
> Software is furnished to do so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in all copies or
> substantial portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING
> BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
> NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
> DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
> OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
