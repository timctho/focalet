const screenshot = document.querySelector('#screen');
const selection = document.querySelector('#selection');
let anchor = null;

window.zommiSelection.onInitialize(({ imageDataUrl }) => { screenshot.src = imageDataUrl; });
document.addEventListener('mousedown', (event) => {
  if (event.button !== 0) return;
  anchor = { x: event.clientX, y: event.clientY };
  draw(anchor, anchor);
});
document.addEventListener('mousemove', (event) => {
  if (!anchor) return;
  draw(anchor, { x: event.clientX, y: event.clientY });
});
document.addEventListener('mouseup', (event) => {
  if (event.button !== 0 || !anchor) return;
  const end = { x: event.clientX, y: event.clientY };
  window.zommiSelection.complete({ x1: anchor.x, y1: anchor.y, x2: end.x, y2: end.y });
  anchor = null;
});
document.addEventListener('keydown', (event) => {
  if (event.key === 'Escape') window.zommiSelection.cancel();
});

function draw(start, end) {
  selection.hidden = false;
  selection.style.left = `${Math.min(start.x, end.x)}px`;
  selection.style.top = `${Math.min(start.y, end.y)}px`;
  selection.style.width = `${Math.abs(end.x - start.x)}px`;
  selection.style.height = `${Math.abs(end.y - start.y)}px`;
}
