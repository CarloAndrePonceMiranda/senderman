let ws = null;
let autoScroll = true;
let currentFilesPath = '';
let currentFilesParentPath = '';

function escapeHtml(value) {
  return String(value).replace(/[&<>"]/g, match => ({
    '&': '&amp;',
    '<': '&lt;',
    '>': '&gt;',
    '"': '&quot;',
  }[match]));
}

function toast(msg, type = 'success') {
  const container = document.getElementById('toast-container');
  const id = 'toast-' + Date.now();
  const icon = type === 'success' ? 'bi-check-circle-fill text-success'
    : type === 'danger' ? 'bi-x-circle-fill text-danger'
    : 'bi-info-circle-fill text-info';
  container.insertAdjacentHTML('beforeend', `
    <div id="${id}" class="toast show mb-2 shadow" role="alert">
      <div class="toast-body d-flex align-items-center gap-2">
        <i class="bi ${icon}"></i> ${escapeHtml(msg)}
        <button type="button" class="btn-close btn-close-white ms-auto" data-bs-dismiss="toast"></button>
      </div>
    </div>`);
  setTimeout(() => document.getElementById(id)?.remove(), 3500);
}

function showUninstallShutdown() {
  const overlay = document.getElementById('uninstall-shutdown');
  const countdown = document.getElementById('uninstall-countdown');
  if (!overlay || !countdown) return;

  overlay.classList.remove('d-none');
  document.querySelectorAll('button, input, a').forEach(element => {
    element.setAttribute('disabled', 'disabled');
  });

  let remaining = 10;
  countdown.textContent = remaining;
  const timer = window.setInterval(() => {
    remaining -= 1;
    countdown.textContent = remaining;
    if (remaining > 0) return;

    window.clearInterval(timer);
    window.close();
    window.setTimeout(() => {
      window.open('', '_self');
      window.close();
      window.setTimeout(() => window.location.replace('about:blank'), 250);
    }, 150);
  }, 1000);
}

function setActiveTab(name) {
  document.querySelectorAll('[data-tab]').forEach(button => {
    button.classList.toggle('active', button.dataset.tab === name);
  });
}

function switchTab(name) {
  ['activity', 'users', 'files', 'maintenance'].forEach(tab => {
    document.getElementById(`tab-${tab}`).classList.add('d-none');
  });
  document.getElementById(`tab-${name}`).classList.remove('d-none');
  setActiveTab(name);
  if (name === 'files') loadFiles(currentFilesPath);
  if (name === 'users') refreshAll();
}

