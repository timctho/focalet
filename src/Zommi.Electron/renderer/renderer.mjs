import {
  activityOpenState,
  activityKey,
  effortsForModel,
  extractDisplayUserText,
  initialHistoryStart,
  isNearBottom,
  mergeActivityText,
  mergeDistinctTextSections,
  previousHistoryStart,
  sessionStatus,
  sessionTitle,
  wheelScrollContainer,
} from './renderer-logic.mjs';
import { artifactsFromText, artifactsFromThreadItem, sandboxHtmlDocument } from '../artifacts.mjs';
import { renderMarkdown } from './markdown.mjs';
import { createNebulaOrbRenderer } from './orb-renderer.mjs';

const HISTORY_PAGE_SIZE = 18;
const HISTORY_LOAD_THRESHOLD_PX = 96;

const glass = document.querySelector('.glass');
const panelShell = document.querySelector('.panel-shell');
const panelContent = document.querySelector('.panel-content');
const compactOrb = document.querySelector('#ZommiOrb');
const compactOrbCanvas = document.querySelector('#ZommiOrbCanvas');
const compactOrbRenderer = createNebulaOrbRenderer(compactOrbCanvas);
const transcript = document.querySelector('#CodexTranscript');
const transcriptContentResizeObserver = new ResizeObserver(() => {
  if (autoFollow) scrollTranscript();
});
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
const runtimeSummary = document.querySelector('#RuntimeSummary');
const runtimeSummaryLabel = document.querySelector('#RuntimeSummaryLabel');
const runtimeStatusDot = document.querySelector('#RuntimeStatusDot');
const runtimePanel = document.querySelector('#RuntimePanel');
const runtimeList = document.querySelector('#RuntimeList');
const runtimeEmpty = document.querySelector('#RuntimeEmpty');
const refreshRuntimes = document.querySelector('#RefreshRuntimes');
const runtimeSignIn = document.querySelector('#RuntimeSignIn');
const runtimeOverrideAdapter = document.querySelector('#RuntimeOverrideAdapter');
const runtimeOverrideHost = document.querySelector('#RuntimeOverrideHost');
const runtimeOverrideHostLabel = document.querySelector('#RuntimeOverrideHostLabel');
const runtimeOverrideLocator = document.querySelector('#RuntimeOverrideLocator');
const runtimeOverrideLocatorLabel = document.querySelector('#RuntimeOverrideLocatorLabel');
const saveRuntimeOverride = document.querySelector('#SaveRuntimeOverride');
const runtimeOverrideList = document.querySelector('#RuntimeOverrideList');
const selectImage = document.querySelector('#SelectImage');
const approvalPanel = document.querySelector('#ApprovalPanel');
const approvalDetail = document.querySelector('#ApprovalDetail');
const approvalOptions = document.querySelector('#ApprovalOptions');
const questionPanel = document.querySelector('#QuestionPanel');
const questionTitle = document.querySelector('#QuestionTitle');
const questionMessage = document.querySelector('#QuestionMessage');
const questionOptions = document.querySelector('#QuestionOptions');
const questionInput = document.querySelector('#QuestionInput');
const questionSecretInput = document.querySelector('#QuestionSecretInput');
const questionCancel = document.querySelector('#QuestionCancel');
const questionSubmit = document.querySelector('#QuestionSubmit');
const modelPanel = document.querySelector('#ModelPanel');
const modelSearch = document.querySelector('#ModelSearch');
const modelList = document.querySelector('#ModelList');
const effortList = document.querySelector('#EffortList');
const modelSummary = document.querySelector('#ModelSummary');
const modelSummaryLabel = document.querySelector('#ModelSummaryLabel');
const artifactViewer = document.querySelector('#ArtifactViewer');
const artifactViewerTitle = document.querySelector('#ArtifactViewerTitle');
const artifactViewerBody = document.querySelector('#ArtifactViewerBody');
const attachments = [];
let activityElements = new Map();
let artifactElements = new Map();
const pendingStreamUpdates = [];
const activeTurns = new Map();
const unreadThreadIds = new Set();
let assistantElement = null;
let assistantText = '';
let currentTurnBody = null;
let streamFrame = 0;
let turnActive = false;
let interruptRequested = false;
let terminalTurnStatus = false;
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
let sessionPanelCloseTimer = null;
let historyTurns = [];
let historyStartIndex = 0;
let historyLoading = false;
let historyLoadFrame = 0;
let whitespaceDragFrame = 0;
let pendingWhitespaceDragPoint = null;
let whitespaceDragActive = false;
let chatControlsLoading = false;
let chatControlsReady = false;
let runtimeBusy = false;
let currentThreadCwd = '';
let runtimeState = {
  targets: [], activeTargetId: null, activeTarget: null, capabilities: [],
  settings: { hosts: [], adapters: [], overrides: [] },
};
let activeRuntimeTargetId = null;
let activeRuntimeName = 'Agent';
let activeCapabilities = new Set();
let pendingApproval = null;
let pendingQuestion = null;

document.querySelector('#HideZommi').addEventListener('click', () => window.zommi.hide());
compactOrb.addEventListener('click', () => window.zommi.openPanel());
panelContent.addEventListener('mousedown', startWhitespaceWindowDrag);
document.addEventListener('mousemove', queueWhitespaceWindowDrag);
document.addEventListener('mouseup', endWhitespaceWindowDrag);
document.querySelector('#ExpandZommi').addEventListener('click', () => window.zommi.toggleExpanded());
selectImage.addEventListener('click', () => window.zommi.selectImage());
document.querySelector('#ClosePreview').addEventListener('click', hidePreview);
toggleSessions.addEventListener('mouseenter', openSessionSidebarFromHover);
toggleSessions.addEventListener('mouseleave', scheduleSessionSidebarClose);
sessionSidebar.addEventListener('mouseenter', cancelSessionSidebarClose);
sessionSidebar.addEventListener('mouseleave', scheduleSessionSidebarClose);
newSession.addEventListener('click', createSession);
runtimeSummary.addEventListener('click', toggleRuntimePanel);
refreshRuntimes.addEventListener('click', refreshRuntimeTargets);
runtimeSignIn.addEventListener('click', signInToRuntime);
runtimeOverrideAdapter.addEventListener('change', renderRuntimeOverrides);
saveRuntimeOverride.addEventListener('click', saveRuntimeTargetOverride);
glass.addEventListener('mouseenter', () => setPointerOverGlass(true));
glass.addEventListener('mouseleave', () => setPointerOverGlass(false));
modelSummary.addEventListener('click', toggleModelPanel);
document.querySelector('#CloseArtifactViewer').addEventListener('click', closeArtifactViewer);
modelSearch.addEventListener('input', renderModelOptions);
modelSearch.addEventListener('keydown', handleModelSearchKeydown);
document.addEventListener('pointerdown', closeModelPanelFromOutside);
document.addEventListener('keydown', handleGlobalKeydown);
scrollToLatest.addEventListener('click', () => scrollTranscript({ force: true }));
transcript.addEventListener('scroll', handleTranscriptScroll, { passive: true });
transcript.addEventListener('wheel', handleTranscriptWheel, { passive: false });
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
window.zommi.onRuntimeState?.(applyRuntimeState);
window.zommi.onApprovalRequested?.(showApprovalRequest);
window.zommi.onQuestionRequested?.(showQuestionRequest);
window.zommi.onStatus(handleBackendStatus);
window.zommi.onStream(queueStreamUpdate);
window.zommi.onTurnCompleted(completeTurn);
window.zommi.onFocusComposer(() => focusComposer());
window.zommi.onWindowPresentation?.(({ open }) => setPanelPresentation(Boolean(open)));
window.zommi.onWindowBoundsSettled?.(() => syncPanelMorphGeometry());
window.zommi.onAcceptanceConversation?.(seedAcceptanceConversation);
window.zommi.onShortcuts((state) => {
  shortcuts.textContent = 'Alt+A context · Alt+Shift+A image';
  shortcuts.setAttribute('aria-label', `Alt+A registered: ${Boolean(state.context)}; Alt+Shift+A registered: ${Boolean(state.image)}`);
});
questionCancel.addEventListener('click', () => resolveQuestion({}));
questionSubmit.addEventListener('click', submitQuestionInput);
questionInput.addEventListener('keydown', (event) => {
  if (event.key === 'Escape') {
    event.preventDefault();
    void resolveQuestion({});
  } else if (event.key === 'Enter' && (event.ctrlKey || event.metaKey)) {
    event.preventDefault();
    submitQuestionInput();
  }
});
questionSecretInput.addEventListener('keydown', (event) => {
  if (event.key === 'Escape') {
    event.preventDefault();
    void resolveQuestion({});
  } else if (event.key === 'Enter') {
    event.preventDefault();
    submitQuestionInput();
  }
});

