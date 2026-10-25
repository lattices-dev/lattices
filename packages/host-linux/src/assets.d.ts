declare module "*.c" {
  /** C helper source bundled by Bun's text loader. */
  const source: string;
  export default source;
}
