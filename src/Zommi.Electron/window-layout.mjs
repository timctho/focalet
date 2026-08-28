export const COMPACT_WINDOW_SIZE = 56;
export const PANEL_BOTTOM_GAP = 18;

export function calculateAdaptiveWindowSize(workArea, isLarge) {
  const horizontalScale = isLarge ? 0.72 : 0.56;
  const verticalScale = isLarge ? 0.84 : 0.72;
  const minimumWidth = isLarge ? 980 : 840;
  const maximumWidth = isLarge ? 1360 : 1120;
  const minimumHeight = isLarge ? 720 : 600;
  const maximumHeight = isLarge ? 940 : 840;
  const availableWidth = Math.max(640, Math.floor(workArea.width - 32));
  const availableHeight = Math.max(500, Math.floor(workArea.height - 32));
  return {
    width: Math.min(availableWidth, clamp(Math.round(workArea.width * horizontalScale), minimumWidth, maximumWidth)),
    height: Math.min(availableHeight, clamp(Math.round(workArea.height * verticalScale), minimumHeight, maximumHeight)),
  };
}

export function calculateAnchoredWindowBounds(workArea, size, bottomGap = PANEL_BOTTOM_GAP) {
  return {
    x: Math.round(workArea.x + (workArea.width - size.width) / 2),
    y: Math.round(workArea.y + workArea.height - size.height - bottomGap),
    width: Math.round(size.width),
    height: Math.round(size.height),
  };
}

export function calculateCompactWindowBounds(workArea) {
  return calculateAnchoredWindowBounds(workArea, {
    width: COMPACT_WINDOW_SIZE,
    height: COMPACT_WINDOW_SIZE,
  });
}

export function interpolateWindowBounds(start, target, progress) {
  const position = Math.max(0, Math.min(1, progress));
  return Object.fromEntries(['x', 'y', 'width', 'height'].map((key) => [
    key,
    Math.round(start[key] + (target[key] - start[key]) * position),
  ]));
}

function clamp(value, minimum, maximum) {
  return Math.max(minimum, Math.min(value, maximum));
}