void initializeChatControls();
syncPanelMorphGeometry();
new ResizeObserver(syncPanelMorphGeometry).observe(glass);

function setPointerOverGlass(pointerOver) {
  requestAnimationFrame(() => window.zommi.reportAcceptanceHover?.(pointerOver));
}

function startWhitespaceWindowDrag(event) {
  if (event.button !== 0 || event.target !== panelContent) return;
  event.preventDefault();
  whitespaceDragActive = true;
  window.zommi.beginWindowDrag({ x: event.screenX, y: event.screenY });
}

function queueWhitespaceWindowDrag(event) {
  if (!whitespaceDragActive) return;
  pendingWhitespaceDragPoint = { x: event.screenX, y: event.screenY };
  if (whitespaceDragFrame) return;
  whitespaceDragFrame = requestAnimationFrame(() => {
    whitespaceDragFrame = 0;
    if (pendingWhitespaceDragPoint) window.zommi.moveWindowDrag(pendingWhitespaceDragPoint);
    pendingWhitespaceDragPoint = null;
  });
}

function endWhitespaceWindowDrag() {
  if (!whitespaceDragActive) return;
  whitespaceDragActive = false;
  if (whitespaceDragFrame) cancelAnimationFrame(whitespaceDragFrame);
  whitespaceDragFrame = 0;
  pendingWhitespaceDragPoint = null;
  window.zommi.endWindowDrag();
}

function setPanelPresentation(open) {
  syncPanelMorphGeometry();
  glass.classList.toggle('is-compact', !open);
  document.body.classList.toggle('is-compact', !open);
  panelShell.setAttribute('aria-hidden', String(!open));
  panelContent.setAttribute('aria-hidden', String(!open));
  compactOrb.setAttribute('aria-hidden', String(open));
  compactOrb.tabIndex = open ? -1 : 0;
}

function syncPanelMorphGeometry() {
  const panelWidth = panelShell?.offsetWidth || 0;
  const panelHeight = panelShell?.offsetHeight || 0;
  const orbSize = compactOrb?.offsetWidth || 0;
  if (!panelWidth || !panelHeight || !orbSize) return;
  glass.style.setProperty('--orb-scale-x', String(orbSize / panelWidth));
  glass.style.setProperty('--orb-scale-y', String(orbSize / panelHeight));
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
  if (chatControlsLoading) return;
  chatControlsLoading = true;
  renderModelControls();
  try {
    const discovered = await window.zommi.getRuntimeState();
    applyRuntimeState(discovered);
    if (!discovered?.activeTargetId) {
      chatControlsReady = false;
      renderStatus('No supported agent found. Capture remains available.', true);
      return;
    }
    const state = await window.zommi.getChatState();
    chatControlsReady = true;
    applyChatState(state, { renderHistory: true });
  } catch (error) {
    chatControlsReady = false;
    renderStatus(`Chat controls unavailable: ${error.message}`, true);
  } finally {
    chatControlsLoading = false;
    renderModelControls();
  }
}

function handleBackendStatus({ message, warning }) {
  const runtimeReadiness = /(?:\bready\b|loading\s+.*tools?|control\s+ready)/i.test(String(message));
  if (!warning && runtimeReadiness && (turnActive || terminalTurnStatus)) return;
  renderStatus(message, warning);
  if (!chatControlsReady && /\bready\b/i.test(String(message))) {
    void initializeChatControls();
  }
}

function applyChatState(state, { renderHistory = false } = {}) {
  if (state?.runtime) applyRuntimeState(state.runtime);
  activeRuntimeTargetId = state?.runtimeTargetId || activeRuntimeTargetId;
  activeThreadId = state?.activeThreadId || state?.thread?.id || activeThreadId;
  if (Array.isArray(state?.models) && state.models.length) models = state.models;
  if (Array.isArray(state?.sessions)) sessions = state.sessions;
  if (Array.isArray(state?.activeTurns)) {
    activeTurns.clear();
    for (const turn of state.activeTurns) {
      if (turn?.threadId) activeTurns.set(String(turn.threadId), String(turn.turnId || 'running'));
    }
  }
  markSessionRead(activeThreadId);
  syncActiveTurnState();
  selectedModel = state?.activeModel || selectedModel || models.find((model) => model.isDefault)?.model || models[0]?.model || '';
  const activeModel = findSelectedModel();
  const supported = effortsForModel(activeModel);
  selectedEffort = state?.activeEffort || selectedEffort || activeModel?.defaultReasoningEffort || supported[0] || '';
  if (supported.length && !supported.includes(selectedEffort)) selectedEffort = activeModel?.defaultReasoningEffort || supported[0];
  renderModelControls();
  renderSessions();
  if (renderHistory) renderThreadHistory(state?.thread);
  renderPrimaryAction();
  composer.disabled = sessionBusy;
}

function applyRuntimeState(nextState) {
  if (!nextState) return;
  runtimeState = {
    targets: Array.isArray(nextState.targets) ? nextState.targets : [],
    activeTargetId: nextState.activeTargetId || null,
    activeTarget: nextState.activeTarget || null,
    capabilities: Array.isArray(nextState.capabilities) ? nextState.capabilities : [],
    settings: nextState.settings && typeof nextState.settings === 'object'
      ? nextState.settings
      : { hosts: [], adapters: [], overrides: [] },
  };
  activeRuntimeTargetId = runtimeState.activeTargetId;
  activeRuntimeName = runtimeState.activeTarget?.displayName || 'Agent';
  activeCapabilities = new Set(runtimeState.capabilities);
  renderRuntimeControls();
  renderModelControls();
  renderSessions();
  renderPrimaryAction();
}

