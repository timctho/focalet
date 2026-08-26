import {
  activityKey,
  effortsForModel,
  extractDisplayUserText,
  isNearBottom,
  mergeActivityText,
  mergeDistinctTextSections,
  sessionTitle,
} from './renderer-logic.mjs';

const glass = document.querySelector('.glass');
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
const scrollToLatest = document.querySelector('#ScrollToLatest');
const sessionSidebar = document.querySelector('#SessionSidebar');
const sessionList = document.querySelector('#SessionList');
const toggleSessions = document.querySelector('#ToggleSessions');
const newSession = document.querySelector('#NewSession');
const modelPanel = document.querySelector('#ModelPanel');
const modelSearch = document.querySelector('#ModelSearch');
const modelList = document.querySelector('#ModelList');
const effortList = document.querySelector('#EffortList');
const modelSummary = document.querySelector('#ModelSummary');
const modelSummaryLabel = document.querySelector('#ModelSummaryLabel');
const attachments = [];
const activityElements = new Map();
const pendingStreamUpdates = [];
let assistantElement = null;
let assistantTextNode = null;
let currentTurnBody = null;
let streamFrame = 0;
let turnActive = false;
let interruptRequested = false;
let previewTimer = null;
let turnNumber = 0;
let autoFollow = true;
let programmaticScroll = false;
let activeThreadId = null;
let sessions = [];
let models = [];
let selectedModel = '';
let selectedEffort = '';
let sessionBusy = false;

document.querySelector('#HideZommi').addEventListener('click', () => window.zommi.hide());
document.querySelector('#ExpandZommi').addEventListener('click', () => window.zommi.toggleExpanded());
document.querySelector('#SelectImage').addEventListener('click', () => window.zommi.selectImage());
document.querySelector('#ClosePreview').addEventListener('click', hidePreview);
toggleSessions.addEventListener('click', toggleSessionSidebar);
newSession.addEventListener('click', createSession);
glass.addEventListener('mouseenter', () => setPointerOverGlass(true));
glass.addEventListener('mouseleave', () => setPointerOverGlass(false));
modelSummary.addEventListener('click', toggleModelPanel);
modelSearch.addEventListener('input', renderModelOptions);
modelSearch.addEventListener('keydown', handleModelSearchKeydown);
document.addEventListener('pointerdown', closeModelPanelFromOutside);
document.addEventListener('keydown', handleGlobalKeydown);
scrollToLatest.addEventListener('click', () => scrollTranscript({ force: true }));
transcript.addEventListener('scroll', handleTranscriptScroll, { passive: true });
transcript.addEventListener('wheel', handleTranscriptWheel, { passive: true });
sendButton.addEventListener('click', handlePrimaryAction);
composer.addEventListener('input', resizeComposer);
composer.addEventListener('keydown', (event) => {
  if (event.key === 'Enter' && !event.shiftKey) {
    event.preventDefault();
    if (!turnActive) sendMessage();
  }
  if (event.key === 'Escape') window.zommi.hide();
});
preview.addEventListener('mouseenter', () => clearTimeout(previewTimer));
preview.addEventListener('mouseleave', schedulePreviewHide);

window.zommi.onContext(addAttachment);
window.zommi.onStatus(({ message, warning }) => renderStatus(message, warning));
window.zommi.onStream(queueStreamUpdate);
window.zommi.onTurnCompleted(completeTurn);
window.zommi.onFocusComposer(() => focusComposer());
window.zommi.onAcceptanceConversation?.(seedAcceptanceConversation);
window.zommi.onWindowMoving?.((moving) => document.body.classList.toggle('window-moving', Boolean(moving)));
window.zommi.onShortcuts((state) => {
  shortcuts.textContent = 'Alt+A context · Alt+Shift+A image';
  shortcuts.setAttribute('aria-label', `Alt+A registered: ${Boolean(state.context)}; Alt+Shift+A registered: ${Boolean(state.image)}`);
});

void initializeChatControls();

function setPointerOverGlass(pointerOver) {
  glass.classList.toggle('pointer-over', pointerOver);
  requestAnimationFrame(() => window.zommi.reportAcceptanceHover?.(pointerOver));
}

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
    remove.append(createUiIcon('close'));
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

