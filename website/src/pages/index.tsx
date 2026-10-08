import type { ReactNode } from "react";
import clsx from "clsx";
import Link from "@docusaurus/Link";
import useBaseUrl from "@docusaurus/useBaseUrl";
import useDocusaurusContext from "@docusaurus/useDocusaurusContext";
import Layout from "@theme/Layout";
import Heading from "@theme/Heading";

import styles from "./index.module.css";

const features = [
  {
    icon: "1",
    title: "One conversation model",
    body: "Tenants, channels, conversations, participants and activities. Every inbound message, from any provider or socket, becomes an activity with a per-conversation seq.",
    to: "/concepts/overview",
  },
  {
    icon: "2",
    title: "Zero data loss by design",
    body: "Activities and their delivery jobs commit in one transaction (transactional outbox). Idempotent inbound batches, retries with backoff, dead letters and Lifeline rescue.",
    to: "/architecture/activity-flow",
  },
  {
    icon: "3",
    title: "Pluggable channels",
    body: "Webhook (SSRF-guarded, signed), WhatsApp via Meta Cloud API or Infobip, WebSocket and echo. A small adapter behaviour for adding your own.",
    to: "/channels/overview",
  },
  {
    icon: "4",
    title: "WebSocket-first",
    body: "Real-time sockets with presence and seq watermarks for resume today; Converger Protocol v1, a superset of mekik/1, is being specified.",
    to: "/websocket",
  },
  {
    icon: "5",
    title: "Routing and middleware",
    body: "Routing rules fan activities out to target channels; per-channel transformation middleware runs in the pipeline with crash containment.",
    to: "/concepts/routing-rules",
  },
  {
    icon: "6",
    title: "Production hardened",
    body: "Secrets encrypted at rest, hashed API keys, signed webhooks, cluster-wide rate limits, trusted proxies, one-shot locked migrations and a full CI gate.",
    to: "/security/overview",
  },
];

function HomepageHeader() {
  const logo = useBaseUrl("/img/logo-light.svg");
  return (
    <header className={clsx("hero", styles.heroBanner)}>
      <div className="container">
        <img src={logo} alt="" className={styles.heroLogo} />
        <span className={styles.heroBadge}>Elixir · Phoenix · Postgres</span>
        <Heading as="h1" className={styles.heroTitle}>
          Converger
        </Heading>
        <p className={styles.heroTagline}>
          A multi-tenant channel hub. Connect WebSocket clients, webhooks and
          messaging providers to one conversation model, route between them, and
          never lose a message.
        </p>
        <div className={styles.heroButtons}>
          <Link className="button button--secondary button--lg" to="/getting-started">
            Get started
          </Link>
          <Link
            className="button button--outline button--lg"
            style={{ color: "white", borderColor: "white" }}
            to="/adr"
          >
            Architecture decisions
          </Link>
        </div>
        <pre className={styles.codeBlock}>
          {`git clone https://github.com/AimTune/converger.git && cd converger
cp .env.example .env   # fill in the generated secrets
docker compose up`}
        </pre>
      </div>
    </header>
  );
}

function HomepageFeatures() {
  return (
    <section className={styles.features}>
      <div className="container">
        <Heading as="h2" style={{ textAlign: "center", marginBottom: "2rem" }}>
          What Converger gives you
        </Heading>
        <div className={styles.featureGrid}>
          {features.map((f) => (
            <Link key={f.title} to={f.to} className={styles.featureCard} style={{ color: "inherit", textDecoration: "none" }}>
              <span className={styles.featureIcon}>{f.icon}</span>
              <h3 style={{ marginTop: "0.75rem" }}>{f.title}</h3>
              <p>{f.body}</p>
            </Link>
          ))}
        </div>
      </div>
    </section>
  );
}

export default function Home(): ReactNode {
  const { siteConfig } = useDocusaurusContext();
  return (
    <Layout
      title={siteConfig.title}
      description="Converger: a multi-tenant channel hub built with Elixir and Phoenix. WebSocket-first, zero data loss."
    >
      <HomepageHeader />
      <main>
        <HomepageFeatures />
      </main>
    </Layout>
  );
}
