const fs = require('fs');
const path = require('path');

const releasesPath = path.join(__dirname, '..', 'releases.json');
const outputPath = path.join(__dirname, '..', 'index.html');

const data = JSON.parse(fs.readFileSync(releasesPath, 'utf8'));
const domain = data.domain;
const baseUrl = `https://${domain}`;

function formatDate(dateStr) {
    const date = new Date(dateStr);
    return date.toLocaleDateString('en-US', { year: 'numeric', month: 'long', day: 'numeric' });
}

function generateReleaseCard(release, repo) {
    const badges = [];
    if (release.latest) {
        badges.push('<span class="release-badge latest">Latest</span>');
    }
    if (release.badges) {
        release.badges.forEach(badge => {
            badges.push(`<span class="release-badge arm">${badge}</span>`);
        });
    }

    const assetsHtml = release.assets.map(asset => {
        const downloadUrl = `downloads/agent/${release.version}/${asset.name}`;
        const sha256Url = `downloads/agent/${release.version}/${asset.name}.sha256`;

        return `
                            <div class="asset-row">
                                <div class="asset-info">
                                    <span class="asset-name">${asset.name}</span>
                                    <span class="asset-arch">${asset.arch}</span>
                                </div>
                                <div class="asset-actions">
                                    ${asset.hasSha256 ? `<a href="${sha256Url}" class="btn-hash" title="Download SHA256">SHA256</a>` : ''}
                                    <a href="${downloadUrl}" class="btn-download">Download</a>
                                </div>
                            </div>`;
    }).join('');

    return `
                    <div class="release-card">
                        <div class="release-header">
                            <div class="release-info">
                                <span class="release-version">${release.version}</span>
                                ${badges.join('\n                                ')}
                            </div>
                            <span class="release-date">${formatDate(release.date)}</span>
                        </div>
                        <div class="release-assets">${assetsHtml}
                        </div>
                    </div>`;
}

function generateWindowsCard(windows) {
    const assetsHtml = windows.assets.map(asset => {
        const downloadUrl = `downloads/agent/windows/${asset.name}`;
        const sha256Url = `downloads/agent/windows/${asset.name}.sha256`;

        return `
                            <div class="asset-row">
                                <div class="asset-info">
                                    <span class="asset-name">${asset.name}</span>
                                    <span class="asset-arch">${asset.description}</span>
                                </div>
                                <div class="asset-actions">
                                    ${asset.hasSha256 ? `<a href="${sha256Url}" class="btn-hash" title="Download SHA256">SHA256</a>` : ''}
                                    <a href="${downloadUrl}" class="btn-download">Download</a>
                                </div>
                            </div>`;
    }).join('');

    return `
                    <div class="release-card windows-card">
                        <div class="release-header">
                            <div class="release-info">
                                <span class="release-version">Windows</span>
                                <span class="release-badge windows">Windows x64</span>
                            </div>
                        </div>
                        <div class="release-assets">${assetsHtml}
                        </div>
                    </div>`;
}

const COPY_BTN_SVG = `<svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor">
                                    <path d="M0 6.75C0 5.784.784 5 1.75 5h1.5a.75.75 0 010 1.5h-1.5a.25.25 0 00-.25.25v7.5c0 .138.112.25.25.25h7.5a.25.25 0 00.25-.25v-1.5a.75.75 0 011.5 0v1.5A1.75 1.75 0 019.25 16h-7.5A1.75 1.75 0 010 14.25v-7.5z"/>
                                    <path d="M5 1.75C5 .784 5.784 0 6.75 0h7.5C15.216 0 16 .784 16 1.75v7.5A1.75 1.75 0 0114.25 11h-7.5A1.75 1.75 0 015 9.25v-7.5zm1.75-.25a.25.25 0 00-.25.25v7.5c0 .138.112.25.25.25h7.5a.25.25 0 00.25-.25v-7.5a.25.25 0 00-.25-.25h-7.5z"/>
                                </svg>`;

function escapeHtml(s) {
    return String(s)
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;');
}