async function initializeChatControls() {
  try {
    const state = await window.zommi.getChatState();
    applyChatState(state, { renderHistory: true });
  } catch (error) {
    renderStatus(`Chat controls unavailable: ${error.message}`, true);
  }
}

function applyChatState(state, { renderHistory = false } = {}) {
  activeThreadId = state?.activeThreadId || state?.thread?.id || activeThreadId;
  if (Array.isArray(state?.models) && state.models.length) models = state.models;
  if (Array.isArray(state?.sessions)) sessions = state.sessions;
  selectedModel = state?.activeModel || selectedModel || models.find((model) => model.isDefault)?.model || models[0]?.model || '';
  const activeModel = findSelectedModel();
  const supported = effortsForModel(activeModel);
  selectedEffort = state?.activeEffort || selectedEffort || activeModel?.defaultReasoningEffort || supported[0] || '';
  if (supported.length && !supported.includes(selectedEffort)) selectedEffort = activeModel?.defaultReasoningEffort || supported[0];
  renderModelControls();
  renderSessions();
  if (renderHistory) renderThreadHistory(state?.thread);
}

function renderModelControls() {
  renderModelOptions();
  renderEffortOptions();
  const model = findSelectedModel();
  const modelName = model?.displayName || selectedModel || 'Default model';
  modelSummaryLabel.textContent = `${modelName}${selectedEffort ? ` · ${formatEffort(selectedEffort)}` : ''}`;
  modelSummary.title = modelSummaryLabel.textContent;
  modelSummary.setAttribute('aria-label', `Choose model and reasoning level, current ${modelSummaryLabel.textContent}`);
  modelSummary.disabled = sessionBusy;
}

function findSelectedModel() {
  return models.find((model) => (model.model || model.id) === selectedModel) || null;
}

function formatEffort(value) {
  const text = String(value || '');
  return text ? `${text[0].toUpperCase()}${text.slice(1)}` : '';
}

function renderModelOptions() {
  const query = modelSearch.value.trim().toLowerCase();
  const visibleModels = models.filter((model) => {
    const haystack = `${model.displayName || ''} ${model.model || model.id || ''}`.toLowerCase();
    return !query || haystack.includes(query);
  });
  modelList.replaceChildren();
  for (const model of visibleModels) {
    const value = model.model || model.id;
    const option = document.createElement('button');
    option.type = 'button';
    option.className = `model-option${value === selectedModel ? ' selected' : ''}`;
    option.id = `Model-${domId(value)}`;
    option.dataset.model = value;
    option.setAttribute('role', 'option');
    option.setAttribute('aria-selected', String(value === selectedModel));
    option.disabled = turnActive || sessionBusy;
    const text = document.createElement('span');
    text.className = 'model-option-text';
    const name = document.createElement('span');
    name.className = 'model-option-name';
    name.textContent = model.displayName || value;
    const id = document.createElement('span');
    id.className = 'model-option-id';
    id.textContent = value;
    text.append(name, id);
    const check = document.createElement('span');
    check.className = 'model-option-check';
    check.setAttribute('aria-hidden', 'true');
    check.append(createUiIcon('check'));
    option.append(text, check);
    option.addEventListener('click', () => selectModel(value));
    modelList.append(option);
  }
  if (!visibleModels.length) {
    const empty = document.createElement('div');
    empty.className = 'model-empty';
    empty.textContent = 'No matching models';
    modelList.append(empty);
  }
}

function renderEffortOptions() {
  effortList.replaceChildren();
  for (const effort of effortsForModel(findSelectedModel())) {
    const option = document.createElement('button');
    option.type = 'button';
    option.className = `effort-option${effort === selectedEffort ? ' selected' : ''}`;
    option.id = `Effort-${domId(effort)}`;
    option.dataset.effort = effort;
    option.setAttribute('role', 'option');
    option.setAttribute('aria-selected', String(effort === selectedEffort));
    option.textContent = formatEffort(effort);
    option.disabled = turnActive || sessionBusy;
    option.addEventListener('click', () => selectEffort(effort));
    effortList.append(option);
  }
}

function domId(value) {
  return String(value || '').replace(/[^a-z0-9_-]+/gi, '-');
}

