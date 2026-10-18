// Appearance messages as the app bridge sends them, for the Theme tests and
// renders. appearance.test.ts regenerates each one from `sources`
// and fails if the loader has drifted from what is written here.

export const sources = {
  "light": {
    "name": "white",
    "config": {
      "translucency": 1
    },
    "colors": "mode = \"light\"\naccent = \"#6e6e6e\"\nbackground = \"#ffffff\"\nforeground = \"#000000\"\nred = \"#2a2a2a\"\ngreen = \"#3a3a3a\"\n"
  },
  "tinted": {
    "name": "tokyo-night",
    "config": {
      "translucency": 1
    },
    "colors": "accent = \"#7aa2f7\"\nbackground = \"#1a1b26\"\nforeground = \"#a9b1d6\"\n"
  },
  "glass": {
    "name": "matte-black",
    "config": {
      "translucency": 0.88
    },
    "colors": "mode = \"dark\"\naccent = \"#e68e0d\"\nbackground = \"#121212\"\nforeground = \"#bebebe\"\ngreen = \"#FFC107\"\nyellow = \"#b91c1c\"\n"
  }
};

export const light = {
  "source": "omarchy",
  "theme": "white",
  "mode": "light",
  "chassisOpacity": 1,
  "font": "Adwaita Sans",
  "mono": "JetBrains Mono",
  "tokens": {
    "ink": "#ededed",
    "bg": "#ffffff",
    "chassis": "#f6f6f6",
    "surface": "#f6f6f6",
    "hover": "#e8e8e8",
    "border": "#e3e3e3",
    "borderLit": "#cccccc",
    "borderHot": "#adadad",
    "grid": "#e0e0e0",
    "text": "#171717",
    "body": "#3a3a3a",
    "muted": "#575757",
    "dim": "#747474",
    "accent": "#6e6e6e",
    "accentSoft": "#e9e9e9",
    "accentLine": "#b4b4b4",
    "accentHover": "#585858",
    "accentInk": "#f3f3f3",
    "selection": "#cecece",
    "live": "#171717",
    "liveSoft": "#e3e3e3",
    "liveLine": "#a3a3a3",
    "caution": "#8e550b",
    "cautionSoft": "#f0e9df",
    "cautionLine": "#ccb391",
    "red": "#b6202a",
    "redSoft": "#f4dedf",
    "redText": "#6a1318"
  }
};

export const tinted = {
  "source": "omarchy",
  "theme": "tokyo-night",
  "mode": "dark",
  "chassisOpacity": 1,
  "font": "Adwaita Sans",
  "mono": "JetBrains Mono",
  "tokens": {
    "ink": "#101017",
    "bg": "#161720",
    "chassis": "#1a1b26",
    "surface": "#252631",
    "hover": "#2f303a",
    "border": "#2c2d38",
    "borderLit": "#3f404a",
    "borderHot": "#55565f",
    "grid": "#30313b",
    "text": "#f3f4f9",
    "body": "#cacbd1",
    "muted": "#a0a1a8",
    "dim": "#7f8088",
    "accent": "#7aa2f7",
    "accentSoft": "#252c40",
    "accentLine": "#4a5f90",
    "accentHover": "#92b2f7",
    "accentInk": "#111723",
    "selection": "#384669",
    "live": "#f3f4f9",
    "liveSoft": "#2e2f38",
    "liveLine": "#66676e",
    "caution": "#ddbb88",
    "cautionSoft": "#302c2e",
    "cautionLine": "#70614f",
    "red": "#ef6c70",
    "redSoft": "#37242c",
    "redText": "#f1a5aa"
  }
};

export const glass = {
  "source": "omarchy",
  "theme": "matte-black",
  "mode": "dark",
  "chassisOpacity": 0.88,
  "font": "Adwaita Sans",
  "mono": "JetBrains Mono",
  "tokens": {
    "ink": "#0b0b0b",
    "bg": "#0f0f0f",
    "chassis": "#121212",
    "surface": "#1d1d1d",
    "hover": "#282828",
    "border": "#252525",
    "borderLit": "#393939",
    "borderHot": "#505050",
    "grid": "#292929",
    "text": "#f1f1f1",
    "body": "#c2c2c2",
    "muted": "#9a9a9a",
    "dim": "#797979",
    "accent": "#e68e0d",
    "accentSoft": "#2f220f",
    "accentLine": "#7f510e",
    "accentHover": "#e9a33c",
    "accentInk": "#201402",
    "selection": "#583a0e",
    "live": "#f1f1f1",
    "liveSoft": "#282828",
    "liveLine": "#626262",
    "caution": "#ddbb88",
    "cautionSoft": "#2a251f",
    "cautionLine": "#6c5c45",
    "red": "#ef6c70",
    "redSoft": "#311d1e",
    "redText": "#f2a6a8"
  }
};
