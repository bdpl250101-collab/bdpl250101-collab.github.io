#!/usr/bin/env node
/*
 * check-links.js — resolve every student-section link and settle its link_type.
 *
 * The three panels promise one of two things per card: a link straight to the posting,
 * or a search that lands the reader where they can find it themselves. What they must
 * never do is send someone to a 404, or to a portal home page that looks like a posting
 * link and isn't. A stale deep link is worse than an honest search link, because the
 * reader assumes the posting is gone rather than that our link rotted.
 *
 * So this fetches each link and demotes anything that no longer resolves to a real page:
 *
 *   deep    the URL still returns a page at the path we recorded
 *   search  the URL is a portal's search-results page; the card names what to search for
 *   portal  the URL is a portal home; the card names what to search for
 *
 * A demoted deep link also gets its URL rewritten to the section's matching portal, so a
 * click still goes somewhere useful instead of the dead path.
 *
 * SAFE BY DESIGN: this never fails the pipeline. Being unable to reach the network is not
 * evidence a link is broken, so an unreachable check leaves link_type alone. It exits 0
 * even when every request fails; run-weekly.sh runs it ahead of the real gates.
 *
 * Usage: node scripts/check-links.js [--dry-run] [--timeout MS]
 */
"use strict";
const fs = require("fs");
const path = require("path");

const ROOT = path.resolve(__dirname, "..");
const SECTIONS = ["jobs", "postdoc", "grants"];

const argv = process.argv.slice(2);
const DRY = argv.includes("--dry-run");
const tIdx = argv.indexOf("--timeout");
const TIMEOUT = tIdx >= 0 ? Number(argv[tIdx + 1]) : 15000;

const UA =
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) " +
  "Chrome/128.0 Safari/537.36 bdpl-dashboard-linkcheck";

const readJson = (rel) => JSON.parse(fs.readFileSync(path.join(ROOT, rel), "utf8"));
const writeJson = (rel, o) =>
  fs.writeFileSync(path.join(ROOT, rel), JSON.stringify(o, null, 2).replace(/\r?\n/g, "\r\n") + "\r\n");

/* A path that is just "/" — or a site's landing page — means the deep URL was thrown away
   by the server rather than served. Many portals answer a dead posting id with a 302 to
   their own front page and a 200, which is indistinguishable from success on status alone. */
const isHomePath = (p) => !p || p === "/" || /^\/(index|home|main)(\.[a-z]+)?\/?$/i.test(p);

/* Login walls answer 200 from an auth page. Match on where we landed, not on status. */
const LOGIN = /(login|signin|sign-in|auth|idp\.|sso|account\/|session\/new|\.auth\.)/i;

/* A soft 404: the server answers 200 and serves an error stub instead of the page.
   Status alone cannot see it, and neither can a text search — svakorea.org's real
   announcement page contains the string "404" somewhere in its own markup, same as its
   error stub. What separates them is bulk and a title: the stub was 2,675 bytes with no
   <title>, the real page 628,528 bytes with one. So: no title AND a tiny body, or a
   title that says the page is missing.

   Checked for deep links only. A demotion here costs a card its "open posting" label and
   nothing else, so erring toward demotion is the safe direction — the opposite error
   sends a reader to a blank page believing the posting is gone. */
const NOTFOUND_TITLE = /(not found|no longer|찾을 수 없|존재하지 않|삭제된|error|404)/i;
function soft404(body) {
  if (typeof body !== "string") return null;
  const m = body.match(/<title[^>]*>([^<]*)<\/title>/i);
  const title = m ? m[1].trim() : "";
  if (title && NOTFOUND_TITLE.test(title)) return 'the page title says it is missing: "' + title.slice(0, 60) + '"';
  if (!title && body.length < 4000) return "served a " + body.length + "-byte stub with no <title> (soft 404)";
  return null;
}