function renderOptionsList(options) {
    return options.map(o =>
        `<li><code>${escapeHtml(o.flag)}</code> — ${o.desc}</li>`
    ).join('\n                                ');
}

function renderOptionGroup(group) {
    return `<div class="opt-group">
                            <h5>${group.title}</h5>
                            <ul class="standalone-options">
                                ${renderOptionsList(group.options)}
                            </ul>
                        </div>`;
}

function generateStandaloneSection(standalone) {
    const installCmd = `curl -fsSL ${baseUrl}/${standalone.installerFile} | sudo bash -s -- --api-version=VERSION --ui-version=VERSION --domain=YOUR_DOMAIN_OR_IP --postgres=local`;

    const featuresHtml = standalone.features.map(f =>
        `<li>${f}</li>`
    ).join('\n                                ');

    const osHtml = standalone.supportedOS.map(os =>
        `<span class="os-badge">${os}</span>`
    ).join('\n                            ');

    const installNote = standalone.installNote
        || 'Replace <code>VERSION</code> with the desired version numbers. API and UI versions can differ.';

    const nginxDescription = standalone.nginxDescription
        || 'Reverse proxy — TLS, HTTP/2, gRPC';

    // Install option groups (preferred) — fall back to flat options array.
    let installOptionsHtml;
    if (standalone.installOptionGroups) {
        installOptionsHtml = standalone.installOptionGroups
            .map(renderOptionGroup)
            .join('\n                        ');
    } else {
        installOptionsHtml = `<ul class="standalone-options">
                                ${renderOptionsList(standalone.options || [])}
                            </ul>`;
    }

    // Upgrade card
    const upgrade = standalone.upgrade;
    const upgradeCard = upgrade ? `
                    <div class="standalone-card">
                        <h4>Upgrade (upgrade.sh)</h4>
                        <p class="install-note">${upgrade.description}</p>
                        <div class="code-block">
                            <code id="upgrade-cmd">${upgrade.command.replace('{BASE_URL}', baseUrl)}</code>
                            <button class="copy-btn" onclick="copyToClipboard('upgrade-cmd')" title="Copy to clipboard">
                                ${COPY_BTN_SVG}
                            </button>
                        </div>
                        <div class="opt-group">
                            <h5>Options</h5>
                            <ul class="standalone-options">
                                ${renderOptionsList(upgrade.options)}
                            </ul>
                        </div>${upgrade.note ? `
                        <p class="install-note">${upgrade.note}</p>` : ''}
                    </div>` : '';

    // Uninstall card
    const uninstall = standalone.uninstall;
    const uninstallCard = uninstall ? `
                    <div class="standalone-card">
                        <h4>Uninstall (uninstall.sh)</h4>
                        <p class="install-note">${uninstall.description}</p>
                        <div class="code-block">
                            <code id="uninstall-cmd">${uninstall.command}</code>
                            <button class="copy-btn" onclick="copyToClipboard('uninstall-cmd')" title="Copy to clipboard">
                                ${COPY_BTN_SVG}
                            </button>
                        </div>
                        <div class="opt-group">
                            <h5>Options</h5>
                            <ul class="standalone-options">
                                ${renderOptionsList(uninstall.options)}
                            </ul>
                        </div>
                    </div>` : '';

    return `
                <div class="standalone-section">
                    <div class="standalone-hero">
                        <div class="standalone-hero-content">
                            <div class="standalone-icon">
                                <svg width="32" height="32" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                                    <rect x="2" y="2" width="20" height="8" rx="2" ry="2"></rect>
                                    <rect x="2" y="14" width="20" height="8" rx="2" ry="2"></rect>
                                    <line x1="6" y1="6" x2="6.01" y2="6"></line>
                                    <line x1="6" y1="18" x2="6.01" y2="18"></line>
                                </svg>
                            </div>
                            <div>
                                <h3>Standalone Installation</h3>
                                <p>${standalone.description}</p>
                            </div>
                        </div>
                        <div class="os-badges">
                            ${osHtml}
                        </div>
                    </div>

                    <div class="standalone-install">
                        <h4>Quick Install</h4>
                        <div class="code-block">
                            <code id="standalone-cmd">${installCmd}</code>
                            <button class="copy-btn" onclick="copyToClipboard('standalone-cmd')" title="Copy to clipboard">
                                ${COPY_BTN_SVG}
                            </button>
                        </div>
                        <p class="install-note">${installNote}</p>
                    </div>

                    <div class="standalone-grid">
                        <div class="standalone-card">
                            <h4>Components</h4>
                            <div class="component-list">
                                <div class="component-item">
                                    <span class="component-name">${standalone.components.api.name}</span>
                                    <span class="component-desc">${standalone.components.api.description}</span>
                                </div>
                                <div class="component-item">
                                    <span class="component-name">${standalone.components.ui.name}</span>
                                    <span class="component-desc">${standalone.components.ui.description}</span>
                                </div>
                                <div class="component-item">
                                    <span class="component-name">nginx</span>
                                    <span class="component-desc">${nginxDescription}</span>
                                </div>
                                <div class="component-item">
                                    <span class="component-name">PostgreSQL</span>
                                    <span class="component-desc">Local or external database</span>
                                </div>
                                <div class="component-item">
                                    <span class="component-name">InfluxDB</span>
                                    <span class="component-desc">Optional time-series metrics</span>
                                </div>
                            </div>
                        </div>

                        <div class="standalone-card">
                            <h4>Features</h4>
                            <ul class="standalone-features">
                                ${featuresHtml}
                            </ul>
                        </div>
                    </div>

                    <div class="standalone-card">
                        <h4>Install Options (install.sh)</h4>
                        ${installOptionsHtml}
                    </div>${upgradeCard}${uninstallCard}

                    <div class="standalone-scripts">
                        <div class="standalone-script-row">
                            <div class="script-info">
                                <span class="asset-name">install.sh</span>
                                <span class="asset-arch">Installer</span>
                            </div>
                            <a href="${standalone.installerFile}" download class="btn-download">Download</a>
                        </div>
                        <div class="standalone-script-row">
                            <div class="script-info">
                                <span class="asset-name">upgrade.sh</span>
                                <span class="asset-arch">Upgrader</span>
                            </div>
                            <a href="deploy/standalone/upgrade.sh" download class="btn-download">Download</a>
                        </div>
                        <div class="standalone-script-row">
                            <div class="script-info">
                                <span class="asset-name">uninstall.sh</span>
                                <span class="asset-arch">Uninstaller</span>
                            </div>
                            <a href="deploy/standalone/uninstall.sh" download class="btn-download">Download</a>
                        </div>
                    </div>
                </div>`;
}

