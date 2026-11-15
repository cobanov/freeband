// Server-rendered public pages: /, /story, /guide, /privacy, each also under /tr.

import { Hono, type Context } from "hono";
import type { AppEnv } from "../types";
import type { Safe } from "../views/html";
import { page, type OpenGraph } from "../views/layout";
import { PRIVACY_TITLE, privacyBody } from "../views/privacy";
import { GUIDE_DESCRIPTION, GUIDE_TITLE, guideBody } from "../views/guide";
import { HOME_DESCRIPTION, HOME_IMAGE_ALT, HOME_TITLE, homeBody } from "../views/home";
import { alternates, localPath, type Lang } from "../views/i18n";
import { STORY_DESCRIPTION, STORY_IMAGE_ALT, STORY_TITLE, storyBody } from "../views/story";

export const pages = new Hono<AppEnv>();

function render(
  c: Context<AppEnv>,
  title: string,
  body: Safe,
  extra: { description?: string; og?: OpenGraph; lang: Lang; alternates: Record<Lang, string> },
) {
  return c.html(page({ title, nonce: c.get("nonce"), body, path: c.req.path, analytics: true, ...extra }));
}

/** Open Graph data for a public page; absolute URLs on the public hostname. */
function og(c: Context<AppEnv>, path: string, image: string, imageAlt: string): OpenGraph {
  const origin = `https://${c.env.PUBLIC_HOSTNAME}`;
  return { url: origin + path, image: `${origin}/img/${image}`, imageAlt };
}

// Public pages in English (root) and Turkish (/tr).
pages.get("/tr/", (c) => c.redirect("/tr", 301));
for (const lang of ["en", "tr"] as const) {
  const suffix = lang === "en" ? "" : `-${lang}`;

  pages.get(localPath(lang, "/"), (c) => {
    return render(c, HOME_TITLE[lang], homeBody({ lang, testflight: c.env.TESTFLIGHT_URL }), {
      lang,
      alternates: alternates("/"),
      description: HOME_DESCRIPTION[lang],
      og: og(c, localPath(lang, "/"), `og-home${suffix}.png`, HOME_IMAGE_ALT[lang]),
    });
  });

  pages.get(localPath(lang, "/story"), (c) => {
    return render(c, `${STORY_TITLE[lang]} · Freeband`, storyBody(lang), {
      lang,
      alternates: alternates("/story"),
      description: STORY_DESCRIPTION[lang],
      og: og(c, localPath(lang, "/story"), `og-story${suffix}.png`, STORY_IMAGE_ALT[lang]),
    });
  });

  pages.get(localPath(lang, "/guide"), (c) => {
    return render(c, `${GUIDE_TITLE[lang]} · Freeband`, guideBody(lang, c.env.TESTFLIGHT_URL), {
      lang,
      alternates: alternates("/guide"),
      description: GUIDE_DESCRIPTION[lang],
      og: og(c, localPath(lang, "/guide"), `og-home${suffix}.png`, HOME_IMAGE_ALT[lang]),
    });
  });

  pages.get(localPath(lang, "/privacy"), (c) => {
    return render(c, PRIVACY_TITLE[lang], privacyBody(lang), {
      lang,
      alternates: alternates("/privacy"),
      og: og(c, localPath(lang, "/privacy"), `og-home${suffix}.png`, HOME_IMAGE_ALT[lang]),
    });
  });
}
