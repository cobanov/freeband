import { describe, expect, it } from "vitest";
import { call } from "./helpers";

describe("/join", () => {
  it("explains the steps and builds the app link from the fragment only", async () => {
    const res = await call("/tr/join");
    expect(res.status).toBe(200);
    const page = await res.text();
    for (const s of ["Freeband&#39;e katıl", "Mi Fitness", "freeband://join?invite=", "join-code"]) expect(page).toContain(s);
    // The public TestFlight link from wrangler.jsonc.
    expect(page).toContain('<a href="https://testflight.apple.com/join/Qq9A6c1E">Freeband\'i TestFlight\'tan kur</a>');
    const en = await (await call("/join")).text();
    for (const s of ["Join Freeband", "Install the app.", "freeband://join?invite=", "Install Freeband from TestFlight"]) expect(en).toContain(s);
  });

  it("sends Turkish browsers to /tr/join and /tr/login, keeping the query", async () => {
    const tr = { headers: { "Accept-Language": "tr-TR,tr;q=0.9,en;q=0.8" }, redirect: "manual" as const };
    const join = await call("/join?x=1", tr);
    expect(join.status).toBe(302);
    expect(join.headers.get("location")).toBe("/tr/join?x=1");
    const login = await call("/login", tr);
    expect(login.status).toBe(302);
    expect(login.headers.get("location")).toBe("/tr/login");
    const en = await call("/login", { headers: { "Accept-Language": "en-GB,en;q=0.9,tr;q=0.5" }, redirect: "manual" });
    expect(en.status).toBe(200);
  });
});
