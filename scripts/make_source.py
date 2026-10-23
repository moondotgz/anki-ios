#!/usr/bin/env python3
"""Builds the AltStore / SideStore source (apps.json) from GitHub releases.

Each release whose tag starts with "build-" and that has an .ipa asset
becomes one version in the source, newest first.

Usage: make_source.py RELEASES_JSON SITE_URL OUTPUT
  RELEASES_JSON  output of `gh api repos/OWNER/REPO/releases --paginate`
  SITE_URL       public URL of the GitHub Pages site, ending in /
"""

import json
import sys

BUNDLE_ID = "com.moondotgz.ankiswift"
APP_NAME = "AnkiSwift"
TINT = "#346EF5"
MIN_OS = "26.0"

DESCRIPTION = (
    "An unofficial Anki flashcard app for iPhone and iPad with the iOS 26 Liquid Glass design.\n\n"
    "• Syncs with AnkiWeb or a self-hosted Anki sync server, including media\n"
    "• Anki's v3 SM-2 scheduler with learning steps, fuzz, leeches and burying\n"
    "• Renders Anki templates: cloze, type-in answers, hints, furigana, audio and images\n"
    "• Imports .apkg decks and .colpkg backups, exports .apkg\n"
    "• Note editor, browser with Anki search syntax, deck options and statistics\n\n"
    "Not affiliated with Ankitects. Anki is a trademark of Ankitects Pty Ltd."
)


def release_versions(releases):
    versions = []
    for rel in releases:
        if rel.get("draft") or not rel.get("tag_name", "").startswith("build-"):
            continue
        ipa = next((a for a in rel.get("assets", []) if a["name"].endswith(".ipa")), None)
        if ipa is None:
            continue
        # release bodies carry "<!-- version: X -->" and "<!-- build: N -->" lines
        meta = {}
        for line in (rel.get("body") or "").splitlines():
            if ":" in line and line.startswith("<!--"):
                key, _, value = line.strip("<!-> ").partition(":")
                meta[key.strip()] = value.strip()
        notes = "\n".join(l for l in (rel.get("body") or "").splitlines() if not l.startswith("<!--")).strip()
        versions.append({
            "version": meta.get("version", "1.0.0"),
            "buildVersion": meta.get("build", rel["tag_name"].removeprefix("build-")),
            "date": rel.get("published_at") or rel.get("created_at"),
            "localizedDescription": notes or rel.get("name") or "",
            "downloadURL": ipa["browser_download_url"],
            "size": ipa["size"],
            "minOSVersion": MIN_OS,
        })
    versions.sort(key=lambda v: int(v["buildVersion"]) if v["buildVersion"].isdigit() else 0, reverse=True)
    return versions


def main():
    releases_path, site_url, output = sys.argv[1:4]
    with open(releases_path) as f:
        releases = json.load(f)
    # `gh api --paginate --slurp` returns a list of pages
    if releases and all(isinstance(page, list) for page in releases):
        releases = [rel for page in releases for rel in page]
    versions = release_versions(releases)

    app = {
        "name": APP_NAME,
        "bundleIdentifier": BUNDLE_ID,
        "developerName": "moondotgz",
        "subtitle": "Anki-compatible flashcards with Liquid Glass.",
        "localizedDescription": DESCRIPTION,
        "iconURL": site_url + "icon.png",
        "tintColor": TINT,
        "category": "education",
        "screenshots": [],
        "versions": versions,
        "appPermissions": {
            "entitlements": [],
            "privacy": {
                "NSPhotoLibraryUsageDescription": "Add images from your photo library to your notes.",
            },
        },
    }
    # flat fields for older AltStore releases that predate "versions"
    if versions:
        latest = versions[0]
        app.update({
            "version": latest["version"],
            "versionDate": latest["date"],
            "versionDescription": latest["localizedDescription"],
            "downloadURL": latest["downloadURL"],
            "size": latest["size"],
        })

    source = {
        "name": "AnkiSwift",
        "identifier": BUNDLE_ID + ".source",
        "subtitle": "Unofficial Anki-compatible app for iOS",
        "description": DESCRIPTION,
        "iconURL": site_url + "icon.png",
        "website": site_url,
        "tintColor": TINT,
        "featuredApps": [BUNDLE_ID],
        "apps": [app],
        "news": [],
    }
    with open(output, "w") as f:
        json.dump(source, f, indent=2)
    print(f"wrote {output} with {len(versions)} version(s)")


if __name__ == "__main__":
    main()
