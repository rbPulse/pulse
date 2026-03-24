const PASSWORD = '123';
const SESSION_KEY = 'pulse_op_auth';

const gate = document.getElementById('gate');
const app = document.getElementById('app');
const input = document.getElementById('passwordInput');
const loginBtn = document.getElementById('loginBtn');
const gateError = document.getElementById('gateError');
const logoutBtn = document.getElementById('logoutBtn');

function unlock() {
  gate.classList.add('hidden');
  app.classList.remove('hidden');
  setDate();
}

function tryLogin() {
  if (input.value === PASSWORD) {
    sessionStorage.setItem(SESSION_KEY, '1');
    gateError.textContent = '';
    unlock();
  } else {
    gateError.textContent = 'Incorrect password.';
    input.value = '';
    input.focus();
  }
}

loginBtn.addEventListener('click', tryLogin);
input.addEventListener('keydown', e => { if (e.key === 'Enter') tryLogin(); });

logoutBtn.addEventListener('click', () => {
  sessionStorage.removeItem(SESSION_KEY);
  app.classList.add('hidden');
  gate.classList.remove('hidden');
  input.value = '';
});

// Persist session within tab
if (sessionStorage.getItem(SESSION_KEY)) unlock();

// Navigation
const navItems = document.querySelectorAll('.nav-item');
const pages = document.querySelectorAll('.page');

navItems.forEach(item => {
  item.addEventListener('click', () => {
    const pageId = item.dataset.page;
    navItems.forEach(n => n.classList.remove('active'));
    pages.forEach(p => p.classList.remove('active'));
    item.classList.add('active');
    document.getElementById('page-' + pageId).classList.add('active');
  });
});

function setDate() {
  const el = document.getElementById('pageDate');
  if (!el) return;
  el.textContent = new Date().toLocaleDateString('en-US', { weekday: 'long', year: 'numeric', month: 'long', day: 'numeric' });
}
