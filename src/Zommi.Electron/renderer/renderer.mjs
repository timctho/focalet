const transcript = document.querySelector('#CodexTranscript');
const composer = document.querySelector('#ZommiComposer');
const chips = document.querySelector('#ContextChips');
const sendButton = document.querySelector('#SendMessage');
const status = document.querySelector('#CodexStatus');
const shortcuts = document.querySelector('#ZommiShortcuts');
const queryBubble = document.querySelector('#QueryBubble');
const preview = document.querySelector('#ContextPreview');
const previewTitle = document.querySelector('#PreviewTitle');
const previewText = document.querySelector('#ContextPreviewText');
const previewImage = document.querySelector('#ContextPreviewImage');
const attachments = [];
const activityElements = new Map();
let assistantElement = null;
let turnActive = false;
let previewTimer = null;

document.querySelector('#HideZommi').addEventListener('click', () => window.zommi.hide());
document.querySelector('#ExpandZommi').addEventListener('click', () => window.zommi.toggleExpanded());
document.querySelector('#SelectImage').addEventListener('click', () => window.zommi.selectImage());
document.querySelector('#ClosePreview').addEventListener('click', hidePreview);
sendButton.addEventListener('click', sendMessage);
composer.addEventListener('input', resizeComposer);
composer.addEventListener('keydown', (event) => {
  if (event.key === 'Enter' && !event.shiftKey) {
    event.preventDefault();
    sendMessage();
  }
  if (event.key === 'Escape') window.zommi.hide();
});
preview.addEventListener('mouseenter', () => clearTimeout(previewTimer));
preview.addEventListener('mouseleave', schedulePreviewHide);

window.zommi.onContext(addAttachment);
window.zommi.onStatus(({ message, warning }) => renderStatus(message, warning));
window.zommi.onStream(renderStreamUpdate);
window.zommi.onTurnCompleted(completeTurn);
window.zommi.onFocusComposer(() => focusComposer());
window.zommi.onShortcuts((state) => {
  shortcuts.textContent = 'Alt+A context · Alt+Shift+A image';
  shortcuts.setAttribute('aria-label', `Alt+A registered: ${Boolean(state.context)}; Alt+Shift+A registered: ${Boolean(state.image)}`);
});

function addAttachment(attachment) {
  attachment.token = createToken(attachment);
  attachments.push(attachment);
  renderAttachments();
  focusComposer();
}

function createToken(attachment) {
  let label = 'image';
  if (attachment.snapshot) {
    const locator = attachment.snapshot.locator;
    if (locator?.kind?.toLowerCase() === 'url') {
      try {
        label = new URL(locator.value).hostname.replace(/^www\./i, '').slice(0, 30) || 'context';
      } catch {
        label = 'context';
      }
    } else {
      label = String(attachment.snapshot.application || 'context').toLowerCase().replaceAll(' ', '-').slice(0, 30);
    }
  }
  const used = new Set(attachments.map((item) => item.token).filter(Boolean));
  let token = `[${label}]`;
  for (let suffix = 2; used.has(token); suffix++) token = `[${label} ${suffix}]`;
  return token;
}

function renderAttachments() {
  chips.replaceChildren();
  chips.classList.toggle('has-items', attachments.length > 0);
  for (const attachment of attachments) {
    const chip = document.createElement('span');
    chip.className = 'context-chip';
    chip.dataset.attachmentId = attachment.id;
    chip.setAttribute('aria-label', `Attached context ${attachment.token}`);
    const label = document.createElement('span');
    label.className = 'label';
    label.textContent = attachment.token;
    const remove = document.createElement('button');
    remove.type = 'button';
    remove.setAttribute('aria-label', `Remove ${attachment.token}`);
    remove.textContent = '×';
    remove.addEventListener('click', () => removeAttachment(attachment.id));
    chip.append(label, remove);
    chip.addEventListener('mouseenter', () => showPreview(attachment));
    chip.addEventListener('mouseleave', schedulePreviewHide);
    chips.append(chip);
  }
}

function removeAttachment(id) {
  const index = attachments.findIndex((item) => item.id === id);
  if (index >= 0) attachments.splice(index, 1);
  hidePreview();
  renderAttachments();
}

