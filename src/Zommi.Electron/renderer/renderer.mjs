const transcript = document.querySelector('#CodexTranscript');
const composer = document.querySelector('#ZommiComposer');
const chips = document.querySelector('#ContextChips');
const sendButton = document.querySelector('#SendMessage');
const status = document.querySelector('#CodexStatus');
const shortcuts = document.querySelector('#ZommiShortcuts');
const preview = document.querySelector('#ContextPreview');
const previewTitle = document.querySelector('#PreviewTitle');
const previewText = document.querySelector('#ContextPreviewText');
const previewImage = document.querySelector('#ContextPreviewImage');
const attachments = [];
const activityElements = new Map();
let assistantElement = null;
let assistantTextNode = null;
let currentTurnBody = null;
let turnActive = false;
let previewTimer = null;
let turnNumber = 0;

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
window.zommi.onAcceptanceConversation?.(seedAcceptanceConversation);
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
  if (attachment.snapshot && !attachment.imageDataUrl) {
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
  previewText.hidden = !attachment.previewText;
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
  removeWelcome();
  beginTurn(message, attachments.map((item) => item.token));
  assistantElement = null;
  assistantTextNode = null;
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
  ensureTurnBody();
  if (kind === 'assistant') {
    if (!assistantElement) {
      const row = document.createElement('article');
      row.className = 'message-row assistant';
      row.setAttribute('aria-label', `Codex response turn ${turnNumber}`);
      const avatar = document.createElement('span');
      avatar.className = 'assistant-mark';
      avatar.setAttribute('aria-hidden', 'true');
      avatar.textContent = '✦';
      assistantElement = document.createElement('div');
      assistantElement.className = 'message assistant';
      assistantTextNode = document.createTextNode('');
      assistantElement.append(assistantTextNode);
      row.append(avatar, assistantElement);
      currentTurnBody.append(row);
    }
    if (update.text) assistantTextNode.data += update.text;
    scrollTranscript();
    return;
  }
  const key = update.itemId || `${kind}:${update.title}`;
  let activity = activityElements.get(key);
  if (!activity) {
    activity = createActivity(kind, update.title);
    activityElements.set(key, activity);
    currentTurnBody.append(activity.element);
  }
  updateActivity(activity, update, lifecycle);
  scrollTranscript();
}

function createActivity(kind, title) {
  const element = document.createElement('details');
  element.className = `activity-card ${kind}`;
  element.setAttribute('aria-label', `${kind === 'thinking' ? 'Thinking' : title || 'Activity'} activity`);
  element.open = true;
  const summary = document.createElement('summary');
  const icon = document.createElement('span');
  icon.className = 'activity-icon';
  icon.setAttribute('aria-hidden', 'true');
  icon.textContent = kind === 'thinking' ? '✦' : kind === 'plan' ? '≡' : '⌘';
  const heading = document.createElement('span');
  heading.className = 'activity-title';
  heading.textContent = kind === 'thinking' ? 'Thinking' : title || 'Activity';
  const subtitle = document.createElement('span');
  subtitle.className = 'activity-subtitle';
  const state = document.createElement('span');
  state.className = 'activity-state';
  state.textContent = 'running';
  summary.append(icon, heading, subtitle, state);
  const content = document.createElement('pre');
  content.className = 'activity-content';
  element.append(summary, content);
  return { element, subtitle, state, content, hasText: false };
}

function updateActivity(activity, update, lifecycle) {
  const text = String(update.text || '');
  const kind = normalizeKind(update.kind);
  if (text) {
    if (!activity.subtitle.textContent && (kind === 'tool' || kind === 'tooloutput' || kind === 'tool-output')) {
      activity.subtitle.textContent = compactLabel(text);
    }
    const shouldUseAsSubtitleOnly = lifecycle === 'started' && kind === 'tool' && !activity.hasText;
    if (!shouldUseAsSubtitleOnly) {
      activity.content.append(document.createTextNode(text));
      activity.hasText = true;
    }
  }
  activity.content.hidden = !activity.hasText;
  if (lifecycle === 'completed') {
    activity.element.classList.add('completed');
    activity.state.textContent = update.status || 'done';
    activity.element.open = false;
  } else {
    activity.state.textContent = lifecycle === 'started' ? 'running' : 'live';
  }
}