function escapeAttr(value) {
  return escapeHtml(String(value)).replace(/'/g, '&#39;');
}

function apiUrl(path) {
  return new URL(path, window.location.origin).toString();
}

function normalizeFilesPath(path) {
  return String(path || '').replace(/^\/+|\/+$/g, '');
}

function renderFilesBreadcrumb() {
  const breadcrumb = document.getElementById('files-breadcrumb');
  if (!breadcrumb) return;

  const rootButton = `<button class="btn btn-sm btn-link file-link-btn" type="button" data-action="go-root">senderman/files</button>`;
  if (!currentFilesPath) {
    breadcrumb.innerHTML = rootButton;
    return;
  }

  const segments = currentFilesPath.split('/').filter(Boolean);
  let runningPath = '';
  const parts = [rootButton];

  segments.forEach(segment => {
    runningPath = runningPath ? `${runningPath}/${segment}` : segment;
    parts.push('<span class="breadcrumb-sep">/</span>');
    parts.push(`<button class="btn btn-sm btn-link file-link-btn" type="button" data-action="open-folder" data-path="${escapeAttr(runningPath)}">${escapeHtml(segment)}</button>`);
  });

  breadcrumb.innerHTML = parts.join('');
}

function colorLine(line) {
  const safeLine = escapeHtml(line);
  if (line.includes('OK LOGIN') || line.includes('OK DOWNLOAD') || line.includes('OK UPLOAD')) {
    return `<span class="log-ok">${safeLine}</span>`;
  }
  if (line.includes('FAIL LOGIN') || line.includes('Login incorrect') || line.includes('530')) {
    return `<span class="log-fail">${safeLine}</span>`;
  }
  if (line.includes('CONNECT:')) {
    return `<span class="log-connect">${safeLine}</span>`;
  }
  if (line.includes('RETR ') || line.includes('STOR ')) {
    return `<span class="log-retr">${safeLine}</span>`;
  }
  return `<span class="log-default">${safeLine}</span>`;
}

function connectWS() {
  const proto = location.protocol === 'https:' ? 'wss' : 'ws';
  ws = new WebSocket(`${proto}://${location.host}/ws/logs`);

  ws.onmessage = event => {
    if (event.data === '__ping__') return;
    const box = document.getElementById('log-box');
    const line = document.createElement('div');
    line.innerHTML = colorLine(event.data);
    box.appendChild(line);
    if (autoScroll) box.scrollTop = box.scrollHeight;
    while (box.children.length > 500) box.removeChild(box.firstChild);
  };

  ws.onclose = () => setTimeout(connectWS, 3000);
  ws.onerror = () => ws.close();
}

function clearLog() {
  document.getElementById('log-box').innerHTML = '';
}

async function refreshAll() {
  try {
    const response = await fetch(apiUrl('/api/status'));
    if (!response.ok) return;
    const data = await response.json();

    const dot = document.getElementById('status-dot');
    const text = document.getElementById('status-text');
    const stat = document.getElementById('stat-uptime');
    const badge = document.getElementById('srv-badge');

    if (data.active) {
      dot.className = 'status-dot dot-on me-1';
      text.textContent = 'En línea';
      stat.textContent = 'ON';
      stat.className = 'stat-num text-success';
      badge.classList.add('pulse-glow');
    } else {
      dot.className = 'status-dot dot-off me-1';
      text.textContent = 'Detenido';
      stat.textContent = 'OFF';
      stat.className = 'stat-num text-danger';
      badge.classList.remove('pulse-glow');
    }

    renderUserRegistry(data.users || []);
    renderMaintenancePanel(data.maintenance || {});

    const startBtn = document.getElementById('service-start-btn');
    const stopBtn = document.getElementById('service-stop-btn');
    const restartBtn = document.getElementById('service-restart-btn');
    if (data.active) {
      startBtn.classList.add('d-none');
      stopBtn.classList.remove('d-none');
      restartBtn.classList.remove('d-none');
    } else {
      startBtn.classList.remove('d-none');
      stopBtn.classList.add('d-none');
      restartBtn.classList.add('d-none');
    }

    const connected = data.connected_users || [];
    document.getElementById('stat-connected').textContent = connected.length;

    const tbody = document.getElementById('users-tbody');
    if (connected.length === 0) {
      tbody.innerHTML = `<tr><td colspan="5" class="text-center text-secondary py-4"><i class="bi bi-people fs-3 d-block mb-2"></i>Sin usuarios conectados</td></tr>`;
      return;
    }

    tbody.innerHTML = connected.map(user => `
      <tr class="connected-row">
        <td><i class="bi bi-person-fill text-info me-1"></i><code>${escapeHtml(user.user)}</code></td>
        <td><span class="badge ${user.protocol === 'SFTP' ? 'badge-on' : 'badge-off'} connected-badge">${escapeHtml(user.protocol || '—')}</span></td>
        <td><span class="badge badge-on connected-badge">${escapeHtml(user.ip)}</span></td>
        <td class="text-secondary small">${escapeHtml(user.since)}</td>
        <td class="text-secondary small">${escapeHtml(user.pid)}</td>
      </tr>`).join('');
  } catch (error) {
    console.error(error);
  }
}

let ftpAutoSyncInFlight = false;

function renderMaintenancePanel(state) {
  const installed = document.getElementById('maintenance-installed');
  const release = document.getElementById('maintenance-release');
  const root = document.getElementById('maintenance-root');
  const service = document.getElementById('maintenance-service');

  if (installed) installed.textContent = state.installed ? 'Sí' : 'No';
  if (release) release.textContent = state.release || '—';
  if (root) root.textContent = state.install_root || '—';
  if (service) service.textContent = state.service?.active ? 'Activo' : 'Detenido';
  loadFtpConfig();
}

async function loadFtpConfig() {
  try {
    const response = await fetch(apiUrl('/api/ftp-config'));
    if (!response.ok) return;
    const config = await response.json();
    document.getElementById('ftp-public-ip').value = config.public_ip || config.detected_public_ip || '';
    document.getElementById('ftp-control-port').value = config.control_port || 21;
    document.getElementById('ftp-passive-min').value = config.passive_min_port || 40404;
    document.getElementById('ftp-passive-max').value = config.passive_max_port || 40404;
    document.getElementById('ftp-detected-ip').textContent = config.detected_public_ip ? `Detectada: ${config.detected_public_ip}` : 'No se pudo detectar automáticamente';
    document.getElementById('ftp-forwarding-summary').textContent = `TCP ${config.control_port || 21} y TCP ${config.passive_min_port || 40404}-${config.passive_max_port || 40404} -> este equipo`;

    if (config.detected_public_ip && config.detected_public_ip !== config.public_ip && !ftpAutoSyncInFlight) {
      ftpAutoSyncInFlight = true;
      document.getElementById('ftp-detected-ip').textContent = `Cambio detectado: actualizando a ${config.detected_public_ip}...`;
      await saveFtpConfig(config.detected_public_ip, true);
      ftpAutoSyncInFlight = false;
    }
  } catch (error) {
    console.error(error);
    ftpAutoSyncInFlight = false;
  }
}

async function saveFtpConfig(publicIp = null, automatic = false) {
  const payload = {
    public_ip: publicIp || document.getElementById('ftp-public-ip').value.trim(),
    control_port: Number(document.getElementById('ftp-control-port').value),
    passive_min_port: Number(document.getElementById('ftp-passive-min').value),
    passive_max_port: Number(document.getElementById('ftp-passive-max').value),
  };
  const response = await fetch(apiUrl('/api/ftp-config'), { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload) });
  const result = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(result.detail || 'No se pudo guardar la configuración FTP');
  toast(automatic ? 'IP pública actualizada automáticamente' : 'Configuración FTP aplicada y servicio reiniciado', 'success');
  const config = result.config || {};
  document.getElementById('ftp-public-ip').value = config.public_ip || payload.public_ip;
  document.getElementById('ftp-detected-ip').textContent = config.detected_public_ip ? `Detectada: ${config.detected_public_ip}` : 'No se pudo detectar automáticamente';
}

