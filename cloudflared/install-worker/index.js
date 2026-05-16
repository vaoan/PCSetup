export default {
  async fetch(request) {
    try {
      const response = await fetch(
        'https://raw.githubusercontent.com/vaoan/PCSetup/refs/heads/main/remote-call.ps1'
      );

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
          'Cache-Control': 'no-cache'
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
