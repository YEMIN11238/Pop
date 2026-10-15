(() => {
  "use strict";

  const repository = "YEMIN11238/Pop";
  const apiURL = `https://api.github.com/repos/${repository}/releases/latest`;

  // Download URLs must point to this repository's HTTPS release assets.
  // Never navigate to a URL supplied in the page query string.
  function trustedAssetURL(asset) {
    if (!asset || typeof asset.browser_download_url !== "string" || typeof asset.name !== "string") return null;
    try {
      const url = new URL(asset.browser_download_url);
      const prefix = `/${repository}/releases/download/`;
      const components = url.pathname.slice(prefix.length).split("/");
      if (url.protocol !== "https:" || url.host !== "github.com" || url.username || url.password || url.search || url.hash) return null;
      if (!url.pathname.startsWith(prefix) || components.length !== 2 || !components[0]) return null;
      if (decodeURIComponent(components[1]) !== asset.name) return null;
      return url.href;
    } catch {
      return null;
    }
  }

  async function latestRelease() {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 10000);
    try {
      const response = await fetch(apiURL, {
        headers: { Accept: "application/vnd.github+json" },
        credentials: "omit",
        referrerPolicy: "no-referrer",
        signal: controller.signal
      });
      if (!response.ok) throw new Error("Release information unavailable");
      const release = await response.json();
      if (release.draft || release.prerelease || !Array.isArray(release.assets) || typeof release.tag_name !== "string") {
        throw new Error("Invalid latest release");
      }
      return release;
    } finally {
      clearTimeout(timeout);
    }
  }

  function initializeDemo() {
    const toggle = document.querySelector("[data-motion-toggle]");
    if (!toggle) return;
    toggle.hidden = false;
    const demo = toggle.closest(".hero-demo");
    const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
    let paused = reducedMotion.matches;
    function update() {
      demo.classList.toggle("is-paused", paused);
      demo.classList.toggle("motion-enabled", !paused);
      toggle.textContent = paused ? "播放动图" : "暂停动图";
      toggle.setAttribute("aria-pressed", String(paused));
    }
    update();
    toggle.addEventListener("click", () => { paused = !paused; update(); });
    reducedMotion.addEventListener("change", (event) => { paused = event.matches; update(); });
  }

  async function initializeRelease() {
    const downloadPage = document.body.hasAttribute("data-download-page");
    const status = document.getElementById("download-status");
    try {
      const release = await latestRelease();
      const version = release.tag_name.slice(0, 64);
      document.querySelectorAll("[data-latest-version]").forEach((element) => { element.textContent = version; });
      if (!downloadPage) return;

      const requestedFormat = new URLSearchParams(window.location.search).get("format");
      const format = requestedFormat === "zip" ? "zip" : "dmg";
      const assetPattern = new RegExp(`^Pop-[0-9A-Za-z][0-9A-Za-z.+_-]*-universal\\.${format}$`);
      const asset = release.assets.find((item) => assetPattern.test(item.name) && trustedAssetURL(item));
      if (!asset) throw new Error("No universal package in latest release");

      const button = document.getElementById("download-file");
      button.href = trustedAssetURL(asset);
      button.textContent = `下载 ${version} · ${format.toUpperCase()}`;
      button.hidden = false;
      status.textContent = `已找到最新正式版 ${version}`;
      const detail = document.getElementById("file-detail");
      const size = Number.isFinite(asset.size) && asset.size > 0 ? ` · ${(asset.size / 1024 / 1024).toFixed(1)} MB` : "";
      detail.textContent = `${asset.name}${size}`;
      detail.hidden = false;

      const checksums = release.assets.find((item) => item.name === "SHA256SUMS.txt" && trustedAssetURL(item));
      if (checksums) {
        const checksumLink = document.getElementById("checksum-link");
        checksumLink.href = trustedAssetURL(checksums);
        checksumLink.hidden = false;
      }
    } catch {
      if (downloadPage && status) {
        status.textContent = "暂时无法读取最新版本。请使用下方「进入最新 Release」入口，在 Assets 中选择 DMG 或 ZIP。";
      }
      // The permanent GitHub /releases/latest link remains usable when the
      // API is offline, rate limited, or blocked. No hard-coded version fallback.
    }
  }

  initializeDemo();
  initializeRelease();
})();