function applyTheme(theme) {
  const body = document.body;
  const icon = document.getElementById('theme-icon');
  body.dataset.theme = theme;
  document.documentElement.setAttribute('data-bs-theme', theme);
  localStorage.setItem('senderman-theme', theme);
  if (icon) {
    icon.className = theme === 'light' ? 'bi bi-sun-fill' : 'bi bi-moon-stars-fill';
  }
}

function toggleTheme() {
  applyTheme(document.body.dataset.theme === 'light' ? 'dark' : 'light');
}

async function serviceAction(action) {
  const labels = { start: 'Iniciando', stop: 'Deteniendo', restart: 'Reiniciando' };
  try {
    const response = await fetch(apiUrl(`/api/service/${action}`), { method: 'POST' });
    if (response.ok) {
      toast(`${labels[action]} vsftpd...`, 'info');
      setTimeout(refreshAll, 1500);
      return;
    }
    const error = await response.json();
    toast(error.detail || 'Error', 'danger');
  } catch (error) {
    toast('Error de red', 'danger');
  }
}

async function maintenanceAction(action) {
  const labels = {
    'maintenance-install': 'Instalando',
    'maintenance-update': 'Actualizando',
    'maintenance-uninstall': 'Desinstalando',
  };

  try {
    if (action === 'maintenance-uninstall') {
      const keepConfig = document.getElementById('maintenance-keep-config')?.checked ?? true;
      const confirmed = window.confirm(`¿Seguro que quieres desinstalar Senderman?${keepConfig ? ' Se conservará la configuración local.' : ' Se eliminará también la configuración local.'}`);
      if (!confirmed) return;

      const response = await fetch(apiUrl(`/api/maintenance/uninstall?keep_config=${keepConfig ? 'true' : 'false'}`), { method: 'POST' });
      if (response.ok) {
        showUninstallShutdown();
        return;
      }
      const error = await response.json().catch(() => ({}));
      toast(error.detail || 'Error', 'danger');
      return;
    }

    const endpoint = action === 'maintenance-install' ? '/api/maintenance/install' : '/api/maintenance/update';
    const response = await fetch(apiUrl(endpoint), { method: 'POST' });
    if (response.ok) {
      toast(`${labels[action]} Senderman...`, 'info');
      setTimeout(refreshAll, 1500);
      return;
    }
    const error = await response.json().catch(() => ({}));
    toast(error.detail || 'Error', 'danger');
  } catch (error) {
    toast('Error de red', 'danger');
  }
}

function downloadTextFile(filename, content, mimeType = 'text/plain') {
  const blob = new Blob([content], { type: mimeType });
  const url = URL.createObjectURL(blob);
  const link = document.createElement('a');
  link.href = url;
  link.download = filename;
  document.body.appendChild(link);
  link.click();
  link.remove();
  URL.revokeObjectURL(url);
}

function openUserModal(modalId) {
  return bootstrap.Modal.getOrCreateInstance(document.getElementById(modalId));
}