function renderRuntimeControls() {
  const active = runtimeState.targets.find((target) => target.id === runtimeState.activeTargetId)
    || runtimeState.activeTarget;
  runtimeSummaryLabel.textContent = active
    ? `${active.displayName} · ${shortHostName(active.executionHost)}`
    : runtimeBusy ? 'Finding agents…' : 'Choose agent';
  runtimeSummary.title = active
    ? `${active.displayName} ${active.protocolName} on ${active.executionHost?.displayName || 'this device'}`
    : 'Choose agent runtime';
  runtimeSummary.setAttribute('aria-label', runtimeSummary.title);
  runtimeStatusDot.dataset.status = active?.status || (runtimeBusy ? 'detecting' : 'unreachable');
  runtimeList.replaceChildren();
  for (const target of runtimeState.targets) {
    const option = document.createElement('button');
    option.type = 'button';
    option.className = `runtime-target${target.id === runtimeState.activeTargetId ? ' selected' : ''}`;
    option.dataset.targetId = target.id;
    option.setAttribute('role', 'option');
    option.setAttribute('aria-selected', String(target.id === runtimeState.activeTargetId));
    option.disabled = runtimeBusy;
    const dot = document.createElement('span');
    dot.className = 'runtime-status-dot';
    dot.dataset.status = target.status || 'detected';
    dot.setAttribute('aria-hidden', 'true');
    const copy = document.createElement('span');
    copy.className = 'runtime-target-copy';
    const name = document.createElement('span');
    name.className = 'runtime-target-name';
    name.textContent = target.displayName;
    const detail = document.createElement('span');
    detail.className = 'runtime-target-detail';
    detail.textContent = `${target.protocolName} · ${target.executionHost?.displayName || 'Local'}`;
    copy.append(name, detail);
    const state = document.createElement('span');
    state.className = `runtime-target-state${target.classification === 'compatible' ? ' compatible' : ''}`;
    state.textContent = target.classification === 'compatible'
      ? 'Compatible'
      : runtimeStatusLabel(target.status);
    option.append(dot, copy, state);
    option.addEventListener('click', () => selectRuntimeTarget(target.id));
    runtimeList.append(option);
  }
  runtimeEmpty.hidden = runtimeState.targets.length > 0;
  runtimeSignIn.hidden = active?.status !== 'sign-in-required';
  runtimeSignIn.textContent = active ? `Open ${active.displayName} sign-in` : 'Open sign-in';
  renderRuntimeOverrides();
  selectImage.disabled = Boolean(active) && !activeCapabilities.has('input.image.v1');
  selectImage.title = selectImage.disabled ? `${activeRuntimeName} does not accept image input` : 'Select image context';
}

function renderRuntimeOverrides() {
  const settings = runtimeState.settings || {};
  const adapters = Array.isArray(settings.adapters) ? settings.adapters : [];
  const previousAdapter = runtimeOverrideAdapter.value;
  runtimeOverrideAdapter.replaceChildren(...adapters.map((adapter) => {
    const option = document.createElement('option');
    option.value = adapter.adapterId;
    option.textContent = `${adapter.displayName} · ${adapter.protocolName}`;
    return option;
  }));
  if (adapters.some((adapter) => adapter.adapterId === previousAdapter)) runtimeOverrideAdapter.value = previousAdapter;
  const selectedAdapter = adapters.find((adapter) => adapter.adapterId === runtimeOverrideAdapter.value) || adapters[0];
  const acceptsEndpoint = Boolean(selectedAdapter?.acceptsEndpoint);
  runtimeOverrideHostLabel.hidden = acceptsEndpoint;
  runtimeOverrideLocatorLabel.textContent = acceptsEndpoint ? 'Gateway endpoint' : 'Executable path';
  runtimeOverrideLocator.placeholder = acceptsEndpoint ? 'ws://127.0.0.1:18789' : 'Absolute native or WSL path';

  const previousHost = runtimeOverrideHost.value;
  const hosts = (settings.hosts || []).filter((host) => selectedAdapter?.hostKinds?.includes(host.kind));
  runtimeOverrideHost.replaceChildren(...hosts.map((host) => {
    const option = document.createElement('option');
    option.value = host.id;
    option.textContent = host.displayName;
    return option;
  }));
  if (hosts.some((host) => host.id === previousHost)) runtimeOverrideHost.value = previousHost;
  saveRuntimeOverride.disabled = runtimeBusy || !selectedAdapter || (!acceptsEndpoint && !runtimeOverrideHost.value);

  runtimeOverrideList.replaceChildren();
  for (const override of settings.overrides || []) {
    const row = document.createElement('div');
    row.className = 'runtime-override';
    const label = document.createElement('span');
    const adapter = adapters.find((candidate) => candidate.adapterId === override.adapterId);
    label.textContent = `${adapter?.displayName || override.adapterId} · ${override.endpoint || override.executablePath}`;
    label.title = label.textContent;
    const remove = document.createElement('button');
    remove.type = 'button';
    remove.textContent = 'Remove';
    remove.disabled = runtimeBusy;
    remove.addEventListener('click', () => removeRuntimeTargetOverride(override.id));
    row.append(label, remove);
    runtimeOverrideList.append(row);
  }
}

async function saveRuntimeTargetOverride() {
  if (runtimeBusy) return;
  const adapter = runtimeState.settings?.adapters?.find((item) => item.adapterId === runtimeOverrideAdapter.value);
  const locator = runtimeOverrideLocator.value.trim();
  if (!adapter || !locator) {
    renderStatus('Choose an agent and enter an override location.', true);
    return;
  }
  runtimeBusy = true;
  renderRuntimeControls();
  try {
    const value = adapter.acceptsEndpoint
      ? { adapterId: adapter.adapterId, endpoint: locator }
      : { adapterId: adapter.adapterId, executionHostId: runtimeOverrideHost.value, executablePath: locator };
    applyRuntimeState(await window.zommi.saveRuntimeOverride(value));
    runtimeOverrideLocator.value = '';
    renderStatus('Runtime override added');
  } catch (error) {
    renderStatus(`Could not add runtime override: ${error.message}`, true);
  } finally {
    runtimeBusy = false;
    renderRuntimeControls();
  }
}

async function removeRuntimeTargetOverride(id) {
  if (runtimeBusy) return;
  runtimeBusy = true;
  renderRuntimeControls();
  try {
    applyRuntimeState(await window.zommi.removeRuntimeOverride(id));
    renderStatus('Runtime override removed');
  } catch (error) {
    renderStatus(`Could not remove runtime override: ${error.message}`, true);
  } finally {
    runtimeBusy = false;
    renderRuntimeControls();
  }
}

function shortHostName(host) {
  if (!host) return 'Local';
  if (host.kind === 'wsl') return host.name || host.displayName || 'WSL';
  return host.displayName || 'Local';
}

function runtimeStatusLabel(value) {
  return ({
    detected: 'Detected',
    starting: 'Starting',
    ready: 'Ready',
    'sign-in-required': 'Sign in',
    'unsupported-version': 'Unsupported',
    unreachable: 'Unavailable',
  })[value] || 'Detected';
}

function renderModelControls() {
  renderModelOptions();
  renderEffortOptions();
  const supportsModelSelection = activeCapabilities.has('model.select.v1');
  modelSummary.hidden = !runtimeState.activeTargetId || !supportsModelSelection;
  if (modelSummary.hidden) closeModelPanel();
  if (!chatControlsReady) {
    modelSummaryLabel.textContent = chatControlsLoading ? 'Connecting…' : 'Retry';
    modelSummary.title = chatControlsLoading ? `Connecting to ${activeRuntimeName}` : `Retry ${activeRuntimeName} connection`;
    modelSummary.setAttribute('aria-label', modelSummary.title);
    modelSummary.disabled = sessionBusy || chatControlsLoading;
    return;
  }
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
  if (!chatControlsReady) {
    void initializeChatControls();
    return;
  }
  const open = modelPanel.hidden;
  closeRuntimePanel();
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
  if (!modelPanel.hidden && !modelPanel.contains(event.target) && !modelSummary.contains(event.target)) closeModelPanel();
  if (!runtimePanel.hidden && !runtimePanel.contains(event.target) && !runtimeSummary.contains(event.target)) closeRuntimePanel();
}

function handleGlobalKeydown(event) {
  if (event.key !== 'Escape' || (modelPanel.hidden && runtimePanel.hidden && artifactViewer.hidden)) return;
  event.preventDefault();
  if (!artifactViewer.hidden) {
    closeArtifactViewer();
  } else if (!runtimePanel.hidden) {
    closeRuntimePanel();
    runtimeSummary.focus({ preventScroll: true });
  } else {
    closeModelPanel();
    modelSummary.focus({ preventScroll: true });
  }
}