function generateScriptCard(script, type) {
    const usageCmd = type === 'stack'
        ? `curl -sSL ${baseUrl}/${script.file} | bash`
        : `curl -sSL ${baseUrl}/${script.file} | sudo bash -s -- -p postgres`;

    let optionsHtml = '';
    if (script.features) {
        optionsHtml = `
                            <h4>Features:</h4>
                            <ul>
                                ${script.features.map(f => `<li>${f}</li>`).join('\n                                ')}
                            </ul>`;
    } else if (script.options) {
        optionsHtml = `
                            <h4>Options:</h4>
                            <ul>
                                ${script.options.map(o => `<li><code>${o.flag}</code> - ${o.desc}</li>`).join('\n                                ')}
                            </ul>`;
    }

    const icon = type === 'stack'
        ? `<svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                                <rect x="2" y="3" width="20" height="14" rx="2" ry="2"></rect>
                                <line x1="8" y1="21" x2="16" y2="21"></line>
                                <line x1="12" y1="17" x2="12" y2="21"></line>
                            </svg>`
        : `<svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                                <polyline points="4 17 10 11 4 5"></polyline>
                                <line x1="12" y1="19" x2="20" y2="19"></line>
                            </svg>`;

    return `
                    <div class="script-card">
                        <div class="script-icon">
                            ${icon}
                        </div>
                        <h3>${script.name}</h3>
                        <p>${script.description}</p>
                        <div class="script-usage">
                            <div class="code-block small">
                                <code>${usageCmd}</code>
                            </div>
                        </div>
                        <div class="script-options">${optionsHtml}
                        </div>
                        <a href="${script.file}" download class="btn-download full-width">Download ${script.file}</a>
                    </div>`;
}