function fillEditModal(user) {
  document.getElementById('edit-user-original-name').value = user.username || '';
  document.getElementById('edit-user-name').value = user.username || '';
  document.getElementById('edit-user-home').value = user.home_dir || '';
  document.getElementById('edit-user-key').value = user.public_key || '';
  document.getElementById('edit-user-quota').value = Number(user.quota_bytes || 0);
  document.getElementById('edit-user-locked').checked = !!user.locked;
  document.getElementById('edit-user-write').checked = !!user.write_enabled;
}

async function loadUserForEdit(username) {
  const response = await fetch(apiUrl(`/api/users/${encodeURIComponent(username)}`));
  if (!response.ok) {
    const error = await response.json().catch(() => ({}));
    throw new Error(error.detail || 'No se pudo cargar el usuario');
  }
  return response.json();
}

function resetCreateForm() {
  const nameInput = document.getElementById('new-user-name');
  const homeInput = document.getElementById('new-user-home');
  const quotaInput = document.getElementById('new-user-quota');
  const keyInput = document.getElementById('new-user-key');
  const generateInput = document.getElementById('new-user-generate-key');
  if (nameInput) nameInput.value = '';
  if (homeInput) homeInput.value = '';
  if (quotaInput) quotaInput.value = '0';
  if (keyInput) keyInput.value = '';
  if (generateInput) generateInput.checked = true;
}

async function registerUser() {
  const input = document.getElementById('new-user-name');
  const homeInput = document.getElementById('new-user-home');
  const quotaInput = document.getElementById('new-user-quota');
  const publicKeyInput = document.getElementById('new-user-key');
  const generateInput = document.getElementById('new-user-generate-key');
  const modalElement = document.getElementById('register-user-modal');
  const modal = bootstrap.Modal.getInstance(modalElement);
  const username = input.value.trim();
  const homeDir = homeInput.value.trim();
  const quotaBytes = Number(quotaInput.value || 0);
  const publicKey = publicKeyInput.value.trim();
  const generateKeypair = !!generateInput.checked;

  if (!username) {
    toast('Escribe un nombre de usuario', 'danger');
    return;
  }
  if (!publicKey && !generateKeypair) {
    toast('Pega una clave pública o activa la generación automática', 'danger');
    return;
  }

  try {
    const response = await fetch(apiUrl('/api/users/create'), {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ username, home_dir: homeDir, quota_bytes: quotaBytes, public_key: publicKey, generate_keypair: generateKeypair }),
    });
    if (response.ok) {
      const payload = await response.json();
      input.value = '';
      homeInput.value = '';
      quotaInput.value = '0';
      publicKeyInput.value = '';
      generateInput.checked = true;
      toast('Usuario registrado en el panel', 'success');
      if (payload.private_key) {
        downloadTextFile(`${username}-sftp.key`, payload.private_key);
        toast('La clave privada se descargó automáticamente', 'info');
      }
      if (modal) modal.hide();
      refreshAll();
      return;
    }
    const error = await response.json();
    toast(error.detail || 'Error al registrar', 'danger');
  } catch (error) {
    toast('Error de red', 'danger');
  }
}

async function openEditUserModal(username, options = {}) {
  try {
    const user = await loadUserForEdit(username);
    fillEditModal(user);
    openUserModal('edit-user-modal').show();
    if (options.generateKey) {
      setTimeout(() => generateUserKeyForUser(username), 250);
    }
  } catch (error) {
    toast(error.message || 'No se pudo cargar el usuario', 'danger');
  }
}

async function saveEditedUser() {
  const originalName = document.getElementById('edit-user-original-name').value.trim();
  const newName = document.getElementById('edit-user-name').value.trim();
  const homeDir = document.getElementById('edit-user-home').value.trim();
  const quotaBytes = Number(document.getElementById('edit-user-quota').value || 0);
  const publicKey = document.getElementById('edit-user-key').value.trim();
  const locked = document.getElementById('edit-user-locked').checked;
  const writeEnabled = document.getElementById('edit-user-write').checked;
  const modal = bootstrap.Modal.getInstance(document.getElementById('edit-user-modal'));

  try {
    const response = await fetch(apiUrl(`/api/users/${encodeURIComponent(originalName)}`), {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        new_username: newName,
        home_dir: homeDir,
        quota_bytes: quotaBytes,
        public_key: publicKey,
        locked,
        write_enabled: writeEnabled,
      }),
    });

    if (response.ok) {
      toast('Usuario actualizado', 'success');
      if (modal) modal.hide();
      refreshAll();
      return;
    }

    const error = await response.json();
    toast(error.detail || 'No se pudo guardar el usuario', 'danger');
  } catch (error) {
    toast('Error de red', 'danger');
  }
}

