// This is the selected 05 / Nebula Liquid Glass material from
// docs/orb-design-samples.html, reduced to its production-only shader branch.
const VERTEX_SOURCE = `
  attribute vec2 a_position;
  varying vec2 v_uv;
  void main() {
    v_uv = a_position * .5 + .5;
    gl_Position = vec4(a_position, 0., 1.);
  }
`;

const FRAGMENT_SOURCE = `
  precision highp float;
  varying vec2 v_uv;
  uniform vec2 u_resolution;
  uniform float u_time;
  uniform float u_working;

  const vec3 CYAN = vec3(.388, .847, .957);
  const vec3 BLUE = vec3(.365, .549, 1.);
  const vec3 VIOLET = vec3(.608, .431, .91);
  const vec3 PINK = vec3(.941, .545, .659);

  mat2 rotate2d(float angle) {
    float c = cos(angle), s = sin(angle);
    return mat2(c, -s, s, c);
  }

  vec3 spectrum(float value) {
    float t = clamp(value, 0., 1.);
    if (t < .36) return mix(CYAN, BLUE, t / .36);
    if (t < .7) return mix(BLUE, VIOLET, (t - .36) / .34);
    return mix(VIOLET, PINK, (t - .7) / .3);
  }

  vec3 backdrop(vec2 point) {
    float vertical = clamp(point.y * .24 + .52, 0., 1.);
    vec3 base = mix(vec3(.73, .77, .82), vec3(.91, .93, .94), vertical);
    float cyanPool = exp(-dot((point - vec2(-.85, .34)) * vec2(.7, 1.1), (point - vec2(-.85, .34)) * vec2(.7, 1.1)) * 1.2);
    float pinkPool = exp(-dot((point - vec2(.9, -.45)) * vec2(.8, 1.), (point - vec2(.9, -.45)) * vec2(.8, 1.)) * 1.1);
    base = mix(base, CYAN, cyanPool * .09);
    base = mix(base, PINK, pinkPool * .065);
    float threadA = exp(-abs(point.y - .16 * sin(point.x * 1.7) - .08) * 85.);
    float threadB = exp(-abs(point.y + .18 * sin(point.x * 1.45 + .8) + .18) * 72.);
    base = mix(base, vec3(.97, .98, 1.), threadA * .42);
    base = mix(base, vec3(.58, .65, .78), threadB * .17);
    return base;
  }

  vec3 backdropHaze(vec2 point) {
    float vertical = clamp(point.y * .24 + .52, 0., 1.);
    vec3 base = mix(vec3(.73, .77, .82), vec3(.91, .93, .94), vertical);
    float cyanPool = exp(-dot((point - vec2(-.85, .34)) * vec2(.7, 1.1), (point - vec2(-.85, .34)) * vec2(.7, 1.1)) * 1.2);
    float pinkPool = exp(-dot((point - vec2(.9, -.45)) * vec2(.8, 1.), (point - vec2(.9, -.45)) * vec2(.8, 1.)) * 1.1);
    base = mix(base, CYAN, cyanPool * .09);
    base = mix(base, PINK, pinkPool * .065);
    return base;
  }

  vec3 studioEnvironment(vec3 reflected) {
    float vertical = smoothstep(-.92, .88, reflected.y);
    vec3 environment = mix(vec3(.56, .62, .7), vec3(.98, .99, 1.), vertical);
    float tallSoftbox = exp(-pow((reflected.x + .56) / .17, 2.)) * smoothstep(-.62, .62, reflected.y);
    float topSoftbox = exp(-pow((reflected.y - .7) / .13, 2.));
    environment = mix(environment, vec3(1.), tallSoftbox * .72);
    environment = mix(environment, vec3(.94, .98, 1.), topSoftbox * .34);
    return environment;
  }

  float valueNoise(vec2 point) {
    vec2 cell = floor(point);
    vec2 fraction = fract(point);
    fraction = fraction * fraction * (3. - 2. * fraction);
    float a = fract(sin(dot(cell, vec2(127.1, 311.7))) * 43758.5453);
    float b = fract(sin(dot(cell + vec2(1., 0.), vec2(127.1, 311.7))) * 43758.5453);
    float c = fract(sin(dot(cell + vec2(0., 1.), vec2(127.1, 311.7))) * 43758.5453);
    float d = fract(sin(dot(cell + vec2(1., 1.), vec2(127.1, 311.7))) * 43758.5453);
    return mix(mix(a, b, fraction.x), mix(c, d, fraction.x), fraction.y);
  }

  float nebulaNoise(vec2 point) {
    float result = valueNoise(point) * .54;
    point = rotate2d(.73) * point * 2.03 + 4.17;
    result += valueNoise(point) * .29;
    point = rotate2d(-.51) * point * 2.01 + 7.31;
    result += valueNoise(point) * .17;
    return result;
  }

  void main() {
    vec2 p = v_uv * 2. - 1.;
    p.x *= u_resolution.x / u_resolution.y;
    vec2 center = vec2(0., -.01);
    float radius = .52;
    vec2 local = p - center;
    float distanceToCenter = length(local);
    float aa = 1.5 / min(u_resolution.x, u_resolution.y);
    float sphereMask = smoothstep(radius + aa, radius - aa, distanceToCenter);
    float time = u_time * u_working;
    vec3 sceneColor = backdrop(p);

    vec2 shadowPoint = (local - vec2(.035, -.055)) / vec2(.67, .57);
    float castShadow = exp(-dot(shadowPoint, shadowPoint) * 9.5) * (1. - sphereMask);
    sceneColor *= 1. - castShadow * .075;
    vec2 causticPoint = (local - vec2(-.075, .055)) / vec2(.61, .53);
    float outerCaustic = exp(-abs(length(causticPoint) - .96) * 24.) * (1. - sphereMask);
    sceneColor = mix(sceneColor, vec3(.98, 1., 1.), outerCaustic * .2);

    float tempo = .5 + .5 * sin(u_time * 1.38);
    float haloDistance = max(distanceToCenter - radius, 0.);
    float workingHalo = exp(-pow(haloDistance / .115, 2.)) * (1. - sphereMask);
    float haloStrength = u_working * (.012 + tempo * .026);
    vec3 haloTint = mix(CYAN, VIOLET, .35);
    sceneColor = min(sceneColor + haloTint * workingHalo * haloStrength, vec3(1.));

    if (sphereMask <= .001) {
      gl_FragColor = vec4(sceneColor, 1.);
      return;
    }

    vec2 q = local / radius;
    float radial = length(q);
    float z = sqrt(max(0., 1. - dot(q, q)));
    vec3 normal = normalize(vec3(q, z));
    float fresnel = pow(1. - max(normal.z, 0.), 2.65);
    float angle = atan(q.y, q.x);

    float lensScale = .68 + radial * radial * .13;
    vec2 refractedPoint = center + q * radius * lensScale;
    refractedPoint += normal.xy * (.012 + fresnel * .026);
    float blurRadius = .0035 + (1. - z) * .008;
    vec3 refracted = backdrop(refractedPoint) * .48;
    refracted += backdrop(refractedPoint + vec2(blurRadius, 0.)) * .13;
    refracted += backdrop(refractedPoint - vec2(blurRadius, 0.)) * .13;
    refracted += backdrop(refractedPoint + vec2(0., blurRadius)) * .13;
    refracted += backdrop(refractedPoint - vec2(0., blurRadius)) * .13;

    float dispersion = .0025 + fresnel * .011;
    vec2 dispersionVector = normalize(q + vec2(.0001)) * dispersion;
    vec3 dispersed = refracted;
    dispersed.r = backdrop(refractedPoint + dispersionVector).r;
    dispersed.b = backdrop(refractedPoint - dispersionVector).b;

    vec2 lensPoint = q + normal.xy * (.05 + fresnel * .08);
    float diagonal = clamp(.5 + lensPoint.x * .29 - lensPoint.y * .34 + .04 * sin(lensPoint.y * 5. + time * .23), 0., 1.);
    vec3 liquidColor = spectrum(diagonal);
    vec2 offsetA = vec2(cos(time * .22), sin(time * .19)) * .18;
    vec2 offsetB = vec2(sin(time * .17), cos(time * .21)) * .2;
    float poolA = exp(-dot((lensPoint - vec2(-.19, .1) - offsetA) * vec2(.75, 1.2), (lensPoint - vec2(-.19, .1) - offsetA) * vec2(.75, 1.2)) * 5.1);
    float poolB = exp(-dot((lensPoint - vec2(.21, -.13) + offsetB) * vec2(1.25, .74), (lensPoint - vec2(.21, -.13) + offsetB) * vec2(1.25, .74)) * 5.7);

    vec2 nebulaPoint = rotate2d(time * .018) * lensPoint;
    vec2 nebulaDrift = vec2(time * .014, -time * .009);
    float nebulaWarp = nebulaNoise(nebulaPoint * 1.34 + nebulaDrift);
    float nebulaField = nebulaNoise(nebulaPoint * 2.08 + vec2(nebulaWarp * .62, -nebulaWarp * .48) + nebulaDrift);
    float nebulaSoft = smoothstep(.24, .64, nebulaField) * smoothstep(1.04, .18, radial);
    float nebulaCore = smoothstep(.48, .8, nebulaField) * smoothstep(.96, .12, radial);
    vec2 cloudAPoint = (nebulaPoint - vec2(-.25, .12)) * vec2(.78, 1.2);
    vec2 cloudBPoint = (nebulaPoint - vec2(.28, -.17)) * vec2(1.18, .76);
    float cloudA = exp(-dot(cloudAPoint, cloudAPoint) * 2.55) * (.52 + nebulaField * .48);
    float cloudB = exp(-dot(cloudBPoint, cloudBPoint) * 2.8) * (.48 + nebulaWarp * .52);
    vec3 nebulaColor = spectrum(clamp(.18 + nebulaPoint.x * .27 - nebulaPoint.y * .19 + nebulaWarp * .48, 0., 1.));

    vec3 color = mix(dispersed, backdropHaze(refractedPoint), .94);
    vec3 environment = studioEnvironment(reflect(vec3(0., 0., -1.), normal));
    float colorVeil = clamp(.1 + (poolA + poolB) * .58, 0., 1.);
    vec3 suspendedColor = mix(liquidColor, mix(CYAN, PINK, poolB), poolA * .35);
    color = mix(color, suspendedColor, colorVeil * .38);
    float nebulaDensity = clamp(nebulaSoft * .27 + nebulaCore * .18 + cloudA * .12 + cloudB * .13, 0., .52);
    color = mix(color, nebulaColor, nebulaDensity);
    color = mix(color, environment, .11 * (.18 + fresnel * .82));

    vec3 viewDirection = vec3(0., 0., 1.);
    vec3 keyLight = normalize(vec3(-.52, .68, .72));
    vec3 fillLight = normalize(vec3(.7, .18, .65));
    float specular = pow(max(dot(reflect(-keyLight, normal), viewDirection), 0.), 108.);
    float softSpecular = pow(max(dot(reflect(-fillLight, normal), viewDirection), 0.), 18.);
    color = mix(color, vec3(1.), specular * .86);
    color = mix(color, vec3(.91, .97, 1.), softSpecular * .1);

    float innerRim = exp(-abs(radial - .9) * 27.);
    float chromaticEdge = exp(-abs(radial - .945) * 46.);
    float thinRim = exp(-abs(radial - .992) * 155.);
    float litSide = .5 + .5 * dot(normal.xy, normalize(vec2(-.72, .69)));
    color = mix(color, vec3(1.), innerRim * (.08 + litSide * .14));
    color = mix(color, spectrum(fract(angle / 6.28318 + .53 + time * .018)), chromaticEdge * .12);
    color = mix(color, vec3(1.), thinRim * (.5 + litSide * .35));

    float lensCrescent = exp(-abs(length(q - vec2(.12, -.08)) - .73) * 72.) * smoothstep(.25, -.62, q.x) * smoothstep(-.5, .55, q.y);
    color = mix(color, vec3(1.), lensCrescent * .22);
    vec2 focusPoint = q - vec2(-.28 + .08 * sin(time * .21), .24 + .05 * cos(time * .17));
    float movingFocus = exp(-dot(focusPoint, focusPoint) * 90.);
    color = mix(color, vec3(1.), movingFocus * .2);
    gl_FragColor = vec4(clamp(color, 0., 1.), 1.);
  }
`;

