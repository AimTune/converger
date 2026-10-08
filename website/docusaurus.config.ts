import { themes as prismThemes } from "prism-react-renderer";
import type { Config } from "@docusaurus/types";
import type * as Preset from "@docusaurus/preset-classic";

const GITHUB_REPO = "https://github.com/AimTune/converger";
const SITE_URL = "https://converger.aimtune.dev";
const BASE_URL = "/";

type SidebarItem = {
  type: string;
  id?: string;
  label?: string;
  items?: SidebarItem[];
  [key: string]: unknown;
};

/**
 * Root-level docs that belong to a section. The files stay where they are
 * (`docs/deployment.md` etc. are linked by path from code and other docs);
 * only their sidebar entry moves. `index` is the position inside the
 * category; omitted means "append". Missing docs (e.g. `chaos` before its PR
 * lands) are simply skipped.
 */
const RELOCATE: Record<string, { category: string; index?: number }> = {
  webhooks: { category: "Channels and adapters", index: 0 },
  security: { category: "Security" },
  deployment: { category: "Operations", index: 0 },
  storage: { category: "Operations", index: 1 },
  chaos: { category: "Operations" },
};

function relocateRootDocs(items: SidebarItem[]): SidebarItem[] {
  const findCategory = (label: string) =>
    items.find((i) => i.type === "category" && i.label === label);

  const result = items.filter((item) => {
    if (item.type !== "doc" || !item.id || !(item.id in RELOCATE)) return true;
    const target = RELOCATE[item.id];
    const category = findCategory(target.category);
    if (!category || !category.items) return true;
    const index = target.index ?? category.items.length;
    category.items.splice(Math.min(index, category.items.length), 0, item);
    return false;
  });

  // `docs/protocol/` without its own `_category_.json` gets the folder name as
  // label and no position: give it a proper label and put it after WebSocket.
  const protocolIdx = result.findIndex(
    (i) => i.type === "category" && i.label === "protocol",
  );
  if (protocolIdx !== -1) {
    const [protocol] = result.splice(protocolIdx, 1);
    protocol.label = "Protocol";
    const wsIdx = result.findIndex((i) => i.type === "doc" && i.id === "websocket");
    result.splice(wsIdx === -1 ? result.length : wsIdx + 1, 0, protocol);
  }

  return result;
}

const config: Config = {
  title: "Converger",
  tagline:
    "A multi-tenant channel hub: one conversation model across WebSocket, webhooks and messaging providers, with zero data loss.",
  favicon: "img/favicon.svg",

  future: {
    v4: true,
    faster: true,
  },

  url: SITE_URL,
  baseUrl: BASE_URL,

  organizationName: "AimTune",
  projectName: "converger",
  trailingSlash: false,

  onBrokenLinks: "throw",
  onBrokenAnchors: "warn",
  markdown: {
    // `.md` files are plain CommonMark (no JSX), `.mdx` files are MDX. Docs are
    // written by engineers next to the code; this keeps `<token>` or `{id}` in
    // prose from breaking the build.
    format: "detect",
    mermaid: true,
    hooks: {
      onBrokenMarkdownLinks: "throw",
      onBrokenMarkdownImages: "throw",
    },
  },

  i18n: {
    defaultLocale: "en",
    locales: ["en"],
  },

  themes: ["@docusaurus/theme-mermaid"],

  presets: [
    [
      "classic",
      {
        docs: {
          // Single source of truth: the repository's top-level docs/ folder.
          path: "../docs",
          sidebarPath: "./sidebars.ts",
          routeBasePath: "/",
          // ADRs are named NNNN-title.md; keep the number in their URL.
          numberPrefixParser: false,
          editUrl: ({ docPath }) => `${GITHUB_REPO}/edit/main/docs/${docPath}`,
          showLastUpdateTime: false,
          sidebarItemsGenerator: async ({ defaultSidebarItemsGenerator, ...args }) => {
            const items = (await defaultSidebarItemsGenerator(args)) as SidebarItem[];
            return (args.item.dirName === "." ? relocateRootDocs(items) : items) as never;
          },
        },
        blog: false,
        theme: {
          customCss: "./src/css/custom.css",
        },
      } satisfies Preset.Options,
    ],
  ],

  themeConfig: {
    image: "img/converger-social-card.png",
    colorMode: {
      respectPrefersColorScheme: true,
    },
    mermaid: {
      theme: { light: "neutral", dark: "dark" },
    },
    navbar: {
      title: "Converger",
      logo: {
        alt: "Converger logo",
        src: "img/logo.svg",
      },
      items: [
        {
          type: "docSidebar",
          sidebarId: "docs",
          position: "left",
          label: "Docs",
        },
        { to: "/concepts/overview", position: "left", label: "Concepts" },
        { to: "/architecture/overview", position: "left", label: "Architecture" },
        { to: "/api/overview", position: "left", label: "API" },
        { to: "/adr", position: "left", label: "ADRs" },
        {
          href: GITHUB_REPO,
          label: "GitHub",
          position: "right",
        },
      ],
    },
    footer: {
      style: "dark",
      links: [
        {
          title: "Docs",
          items: [
            { label: "Introduction", to: "/intro" },
            { label: "Getting started", to: "/getting-started" },
            { label: "Concepts", to: "/concepts/overview" },
            { label: "Architecture", to: "/architecture/overview" },
          ],
        },
        {
          title: "Reference",
          items: [
            { label: "Channels and adapters", to: "/channels/overview" },
            { label: "REST API", to: "/api/overview" },
            { label: "WebSocket", to: "/websocket" },
            { label: "Configuration", to: "/operations/configuration" },
          ],
        },
        {
          title: "Project",
          items: [
            { label: "Architecture decisions", to: "/adr" },
            { label: "Roadmap", to: "/roadmap" },
            { label: "Contributing", to: "/contributing" },
            { label: "GitHub", href: GITHUB_REPO },
            { label: "Issues", href: `${GITHUB_REPO}/issues` },
          ],
        },
      ],
      copyright: `© ${new Date().getFullYear()} Hamza Agar. Built with Docusaurus.`,
    },
    prism: {
      theme: prismThemes.github,
      darkTheme: prismThemes.dracula,
      additionalLanguages: ["bash", "json", "diff", "elixir", "http", "powershell", "yaml"],
    },
  } satisfies Preset.ThemeConfig,
};

export default config;