function handleModelSearchKeydown(event) {
  if (event.key !== 'ArrowDown') return;
  const firstOption = modelList.querySelector('.model-option:not(:disabled)');
  if (!firstOption) return;
  event.preventDefault();
  firstOption.focus({ preventScroll: true });
}

function toggleRuntimePanel() {
  const open = runtimePanel.hidden;
  closeModelPanel();
  runtimePanel.hidden = !open;
  runtimePanel.setAttribute('aria-hidden', String(!open));
  runtimeSummary.setAttribute('aria-expanded', String(open));
  if (open) renderRuntimeControls();
}

function closeRuntimePanel() {
  if (runtimePanel.hidden) return;
  runtimePanel.hidden = true;
  runtimePanel.setAttribute('aria-hidden', 'true');
  runtimeSummary.setAttribute('aria-expanded', 'false');
}

async function selectRuntimeTarget(targetId) {
  if (runtimeBusy) return;
  if (targetId === runtimeState.activeTargetId) {
    closeRuntimePanel();
    return;
  }
  runtimeBusy = true;
  chatControlsReady = false;
  renderRuntimeControls();
  renderModelControls();
  renderStatus('Switching agent runtime…');
  try {
    const selected = await window.zommi.selectRuntime(targetId);
    applyRuntimeState(selected);
    resetChatForRuntimeSwitch();
    const state = await window.zommi.getChatState();
    chatControlsReady = true;
    applyChatState(state, { renderHistory: true });
    renderStatus(`${activeRuntimeName} ready`);
    closeRuntimePanel();
    focusComposer();
  } catch (error) {
    renderStatus(`Could not switch agent: ${error.message}`, true);
    try {
      applyRuntimeState(await window.zommi.getRuntimeState());
    } catch {
      // The original switching error remains the actionable result.
    }
  } finally {
    runtimeBusy = false;
    renderRuntimeControls();
    renderModelControls();
  }
}

async function refreshRuntimeTargets() {
  if (runtimeBusy) return;
  runtimeBusy = true;
  renderRuntimeControls();
  renderStatus('Finding agent runtimes…');
  try {
    const refreshed = await window.zommi.refreshRuntimes();
    applyRuntimeState(refreshed);
    if (refreshed.activeTargetId) await initializeChatControls();
    else renderStatus('No supported agent found. Capture remains available.', true);
  } catch (error) {
    renderStatus(`Agent discovery failed: ${error.message}`, true);
  } finally {
    runtimeBusy = false;
    renderRuntimeControls();
  }
}

async function signInToRuntime() {
  if (!runtimeState.activeTargetId || runtimeBusy) return;
  runtimeBusy = true;
  renderRuntimeControls();
  try {
    const result = await window.zommi.signInRuntime(runtimeState.activeTargetId);
    renderStatus(`${result.displayCommand} opened in a terminal`);
  } catch (error) {
    renderStatus(`Could not open sign-in: ${error.message}`, true);
  } finally {
    runtimeBusy = false;
    renderRuntimeControls();
  }
}

function resetChatForRuntimeSwitch() {
  dismissApproval();
  dismissQuestion();
  closeArtifactViewer();
  activeThreadId = null;
  sessions = [];
  models = [];
  selectedModel = '';
  selectedEffort = '';
  activeTurns.clear();
  unreadThreadIds.clear();
  syncActiveTurnState();
  renderThreadHistory(null);
  renderSessions();
  renderPrimaryAction();
}

function showQuestionRequest(request) {
  if (request?.runtimeTargetId && request.runtimeTargetId !== activeRuntimeTargetId) return;
  pendingQuestion = request;
  questionTitle.textContent = request?.title || 'Agent asks a question';
  questionMessage.textContent = request?.message || '';
  questionOptions.replaceChildren();
  questionInput.hidden = true;
  questionSecretInput.hidden = true;
  questionSubmit.hidden = true;
  questionInput.value = '';
  questionSecretInput.value = '';
  if (Array.isArray(request?.questions) && request.questions.length) {
    renderStructuredQuestions(request.questions);
    questionSubmit.hidden = false;
    questionPanel.hidden = false;
    requestAnimationFrame(() => questionOptions.querySelector('input')?.focus({ preventScroll: true }));
    return;
  }
  const method = String(request?.method || 'input');
  if (method === 'confirm') {
    addQuestionOption('Yes', { confirmed: true });
    addQuestionOption('No', { confirmed: false });
  } else if (method === 'select') {
    for (const option of request?.options || []) {
      const value = typeof option === 'string' ? option : String(option?.value ?? option?.label ?? '');
      const label = typeof option === 'string' ? option : String(option?.label ?? option?.value ?? '');
      if (value) addQuestionOption(label || value, { value });
    }
  } else {
    const input = request?.sensitive ? questionSecretInput : questionInput;
    input.hidden = false;
    questionSubmit.hidden = false;
    input.placeholder = request?.placeholder || '';
    input.value = request?.sensitive ? '' : request?.prefill || '';
  }
  questionPanel.hidden = false;
  requestAnimationFrame(() => {
    const input = !questionSecretInput.hidden ? questionSecretInput : questionInput;
    if (!input.hidden) {
      input.focus({ preventScroll: true });
      input.setSelectionRange(input.value.length, input.value.length);
    } else {
      questionOptions.querySelector('button')?.focus({ preventScroll: true });
    }
  });
}

function renderStructuredQuestions(questions) {
  for (const question of questions.slice(0, 3)) {
    const fieldset = document.createElement('fieldset');
    fieldset.className = 'structured-question';
    fieldset.dataset.questionId = String(question.questionId || '');
    const legend = document.createElement('legend');
    legend.textContent = question.header || 'Question';
    const prompt = document.createElement('div');
    prompt.className = 'structured-question-prompt';
    prompt.textContent = question.question || '';
    fieldset.append(legend, prompt);
    const options = Array.isArray(question.options) ? question.options.slice(0, 4) : [];
    for (const option of options) {
      const label = document.createElement('label');
      label.className = 'structured-question-option';
      const input = document.createElement('input');
      input.type = question.multiSelect ? 'checkbox' : 'radio';
      input.name = `question-${domId(question.questionId)}`;
      input.value = String(typeof option === 'string' ? option : option?.label || '');
      input.dataset.answerOption = 'true';
      const copy = document.createElement('span');
      const title = document.createElement('strong');
      title.textContent = input.value;
      copy.append(title);
      const description = typeof option === 'object' ? String(option?.description || '') : '';
      if (description) {
        const detail = document.createElement('small');
        detail.textContent = description;
        copy.append(detail);
      }
      label.append(input, copy);
      fieldset.append(label);
    }
    if (question.isOther || !options.length) {
      const other = document.createElement('input');
      other.type = question.isSecret ? 'password' : 'text';
      other.className = 'question-input structured-question-other';
      other.dataset.otherAnswer = 'true';
      other.autocomplete = 'off';
      other.spellcheck = false;
      other.placeholder = options.length ? 'Other answer' : 'Your answer';
      fieldset.append(other);
    }
    questionOptions.append(fieldset);
  }
}

function addQuestionOption(label, answer) {
  const button = document.createElement('button');
  button.type = 'button';
  button.className = 'question-option';
  button.textContent = label;
  button.addEventListener('click', () => resolveQuestion(answer));
  questionOptions.append(button);
}

function submitQuestionInput() {
  if (!pendingQuestion) return;
  if (Array.isArray(pendingQuestion.questions) && pendingQuestion.questions.length) {
    const answers = {};
    for (const fieldset of questionOptions.querySelectorAll('.structured-question')) {
      const values = [...fieldset.querySelectorAll('input[data-answer-option]:checked')]
        .map((input) => input.value)
        .filter(Boolean);
      const other = fieldset.querySelector('input[data-other-answer]')?.value?.trim();
      if (other) values.push(other);
      answers[fieldset.dataset.questionId] = values;
    }
    void resolveQuestion({ answers });
    return;
  }
  const input = pendingQuestion.sensitive ? questionSecretInput : questionInput;
  void resolveQuestion({ value: input.value });
}

