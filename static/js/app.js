let ws = null;
let autoScroll = true;

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

function setActiveTab(name) {
  document.querySelectorAll('[data-tab]').forEach(button => {
    button.classList.toggle('active', button.dataset.tab === name);
  });
}

function switchTab(name) {
  ['activity', 'users', 'files'].forEach(tab => {
    document.getElementById(`tab-${tab}`).classList.add('d-none');
  });
  document.getElementById(`tab-${name}`).classList.remove('d-none');
  setActiveTab(name);
  if (name === 'files') loadFiles();
  if (name === 'users') refreshAll();
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
    const response = await fetch('/api/status');
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
    const response = await fetch(`/api/service/${action}`, { method: 'POST' });
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

function renderUserRegistry(users) {
  const tbody = document.getElementById('users-registry-tbody');
  if (!tbody) return;

  if (!users.length) {
    tbody.innerHTML = `<tr><td colspan="3" class="text-center text-secondary py-4"><i class="bi bi-people fs-3 d-block mb-2"></i>Sin usuarios registrados</td></tr>`;
    return;
  }

  tbody.innerHTML = users.map(user => {
    const locked = !!user.locked;
    const writeEnabled = !!user.write_enabled;
    const stateIcon = locked ? 'bi-lock-fill' : 'bi-unlock-fill';
    const writeIcon = writeEnabled ? 'bi-pencil-square' : 'bi-file-lock2-fill';

    return `
      <tr class="connected-row">
        <td><i class="bi bi-person-fill text-info me-1"></i><code>${escapeHtml(user.username)}</code></td>
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
      </tr>`;
  }).join('');
}

async function userAction(username, action) {
  try {
    const response = await fetch(`/api/users/${encodeURIComponent(username)}/${action}`, { method: 'POST' });
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
    const response = await fetch(`/api/users/${encodeURIComponent(username)}/write/${state}`, { method: 'POST' });
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
  modal.show();
}

async function registerUser() {
  const input = document.getElementById('new-user-name');
  const passwordInput = document.getElementById('new-user-pass');
  const modalElement = document.getElementById('register-user-modal');
  const modal = bootstrap.Modal.getInstance(modalElement);
  const username = input.value.trim();
  const password = passwordInput.value;

  if (!username) {
    toast('Escribe un nombre de usuario', 'danger');
    return;
  }
  if (!password || password.length < 8) {
    toast('La contraseña debe tener al menos 8 caracteres', 'danger');
    return;
  }

  try {
    const response = await fetch('/api/users/create', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ username, password }),
    });
    if (response.ok) {
      input.value = '';
      passwordInput.value = '';
      toast('Usuario registrado en el panel', 'success');
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

async function loadFiles() {
  const tbody = document.getElementById('files-tbody');
  tbody.innerHTML = '<tr><td colspan="3" class="text-center text-secondary py-3">Cargando...</td></tr>';
  try {
    const response = await fetch('/api/files');
    if (!response.ok) throw new Error('files');
    const files = await response.json();
    const fileItems = files.filter(file => !file.is_dir);
    const totalBytes = fileItems.reduce((sum, file) => sum + (file.raw_size || 0), 0);
    document.getElementById('stat-files').textContent = fileItems.length;

    if (files.length === 0) {
      tbody.innerHTML = '<tr><td colspan="3" class="text-center text-secondary py-4">Carpeta vacía</td></tr>';
      return;
    }

    const rows = files.map(file => {
      const depth = (file.name.match(/\//g) || []).length;
      const depthClass = `file-indent-${Math.min(depth, 10)}`;
      const icon = file.is_dir ? 'bi-folder-fill text-warning' : 'bi-file-earmark text-secondary';
      const shortName = file.name.includes('/') ? file.name.split('/').pop() : file.name;
      const labelBadge = depth === 0 && file.is_dir ? `<span class="badge badge-off ms-1 small">${escapeHtml(file.name)}</span>` : '';

      return `<tr>
        <td class="file-tree-cell ${depthClass}">
          <i class="bi ${icon} file-icon"></i>
          <span title="${escapeHtml(file.name)}">${escapeHtml(shortName)}</span>
          ${labelBadge}
        </td>
        <td class="text-secondary small">${escapeHtml(file.size)}</td>
        <td class="text-secondary small">${escapeHtml(file.modified)}</td>
      </tr>`;
    }).join('');

    const totalRow = `<tr class="files-total-row">
      <td class="text-secondary small"><i class="bi bi-hdd me-1"></i>Total</td>
      <td class="text-info small fw-semibold">${formatBytes(totalBytes)}</td>
      <td></td>
    </tr>`;

    tbody.innerHTML = rows + totalRow;
  } catch (error) {
    tbody.innerHTML = '<tr><td colspan="3" class="text-center text-danger py-3">Error al cargar archivos</td></tr>';
  }
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

  document.querySelectorAll('[data-action="register-user"]').forEach(button => {
    button.addEventListener('click', registerUser);
  });

  document.querySelectorAll('[data-service-action]').forEach(button => {
    button.addEventListener('click', () => serviceAction(button.dataset.serviceAction));
  });

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
}

document.addEventListener('DOMContentLoaded', () => {
  bindUI();
  applyTheme(localStorage.getItem('senderman-theme') || 'dark');
  connectWS();
  refreshAll();
  loadFiles();
  setInterval(refreshAll, 8000);
});