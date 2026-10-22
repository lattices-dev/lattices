import { stat } from 'node:fs/promises'
import { isAbsolute, relative, resolve, sep } from 'node:path'
import type { Plugin } from 'vite'

/** Match the exported directory routes during preview without changing dev SPA routing. */
export function staticPreview(): Plugin {
  return {
    name: 'lattices-static-preview',
    config(_config, { isPreview }) {
      // Vite's MPA mode retains static HTML serving but removes the /index.html
      // fallback that otherwise returns HTML 200 for missing agent artifacts.
      if (isPreview) return { appType: 'mpa' }
    },
    configurePreviewServer(server) {
      const output = resolve(server.config.root, server.config.build.outDir)
      server.middlewares.use(async (request, response, next) => {
        if (request.method !== 'GET' && request.method !== 'HEAD') return next()
        const url = request.url ?? '/'
        const queryAt = url.indexOf('?')
        const pathname = queryAt < 0 ? url : url.slice(0, queryAt)
        if (pathname.endsWith('/')) return next()
        if (!pathname.startsWith('/') || pathname.startsWith('//') || pathname.includes('\\')) return next()

        let decoded: string
        try { decoded = decodeURIComponent(pathname) } catch { return next() }
        const index = resolve(output, `.${decoded}`, 'index.html')
        const withinOutput = relative(output, index)
        if (withinOutput === '..' || withinOutput.startsWith(`..${sep}`) || isAbsolute(withinOutput)) return next()

        try {
          if (!(await stat(index)).isFile()) return next()
        } catch { return next() }

        // Directory URLs on GitHub Pages end in /. Preserve the query string,
        // then let Vite serve that directory's exported HTML on the next request.
        response.writeHead(301, {
          Location: `${pathname}/${queryAt < 0 ? '' : url.slice(queryAt)}`,
        })
        response.end()
      })
    },
  }
}