function selectModel(value) {
  selectedModel = value;
  const model = findSelectedModel();
  const efforts = effortsForModel(model);
  if (!efforts.includes(selectedEffort)) selectedEffort = model?.defaultReasoningEffort || efforts[0] || '';
  renderModelControls();
}

function selectEffort(value) {
  selectedEffort = value;
  renderModelControls();
}

function toggleModelPanel() {
  const open = modelPanel.hidden;
  modelPanel.hidden = !open;
  modelSummary.setAttribute('aria-expanded', String(open));
  if (open) {
    modelSearch.value = '';
    renderModelOptions();
    requestAnimationFrame(() => modelSearch.focus({ preventScroll: true }));
  }
}

function closeModelPanel() {
  if (modelPanel.hidden) return;
  modelPanel.hidden = true;
  modelSummary.setAttribute('aria-expanded', 'false');
}

function closeModelPanelFromOutside(event) {
  if (modelPanel.hidden || modelPanel.contains(event.target) || modelSummary.contains(event.target)) return;
  closeModelPanel();
}

function handleGlobalKeydown(event) {
  if (event.key !== 'Escape' || modelPanel.hidden) return;
  event.preventDefault();
  closeModelPanel();
  modelSummary.focus({ preventScroll: true });
}

function handleModelSearchKeydown(event) {
  if (event.key !== 'ArrowDown') return;
  const firstOption = modelList.querySelector('.model-option:not(:disabled)');
  if (!firstOption) return;
  event.preventDefault();
  firstOption.focus({ preventScroll: true });
}

function toggleSessionSidebar() {
  const open = !sessionSidebar.classList.contains('open');
  sessionSidebar.classList.toggle('open', open);
  sessionSidebar.setAttribute('aria-hidden', String(!open));
  toggleSessions.setAttribute('aria-expanded', String(open));
  toggleSessions.setAttribute('aria-label', `${open ? 'Hide' : 'Show'} chat sessions`);
}

function renderSessions() {
  sessionList.replaceChildren();
  const ordered = [...sessions];
  if (activeThreadId && !ordered.some((session) => session.id === activeThreadId)) {
    ordered.unshift({ id: activeThreadId, preview: 'New chat' });
  }
  for (const session of ordered) {
    const button = document.createElement('button');
    button.type = 'button';
    button.className = `session-item${session.id === activeThreadId ? ' active' : ''}`;
    button.textContent = sessionTitle(session);
    button.title = extractDisplayUserText(session.name || session.preview || 'New chat');
    button.disabled = sessionBusy || turnActive || session.id === activeThreadId;
    button.addEventListener('click', () => switchSession(session.id));
    sessionList.append(button);
  }
  newSession.disabled = sessionBusy || turnActive;
}

async function createSession() {
  if (sessionBusy || turnActive) return;
  setSessionBusy(true);
  try {
    const state = await window.zommi.createSession({ model: selectedModel, effort: selectedEffort });
    applyChatState(state, { renderHistory: true });
    renderStatus('New chat ready');
    focusComposer();
  } catch (error) {
    renderStatus(`Could not create chat: ${error.message}`, true);
  } finally {
    setSessionBusy(false);
  }
}

async function switchSession(threadId) {
  if (sessionBusy || turnActive || threadId === activeThreadId) return;
  setSessionBusy(true);
  try {
    const state = await window.zommi.switchSession(threadId);
    applyChatState(state, { renderHistory: true });
    renderStatus('Chat switched');
    focusComposer();
  } catch (error) {
    renderStatus(`Could not switch chat: ${error.message}`, true);
  } finally {
    setSessionBusy(false);
  }
}

function setSessionBusy(busy) {
  sessionBusy = busy;
  renderSessions();
  renderModelControls();
}

async function sendMessage() {
  if (turnActive || sessionBusy) return;
  const message = composer.value.trim();
  if (!message) return;
  closeModelPanel();
  turnActive = true;
  interruptRequested = false;
  renderPrimaryAction();
  composer.disabled = true;
  renderSessions();
  renderModelControls();
  removeWelcome();
  beginTurn(message, attachments.map((item) => item.token));
  assistantElement = null;
  assistantTextNode = null;
  activityElements.clear();
  try {
    await window.zommi.send({
      message,
      attachments: attachments.map(({ snapshot, imageDataUrl }) => ({ snapshot, imageDataUrl })),
      model: selectedModel,
      effort: selectedEffort,
    });
    updateActiveSessionTitle(message);
    attachments.splice(0);
    composer.value = '';
    renderAttachments();
    resizeComposer();
  } catch (error) {
    appendError(error.message);
    completeTurn('failed');
  }
}