async function deleteUserByName(username) {
  const confirmed = window.confirm(`¿Eliminar al usuario ${username}?`);
  if (!confirmed) return;

  try {
    const response = await fetch(apiUrl(`/api/users/${encodeURIComponent(username)}?remove_home=true`), { method: 'DELETE' });
    if (response.ok) {
      toast('Usuario eliminado', 'success');
      bootstrap.Modal.getInstance(document.getElementById('edit-user-modal'))?.hide();
      refreshAll();
      return;
    }
    const error = await response.json();
    toast(error.detail || 'No se pudo eliminar el usuario', 'danger');
  } catch (error) {
    toast('Error de red', 'danger');
  }
}

async function deleteEditedUser() {
  const originalName = document.getElementById('edit-user-original-name').value.trim();
  return deleteUserByName(originalName);
}

async function generateUserKeyForUser(username) {
  try {
    const response = await fetch(apiUrl(`/api/users/${encodeURIComponent(username)}/keys/generate`), { method: 'POST' });
    if (!response.ok) {
      const error = await response.json();
      toast(error.detail || 'No se pudo generar la clave', 'danger');
      return;
    }

    const payload = await response.json();
    const keyInput = document.getElementById('edit-user-key');
    if (document.getElementById('edit-user-original-name').value.trim() === username && keyInput) {
      keyInput.value = payload.public_key || '';
    }
    if (payload.private_key) {
      downloadTextFile(`${username}-sftp.key`, payload.private_key);
      toast('La clave privada se descargó automáticamente', 'info');
    }
    refreshAll();
  } catch (error) {
    toast('Error de red', 'danger');
  }
}

async function generateUserKeyForEdit() {
  const originalName = document.getElementById('edit-user-original-name').value.trim();
  return generateUserKeyForUser(originalName);
}

function renderUserRegistry(users) {
  const tbody = document.getElementById('users-registry-tbody');
  if (!tbody) return;

  if (!users.length) {
    tbody.innerHTML = `<tr><td colspan="4" class="text-center text-secondary py-4"><i class="bi bi-people fs-3 d-block mb-2"></i>Sin usuarios registrados</td></tr>`;
    return;
  }

  tbody.innerHTML = users.map(user => {
    const locked = !!user.locked;
    const writeEnabled = !!user.write_enabled;
    const quotaBytes = Number(user.quota_bytes || 0);
    const stateIcon = locked ? 'bi-lock-fill' : 'bi-unlock-fill';
    const writeIcon = writeEnabled ? 'bi-pencil-square' : 'bi-file-lock2-fill';
    const quotaLabel = quotaBytes > 0 ? `Cuota: ${formatBytes(quotaBytes)}` : 'Cuota: sin límite';

    return `
      <tr class="connected-row">
        <td>
          <i class="bi bi-person-fill text-info me-1"></i><code>${escapeHtml(user.username)}</code>
          <div class="small text-secondary">${escapeHtml(quotaLabel)}</div>
        </td>
        <td class="cell-center">
          <button class="btn btn-sm btn-action user-action-btn user-registry-toggle ${locked ? 'toggle-blocked' : 'toggle-active'}" type="button" data-user-action="${locked ? 'unlock' : 'lock'}" data-username="${escapeHtml(user.username)}">
            <i class="bi ${stateIcon}"></i>
            <span class="toggle-label">${locked ? 'Bloqueado' : 'Activo'}</span>
          </button>
        </td>
        <td class="cell-center">
          <button class="btn btn-sm btn-action user-action-btn user-registry-toggle ${writeEnabled ? 'toggle-on' : 'toggle-off'}" type="button" data-user-write="${writeEnabled ? 'off' : 'on'}" data-username="${escapeHtml(user.username)}">
            <i class="bi ${writeIcon}"></i>
            <span class="toggle-label">${writeEnabled ? 'ON' : 'OFF'}</span>
          </button>
        </td>
        <td class="text-end">
          <div class="d-flex justify-content-end gap-2 flex-wrap">
            <button class="btn btn-sm btn-outline-info btn-action" type="button" data-action="edit-user" data-username="${escapeHtml(user.username)}">
              <i class="bi bi-pencil-square"></i>
            </button>
            <button class="btn btn-sm btn-outline-secondary btn-action" type="button" data-action="generate-key" data-username="${escapeHtml(user.username)}">
              <i class="bi bi-key"></i>
            </button>
            <button class="btn btn-sm btn-outline-danger btn-action" type="button" data-action="delete-user" data-username="${escapeHtml(user.username)}">
              <i class="bi bi-trash3"></i>
            </button>
          </div>
        </td>
      </tr>`;
  }).join('');
}