async function resolveQuestion(answer) {
  if (!pendingQuestion) return;
  const request = pendingQuestion;
  setQuestionBusy(true);
  try {
    await window.zommi.resolveQuestion({
      questionId: request.questionId,
      answer,
      runtimeTargetId: request.runtimeTargetId,
      sessionId: request.sessionId || request.threadId,
    });
    dismissQuestion();
    renderStatus(Object.keys(answer).length ? 'Answer sent' : 'Question cancelled');
  } catch (error) {
    renderStatus(`Could not answer question: ${error.message}`, true);
    setQuestionBusy(false);
  }
}

function setQuestionBusy(busy) {
  for (const control of questionPanel.querySelectorAll('button, textarea, input')) control.disabled = busy;
}

function dismissQuestion() {
  pendingQuestion = null;
  questionPanel.hidden = true;
  questionTitle.textContent = 'Agent asks a question';
  questionMessage.textContent = '';
  questionOptions.replaceChildren();
  questionInput.value = '';
  questionInput.placeholder = '';
  questionSecretInput.value = '';
  questionSecretInput.placeholder = '';
  setQuestionBusy(false);
}

function showApprovalRequest(request) {
  if (request?.runtimeTargetId && request.runtimeTargetId !== activeRuntimeTargetId) return;
  pendingApproval = request;
  approvalDetail.textContent = approvalRequestText(request);
  approvalOptions.replaceChildren();
  for (const option of request.options || []) {
    const button = document.createElement('button');
    button.type = 'button';
    button.className = `approval-option ${String(option.kind || '').startsWith('allow') ? 'allow' : 'reject'}`;
    button.textContent = option.name || option.optionId;
    button.addEventListener('click', () => resolveApproval(option.optionId));
    approvalOptions.append(button);
  }
  if (!(request.options || []).some((option) => String(option.kind || '').startsWith('reject'))) {
    const deny = document.createElement('button');
    deny.type = 'button';
    deny.className = 'approval-option reject';
    deny.textContent = 'Deny';
    deny.addEventListener('click', () => resolveApproval(null));
    approvalOptions.append(deny);
  }
  approvalPanel.hidden = false;
  approvalOptions.querySelector('button')?.focus({ preventScroll: true });
}

async function resolveApproval(optionId) {
  if (!pendingApproval) return;
  const request = pendingApproval;
  for (const button of approvalOptions.querySelectorAll('button')) button.disabled = true;
  try {
    await window.zommi.resolveApproval({
      approvalId: request.approvalId,
      optionId,
      runtimeTargetId: request.runtimeTargetId,
      sessionId: request.sessionId || request.threadId,
    });
    dismissApproval();
    renderStatus(optionId ? 'Permission response sent' : 'Permission denied');
  } catch (error) {
    renderStatus(`Could not answer permission: ${error.message}`, true);
    for (const button of approvalOptions.querySelectorAll('button')) button.disabled = false;
  }
}

function dismissApproval() {
  pendingApproval = null;
  approvalPanel.hidden = true;
  approvalDetail.textContent = '';
  approvalOptions.replaceChildren();
}

function approvalRequestText(request) {
  const toolCall = request?.toolCall || {};
  const values = [toolCall.title || 'Agent tool'];
  if (toolCall.rawInput) values.push(typeof toolCall.rawInput === 'string' ? toolCall.rawInput : JSON.stringify(toolCall.rawInput, null, 2));
  return values.join('\n');
}

function setSessionSidebarOpen(open) {
  sessionSidebar.classList.toggle('open', open);
  sessionSidebar.setAttribute('aria-hidden', String(!open));
  toggleSessions.setAttribute('aria-expanded', String(open));
  toggleSessions.setAttribute('aria-label', `Chat sessions — ${open ? 'visible while hovered' : 'hover to show'}`);
}

function openSessionSidebarFromHover() {
  cancelSessionSidebarClose();
  setSessionSidebarOpen(true);
}

function cancelSessionSidebarClose() {
  clearTimeout(sessionPanelCloseTimer);
  sessionPanelCloseTimer = null;
}

function scheduleSessionSidebarClose() {
  cancelSessionSidebarClose();
  sessionPanelCloseTimer = setTimeout(() => {
    if (!toggleSessions.matches(':hover') && !sessionSidebar.matches(':hover')) {
      setSessionSidebarOpen(false);
    }
  }, 220);
}

function renderOrbActivity() {
  const working = activeTurns.size > 0;
  compactOrb.classList.toggle('is-working', working);
  compactOrbRenderer.setWorking(working);
  compactOrb.dataset.activity = working ? 'working' : 'idle';
  compactOrb.setAttribute('aria-label', working ? 'Open Zommi chat — agent working' : 'Open Zommi chat');
}

function renderSessions() {
  renderOrbActivity();
  sessionList.replaceChildren();
  const supportsSessionNavigation = activeCapabilities.has('session.list.v1')
    || activeCapabilities.has('session.create.v1')
    || activeCapabilities.has('session.resume.v1');
  toggleSessions.hidden = !runtimeState.activeTargetId || !supportsSessionNavigation;
  if (toggleSessions.hidden) setSessionSidebarOpen(false);
  const ordered = [...sessions];
  const runningThreadIds = new Set(activeTurns.keys());
  if (activeThreadId && !ordered.some((session) => session.id === activeThreadId)) {
    ordered.unshift({ id: activeThreadId, preview: 'New chat' });
  }
  for (const session of ordered) {
    const state = sessionStatus(session.id, activeThreadId, runningThreadIds, unreadThreadIds);
    const button = document.createElement('button');
    button.type = 'button';
    button.className = `session-item${session.id === activeThreadId ? ' active' : ''}`;
    button.dataset.threadId = session.id;
    button.dataset.status = state;
    button.title = extractDisplayUserText(session.name || session.preview || 'New chat');
    button.setAttribute('aria-label', sessionTitle(session));
    button.setAttribute('aria-description', sessionStatusLabel(state));
    button.disabled = sessionBusy || session.id === activeThreadId;
    const stateIcon = document.createElement('span');
    stateIcon.className = `session-status ${state}`;
    stateIcon.setAttribute('aria-label', sessionStatusLabel(state));
    stateIcon.title = sessionStatusLabel(state);
    stateIcon.append(createUiIcon(sessionStatusIcon(state)));
    const label = document.createElement('span');
    label.className = 'session-name';
    label.textContent = sessionTitle(session);
    button.append(stateIcon, label);
    button.addEventListener('click', () => switchSession(session.id));
    sessionList.append(button);
  }
  newSession.hidden = !activeCapabilities.has('session.create.v1');
  newSession.disabled = sessionBusy || runtimeBusy;
}

function sessionStatusLabel(value) {
  return ({ running: 'Running', unread: 'Unread', read: 'Read', done: 'Done' })[value] || 'Done';
}

function sessionStatusIcon(value) {
  return ({ running: 'spinner', unread: 'unread', read: 'read', done: 'check' })[value] || 'check';
}

function markSessionRead(threadId) {
  if (threadId) unreadThreadIds.delete(threadId);
}

function syncActiveTurnState() {
  turnActive = Boolean(activeThreadId && activeTurns.has(activeThreadId));
  if (!turnActive) interruptRequested = false;
}

async function createSession() {
  if (sessionBusy) return;
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
  if (sessionBusy || threadId === activeThreadId) return;
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
  composer.disabled = busy;
  renderSessions();
  renderModelControls();
}