function handlePrimaryAction() {
  if (turnActive) {
    void stopTurn();
    return;
  }
  void sendMessage();
}

async function stopTurn() {
  if (!turnActive || interruptRequested) return;
  interruptRequested = true;
  renderPrimaryAction();
  renderStatus('stopping…');
  try {
    await window.zommi.interrupt();
  } catch (error) {
    if (!turnActive) return;
    interruptRequested = false;
    renderPrimaryAction();
    renderStatus(`Could not stop response: ${error.message}`, true);
  }
}

function renderPrimaryAction() {
  sendButton.classList.toggle('is-stop', turnActive);
  sendButton.classList.toggle('stop-requested', interruptRequested);
  sendButton.disabled = turnActive && interruptRequested;
  sendButton.setAttribute('aria-label', turnActive ? 'Stop response' : 'Send message');
  sendButton.title = turnActive ? (interruptRequested ? 'Stopping…' : 'Stop') : 'Send';
}

function updateActiveSessionTitle(message) {
  let session = sessions.find((item) => item.id === activeThreadId);
  if (!session && activeThreadId) {
    session = { id: activeThreadId, preview: message, updatedAt: Math.floor(Date.now() / 1000) };
    sessions.unshift(session);
  }
  if (session && (!session.preview || session.preview === 'New chat')) session.preview = message;
  renderSessions();
}

function queueStreamUpdate(update) {
  pendingStreamUpdates.push(update);
  if (streamFrame) return;
  streamFrame = requestAnimationFrame(flushStreamUpdates);
}

function flushStreamUpdates() {
  if (streamFrame) cancelAnimationFrame(streamFrame);
  streamFrame = 0;
  if (!pendingStreamUpdates.length) return;
  const updates = pendingStreamUpdates.splice(0);
  for (const update of updates) renderStreamUpdate(update, { deferScroll: true });
  scrollTranscript();
}

function renderStreamUpdate(update, { deferScroll = false } = {}) {
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
      avatar.append(createUiIcon('sparkle'));
      assistantElement = document.createElement('div');
      assistantElement.className = 'message assistant';
      assistantTextNode = document.createTextNode('');
      assistantElement.append(assistantTextNode);
      row.append(avatar, assistantElement);
      currentTurnBody.append(row);
    }
    if (update.text) assistantTextNode.data += update.text;
    if (!deferScroll) scrollTranscript();
    return;
  }
  const key = activityKey(kind, update.itemId, update.title);
  let activity = activityElements.get(key);
  if (!activity) {
    activity = createActivity(kind, update.title);
    activityElements.set(key, activity);
    currentTurnBody.append(activity.element);
  }
  updateActivity(activity, update, lifecycle);
  if (!deferScroll) scrollTranscript();
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
  icon.append(createUiIcon(kind === 'thinking' ? 'sparkle' : kind === 'plan' ? 'plan' : 'tool'));
  const heading = document.createElement('span');
  heading.className = 'activity-title';
  heading.textContent = kind === 'thinking' ? 'Thinking' : title || 'Activity';
  const subtitle = document.createElement('span');
  subtitle.className = 'activity-subtitle';
  const state = document.createElement('span');
  state.className = 'activity-state';
  setActivityState(state, false);
  summary.append(icon, heading, subtitle, state);
  const content = document.createElement('pre');
  content.className = 'activity-content';
  element.append(summary, content);
  return { element, subtitle, state, content, text: '', hasText: false, sourceTexts: new Map() };
}

