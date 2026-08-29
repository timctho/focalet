export function normalizeRectangle(rectangle) {
  const x1 = Number(rectangle?.x1 ?? 0);
  const y1 = Number(rectangle?.y1 ?? 0);
  const x2 = Number(rectangle?.x2 ?? x1);
  const y2 = Number(rectangle?.y2 ?? y1);
  return {
    x: Math.round(Math.min(x1, x2)),
    y: Math.round(Math.min(y1, y2)),
    width: Math.round(Math.abs(x2 - x1)),
    height: Math.round(Math.abs(y2 - y1)),
  };
}

export function scaleCropRectangle(rectangle, displayBounds, imageSize) {
  const scaleX = imageSize.width / displayBounds.width;
  const scaleY = imageSize.height / displayBounds.height;
  const x = Math.max(0, Math.round(rectangle.x * scaleX));
  const y = Math.max(0, Math.round(rectangle.y * scaleY));
  return {
    x,
    y,
    width: Math.max(1, Math.min(imageSize.width - x, Math.round(rectangle.width * scaleX))),
    height: Math.max(1, Math.min(imageSize.height - y, Math.round(rectangle.height * scaleY))),
  };
}