async function probe(url, wantBody) {
  const opts = {
    redirect: "follow",
    signal: AbortSignal.timeout(TIMEOUT),
    headers: { "User-Agent": UA, Accept: "text/html,application/xhtml+xml,*/*" },
  };
  let res;
  try {
    res = await fetch(url, Object.assign({ method: "HEAD" }, opts));
    // HEAD support is unreliable and its failures are not evidence about the page: the
    // Korean agency portals answer HEAD with 400 and GET with 200, and plenty of sites
    // answer 403 or 405. Any 4xx/5xx from HEAD gets re-asked with GET, and the GET is
    // what counts -- including for a real 404, which then has two observations behind it.
    if (res.status >= 400) res = await fetch(url, Object.assign({ method: "GET" }, opts));
  } catch (e) {
    try {
      res = await fetch(url, Object.assign({ method: "GET" }, opts));
    } catch (e2) {
      return { ok: false, reason: "unreachable: " + (e2.message || e2), network: true };
    }
  }

  const finalUrl = res.url || url;
  let from, to;
  try { from = new URL(url); to = new URL(finalUrl); } catch (e) {
    return { ok: false, reason: "unparseable URL", network: true };
  }

  if (res.status === 404 || res.status === 410)
    return { ok: false, reason: "HTTP " + res.status, final: finalUrl };
  if (res.status === 401)
    return { ok: false, reason: "login wall (HTTP 401)", final: finalUrl };
  if (LOGIN.test(to.pathname + to.hostname))
    return { ok: false, reason: "redirected to a login page: " + finalUrl, final: finalUrl };
  // Landed on a home page after asking for a deeper path: the path is gone.
  if (!isHomePath(from.pathname) && isHomePath(to.pathname) && !to.search)
    return { ok: false, reason: "redirected to the site home: " + finalUrl, final: finalUrl };
  if (to.hostname !== from.hostname && isHomePath(to.pathname))
    return { ok: false, reason: "redirected off-host to a home page: " + finalUrl, final: finalUrl };
  if (res.status >= 400)
    return { ok: false, reason: "HTTP " + res.status, final: finalUrl, soft: res.status === 403 };

  if (wantBody) {
    let body = null;
    try {
      body = await (await fetch(url, Object.assign({ method: "GET" }, opts))).text();
    } catch (e) {
      return { ok: true, status: res.status, final: finalUrl }; // could not re-read; do not punish
    }
    const why = soft404(body);
    if (why) return { ok: false, reason: why, final: finalUrl };
  }
  return { ok: true, status: res.status, final: finalUrl };
}

/* When a deep link dies, send the reader to the portal for the same site if there is one,
   and to the section's first portal otherwise. Both are already in the file and already
   guarded by gen-seeds, so this cannot invent a destination. */
function fallbackFor(item, portals) {
  const list = (portals || []).map((p) => String(p.url || "")).filter(Boolean);
  if (!list.length) return null;
  let host = null;
  try { host = new URL(item.link).hostname.replace(/^www\./, ""); } catch (e) {}
  if (host) {
    const same = list.find((u) => {
      try { return new URL(u).hostname.replace(/^www\./, "") === host; } catch (e) { return false; }
    });
    if (same) return same;
  }
  return list[0];
}

(async () => {
  let checked = 0, demoted = 0, confirmed = 0, skipped = 0, netFail = 0;
  const notes = [];

  for (const name of SECTIONS) {
    const rel = "data/" + name + ".json";
    const d = readJson(rel);
    let touched = false;

    for (let i = 0; i < d.items.length; i++) {
      const x = d.items[i];
      const at = name + "[" + i + "]";

      // No URL at all is a legitimate state (an expired listing with no replacement).
      if (!x.link) {
        if (x.link_type !== "search" && x.link_type !== "portal") {
          x.link_type = "search";
          touched = true;
          notes.push(at + ": no URL -> link_type=search");
        }
        skipped++;
        continue;
      }

      const r = await probe(x.link, x.link_type === "deep");
      checked++;
      await new Promise((s) => setTimeout(s, 150));

      if (r.network) {
        netFail++;
        notes.push(at + ": " + r.reason + " — left as " + (x.link_type || "unset") + " (not evidence of a bad link)");
        continue;
      }

      if (r.ok) {
        confirmed++;
        continue;
      }

      // A 403 is usually bot-blocking, not a dead page. Do not rewrite the URL on that
      // alone; only stop calling it a deep link.
      if (r.soft) {
        if (x.link_type !== "deep") { confirmed++; continue; }
        {
          x.link_type = "portal";
          touched = true;
          demoted++;
          notes.push(at + ": " + r.reason + " (bot block) -> deep demoted to portal, URL kept");
        }
        continue;
      }

      const fb = fallbackFor(x, d.portals);
      const was = x.link_type || "unset";
      if (was === "portal" && (!fb || fb === x.link)) { confirmed++; continue; } // already the weakest claim
      if (fb && fb !== x.link) {
        x.link = fb;
        x.link_type = "portal";
      } else {
        x.link_type = "portal";
      }
      touched = true;
      demoted++;
      notes.push(at + ": " + r.reason + " -> " + was + " demoted to portal" + (fb && fb !== x.link ? "" : " (URL -> " + x.link + ")"));
    }

    // Every non-deep card has to name what the reader should search for, or the label
    // renders as an empty quote. Fall back to the title, which is the posting name.
    for (const x of d.items) {
      if (x.link_type !== "deep" && (!x.query || !String(x.query).trim())) {
        x.query = x.title;
        touched = true;
      }
    }

    if (touched && !DRY) writeJson(rel, d);
  }

  for (const n of notes) console.log("  " + n);
  console.log(
    "link check " + (DRY ? "(dry-run) " : "") + "done: " + checked + " fetched, " +
    confirmed + " confirmed, " + demoted + " demoted, " + skipped + " without a URL" +
    (netFail ? ", " + netFail + " unreachable (left alone)" : "")
  );
})().catch((e) => {
  // Never fail the pipeline on this. A broken checker must not block a good week.
  console.log("link check SKIPPED — " + (e && e.message ? e.message : e));
  process.exit(0);
});