async function userAction(username, action) {
  try {
    const response = await fetch(apiUrl(`/api/users/${encodeURIComponent(username)}/${action}`), { method: 'POST' });
    if (response.ok) {
      toast(action === 'lock' ? 'Usuario bloqueado' : 'Usuario desbloqueado', action === 'lock' ? 'danger' : 'success');
      refreshAll();
      return;
    }
    const error = await response.json();
    toast(error.detail || 'Error', 'danger');
  } catch (error) {
    toast('Error de red', 'danger');
  }
}

async function userWriteAction(username, state) {
  try {
    const response = await fetch(apiUrl(`/api/users/${encodeURIComponent(username)}/write/${state}`), { method: 'POST' });
    if (response.ok) {
      toast(state === 'on' ? 'Escritura habilitada' : 'Escritura deshabilitada', state === 'on' ? 'success' : 'info');
      refreshAll();
      return;
    }
    const error = await response.json();
    toast(error.detail || 'Error', 'danger');
  } catch (error) {
    toast('Error de red', 'danger');
  }
}

function openRegisterModal() {
  const modal = bootstrap.Modal.getOrCreateInstance(document.getElementById('register-user-modal'));
  resetCreateForm();
  modal.show();
}

async function loadFiles(path = currentFilesPath) {
  const tbody = document.getElementById('files-tbody');
  tbody.innerHTML = '<tr><td colspan="4" class="text-center text-secondary py-3">Cargando...</td></tr>';
  try {
    const normalizedPath = normalizeFilesPath(path);
    const response = await fetch(apiUrl(`/api/files?path=${encodeURIComponent(normalizedPath)}`));
    if (!response.ok) throw new Error('files');
    const payload = await response.json();
    const files = payload.entries || [];
    currentFilesPath = payload.current_path || '';
    currentFilesParentPath = payload.parent_path || '';
    renderFilesBreadcrumb();

    const fileItems = files.filter(file => !file.is_dir);
    const totalBytes = fileItems.reduce((sum, file) => sum + (file.raw_size || 0), 0);
    document.getElementById('stat-files').textContent = files.length;

    if (files.length === 0) {
      tbody.innerHTML = '<tr><td colspan="4" class="text-center text-secondary py-4">Carpeta vacía</td></tr>';
      return;
    }

    const rows = files.map(file => {
      const icon = file.is_dir ? 'bi-folder-fill text-warning' : 'bi-file-earmark text-secondary';
      const itemPath = file.path || file.name;
      const shortName = file.name || itemPath;
      const labelBadge = file.is_dir ? '<span class="badge badge-off ms-1 small">Carpeta</span>' : '';
      const downloadLabel = file.is_dir ? 'Descargar carpeta' : 'Descargar archivo';

      return `<tr>
        <td class="file-tree-cell file-indent-0">
          <i class="bi ${icon} file-icon"></i>
          ${file.is_dir ? `<button class="file-link-btn fw-semibold" type="button" data-action="open-folder" data-path="${escapeAttr(itemPath)}" title="Abrir carpeta">${escapeHtml(shortName)}</button>` : `<span title="${escapeHtml(itemPath)}">${escapeHtml(shortName)}</span>`}
          ${labelBadge}
        </td>
        <td class="text-secondary small">${escapeHtml(file.size)}</td>
        <td class="text-secondary small">${escapeHtml(file.modified)}</td>
        <td class="text-end">
          <div class="file-actions">
            ${file.is_dir ? `<button class="btn btn-sm btn-outline-secondary btn-action file-action-btn" type="button" data-action="open-folder" data-path="${escapeAttr(itemPath)}" title="Abrir carpeta"><i class="bi bi-box-arrow-in-right"></i></button>` : ''}
            <button class="btn btn-sm btn-outline-secondary btn-action file-action-btn" type="button" data-action="download-file" data-path="${escapeAttr(file.name)}" title="${downloadLabel}">
              <i class="bi bi-download"></i>
            </button>
          </div>
        </td>
      </tr>`;
    }).join('');

    const totalRow = `<tr class="files-total-row">
      <td class="text-secondary small"><i class="bi bi-hdd me-1"></i>Total</td>
      <td class="text-info small fw-semibold">${formatBytes(totalBytes)}</td>
      <td></td>
      <td></td>
    </tr>`;

    tbody.innerHTML = rows + totalRow;
  } catch (error) {
    tbody.innerHTML = '<tr><td colspan="4" class="text-center text-danger py-3">Error al cargar archivos</td></tr>';
  }
}