function showPreview(attachment) {
  clearTimeout(previewTimer);
  previewTitle.textContent = attachment.token;
  previewText.textContent = attachment.previewText || '';
  previewText.hidden = Boolean(attachment.imageDataUrl);
  previewImage.hidden = !attachment.imageDataUrl;
  if (attachment.imageDataUrl) previewImage.src = attachment.imageDataUrl;
  else previewImage.removeAttribute('src');
  preview.hidden = false;
}

function schedulePreviewHide() {
  clearTimeout(previewTimer);
  previewTimer = setTimeout(() => {
    if (!preview.matches(':hover')) hidePreview();
  }, 260);
}

function hidePreview() {
  clearTimeout(previewTimer);
  preview.hidden = true;
}

async function sendMessage() {
  if (turnActive) return;
  const message = composer.value.trim();
  if (!message) return;
  turnActive = true;
  sendButton.disabled = true;
  composer.disabled = true;
  queryBubble.textContent = message;
  queryBubble.classList.remove('empty');
  removeWelcome();
  appendUserMessage(message, attachments.map((item) => item.token));
  assistantElement = null;
  activityElements.clear();
  try {
    await window.zommi.send({
      message,
      attachments: attachments.map(({ snapshot, imageDataUrl }) => ({ snapshot, imageDataUrl })),
    });
    attachments.splice(0);
    composer.value = '';
    renderAttachments();
    resizeComposer();
  } catch (error) {
    appendError(error.message);
    completeTurn('failed');
  }
}

function renderStreamUpdate(update) {
  removeWelcome();
  const kind = normalizeKind(update.kind);
  const lifecycle = normalizeLifecycle(update.lifecycle);
  if (kind === 'assistant') {
    if (!assistantElement) {
      assistantElement = document.createElement('div');
      assistantElement.className = 'message assistant';
      assistantElement.setAttribute('aria-label', 'Codex response');
      transcript.append(assistantElement);
    }
    if (update.text) assistantElement.append(document.createTextNode(update.text));
    scrollTranscript();
    return;
  }
  const key = update.itemId || `${kind}:${update.title}`;
  let element = activityElements.get(key);
  if (!element) {
    element = document.createElement('div');
    element.className = `activity ${kind}`;
    const heading = document.createElement('strong');
    heading.textContent = kind === 'thinking' ? 'Thinking…' : update.title || 'Activity';
    element.append(heading, document.createTextNode('\n'));
    activityElements.set(key, element);
    transcript.append(element);
  }
  if (update.text) element.append(document.createTextNode(update.text));
  if (lifecycle === 'completed' && update.status) element.append(document.createTextNode(`\n↳ ${update.status}`));
  scrollTranscript();
}

function normalizeKind(value) {
  if (typeof value === 'number') return ['assistant', 'thinking', 'plan', 'tool', 'toolOutput'][value] || 'tool';
  return String(value || 'tool').toLowerCase();
}

function normalizeLifecycle(value) {
  if (typeof value === 'number') return ['started', 'delta', 'completed'][value] || 'delta';
  return String(value || 'delta').toLowerCase();
}

function appendUserMessage(message, tokens) {
  const element = document.createElement('div');
  element.className = 'activity user';
  element.textContent = `${tokens.length ? `${tokens.join(' ')} ` : ''}${message}`;
  transcript.append(element);
  scrollTranscript();
}

function appendError(message) {
  const element = document.createElement('div');
  element.className = 'activity error';
  element.textContent = `Error: ${message}`;
  transcript.append(element);
}

function completeTurn(turnStatus) {
  turnActive = false;
  sendButton.disabled = false;
  composer.disabled = false;
  renderStatus(String(turnStatus).toLowerCase() === 'completed' ? 'ready' : `turn ${turnStatus}`, turnStatus !== 'completed');
  focusComposer();
}

function renderStatus(message, warning = false) {
  status.textContent = message;
  status.classList.toggle('warning', Boolean(warning));
  status.setAttribute('aria-label', `Codex status: ${message}`);
}

function resizeComposer() {
  composer.style.height = 'auto';
  composer.style.height = `${Math.min(composer.scrollHeight, 110)}px`;
}

function focusComposer() {
  setTimeout(() => composer.focus({ preventScroll: true }), 0);
}

function scrollTranscript() {
  transcript.scrollTop = transcript.scrollHeight;
}

function removeWelcome() {
  transcript.querySelector('.welcome')?.remove();
}