const latestVersion = data.agent.releases.find(r => r.latest)?.version || data.agent.releases[0].version;

const html = `<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>ClusterEye Archive - Official Downloads</title>
    <link rel="stylesheet" href="style.css">
    <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&display=swap" rel="stylesheet">
</head>
<body>
    <header>
        <div class="container">
            <div class="logo">ClusterEye<span class="logo-accent">Archive</span></div>
            <p class="subtitle">Pre-compiled binaries and installation scripts for ClusterEye</p>
        </div>
    </header>

    <main class="container">
        <!-- Quick Install Section -->
        <section class="section">
            <h2 class="section-title">Quick Install</h2>
            <div class="install-cards">
                <div class="install-card">
                    <div class="install-header">
                        <span class="install-icon">$</span>
                        <span class="install-label">Full Stack (Kind + Helm)</span>
                    </div>
                    <div class="code-block">
                        <code id="stack-cmd">curl -sSL ${baseUrl}/${data.scripts.stack.file} | bash</code>
                        <button class="copy-btn" onclick="copyToClipboard('stack-cmd')" title="Copy to clipboard">
                            <svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor">
                                <path d="M0 6.75C0 5.784.784 5 1.75 5h1.5a.75.75 0 010 1.5h-1.5a.25.25 0 00-.25.25v7.5c0 .138.112.25.25.25h7.5a.25.25 0 00.25-.25v-1.5a.75.75 0 011.5 0v1.5A1.75 1.75 0 019.25 16h-7.5A1.75 1.75 0 010 14.25v-7.5z"/>
                                <path d="M5 1.75C5 .784 5.784 0 6.75 0h7.5C15.216 0 16 .784 16 1.75v7.5A1.75 1.75 0 0114.25 11h-7.5A1.75 1.75 0 015 9.25v-7.5zm1.75-.25a.25.25 0 00-.25.25v7.5c0 .138.112.25.25.25h7.5a.25.25 0 00.25-.25v-7.5a.25.25 0 00-.25-.25h-7.5z"/>
                            </svg>
                        </button>
                    </div>
                    <p class="install-note">Installs Kind, Helm, and the complete ClusterEye stack on Ubuntu 24.04</p>
                </div>
                <div class="install-card">
                    <div class="install-header">
                        <span class="install-icon">$</span>
                        <span class="install-label">Standalone (Bare-Metal)</span>
                    </div>
                    <div class="code-block">
                        <code id="standalone-quick-cmd">curl -fsSL ${baseUrl}/${data.standalone.installerFile} | sudo bash -s -- --api-version=VERSION --ui-version=VERSION --domain=YOUR_DOMAIN_OR_IP --postgres=local</code>
                        <button class="copy-btn" onclick="copyToClipboard('standalone-quick-cmd')" title="Copy to clipboard">
                            <svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor">
                                <path d="M0 6.75C0 5.784.784 5 1.75 5h1.5a.75.75 0 010 1.5h-1.5a.25.25 0 00-.25.25v7.5c0 .138.112.25.25.25h7.5a.25.25 0 00.25-.25v-1.5a.75.75 0 011.5 0v1.5A1.75 1.75 0 019.25 16h-7.5A1.75 1.75 0 010 14.25v-7.5z"/>
                                <path d="M5 1.75C5 .784 5.784 0 6.75 0h7.5C15.216 0 16 .784 16 1.75v7.5A1.75 1.75 0 0114.25 11h-7.5A1.75 1.75 0 015 9.25v-7.5zm1.75-.25a.25.25 0 00-.25.25v7.5c0 .138.112.25.25.25h7.5a.25.25 0 00.25-.25v-7.5a.25.25 0 00-.25-.25h-7.5z"/>
                            </svg>
                        </button>
                    </div>
                    <p class="install-note">Full platform on bare-metal Linux — no Docker required</p>
                </div>
                <div class="install-card">
                    <div class="install-header">
                        <span class="install-icon">$</span>
                        <span class="install-label">Agent Only (Linux)</span>
                    </div>
                    <div class="code-block">
                        <code id="agent-cmd">curl -sSL ${baseUrl}/${data.scripts.agent.file} | sudo bash -s -- -p postgres</code>
                        <button class="copy-btn" onclick="copyToClipboard('agent-cmd')" title="Copy to clipboard">
                            <svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor">
                                <path d="M0 6.75C0 5.784.784 5 1.75 5h1.5a.75.75 0 010 1.5h-1.5a.25.25 0 00-.25.25v7.5c0 .138.112.25.25.25h7.5a.25.25 0 00.25-.25v-1.5a.75.75 0 011.5 0v1.5A1.75 1.75 0 019.25 16h-7.5A1.75 1.75 0 010 14.25v-7.5z"/>
                                <path d="M5 1.75C5 .784 5.784 0 6.75 0h7.5C15.216 0 16 .784 16 1.75v7.5A1.75 1.75 0 0114.25 11h-7.5A1.75 1.75 0 015 9.25v-7.5zm1.75-.25a.25.25 0 00-.25.25v7.5c0 .138.112.25.25.25h7.5a.25.25 0 00.25-.25v-7.5a.25.25 0 00-.25-.25h-7.5z"/>
                            </svg>
                        </button>
                    </div>
                    <p class="install-note">Platforms: <code>postgres</code>, <code>mongo</code>, <code>mssql</code></p>
                </div>
            </div>
        </section>

        <!-- Tabs Navigation -->
        <section class="section">
            <div class="tabs">
                <button class="tab active" data-tab="standalone">Standalone Install</button>
                <button class="tab" data-tab="agent">ClusterEye Agent</button>
                <button class="tab" data-tab="scripts">Install Scripts</button>
            </div>

            <!-- Standalone Tab Content -->
            <div class="tab-content active" id="standalone-content">
${generateStandaloneSection(data.standalone)}
            </div>

            <!-- Agent Tab Content -->
            <div class="tab-content" id="agent-content">
                <h3 class="platform-title">Linux Releases</h3>
                <div class="releases">
${data.agent.releases.map(r => generateReleaseCard(r, data.agent.repo)).join('\n')}
                </div>

                <h3 class="platform-title">Windows</h3>
                <div class="releases">
${generateWindowsCard(data.windows)}
                </div>
            </div>

            <!-- Scripts Tab Content -->
            <div class="tab-content" id="scripts-content">
                <div class="scripts-grid">
${generateScriptCard(data.scripts.stack, 'stack')}
${generateScriptCard(data.scripts.agent, 'agent')}
                </div>
            </div>
        </section>
    </main>

    <footer>
        <div class="container">
            <p>Maintained by <a href="https://github.com/CloudNativeWorks">CloudNativeWorks</a></p>
            <p class="footer-links">
                <a href="https://github.com/CloudNativeWorks/clustereye-agent">GitHub</a>
                <span class="separator">|</span>
                <a href="https://github.com/CloudNativeWorks/clustereye-agent/issues">Issues</a>
            </p>
        </div>
    </footer>

    <script>
        // Tab switching
        document.querySelectorAll('.tab').forEach(tab => {
            tab.addEventListener('click', () => {
                document.querySelectorAll('.tab').forEach(t => t.classList.remove('active'));
                document.querySelectorAll('.tab-content').forEach(c => c.classList.remove('active'));

                tab.classList.add('active');
                document.getElementById(tab.dataset.tab + '-content').classList.add('active');
            });
        });

        // Copy to clipboard
        function copyToClipboard(elementId) {
            const text = document.getElementById(elementId).textContent;
            navigator.clipboard.writeText(text).then(() => {
                const btn = document.querySelector(\`#\${elementId}\`).parentElement.querySelector('.copy-btn');
                btn.classList.add('copied');
                setTimeout(() => btn.classList.remove('copied'), 2000);
            });
        }
    </script>
</body>
</html>
`;

fs.writeFileSync(outputPath, html);
console.log('Generated index.html successfully');