const SOURCE_SIZE = 180;
const OUTPUT_SIZE = 126;
const OUTPUT_RADIUS = 59;
const FRAME_INTERVAL_MS = 33;

export function createNebulaOrbRenderer(canvas) {
  if (!canvas) return { setWorking() {} };
  const output = canvas.getContext('2d');
  const source = document.createElement('canvas');
  source.width = SOURCE_SIZE;
  source.height = SOURCE_SIZE;
  const gl = source.getContext('webgl', {
    alpha: true,
    antialias: true,
    depth: false,
    premultipliedAlpha: false,
    powerPreference: 'high-performance',
  });
  if (!output) {
    canvas.classList.add('fallback-orb');
    return { setWorking() {} };
  }
  if (!gl) return createCanvasFallback(canvas, output);

  try {
    const program = createProgram(gl);
    gl.useProgram(program);
    const buffer = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, buffer);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 1, -1, -1, 1, -1, 1, 1, -1, 1, 1]), gl.STATIC_DRAW);
    const position = gl.getAttribLocation(program, 'a_position');
    gl.enableVertexAttribArray(position);
    gl.vertexAttribPointer(position, 2, gl.FLOAT, false, 0, 0);
    gl.viewport(0, 0, SOURCE_SIZE, SOURCE_SIZE);
    const uniforms = {
      resolution: gl.getUniformLocation(program, 'u_resolution'),
      time: gl.getUniformLocation(program, 'u_time'),
      working: gl.getUniformLocation(program, 'u_working'),
    };

    canvas.width = OUTPUT_SIZE;
    canvas.height = OUTPUT_SIZE;
    output.imageSmoothingEnabled = true;
    output.imageSmoothingQuality = 'high';
    canvas.dataset.material = '05-nebula-liquid-glass';
    let working = false;
    let frameRequest = 0;
    let frameCount = 0;
    let lastFrameAt = -Infinity;

    const draw = (now) => {
      frameRequest = 0;
      if (now - lastFrameAt >= FRAME_INTERVAL_MS) {
        lastFrameAt = now;
        gl.clearColor(0, 0, 0, 0);
        gl.clear(gl.COLOR_BUFFER_BIT);
        gl.uniform2f(uniforms.resolution, SOURCE_SIZE, SOURCE_SIZE);
        gl.uniform1f(uniforms.time, working ? now / 1000 : 0);
        gl.uniform1f(uniforms.working, working ? 1 : 0);
        gl.drawArrays(gl.TRIANGLES, 0, 6);

        const cropSize = SOURCE_SIZE * .56;
        const cropOffset = (SOURCE_SIZE - cropSize) / 2;
        output.clearRect(0, 0, OUTPUT_SIZE, OUTPUT_SIZE);
        output.save();
        output.beginPath();
        output.arc(OUTPUT_SIZE / 2, OUTPUT_SIZE / 2, OUTPUT_RADIUS, 0, Math.PI * 2);
        output.clip();
        output.drawImage(source, cropOffset, cropOffset, cropSize, cropSize, 0, 0, OUTPUT_SIZE, OUTPUT_SIZE);
        output.restore();
        frameCount += 1;
        canvas.dataset.frameCount = String(frameCount);
        canvas.dataset.renderState = working ? 'working' : 'idle';
      }
      if (working) frameRequest = requestAnimationFrame(draw);
    };

    const setWorking = (nextWorking) => {
      const next = Boolean(nextWorking);
      if (working === next && frameCount > 0) return;
      working = next;
      if (frameRequest) cancelAnimationFrame(frameRequest);
      frameRequest = requestAnimationFrame(draw);
    };

    setWorking(false);
    return { setWorking };
  } catch {
    return createCanvasFallback(canvas, output);
  }
}

