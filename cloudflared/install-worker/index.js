export default {
  async fetch(request) {
    try {
      const requestUrl = new URL(request.url);
      const branchParam = requestUrl.searchParams.get('branch');
      const branch = /^[A-Za-z0-9._/-]+$/.test(branchParam || '') ? branchParam : 'main';
      const sourceUrl = new URL('https://api.github.com/repos/vaoan/PCSetup/contents/remote-call.ps1');
      sourceUrl.searchParams.set('ref', branch);
      sourceUrl.searchParams.set('ts', Date.now().toString());

      const response = await fetch(sourceUrl.toString(), {
        headers: {
          Accept: 'application/vnd.github.raw',
          'User-Agent': 'pcsetup-install-worker'
        },
        cf: {
          cacheEverything: false,
          cacheTtl: 0,
          cacheTtlByStatus: {
            '200-299': 0,
            '400-599': 0
          }
        }
      });

      if (!response.ok) {
        return new Response(
          `Error fetching remote script: ${response.status} ${response.statusText}`,
          {
            status: 502,
            headers: { 'Content-Type': 'text/plain; charset=utf-8' }
          }
        );
      }

      const scriptContent = await response.text();

      return new Response(scriptContent, {
        status: 200,
        headers: {
          'Content-Type': 'text/plain; charset=utf-8',
          'Cache-Control': 'no-cache',
          'X-PCSetup-Branch': branch,
          'X-PCSetup-Source': sourceUrl.toString()
        }
      });
    } catch (error) {
      return new Response(
        `Error: ${error.message}`,
        {
          status: 502,
          headers: { 'Content-Type': 'text/plain; charset=utf-8' }
        }
      );
    }
  }
};