async function sendMessage() {
  if (turnActive || sessionBusy) return;
  const message = composer.value.trim();
  if (!message) return;
  const sendingThreadId = activeThreadId;
  if (!sendingThreadId) {
    renderStatus('No agent session is ready. Choose or refresh an agent, then send again.', true);
    return;
  }
  const sendingAttachments = attachments.map(({ snapshot, imageDataUrl }) => ({ snapshot, imageDataUrl }));
  const sendingTokens = attachments.map((item) => item.token);
  const clientOperationId = `zommi:${crypto.randomUUID()}`;
  terminalTurnStatus = false;
  // Acknowledge the local submit before constructing the new transcript and
  // its accessibility tree. The original text is retained above and restored
  // if the runtime rejects the turn.
  composer.value = '';
  resizeComposer();
  closeModelPanel();
  activeTurns.set(sendingThreadId, 'starting');
  syncActiveTurnState();
  interruptRequested = false;
  renderPrimaryAction();
  renderSessions();
  renderModelControls();
  removeWelcome();
  beginTurn(message, sendingTokens);
  assistantElement = null;
  assistantText = '';
  activityElements = new Map();
  artifactElements = new Map();
  attachments.splice(0);
  renderAttachments();
  try {
    const result = await window.zommi.send({
      message,
      attachments: sendingAttachments,
      model: selectedModel,
      effort: selectedEffort,
      clientOperationId,
      rendererSubmittedAtEpochMs: Date.now(),
    });
    activeTurns.set(sendingThreadId, result?.turnId || activeTurns.get(sendingThreadId) || 'running');
    updateSessionTitle(sendingThreadId, message);
    if (activeThreadId === sendingThreadId) {
      syncActiveTurnState();
      renderPrimaryAction();
    }
    renderSessions();
  } catch (error) {
    activeTurns.delete(sendingThreadId);
    if (activeThreadId === sendingThreadId) {
      composer.value = message;
      appendError(error.message);
    }
    completeTurn({ threadId: sendingThreadId, status: 'failed' });
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
  if (!turnActive || interruptRequested || !activeCapabilities.has('turn.interrupt.v1')) return;
  interruptRequested = true;
  renderPrimaryAction();
  renderStatus('stopping…');
  try {
    const activeTurnId = activeTurns.get(activeThreadId);
    await window.zommi.interrupt({
      runtimeTargetId: activeRuntimeTargetId,
      sessionId: activeThreadId,
      ...(!['starting', 'running'].includes(String(activeTurnId)) ? { turnId: activeTurnId } : {}),
    });
  } catch (error) {
    if (!turnActive) return;
    interruptRequested = false;
    renderPrimaryAction();
    renderStatus(`Could not stop response: ${error.message}`, true);
  }
}

function renderPrimaryAction() {
  const canInterrupt = activeCapabilities.has('turn.interrupt.v1');
  sendButton.classList.toggle('is-stop', turnActive);
  sendButton.classList.toggle('stop-requested', interruptRequested);
  sendButton.disabled = runtimeBusy || (!turnActive && !chatControlsReady) || (turnActive && (!canInterrupt || interruptRequested));
  sendButton.setAttribute('aria-label', turnActive ? (canInterrupt ? 'Stop response' : 'Response running') : 'Send message');
  sendButton.title = turnActive ? (canInterrupt ? (interruptRequested ? 'Stopping…' : 'Stop') : 'This agent cannot be interrupted') : 'Send';
}

function updateSessionTitle(threadId, message) {
  let session = sessions.find((item) => item.id === threadId);
  if (!session && threadId) {
    session = { id: threadId, preview: message, updatedAt: Math.floor(Date.now() / 1000) };
    sessions.unshift(session);
  }
  if (session && (!session.preview || session.preview === 'New chat')) session.preview = message;
  renderSessions();
}

function queueStreamUpdate(update) {
  if (update?.runtimeTargetId && update.runtimeTargetId !== activeRuntimeTargetId) return;
  const threadId = String(update?.threadId || activeThreadId || '');
  if (!threadId) return;
  const wasRunning = activeTurns.has(threadId);
  activeTurns.set(threadId, activeTurns.get(threadId) || update?.itemId || 'running');
  if (!wasRunning) renderSessions();
  if (threadId !== activeThreadId) return;
  pendingStreamUpdates.push(update);
  if (streamFrame) return;
  streamFrame = requestAnimationFrame(flushStreamUpdates);
}

function flushStreamUpdates() {
  if (streamFrame) cancelAnimationFrame(streamFrame);
  streamFrame = 0;
  if (!pendingStreamUpdates.length) return;
  const updates = pendingStreamUpdates.splice(0);
  for (const update of updates) {
    if (!update?.threadId || update.threadId === activeThreadId) renderStreamUpdate(update, { deferScroll: true });
  }
  scrollTranscript();
}

function renderStreamUpdate(update, { deferScroll = false, turnCompleted = false } = {}) {
  removeWelcome();
  const kind = normalizeKind(update.kind);
  const lifecycle = normalizeLifecycle(update.lifecycle);
  ensureTurnBody();
  if (kind === 'assistant') {
    if (!assistantElement) {
      const row = document.createElement('article');
      row.className = 'message-row assistant';
      row.setAttribute('aria-label', `${activeRuntimeName} response turn ${turnNumber}`);
      const avatar = document.createElement('span');
      avatar.className = 'assistant-mark';
      avatar.setAttribute('aria-hidden', 'true');
      avatar.append(createUiIcon('sparkle'));
      assistantElement = document.createElement('div');
      assistantElement.className = 'message assistant markdown-content';
      row.append(avatar, assistantElement);
      currentTurnBody.append(row);
    }
    if (update.text) {
      assistantText = update.replace ? update.text : `${assistantText}${update.text}`;
      renderAssistantMarkdown(assistantElement, assistantText);
    }
    renderArtifacts(update.artifacts, update.runtimeTargetId);
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
  updateActivity(activity, update, lifecycle, { turnCompleted });
  renderArtifacts(update.artifacts, update.runtimeTargetId);
  if (!deferScroll) scrollTranscript();
}

function createActivity(kind, title) {
  const element = document.createElement('details');
  element.className = `activity-card ${kind}`;
  element.setAttribute('aria-label', `${kind === 'thinking' ? 'Thinking' : title || 'Activity'} activity`);
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
  const activity = {
    element,
    subtitle,
    state,
    content,
    kind,
    text: '',
    hasText: false,
    pointerInside: false,
    userControlled: false,
    sourceTexts: new Map(),
  };
  element.open = true;
  summary.addEventListener('click', () => {
    activity.userControlled = true;
    if (!element.open) {
      autoFollow = false;
      updateLatestButton();
    }
  });
  element.addEventListener('pointerenter', () => { activity.pointerInside = true; });
  element.addEventListener('pointerleave', () => { activity.pointerInside = false; });
  return activity;
}

function updateActivity(activity, update, lifecycle, { turnCompleted = false } = {}) {
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
  } else {
    activity.element.classList.remove('completed');
    setActivityState(activity.state, false);
  }
  activity.element.open = activityOpenState({
    currentOpen: activity.element.open,
    userControlled: activity.userControlled,
    kind: activity.kind,
    lifecycle,
    turnCompleted,
  });
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

function renderAssistantMarkdown(element, markdown) {
  element.innerHTML = renderMarkdown(markdown);
  if (!element.querySelector('h1, h2, h3, h4, h5, h6, pre, table')) return;
  const actions = document.createElement('div');
  actions.className = 'response-actions';
  const copy = document.createElement('button');
  copy.type = 'button';
  copy.className = 'response-copy-button';
  copy.textContent = 'Copy';
  copy.setAttribute('aria-label', 'Copy formatted response');
  copy.addEventListener('click', () => copyFormattedResponse(copy, markdown));
  actions.append(copy);
  element.prepend(actions);
}

async function copyFormattedResponse(button, markdown) {
  button.disabled = true;
  try {
    await window.zommi.copy(markdown);
    button.textContent = 'Copied';
  } catch {
    button.textContent = 'Copy failed';
  }
  setTimeout(() => {
    if (!button.isConnected) return;
    button.disabled = false;
    button.textContent = 'Copy';
  }, 1400);
}

function renderArtifacts(values, runtimeTargetId = activeRuntimeTargetId) {
  for (const artifact of Array.isArray(values) ? values : []) {
    const key = artifact?.path
      ? `${artifact.kind}:${artifact.path}`
      : artifact?.dataUrl
        ? `${artifact.kind}:data:${artifact.dataUrl.length}:${artifact.dataUrl.slice(-64)}`
        : String(artifact?.id || '');
    if (!key || artifactElements.has(key)) continue;
    const card = document.createElement('figure');
    card.className = `artifact-card ${artifact.kind}`;
    card.dataset.artifactId = String(artifact.id || artifact.path || artifact.kind);
    const header = document.createElement('div');
    header.className = 'artifact-head';
    const kind = document.createElement('span');
    kind.className = 'artifact-kind';
    kind.textContent = artifact.kind === 'html' ? 'HTML' : 'Image';
    const title = document.createElement('span');
    title.className = 'artifact-title';
    title.textContent = artifact.title || (artifact.kind === 'html' ? 'HTML preview' : 'Generated image');
    header.append(kind, title);
    const surface = document.createElement('div');
    surface.className = 'artifact-surface loading';
    surface.textContent = 'Loading preview…';
    const footer = document.createElement('figcaption');
    const path = document.createElement('span');
    path.className = 'artifact-path';
    path.textContent = artifact.path || 'Generated in this chat';
    path.title = path.textContent;
    const open = document.createElement('button');
    open.type = 'button';
    open.className = 'artifact-open';
    open.textContent = 'Preview';
    open.disabled = true;
    footer.append(path, open);
    card.append(header, surface, footer);
    currentTurnBody.append(card);
    const state = { card, surface, open, artifact, loaded: null };
    artifactElements.set(key, state);
    void hydrateArtifact(state, runtimeTargetId);
  }
}

async function hydrateArtifact(state, runtimeTargetId) {
  try {
    const artifact = state.artifact;
    const loaded = artifact.kind === 'image' && artifact.dataUrl
      ? { ...artifact, dataUrl: artifact.dataUrl }
      : artifact.kind === 'html' && typeof artifact.html === 'string'
        ? { ...artifact, html: artifact.html }
        : await window.zommi.loadArtifactPreview({ ...artifact, runtimeTargetId: runtimeTargetId || activeRuntimeTargetId });
    state.loaded = loaded;
    state.surface.replaceChildren(createArtifactMedia(loaded, true));
    state.surface.classList.remove('loading');
    state.open.disabled = false;
    state.open.addEventListener('click', () => showArtifactViewer(loaded, artifact));
  } catch (error) {
    state.card.classList.add('failed');
    state.surface.classList.remove('loading');
    state.surface.textContent = `Preview unavailable · ${error.message}`;
  }
}

function createArtifactMedia(loaded, compact) {
  if (loaded.kind === 'image') {
    const image = document.createElement('img');
    image.src = loaded.dataUrl;
    image.alt = loaded.title || loaded.name || 'Generated image';
    image.loading = compact ? 'lazy' : 'eager';
    return image;
  }
  const frame = document.createElement('iframe');
  frame.className = 'artifact-html-frame';
  frame.title = loaded.title || loaded.name || 'Generated HTML preview';
  frame.setAttribute('sandbox', '');
  frame.setAttribute('referrerpolicy', 'no-referrer');
  frame.tabIndex = compact ? -1 : 0;
  frame.srcdoc = sandboxHtmlDocument(loaded.html);
  return frame;
}

function showArtifactViewer(loaded, artifact) {
  artifactViewerTitle.textContent = artifact.title || loaded.name || (loaded.kind === 'html' ? 'HTML preview' : 'Generated image');
  artifactViewerBody.replaceChildren(createArtifactMedia(loaded, false));
  artifactViewer.hidden = false;
  document.querySelector('#CloseArtifactViewer').focus({ preventScroll: true });
}

function closeArtifactViewer() {
  artifactViewer.hidden = true;
  artifactViewerBody.replaceChildren();
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
    unread: 'M10 5.5a4.5 4.5 0 1 1 0 9 4.5 4.5 0 0 1 0-9Z',
    read: 'M3.8 10s2.2-3.4 6.2-3.4 6.2 3.4 6.2 3.4-2.2 3.4-6.2 3.4S3.8 10 3.8 10Zm6.2-1.5a1.5 1.5 0 1 0 0 3 1.5 1.5 0 0 0 0-3Z',
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

function beginTurn(message, tokens, options = {}) {
  const displayTurnNumber = options.number || turnNumber + 1;
  turnNumber = Math.max(turnNumber, displayTurnNumber);
  const turn = document.createElement('section');
  turn.className = 'conversation-turn';
  turn.setAttribute('aria-label', `Conversation turn ${displayTurnNumber}`);

  const row = document.createElement('article');
  row.className = 'message-row user';
  row.setAttribute('aria-label', `User message turn ${displayTurnNumber}`);
  const bubble = document.createElement('div');
  bubble.className = 'message user';
  if (tokens.length) {
    const context = document.createElement('span');
    context.className = 'message-context';
    context.textContent = tokens.join(' ');
    bubble.append(context);
  }
  const text = document.createElement('div');
  text.className = 'message-text markdown-content';
  text.innerHTML = renderMarkdown(message);
  bubble.append(text);
  row.append(bubble);
  currentTurnBody = document.createElement('div');
  currentTurnBody.className = 'turn-body';
  turn.append(row, currentTurnBody);
  (options.parent || transcript).append(turn);
  transcriptContentResizeObserver.observe(turn);
  if (options.scroll !== false) scrollTranscript({ force: true });
  return turn;
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

function completeTurn(completion) {
  if (completion?.runtimeTargetId && completion.runtimeTargetId !== activeRuntimeTargetId) return;
  const threadId = typeof completion === 'object' && completion
    ? String(completion.threadId || activeThreadId || '')
    : String(activeThreadId || '');
  const turnStatus = typeof completion === 'object' && completion ? completion.status : completion;
  activeTurns.delete(threadId);
  if (threadId !== activeThreadId) {
    if (threadId) unreadThreadIds.add(threadId);
    renderSessions();
    return;
  }
  flushStreamUpdates();
  renderArtifacts(artifactsFromText(assistantText, { cwd: currentThreadCwd }), completion?.runtimeTargetId);
  terminalTurnStatus = true;
  syncActiveTurnState();
  interruptRequested = false;
  for (const activity of activityElements.values()) {
    if (!activity.element.classList.contains('completed')) {
      activity.element.classList.add('completed');
      setActivityState(activity.state, true);
    }
    activity.element.open = activityOpenState({
      currentOpen: activity.element.open,
      userControlled: activity.userControlled || activity.pointerInside || activity.element.matches(':focus-within'),
      kind: activity.kind,
      lifecycle: 'completed',
      turnCompleted: true,
    });
  }
  renderPrimaryAction();
  composer.disabled = sessionBusy;
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
  status.setAttribute('aria-label', `Agent status: ${message}`);
}

function resizeComposer() {
  composer.style.height = 'auto';
  composer.style.height = `${Math.min(composer.scrollHeight, 110)}px`;
}

function focusComposer() {
  setTimeout(() => composer.focus({ preventScroll: true }), 0);
}

function handleTranscriptScroll() {
  if (!historyLoading && historyStartIndex > 0 && transcript.scrollTop <= HISTORY_LOAD_THRESHOLD_PX) {
    if (!historyLoadFrame) historyLoadFrame = requestAnimationFrame(loadOlderHistory);
  }
  const nearBottom = isNearBottom(transcript);
  if (programmaticScroll && nearBottom) return;
  if (programmaticScroll) programmaticScroll = false;
  autoFollow = nearBottom;
  updateLatestButton();
}

function handleTranscriptWheel(event) {
  if (!event.deltaY) return;
  if (wheelScrollContainer(event.target, transcript) !== transcript) {
    programmaticScroll = false;
    autoFollow = false;
    updateLatestButton();
    return;
  }
  event.preventDefault();
  programmaticScroll = false;
  const maximumScrollTop = Math.max(0, transcript.scrollHeight - transcript.clientHeight);
  transcript.scrollTop = Math.max(0, Math.min(maximumScrollTop, transcript.scrollTop + event.deltaY));
  autoFollow = event.deltaY > 0 && isNearBottom(transcript);
  updateLatestButton();
}

function scrollTranscript({ force = false, settle = false } = {}) {
  if (!force && isReadingExpandedThinking()) {
    autoFollow = false;
    updateLatestButton();
    return;
  }
  if (!force && !autoFollow) {
    updateLatestButton();
    return;
  }
  autoFollow = true;
  programmaticScroll = true;
  transcript.scrollTop = transcript.scrollHeight;
  requestAnimationFrame(() => {
    if (settle) transcript.scrollTop = transcript.scrollHeight;
    programmaticScroll = false;
    autoFollow = isNearBottom(transcript);
    updateLatestButton();
  });
}

function isReadingExpandedThinking() {
  return [...activityElements.values()].some((activity) => activity.kind === 'thinking'
    && activity.element.open
    && (activity.userControlled || activity.pointerInside || activity.element.matches(':focus-within')));
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
  if (historyLoadFrame) cancelAnimationFrame(historyLoadFrame);
  historyLoadFrame = 0;
  transcriptContentResizeObserver.disconnect();
  transcript.replaceChildren();
  assistantElement = null;
  assistantText = '';
  currentTurnBody = null;
  activityElements = new Map();
  artifactElements = new Map();
  turnNumber = 0;
  currentThreadCwd = String(thread?.cwd || '');
  historyTurns = Array.isArray(thread?.turns) ? thread.turns : [];
  historyStartIndex = initialHistoryStart(historyTurns.length, HISTORY_PAGE_SIZE);
  renderHistoryRange(historyStartIndex, historyTurns.length, transcript);
  if (!historyTurns.length) appendWelcome();
  autoFollow = true;
  scrollTranscript({ force: true, settle: true });
}

function renderHistoryRange(start, end, parent) {
  for (let index = start; index < end; index += 1) {
    const turn = historyTurns[index];
    const items = Array.isArray(turn?.items) ? turn.items : [];
    const userItem = items.find((item) => item.type === 'userMessage');
    const userText = userItem ? displayUserItem(userItem) : 'Continue';
    assistantElement = null;
    assistantText = '';
    activityElements = new Map();
    artifactElements = new Map();
    beginTurn(userText || 'Continue', [], { number: index + 1, parent, scroll: false });
    const turnCompleted = activeTurns.get(activeThreadId) !== turn?.id;
    for (const item of items) renderHistoryItem(item, { deferScroll: true, turnCompleted });
  }
}

function loadOlderHistory() {
  historyLoadFrame = 0;
  if (historyLoading || historyStartIndex <= 0) return;
  historyLoading = true;
  const previousHeight = transcript.scrollHeight;
  const previousTop = transcript.scrollTop;
  const nextStart = previousHistoryStart(historyStartIndex, HISTORY_PAGE_SIZE);
  const firstRenderedTurn = transcript.querySelector('.conversation-turn');
  const cursor = { assistantElement, assistantText, currentTurnBody, activityElements, artifactElements };
  const fragment = document.createDocumentFragment();
  renderHistoryRange(nextStart, historyStartIndex, fragment);
  transcript.insertBefore(fragment, firstRenderedTurn);
  historyStartIndex = nextStart;
  assistantElement = cursor.assistantElement;
  assistantText = cursor.assistantText;
  currentTurnBody = cursor.currentTurnBody;
  activityElements = cursor.activityElements;
  artifactElements = cursor.artifactElements;
  transcript.scrollTop = previousTop + transcript.scrollHeight - previousHeight;
  historyLoading = false;
}

function displayUserItem(item) {
  const text = (item.content || [])
    .filter((content) => content?.type === 'text' && content.text)
    .map((content) => content.text)
    .join('\n');
  return extractDisplayUserText(text);
}

function renderHistoryItem(item, { deferScroll = false, turnCompleted = true } = {}) {
  if (!item || item.type === 'userMessage') return;
  const lifecycle = isCompletedHistoryItem(item) ? 'completed' : 'delta';
  const artifacts = artifactsFromThreadItem(item, { cwd: currentThreadCwd });
  if (item.type === 'agentMessage') {
    if (item.phase === 'commentary') {
      renderStreamUpdate({ kind: 'thinking', lifecycle, title: 'Thinking', text: item.text || '', itemId: item.id, status: item.status, artifacts }, { deferScroll, turnCompleted });
    } else {
      renderStreamUpdate({ kind: 'assistant', lifecycle, title: activeRuntimeName, text: item.text || '', itemId: item.id, artifacts }, { deferScroll, turnCompleted });
    }
    return;
  }
  if (item.type === 'reasoning') {
    const text = mergeDistinctTextSections([...(item.summary || []), ...(item.content || [])]);
    renderStreamUpdate({ kind: 'thinking', lifecycle, title: 'Thinking', text, itemId: item.id, status: item.status }, { deferScroll, turnCompleted });
    return;
  }
  if (item.type === 'plan') {
    renderStreamUpdate({ kind: 'plan', lifecycle, title: 'Plan', text: item.text || '', itemId: item.id, status: item.status }, { deferScroll, turnCompleted });
    return;
  }
  const history = historyTool(item);
  if (history) renderStreamUpdate({ ...history, lifecycle, itemId: item.id, status: item.status || 'done', artifacts }, { deferScroll, turnCompleted });
}

function isCompletedHistoryItem(item) {
  const value = String(item?.status || '').toLowerCase();
  return !value || ['completed', 'failed', 'declined', 'interrupted', 'cancelled'].includes(value);
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
  assistantText = '';
  activityElements.clear();
  beginTurn('Now compare it with the second tab.', ['[shop.example.com]']);
  const generatedImage = btoa('<svg xmlns="http://www.w3.org/2000/svg" width="640" height="360"><rect width="640" height="360" fill="#edf4ff"/><circle cx="320" cy="170" r="90" fill="#779cff"/><text x="320" y="310" text-anchor="middle" font-family="sans-serif" font-size="28" fill="#253b68">ZOMMI IMAGE PREVIEW</text></svg>');
  renderStreamUpdate({
    kind: 'assistant', lifecycle: 'completed', title: 'Codex',
    text: 'I’ll keep both contexts separate and compare only the facts each tab exposes.',
    artifacts: [
      { id: 'seed-generated-image', kind: 'image', title: 'Generated image', dataUrl: `data:image/svg+xml;base64,${generatedImage}` },
      { id: 'seed-generated-html', kind: 'html', title: 'Generated HTML', path: 'preview.html', html: '<main style="font:28px sans-serif;padding:48px;color:#253b68">ZOMMI_HTML_PREVIEW</main>' },
    ],
  });
  renderStatus('ready');
}
