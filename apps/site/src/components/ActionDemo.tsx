import { useEffect, useRef } from "react";

const demoVideo = "/action/virtual-workspaces-demo.mp4";
const demoPoster = "/action/virtual-workspaces-demo.webp";

export function ActionDemo() {
  const videoRef = useRef<HTMLVideoElement>(null);

  useEffect(() => {
    const video = videoRef.current;
    if (!video) return;
    const motion = window.matchMedia("(prefers-reduced-motion: reduce)");
    const connection = (navigator as Navigator & { connection?: { saveData?: boolean } }).connection;
    if (!motion.matches && !connection?.saveData) void video.play().catch(() => {});
    const onMotionChange = () => {
      if (motion.matches) video.pause();
    };
    motion.addEventListener("change", onMotionChange);
    return () => motion.removeEventListener("change", onMotionChange);
  }, []);

  return (
    <figure className="action-demo">
      <video
        ref={videoRef}
        controls
        muted
        loop
        playsInline
        preload="metadata"
        width={1920}
        height={1080}
        poster={demoPoster}
        aria-label="Action demo: a terminal drives a browser and opens a live virtual workspace preview"
        aria-describedby="action-demo-caption"
      >
        <source src={demoVideo} type="video/mp4" />
        <a href={demoVideo}>Watch the Action demo.</a>
      </video>
      <figcaption id="action-demo-caption">
        <div>
          <strong>A real terminal. A real browser. A live agent preview.</strong>
          <p>29-second development preview. Scripted sequence, real MCP calls.</p>
        </div>
        <a href={demoVideo} target="_blank" rel="noopener noreferrer">Open full-size video <span aria-hidden="true">↗</span></a>
      </figcaption>
      <details className="action-demo-description">
        <summary>What happens in the demo</summary>
        <p>A Ghostty terminal sits on the left and a browser on the right of a virtual desktop. The terminal runs an Action call that opens the Lattices docs. Its next call creates a second virtual workspace, whose live preview appears over the browser. Further calls navigate that workspace to the docs and read the page title. The entire stage is recorded locally on a Mac. This is a timed script executing real calls, not an agent deciding its next steps live. There is no audio.</p>
      </details>
    </figure>
  );
}
