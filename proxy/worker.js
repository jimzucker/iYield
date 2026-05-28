// Copyright 2026 James A. Zucker
// Licensed under the Apache License, Version 2.0. See ../LICENSE and ../NOTICE.
//
// Minimal CORS proxy for the TrueYield web build. Forwards GET requests for the
// Yahoo Finance chart endpoint and adds permissive CORS headers so the browser
// build can fetch data (Yahoo's endpoint sends no Access-Control-Allow-Origin).
//
// It is deliberately narrow: only /v8/finance/chart/* is proxied, and only GET.
// Deploy with Cloudflare Wrangler — see README.md in this folder.

const YAHOO = "https://query2.finance.yahoo.com";
const ALLOWED_PREFIX = "/v8/finance/chart/";

function corsHeaders() {
  return {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "GET, OPTIONS",
    "Access-Control-Allow-Headers": "*",
    "Access-Control-Max-Age": "86400",
  };
}

export default {
  async fetch(request) {
    const url = new URL(request.url);

    if (request.method === "OPTIONS") {
      return new Response(null, { headers: corsHeaders() });
    }
    if (request.method !== "GET") {
      return new Response("Method not allowed", {
        status: 405,
        headers: corsHeaders(),
      });
    }
    if (!url.pathname.startsWith(ALLOWED_PREFIX)) {
      return new Response("Not found", {
        status: 404,
        headers: corsHeaders(),
      });
    }

    const target = YAHOO + url.pathname + url.search;
    const upstream = await fetch(target, {
      headers: {
        // Yahoo rejects requests without a browser-like User-Agent.
        "User-Agent":
          "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15",
        Accept: "application/json",
      },
    });

    const body = await upstream.text();
    return new Response(body, {
      status: upstream.status,
      headers: {
        ...corsHeaders(),
        "Content-Type": "application/json; charset=utf-8",
        // Let the browser cache identical lookups briefly.
        "Cache-Control": "public, max-age=60",
      },
    });
  },
};