async function downloadFile(path) {
  try {
    const response = await fetch(apiUrl(`/api/files/download?path=${encodeURIComponent(path)}`));
    if (!response.ok) throw new Error('download');
    const blob = await response.blob();
    const contentDisposition = response.headers.get('content-disposition') || '';
    const match = contentDisposition.match(/filename="?([^";]+)"?/i);
    const filename = match ? match[1] : path.split('/').pop();
    const url = URL.createObjectURL(blob);
    const link = document.createElement('a');
    link.href = url;
    link.download = filename;
    document.body.appendChild(link);
    link.click();
    link.remove();
    URL.revokeObjectURL(url);
  } catch (error) {
    toast('No se pudo descargar el archivo', 'danger');
  }
}

async function uploadItems(items) {
  if (!items || items.length === 0) {
    toast('Selecciona al menos un archivo', 'danger');
    return;
  }

  const formData = new FormData();
  items.forEach(item => {
    formData.append('files', item.file, normalizeFilesPath(item.path || item.file.webkitRelativePath || item.file.name));
  });

  try {
    const response = await fetch(apiUrl(`/api/files/upload?path=${encodeURIComponent(currentFilesPath)}`), {
      method: 'POST',
      body: formData,
    });
    if (!response.ok) {
      const error = await response.json().catch(() => ({}));
      throw new Error(error.detail || 'upload');
    }
    toast('Archivos cargados correctamente', 'success');
    loadFiles(currentFilesPath);
  } catch (error) {
    toast(error.message || 'No se pudieron subir los archivos', 'danger');
  }
}

function readAllDirectoryEntries(reader) {
  return new Promise(resolve => {
    const entries = [];

    const readBatch = () => {
      reader.readEntries(batch => {
        if (!batch.length) {
          resolve(entries);
          return;
        }
        entries.push(...batch);
        readBatch();
      }, () => resolve(entries));
    };

    readBatch();
  });
}

async function getFilesFromEntry(entry) {
  if (entry.isFile) {
    return new Promise(resolve => {
      entry.file(file => {
        resolve([{ file, path: normalizeFilesPath(entry.fullPath || file.webkitRelativePath || file.name) }]);
      });
    });
  }

  if (!entry.isDirectory) {
    return Promise.resolve([]);
  }

  const children = await readAllDirectoryEntries(entry.createReader());
  const nested = await Promise.all(children.map(child => getFilesFromEntry(child)));
  return nested.flat();
}

async function collectDroppedItems(dataTransfer) {
  const items = dataTransfer?.items;
  if (items && items.length && items[0].webkitGetAsEntry) {
    const all = [];
    for (const item of Array.from(items)) {
      const entry = item.webkitGetAsEntry();
      if (entry) {
        const files = await getFilesFromEntry(entry);
        all.push(...files);
      }
    }
    return all;
  }

  return Array.from(dataTransfer?.files || []).map(file => ({
    file,
    path: normalizeFilesPath(file.webkitRelativePath || file.name),
  }));
}

async function uploadFiles(fileList) {
  const items = Array.from(fileList || []).map(file => ({
    file,
    path: normalizeFilesPath(file.webkitRelativePath || file.name),
  }));
  return uploadItems(items);
}

function formatBytes(bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  let index = 0;
  while (bytes >= 1024 && index < units.length - 1) {
    bytes /= 1024;
    index += 1;
  }
  return `${bytes.toFixed(1)} ${units[index]}`;
}