function updateActivity(activity, update, lifecycle) {
  const text = String(update.text || '');
  const kind = normalizeKind(update.kind);
  const sourceId = String(update.itemId || `${kind}:${update.title || ''}`);
  if (text) {
    if (!activity.subtitle.textContent && (kind === 'tool' || kind === 'tooloutput' || kind === 'tool-output')) {
      activity.subtitle.textContent = compactLabel(text);
    }
    const shouldUseAsSubtitleOnly = lifecycle === 'started' && kind === 'tool' && !activity.hasText;
    if (!shouldUseAsSubtitleOnly) {
      const sourceText = mergeActivityText(activity.sourceTexts.get(sourceId), text, kind, lifecycle);
      activity.sourceTexts.set(sourceId, sourceText);
      const merged = kind === 'thinking'
        ? mergeDistinctTextSections(activity.sourceTexts.values())
        : mergeActivityText(activity.text, text, kind, lifecycle);
      if (merged !== activity.text) {
        activity.text = merged;
        activity.content.textContent = merged;
      }
      activity.hasText = Boolean(activity.text);
    }
  }
  activity.content.hidden = !activity.hasText;
  if (lifecycle === 'completed') {
    activity.element.classList.add('completed');
    setActivityState(activity.state, true);
    activity.element.open = false;
  } else {
    activity.element.classList.remove('completed');
    activity.element.open = true;
    setActivityState(activity.state, false);
  }
}

function setActivityState(element, completed) {
  element.replaceChildren(createUiIcon(completed ? 'check' : 'spinner'));
  element.dataset.status = completed ? 'done' : 'live';
  element.setAttribute('aria-label', completed ? 'Done' : 'Live');
  element.title = completed ? 'Done' : 'Live';
}

function compactLabel(value) {
  const line = String(value).split(/\r?\n/, 1)[0].replace(/\s+/g, ' ').trim();
  return line.length <= 70 ? line : `${line.slice(0, 69)}…`;
}

