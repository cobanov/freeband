// The pages (home, story, guide, privacy) exist in English and Turkish. English
// lives at the root ("/", "/story"), Turkish under "/tr".

export type Lang = "en" | "tr";

/** A string in both languages. */
export type Text = Record<Lang, string>;

/** The path of a public page in a language: ("tr", "/story") → "/tr/story". */
export function localPath(lang: Lang, path: string): string {
  if (lang === "en") return path;
  return path === "/" ? "/tr" : `/tr${path}`;
}

/** Both language versions of a public page, for the switcher and hreflang links. */
export function alternates(path: string): Record<Lang, string> {
  return { en: localPath("en", path), tr: localPath("tr", path) };
}