function bindUI() {
  document.querySelectorAll('[data-action="toggle-theme"]').forEach(button => {
    button.addEventListener('click', toggleTheme);
  });

  document.querySelectorAll('[data-action="refresh-all"]').forEach(button => {
    button.addEventListener('click', refreshAll);
  });

  document.querySelectorAll('[data-action="clear-log"]').forEach(button => {
    button.addEventListener('click', clearLog);
  });

  document.querySelectorAll('[data-action="open-register-modal"]').forEach(button => {
    button.addEventListener('click', openRegisterModal);
  });

  document.querySelectorAll('[data-action="load-files"]').forEach(button => {
    button.addEventListener('click', loadFiles);
  });

  document.querySelectorAll('[data-action="upload-files"]').forEach(button => {
    button.addEventListener('click', () => {
      document.getElementById('files-upload-input')?.click();
    });
  });

  document.querySelectorAll('[data-action="upload-folder"]').forEach(button => {
    button.addEventListener('click', () => {
      document.getElementById('files-folder-input')?.click();
    });
  });

  document.querySelectorAll('[data-action="register-user"]').forEach(button => {
    button.addEventListener('click', registerUser);
  });

  document.querySelectorAll('[data-service-action]').forEach(button => {
    button.addEventListener('click', () => serviceAction(button.dataset.serviceAction));
  });

  document.querySelectorAll('[data-action="maintenance-install"]').forEach(button => {
    button.addEventListener('click', () => maintenanceAction('maintenance-install'));
  });

  document.querySelectorAll('[data-action="maintenance-update"]').forEach(button => {
    button.addEventListener('click', () => maintenanceAction('maintenance-update'));
  });

  document.querySelectorAll('[data-action="maintenance-uninstall"]').forEach(button => {
    button.addEventListener('click', () => maintenanceAction('maintenance-uninstall'));
  });
  document.querySelectorAll('[data-action="save-ftp-config"]').forEach(button => {
    button.addEventListener('click', () => saveFtpConfig().catch(error => toast(error.message, 'danger')));
  });

  document.querySelectorAll('[data-action="go-monitor"]').forEach(button => {
    button.addEventListener('click', () => switchTab('activity'));
  });

  document.getElementById('save-user-btn')?.addEventListener('click', saveEditedUser);
  document.getElementById('delete-user-btn')?.addEventListener('click', deleteEditedUser);
  document.getElementById('generate-user-key-btn')?.addEventListener('click', generateUserKeyForEdit);

  document.querySelectorAll('[data-tab]').forEach(button => {
    button.addEventListener('click', () => switchTab(button.dataset.tab));
  });

  const registryTbody = document.getElementById('users-registry-tbody');
  if (registryTbody) {
    registryTbody.addEventListener('click', event => {
      const button = event.target.closest('button[data-username]');
      if (!button) return;
      const { username, userAction: action, userWrite: writeState } = button.dataset;
      if (action) {
        userAction(username, action);
      } else if (writeState) {
        userWriteAction(username, writeState);
      }
    });
  }

  document.addEventListener('click', event => {
    const editButton = event.target.closest('button[data-action="edit-user"]');
    if (editButton) {
      openEditUserModal(editButton.dataset.username || '');
      return;
    }

    const generateButton = event.target.closest('button[data-action="generate-key"]');
    if (generateButton) {
      openEditUserModal(generateButton.dataset.username || '', { generateKey: true });
      return;
    }

    const deleteButton = event.target.closest('button[data-action="delete-user"]');
    if (deleteButton && deleteButton.dataset.username) {
      deleteUserByName(deleteButton.dataset.username);
      return;
    }

    const openButton = event.target.closest('button[data-action="open-folder"]');
    if (openButton) {
      const nextPath = normalizeFilesPath(openButton.dataset.path || '');
      loadFiles(nextPath);
      return;
    }

    const downloadButton = event.target.closest('button[data-action="download-file"]');
    if (downloadButton) {
      downloadFile(downloadButton.dataset.path || '');
      return;
    }

    const filesUpButton = event.target.closest('button[data-action="files-up"]');
    if (filesUpButton) {
      loadFiles(currentFilesParentPath || '');
      return;
    }

    const rootButton = event.target.closest('button[data-action="go-root"]');
    if (rootButton) {
      loadFiles('');
    }
  });

  const uploadInput = document.getElementById('files-upload-input');
  if (uploadInput) {
    uploadInput.addEventListener('change', event => {
      const input = event.target;
      uploadFiles(input.files);
      input.value = '';
    });
  }

  const folderInput = document.getElementById('files-folder-input');
  if (folderInput) {
    folderInput.addEventListener('change', event => {
      const input = event.target;
      uploadFiles(input.files);
      input.value = '';
    });
  }

  const dropzone = document.getElementById('files-dropzone');
  if (dropzone) {
    const prevent = event => {
      event.preventDefault();
      event.stopPropagation();
    };

    ['dragenter', 'dragover'].forEach(type => {
      dropzone.addEventListener(type, event => {
        prevent(event);
        dropzone.classList.add('is-dragover');
      });
    });

    ['dragleave', 'drop'].forEach(type => {
      dropzone.addEventListener(type, event => {
        prevent(event);
        dropzone.classList.remove('is-dragover');
      });
    });

    dropzone.addEventListener('drop', event => {
      collectDroppedItems(event.dataTransfer).then(items => uploadItems(items));
    });
  }
}

document.addEventListener('DOMContentLoaded', () => {
  bindUI();
  applyTheme(localStorage.getItem('senderman-theme') || 'dark');
  connectWS();
  refreshAll();
  loadFiles();
  setInterval(refreshAll, 8000);
});