function createCanvasFallback(canvas, context) {
  canvas.width = OUTPUT_SIZE;
  canvas.height = OUTPUT_SIZE;
  canvas.dataset.material = '05-nebula-liquid-glass-fallback';
  let working = false;
  let frameRequest = 0;
  let frameCount = 0;
  let lastFrameAt = -Infinity;

  const draw = (now) => {
    frameRequest = 0;
    if (now - lastFrameAt >= FRAME_INTERVAL_MS) {
      lastFrameAt = now;
      drawFallbackFrame(context, working ? now / 1000 : 0, working);
      frameCount += 1;
      canvas.dataset.frameCount = String(frameCount);
      canvas.dataset.renderState = working ? 'working' : 'idle';
    }
    if (working) frameRequest = requestAnimationFrame(draw);
  };

  const setWorking = (nextWorking) => {
    const next = Boolean(nextWorking);
    if (working === next && frameCount > 0) return;
    working = next;
    if (frameRequest) cancelAnimationFrame(frameRequest);
    frameRequest = requestAnimationFrame(draw);
  };

  setWorking(false);
  return { setWorking };
}

function drawFallbackFrame(context, time, working) {
  const center = OUTPUT_SIZE / 2;
  const sphereRadius = 55;
  context.clearRect(0, 0, OUTPUT_SIZE, OUTPUT_SIZE);
  context.save();
  context.beginPath();
  context.arc(center, center, OUTPUT_RADIUS, 0, Math.PI * 2);
  context.clip();

  const backdrop = context.createLinearGradient(0, OUTPUT_SIZE, OUTPUT_SIZE, 0);
  backdrop.addColorStop(0, '#b9c4cf');
  backdrop.addColorStop(1, '#edf1f3');
  context.fillStyle = backdrop;
  context.fillRect(0, 0, OUTPUT_SIZE, OUTPUT_SIZE);

  if (working) {
    const halo = context.createRadialGradient(center, center, sphereRadius * .72, center, center, OUTPUT_RADIUS);
    halo.addColorStop(0, 'rgba(110, 142, 238, 0)');
    halo.addColorStop(.75, `rgba(112, 130, 238, ${.03 + (.5 + .5 * Math.sin(time * 1.38)) * .05})`);
    halo.addColorStop(1, 'rgba(137, 100, 219, 0)');
    context.fillStyle = halo;
    context.fillRect(0, 0, OUTPUT_SIZE, OUTPUT_SIZE);
  }

  context.save();
  context.beginPath();
  context.arc(center, center, sphereRadius, 0, Math.PI * 2);
  context.clip();
  const glass = context.createLinearGradient(18, 12, 108, 114);
  glass.addColorStop(0, '#f6fbfd');
  glass.addColorStop(.45, '#c3cddd');
  glass.addColorStop(1, '#9c91b9');
  context.fillStyle = glass;
  context.fillRect(0, 0, OUTPUT_SIZE, OUTPUT_SIZE);

  context.globalCompositeOperation = 'screen';
  const drift = working ? time : 0;
  drawColorPool(context, 46 + Math.sin(drift * .22) * 8, 49 + Math.cos(drift * .19) * 6, 48, '#58d8ef', .52);
  drawColorPool(context, 76 + Math.cos(drift * .17) * 8, 48 + Math.sin(drift * .21) * 7, 47, '#557aff', .48);
  drawColorPool(context, 66 + Math.sin(drift * .14) * 7, 79 + Math.cos(drift * .16) * 8, 50, '#9569ea', .55);
  drawColorPool(context, 88 + Math.cos(drift * .13) * 6, 82 + Math.sin(drift * .15) * 7, 38, '#ea82b1', .42);
  context.globalCompositeOperation = 'source-over';

  const lens = context.createRadialGradient(42, 32, 2, center, center, sphereRadius);
  lens.addColorStop(0, 'rgba(255,255,255,.74)');
  lens.addColorStop(.18, 'rgba(255,255,255,.12)');
  lens.addColorStop(.76, 'rgba(223,237,248,.02)');
  lens.addColorStop(1, 'rgba(104,90,146,.22)');
  context.fillStyle = lens;
  context.fillRect(0, 0, OUTPUT_SIZE, OUTPUT_SIZE);
  context.restore();

  context.strokeStyle = 'rgba(255,255,255,.72)';
  context.lineWidth = 1.4;
  context.beginPath();
  context.arc(center, center, sphereRadius - .7, 0, Math.PI * 2);
  context.stroke();
  const glint = context.createRadialGradient(40, 33, 0, 40, 33, 18);
  glint.addColorStop(0, 'rgba(255,255,255,.9)');
  glint.addColorStop(.35, 'rgba(255,255,255,.35)');
  glint.addColorStop(1, 'rgba(255,255,255,0)');
  context.fillStyle = glint;
  context.beginPath();
  context.ellipse(40, 33, 18, 11, -.45, 0, Math.PI * 2);
  context.fill();
  context.restore();
}

function drawColorPool(context, x, y, radius, color, alpha) {
  const gradient = context.createRadialGradient(x, y, 0, x, y, radius);
  gradient.addColorStop(0, color);
  gradient.addColorStop(1, 'rgba(255,255,255,0)');
  context.globalAlpha = alpha;
  context.fillStyle = gradient;
  context.fillRect(x - radius, y - radius, radius * 2, radius * 2);
  context.globalAlpha = 1;
}

function createProgram(gl) {
  const program = gl.createProgram();
  gl.attachShader(program, compileShader(gl, gl.VERTEX_SHADER, VERTEX_SOURCE));
  gl.attachShader(program, compileShader(gl, gl.FRAGMENT_SHADER, FRAGMENT_SOURCE));
  gl.linkProgram(program);
  if (!gl.getProgramParameter(program, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(program));
  return program;
}

function compileShader(gl, type, source) {
  const shader = gl.createShader(type);
  gl.shaderSource(shader, source);
  gl.compileShader(shader);
  if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(shader));
  return shader;
}
