export default {
  async fetch(request) {
    const requestUrl = new URL(request.url);
    const branchParam = requestUrl.searchParams.get('branch');
    const branch = /^[A-Za-z0-9._/-]+$/.test(branchParam || '') ? branchParam : 'main';
    const branchLiteral = JSON.stringify(branch);

    const script = [
      `param([string]$Branch = ${branchLiteral})`,
      ``,
      `[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072`,
      `$resolvedBranch = if ([string]::IsNullOrWhiteSpace($Branch)) { ${branchLiteral} } else { $Branch }`,
      `$sourceUrl = "https://raw.githubusercontent.com/vaoan/PCSetup/refs/heads/$resolvedBranch/remote-call.ps1?ts=$([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())"`,
      `& ([scriptblock]::Create((Invoke-RestMethod -Uri $sourceUrl -UseBasicParsing))) -Branch $resolvedBranch`
    ].join('\n');

    return new Response(script, {
      status: 200,
      headers: {
        'Content-Type': 'text/plain; charset=utf-8',
        'Cache-Control': 'no-cache',
        'X-PCSetup-Branch': branch,
        'X-PCSetup-Source': `https://raw.githubusercontent.com/vaoan/PCSetup/refs/heads/${branch}/remote-call.ps1`
      }
    });
  }
};
