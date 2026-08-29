const DEFAULT_POINTER_GRACE_MS = 750;

export async function collectImageSelection({
  selectImage,
  capturePointerContext = null,
  pointerGraceMs = DEFAULT_POINTER_GRACE_MS,
  onPointerError = () => {},
}) {
  let pointerSettled = !capturePointerContext;
  let pointerContext = null;
  let pointerPromise = Promise.resolve();
  if (capturePointerContext) {
    try {
      pointerPromise = Promise.resolve(capturePointerContext())
      .then((value) => { pointerContext = value; })
      .catch((error) => { onPointerError(error); })
      .finally(() => { pointerSettled = true; });
    } catch (error) {
      pointerSettled = true;
      onPointerError(error);
    }
  }

  const selection = await selectImage();
  if (selection?.cancelled || !selection?.dataUrl) {
    return { selection, pointerContext: pointerSettled ? pointerContext : null, pointerTimedOut: false };
  }

  if (!pointerSettled) await waitForPointer(pointerPromise, pointerGraceMs);
  return { selection, pointerContext, pointerTimedOut: !pointerSettled };
}

async function waitForPointer(pointerPromise, timeoutMs) {
  let timer = null;
  try {
    await Promise.race([
      pointerPromise,
      new Promise((resolve) => { timer = setTimeout(resolve, Math.max(0, Number(timeoutMs) || 0)); }),
    ]);
  } finally {
    if (timer) clearTimeout(timer);
  }
}
