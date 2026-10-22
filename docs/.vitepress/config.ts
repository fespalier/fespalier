import { defineMd3Config } from "@vaam-apps/vitepress-md3/config";

// Served from GitHub Pages at /fespalier/. The Docs workflow passes the path
// Pages reports in DOCS_BASE (empty on pull requests, hence `||`).
const base = process.env.DOCS_BASE || "/fespalier/";
const repo = "https://github.com/fespalier/fespalier";

// GitHub's heading slug, the rule scripts/skills/check-links.mjs checks every
// `page.md#anchor` against: lower case, punctuation dropped, spaces to `-`.
// VitePress's own slugify turns punctuation into dashes, so without this the
// anchors the pages link to would not exist on the site.
const githubSlug = (heading: string) =>
  heading
    .replace(/[*`]/g, "")
    .toLowerCase()
    .replace(/[^\p{L}\p{N} _-]/gu, "")
    .replace(/ /g, "-");

export default defineMd3Config({
  base,
  lang: "en",
  title: "fespalier",
  titleTemplate: ":title · fespalier",
  description: "File-tree routing for Flutter, in the spirit of Next.js.",
  cleanUrls: true,
  lastUpdated: true,
  // A link to a page that does not exist fails the build.
  ignoreDeadLinks: false,
  head: [["link", { rel: "icon", type: "image/svg+xml", href: `${base}logo.svg` }]],

  markdown: {
    anchor: { slugify: githubSlug },
    // Some pages quote ICU messages (`{{count} dogs}`) in inline code.
    // VitePress compiles Markdown as Vue, so mark inline code v-pre or the
    // braces are evaluated as an interpolation and the build fails.
    config(md) {
      const render = md.renderer.rules.code_inline;
      md.renderer.rules.code_inline = (tokens, idx, options, env, self) => {
        const html = render
          ? render(tokens, idx, options, env, self)
          : `<code>${md.utils.escapeHtml(tokens[idx]?.content ?? "")}</code>`;
        return html.replace(/^<code/, "<code v-pre");
      };
    },
  },

  themeConfig: {
    md3: {
      style: "expressive",
      // Green: an espalier is a trained tree.
      seed: "#2e7d32",
    },

    logo: "/logo.svg",

    nav: [
      { text: "Get started", link: "/getting-started" },
      { text: "Routing", link: "/routing" },
      { text: "CLI", link: "/cli" },
      { text: "Examples", link: "/examples" },
      {
        text: "More",
        items: [
          { text: "All pages", link: "/README" },
          { text: "Changelog", link: `${repo}/blob/main/CHANGELOG.md` },
          { text: "Roadmap", link: `${repo}/blob/main/ROADMAP.md` },
          { text: "README", link: `${repo}/blob/main/README.md` },
        ],
      },
    ],

    sidebar: [
      {
        text: "Introduction",
        items: [
          { text: "Overview", link: "/" },
          { text: "All pages", link: "/README" },
          { text: "Installation and setup", link: "/getting-started" },
          { text: "Configuration", link: "/configuration" },
          { text: "Run the examples", link: "/examples" },
        ],
      },
      {
        text: "Core concepts",
        items: [
          { text: "File kinds", link: "/file-kinds" },
          { text: "Routing", link: "/routing" },
          { text: "Navigation", link: "/navigation" },
          { text: "Layouts", link: "/layouts" },
          { text: "Guards", link: "/guards" },
          { text: "Data", link: "/data" },
          { text: "Actions", link: "/actions" },
          { text: "main() and startup", link: "/app-startup" },
        ],
      },
      {
        text: "Features",
        items: [
          { text: "Forms", link: "/forms" },
          { text: "HTTP transport", link: "/transport" },
          { text: "HTTP clients", link: "/http" },
          { text: "Authentication", link: "/auth" },
          { text: "Images", link: "/responsive-images" },
          { text: "Translations", link: "/i18n-tolgee" },
          { text: "Maps", link: "/maps" },
          { text: "Downloads", link: "/downloads" },
          { text: "Push notifications", link: "/push" },
          { text: "Analytics", link: "/analytics" },
          { text: "Shortcuts and widgets", link: "/launch" },
        ],
      },
      {
        text: "CLI and tooling",
        items: [
          { text: "CLI reference", link: "/cli" },
          { text: "Route tests", link: "/route-tests" },
          { text: "Testing", link: "/testing" },
          { text: "DevTools extension", link: "/devtools" },
          { text: "Dashboards: fsp telemetry", link: "/telemetry-dashboards" },
        ],
      },
      {
        text: "Integrations",
        items: [
          { text: "Adapters", link: "/adapters" },
          { text: "Observability", link: "/observability" },
          { text: "Telemetry conventions", link: "/telemetry-conventions" },
          { text: "Offline-first", link: "/offline-first" },
          { text: "CrateStack", link: "/cratestack" },
        ],
      },
      {
        text: "Migration",
        items: [
          { text: "Adopting and upgrading", link: "/migration" },
          { text: "Coming from RIBs", link: "/coming-from-ribs" },
        ],
      },
      {
        text: "Help",
        items: [
          { text: "Troubleshooting", link: "/troubleshooting" },
          { text: "FAQ", link: "/faq" },
        ],
      },
      {
        text: "Contributing",
        items: [
          { text: "Development", link: "/development" },
          { text: "Releasing", link: "/releasing" },
          { text: "Roadmap", link: `${repo}/blob/main/ROADMAP.md` },
          { text: "Changelog", link: `${repo}/blob/main/CHANGELOG.md` },
        ],
      },
    ],

    outline: { level: [2, 3] },
    search: { provider: "local" },
    socialLinks: [{ icon: "github", link: repo }],
    editLink: {
      pattern: `${repo}/edit/main/docs/:path`,
      text: "Edit this page on GitHub",
    },
    footer: {
      message: "Released under the MIT License.",
      copyright: "Copyright © 2026 Vaam",
    },
  },
});