function compactLabel(value) {
  const line = String(value).split(/\r?\n/, 1)[0].replace(/\s+/g, ' ').trim();
  return line.length <= 70 ? line : `${line.slice(0, 69)}…`;
}

function normalizeKind(value) {
  if (typeof value === 'number') return ['assistant', 'thinking', 'plan', 'tool', 'toolOutput'][value] || 'tool';
  return String(value || 'tool').toLowerCase();
}

function normalizeLifecycle(value) {
  if (typeof value === 'number') return ['started', 'delta', 'completed'][value] || 'delta';
  return String(value || 'delta').toLowerCase();
}

function beginTurn(message, tokens) {
  turnNumber += 1;
  const turn = document.createElement('section');
  turn.className = 'conversation-turn';
  turn.setAttribute('aria-label', `Conversation turn ${turnNumber}`);

  const row = document.createElement('article');
  row.className = 'message-row user';
  row.setAttribute('aria-label', `User message turn ${turnNumber}`);
  const bubble = document.createElement('div');
  bubble.className = 'message user';
  if (tokens.length) {
    const context = document.createElement('span');
    context.className = 'message-context';
    context.textContent = tokens.join(' ');
    bubble.append(context);
  }
  const text = document.createElement('span');
  text.className = 'message-text';
  text.textContent = message;
  bubble.append(text);
  row.append(bubble);
  currentTurnBody = document.createElement('div');
  currentTurnBody.className = 'turn-body';
  turn.append(row, currentTurnBody);
  transcript.append(turn);
  scrollTranscript();
}

function ensureTurnBody() {
  if (currentTurnBody) return;
  beginTurn('Continue', []);
}

function appendError(message) {
  ensureTurnBody();
  const element = document.createElement('div');
  element.className = 'error-card';
  element.textContent = `Error: ${message}`;
  currentTurnBody.append(element);
}

function completeTurn(turnStatus) {
  turnActive = false;
  sendButton.disabled = false;
  composer.disabled = false;
  if (String(turnStatus).toLowerCase() === 'completed') renderStatus('ready');
  else if (!status.classList.contains('warning')) renderStatus(`turn ${turnStatus}`, true);
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

function seedAcceptanceConversation() {
  if (transcript.querySelector('.conversation-turn')) return;
  removeWelcome();
  beginTurn('Summarize the selected section and keep the table structure.', ['[docs.example.com]']);
  renderStreamUpdate({ kind: 'thinking', lifecycle: 'started', title: 'Thinking', text: '', itemId: 'seed-thinking-1' });
  renderStreamUpdate({ kind: 'thinking', lifecycle: 'delta', title: 'Thinking', text: 'Reading the selected text and semantic table hierarchy.', itemId: 'seed-thinking-1' });
  renderStreamUpdate({ kind: 'thinking', lifecycle: 'completed', title: 'Thinking', text: '', status: 'done', itemId: 'seed-thinking-1' });
  renderStreamUpdate({ kind: 'tool', lifecycle: 'started', title: 'Tool', text: 'context · inspect_structure', itemId: 'seed-tool-1' });
  renderStreamUpdate({ kind: 'toolOutput', lifecycle: 'delta', title: 'Tool progress', text: 'Read the current document structure.', itemId: 'seed-tool-1' });
  renderStreamUpdate({ kind: 'tool', lifecycle: 'completed', title: 'Tool', text: '', status: 'completed', itemId: 'seed-tool-1' });
  renderStreamUpdate({ kind: 'assistant', lifecycle: 'delta', title: 'Codex', text: 'The selected section is preserved as structured context, including its table rows and headers.' });

  assistantElement = null;
  assistantTextNode = null;
  activityElements.clear();
  beginTurn('Now compare it with the second tab.', ['[shop.example.com]']);
  renderStreamUpdate({ kind: 'assistant', lifecycle: 'delta', title: 'Codex', text: 'I’ll keep both contexts separate and compare only the facts each tab exposes.' });
  renderStatus('ready');
}
