#!/bin/sh
':' //; exec "$(command -v node || command -v bun)" "$0" "$@"
// The line above is shell and JavaScript at once: sh runs Node, or Bun when
// Node is missing; JavaScript sees a string and a comment.
import { runCli } from "../dist/cli.js";

process.exitCode = await runCli(process.argv.slice(2));