function createUiIcon(name) {
  const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  svg.setAttribute('class', 'ui-icon');
  svg.setAttribute('viewBox', '0 0 20 20');
  svg.setAttribute('aria-hidden', 'true');
  const path = document.createElementNS('http://www.w3.org/2000/svg', 'path');
  const paths = {
    close: 'm6 6 8 8m0-8-8 8',
    sparkle: 'M10 3.5c.55 3.8 2.7 5.95 6.5 6.5-3.8.55-5.95 2.7-6.5 6.5-.55-3.8-2.7-5.95-6.5-6.5 3.8-.55 5.95-2.7 6.5-6.5Z',
    plan: 'M5 5.5h10M5 10h10M5 14.5h7',
    tool: 'M6.3 5.1a3.4 3.4 0 0 0 4.2 4.4l4.2 4.2-1.9 1.9-4.2-4.2a3.4 3.4 0 0 1-4.2-4.3l2 2 1.9-1.9-2-2.1Z',
    check: 'm5.5 10 3 3 6-6',
    spinner: 'M15.5 10a5.5 5.5 0 1 1-2.1-4.3',
  };
  path.setAttribute('d', paths[name] || paths.tool);
  svg.append(path);
  return svg;
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
  scrollTranscript({ force: true });
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
  flushStreamUpdates();
  turnActive = false;
  interruptRequested = false;
  for (const activity of activityElements.values()) {
    if (activity.element.classList.contains('completed')) continue;
    activity.element.classList.add('completed');
    setActivityState(activity.state, true);
    activity.element.open = false;
  }
  renderPrimaryAction();
  composer.disabled = false;
  const normalizedStatus = String(turnStatus).toLowerCase();
  if (normalizedStatus === 'completed') renderStatus('ready');
  else if (normalizedStatus === 'interrupted') renderStatus('stopped');
  else if (!status.classList.contains('warning')) renderStatus(`turn ${turnStatus}`, true);
  renderSessions();
  renderModelControls();
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

function handleTranscriptScroll() {
  const nearBottom = isNearBottom(transcript);
  if (programmaticScroll && nearBottom) return;
  if (programmaticScroll) programmaticScroll = false;
  autoFollow = nearBottom;
  updateLatestButton();
}

function handleTranscriptWheel(event) {
  if (!event.deltaY) return;
  programmaticScroll = false;
  autoFollow = false;
  updateLatestButton();
}

function scrollTranscript({ force = false } = {}) {
  if (!force && !autoFollow) {
    updateLatestButton();
    return;
  }
  autoFollow = true;
  programmaticScroll = true;
  transcript.scrollTop = transcript.scrollHeight;
  requestAnimationFrame(() => {
    programmaticScroll = false;
    autoFollow = isNearBottom(transcript);
    updateLatestButton();
  });
}

function updateLatestButton() {
  scrollToLatest.hidden = autoFollow || isNearBottom(transcript);
}

function removeWelcome() {
  transcript.querySelector('.welcome')?.remove();
}

function renderThreadHistory(thread) {
  pendingStreamUpdates.splice(0);
  if (streamFrame) cancelAnimationFrame(streamFrame);
  streamFrame = 0;
  transcript.replaceChildren();
  assistantElement = null;
  assistantTextNode = null;
  currentTurnBody = null;
  activityElements.clear();
  turnNumber = 0;
  const turns = Array.isArray(thread?.turns) ? thread.turns : [];
  for (const turn of turns) {
    const items = Array.isArray(turn?.items) ? turn.items : [];
    const userItem = items.find((item) => item.type === 'userMessage');
    const userText = userItem ? displayUserItem(userItem) : 'Continue';
    assistantElement = null;
    assistantTextNode = null;
    activityElements.clear();
    beginTurn(userText || 'Continue', []);
    for (const item of items) renderHistoryItem(item);
  }
  if (!turns.length) appendWelcome();
  autoFollow = true;
  scrollTranscript({ force: true });
}

function displayUserItem(item) {
  const text = (item.content || [])
    .filter((content) => content?.type === 'text' && content.text)
    .map((content) => content.text)
    .join('\n');
  return extractDisplayUserText(text);
}

function renderHistoryItem(item) {
  if (!item || item.type === 'userMessage') return;
  if (item.type === 'agentMessage') {
    if (item.phase === 'commentary') {
      renderStreamUpdate({ kind: 'thinking', lifecycle: 'completed', title: 'Thinking', text: item.text || '', itemId: item.id, status: 'done' });
    } else {
      renderStreamUpdate({ kind: 'assistant', lifecycle: 'completed', title: 'Codex', text: item.text || '', itemId: item.id });
    }
    return;
  }
  if (item.type === 'reasoning') {
    const text = mergeDistinctTextSections([...(item.summary || []), ...(item.content || [])]);
    renderStreamUpdate({ kind: 'thinking', lifecycle: 'completed', title: 'Thinking', text, itemId: item.id, status: 'done' });
    return;
  }
  if (item.type === 'plan') {
    renderStreamUpdate({ kind: 'plan', lifecycle: 'completed', title: 'Plan', text: item.text || '', itemId: item.id, status: 'done' });
    return;
  }
  const history = historyTool(item);
  if (history) renderStreamUpdate({ ...history, lifecycle: 'completed', itemId: item.id, status: item.status || 'done' });
}

function historyTool(item) {
  if (item.type === 'commandExecution') return { kind: 'tool', title: 'Command', text: [item.command, item.aggregatedOutput].filter(Boolean).join('\n') };
  if (item.type === 'fileChange') return { kind: 'tool', title: 'File change', text: (item.changes || []).map((change) => [change.kind, change.path].filter(Boolean).join(' · ')).join('\n') };
  if (item.type === 'mcpToolCall') return { kind: 'tool', title: 'MCP tool', text: [item.server, item.tool].filter(Boolean).join(' · ') };
  if (item.type === 'dynamicToolCall') return { kind: 'tool', title: 'Tool', text: [item.namespace, item.tool].filter(Boolean).join(' · ') };
  if (item.type === 'webSearch') return { kind: 'tool', title: 'Web search', text: item.query || '' };
  if (item.type === 'imageView') return { kind: 'tool', title: 'View image', text: item.path || '' };
  if (item.type === 'imageGeneration') return { kind: 'tool', title: 'Image generation', text: item.revisedPrompt || item.savedPath || '' };
  if (item.type === 'contextCompaction') return { kind: 'tool', title: 'Context', text: 'Conversation compacted' };
  return null;
}

function appendWelcome() {
  const welcome = document.createElement('div');
  welcome.className = 'welcome';
  const orb = document.createElement('div');
  orb.className = 'orb';
  const text = document.createElement('p');
  text.textContent = 'Ask about anything under your pointer.';
  welcome.append(orb, text);
  transcript.append(welcome);
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
