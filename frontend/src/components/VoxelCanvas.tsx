"use client";

import { useEffect, useRef } from "react";
import { SCENES, type Voxel } from "@/lib/voxel";

// Faces: normal and its 4 corners (offsets from the voxel centre). Bottom faces are never visible from above.
const FACES: { n: [number, number, number]; c: [number, number, number][] }[] = [
  { n: [0, 1, 0], c: [[-1, 1, -1], [1, 1, -1], [1, 1, 1], [-1, 1, 1]] },
  { n: [1, 0, 0], c: [[1, -1, -1], [1, 1, -1], [1, 1, 1], [1, -1, 1]] },
  { n: [-1, 0, 0], c: [[-1, -1, -1], [-1, 1, -1], [-1, 1, 1], [-1, -1, 1]] },
  { n: [0, 0, 1], c: [[-1, -1, 1], [1, -1, 1], [1, 1, 1], [-1, 1, 1]] },
  { n: [0, 0, -1], c: [[-1, -1, -1], [1, -1, -1], [1, 1, -1], [-1, 1, -1]] },
];

const ELEV = 0.52; // camera elevation, radians
const SIN_E = Math.sin(ELEV);
const COS_E = Math.cos(ELEV);
const LIGHT = (() => {
  const l = [-0.55, 0.9, 0.65];
  const m = Math.hypot(l[0], l[1], l[2]);
  return l.map((v) => v / m);
})();

/** Which faces of each voxel touch air, as a 5-bit mask over FACES. */
function exposure(vox: Voxel[]) {
  const set = new Set(vox.map(([x, y, z]) => `${x},${y},${z}`));
  return vox.map(([x, y, z]) => {
    let m = 0;
    FACES.forEach((f, i) => {
      if (!set.has(`${x + f.n[0]},${y + f.n[1]},${z + f.n[2]}`)) m |= 1 << i;
    });
    return m;
  });
}

function draw(ctx: CanvasRenderingContext2D, w: number, h: number, vox: Voxel[], mask: number[], theta: number, radius: number, centerY: number) {
  ctx.clearRect(0, 0, w, h);
  const s = Math.min(w, h * 1.15) / (radius * 2.3);
  const ox = w / 2;
  const oy = h / 2 + centerY * s * COS_E;
  const ct = Math.cos(theta);
  const st = Math.sin(theta);

  // ground shadow
  const grad = ctx.createRadialGradient(ox, oy, 0, ox, oy, radius * s);
  grad.addColorStop(0, "rgba(0,0,0,0.45)");
  grad.addColorStop(1, "rgba(0,0,0,0)");
  ctx.fillStyle = grad;
  ctx.beginPath();
  ctx.ellipse(ox, oy + s, radius * s, radius * s * SIN_E, 0, 0, Math.PI * 2);
  ctx.fill();

  // rotate, then paint far to near
  const items = vox.map((v, i) => {
    const xr = v[0] * ct - v[2] * st;
    const zr = v[0] * st + v[2] * ct;
    return { i, xr, zr, y: v[1], depth: zr * COS_E + v[1] * SIN_E };
  });
  items.sort((a, b) => a.depth - b.depth);

  const proj = (x: number, y: number, z: number): [number, number] => [ox + x * s, oy - (y * COS_E - z * SIN_E) * s];

  for (const it of items) {
    const [, , , c] = vox[it.i];
    const m = mask[it.i];
    for (let f = 0; f < FACES.length; f++) {
      if (!(m & (1 << f))) continue;
      const n = FACES[f].n;
      const nx = n[0] * ct - n[2] * st;
      const nz = n[0] * st + n[2] * ct;
      if (n[1] === 0 && nz <= 0.001) continue;
      const lit = 0.5 + 0.55 * Math.max(0, nx * LIGHT[0] + n[1] * LIGHT[1] + nz * LIGHT[2]);
      ctx.fillStyle = `rgb(${Math.min(255, c[0] * lit) | 0},${Math.min(255, c[1] * lit) | 0},${Math.min(255, c[2] * lit) | 0})`;
      ctx.strokeStyle = ctx.fillStyle;
      ctx.beginPath();
      FACES[f].c.forEach(([dx, dy, dz], k) => {
        const lx = dx * 0.5, lz = dz * 0.5;
        const [px, py] = proj(it.xr + lx * ct - lz * st, it.y + dy * 0.5, it.zr + lx * st + lz * ct);
        if (k === 0) ctx.moveTo(px, py);
        else ctx.lineTo(px, py);
      });
      ctx.closePath();
      ctx.fill();
      ctx.lineWidth = 0.6;
      ctx.stroke();
    }
  }
}

/** A slowly turning voxel scene. Pauses off screen and stands still for reduced motion. */
export function VoxelCanvas({
  scene,
  spin = 0.25,
  className,
  label,
}: {
  scene: keyof typeof SCENES;
  spin?: number;
  className?: string;
  label: string;
}) {
  const ref = useRef<HTMLCanvasElement>(null);

  useEffect(() => {
    const canvas = ref.current;
    if (!canvas) return;
    const ctx = canvas.getContext("2d");
    if (!ctx) return;
    const sc = SCENES[scene];
    const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

    let vox = sc.build(0);
    let mask = exposure(vox);
    let w = 0, h = 0, raf = 0, visible = true, last = 0;
    const t0 = performance.now();

    const resize = () => {
      const r = canvas.getBoundingClientRect();
      const dpr = Math.min(2, window.devicePixelRatio || 1);
      w = r.width;
      h = r.height;
      canvas.width = Math.round(w * dpr);
      canvas.height = Math.round(h * dpr);
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    };

    const frame = (now: number) => {
      raf = requestAnimationFrame(frame);
      if (!visible || now - last < 1000 / 30) return;
      last = now;
      const t = (now - t0) / 1000;
      if (sc.animated) {
        vox = sc.build(t);
        mask = exposure(vox);
      }
      draw(ctx, w, h, vox, mask, -0.7 + t * spin, sc.radius, sc.centerY);
    };

    resize();
    const ro = new ResizeObserver(() => {
      resize();
      if (reduce) draw(ctx, w, h, vox, mask, -0.7, sc.radius, sc.centerY);
    });
    ro.observe(canvas);
    const io = new IntersectionObserver(([e]) => (visible = e.isIntersecting));
    io.observe(canvas);

    if (reduce) draw(ctx, w, h, vox, mask, -0.7, sc.radius, sc.centerY);
    else raf = requestAnimationFrame(frame);

    return () => {
      cancelAnimationFrame(raf);
      ro.disconnect();
      io.disconnect();
    };
  }, [scene, spin]);

  return <canvas ref={ref} className={className} role="img" aria-label={label} />;
}
