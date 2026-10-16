// Shows the latest release's version and size, and copies commands on click.
(function () {
  'use strict';
  const repo = '__REPO__';
  if (!repo.includes('__')) {
    fetch(`https://api.github.com/repos/${repo}/releases/latest`)
      .then(response => (response.ok ? response.json() : null))
      .then(release => {
        if (!release) return;
        const dmg = (release.assets || []).find(asset => /\.dmg$/i.test(asset.name));
        const version = String(release.tag_name || '').replace(/^v/, '');
        if (version) document.querySelectorAll('[data-version]').forEach(el => { el.textContent = version; });
        if (dmg) {
          const size = dmg.size >= 1048576 ? `${(dmg.size / 1048576).toFixed(1)} MB` : `${Math.round(dmg.size / 1024)} KB`;
          document.querySelectorAll('[data-size]').forEach(el => { el.textContent = size; });
          document.querySelectorAll('[data-download]').forEach(el => { el.href = dmg.browser_download_url; });
        }
      })
      .catch(() => {});
  }

  document.querySelectorAll('[data-copy]').forEach(el => {
    el.title = 'Click to copy';
    el.addEventListener('click', () => {
      navigator.clipboard.writeText(el.dataset.copy).then(() => {
        el.classList.add('copied');
        setTimeout(() => el.classList.remove('copied'), 1200);
      }).catch(() => {});
    });
  });
})();
