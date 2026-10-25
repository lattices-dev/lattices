import type React from "react"
import type { Metadata } from "next"
import { Cormorant_Garamond, JetBrains_Mono } from "next/font/google"
import { GoogleAnalytics } from "@/components/GoogleAnalytics"
import "./globals.css"

const jetBrainsMono = JetBrains_Mono({
  subsets: ["latin"],
  variable: "--font-jetbrains-mono",
  weight: "variable",
  display: "swap",
})

const cormorantGaramond = Cormorant_Garamond({
  subsets: ["latin"],
  variable: "--font-display",
  weight: ["500", "600"],
  display: "swap",
})

const themeBootScript = `try{
  var raw=new URLSearchParams(location.search).get('theme');
  var normalize=function(value){
    if(value==='light'||value==='cream')return 'light';
    if(value==='dark'||value==='black')return 'dark';
    if(value==='auto')return 'auto';
    return null;
  };
  var query=normalize(raw);
  var saved=null;
  try{saved=normalize(localStorage.getItem('blink-theme'));}catch(e){}
  var preference=query||saved||'auto';
  if(query){try{localStorage.setItem('blink-theme',preference);}catch(e){}}
  document.documentElement.setAttribute('data-theme-preference',preference);
  var dark=preference==='dark'||(preference==='auto'&&window.matchMedia('(prefers-color-scheme: dark)').matches);
  if(dark)document.documentElement.setAttribute('data-theme','black');
  else document.documentElement.removeAttribute('data-theme');
}catch(e){}`

export const metadata: Metadata = {
  metadataBase: new URL("https://blink.arach.dev"),
  title: "Canvas — Spatial notes for your Mac",
  description:
    "A native macOS menubar app. Summon a borderless glass note anywhere with a keystroke, place it in space, and it stays. Plain markdown you own — open to your agents.",
  keywords:
    "macOS notes, menubar app, spatial notes, floating notes, markdown, keyboard-first, agent-first, native app",
  authors: [{ name: "Canvas" }],
  alternates: {
    canonical: "/",
    types: {
      "text/plain": [{ url: "/llms.txt", title: "Canvas for language models" }],
      "text/markdown": [{ url: "/agents.md", title: "Canvas agent instructions" }],
    },
  },
  openGraph: {
    title: "Canvas — Spatial notes for your Mac",
    description:
      "Summon a borderless glass note anywhere with a keystroke, place it in space, and it stays. Plain markdown you own — open to your agents.",
    type: "website",
  },
}

export default function RootLayout({
  children,
}: {
  children: React.ReactNode
}) {
  return (
    // suppressHydrationWarning: the script below sets data-theme on <html> before
    // React hydrates, so the server markup and client DOM intentionally differ.
    <html
      lang="en"
      className={`${jetBrainsMono.variable} ${cormorantGaramond.variable}`}
      suppressHydrationWarning
    >
      <body>
        {/* Resolve light, dark, or the macOS preference before paint — no flash. */}
        <script
          dangerouslySetInnerHTML={{
            __html: themeBootScript,
          }}
        />
        {children}
        <GoogleAnalytics />
      </body>
    </html>
  )
}
